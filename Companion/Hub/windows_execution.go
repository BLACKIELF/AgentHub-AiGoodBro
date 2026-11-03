package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"sort"
	"strconv"
	"strings"
	"time"
)

const windowsExecutionAuthorityMaxAge = 10 * time.Second

// The native client captures workflow/model/plan evidence immediately before
// POSTing approval. Hub scheduling is asynchronous, so bound that handoff with
// a monotonic local receive timestamp and require a new approval after expiry.
func windowsExecutionAuthorityFresh(receivedAt time.Time) bool {
	if receivedAt.IsZero() {
		return false
	}
	age := time.Since(receivedAt)
	return age >= 0 && age <= windowsExecutionAuthorityMaxAge
}

func clearWindowsExecutionAuthority(task *Task) {
	if task == nil {
		return
	}
	task.windowsExecutionAuthority = nil
	task.windowsEffectiveExecution = nil
	task.windowsExecutionAuthorityAt = time.Time{}
}

// Revalidate the approved snapshot at the OS spawn boundary. The model list
// itself is the native snapshot captured before approval; current persisted
// workflow/identity/plan/quota inputs are checked by lockDesktopSpawn.
func validateWindowsExecutionAtSpawn(task *Task, now time.Time) error {
	if task == nil || task.WindowsExecution == nil {
		return nil
	}
	if !windowsExecutionAuthorityFresh(task.windowsExecutionAuthorityAt) {
		return errWindowsExecutionStale
	}
	if task.windowsExecutionAuthority == nil || task.windowsEffectiveExecution == nil || !task.windowsExecutionAuthorityConsumed {
		return errDispatchPolicyUnavailable
	}
	resolved, err := resolveWindowsExecution(*task.WindowsExecution, *task.windowsExecutionAuthority, now)
	if err != nil {
		return err
	}
	if !sameWindowsEffectiveExecution(resolved, *task.windowsEffectiveExecution) {
		return errDispatchPolicyUnavailable
	}
	return nil
}

func sameWindowsEffectiveExecution(left, right windowsEffectiveExecution) bool {
	if left.ProfileID != right.ProfileID || left.Model != right.Model || left.Effort != right.Effort ||
		left.ServiceTier != right.ServiceTier || left.WorkflowRevision != right.WorkflowRevision ||
		left.BindingSHA256 != right.BindingSHA256 {
		return false
	}
	if left.NotAfterMS == nil || right.NotAfterMS == nil {
		return left.NotAfterMS == nil && right.NotAfterMS == nil
	}
	return *left.NotAfterMS == *right.NotAfterMS
}

// The request contains only one-call overrides and a binding. Effective values
// are always derived from the held native workflow/model evidence at spawn.
type windowsExecutionRequest struct {
	WorkflowRevision uint64                    `json:"workflowRevision"`
	BindingSHA256    string                    `json:"bindingSHA256"`
	Overrides        windowsExecutionOverrides `json:"overrides"`
}

type windowsExecutionOverrides struct {
	Model       *string `json:"model"`
	Effort      *string `json:"effort"`
	ServiceTier *string `json:"serviceTier"`
}

type windowsExecutionPreference struct {
	Participating bool                   `json:"participating"`
	Model         *string                `json:"model"`
	Effort        *string                `json:"effort"`
	ServiceTier   *string                `json:"service_tier"`
	DispatchCode  *string                `json:"dispatch_code"`
	NotAfterMS    *int64                 `json:"not_after_ms"`
	Window        *managerDispatchWindow `json:"dispatch_window"`
	Revision      uint64                 `json:"revision"`
}

type windowsModelCapability struct {
	ID            string   `json:"id"`
	Label         string   `json:"label"`
	Efforts       []string `json:"efforts"`
	DefaultEffort string   `json:"default_effort"`
	IsDefault     bool     `json:"is_default"`
}

// Constructed from freshly read protected workflow, model, and account evidence.
type windowsExecutionAuthority struct {
	ProfileID         uint64                     `json:"profileId"`
	Preference        windowsExecutionPreference `json:"preference"`
	ExcludedPlanTypes []string                   `json:"excludedPlanTypes"`
	OfficialPlan      string                     `json:"officialPlan"`
	Models            []windowsModelCapability   `json:"models"`
}

type windowsEffectiveExecution struct {
	ProfileID        uint64 `json:"profileId"`
	Model            string `json:"model"`
	Effort           string `json:"effort"`
	ServiceTier      string `json:"serviceTier"`
	WorkflowRevision uint64 `json:"workflowRevision"`
	NotAfterMS       *int64 `json:"notAfterMs"`
	BindingSHA256    string `json:"bindingSHA256"`
}

func windowsExecutionBodyHash(oldHash string, extension *windowsExecutionRequest) (string, error) {
	if !lowerSHA(oldHash) {
		return "", errInvalid
	}
	if extension == nil {
		return oldHash, nil
	}
	if !lowerSHA(extension.BindingSHA256) {
		return "", errInvalid
	}
	return hashParts(oldHash, "windows-execution-v1", extension.BindingSHA256), nil
}

func cloneWindowsExecutionRequest(request *windowsExecutionRequest) *windowsExecutionRequest {
	if request == nil {
		return nil
	}
	copy := *request
	copy.Overrides.Model = cloneWindowsString(request.Overrides.Model)
	copy.Overrides.Effort = cloneWindowsString(request.Overrides.Effort)
	copy.Overrides.ServiceTier = cloneWindowsString(request.Overrides.ServiceTier)
	return &copy
}

func cloneWindowsExecutionAuthority(authority *windowsExecutionAuthority) *windowsExecutionAuthority {
	if authority == nil {
		return nil
	}
	copy := *authority
	copy.Preference.Model = cloneWindowsString(authority.Preference.Model)
	copy.Preference.Effort = cloneWindowsString(authority.Preference.Effort)
	copy.Preference.ServiceTier = cloneWindowsString(authority.Preference.ServiceTier)
	copy.Preference.DispatchCode = cloneWindowsString(authority.Preference.DispatchCode)
	if authority.Preference.NotAfterMS != nil {
		value := *authority.Preference.NotAfterMS
		copy.Preference.NotAfterMS = &value
	}
	if window := authority.Preference.Window; window != nil {
		windowCopy := *window
		windowCopy.Intervals = append([]managerDispatchInterval(nil), window.Intervals...)
		for i := range windowCopy.Intervals {
			interval := &windowCopy.Intervals[i]
			if window.Intervals[i].StartMinute != nil {
				value := *window.Intervals[i].StartMinute
				interval.StartMinute = &value
			}
			if window.Intervals[i].EndMinute != nil {
				value := *window.Intervals[i].EndMinute
				interval.EndMinute = &value
			}
			if window.Intervals[i].AllDays != nil {
				value := *window.Intervals[i].AllDays
				interval.AllDays = &value
			}
			if window.Intervals[i].AllDay != nil {
				value := *window.Intervals[i].AllDay
				interval.AllDay = &value
			}
			interval.Weekdays = append([]int(nil), window.Intervals[i].Weekdays...)
		}
		copy.Preference.Window = &windowCopy
	}
	copy.ExcludedPlanTypes = append([]string(nil), authority.ExcludedPlanTypes...)
	copy.Models = append([]windowsModelCapability(nil), authority.Models...)
	for i := range copy.Models {
		copy.Models[i].Efforts = append([]string(nil), authority.Models[i].Efforts...)
	}
	return &copy
}

func cloneWindowsString(value *string) *string {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func sameWindowsStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func resolveWindowsExecution(request windowsExecutionRequest, authority windowsExecutionAuthority, now time.Time) (windowsEffectiveExecution, error) {
	if !lowerSHA(request.BindingSHA256) || authority.ProfileID == 0 || request.WorkflowRevision != authority.Preference.Revision {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	if !authority.Preference.Participating || authority.Preference.Window != nil && !authority.Preference.Window.allows(now) {
		return windowsEffectiveExecution{}, errDispatchDisabled
	}
	if authority.Preference.NotAfterMS != nil && (*authority.Preference.NotAfterMS < 0 || now.UnixMilli() >= *authority.Preference.NotAfterMS) {
		return windowsEffectiveExecution{}, errDispatchDisabled
	}
	if !validWindowsPlan(authority.OfficialPlan) || len(authority.ExcludedPlanTypes) > 100 {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	for _, excluded := range authority.ExcludedPlanTypes {
		if !validWindowsPlan(excluded) {
			return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
		}
		if strings.EqualFold(excluded, authority.OfficialPlan) {
			return windowsEffectiveExecution{}, errDispatchDisabled
		}
	}
	if request.Overrides.ServiceTier != nil && *request.Overrides.ServiceTier != "default" && *request.Overrides.ServiceTier != "fast" {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	models := make(map[string]windowsModelCapability, len(authority.Models))
	defaults := 0
	if len(authority.Models) == 0 || len(authority.Models) > 100 {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	for _, model := range authority.Models {
		if !validWindowsModel(model.ID) || len(model.Efforts) == 0 || len(model.Efforts) > 8 || !validWindowsEffort(model.DefaultEffort) {
			return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
		}
		if _, exists := models[model.ID]; exists {
			return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
		}
		seen := make(map[string]bool, len(model.Efforts))
		for _, effort := range model.Efforts {
			if !validWindowsEffort(effort) || seen[effort] {
				return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
			}
			seen[effort] = true
		}
		if !seen[model.DefaultEffort] {
			return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
		}
		if model.IsDefault {
			defaults++
		}
		models[model.ID] = model
	}
	if defaults != 1 {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	modelID := ""
	if authority.Preference.Model != nil {
		modelID = *authority.Preference.Model
	} else {
		for _, model := range authority.Models {
			if model.IsDefault {
				modelID = model.ID
				break
			}
		}
	}
	saved, ok := models[modelID]
	if !ok {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	savedEffort := saved.DefaultEffort
	if authority.Preference.Effort != nil {
		savedEffort = *authority.Preference.Effort
	}
	if !containsString(saved.Efforts, savedEffort) {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	if request.Overrides.Model != nil {
		modelID = *request.Overrides.Model
	}
	model, ok := models[modelID]
	if !ok {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	effort := savedEffort // Model-only override preserves the saved effective effort.
	if request.Overrides.Effort != nil {
		effort = *request.Overrides.Effort
	}
	if !containsString(model.Efforts, effort) {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	tier := "default"
	if authority.Preference.ServiceTier != nil {
		tier = *authority.Preference.ServiceTier
	}
	if tier != "default" && tier != "fast" {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	if request.Overrides.ServiceTier != nil {
		tier = *request.Overrides.ServiceTier
	}
	if modelID == "gpt-5.2" && tier == "fast" {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	binding := windowsExecutionBinding(authority, request.Overrides, modelID, effort, tier)
	if binding != request.BindingSHA256 {
		return windowsEffectiveExecution{}, errDispatchPolicyUnavailable
	}
	return windowsEffectiveExecution{authority.ProfileID, modelID, effort, tier, authority.Preference.Revision,
		authority.Preference.NotAfterMS, binding}, nil
}

func (execution windowsEffectiveExecution) codexArguments() []string {
	args := []string{"-m", execution.Model, "-c", `model_reasoning_effort="` + execution.Effort + `"`, "-c", `service_tier="` + execution.ServiceTier + `"`}
	if execution.ServiceTier == "fast" {
		return append(args, "--enable", "fast_mode")
	}
	return append(args, "--disable", "fast_mode")
}

func windowsExecutionBinding(authority windowsExecutionAuthority, overrides windowsExecutionOverrides, model, effort, tier string) string {
	var data bytes.Buffer
	field := func(value string) {
		var size [8]byte
		binary.BigEndian.PutUint64(size[:], uint64(len([]byte(value))))
		data.Write(size[:])
		data.WriteString(value)
	}
	optional := func(value *string) {
		if value == nil {
			field("none")
			return
		}
		field("some")
		field(*value)
	}
	p := authority.Preference
	field("aigoodbro.workflow-execution.v2")
	field(strconv.FormatUint(authority.ProfileID, 10))
	field(strconv.FormatUint(p.Revision, 10))
	if p.Participating {
		field("true")
	} else {
		field("false")
	}
	optional(p.Model)
	optional(p.Effort)
	optional(p.ServiceTier)
	optional(p.DispatchCode)
	if p.NotAfterMS == nil {
		optional(nil)
	} else {
		value := strconv.FormatInt(*p.NotAfterMS, 10)
		optional(&value)
	}
	if p.Window == nil {
		field("none")
	} else {
		field("some")
		field(p.Window.Mode)
		field(p.Window.TimeZoneIdentifier)
		field(strconv.Itoa(len(p.Window.Intervals)))
		for _, interval := range p.Window.Intervals {
			field(strconv.Itoa(*interval.StartMinute))
			field(strconv.Itoa(*interval.EndMinute))
			if *interval.AllDays {
				field("true")
			} else {
				field("false")
			}
			if *interval.AllDay {
				field("true")
			} else {
				field("false")
			}
			weekdays := append([]int(nil), interval.Weekdays...)
			sort.Ints(weekdays)
			field(strconv.Itoa(len(weekdays)))
			for _, day := range weekdays {
				field(strconv.Itoa(day))
			}
		}
	}
	field(strconv.Itoa(len(authority.ExcludedPlanTypes)))
	for _, plan := range authority.ExcludedPlanTypes {
		field(plan)
	}
	field(authority.OfficialPlan)
	field(strconv.Itoa(len(authority.Models)))
	for _, model := range authority.Models {
		field(model.ID)
		field(model.DefaultEffort)
		if model.IsDefault {
			field("true")
		} else {
			field("false")
		}
		field(strconv.Itoa(len(model.Efforts)))
		for _, effort := range model.Efforts {
			field(effort)
		}
	}
	optional(overrides.Model)
	optional(overrides.Effort)
	optional(overrides.ServiceTier)
	field(model)
	field(effort)
	field(tier)
	sum := sha256.Sum256(data.Bytes())
	return hex.EncodeToString(sum[:])
}

func validWindowsPlan(value string) bool {
	if len(value) == 0 || len(value) > 128 || strings.TrimSpace(value) != value {
		return false
	}
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}
func validWindowsModel(value string) bool {
	if len(value) == 0 || len(value) > 80 {
		return false
	}
	for _, b := range []byte(value) {
		if !(b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || strings.ContainsRune("-_.", rune(b))) {
			return false
		}
	}
	return true
}
func validWindowsEffort(value string) bool {
	switch value {
	case "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra":
		return true
	}
	return false
}
func containsString(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}
