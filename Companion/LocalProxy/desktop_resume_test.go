package main

import (
	"bytes"
	"encoding/json"
	"testing"
)

func rpcObject(t *testing.T, raw []byte) map[string]any {
	t.Helper()
	var value map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(raw), &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func TestDesktopResumePreservesPartialOverrides(t *testing.T) {
	metadata := []byte(`{"result":{"thread":{"model":"saved-model","reasoningEffort":"max"}}}`)
	cases := []struct{ name, params, model, effort string }{
		{"omitted", `{"threadId":"t"}`, "saved-model", "max"},
		{"explicit model", `{"threadId":"t","model":"chosen-model"}`, "chosen-model", "max"},
		{"explicit effort", `{"threadId":"t","config":{"model_reasoning_effort":"high","unchanged":true}}`, "saved-model", "high"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			raw := []byte(`{"id":7,"method":"thread/resume","params":` + c.params + `}`)
			if id, needed := resumeMetadataRequest(raw); !needed || id != "t" {
				t.Fatal("missing settings must be restored")
			}
			restored, ok := restoreResumeSettings(raw, metadata)
			if !ok {
				t.Fatal("restore failed")
			}
			params := rpcObject(t, restored)["params"].(map[string]any)
			if params["model"] != c.model || params["config"].(map[string]any)["model_reasoning_effort"] != c.effort {
				t.Fatal("explicit settings overwritten or inherited settings lost")
			}
		})
	}
	if _, needed := resumeMetadataRequest([]byte(`{"id":8,"method":"thread/resume","params":{"threadId":"t","model":"chosen","config":{"model_reasoning_effort":"high"}}}`)); needed {
		t.Fatal("complete explicit selection needs no lookup")
	}
}

func TestDesktopResumeBridgeRestoresFirstTurnOnly(t *testing.T) {
	for _, method := range []string{"thread/resume", "thread/fork"} {
		t.Run(method, func(t *testing.T) {
			var backend, client bytes.Buffer
			bridge := &desktopRPCBridge{backend: &backend, client: &client}
			defer bridge.close()
			if err := bridge.fromClient([]byte(`{"id":7,"method":"` + method + `","params":{"threadId":"old"}}`)); err != nil {
				t.Fatal(err)
			}
			lookup := rpcObject(t, backend.Bytes())
			backend.Reset()
			if lookup["method"] != "thread/read" {
				t.Fatal("public metadata lookup required")
			}
			reply, _ := json.Marshal(map[string]any{"id": lookup["id"], "result": map[string]any{"thread": map[string]any{"model": "saved-model", "reasoningEffort": "max"}}})
			if err := bridge.fromBackend(reply); err != nil {
				t.Fatal(err)
			}
			request := rpcObject(t, backend.Bytes())
			backend.Reset()
			if request["method"] != method || request["params"].(map[string]any)["modelProvider"] != "openai" {
				t.Fatal("restored request must use built-in provider")
			}
			if client.Len() != 0 {
				t.Fatal("internal metadata reply leaked to client")
			}
			resumeReply := []byte(`{"id":7,"result":{"thread":{"id":"effective"},"model":"saved-model","reasoningEffort":"max"}}`)
			if err := bridge.fromBackend(resumeReply); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(client.Bytes(), resumeReply) {
				t.Fatal("public reply changed")
			}
			if err := bridge.fromClient([]byte(`{"id":8,"method":"turn/start","params":{"threadId":"effective","effort":"high","input":[{"type":"text","text":"fixture"}]}}`)); err != nil {
				t.Fatal(err)
			}
			first := rpcObject(t, backend.Bytes())["params"].(map[string]any)
			backend.Reset()
			if first["model"] != "saved-model" || first["effort"] != "high" {
				t.Fatal("first turn must persist inherited model and retain explicit effort")
			}
			if err := bridge.fromClient([]byte(`{"id":9,"method":"turn/start","params":{"threadId":"effective"}}`)); err != nil {
				t.Fatal(err)
			}
			if _, exists := rpcObject(t, backend.Bytes())["params"].(map[string]any)["model"]; exists {
				t.Fatal("must not override later turns")
			}
		})
	}
}

func TestDesktopResumeLookupFailureAndLateReply(t *testing.T) {
	for _, timeout := range []bool{false, true} {
		var backend, client bytes.Buffer
		bridge := &desktopRPCBridge{backend: &backend, client: &client}
		if err := bridge.fromClient([]byte(`{"id":"caller","method":"thread/resume","params":{"threadId":"t"}}`)); err != nil {
			t.Fatal(err)
		}
		id := rpcObject(t, backend.Bytes())["id"].(string)
		backend.Reset()
		if timeout {
			bridge.expireResume(id)
		} else {
			failed, _ := json.Marshal(map[string]any{"id": id, "error": map[string]any{"code": -1}})
			if err := bridge.fromBackend(failed); err != nil {
				t.Fatal(err)
			}
		}
		failure := rpcObject(t, client.Bytes())
		if failure["id"] != "caller" || failure["error"] == nil {
			t.Fatal("failure must address caller")
		}
		client.Reset()
		late, _ := json.Marshal(map[string]any{"id": id, "result": map[string]any{"thread": map[string]any{"model": "late", "reasoningEffort": "max"}}})
		if err := bridge.fromBackend(late); err != nil {
			t.Fatal(err)
		}
		if backend.Len() != 0 || client.Len() != 0 {
			t.Fatal("late internal reply must not resume or leak")
		}
		bridge.close()
	}
}
