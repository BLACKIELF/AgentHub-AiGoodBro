package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	provider "github.com/router-for-me/CLIProxyAPI/v8/internal/runtime/executor"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
)

// Codex's native image_gen tool sends JSON to Images, not to Responses.
// Match its model without substituting the conversation's text model.
const nativeImageModel = "gpt-image-2"

func imageLocalPath(path string) string {
	switch path {
	case "/v1/images/generations", "/images/generations":
		return "/images/generations"
	case "/v1/images/edits", "/images/edits":
		return "/images/edits"
	default:
		return ""
	}
}

func imageUpstreamPath(path string) bool {
	return path == "/backend-api/codex/images/generations" || path == "/backend-api/codex/images/edits" || path == "/images/generations" || path == "/images/edits"
}

type imageExecutor struct {
	*provider.CodexExecutor
	transports transportProvider
	baseURL    string
}

const codexIncompleteBootstrapMessage = "stream error: stream disconnected before completion: stream closed before response.completed"

// CLIProxyAPI v8.0.2 labels a clean EOF before the first SSE frame as a
// request-scoped 408, which prevents the manager from trying another account.
// Match only that synchronous, pre-bootstrap sentinel; HTTP 408 responses and
// errors after the stream starts retain their upstream behavior.
// Keep this error without IsRequestScoped: Manager treats that interface as a
// client request fault and stops account rotation, while this is an upstream
// gateway failure that should be eligible for the next admitted account.
type emptyBootstrapError struct{}

func (emptyBootstrapError) Error() string   { return "upstream stream closed before first payload" }
func (emptyBootstrapError) StatusCode() int { return http.StatusBadGateway }

func isEmptyCodexBootstrapEOF(result *executor.StreamResult, err error) bool {
	if result != nil || err == nil || err.Error() != codexIncompleteBootstrapMessage {
		return false
	}
	status, ok := err.(interface{ StatusCode() int })
	return ok && status.StatusCode() == http.StatusRequestTimeout
}

func (e *imageExecutor) ExecuteStream(ctx context.Context, a *auth.Auth, request executor.Request, opts executor.Options) (*executor.StreamResult, error) {
	result, err := e.CodexExecutor.ExecuteStream(ctx, a, request, opts)
	if isEmptyCodexBootstrapEOF(result, err) {
		return nil, emptyBootstrapError{}
	}
	return result, err
}

func (e *imageExecutor) Execute(ctx context.Context, a *auth.Auth, request executor.Request, opts executor.Options) (executor.Response, error) {
	if opts.Alt != "/images/generations" && opts.Alt != "/images/edits" {
		return e.CodexExecutor.Execute(ctx, a, request, opts)
	}
	upstream, err := http.NewRequestWithContext(ctx, http.MethodPost, e.baseURL+opts.Alt, bytes.NewReader(request.Payload))
	if err != nil {
		return executor.Response{}, &imageRequestError{status: 502}
	}
	// Disable net/http's implicit replay even when the caller sends an
	// Idempotency-Key. Only explicit 401/429 rejection permits another attempt.
	upstream.GetBody = nil
	// Only protocol headers cross this boundary. Desktop workspace/cookies and
	// its bearer must never replace the identity of the selected pool lease.
	for _, name := range []string{"Accept", "User-Agent", "Originator", "X-Codex-Image-Turn-Id", "Idempotency-Key"} {
		if value := opts.Headers.Get(name); value != "" {
			upstream.Header.Set(name, value)
		}
	}
	upstream.Header.Set("Content-Type", "application/json")
	if err := e.PrepareRequest(upstream, a); err != nil {
		return executor.Response{}, &imageRequestError{status: 502}
	}
	accountID, _ := a.Metadata["account_id"].(string)
	upstream.Header.Set("ChatGPT-Account-ID", accountID)
	// RoundTrip never follows redirects or replays an uncertain generation.
	response, err := e.transports.RoundTripperFor(a).RoundTrip(upstream)
	if err != nil {
		return executor.Response{}, &imageRequestError{status: 502}
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(response.Body)
	headers := imageResponseHeaders(response.Header)
	if err != nil || (response.StatusCode >= 300 && response.StatusCode < 400) {
		return executor.Response{}, &imageRequestError{status: 502, headers: headers}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return executor.Response{}, &imageRequestError{status: response.StatusCode, payload: payload, headers: headers}
	}
	return executor.Response{Payload: payload, Headers: headers}, nil
}

// Explicit authentication/rate-limit rejections may try another admitted
// account. All other failures stop, especially a lost response after acceptance.
type imageRequestError struct {
	status  int
	payload []byte
	headers http.Header
}

func (e *imageRequestError) Error() string         { return "native image request failed" }
func (e *imageRequestError) StatusCode() int       { return e.status }
func (e *imageRequestError) IsRequestScoped() bool { return e.status != 401 && e.status != 429 }
func (e *imageRequestError) RetryAfter() *time.Duration {
	value := e.headers.Get("Retry-After")
	var delay time.Duration
	if seconds, err := strconv.ParseUint(value, 10, 31); err == nil {
		delay = time.Duration(seconds) * time.Second
	} else if until, err := http.ParseTime(value); err == nil {
		delay = time.Until(until)
	}
	if delay <= 0 {
		return nil
	}
	return &delay
}

func imageResponseHeaders(in http.Header) http.Header {
	out := make(http.Header)
	for _, name := range []string{"Content-Type", "X-Codex-Imagegen-Request-Id", "X-Request-Id", "Retry-After"} {
		if value := in.Get(name); value != "" {
			out.Set(name, value)
		}
	}
	return out
}

func imageHandler(manager *auth.Manager) gin.HandlerFunc {
	return func(c *gin.Context) {
		payload, err := io.ReadAll(c.Request.Body)
		var request struct {
			Model string `json:"model"`
		}
		if err != nil || json.Unmarshal(payload, &request) != nil || strings.TrimSpace(request.Model) == "" {
			c.JSON(400, gin.H{"error": gin.H{"message": "Invalid image request JSON or missing model"}})
			return
		}
		response, err := manager.Execute(c.Request.Context(), []string{"codex"}, executor.Request{Model: request.Model, Payload: payload}, executor.Options{Alt: imageLocalPath(c.Request.URL.Path), Headers: c.Request.Header})
		status := http.StatusOK
		if err != nil {
			var upstreamError *imageRequestError
			if errors.As(err, &upstreamError) {
				status = upstreamError.status
				response = executor.Response{Payload: upstreamError.payload, Headers: upstreamError.headers}
			} else {
				status = http.StatusServiceUnavailable
			}
			if len(response.Payload) == 0 {
				response.Payload = []byte(`{"error":{"message":"Native image request unavailable; no confirmed image result"}}`)
			}
		}
		for name, values := range response.Headers {
			c.Writer.Header()[name] = values
		}
		c.Data(status, "application/json", response.Payload)
	}
}
