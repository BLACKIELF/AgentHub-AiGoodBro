package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/tidwall/gjson"
)

// Exercise the production gateway, provider backend, Claude SDK executor, and
// actual translators. The final upstream transport is fully synthetic/offline.
func TestClaudeTruncationThroughGateway(t *testing.T) {
	for _, format := range []string{"chat", "responses"} {
		for _, stream := range []bool{false, true} {
			for _, kind := range []string{"text", "tool", "tool_complete_json"} {
				for _, reason := range []string{"model_context_window_exceeded", "max_tokens"} {
					t.Run(fmt.Sprintf("%s/stream=%t/%s/%s", format, stream, kind, reason), func(t *testing.T) {
						body := claudeTruncationEvents(kind, reason)
						w, calls, p := syntheticClaudeGateway(t, format, stream, 200, body)
						if calls != 1 {
							t.Fatalf("upstream calls = %d, want 1", calls)
						}
						if w.Code != 200 {
							t.Fatalf("status = %d, want 200", w.Code)
						}
						rows, _ := p.snapshotsForProvider("claude")
						if len(rows) != 2 {
							t.Fatal("fixture lost its second eligible account")
						}
						for _, row := range rows {
							if row.InFlight != 0 || row.State != "ready" {
								t.Fatal("account lease or readiness changed")
							}
						}
						if format == "chat" {
							assertChatTruncation(t, w.Body.String(), stream, kind)
						} else {
							assertResponsesTruncation(t, w.Body.String(), stream, kind)
						}
					})
				}
			}
		}
	}
}

func TestClaudePromptOverflowRemainsError(t *testing.T) {
	for _, format := range []string{"chat", "responses"} {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", format, stream), func(t *testing.T) {
				w, calls, _ := syntheticClaudeGateway(t, format, stream, 400, `{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long"}}`)
				if w.Code != 400 || calls != 1 || !gjson.Get(w.Body.String(), "error.code").Exists() {
					t.Fatalf("prompt overflow status=%d calls=%d", w.Code, calls)
				}
			})
		}
	}
}

func syntheticClaudeGateway(t *testing.T, format string, stream bool, status int, body string) (*httptest.ResponseRecorder, int32, *pool) {
	return syntheticClaudeGatewayWithFault(t, format, stream, status, body, false)
}

func syntheticClaudeGatewayWithFault(t *testing.T, format string, stream bool, status int, body string, broken bool) (*httptest.ResponseRecorder, int32, *pool) {
	t.Helper()
	c := fixtureDeviceCredential("claude")
	c.AccessToken = "sk-ant-oat01-synthetic-offline-fixture"
	second := c
	second.AccountSubject = "fixture-second-account"
	second.AccountID = providerAccountID("claude", second.AccountSubject)
	second.Generation = randomID()
	p := newPool([]savedAccount{{Credential: c, Enabled: true, ConcurrencyLimit: 1}, {Credential: second, Enabled: true, ConcurrencyLimit: 1}})
	for _, entry := range p.entries {
		entry.catalogAt = time.Now()
		entry.view.Models = []string{testModel}
	}
	b := newClaudeBackend("").(*claudeBackend)
	var calls atomic.Int32
	stub := adapterRoundTrip(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		if r.Method != http.MethodPost || r.URL.Host != "api.anthropic.com" || r.URL.Path != "/v1/messages" {
			t.Error("unexpected upstream request")
		}
		res := adapterResponse(status, body)
		if broken {
			res.Body = &brokenFixtureBody{Reader: strings.NewReader(body)}
		}
		if status == 200 {
			res.Header.Set("Content-Type", "text/event-stream")
		} else {
			res.Header.Set("Content-Type", "application/json")
		}
		return res, nil
	})
	b.http.transport = offlineSDKTransport(t, b.http.transport, stub)
	b.http.client.Transport = b.http.transport
	g := testGateway(p, &backendRouter{providers: map[string]authBackend{"claude": b}})
	path := "/providers/claude/v1/responses"
	payload := fmt.Sprintf(`{"model":%q,"input":"fixture request","stream":%t,"tools":[{"type":"function","name":"fixture_lookup","parameters":{"type":"object","properties":{"query":{"type":"string"}}}}]}`, testModel, stream)
	if format == "chat" {
		path = "/providers/claude/v1/chat/completions"
		payload = fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"fixture request"}],"stream":%t,"tools":[{"type":"function","function":{"name":"fixture_lookup","parameters":{"type":"object","properties":{"query":{"type":"string"}}}}}]}`, testModel, stream)
	}
	server := httptest.NewUnstartedServer(g)
	g.host = server.Listener.Addr().String()
	server.Start()
	defer server.Close()
	req, err := http.NewRequest(http.MethodPost, server.URL+path, strings.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+testKey)
	res, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	data, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	w.Code = res.StatusCode
	_, _ = w.Body.Write(data)
	return w, calls.Load(), p
}

type brokenFixtureBody struct{ *strings.Reader }

func (b *brokenFixtureBody) Read(p []byte) (int, error) {
	n, err := b.Reader.Read(p)
	if err == io.EOF {
		return n, io.ErrUnexpectedEOF
	}
	return n, err
}
func (b *brokenFixtureBody) Close() error { return nil }

func TestClaudePartialStreamNeverReplays(t *testing.T) {
	for _, format := range []string{"chat", "responses"} {
		t.Run(format, func(t *testing.T) {
			body := fixtureEvent("message_start", map[string]any{"type": "message_start", "message": map[string]any{"id": "msg_fixture", "type": "message", "role": "assistant", "model": testModel, "content": []any{}, "usage": map[string]any{"input_tokens": 5, "output_tokens": 0}}})
			body += fixtureEvent("content_block_start", map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "text", "text": ""}})
			body += fixtureEvent("content_block_delta", map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "partial answer"}})
			w, calls, _ := syntheticClaudeGatewayWithFault(t, format, true, 200, body, true)
			if w.Code != 200 || calls != 1 || !strings.Contains(w.Body.String(), "partial answer") || !strings.Contains(w.Body.String(), "upstream_stream_failed") {
				t.Fatalf("partial stream replay, lost output or unreported error (status=%d calls=%d)", w.Code, calls)
			}
		})
	}
}

func claudeTruncationEvents(kind, reason string) string {
	body := fixtureEvent("message_start", map[string]any{"type": "message_start", "message": map[string]any{"id": "msg_fixture", "type": "message", "role": "assistant", "model": testModel, "content": []any{}, "usage": map[string]any{"input_tokens": 5, "output_tokens": 0}}})
	if kind == "text" {
		body += fixtureEvent("content_block_start", map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "text", "text": ""}})
		body += fixtureEvent("content_block_delta", map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "partial answer"}})
	} else {
		argument := `{"query":"partial`
		if kind == "tool_complete_json" {
			argument = `{"query":"complete"}`
		}
		body += fixtureEvent("content_block_start", map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "tool_use", "id": "call_fixture", "name": "fixture_lookup", "input": map[string]any{}}})
		body += fixtureEvent("content_block_delta", map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "input_json_delta", "partial_json": argument}})
	}
	body += fixtureEvent("content_block_stop", map[string]any{"type": "content_block_stop", "index": 0})
	body += fixtureEvent("message_delta", map[string]any{"type": "message_delta", "delta": map[string]any{"stop_reason": reason}, "usage": map[string]any{"output_tokens": 4}})
	return body + fixtureEvent("message_stop", map[string]any{"type": "message_stop"})
}

func sseData(body string) []gjson.Result {
	var result []gjson.Result
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "data:") {
			data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
			if gjson.Valid(data) {
				result = append(result, gjson.Parse(data))
			}
		}
	}
	return result
}

func assertChatTruncation(t *testing.T, body string, stream bool, kind string) {
	t.Helper()
	values := []gjson.Result{gjson.Parse(body)}
	if stream {
		values = sseData(body)
	}
	var text, args, finish string
	var outputTokens int64
	for _, v := range values {
		if v.Get("error").Exists() {
			t.Fatal("unexpected translated error")
		}
		if stream {
			text += v.Get("choices.0.delta.content").String()
			args += v.Get("choices.0.delta.tool_calls.0.function.arguments").String()
		} else {
			text = v.Get("choices.0.message.content").String()
			args = v.Get("choices.0.message.tool_calls.0.function.arguments").String()
		}
		if f := v.Get("choices.0.finish_reason").String(); f != "" {
			finish = f
		}
		if n := v.Get("usage.completion_tokens"); n.Exists() {
			outputTokens = n.Int()
		}
	}
	if finish != "length" || outputTokens != 4 {
		t.Fatalf("finish=%q output tokens=%d", finish, outputTokens)
	}
	if kind == "text" && text != "partial answer" {
		t.Fatal("partial text was not preserved")
	}
	if kind != "text" {
		want := `{"query":"partial`
		if kind == "tool_complete_json" {
			want = `{"query":"complete"}`
		}
		if args != want {
			t.Fatal("truncated tool arguments were not preserved")
		}
	}
}

func assertResponsesTruncation(t *testing.T, body string, stream bool, kind string) {
	t.Helper()
	terminal := gjson.Parse(body)
	if stream {
		terminal = gjson.Result{}
		argumentsDone, itemDone, terminalEvent := -1, -1, -1
		for index, v := range sseData(body) {
			if v.Get("type").String() == "response.function_call_arguments.done" {
				argumentsDone = index
			}
			if v.Get("type").String() == "response.output_item.done" && v.Get("item.type").String() == "function_call" {
				if v.Get("item.status").String() != "incomplete" {
					t.Fatal("truncated tool marked complete")
				}
				itemDone = index
			}
			if v.Get("type").String() == "response.incomplete" {
				terminal = v.Get("response")
				terminalEvent = index
			}
		}
		// Upstream ends the argument stream before it emits the incomplete item
		// and response. Clients must use those statuses to decide whether to act.
		if kind != "text" && !(argumentsDone >= 0 && argumentsDone < itemDone && itemDone < terminalEvent) {
			t.Fatal("unexpected truncated tool event ordering")
		}
	}
	if terminal.Get("status").String() != "incomplete" || terminal.Get("incomplete_details.reason").String() != "max_output_tokens" || terminal.Get("usage.input_tokens").Int() != 5 || terminal.Get("usage.output_tokens").Int() != 4 {
		t.Fatal("wrong terminal status, detail or token counts")
	}
	output := terminal.Get("output.0")
	if output.Get("status").String() != "incomplete" {
		t.Fatal("wrong truncated item status")
	}
	if kind == "text" && output.Get("content.0.text").String() != "partial answer" {
		t.Fatal("partial text was not preserved")
	}
	if kind != "text" {
		want := `{"query":"partial`
		if kind == "tool_complete_json" {
			want = `{"query":"complete"}`
		}
		if output.Get("type").String() != "function_call" || output.Get("arguments").String() != want {
			t.Fatal("truncated tool arguments were not preserved")
		}
	}
}
