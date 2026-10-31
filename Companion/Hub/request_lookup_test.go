package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func lookupHTTP(api *API, method, path, token string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, path, nil)
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response := httptest.NewRecorder()
	api.routes().ServeHTTP(response, request)
	return response
}

func TestRequestLookupReadsDurableTaskWithoutReplay(t *testing.T) {
	config := testConfig(t, "/usr/bin/true")
	hub, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	request := CreateRequest{RequestID: "lookup-create-request-0001", Agent: "codex", Project: "demo", Prompt: "private prompt never returned"}
	task, err := hub.create(request)
	if err != nil {
		t.Fatal(err)
	}
	api := &API{hub: hub, token: []byte("synthetic-lookup-token")}
	path := "/api/requests/" + hashText(request.RequestID)
	journal := filepath.Join(config.DataDir, "events.ndjson")
	before, err := os.ReadFile(journal)
	if err != nil {
		t.Fatal(err)
	}
	response := lookupHTTP(api, http.MethodGet, path, "synthetic-lookup-token")
	if response.Code != http.StatusOK || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("lookup response: %d %s", response.Code, response.Body.String())
	}
	var result struct {
		RequestHash string  `json:"requestHash"`
		BodyHash    string  `json:"bodyHash"`
		Task        TaskDTO `json:"task"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	wantBody := hashParts("create", "codex", "demo", "", hashText(request.Prompt), "")
	if result.RequestHash != hashText(request.RequestID) || result.BodyHash != wantBody || result.Task.ID != task.ID || result.Task.ActionHash != task.ActionHash || result.Task.State != stateAwaitingApproval {
		t.Fatalf("request/task binding mismatch: %#v", result)
	}
	for _, secret := range []string{request.Prompt, request.RequestID, config.Projects["demo"], "synthetic-lookup-token", `"sessionId"`, `"prompt"`} {
		if bytes.Contains(response.Body.Bytes(), []byte(secret)) {
			t.Fatalf("lookup exposed private field %q", secret)
		}
	}
	after, _ := os.ReadFile(journal)
	if !bytes.Equal(before, after) || len(hub.tasks) != 1 || len(hub.requests) != 1 || len(hub.handles) != 0 {
		t.Fatal("lookup mutated journal/task/process state")
	}
	if err := hub.store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := newHub(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reopened.shutdown(context.Background()) })
	api.hub = reopened
	before, _ = os.ReadFile(journal)
	response = lookupHTTP(api, http.MethodGet, path, "synthetic-lookup-token")
	if response.Code != http.StatusOK || json.Unmarshal(response.Body.Bytes(), &result) != nil || result.Task.ID != task.ID || result.Task.State != stateBlockedConfiguration || result.BodyHash != wantBody {
		t.Fatalf("recovery did not report exact existing task: %d %s", response.Code, response.Body.String())
	}
	after, _ = os.ReadFile(journal)
	if !bytes.Equal(before, after) || len(reopened.tasks) != 1 || len(reopened.requests) != 1 || len(reopened.handles) != 0 {
		t.Fatal("recovery lookup retried or mutated the task")
	}
}

func TestRequestLookupAuthenticationAndTaskOnlyBoundary(t *testing.T) {
	hub, err := newHub(testConfig(t, "/usr/bin/true"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { hub.shutdown(context.Background()) })
	task, err := hub.create(CreateRequest{RequestID: "lookup-boundary-request-0001", Agent: "codex", Project: "demo", Prompt: "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	api := &API{hub: hub, token: []byte("synthetic-lookup-token")}
	hash := hashText("lookup-boundary-request-0001")
	path := "/api/requests/" + hash
	for _, test := range []struct {
		method, suffix, token string
		status                int
	}{
		{http.MethodGet, "", "", http.StatusUnauthorized},
		{http.MethodGet, "", "wrong", http.StatusUnauthorized},
		{http.MethodPost, "", "synthetic-lookup-token", http.StatusMethodNotAllowed},
		{http.MethodGet, "?retry=true", "synthetic-lookup-token", http.StatusBadRequest},
		{http.MethodGet, "?", "synthetic-lookup-token", http.StatusBadRequest},
		{http.MethodGet, "/extra", "synthetic-lookup-token", http.StatusBadRequest},
	} {
		if response := lookupHTTP(api, test.method, path+test.suffix, test.token); response.Code != test.status {
			t.Fatalf("%s %s got %d want %d", test.method, test.suffix, response.Code, test.status)
		}
	}
	for _, digest := range []string{"raw-request-id", strings.ToUpper(hash)} {
		if response := lookupHTTP(api, http.MethodGet, "/api/requests/"+digest, "synthetic-lookup-token"); response.Code != http.StatusBadRequest {
			t.Fatalf("noncanonical digest accepted: %d", response.Code)
		}
	}
	for _, record := range []requestRecord{
		{RequestHash: hash, BodyHash: hashText("finding"), FindingID: "finding-id"},
		{RequestHash: hash, BodyHash: hashText("mixed"), TaskID: task.ID, FindingID: "finding-id"},
		{RequestHash: hash, BodyHash: hashText("missing"), TaskID: "missing-task"},
		{RequestHash: hashText("other"), BodyHash: hashText("wrong-key"), TaskID: task.ID},
		{RequestHash: hash, BodyHash: "invalid", TaskID: task.ID},
	} {
		hub.mu.Lock()
		hub.requests[hash] = record
		hub.mu.Unlock()
		if response := lookupHTTP(api, http.MethodGet, path, "synthetic-lookup-token"); response.Code != http.StatusNotFound {
			t.Fatalf("non-task or inconsistent claim disclosed: %d", response.Code)
		}
	}
	if response := lookupHTTP(api, http.MethodGet, "/api/requests/"+hashText("absent"), "synthetic-lookup-token"); response.Code != http.StatusNotFound {
		t.Fatalf("missing claim did not stay absent: %d", response.Code)
	}
}
