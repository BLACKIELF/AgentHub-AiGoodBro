package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/translator"
)

type gateway struct {
	pool    *pool
	backend backend
	persist func(context.Context, credential, string, string) error
	key     string
	host    string
	slots   chan struct{}
}

func writeError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if status == 429 || status == 503 {
		w.Header().Set("Retry-After", "1")
	}
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": code, "message": code, "type": "antigravity_proxy_error"}})
}

func (g *gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	remote, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || !net.ParseIP(remote).IsLoopback() || r.Host != g.host || r.Header.Get("Origin") != "" || r.Header.Get("Sec-Fetch-Site") != "" {
		writeError(w, 403, "local_client_required")
		return
	}
	key := ""
	if authorization := r.Header.Get("Authorization"); authorization != "" {
		if !strings.HasPrefix(authorization, "Bearer ") {
			writeError(w, 401, "unauthorized")
			return
		}
		key = strings.TrimPrefix(authorization, "Bearer ")
	}
	for _, header := range []string{"Authorization", "X-Goog-Api-Key", "X-Api-Key"} {
		if len(r.Header.Values(header)) > 1 {
			writeError(w, 401, "unauthorized")
			return
		}
		if header == "Authorization" {
			continue
		}
		value := r.Header.Get(header)
		if value == "" {
			continue
		}
		if key != "" && key != value {
			writeError(w, 401, "unauthorized")
			return
		}
		key = value
	}
	if subtle.ConstantTimeCompare([]byte(key), []byte(g.key)) != 1 {
		writeError(w, 401, "unauthorized")
		return
	}
	provider, path, validRoute := providerRoute(r.URL.Path)
	if !validRoute {
		writeError(w, 404, "route_not_found")
		return
	}
	// No browser CORS, admin, upload, file, plugin or OAuth HTTP surface.
	if r.Method == http.MethodGet && (path == "/v1/models" || path == "/v1beta/models") {
		_, models := g.pool.snapshotsForProvider(provider)
		rows := make([]map[string]any, 0, len(models))
		for _, model := range models {
			if path == "/v1/models" {
				rows = append(rows, map[string]any{"id": model, "object": "model", "owned_by": provider})
			} else {
				rows = append(rows, map[string]any{"name": "models/" + model, "displayName": model, "supportedGenerationMethods": []string{"generateContent", "streamGenerateContent", "countTokens"}})
			}
		}
		w.Header().Set("Content-Type", "application/json")
		if path == "/v1/models" {
			_ = json.NewEncoder(w).Encode(map[string]any{"object": "list", "data": rows})
		} else {
			_ = json.NewEncoder(w).Encode(map[string]any{"models": rows})
		}
		return
	}
	if r.Method != http.MethodPost {
		writeError(w, 404, "route_not_found")
		return
	}
	if path != "/v1/responses" && path != "/v1/responses/compact" && path != "/v1/chat/completions" &&
		path != "/v1/messages" && path != "/v1/messages/count_tokens" && !strings.HasPrefix(path, "/v1beta/models/") {
		writeError(w, 404, "route_not_found")
		return
	}
	select {
	case g.slots <- struct{}{}:
		defer func() { <-g.slots }()
	default:
		writeError(w, 503, "gateway_busy")
		return
	}
	body, err := readBounded(r.Body, 16<<20)
	if err != nil {
		writeError(w, 413, "request_too_large")
		return
	}
	var object map[string]json.RawMessage
	if json.Unmarshal(body, &object) != nil || object == nil {
		writeError(w, 400, "invalid_json")
		return
	}
	model, action, stream, format := "", "generateContent", false, translator.FormatOpenAIResponse
	if strings.HasPrefix(path, "/v1beta/models/") {
		format = translator.FormatGemini
		parts := strings.Split(strings.TrimPrefix(path, "/v1beta/models/"), ":")
		if len(parts) != 2 {
			writeError(w, 404, "route_not_found")
			return
		}
		model, action = parts[0], parts[1]
		if action != "generateContent" && action != "streamGenerateContent" && action != "countTokens" {
			writeError(w, 404, "route_not_found")
			return
		}
		stream = action == "streamGenerateContent"
	} else {
		_ = json.Unmarshal(object["model"], &model)
		_ = json.Unmarshal(object["stream"], &stream)
		if path == "/v1/chat/completions" {
			format = translator.FormatOpenAI
		}
		if path == "/v1/messages" || path == "/v1/messages/count_tokens" {
			format = translator.FormatClaude
		}
		if path == "/v1/messages/count_tokens" {
			action = "countTokens"
			stream = false
		}
		var background bool
		var previous string
		_ = json.Unmarshal(object["background"], &background)
		_ = json.Unmarshal(object["previous_response_id"], &previous)
		if format == translator.FormatOpenAIResponse && (background || previous != "") {
			writeError(w, 400, "stateless_responses_required")
			return
		}
	}
	if !modelPattern.MatchString(model) {
		writeError(w, 400, "invalid_model")
		return
	}
	headers := http.Header{}
	for _, name := range []string{"Anthropic-Version", "Anthropic-Beta"} {
		if value := r.Header.Get(name); len(value) > 0 && len(value) <= 2048 {
			headers.Set(name, value)
		}
	}
	options := executor.Options{Stream: stream, SourceFormat: format, ResponseFormat: format,
		OriginalRequest: body, Headers: headers, Metadata: map[string]any{executor.RequestPathMetadataKey: path}}
	if path == "/v1/responses/compact" {
		options.Alt = "responses/compact"
	}
	request := executor.Request{Model: model, Payload: body, Format: format}
	tried := map[string]bool{}
	for len(tried) < 100 {
		l, err := g.pool.acquireProvider(r.Context(), provider, model, tried)
		if err != nil {
			if err.Error() == "model_unavailable" {
				writeError(w, 404, "model_unavailable")
			} else {
				writeError(w, 503, "pool_busy_or_cooling")
			}
			return
		}
		tried[l.entry.view.ID] = true
		c, err := g.pool.prepare(l.ctx, l.entry, g.backend, g.persist)
		if err != nil {
			l.finish(err)
			if retryable(err) {
				continue
			}
			writeError(w, 502, "credential_unavailable")
			return
		}
		if !stream {
			var response executor.Response
			if action == "countTokens" {
				response, err = g.backend.count(l.ctx, c, request, options)
			} else {
				response, err = g.backend.execute(l.ctx, c, request, options)
			}
			l.finish(err)
			if err != nil {
				if retryable(err) {
					continue
				}
				writeError(w, safeStatus(err), "upstream_request_failed")
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(response.Payload)
			return
		}
		result, err := g.backend.stream(l.ctx, c, request, options)
		if err != nil {
			l.finish(err)
			if retryable(err) {
				continue
			}
			writeError(w, safeStatus(err), "upstream_request_failed")
			return
		}
		if result == nil || result.Chunks == nil {
			l.finish(upstreamError{status: 502})
			writeError(w, 502, "upstream_empty_stream")
			return
		}
		// Inspect the first meaningful chunk before committing a response. After
		// output starts, an error terminates this stream without another account.
		first, ok := firstStreamChunk(l.ctx, result.Chunks)
		if !ok {
			l.finish(upstreamError{status: 502})
			writeError(w, 502, "upstream_empty_stream")
			return
		}
		if first.Err != nil {
			l.finish(first.Err)
			if retryable(first.Err) {
				continue
			}
			writeError(w, safeStatus(first.Err), "upstream_request_failed")
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Connection", "keep-alive")
		controller := http.NewResponseController(w)
		writeChunk := func(payload []byte) error {
			if len(payload) == 0 {
				return nil
			}
			_ = controller.SetWriteDeadline(time.Now().Add(30 * time.Second))
			trimmed := bytes.TrimSpace(payload)
			// Native Responses executors may emit the blank SSE event delimiter
			// as its own chunk. Preserve it rather than inventing an empty data event.
			if len(trimmed) == 0 || bytes.HasPrefix(trimmed, []byte("event:")) || bytes.HasPrefix(trimmed, []byte("data:")) {
				_, err = w.Write(payload)
			} else {
				_, err = fmt.Fprintf(w, "data: %s\n\n", trimmed)
			}
			if err == nil {
				err = controller.Flush()
			}
			return err
		}
		streamErr := writeChunk(first.Payload)
		for streamErr == nil {
			select {
			case <-l.ctx.Done():
				streamErr = l.ctx.Err()
			case chunk, ok := <-result.Chunks:
				if !ok {
					l.finish(nil)
					return
				}
				if chunk.Err != nil {
					streamErr = chunk.Err
					_, _ = io.WriteString(w, "event: error\ndata: {\"error\":{\"code\":\"upstream_stream_failed\"}}\n\n")
					_ = controller.Flush()
				} else {
					streamErr = writeChunk(chunk.Payload)
				}
			}
		}
		l.finish(streamErr)
		return
	}
	writeError(w, 503, "pool_exhausted")
}

// The unprefixed compatibility endpoints always belong to Antigravity.
// A model name can never redirect a request to a different provider's pool.
func providerRoute(path string) (provider, route string, ok bool) {
	if !strings.HasPrefix(path, "/providers/") {
		return "antigravity", path, true
	}
	parts := strings.SplitN(strings.TrimPrefix(path, "/providers/"), "/", 2)
	if len(parts) != 2 {
		return "", "", false
	}
	switch parts[0] {
	case "antigravity", "claude", "kimi", "xai":
	default:
		return "", "", false
	}
	return parts[0], "/" + parts[1], true
}

func firstStreamChunk(ctx context.Context, chunks <-chan executor.StreamChunk) (executor.StreamChunk, bool) {
	for {
		select {
		case <-ctx.Done():
			return executor.StreamChunk{Err: ctx.Err()}, true
		case chunk, ok := <-chunks:
			if !ok {
				return executor.StreamChunk{}, false
			}
			if chunk.Err != nil || len(chunk.Payload) > 0 {
				return chunk, true
			}
		}
	}
}

func retryable(err error) bool {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return false
	}
	switch statusCode(err) {
	case 401, 403, 429:
		return true
	default:
		return false
	}
}
func safeStatus(err error) int {
	status := statusCode(err)
	if status < 400 || status > 599 {
		return 502
	}
	return status
}

func startGateway(ctx context.Context, port int, g *gateway) (*http.Server, int, error) {
	l, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return nil, 0, errors.New("listen_failed")
	}
	g.host = l.Addr().String()
	g.slots = make(chan struct{}, 32)
	server := &http.Server{Handler: g, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second,
		IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10, BaseContext: func(net.Listener) context.Context { return ctx }}
	go func() { _ = server.Serve(l) }()
	return server, l.Addr().(*net.TCPAddr).Port, nil
}
