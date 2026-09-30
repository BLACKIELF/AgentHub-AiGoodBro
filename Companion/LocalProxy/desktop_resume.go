package main

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Resolve omitted model settings through the backend's public thread/read RPC.
// An explicit provider override otherwise suppresses Codex's persisted model
// and effort restoration. Never read or rewrite its private history/database.
type desktopRPCBridge struct {
	backend       io.Writer
	client        io.Writer
	mu            sync.Mutex
	backendMu     sync.Mutex
	clientMu      sync.Mutex
	pending       map[string][]byte
	timers        map[string]*time.Timer
	resumes       map[string]bool
	firstTurn     map[string]map[string]json.RawMessage
	requestPrefix string
}

func resumeMetadataRequest(line []byte) (string, bool) {
	var msg struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params struct {
			ThreadID string                     `json:"threadId"`
			Model    *string                    `json:"model"`
			Config   map[string]json.RawMessage `json:"config"`
		} `json:"params"`
	}
	if json.Unmarshal(line, &msg) != nil || len(msg.ID) == 0 || bytes.Equal(msg.ID, []byte("null")) ||
		(msg.Method != "thread/resume" && msg.Method != "thread/fork") || msg.Params.ThreadID == "" {
		return "", false
	}
	_, configuredModel := msg.Params.Config["model"]
	_, configuredEffort := msg.Params.Config["model_reasoning_effort"]
	return msg.Params.ThreadID, !(configuredEffort && (configuredModel || msg.Params.Model != nil))
}

func restoreResumeSettings(original, reply []byte) ([]byte, bool) {
	var metadata struct {
		Result struct {
			Thread struct {
				Model  *string         `json:"model"`
				Effort json.RawMessage `json:"reasoningEffort"`
			} `json:"thread"`
		} `json:"result"`
	}
	if json.Unmarshal(reply, &metadata) != nil || metadata.Result.Thread.Model == nil || *metadata.Result.Thread.Model == "" || len(metadata.Result.Thread.Effort) == 0 {
		return nil, false
	}
	var msg, params, config map[string]json.RawMessage
	if json.Unmarshal(original, &msg) != nil || json.Unmarshal(msg["params"], &params) != nil {
		return nil, false
	}
	if raw := params["config"]; len(raw) != 0 && !bytes.Equal(raw, []byte("null")) {
		if json.Unmarshal(raw, &config) != nil {
			return nil, false
		}
	}
	if config == nil {
		config = map[string]json.RawMessage{}
	}
	if _, explicit := config["model"]; !explicit && (len(params["model"]) == 0 || bytes.Equal(params["model"], []byte("null"))) {
		params["model"], _ = json.Marshal(*metadata.Result.Thread.Model)
	}
	if _, explicit := config["model_reasoning_effort"]; !explicit {
		config["model_reasoning_effort"] = metadata.Result.Thread.Effort
	}
	params["config"], _ = json.Marshal(config)
	msg["params"], _ = json.Marshal(params)
	line, err := json.Marshal(msg)
	return append(line, '\n'), err == nil
}

func (b *desktopRPCBridge) fromClient(line []byte) error {
	if threadID, needed := resumeMetadataRequest(line); needed {
		b.mu.Lock()
		if b.requestPrefix == "" {
			b.requestPrefix = "aigoodbro-resume-" + uuid.NewString() + "-"
		}
		id := b.requestPrefix + uuid.NewString()
		if b.pending == nil {
			b.pending = map[string][]byte{}
		}
		b.pending[id] = append([]byte(nil), line...)
		if b.timers == nil {
			b.timers = map[string]*time.Timer{}
		}
		b.timers[id] = time.AfterFunc(20*time.Second, func() { b.expireResume(id) })
		b.mu.Unlock()
		request, _ := json.Marshal(map[string]any{"id": id, "method": "thread/read", "params": map[string]any{"threadId": threadID, "includeTurns": false}})
		return b.writeBackend(append(request, '\n'))
	}
	return b.writeRequest(line)
}

func (b *desktopRPCBridge) expireResume(id string) {
	b.mu.Lock()
	original, ok := b.pending[id]
	delete(b.pending, id)
	if timer := b.timers[id]; timer != nil {
		timer.Stop()
		delete(b.timers, id)
	}
	b.mu.Unlock()
	if ok {
		_ = b.resumeError(original)
	}
}

// Codex writes the effective resume configuration into rollout metadata only
// when the next turn supplies model settings. Replay that same configuration
// once, preserving every explicitly supplied turn override.
func (b *desktopRPCBridge) writeRequest(line []byte) error {
	b.mu.Lock()
	var msg, params map[string]json.RawMessage
	if json.Unmarshal(line, &msg) == nil && json.Unmarshal(msg["params"], &params) == nil {
		var method, threadID string
		_ = json.Unmarshal(msg["method"], &method)
		_ = json.Unmarshal(params["threadId"], &threadID)
		if (method == "thread/resume" || method == "thread/fork") && len(msg["id"]) > 0 {
			if b.resumes == nil {
				b.resumes = map[string]bool{}
			}
			b.resumes[string(msg["id"])] = true
		}
		if method == "turn/start" {
			if saved := b.firstTurn[threadID]; saved != nil {
				if len(params["collaborationMode"]) == 0 || bytes.Equal(params["collaborationMode"], []byte("null")) {
					for key, value := range saved {
						if len(params[key]) == 0 || bytes.Equal(params[key], []byte("null")) {
							params[key] = value
						}
					}
					msg["params"], _ = json.Marshal(params)
					encoded, _ := json.Marshal(msg)
					line = append(encoded, '\n')
				}
				delete(b.firstTurn, threadID)
			}
		}
	}
	b.mu.Unlock()
	return b.writeBackend(transformDesktopLine(line))
}

func (b *desktopRPCBridge) writeBackend(line []byte) error {
	b.backendMu.Lock()
	defer b.backendMu.Unlock()
	_, err := b.backend.Write(line)
	return err
}

func (b *desktopRPCBridge) writeClient(line []byte) error {
	b.clientMu.Lock()
	defer b.clientMu.Unlock()
	_, err := b.client.Write(line)
	return err
}

func (b *desktopRPCBridge) resumeError(original []byte) error {
	var request struct {
		ID json.RawMessage `json:"id"`
	}
	_ = json.Unmarshal(original, &request)
	failure, _ := json.Marshal(map[string]any{"id": request.ID, "error": map[string]any{"code": -32603, "message": "Cannot restore saved model settings. Select the model and reasoning effort before resuming."}})
	return b.writeClient(append(failure, '\n'))
}

func (b *desktopRPCBridge) close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, timer := range b.timers {
		timer.Stop()
	}
	b.pending = nil
	b.timers = nil
}

func (b *desktopRPCBridge) fromBackend(line []byte) error {
	b.mu.Lock()
	if b.requestPrefix != "" {
		var msg struct {
			ID     string `json:"id"`
			Method string `json:"method"`
		}
		if json.Unmarshal(line, &msg) == nil && msg.Method == "" {
			if original, found := b.pending[msg.ID]; found {
				delete(b.pending, msg.ID)
				if timer := b.timers[msg.ID]; timer != nil {
					timer.Stop()
					delete(b.timers, msg.ID)
				}
				b.mu.Unlock()
				if restored, ok := restoreResumeSettings(original, line); ok {
					return b.writeRequest(restored)
				}
				return b.resumeError(original)
			}
			// A timed-out internal lookup must never leak into the Desktop RPC
			// stream or resume a task after the caller has seen failure.
			if strings.HasPrefix(msg.ID, b.requestPrefix) {
				b.mu.Unlock()
				return nil
			}
		}
	}
	var reply struct {
		ID     json.RawMessage `json:"id"`
		Result struct {
			Thread struct {
				ID string `json:"id"`
			} `json:"thread"`
			Model  json.RawMessage `json:"model"`
			Effort json.RawMessage `json:"reasoningEffort"`
		} `json:"result"`
	}
	if json.Unmarshal(line, &reply) == nil && b.resumes[string(reply.ID)] {
		delete(b.resumes, string(reply.ID))
		if reply.Result.Thread.ID != "" && len(reply.Result.Model) > 0 {
			if b.firstTurn == nil {
				b.firstTurn = map[string]map[string]json.RawMessage{}
			}
			saved := map[string]json.RawMessage{"model": reply.Result.Model}
			if len(reply.Result.Effort) > 0 {
				saved["effort"] = reply.Result.Effort
			}
			b.firstTurn[reply.Result.Thread.ID] = saved
		}
	}
	b.mu.Unlock()
	return b.writeClient(line)
}
