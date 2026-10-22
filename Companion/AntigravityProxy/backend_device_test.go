package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
)

func syntheticJWT(claims map[string]string) string {
	b, _ := json.Marshal(claims)
	return "fixture." + base64.RawURLEncoding.EncodeToString(b) + ".fixture"
}
func fixtureDeviceCredential(provider string) credential {
	c := fixtureClaudeCredential()
	c.Provider = provider
	c.AccountID = providerAccountID(provider, c.AccountSubject)
	return c
}
func immediateOAuthWait(ctx context.Context, _ time.Duration) error { return ctx.Err() }

func TestDevicePromptRejectsForeignQueryAndSecretCode(t *testing.T) {
	d := deviceAuthorization{DeviceCode: "synthetic-secret-device-code", UserCode: "ABCD-1234", VerificationURIComplete: "https://www.kimi.com/code/authorize_device?user_code=ABCD-1234", ExpiresIn: 600}
	hosts := map[string]bool{"www.kimi.com": true}
	p, err := devicePrompt(d, hosts, "/code/authorize_device")
	if err != nil || p.UserCode != d.UserCode || strings.Contains(p.URL, d.DeviceCode) {
		t.Fatal("invalid safe prompt")
	}
	for _, raw := range []string{
		"https://www.kimi.com/other?user_code=ABCD-1234",
		"https://www.kimi.com/code/authorize_device?user_code=wrong",
		"https://www.kimi.com/code/authorize_device?user_code=ABCD-1234&redirect_uri=https://evil.test",
		"https://www.kimi.com/code/authorize_device?user_code=ABCD-1234&user_code=ABCD-1234",
		"https://www.kimi.com/code/authorize_device?device_code=synthetic-secret-device-code",
		"https://www.kimi.com:443/code/authorize_device?user_code=ABCD-1234",
		"https://www.kimi.com/code%2fauthorize_device?user_code=ABCD-1234",
		"https://evil.test/code/authorize_device?user_code=ABCD-1234",
	} {
		d.VerificationURIComplete = raw
		if _, err = devicePrompt(d, hosts, "/code/authorize_device"); err == nil {
			t.Fatal("untrusted verification URL accepted")
		}
	}
}

func TestKimiDeviceLoginPendingSlowDownAndStableIdentity(t *testing.T) {
	b := newKimiBackend("").(*kimiBackend)
	polls := 0
	var waits []time.Duration
	var deviceID string
	b.wait = func(ctx context.Context, d time.Duration) error { waits = append(waits, d); return ctx.Err() }
	access := syntheticJWT(map[string]string{"user_id": "fixture-account"})
	b.http = mockOAuthHTTP(func(r *http.Request) (*http.Response, error) {
		if deviceID == "" {
			deviceID = r.Header.Get("X-Msh-Device-Id")
		}
		if deviceID == "" || r.Header.Get("X-Msh-Device-Id") != deviceID {
			t.Fatal("device identity changed during login")
		}
		if r.URL.String() == kimiDeviceEndpoint {
			return adapterResponse(200, `{"device_code":"synthetic-secret-device-code","user_code":"ABCD-1234","verification_uri_complete":"https://www.kimi.com/code/authorize_device?user_code=ABCD-1234","expires_in":600,"interval":5}`), nil
		}
		if r.URL.String() != kimiTokenEndpoint {
			t.Fatal("unexpected Kimi endpoint")
		}
		_ = r.ParseForm()
		if r.PostForm.Get("device_code") != "synthetic-secret-device-code" || r.PostForm.Get("client_id") != kimiOAuthClientID {
			t.Fatal("device grant not bound")
		}
		polls++
		switch polls {
		case 1:
			return adapterResponse(200, `{"error":"authorization_pending"}`), nil
		case 2:
			return adapterResponse(400, `{"error":"slow_down"}`), nil
		}
		body, _ := json.Marshal(map[string]any{"access_token": access, "refresh_token": "synthetic-refresh", "expires_in": 3600})
		return adapterResponse(200, string(body)), nil
	})
	opened := 0
	c, err := b.signIn(context.Background(), func(p authPrompt) error {
		opened++
		if p.UserCode != "ABCD-1234" || strings.Contains(p.URL, "synthetic-secret") {
			t.Fatal("secret in prompt")
		}
		return nil
	})
	if err != nil || c.Provider != "kimi" || c.AccountID != providerAccountID("kimi", "fixture-account") || c.DeviceID != deviceID || !strings.Contains(c.MaskedIdentity, "***") || opened != 1 {
		t.Fatalf("Kimi login failed: %v", err)
	}
	if len(waits) != 3 || waits[2] != 10*time.Second {
		t.Fatal("slow_down not honored")
	}
	if _, err := uuid.Parse(deviceID); err != nil {
		t.Fatal("Kimi device identity is not the upstream UUID shape")
	}
	a, err := b.requestAuth(c)
	if err != nil || a.Metadata["refresh_token"] != nil || a.Metadata["device_id"] != deviceID {
		t.Fatal("Kimi execution credential invalid")
	}
}

func TestDeviceFlowCancellationStopsPolling(t *testing.T) {
	b := newKimiBackend("").(*kimiBackend)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	b.http = mockOAuthHTTP(func(*http.Request) (*http.Response, error) {
		calls++
		return adapterResponse(200, `{"device_code":"fixture-secret","user_code":"ABCD-1234","verification_uri_complete":"https://www.kimi.com/code/authorize_device?user_code=ABCD-1234","expires_in":600,"interval":5}`), nil
	})
	_, err := b.signIn(ctx, func(authPrompt) error { cancel(); return nil })
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatal("canceled flow continued polling")
	}
}

func TestKimiRefreshRotationAndIdentityFence(t *testing.T) {
	b := newKimiBackend("").(*kimiBackend)
	c := fixtureDeviceCredential("kimi")
	for _, subject := range []string{"fixture-account", "other-account"} {
		b.http = mockOAuthHTTP(func(r *http.Request) (*http.Response, error) {
			_ = r.ParseForm()
			if r.PostForm.Get("refresh_token") != c.RefreshToken || r.PostForm.Get("grant_type") != "refresh_token" {
				t.Fatal("wrong refresh input")
			}
			body, _ := json.Marshal(map[string]any{"access_token": syntheticJWT(map[string]string{"user_id": subject}), "refresh_token": "synthetic-rotated", "expires_in": 3600})
			return adapterResponse(200, string(body)), nil
		})
		next, err := b.refresh(context.Background(), c)
		if subject == "other-account" {
			if statusCode(err) != 401 {
				t.Fatal("Kimi slot changed identity")
			}
			continue
		}
		if err != nil || next.RefreshToken != "synthetic-rotated" || next.Generation != c.Generation || c.RefreshToken == next.RefreshToken {
			t.Fatal("refresh rotation not immutable")
		}
	}
}

func TestXAIDeviceLoginUsesAuthoritativeIdentity(t *testing.T) {
	b := newXAIBackend("").(*xaiBackend)
	b.wait = immediateOAuthWait
	b.http = mockOAuthHTTP(func(r *http.Request) (*http.Response, error) {
		switch r.URL.String() {
		case xaiDeviceEndpoint:
			_ = r.ParseForm()
			if !strings.Contains(r.PostForm.Get("scope"), "grok-cli:access") {
				t.Fatal("missing xAI scope")
			}
			return adapterResponse(200, `{"device_code":"synthetic-secret","user_code":"ABCD-1234","verification_uri_complete":"https://accounts.x.ai/oauth2/device?user_code=ABCD-1234","expires_in":600,"interval":5}`), nil
		case xaiTokenEndpoint:
			body, _ := json.Marshal(map[string]any{"access_token": "synthetic-xai-access", "refresh_token": "synthetic-xai-refresh", "id_token": syntheticJWT(map[string]string{"sub": "fixture-account"}), "expires_in": 3600})
			return adapterResponse(200, string(body)), nil
		case xaiUserInfoEndpoint:
			if r.Header.Get("Authorization") != "Bearer synthetic-xai-access" {
				t.Fatal("identity probe missing token")
			}
			return adapterResponse(200, `{"sub":"fixture-account","email":"fixture@example.test"}`), nil
		default:
			t.Fatal("unfixed xAI endpoint")
			return nil, errors.New("unexpected_request")
		}
	})
	c, err := b.signIn(context.Background(), func(p authPrompt) error {
		u, _ := url.Parse(p.URL)
		if u.Path != "/oauth2/device" || p.UserCode != "ABCD-1234" {
			t.Fatal("wrong device prompt")
		}
		return nil
	})
	if err != nil || c.AccountID != providerAccountID("xai", "fixture-account") || c.AccountSubject != "fixture-account" {
		t.Fatalf("xAI identity failed: %v", err)
	}
	a, err := b.requestAuth(c)
	if err != nil || a.Metadata["using_api"] != false || a.Metadata["refresh_token"] != nil {
		t.Fatal("xAI OAuth executor gained billing/refresh authority")
	}
}

func TestXAIRefreshRotationAndWrongIdentityRejected(t *testing.T) {
	b := newXAIBackend("").(*xaiBackend)
	c := fixtureDeviceCredential("xai")
	for _, subject := range []string{"fixture-account", "other-account"} {
		b.http = mockOAuthHTTP(func(r *http.Request) (*http.Response, error) {
			if r.URL.String() == xaiTokenEndpoint {
				_ = r.ParseForm()
				if r.PostForm.Get("refresh_token") != c.RefreshToken {
					t.Fatal("wrong xAI refresh input")
				}
				return adapterResponse(200, `{"access_token":"synthetic-new-access","refresh_token":"synthetic-new-refresh","expires_in":3600}`), nil
			}
			if r.URL.String() != xaiUserInfoEndpoint {
				t.Fatal("unexpected refresh identity endpoint")
			}
			body, _ := json.Marshal(map[string]string{"sub": subject})
			return adapterResponse(200, string(body)), nil
		})
		next, err := b.refresh(context.Background(), c)
		if subject == "other-account" {
			if statusCode(err) != 401 {
				t.Fatal("xAI slot changed identity")
			}
			continue
		}
		if err != nil || next.RefreshToken != "synthetic-new-refresh" || next.Generation != c.Generation || c.AccessToken == next.AccessToken {
			t.Fatal("xAI rotation failed")
		}
	}
}

func TestKimiAndXAIModelCatalogsNeverUseStaticFallback(t *testing.T) {
	for _, id := range []string{"kimi", "xai"} {
		t.Run(id, func(t *testing.T) {
			var b authBackend
			var common *oauthExecutorBackend
			var expected string
			if id == "kimi" {
				v := newKimiBackend("").(*kimiBackend)
				b = v
				common = v.oauthExecutorBackend
				expected = "https://api.kimi.com/coding/v1/models"
			} else {
				v := newXAIBackend("").(*xaiBackend)
				b = v
				common = v.oauthExecutorBackend
				expected = "https://api.x.ai/v1/models"
			}
			c := fixtureDeviceCredential(id)
			common.http = mockOAuthHTTP(func(r *http.Request) (*http.Response, error) {
				if r.URL.String() != expected {
					t.Fatal("wrong models origin")
				}
				return adapterResponse(200, `{"data":[{"id":"fixture-model"}]}`), nil
			})
			models, err := b.models(context.Background(), c)
			if err != nil || len(models) != 1 || models[0] != "fixture-model" {
				t.Fatal("observed catalog not used")
			}
			common.http = mockOAuthHTTP(func(*http.Request) (*http.Response, error) { return adapterResponse(429, `synthetic denied`), nil })
			models, err = b.models(context.Background(), c)
			if statusCode(err) != 429 || len(models) != 0 {
				t.Fatal("unavailable provider gained static models")
			}
		})
	}
}

func TestXAIRejectsAPIBillingAndCompactRoutes(t *testing.T) {
	calls := 0
	tr := xaiSubscriptionTransport{base: adapterRoundTrip(func(*http.Request) (*http.Response, error) { calls++; return adapterResponse(200, `{}`), nil })}
	for _, raw := range []string{"https://api.x.ai/v1/responses", "https://api.x.ai/v1/responses/compact", "https://cli-chat-proxy.grok.com/v1/responses/compact", "https://cli-chat-proxy.grok.com/v1/images/generations"} {
		r, _ := http.NewRequest("POST", raw, nil)
		if _, err := tr.RoundTrip(r); err == nil {
			t.Fatal("unverified subscription route accepted")
		}
	}
	for _, test := range []struct{ method, url string }{{"GET", "https://api.x.ai/v1/models"}, {"POST", "https://cli-chat-proxy.grok.com/v1/responses"}} {
		r, _ := http.NewRequest(test.method, test.url, nil)
		if _, err := tr.RoundTrip(r); err != nil {
			t.Fatal("verified route rejected")
		}
	}
	if calls != 2 {
		t.Fatal("blocked route reached transport")
	}
	b := newXAIBackend("").(*xaiBackend)
	c := fixtureDeviceCredential("xai")
	opts := executor.Options{Alt: "responses/compact"}
	if _, err := b.execute(context.Background(), c, executor.Request{}, opts); statusCode(err) != 400 {
		t.Fatal("compact was not explicitly rejected")
	}
	if _, err := b.stream(context.Background(), c, executor.Request{}, opts); statusCode(err) != 400 {
		t.Fatal("streaming compact was not explicitly rejected")
	}
}
