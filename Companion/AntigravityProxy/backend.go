package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	ag "github.com/router-for-me/CLIProxyAPI/v8/internal/auth/antigravity"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/config"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/misc"
	provider "github.com/router-for-me/CLIProxyAPI/v8/internal/runtime/executor"
	_ "github.com/router-for-me/CLIProxyAPI/v8/internal/translator"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
)

type backend interface {
	refresh(context.Context, credential) (credential, error)
	models(context.Context, credential) ([]string, error)
	execute(context.Context, credential, executor.Request, executor.Options) (executor.Response, error)
	stream(context.Context, credential, executor.Request, executor.Options) (*executor.StreamResult, error)
	count(context.Context, credential, executor.Request, executor.Options) (executor.Response, error)
}

type upstreamError struct {
	status int
	delay  time.Duration
}

func (e upstreamError) Error() string   { return "upstream_unavailable" }
func (e upstreamError) StatusCode() int { return e.status }
func (e upstreamError) RetryAfter() *time.Duration {
	if e.delay <= 0 {
		return nil
	}
	return &e.delay
}

func validateProxy(value string) error {
	if value == "" {
		return nil
	}
	u, err := url.Parse(value)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https" && u.Scheme != "socks5") ||
		u.Hostname() == "" || u.Port() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return errors.New("invalid_network_proxy")
	}
	return nil
}

// All credential-bearing traffic stays on the pinned Google endpoints. The
// parent may choose an outbound proxy; it cannot choose an OAuth/API server.
type googleTransport struct{ base http.RoundTripper }

func (t googleTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	allowed := map[string]bool{
		"oauth2.googleapis.com": true, "www.googleapis.com": true,
		"cloudcode-pa.googleapis.com": true, "daily-cloudcode-pa.googleapis.com": true,
		"daily-cloudcode-pa.sandbox.googleapis.com": true,
	}
	if r == nil || r.URL == nil || r.URL.Scheme != "https" || r.URL.User != nil || !allowed[r.URL.Hostname()] ||
		(r.URL.Port() != "" && r.URL.Port() != "443") || r.Response != nil {
		return nil, errors.New("upstream_host_rejected")
	}
	return t.base.RoundTrip(r)
}

type sdkBackend struct {
	client    *http.Client
	transport http.RoundTripper
	executor  *provider.AntigravityExecutor
}

func newBackend(proxy string) *sdkBackend {
	t := &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		TLSHandshakeTimeout: 15 * time.Second, ResponseHeaderTimeout: 60 * time.Second, IdleConnTimeout: 30 * time.Second}
	if proxy != "" {
		u, _ := url.Parse(proxy)
		t.Proxy = http.ProxyURL(u)
	}
	transport := googleTransport{base: t}
	return &sdkBackend{
		transport: transport,
		client:    &http.Client{Transport: transport, Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
		executor:  provider.NewAntigravityExecutor(&config.Config{}),
	}
}

func (b *sdkBackend) context(ctx context.Context) context.Context {
	return context.WithValue(ctx, "cliproxy.roundtripper", b.transport)
}

func providerAuth(c credential) *auth.Auth {
	// Refresh is owned by our generation-fenced Keychain transaction. The
	// executor receives no refresh token and cannot silently persist elsewhere.
	return &auth.Auth{ID: c.AccountID, Provider: "antigravity", Metadata: map[string]any{
		"access_token": c.AccessToken, "project_id": c.ProjectID,
		"expired": time.Unix(c.ExpiresAt, 0).UTC().Format(time.RFC3339), "type": "antigravity",
	}}
}

func (b *sdkBackend) execute(ctx context.Context, c credential, r executor.Request, o executor.Options) (executor.Response, error) {
	return b.executor.Execute(b.context(ctx), providerAuth(c), r, o)
}
func (b *sdkBackend) stream(ctx context.Context, c credential, r executor.Request, o executor.Options) (*executor.StreamResult, error) {
	return b.executor.ExecuteStream(b.context(ctx), providerAuth(c), r, o)
}
func (b *sdkBackend) count(ctx context.Context, c credential, r executor.Request, o executor.Options) (executor.Response, error) {
	return b.executor.CountTokens(b.context(ctx), providerAuth(c), r, o)
}

func (b *sdkBackend) refresh(ctx context.Context, c credential) (credential, error) {
	form := url.Values{"client_id": {ag.ClientID}, "client_secret": {ag.ClientSecret},
		"grant_type": {"refresh_token"}, "refresh_token": {c.RefreshToken}}
	token, err := exchangeToken(ctx, b.client, form)
	if err != nil {
		return credential{}, err
	}
	c.AccessToken = token.AccessToken
	if token.RefreshToken != "" {
		c.RefreshToken = token.RefreshToken
	}
	c.ExpiresAt = time.Now().Add(time.Duration(token.ExpiresIn) * time.Second).Unix()
	return c, nil
}

func exchangeToken(ctx context.Context, client *http.Client, form url.Values) (ag.TokenResponse, error) {
	var token ag.TokenResponse
	r, err := http.NewRequestWithContext(ctx, http.MethodPost, ag.TokenEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return token, errors.New("token_exchange_failed")
	}
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := client.Do(r)
	if err != nil {
		return token, errors.New("token_exchange_failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return token, upstreamError{status: resp.StatusCode}
	}
	data, err := readBounded(resp.Body, 64<<10)
	if err != nil || json.Unmarshal(data, &token) != nil || token.AccessToken == "" ||
		token.ExpiresIn < 600 || token.ExpiresIn > 86400 {
		return ag.TokenResponse{}, errors.New("invalid_token_response")
	}
	return token, nil
}

func readBounded(r io.Reader, maximum int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, maximum+1))
	if err != nil || int64(len(b)) > maximum {
		return nil, errors.New("response_too_large")
	}
	return b, nil
}

func (b *sdkBackend) models(ctx context.Context, c credential) ([]string, error) {
	body, _ := json.Marshal(map[string]string{"project": c.ProjectID})
	r, err := http.NewRequestWithContext(ctx, http.MethodPost, ag.DailyAPIEndpoint+"/v1internal:fetchAvailableModels", bytes.NewReader(body))
	if err != nil {
		return nil, errors.New("catalog_failed")
	}
	r.Header.Set("Authorization", "Bearer "+c.AccessToken)
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("User-Agent", misc.AntigravityUserAgent())
	resp, err := b.client.Do(r)
	if err != nil {
		return nil, errors.New("catalog_failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, upstreamError{status: resp.StatusCode}
	}
	data, err := readBounded(resp.Body, 4<<20)
	if err != nil {
		return nil, err
	}
	return availableAntigravityModels(data, time.Now())
}

func availableAntigravityModels(data []byte, now time.Time) ([]string, error) {
	var result struct {
		Models map[string]json.RawMessage `json:"models"`
	}
	if json.Unmarshal(data, &result) != nil || result.Models == nil || len(result.Models) > 512 {
		return nil, errors.New("invalid_catalog")
	}
	models := make([]string, 0, len(result.Models))
	for id, raw := range result.Models {
		if !modelPattern.MatchString(id) {
			continue
		}
		var detail struct {
			QuotaInfo *struct {
				RemainingFraction *float64 `json:"remainingFraction"`
				ResetTime         string   `json:"resetTime"`
			} `json:"quotaInfo"`
		}
		if json.Unmarshal(raw, &detail) != nil {
			continue
		}
		if detail.QuotaInfo != nil {
			quota := detail.QuotaInfo
			if quota.RemainingFraction != nil && (*quota.RemainingFraction <= 0 || *quota.RemainingFraction > 1) {
				continue
			}
			if quota.ResetTime != "" {
				reset, err := time.Parse(time.RFC3339, quota.ResetTime)
				if err != nil || !reset.After(now) {
					continue
				}
			}
		}
		// Absence of quotaInfo is unknown quota, not an invented balance. It
		// remains an upstream-advertised model; actual 429s close admission.
		models = append(models, id)
	}
	sort.Strings(models)
	return models, nil
}
