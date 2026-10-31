package main

import (
	"bytes"
	"encoding/json"
	"io"
	"strconv"
	"time"
)

type desktopWorkflowProfile struct {
	Participating *bool                  `json:"participating"`
	Model         *string                `json:"model"`
	Effort        *string                `json:"effort"`
	Revision      *uint64                `json:"revision"`
	Window        *managerDispatchWindow `json:"dispatch_window"`
}

// Optional Windows adapter. The source of truth remains the desktop workflow
// settings. Every admission and final spawn reads it again; no copied cache can
// keep an opted-out account enabled. Empty config preserves existing Mac rules.
func (hub *Hub) desktopWorkflowAllowed(task *Task) error {
	if hub.config.WorkflowPreferencesPath == "" && hub.config.WorkflowProfileID == 0 {
		return nil
	}
	if hub.config.WorkflowPreferencesPath == "" || hub.config.WorkflowProfileID == 0 {
		return errDispatchPolicyUnavailable
	}
	file, release, err := openDesktopSource(hub.config.WorkflowPreferencesPath, false)
	if err != nil {
		return errDispatchPolicyUnavailable
	}
	defer release()
	data, err := io.ReadAll(io.LimitReader(file, 1024*1024+1))
	if err != nil || len(data) > 1024*1024 {
		return errDispatchPolicyUnavailable
	}
	profile, err := decodeDesktopWorkflow(data, hub.config.WorkflowProfileID)
	if err != nil {
		return err
	}
	return profile.allows(task, time.Now())
}

func decodeDesktopWorkflow(data []byte, id uint64) (desktopWorkflowProfile, error) {
	var all struct {
		Profiles map[string]json.RawMessage `json:"profiles"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&all) != nil || decoder.Decode(new(any)) != io.EOF {
		return desktopWorkflowProfile{}, errDispatchPolicyUnavailable
	}
	var profile desktopWorkflowProfile
	raw, ok := all.Profiles[strconv.FormatUint(id, 10)]
	if !ok {
		return profile, errDispatchPolicyUnavailable
	}
	decoder = json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&profile) != nil || decoder.Decode(new(any)) != io.EOF || profile.Participating == nil || profile.Revision == nil || profile.Model == nil || profile.Effort == nil {
		return profile, errDispatchPolicyUnavailable
	}
	return profile, nil
}

func (profile desktopWorkflowProfile) allows(task *Task, now time.Time) error {
	if !*profile.Participating || !profile.Window.allows(now) {
		return errDispatchDisabled
	}
	if task != nil && (task.ExecutionPreference == nil || task.ExecutionPreference.Model != *profile.Model || task.ExecutionPreference.ReasoningEffort != *profile.Effort) {
		return errDispatchPolicyUnavailable
	}
	return nil
}
