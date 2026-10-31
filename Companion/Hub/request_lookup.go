package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
)

// Recovery is a read of an existing durable task claim. It never retries or
// advances create/approve and deliberately excludes the finding namespace.
func (hub *Hub) lookupTaskRequest(requestHash string, now time.Time) ([]byte, error) {
	if !validDigest(requestHash) || strings.ToLower(requestHash) != requestHash {
		return nil, errInvalid
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	record, found := hub.requests[requestHash]
	if !found || record.RequestHash != requestHash || record.TaskID == "" || record.FindingID != "" ||
		!validDigest(record.BodyHash) || strings.ToLower(record.BodyHash) != record.BodyHash {
		return nil, errNotFound
	}
	task := hub.tasks[record.TaskID]
	if task == nil || task.ID != record.TaskID {
		return nil, errNotFound
	}
	// Marshal while holding the same lock: DTO preference pointers must not outlive
	// this snapshot and race with a concurrent task transition.
	return json.Marshal(struct {
		RequestHash string  `json:"requestHash"`
		BodyHash    string  `json:"bodyHash"`
		Task        TaskDTO `json:"task"`
	}{record.RequestHash, record.BodyHash, task.dtoAt(now)})
}

func (api *API) handleRequestLookup(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	if request.URL.RawQuery != "" || request.URL.ForceQuery {
		writeError(response, http.StatusBadRequest, "invalid_request")
		return
	}
	now := time.Now().UTC()
	if api.now != nil {
		now = api.now()
	}
	payload, err := api.hub.lookupTaskRequest(strings.TrimPrefix(request.URL.Path, "/api/requests/"), now)
	if err != nil {
		switch {
		case errors.Is(err, errInvalid):
			writeError(response, http.StatusBadRequest, "invalid_request")
		case errors.Is(err, errNotFound):
			writeError(response, http.StatusNotFound, "not_found")
		default:
			writeError(response, http.StatusInternalServerError, "internal_error")
		}
		return
	}
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(http.StatusOK)
	_, _ = response.Write(payload)
}
