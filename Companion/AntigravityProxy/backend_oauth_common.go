package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
)

// Provider adapters own a closed set of HTTPS origins. This transport is also
// injected into the SDK executors, including their internally-created clients.
// A redirect is rejected even when its destination is on the same origin.
type oauthOriginTransport struct {
	base  http.RoundTripper
	hosts map[string]bool
}

func (t oauthOriginTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r == nil || r.URL == nil || r.URL.Scheme != "https" || r.URL.User != nil ||
		!t.hosts[r.URL.Hostname()] || (r.URL.Port() != "" && r.URL.Port() != "443") || r.Response != nil {
		return nil, errors.New("upstream_host_rejected")
	}
	return t.base.RoundTrip(r)
}

type oauthHTTP struct {
	client    *http.Client
	transport http.RoundTripper
}

func newOAuthHTTP(proxy string, hosts ...string) *oauthHTTP {
	t := &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		TLSHandshakeTimeout: 15 * time.Second, ResponseHeaderTimeout: 60 * time.Second, IdleConnTimeout: 30 * time.Second}
	if proxy != "" {
		u, _ := url.Parse(proxy)
		t.Proxy = http.ProxyURL(u)
	}
	allowed := make(map[string]bool, len(hosts))
	for _, h := range hosts {
		allowed[h] = true
	}
	transport := oauthOriginTransport{base: t, hosts: allowed}
	return &oauthHTTP{transport: transport, client: &http.Client{Transport: transport, Timeout: 30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

// Response bodies and network errors never become IPC error messages.
func (h *oauthHTTP) json(ctx context.Context, method, endpoint string, headers http.Header, body io.Reader, result any) (int, error) {
	r, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return 0, errors.New("oauth_request_failed")
	}
	r.Header = headers.Clone()
	if r.Header == nil {
		r.Header = make(http.Header)
	}
	r.Header.Set("Accept", "application/json")
	resp, err := h.client.Do(r)
	if err != nil {
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		return 0, errors.New("oauth_transport_failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		delay := time.Duration(0)
		if seconds, e := strconv.Atoi(resp.Header.Get("Retry-After")); e == nil && seconds > 0 && seconds <= 86400 {
			delay = time.Duration(seconds) * time.Second
		}
		return resp.StatusCode, upstreamError{status: resp.StatusCode, delay: delay}
	}
	data, err := readBounded(resp.Body, 4<<20)
	if err != nil || json.Unmarshal(data, result) != nil {
		return resp.StatusCode, errors.New("invalid_upstream_response")
	}
	return resp.StatusCode, nil
}

func providerAccountID(provider, subject string) string {
	digest := sha256.Sum256([]byte(provider + "\x00" + subject))
	return provider + "-" + hex.EncodeToString(digest[:16])
}

func maskedOAuthIdentity(provider, subject, email string) string {
	parts := strings.SplitN(strings.TrimSpace(email), "@", 2)
	if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
		return string([]rune(parts[0])[0]) + "***@" + string([]rune(parts[1])[0]) + "***"
	}
	digest := sha256.Sum256([]byte(subject))
	return provider + " *** " + hex.EncodeToString(digest[:4])
}

type oauthExecutorBackend struct {
	provider   string
	http       *oauthHTTP
	executor   auth.ProviderExecutor
	authRecord func(credential) *auth.Auth
}

func (b *oauthExecutorBackend) requestAuth(c credential) (*auth.Auth, error) {
	if c.Provider != b.provider || c.validate() != nil || c.AccountSubject == "" || c.AccountID != providerAccountID(c.Provider, c.AccountSubject) {
		return nil, errors.New("invalid_provider_credential")
	}
	return b.authRecord(c), nil
}

type deviceOAuthToken struct {
	AccessToken  string  `json:"access_token"`
	RefreshToken string  `json:"refresh_token"`
	IDToken      string  `json:"id_token"`
	ExpiresIn    float64 `json:"expires_in"`
	Error        string  `json:"error"`
}

type deviceAuthorization struct {
	DeviceCode              string `json:"device_code"`
	UserCode                string `json:"user_code"`
	VerificationURI         string `json:"verification_uri"`
	VerificationURIComplete string `json:"verification_uri_complete"`
	ExpiresIn               int64  `json:"expires_in"`
	Interval                int64  `json:"interval"`
}

var deviceUserCodePattern = regexp.MustCompile(`^[A-Za-z0-9-]{1,32}$`)

func devicePrompt(d deviceAuthorization, hosts map[string]bool, path string) (authPrompt, error) {
	if d.DeviceCode == "" || len(d.DeviceCode) > 16384 || !deviceUserCodePattern.MatchString(d.UserCode) || d.ExpiresIn <= 0 || d.ExpiresIn > 1800 {
		return authPrompt{}, errors.New("invalid_device_response")
	}
	raw := d.VerificationURIComplete
	if raw == "" {
		raw = d.VerificationURI
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || !hosts[u.Hostname()] || u.Port() != "" || u.User != nil || u.Path != path || u.RawPath != "" || u.Fragment != "" {
		return authPrompt{}, errors.New("oauth_verification_url_rejected")
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil || len(q) > 1 || len(q["user_code"]) > 1 || (len(q) == 1 && len(q["user_code"]) != 1) || (q.Get("user_code") != "" && q.Get("user_code") != d.UserCode) {
		return authPrompt{}, errors.New("oauth_verification_url_rejected")
	}
	q.Set("user_code", d.UserCode)
	u.RawQuery = q.Encode()
	return authPrompt{URL: u.String(), UserCode: d.UserCode}, nil
}

func waitOAuthPoll(ctx context.Context, delay time.Duration) error {
	t := time.NewTimer(delay)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// Device grant polling must inspect RFC 8628 error codes in 400 as well as
// 200 responses. Neither the device_code nor arbitrary response text escapes.
func (h *oauthHTTP) deviceToken(ctx context.Context, endpoint string, headers http.Header, form url.Values) (deviceOAuthToken, int, error) {
	var token deviceOAuthToken
	r, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return token, 0, errors.New("oauth_request_failed")
	}
	r.Header = headers.Clone()
	if r.Header == nil {
		r.Header = make(http.Header)
	}
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.Header.Set("Accept", "application/json")
	resp, err := h.client.Do(r)
	if err != nil {
		if ctx.Err() != nil {
			return token, 0, ctx.Err()
		}
		return token, 0, errors.New("oauth_transport_failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 && resp.StatusCode != 400 {
		return token, resp.StatusCode, upstreamError{status: resp.StatusCode}
	}
	data, err := readBounded(resp.Body, 64<<10)
	if err != nil || json.Unmarshal(data, &token) != nil {
		return token, resp.StatusCode, errors.New("invalid_token_response")
	}
	if token.Error != "" {
		switch token.Error {
		case "authorization_pending", "slow_down":
			return token, resp.StatusCode, nil
		case "invalid_grant", "invalid_token", "expired_token", "access_denied":
			return token, resp.StatusCode, upstreamError{status: 401}
		default:
			return token, resp.StatusCode, errors.New("oauth_token_rejected")
		}
	}
	if resp.StatusCode != 200 || token.AccessToken == "" || len(token.AccessToken) > 16384 || len(token.RefreshToken) > 16384 || len(token.IDToken) > 16384 || token.ExpiresIn < 60 || token.ExpiresIn > 31*86400 {
		return token, resp.StatusCode, errors.New("invalid_token_response")
	}
	return token, resp.StatusCode, nil
}

func (h *oauthHTTP) pollDevice(ctx context.Context, d deviceAuthorization, endpoint, clientID string, headers http.Header, wait func(context.Context, time.Duration) error) (deviceOAuthToken, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Duration(d.ExpiresIn)*time.Second)
	defer cancel()
	interval := time.Duration(d.Interval) * time.Second
	if interval < 5*time.Second {
		interval = 5 * time.Second
	}
	if interval > 60*time.Second {
		interval = 60 * time.Second
	}
	for {
		if err := wait(ctx, interval); err != nil {
			return deviceOAuthToken{}, err
		}
		if ctx.Err() != nil {
			return deviceOAuthToken{}, ctx.Err()
		}
		token, _, err := h.deviceToken(ctx, endpoint, headers, url.Values{"client_id": {clientID}, "device_code": {d.DeviceCode}, "grant_type": {"urn:ietf:params:oauth:grant-type:device_code"}})
		if err != nil {
			return deviceOAuthToken{}, err
		}
		if token.Error == "slow_down" {
			interval += 5 * time.Second
			if interval > 60*time.Second {
				interval = 60 * time.Second
			}
			continue
		}
		if token.Error == "authorization_pending" {
			continue
		}
		return token, nil
	}
}

// Only tokens freshly received from our fixed TLS token endpoint enter here;
// this is identity extraction, not JWT verification or an import interface.
func oauthTokenClaims(token string) (string, string) {
	if len(token) > 16384 {
		return "", ""
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", ""
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", ""
	}
	var claims struct {
		UserID  string `json:"user_id"`
		Subject string `json:"sub"`
		Email   string `json:"email"`
	}
	if json.Unmarshal(data, &claims) != nil {
		return "", ""
	}
	subject := claims.UserID
	if subject == "" {
		subject = claims.Subject
	}
	if len(subject) > 1024 || len(claims.Email) > 320 {
		return "", ""
	}
	return subject, claims.Email
}
func (b *oauthExecutorBackend) context(ctx context.Context) context.Context {
	return context.WithValue(ctx, "cliproxy.roundtripper", b.http.transport)
}
func (b *oauthExecutorBackend) execute(ctx context.Context, c credential, r executor.Request, o executor.Options) (executor.Response, error) {
	a, e := b.requestAuth(c)
	if e != nil {
		return executor.Response{}, e
	}
	return b.executor.Execute(b.context(ctx), a, r, o)
}
func (b *oauthExecutorBackend) stream(ctx context.Context, c credential, r executor.Request, o executor.Options) (*executor.StreamResult, error) {
	a, e := b.requestAuth(c)
	if e != nil {
		return nil, e
	}
	return b.executor.ExecuteStream(b.context(ctx), a, r, o)
}
func (b *oauthExecutorBackend) count(ctx context.Context, c credential, r executor.Request, o executor.Options) (executor.Response, error) {
	a, e := b.requestAuth(c)
	if e != nil {
		return executor.Response{}, e
	}
	return b.executor.CountTokens(b.context(ctx), a, r, o)
}

func oauthAuthRecord(c credential) *auth.Auth {
	// No refresh token or storage object is exposed to the executor. Refresh
	// activation remains fenced by the parent's durable Keychain acknowledgement.
	return &auth.Auth{ID: c.AccountID, Provider: c.Provider, Attributes: map[string]string{"auth_kind": "oauth"},
		Metadata: map[string]any{"type": c.Provider, "auth_kind": "oauth", "access_token": c.AccessToken, "expired": time.Unix(c.ExpiresAt, 0).UTC().Format(time.RFC3339)}}
}

func (b *oauthExecutorBackend) listModels(ctx context.Context, c credential, endpoint string, headers http.Header) ([]string, error) {
	if _, err := b.requestAuth(c); err != nil {
		return nil, err
	}
	headers = headers.Clone()
	headers.Set("Authorization", "Bearer "+c.AccessToken)
	seen := map[string]bool{}
	lastID := ""
	for page := 0; page < 10; page++ {
		u, err := url.Parse(endpoint)
		if err != nil {
			return nil, errors.New("invalid_catalog")
		}
		if lastID != "" {
			q := u.Query()
			q.Set("after_id", lastID)
			u.RawQuery = q.Encode()
		}
		var result struct {
			Data []struct {
				ID string `json:"id"`
			} `json:"data"`
			HasMore bool   `json:"has_more"`
			LastID  string `json:"last_id"`
		}
		if _, err = b.http.json(ctx, http.MethodGet, u.String(), headers, nil, &result); err != nil {
			return nil, err
		}
		if result.Data == nil || len(result.Data) > 2048 {
			return nil, errors.New("invalid_catalog")
		}
		for _, m := range result.Data {
			if modelPattern.MatchString(m.ID) {
				seen[m.ID] = true
			}
		}
		if len(seen) > 2048 {
			return nil, errors.New("invalid_catalog")
		}
		if !result.HasMore {
			models := make([]string, 0, len(seen))
			for id := range seen {
				models = append(models, id)
			}
			sort.Strings(models)
			return models, nil
		}
		if result.LastID == "" || result.LastID == lastID || len(result.LastID) > 256 {
			return nil, errors.New("invalid_catalog")
		}
		lastID = result.LastID
	}
	return nil, errors.New("catalog_page_limit")
}
