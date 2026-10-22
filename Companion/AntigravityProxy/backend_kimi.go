package main

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
	kimi "github.com/router-for-me/CLIProxyAPI/v8/internal/auth/kimi"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/config"
	provider "github.com/router-for-me/CLIProxyAPI/v8/internal/runtime/executor"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

// Pinned public Kimi Code OAuth client, from CPA v8.0.38 internal/auth/kimi.
const kimiOAuthClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
const kimiDeviceEndpoint = kimi.KimiOAuthHost + "/api/oauth/device_authorization"
const kimiTokenEndpoint = kimi.KimiOAuthHost + "/api/oauth/token"

func init() { registerBackend("kimi", newKimiBackend) }

type kimiBackend struct {
	*oauthExecutorBackend
	wait func(context.Context, time.Duration) error
}

func newKimiBackend(proxy string) authBackend {
	return &kimiBackend{&oauthExecutorBackend{provider: "kimi", http: newOAuthHTTP(proxy, "auth.kimi.com", "api.kimi.com"), executor: provider.NewKimiExecutor(&config.Config{}), authRecord: kimiAuthRecord}, waitOAuthPoll}
}
func kimiAuthRecord(c credential) *auth.Auth {
	a := oauthAuthRecord(c)
	a.Metadata["device_id"] = c.DeviceID
	a.Metadata["base_url"] = kimi.KimiAPIBaseURL
	a.Metadata["domain"] = "kimi.com"
	return a
}
func kimiHeaders(deviceID string) http.Header {
	return http.Header{"X-Msh-Platform": {"CLIProxyAPI"}, "X-Msh-Version": {"v8.0.38"}, "X-Msh-Device-Name": {"AiGoodBro"}, "X-Msh-Device-Model": {"macOS"}, "X-Msh-Device-Id": {deviceID}, "User-Agent": {"AiGoodBro/1022v1"}}
}

func (b *kimiBackend) signIn(ctx context.Context, open func(authPrompt) error) (credential, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	deviceID := uuid.NewString()
	headers := kimiHeaders(deviceID)
	headers.Set("Content-Type", "application/x-www-form-urlencoded")
	var d deviceAuthorization
	if _, err := b.http.json(ctx, http.MethodPost, kimiDeviceEndpoint, headers, strings.NewReader(url.Values{"client_id": {kimiOAuthClientID}}.Encode()), &d); err != nil {
		return credential{}, err
	}
	prompt, err := devicePrompt(d, map[string]bool{"www.kimi.com": true, "kimi.com": true}, "/code/authorize_device")
	if err != nil {
		return credential{}, err
	}
	if err = open(prompt); err != nil {
		return credential{}, errors.New("oauth_browser_unavailable")
	}
	token, err := b.http.pollDevice(ctx, d, kimiTokenEndpoint, kimiOAuthClientID, headers, b.wait)
	if err != nil {
		return credential{}, err
	}
	subject, email := oauthTokenClaims(token.AccessToken)
	if subject == "" {
		subject, email = oauthTokenClaims(token.RefreshToken)
	}
	if subject == "" || token.RefreshToken == "" {
		return credential{}, errors.New("oauth_identity_failed")
	}
	c := credential{Provider: "kimi", AccountID: providerAccountID("kimi", subject), Generation: randomID(), MaskedIdentity: maskedOAuthIdentity("Kimi", subject, email), AccessToken: token.AccessToken, RefreshToken: token.RefreshToken,
		ExpiresAt: time.Now().Add(time.Duration(token.ExpiresIn) * time.Second).Unix(), AccountSubject: subject, DeviceID: deviceID}
	return c, c.validate()
}

func (b *kimiBackend) refresh(ctx context.Context, c credential) (credential, error) {
	if _, err := b.requestAuth(c); err != nil {
		return credential{}, err
	}
	token, status, err := b.http.deviceToken(ctx, kimiTokenEndpoint, kimiHeaders(c.DeviceID), url.Values{"client_id": {kimiOAuthClientID}, "grant_type": {"refresh_token"}, "refresh_token": {c.RefreshToken}})
	if err != nil {
		if status == 0 || status == 200 {
			return credential{}, upstreamError{status: 401}
		}
		return credential{}, err
	}
	if token.Error != "" {
		return credential{}, upstreamError{status: 401}
	}
	subject, _ := oauthTokenClaims(token.AccessToken)
	if subject != "" && subject != c.AccountSubject {
		return credential{}, upstreamError{status: 401}
	}
	c.AccessToken = token.AccessToken
	if token.RefreshToken != "" {
		c.RefreshToken = token.RefreshToken
	}
	c.ExpiresAt = time.Now().Add(time.Duration(token.ExpiresIn) * time.Second).Unix()
	return c, c.validate()
}

func (b *kimiBackend) models(ctx context.Context, c credential) ([]string, error) {
	return b.listModels(ctx, c, kimi.KimiAPIBaseURL+"/v1/models", kimiHeaders(c.DeviceID))
}
