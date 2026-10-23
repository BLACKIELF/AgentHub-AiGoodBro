package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"

	claude "github.com/router-for-me/CLIProxyAPI/v8/internal/auth/claude"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/config"
	provider "github.com/router-for-me/CLIProxyAPI/v8/internal/runtime/executor"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

func init() { registerBackend("claude", newClaudeBackend) }

type claudeBackend struct{ *oauthExecutorBackend }

func newClaudeBackend(proxy string) authBackend {
	return &claudeBackend{&oauthExecutorBackend{provider: "claude", http: newOAuthHTTP(proxy, "platform.claude.com", "api.anthropic.com"),
		executor: provider.NewClaudeExecutor(&config.Config{}), authRecord: claudeAuthRecord}}
}

func claudeAuthRecord(c credential) *auth.Auth {
	a := oauthAuthRecord(c)
	a.Metadata["account_uuid"] = c.AccountSubject
	a.Metadata["organization_uuid"] = c.OrganizationID
	a.Metadata["claude_device_ids"] = []string{c.DeviceID}
	return a
}

func claudeAuthorizationURL(state, verifier string) string {
	hash := sha256.Sum256([]byte(verifier))
	q := url.Values{"code": {"true"}, "client_id": {claude.ClientID}, "response_type": {"code"}, "redirect_uri": {claude.RedirectURI},
		"scope": {claude.ClaudeOAuthScope}, "code_challenge": {base64.RawURLEncoding.EncodeToString(hash[:])}, "code_challenge_method": {"S256"}, "state": {state}}
	return claude.AuthURL + "?" + q.Encode()
}

func claudeCallbackHandler(state string, result chan<- oauthResult) http.Handler {
	var used atomic.Bool
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'none'")
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		remote, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || !net.ParseIP(remote).IsLoopback() || r.Host != "localhost:54545" || r.Method != http.MethodGet || r.URL.Path != "/callback" || len(r.URL.RawQuery) > 8192 {
			http.Error(w, "Invalid callback", 400)
			return
		}
		q, err := url.ParseQuery(r.URL.RawQuery)
		if err != nil || len(q["state"]) != 1 || subtle.ConstantTimeCompare([]byte(q.Get("state")), []byte(state)) != 1 ||
			len(q["code"]) > 1 || len(q["error"]) > 1 || (q.Get("error") == "" && (len(q["code"]) != 1 || q.Get("code") == "" || len(q.Get("code")) > 4096)) {
			http.Error(w, "Invalid callback", 400)
			return
		}
		if !used.CompareAndSwap(false, true) {
			http.Error(w, "Callback already received", 409)
			return
		}
		select {
		case result <- oauthResult{code: q.Get("code"), denied: q.Get("error") != ""}:
		default:
		}
		_, _ = w.Write([]byte("Authorization received. Return to AiGoodBro to see the result."))
	})
}

func (b *claudeBackend) signIn(ctx context.Context, open func(authPrompt) error) (credential, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	listener, err := net.Listen("tcp4", "127.0.0.1:54545")
	if err != nil {
		return credential{}, errors.New("oauth_listener_unavailable")
	}
	state, verifier := randomID(), randomID()
	result := make(chan oauthResult, 1)
	server := &http.Server{Handler: claudeCallbackHandler(state, result), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, MaxHeaderBytes: 8192}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	if err = open(authPrompt{URL: claudeAuthorizationURL(state, verifier)}); err != nil {
		return credential{}, errors.New("oauth_browser_unavailable")
	}
	var callback oauthResult
	select {
	case callback = <-result:
	case <-ctx.Done():
		return credential{}, ctx.Err()
	}
	_ = server.Close()
	if callback.denied {
		return credential{}, errors.New("oauth_denied")
	}
	return b.exchangeCode(ctx, callback.code, state, verifier)
}

type claudeOAuthToken struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"`
	Account      struct {
		UUID  string `json:"uuid"`
		Email string `json:"email_address"`
	} `json:"account"`
	Organization struct {
		UUID string `json:"uuid"`
	} `json:"organization"`
}

func claudeControlHeaders() http.Header {
	return http.Header{"Content-Type": {"application/json"}, "User-Agent": {"AiGoodBro/1022v1"}}
}

func (b *claudeBackend) exchangeCode(ctx context.Context, code, state, verifier string) (credential, error) {
	// The code fragment may carry state, but it may never replace the state
	// already checked at the callback boundary.
	if parts := strings.SplitN(code, "#", 2); len(parts) == 2 {
		if parts[1] != state {
			return credential{}, errors.New("oauth_state_mismatch")
		}
		code = parts[0]
	}
	// Keep the upstream's authorization-code wire field names and order.
	body, _ := json.Marshal(struct {
		GrantType    string `json:"grant_type"`
		Code         string `json:"code"`
		RedirectURI  string `json:"redirect_uri"`
		ClientID     string `json:"client_id"`
		CodeVerifier string `json:"code_verifier"`
		State        string `json:"state"`
	}{"authorization_code", code, claude.RedirectURI, claude.ClientID, verifier, state})
	var token claudeOAuthToken
	if _, err := b.http.json(ctx, http.MethodPost, claude.TokenURL, claudeControlHeaders(), bytes.NewReader(body), &token); err != nil {
		return credential{}, err
	}
	if token.AccessToken == "" || token.RefreshToken == "" || token.ExpiresIn < 60 || token.ExpiresIn > 31*86400 {
		return credential{}, errors.New("invalid_token_response")
	}
	subject, email, org := strings.TrimSpace(token.Account.UUID), strings.TrimSpace(token.Account.Email), strings.TrimSpace(token.Organization.UUID)
	// Token responses already come from the pinned TLS endpoint. A profile is
	// required only when they omit the stable account identity.
	if subject == "" {
		var profile claude.OAuthProfile
		headers := claudeControlHeaders()
		headers.Set("Authorization", "Bearer "+token.AccessToken)
		if _, err := b.http.json(ctx, http.MethodGet, claude.ProfileURL, headers, nil, &profile); err != nil {
			return credential{}, errors.New("oauth_identity_failed")
		}
		subject, email, org = profile.Account.UUID, profile.Account.Email, profile.Organization.UUID
	}
	if subject == "" || len(subject) > 1024 || len(email) > 320 {
		return credential{}, errors.New("oauth_identity_failed")
	}
	deviceIDs, err := claude.GenerateDeviceIDPool()
	if err != nil || len(deviceIDs) == 0 {
		return credential{}, errors.New("oauth_identity_failed")
	}
	c := credential{Provider: "claude", AccountID: providerAccountID("claude", subject), Generation: randomID(), MaskedIdentity: maskedOAuthIdentity("Claude", subject, email),
		AccessToken: token.AccessToken, RefreshToken: token.RefreshToken, ExpiresAt: time.Now().Add(time.Duration(token.ExpiresIn) * time.Second).Unix(),
		AccountSubject: subject, OrganizationID: org, DeviceID: deviceIDs[0]}
	return c, c.validate()
}

func (b *claudeBackend) refresh(ctx context.Context, c credential) (credential, error) {
	if _, err := b.requestAuth(c); err != nil {
		return credential{}, err
	}
	body, _ := json.Marshal(map[string]string{"client_id": claude.ClientID, "grant_type": "refresh_token", "refresh_token": c.RefreshToken, "scope": claude.ClaudeOAuthScope})
	var token claudeOAuthToken
	status, err := b.http.json(ctx, http.MethodPost, claude.RefreshTokenURL, claudeControlHeaders(), bytes.NewReader(body), &token)
	if err != nil {
		// A single-use refresh token may have been consumed when its response is
		// lost. Do not replay it on the next request. Explicit HTTP failures keep
		// their status/cooldown; ambiguous responses require reauthorization.
		if status == 0 || (status >= 200 && status < 300) {
			return credential{}, upstreamError{status: 401}
		}
		return credential{}, err
	}
	if token.AccessToken == "" || token.ExpiresIn < 60 || token.ExpiresIn > 31*86400 {
		return credential{}, upstreamError{status: 401}
	}
	if token.Account.UUID != "" && token.Account.UUID != c.AccountSubject {
		return credential{}, upstreamError{status: 401}
	}
	c.AccessToken = token.AccessToken
	if token.RefreshToken != "" {
		c.RefreshToken = token.RefreshToken
	}
	if token.Organization.UUID != "" {
		c.OrganizationID = token.Organization.UUID
	}
	c.ExpiresAt = time.Now().Add(time.Duration(token.ExpiresIn) * time.Second).Unix()
	return c, c.validate()
}

func (b *claudeBackend) models(ctx context.Context, c credential) ([]string, error) {
	return b.listModels(ctx, c, "https://api.anthropic.com/v1/models?limit=100", http.Header{"Anthropic-Version": {"2023-06-01"}, "Anthropic-Beta": {"oauth-2025-04-20"}})
}
