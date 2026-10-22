package main

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

func TestXAIModelsPaginationThroughSubscriptionGuard(t *testing.T) {
	b := newXAIBackend("").(*xaiBackend)
	calls := 0
	transport := xaiSubscriptionTransport{base: adapterRoundTrip(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != "GET" || r.URL.Hostname() != "api.x.ai" || r.URL.Path != "/v1/models" {
			t.Fatal("unexpected catalog route")
		}
		if calls == 1 {
			if r.URL.RawQuery != "" {
				t.Fatal("first page has cursor")
			}
			return adapterResponse(200, `{"data":[{"id":"grok-one"}],"has_more":true,"last_id":"cursor+/="}`), nil
		}
		if calls != 2 || r.URL.Query().Get("after_id") != "cursor+/=" {
			t.Fatal("invalid second page cursor")
		}
		return adapterResponse(200, `{"data":[{"id":"grok-two"}],"has_more":false}`), nil
	})}
	b.http = mockOAuthHTTP(transport.RoundTrip)
	models, err := b.models(context.Background(), fixtureDeviceCredential("xai"))
	if err != nil || calls != 2 || strings.Join(models, ",") != "grok-one,grok-two" {
		t.Fatalf("catalog pagination: %v %v %d", models, err, calls)
	}
}

func TestXAIModelsGuardRejectsMalformedQueries(t *testing.T) {
	calls := 0
	tr := xaiSubscriptionTransport{base: adapterRoundTrip(func(*http.Request) (*http.Response, error) { calls++; return adapterResponse(200, `{}`), nil })}
	for _, query := range []string{"after_id=", "after_id=a&after_id=b", "other=a", "after_id=a&other=b", "after_id=%zz", "after_id=%00", "after_id=" + strings.Repeat("a", 257)} {
		r, _ := http.NewRequest("GET", "https://api.x.ai/v1/models?"+query, nil)
		if _, err := tr.RoundTrip(r); err == nil {
			t.Fatalf("accepted invalid query %q", query)
		}
	}
	for _, raw := range []string{"https://auth.x.ai/oauth2/userinfo?after_id=a", "https://cli-chat-proxy.grok.com/v1/responses?after_id=a"} {
		method := "GET"
		if strings.Contains(raw, "responses") {
			method = "POST"
		}
		r, _ := http.NewRequest(method, raw, nil)
		if _, err := tr.RoundTrip(r); err == nil {
			t.Fatal("cursor leaked to noncatalog endpoint")
		}
	}
	if calls != 0 {
		t.Fatal("invalid query reached transport")
	}
}

func TestGoogleAccountIdentitySurvivesEmailRename(t *testing.T) {
	first, err := parseGoogleIdentity([]byte(`{"id":"stable-123","email":"old@example.test","verified_email":true}`))
	if err != nil {
		t.Fatal(err)
	}
	renamed, err := parseGoogleIdentity([]byte(`{"sub":"stable-123","email":"new@example.test","verified_email":true}`))
	if err != nil || first.accountID() != renamed.accountID() || first.Email == renamed.Email {
		t.Fatal("email rename changed durable account slot")
	}
	other, err := parseGoogleIdentity([]byte(`{"id":"different-456","email":"old@example.test","verified_email":true}`))
	if err != nil || other.accountID() == first.accountID() {
		t.Fatal("different subjects shared slot")
	}
	for _, subjectFields := range []string{``, `"id":"",`, `"id":"one","sub":"two",`, `"id":" bad ",`, `"id":"bad\nvalue",`} {
		payload := fmt.Sprintf(`{%s"email":"old@example.test","verified_email":true}`, subjectFields)
		if _, err := parseGoogleIdentity([]byte(payload)); err == nil {
			t.Fatal("missing or invalid subject accepted")
		}
	}
}
