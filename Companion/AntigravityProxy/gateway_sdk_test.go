package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// These tests cross the real gateway, provider router, SDK executors and SDK
// translators. Only the final HTTP transport is replaced; it cannot dial.
func TestProviderGatewaysUseSDKResponsesOffline(t *testing.T) {
	for _, name := range []string{"claude", "kimi", "xai"} {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", name, stream), func(t *testing.T) {
				c := fixtureDeviceCredential(name)
				if name == "claude" {
					// The public token prefix selects the SDK's actual OAuth path.
					c.AccessToken = "sk-ant-oat01-synthetic-offline-fixture"
				}
				p := newPool([]savedAccount{{Credential: c, Enabled: true, ConcurrencyLimit: 1}})
				entry := p.entries[c.AccountID]
				entry.catalogAt = time.Now()
				entry.view.Models = []string{testModel}
				b := backendFactories[name]("")
				var common *oauthExecutorBackend
				switch typed := b.(type) {
				case *claudeBackend:
					common = typed.oauthExecutorBackend
				case *kimiBackend:
					common = typed.oauthExecutorBackend
				case *xaiBackend:
					common = typed.oauthExecutorBackend
				default:
					t.Fatal("missing provider adapter")
				}
				var calls atomic.Int32
				stub := adapterRoundTrip(func(r *http.Request) (*http.Response, error) {
					calls.Add(1)
					wantHost, wantPath := "api.anthropic.com", "/v1/messages"
					if name == "kimi" {
						wantHost, wantPath = "api.kimi.com", "/coding/v1/responses"
					} else if name == "xai" {
						wantHost, wantPath = "cli-chat-proxy.grok.com", "/v1/responses"
					}
					if r.Method != "POST" || r.URL.Scheme != "https" || r.URL.Host != wantHost || r.URL.Path != wantPath {
						t.Error("SDK selected an unexpected origin or path")
						return nil, errors.New("fixture_unexpected_origin")
					}
					if r.Header.Get("Authorization") != "Bearer "+c.AccessToken || strings.Contains(fmt.Sprint(r.Header), testKey) {
						t.Error("OAuth credential was not bound or local key escaped")
						return nil, errors.New("fixture_wrong_credential")
					}
					payload, err := io.ReadAll(r.Body)
					if err != nil || !bytes.Contains(payload, []byte("fixture request")) || bytes.Contains(payload, []byte(c.RefreshToken)) {
						t.Error("SDK request lost input or leaked refresh material")
						return nil, errors.New("fixture_invalid_request")
					}
					var object map[string]any
					if json.Unmarshal(payload, &object) != nil || object["model"] != testModel {
						t.Error("SDK request model binding failed")
						return nil, errors.New("fixture_invalid_model")
					}
					tool := upstreamFixtureToolName(object)
					if tool == "" {
						t.Error("SDK request lost function tool")
						return nil, errors.New("fixture_missing_tool")
					}
					var body string
					if name == "claude" {
						if object["stream"] != true || object["messages"] == nil {
							t.Error("Responses input was not translated into Claude messages")
							return nil, errors.New("fixture_invalid_claude_translation")
						}
						body = anthropicFixtureEvents(tool)
					} else if name == "xai" || stream {
						body = responsesFixtureEvents(tool)
					} else {
						body = string(fixtureJSON(responsesFixtureObject(tool)))
					}
					response := adapterResponse(200, body)
					if name != "kimi" || stream {
						response.Header.Set("Content-Type", "text/event-stream")
					}
					return response, nil
				})
				common.http.transport = offlineSDKTransport(t, common.http.transport, stub)
				common.http.client.Transport = common.http.transport
				g := testGateway(p, &backendRouter{providers: map[string]authBackend{name: b}})
				body := fmt.Sprintf(`{"model":%q,"input":"fixture request","stream":%t,"tools":[{"type":"function","name":"fixture_lookup","description":"Offline fixture","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}}]}`, testModel, stream)
				result := request(g, "/providers/"+name+"/v1/responses", body, map[string]string{"Authorization": "Bearer " + testKey})
				if result.Code != 200 || !strings.Contains(result.Body.String(), "fixture answer") || !strings.Contains(result.Body.String(), "fixture_lookup") || !strings.Contains(result.Body.String(), "function_call") {
					t.Fatalf("Responses text/tool round trip failed: status=%d, body=%s", result.Code, result.Body.String())
				}
				if strings.Contains(result.Body.String(), c.AccessToken) || strings.Contains(result.Body.String(), c.RefreshToken) || strings.Contains(result.Body.String(), testKey) {
					t.Fatal("credential escaped to client")
				}
				if stream {
					if result.Header().Get("Content-Type") != "text/event-stream" || !strings.Contains(result.Body.String(), "response.completed") {
						t.Fatal("Responses stream lacked terminal event")
					}
					for _, line := range strings.Split(result.Body.String(), "\n") {
						if strings.HasPrefix(line, "data:") {
							data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
							if data != "[DONE]" && !json.Valid([]byte(data)) {
								t.Fatalf("gateway damaged SSE JSON framing: %q", data)
							}
						}
					}
				} else {
					var response map[string]any
					if json.Unmarshal(result.Body.Bytes(), &response) != nil || response["object"] != "response" || response["output"] == nil {
						t.Fatal("nonstream Responses shape was not preserved")
					}
				}
				if calls.Load() != 1 {
					t.Fatal("unexpected auxiliary or fallback upstream request")
				}
				rows, _ := p.snapshotsForProvider(name)
				if rows[0].InFlight != 0 || rows[0].State != "ready" {
					t.Fatal("completed request did not release its account lease")
				}
			})
		}
	}
}

// Keep production origin/route guards in place; replace only the dial-capable
// transport at the bottom. An unexpected transport fails before any request.
func offlineSDKTransport(t *testing.T, current, stub http.RoundTripper) http.RoundTripper {
	t.Helper()
	switch transport := current.(type) {
	case oauthOriginTransport:
		transport.base = offlineSDKTransport(t, transport.base, stub)
		return transport
	case xaiSubscriptionTransport:
		transport.base = offlineSDKTransport(t, transport.base, stub)
		return transport
	case *http.Transport:
		return stub
	default:
		t.Fatal("unrecognized SDK transport; offline boundary not established")
		return nil
	}
}

func upstreamFixtureToolName(object map[string]any) string {
	tools, _ := object["tools"].([]any)
	for _, value := range tools {
		tool, _ := value.(map[string]any)
		if name, _ := tool["name"].(string); name != "" {
			return name
		}
		if function, ok := tool["function"].(map[string]any); ok {
			if name, _ := function["name"].(string); name != "" {
				return name
			}
		}
	}
	return ""
}
func fixtureJSON(value any) []byte { data, _ := json.Marshal(value); return data }
func fixtureEvent(name string, value any) string {
	return "event: " + name + "\ndata: " + string(fixtureJSON(value)) + "\n\n"
}
func responsesFixtureObject(tool string) map[string]any {
	return map[string]any{"id": "resp_fixture", "object": "response", "created_at": 1700000000, "status": "completed", "model": testModel,
		"output": []any{
			map[string]any{"id": "msg_fixture", "type": "message", "role": "assistant", "status": "completed", "content": []any{map[string]any{"type": "output_text", "text": "fixture answer", "annotations": []any{}}}},
			map[string]any{"id": "fc_fixture", "type": "function_call", "call_id": "call_fixture", "status": "completed", "name": tool, "arguments": `{"query":"fixture"}`},
		}, "usage": map[string]any{"input_tokens": 2, "output_tokens": 3, "total_tokens": 5}}
}
func responsesFixtureEvents(tool string) string {
	response := responsesFixtureObject(tool)
	body := fixtureEvent("response.created", map[string]any{"type": "response.created", "response": map[string]any{"id": "resp_fixture", "object": "response", "status": "in_progress", "model": testModel, "output": []any{}}})
	body += fixtureEvent("response.output_text.delta", map[string]any{"type": "response.output_text.delta", "item_id": "msg_fixture", "output_index": 0, "content_index": 0, "delta": "fixture answer"})
	for index, item := range response["output"].([]any) {
		body += fixtureEvent("response.output_item.done", map[string]any{"type": "response.output_item.done", "output_index": index, "item": item})
	}
	return body + fixtureEvent("response.completed", map[string]any{"type": "response.completed", "response": response})
}
func anthropicFixtureEvents(tool string) string {
	body := fixtureEvent("message_start", map[string]any{"type": "message_start", "message": map[string]any{"id": "msg_fixture", "type": "message", "role": "assistant", "model": testModel, "content": []any{}, "stop_reason": nil, "usage": map[string]any{"input_tokens": 2, "output_tokens": 0}}})
	body += fixtureEvent("content_block_start", map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "text", "text": ""}})
	body += fixtureEvent("content_block_delta", map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "fixture answer"}})
	body += fixtureEvent("content_block_stop", map[string]any{"type": "content_block_stop", "index": 0})
	body += fixtureEvent("content_block_start", map[string]any{"type": "content_block_start", "index": 1, "content_block": map[string]any{"type": "tool_use", "id": "call_fixture", "name": tool, "input": map[string]any{}}})
	body += fixtureEvent("content_block_delta", map[string]any{"type": "content_block_delta", "index": 1, "delta": map[string]any{"type": "input_json_delta", "partial_json": `{"query":"fixture"}`}})
	body += fixtureEvent("content_block_stop", map[string]any{"type": "content_block_stop", "index": 1})
	body += fixtureEvent("message_delta", map[string]any{"type": "message_delta", "delta": map[string]any{"stop_reason": "tool_use", "stop_sequence": nil}, "usage": map[string]any{"output_tokens": 3}})
	return body + fixtureEvent("message_stop", map[string]any{"type": "message_stop"})
}
