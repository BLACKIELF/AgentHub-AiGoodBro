package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"

	ag "github.com/router-for-me/CLIProxyAPI/v8/internal/auth/antigravity"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/config"
)

func authorizationURL(state, verifier, redirect string) string {
	u, _ := url.Parse(ag.NewAntigravityAuth(&config.Config{}, nil).BuildAuthURL(state, redirect))
	q := u.Query()
	challenge := sha256.Sum256([]byte(verifier))
	q.Set("code_challenge", base64.RawURLEncoding.EncodeToString(challenge[:]))
	q.Set("code_challenge_method", "S256")
	q.Set("prompt", "consent select_account")
	u.RawQuery = q.Encode()
	return u.String()
}

type oauthResult struct {
	code   string
	denied bool
}

func callbackHandler(state, host string, result chan<- oauthResult) http.Handler {
	var used atomic.Bool
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'none'")
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		remote, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || !net.ParseIP(remote).IsLoopback() || r.Host != host || r.Method != http.MethodGet ||
			r.URL.Path != "/oauth-callback" || len(r.URL.RawQuery) > 8192 {
			http.Error(w, "Invalid callback", 400)
			return
		}
		q := r.URL.Query()
		if len(q["state"]) != 1 || subtle.ConstantTimeCompare([]byte(q.Get("state")), []byte(state)) != 1 ||
			(len(q["code"]) != 1 && q.Get("error") == "") || len(q["code"]) > 1 || len(q["error"]) > 1 {
			http.Error(w, "Invalid callback", 400)
			return
		}
		if q.Get("error") == "" && (q.Get("code") == "" || len(q.Get("code")) > 4096) {
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

func (b *sdkBackend) signIn(ctx context.Context, open func(authPrompt) error) (credential, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return credential{}, errors.New("oauth_listener_unavailable")
	}
	state, verifier := randomID(), randomID()
	host := listener.Addr().String()
	redirect := "http://" + host + "/oauth-callback"
	result := make(chan oauthResult, 1)
	server := &http.Server{Handler: callbackHandler(state, host, result), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, MaxHeaderBytes: 8192}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()
	if err := open(authPrompt{URL: authorizationURL(state, verifier, redirect)}); err != nil {
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
	form := url.Values{"client_id": {ag.ClientID}, "client_secret": {ag.ClientSecret}, "code": {callback.code},
		"redirect_uri": {redirect}, "grant_type": {"authorization_code"}, "code_verifier": {verifier}}
	token, err := exchangeToken(ctx, b.client, form)
	if err != nil || token.RefreshToken == "" {
		return credential{}, errors.New("oauth_token_exchange_failed")
	}
	r, err := http.NewRequestWithContext(ctx, http.MethodGet, ag.UserInfoEndpoint, nil)
	if err != nil {
		return credential{}, errors.New("oauth_identity_failed")
	}
	r.Header.Set("Authorization", "Bearer "+token.AccessToken)
	resp, err := b.client.Do(r)
	if err != nil {
		return credential{}, errors.New("oauth_identity_failed")
	}
	defer resp.Body.Close()
	data, err := readBounded(resp.Body, 64<<10)
	if err != nil {
		return credential{}, errors.New("oauth_identity_failed")
	}
	identity, err := parseGoogleIdentity(data)
	if resp.StatusCode != 200 || err != nil {
		return credential{}, errors.New("oauth_identity_failed")
	}
	project, err := ag.NewAntigravityAuth(&config.Config{}, b.client).FetchProjectID(ctx, token.AccessToken)
	if err != nil || project == "" {
		return credential{}, errors.New("oauth_project_failed")
	}
	email := strings.ToLower(strings.TrimSpace(identity.Email))

	parts := strings.SplitN(email, "@", 2)
	if parts[0] == "" || parts[1] == "" {
		return credential{}, errors.New("oauth_identity_failed")
	}
	masked := fmt.Sprintf("%c***@%c***", []rune(parts[0])[0], []rune(parts[1])[0])
	c := credential{Provider: "antigravity", AccountID: identity.accountID(), Generation: randomID(), MaskedIdentity: masked,
		AccessToken: token.AccessToken, RefreshToken: token.RefreshToken, ProjectID: project, AccountSubject: identity.Subject,
		ExpiresAt: time.Now().Add(time.Duration(token.ExpiresIn) * time.Second).Unix()}
	return c, c.validate()
}

// Google userinfo v2 names the immutable subject "id"; OIDC uses "sub".
// Never fall back to the mutable primary email for the credential slot.
type googleIdentity struct{ Subject, Email string }

func parseGoogleIdentity(data []byte) (googleIdentity, error) {
	var user struct {
		ID       string `json:"id"`
		Subject  string `json:"sub"`
		Email    string `json:"email"`
		Verified bool   `json:"verified_email"`
	}
	if json.Unmarshal(data, &user) != nil || !user.Verified || len(user.Email) > 320 || !strings.Contains(user.Email, "@") {
		return googleIdentity{}, errors.New("oauth_identity_failed")
	}
	if user.ID != "" && user.Subject != "" && user.ID != user.Subject {
		return googleIdentity{}, errors.New("oauth_identity_failed")
	}
	subject := user.ID
	if subject == "" {
		subject = user.Subject
	}
	if subject == "" || len(subject) > 1024 || strings.TrimSpace(subject) != subject || strings.ContainsAny(subject, "\r\n\x00") {
		return googleIdentity{}, errors.New("oauth_identity_failed")
	}
	return googleIdentity{Subject: subject, Email: user.Email}, nil
}

func (i googleIdentity) accountID() string {
	digest := sha256.Sum256([]byte(i.Subject))
	return "ag-" + hex.EncodeToString(digest[:16])
}
