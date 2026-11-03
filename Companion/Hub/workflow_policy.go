package main

import (
	"bytes"
	"encoding/json"
	"io"
	"reflect"
	"strconv"
	"time"
)

type desktopWorkflowProfile struct {
	Participating *bool                  `json:"participating"`
	Model         *string                `json:"model"`
	Effort        *string                `json:"effort"`
	ServiceTier   *string                `json:"service_tier"`
	DispatchCode  *string                `json:"dispatch_code"`
	NotAfterMS    *int64                 `json:"not_after_ms"`
	Revision      *uint64                `json:"revision"`
	Window        *managerDispatchWindow `json:"dispatch_window"`
}

type desktopWorkflowSnapshot struct {
	Profile           desktopWorkflowProfile
	ExcludedPlanTypes []string
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
	snapshot, err := decodeDesktopWorkflow(data, hub.config.WorkflowProfileID)
	if err != nil {
		return err
	}
	if err := snapshot.Profile.allows(task, time.Now()); err != nil {
		return err
	}
	if task != nil && task.WindowsExecution != nil {
		return snapshot.matchesWindowsExecution(task, task.windowsExecutionAuthority)
	}
	return nil
}

func decodeDesktopWorkflow(data []byte, id uint64) (desktopWorkflowSnapshot, error) {
	var all struct {
		Profiles          map[string]json.RawMessage `json:"profiles"`
		ExcludedPlanTypes []string                   `json:"excluded_plan_types"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&all) != nil || decoder.Decode(new(any)) != io.EOF {
		return desktopWorkflowSnapshot{}, errDispatchPolicyUnavailable
	}
	var profile desktopWorkflowProfile
	raw, ok := all.Profiles[strconv.FormatUint(id, 10)]
	if !ok {
		return desktopWorkflowSnapshot{}, errDispatchPolicyUnavailable
	}
	decoder = json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&profile) != nil || decoder.Decode(new(any)) != io.EOF || profile.Participating == nil || profile.Revision == nil {
		return desktopWorkflowSnapshot{}, errDispatchPolicyUnavailable
	}
	return desktopWorkflowSnapshot{Profile: profile, ExcludedPlanTypes: all.ExcludedPlanTypes}, nil
}

func (profile desktopWorkflowProfile) allows(task *Task, now time.Time) error {
	if !*profile.Participating || !profile.Window.allows(now) {
		return errDispatchDisabled
	}
	if task != nil && task.WindowsExecution != nil {
		if profile.Revision == nil || *profile.Revision != task.WindowsExecution.WorkflowRevision {
			return errDispatchPolicyUnavailable
		}
		return nil
	}
	if task != nil {
		if profile.Model == nil || profile.Effort == nil || task.ExecutionPreference == nil || task.ExecutionPreference.Model != *profile.Model || task.ExecutionPreference.ReasoningEffort != *profile.Effort {
			return errDispatchPolicyUnavailable
		}
	}
	return nil
}

func (snapshot desktopWorkflowSnapshot) matchesWindowsExecution(task *Task, authority *windowsExecutionAuthority) error {
	if task == nil || task.WindowsExecution == nil {
		return nil
	}
	if authority == nil || snapshot.Profile.Participating == nil || snapshot.Profile.Revision == nil {
		return errDispatchPolicyUnavailable
	}
	p := snapshot.Profile
	a := authority.Preference
	if !reflect.DeepEqual(p.Participating, &a.Participating) || !reflect.DeepEqual(p.Model, a.Model) ||
		!reflect.DeepEqual(p.Effort, a.Effort) || !reflect.DeepEqual(p.ServiceTier, a.ServiceTier) ||
		!reflect.DeepEqual(p.DispatchCode, a.DispatchCode) || !reflect.DeepEqual(p.NotAfterMS, a.NotAfterMS) ||
		!reflect.DeepEqual(p.Revision, &a.Revision) || !reflect.DeepEqual(p.Window, a.Window) ||
		!sameWindowsStrings(snapshot.ExcludedPlanTypes, authority.ExcludedPlanTypes) {
		return errDispatchPolicyUnavailable
	}
	return nil
}
