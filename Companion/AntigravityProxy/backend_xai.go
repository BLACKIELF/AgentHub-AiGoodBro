package main

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	xai "github.com/router-for-me/CLIProxyAPI/v8/internal/auth/xai"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/config"
	provider "github.com/router-for-me/CLIProxyAPI/v8/internal/runtime/executor"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
)

// Exact endpoints verified against the public OIDC document on 2026-10-22.
// They are not configurable by credentials, IPC, environment or a client.
const xaiDeviceEndpoint = "https://auth.x.ai/oauth2/device/code"
const xaiTokenEndpoint = "https://auth.x.ai/oauth2/token"
const xaiUserInfoEndpoint = "https://auth.x.ai/oauth2/userinfo"

func init() { registerBackend("xai", newXAIBackend) }

type xaiBackend struct {
	*oauthExecutorBackend
	wait func(context.Context, time.Duration) error
}

func newXAIBackend(proxy string) authBackend {
	h := newOAuthHTTP(proxy, "auth.x.ai", "api.x.ai", "cli-chat-proxy.grok.com")
	h.transport = xaiSubscriptionTransport{base: h.transport}
	h.client.Transport = h.transport
	return &xaiBackend{&oauthExecutorBackend{provider: "xai", http: h, executor: provider.NewXAIExecutor(&config.Config{}), authRecord: xaiAuthRecord}, waitOAuthPoll}
}

type xaiSubscriptionTransport struct{ base http.RoundTripper }

func (t xaiSubscriptionTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	allowed := false
	if r != nil && r.URL != nil && r.URL.RawQuery == "" {
		switch r.URL.Hostname() {
		case "auth.x.ai":
			allowed = (r.Method == http.MethodPost && (r.URL.Path == "/oauth2/device/code" || r.URL.Path == "/oauth2/token")) || (r.Method == http.MethodGet && r.URL.Path == "/oauth2/userinfo")
		case "api.x.ai":
			allowed = r.Method == http.MethodGet && r.URL.Path == "/v1/models"
		case "cli-chat-proxy.grok.com":
			allowed = r.Method == http.MethodPost && r.URL.Path == "/v1/responses"
		}
	}
	if !allowed {
		return nil, errors.New("subscription_route_unavailable")
	}
	return t.base.RoundTrip(r)
}

func (b *xaiBackend) execute(ctx context.Context, c credential, r executor.Request, o executor.Options) (executor.Response, error) {
	if o.Alt == "responses/compact" {
		return executor.Response{}, upstreamError{status: 400}
	}
	return b.oauthExecutorBackend.execute(ctx, c, r, o)
}
func (b *xaiBackend) stream(ctx context.Context, c credential, r executor.Request, o executor.Options) (*executor.StreamResult, error) {
	if o.Alt == "responses/compact" {
		return nil, upstreamError{status: 400}
	}
	return b.oauthExecutorBackend.stream(ctx, c, r, o)
}
func xaiAuthRecord(c credential) *auth.Auth {
	a := oauthAuthRecord(c)
	a.Metadata["id_token"] = c.IDToken
	a.Metadata["sub"] = c.AccountSubject
	a.Metadata["base_url"] = xai.DefaultAPIBaseURL
	// Explicit subscription/OAuth route. No API-billing credential or fallback.
	a.Metadata["using_api"] = false
	return a
}

func (b *xaiBackend) signIn(ctx context.Context, open func(authPrompt) error) (credential, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	headers := http.Header{"Content-Type": {"application/x-www-form-urlencoded"}, "User-Agent": {"AiGoodBro/1022v1"}}
	var d deviceAuthorization
	if _, err := b.http.json(ctx, http.MethodPost, xaiDeviceEndpoint, headers, strings.NewReader(url.Values{"client_id": {xai.ClientID}, "scope": {xai.Scope}}.Encode()), &d); err != nil {
		return credential{}, err
	}
	prompt, err := devicePrompt(d, map[string]bool{"accounts.x.ai": true, "auth.x.ai": true}, "/oauth2/device")
	if err != nil {
		return credential{}, err
	}
	if err = open(prompt); err != nil {
		return credential{}, errors.New("oauth_browser_unavailable")
	}
	token, err := b.http.pollDevice(ctx, d, xaiTokenEndpoint, xai.ClientID, headers, b.wait)
	if err != nil {
		return credential{}, err
	}
	if token.RefreshToken == "" {
		return credential{}, errors.New("invalid_token_response")
	}
	subject, email, err := b.identity(ctx, token.AccessToken)
	if err != nil {
		return credential{}, err
	}
	if claimed, _ := oauthTokenClaims(token.IDToken); claimed != "" && claimed != subject {
		return credential{}, errors.New("oauth_identity_mismatch")
	}
	c := credential{Provider: "xai", AccountID: providerAccountID("xai", subject), Generation: randomID(), MaskedIdentity: maskedOAuthIdentity("Grok", subject, email), AccessToken: token.AccessToken, RefreshToken: token.RefreshToken, IDToken: token.IDToken,
		ExpiresAt: time.Now().Add(time.Duration(token.ExpiresIn) * time.Second).Unix(), AccountSubject: subject}
	return c, c.validate()
}

func (b *xaiBackend) identity(ctx context.Context, accessToken string) (string, string, error) {
	var info struct {
		Subject string `json:"sub"`
		Email   string `json:"email"`
	}
	if _, err := b.http.json(ctx, http.MethodGet, xaiUserInfoEndpoint, http.Header{"Authorization": {"Bearer " + accessToken}}, nil, &info); err != nil {
		return "", "", errors.New("oauth_identity_failed")
	}
	if strings.TrimSpace(info.Subject) == "" || len(info.Subject) > 1024 || len(info.Email) > 320 {
		return "", "", errors.New("oauth_identity_failed")
	}
	return info.Subject, info.Email, nil
}

func (b *xaiBackend) refresh(ctx context.Context, c credential) (credential, error) {
	if _, err := b.requestAuth(c); err != nil {
		return credential{}, err
	}
	token, status, err := b.http.deviceToken(ctx, xaiTokenEndpoint, http.Header{}, url.Values{"client_id": {xai.ClientID}, "grant_type": {"refresh_token"}, "refresh_token": {c.RefreshToken}})
	if err != nil {
		if status == 0 || status == 200 {
			return credential{}, upstreamError{status: 401}
		}
		return credential{}, err
	}
	if token.Error != "" {
		return credential{}, upstreamError{status: 401}
	}
	// The identity endpoint is authoritative; never rotate a slot into another
	// user just because a token endpoint returned a syntactically valid token.
	subject, _, err := b.identity(ctx, token.AccessToken)
	if err != nil || subject != c.AccountSubject {
		return credential{}, upstreamError{status: 401}
	}
	if claimed, _ := oauthTokenClaims(token.IDToken); claimed != "" && claimed != subject {
		return credential{}, upstreamError{status: 401}
	}
	c.AccessToken = token.AccessToken
	if token.RefreshToken != "" {
		c.RefreshToken = token.RefreshToken
	}
	if token.IDToken != "" {
		c.IDToken = token.IDToken
	}
	c.ExpiresAt = time.Now().Add(time.Duration(token.ExpiresIn) * time.Second).Unix()
	return c, c.validate()
}

func (b *xaiBackend) models(ctx context.Context, c credential) ([]string, error) {
	return b.listModels(ctx, c, xai.DefaultAPIBaseURL+"/models", http.Header{"User-Agent": {"AiGoodBro/1022v1"}})
}
