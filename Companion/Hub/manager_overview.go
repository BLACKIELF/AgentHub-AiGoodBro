package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const appleEpochUnixOffset = int64(978307200)

type managerSnapshotFile struct {
	Profiles []managerProfile `json:"profiles"`
}

type managerProfile struct {
	DispatchParticipationWindow  *managerDispatchWindow  `json:"dispatchParticipationWindow,omitempty"`
	Name                         string                  `json:"name"`
	CodexHomePath                string                  `json:"codexHomePath"`
	IsSystemProfile              bool                    `json:"isSystemProfile"`
	ExecutionPreference          *executionPreference    `json:"executionPreference,omitempty"`
	LastQuotaReadFailureAt       *float64                `json:"lastQuotaReadFailureAt"`
	AutomaticSwitchParticipation *bool                   `json:"automaticSwitchParticipation"`
	LastSnapshot                 *managerAccountSnapshot `json:"lastSnapshot"`
}

type executionPreference struct {
	Model           string                     `json:"model"`
	ReasoningEffort string                     `json:"reasoningEffort"`
	ServiceTier     string                     `json:"serviceTier"`
	SubagentMode    string                     `json:"subagentMode"`
	CustomPresets   map[string]executionPreset `json:"customPresets,omitempty"`
}

type executionPreset struct {
	Name                    *string `json:"name,omitempty"`
	UseSavedModel           bool    `json:"useSavedModel"`
	Model                   string  `json:"model"`
	ReasoningEffort         string  `json:"reasoningEffort"`
	SubagentsEnabled        bool    `json:"subagentsEnabled"`
	SubagentModel           string  `json:"subagentModel"`
	SubagentReasoningEffort string  `json:"subagentReasoningEffort"`
}

func (preset *executionPreset) UnmarshalJSON(data []byte) error {
	type wirePreset struct {
		Name                    *string `json:"name"`
		UseSavedModel           *bool   `json:"useSavedModel"`
		Model                   *string `json:"model"`
		ReasoningEffort         *string `json:"reasoningEffort"`
		SubagentsEnabled        *bool   `json:"subagentsEnabled"`
		SubagentModel           *string `json:"subagentModel"`
		SubagentReasoningEffort *string `json:"subagentReasoningEffort"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var wire wirePreset
	if decoder.Decode(&wire) != nil || decoder.Decode(&struct{}{}) != io.EOF || wire.UseSavedModel == nil || wire.Model == nil || wire.ReasoningEffort == nil || wire.SubagentsEnabled == nil || wire.SubagentModel == nil || wire.SubagentReasoningEffort == nil {
		return errInvalid
	}
	*preset = executionPreset{Name: wire.Name, UseSavedModel: *wire.UseSavedModel, Model: *wire.Model,
		ReasoningEffort: *wire.ReasoningEffort, SubagentsEnabled: *wire.SubagentsEnabled,
		SubagentModel: *wire.SubagentModel, SubagentReasoningEffort: *wire.SubagentReasoningEffort}
	return nil
}

var defaultExecutionPreference = executionPreference{
	Model:           "gpt-6-astra",
	ReasoningEffort: "low",
	ServiceTier:     "default",
	SubagentMode:    "standard",
}

func normalizedExecutionPreference(preference *executionPreference) (executionPreference, error) {
	if preference == nil {
		return defaultExecutionPreference, nil
	}
	normalized := *preference
	if normalized.SubagentMode == "" {
		normalized.SubagentMode = "standard"
	}
	maxEffort := map[string]string{
		"gpt-6-astra":   "ultra",
		"gpt-6-sol":     "ultra",
		"gpt-6-luna":    "max",
		"gpt-5.6-sol":   "ultra",
		"gpt-5.6-terra": "ultra",
		"gpt-5.6-luna":  "max",
		"gpt-5.5":       "xhigh",
		"gpt-5.2":       "xhigh",
	}[normalized.Model]
	effortRank := map[string]int{"low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5, "ultra": 6}
	if maxEffort == "" || effortRank[normalized.ReasoningEffort] == 0 || effortRank[normalized.ReasoningEffort] > effortRank[maxEffort] {
		return executionPreference{}, errInvalid
	}
	if normalized.ServiceTier != "default" && normalized.ServiceTier != "fast" {
		return executionPreference{}, errInvalid
	}
	if normalized.SubagentMode != "standard" && normalized.SubagentMode != "sol_luna" && normalized.SubagentMode != "luna_direct" {
		return executionPreference{}, errInvalid
	}
	if len(normalized.CustomPresets) > 3 {
		return executionPreference{}, errInvalid
	}
	for slot, preset := range normalized.CustomPresets {
		if slot != "standard" && slot != "sol_luna" && slot != "luna_direct" {
			return executionPreference{}, errInvalid
		}
		if preset.Name != nil {
			name := *preset.Name
			if name == "" || strings.TrimSpace(name) != name || len([]byte(name)) > 64 || !utf8.ValidString(name) || strings.IndexFunc(name, unicode.IsControl) >= 0 {
				return executionPreference{}, errInvalid
			}
		}
		if !validModelEffort(preset.Model, preset.ReasoningEffort) || !validModelEffort(preset.SubagentModel, preset.SubagentReasoningEffort) {
			return executionPreference{}, errInvalid
		}
	}
	strategy := derivedExecutionStrategy(normalized)
	if normalized.ServiceTier == "fast" && (strategy.Main.Model == "gpt-5.2" || strategy.SubagentsEnabled && strategy.SubagentModel == "gpt-5.2") {
		return executionPreference{}, errInvalid
	}
	return normalized, nil
}

func validModelEffort(model, effort string) bool {
	maxima := map[string]int{"gpt-6-astra": 6, "gpt-6-sol": 6, "gpt-6-luna": 5,
		"gpt-5.6-sol": 6, "gpt-5.6-terra": 6, "gpt-5.6-luna": 5, "gpt-5.5": 4, "gpt-5.2": 4}
	ranks := map[string]int{"low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5, "ultra": 6}
	return maxima[model] > 0 && ranks[effort] > 0 && ranks[effort] <= maxima[model]
}

type effectiveExecutionStrategy struct {
	Main                       executionPreference
	UseSavedModel              bool
	SubagentsEnabled           bool
	SubagentModel              string
	SubagentReasoningEffort    string
	MaximumConcurrentSubagents int
}

func defaultPreset(slot string) executionPreset {
	defaults := map[string]executionPreset{
		"standard":    {UseSavedModel: true, Model: "gpt-6-sol", ReasoningEffort: "low", SubagentModel: "gpt-6-luna", SubagentReasoningEffort: "max"},
		"sol_luna":    {Model: "gpt-6-sol", ReasoningEffort: "high", SubagentsEnabled: true, SubagentModel: "gpt-6-luna", SubagentReasoningEffort: "max"},
		"luna_direct": {Model: "gpt-6-luna", ReasoningEffort: "max", SubagentModel: "gpt-6-luna", SubagentReasoningEffort: "max"},
	}
	return defaults[slot]
}

func derivedExecutionStrategy(preference executionPreference) effectiveExecutionStrategy {
	preset, ok := preference.CustomPresets[preference.SubagentMode]
	if !ok {
		preset = defaultPreset(preference.SubagentMode)
	}
	main := preference
	if !preset.UseSavedModel {
		main.Model, main.ReasoningEffort = preset.Model, preset.ReasoningEffort
	}
	return effectiveExecutionStrategy{Main: main, UseSavedModel: preset.UseSavedModel,
		SubagentsEnabled: preset.SubagentsEnabled, SubagentModel: preset.SubagentModel,
		SubagentReasoningEffort:    preset.SubagentReasoningEffort,
		MaximumConcurrentSubagents: map[bool]int{true: 1}[preset.SubagentsEnabled]}
}

func derivedExecutionPreference(preference executionPreference) executionPreference {
	return derivedExecutionStrategy(preference).Main
}

func frozenTaskExecutionStrategy(task *Task, preference executionPreference) (effectiveExecutionStrategy, error) {
	strategy := derivedExecutionStrategy(preference)
	if task == nil || task.EffectiveExecutionPreference == nil {
		return strategy, nil
	}
	frozen := *task.EffectiveExecutionPreference
	if frozen.ServiceTier != preference.ServiceTier || frozen.SubagentMode != preference.SubagentMode ||
		!validModelEffort(frozen.Model, frozen.ReasoningEffort) {
		return effectiveExecutionStrategy{}, errInvalid
	}
	if !executionPreferencesEqual(frozen, strategy.Main) {
		if len(preference.CustomPresets) != 0 {
			return effectiveExecutionStrategy{}, errInvalid
		}
		legacy := preference
		switch preference.SubagentMode {
		case "sol_luna":
			legacy.Model, legacy.ReasoningEffort = "gpt-5.6-sol", "high"
			strategy.SubagentModel, strategy.SubagentReasoningEffort = "gpt-5.6-luna", "max"
		case "luna_direct":
			legacy.Model, legacy.ReasoningEffort = "gpt-5.6-luna", "max"
			strategy.SubagentModel, strategy.SubagentReasoningEffort = "gpt-5.6-luna", "max"
		default:
			return effectiveExecutionStrategy{}, errInvalid
		}
		if !executionPreferencesEqual(frozen, legacy) {
			return effectiveExecutionStrategy{}, errInvalid
		}
	}
	strategy.Main = frozen
	if strategy.SubagentsEnabled && !frozenTaskSubagentMatches(task, strategy) {
		return effectiveExecutionStrategy{}, errInvalid
	}
	return strategy, nil
}

func frozenTaskSubagentMatches(task *Task, strategy effectiveExecutionStrategy) bool {
	if task == nil || task.SubagentExecution == nil {
		return false
	}
	frozen := task.SubagentExecution
	if frozen.RequestedMode != strategy.Main.SubagentMode || frozen.RequestedRole != presetRoleName ||
		frozen.RequestedModel != strategy.SubagentModel || frozen.RequestedEffort != strategy.SubagentReasoningEffort ||
		frozen.ConcurrentThreads != strategy.MaximumConcurrentSubagents || frozen.RoleSHA256 == "" {
		return false
	}
	return frozen.RoleSHA256 == hashText(string(generatedPresetRole(frozen.RequestedModel, frozen.RequestedEffort)))
}

func executionPreferencesEqual(a, b executionPreference) bool {
	return reflect.DeepEqual(a, b)
}

func readManagerExecutionPreference(path string, accounts []AccountConfig, alias string) (executionPreference, error) {
	var accountHome string
	for _, account := range accounts {
		if account.Alias == alias {
			accountHome = filepath.Clean(account.Home)
			break
		}
	}
	if accountHome == "" {
		return executionPreference{}, errInvalid
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return executionPreference{}, errInvalid
	}
	var snapshot managerSnapshotFile
	if json.Unmarshal(data, &snapshot) != nil {
		return executionPreference{}, errInvalid
	}
	var matched *executionPreference
	matches := 0
	for _, profile := range snapshot.Profiles {
		if filepath.Clean(profile.CodexHomePath) != accountHome {
			continue
		}
		matches++
		matched = profile.ExecutionPreference
	}
	if matches != 1 {
		return executionPreference{}, errInvalid
	}
	return normalizedExecutionPreference(matched)
}

type managerAccountSnapshot struct {
	Email              string             `json:"email"`
	AccountID          string             `json:"accountID"`
	PlanType           string             `json:"planType"`
	FetchedAt          *float64           `json:"fetchedAt"`
	QuotaReadSucceeded *bool              `json:"quotaReadSucceeded"`
	FiveHour           managerUsageWindow `json:"fiveHour"`
	SevenDay           managerUsageWindow `json:"sevenDay"`
}

type managerUsageWindow struct {
	UsedPercent        *float64 `json:"usedPercent"`
	ResetsAt           *float64 `json:"resetsAt"`
	WindowDurationMins *float64 `json:"windowDurationMins"`
}

type managerOverview struct {
	Accounts  []managerAccountOverview `json:"accounts"`
	UpdatedAt time.Time                `json:"updatedAt"`
}

type managerAccountOverview struct {
	DispatchWindowOpen           bool       `json:"-"`
	Alias                        string     `json:"alias"`
	Email                        string     `json:"email,omitempty"`
	Plan                         string     `json:"plan"`
	FiveHourUsedPercent          *float64   `json:"fiveHourUsedPercent"`
	SevenDayUsedPercent          *float64   `json:"sevenDayUsedPercent"`
	FiveHourResetsAt             *time.Time `json:"fiveHourResetsAt"`
	SevenDayResetsAt             *time.Time `json:"sevenDayResetsAt"`
	FetchedAt                    *time.Time `json:"fetchedAt"`
	QuotaReadSucceeded           *bool      `json:"-"`
	LastQuotaReadFailureAt       *time.Time `json:"-"`
	AutomaticSwitchParticipation *bool      `json:"-"`
	Fresh                        bool       `json:"fresh"`
	Source                       string     `json:"source"`
	Status                       string     `json:"status,omitempty"`
}

func defaultManagerSnapshotPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "CodexAccountManagerNext", "account-manager-next-v1.json")
}

func readManagerOverview(path string, accounts []AccountConfig, now time.Time) (managerOverview, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return managerOverview{}, err
	}
	var snapshot managerSnapshotFile
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return managerOverview{}, err
	}
	info, err := os.Stat(path)
	if err != nil {
		return managerOverview{}, err
	}

	aliases := make(map[string]string, len(accounts))
	for _, account := range accounts {
		aliases[filepath.Clean(account.Home)] = account.Alias
	}
	overview := managerOverview{Accounts: make([]managerAccountOverview, 0, len(snapshot.Profiles)), UpdatedAt: info.ModTime().UTC()}
	managedAccountIDs := make(map[string]bool)
	managedEmails := make(map[string]bool)
	for _, profile := range snapshot.Profiles {
		if profile.IsSystemProfile || profile.LastSnapshot == nil {
			continue
		}
		if accountID := strings.TrimSpace(profile.LastSnapshot.AccountID); accountID != "" {
			managedAccountIDs[accountID] = true
		}
		if email := strings.ToLower(strings.TrimSpace(profile.LastSnapshot.Email)); email != "" {
			managedEmails[email] = true
		}
	}
	var latest time.Time
	for _, profile := range snapshot.Profiles {
		if profile.IsSystemProfile && profile.LastSnapshot != nil {
			accountID := strings.TrimSpace(profile.LastSnapshot.AccountID)
			email := strings.ToLower(strings.TrimSpace(profile.LastSnapshot.Email))
			if accountID != "" && managedAccountIDs[accountID] || email != "" && managedEmails[email] {
				continue
			}
		}
		alias, matched := aliases[filepath.Clean(profile.CodexHomePath)]
		source := "matched_alias"
		if !matched {
			alias = profile.Name
			if strings.Contains(alias, "@") {
				alias = maskEmail(alias)
			}
			source = "profile_name"
		}
		account := managerAccountOverview{
			Alias: alias, Source: source,
			DispatchWindowOpen:           profile.DispatchParticipationWindow.allows(now),
			AutomaticSwitchParticipation: profile.AutomaticSwitchParticipation,
			LastQuotaReadFailureAt:       appleReferenceTime(profile.LastQuotaReadFailureAt),
		}
		if profile.LastSnapshot == nil {
			account.Status = "暂无数据"
			overview.Accounts = append(overview.Accounts, account)
			continue
		}
		account.Plan = profile.LastSnapshot.PlanType
		account.Email = maskEmail(profile.LastSnapshot.Email)
		account.QuotaReadSucceeded = profile.LastSnapshot.QuotaReadSucceeded
		account.FiveHourUsedPercent = profile.LastSnapshot.FiveHour.UsedPercent
		account.SevenDayUsedPercent = profile.LastSnapshot.SevenDay.UsedPercent
		account.FiveHourResetsAt = appleReferenceTime(profile.LastSnapshot.FiveHour.ResetsAt)
		account.SevenDayResetsAt = appleReferenceTime(profile.LastSnapshot.SevenDay.ResetsAt)
		account.FetchedAt = appleReferenceTime(profile.LastSnapshot.FetchedAt)
		if account.FetchedAt != nil {
			age := now.UTC().Sub(*account.FetchedAt)
			account.Fresh = age >= -30*time.Minute && age <= 30*time.Minute
			if account.FetchedAt.After(latest) {
				latest = *account.FetchedAt
			}
		}
		overview.Accounts = append(overview.Accounts, account)
	}
	if !latest.IsZero() {
		overview.UpdatedAt = latest
	}
	return overview, nil
}

func appleReferenceTime(value *float64) *time.Time {
	if value == nil || math.IsNaN(*value) || math.IsInf(*value, 0) {
		return nil
	}
	seconds, fraction := math.Modf(*value)
	converted := time.Unix(int64(seconds)+appleEpochUnixOffset, int64(fraction*float64(time.Second))).UTC()
	return &converted
}

func maskEmail(value string) string {
	local, domain, ok := strings.Cut(strings.TrimSpace(value), "@")
	if !ok || local == "" || domain == "" {
		return ""
	}
	first := []rune(local)[0]
	return string(first) + "***@" + domain
}

var errManagerSnapshotUnavailable = errors.New("manager_snapshot_unavailable")
