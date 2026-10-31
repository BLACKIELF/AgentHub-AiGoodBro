package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"time"
)

// Native-only projection. Neither this binding nor auth bytes are a TaskDTO.
type desktopAccountBinding struct {
	AuthSHA256            string `json:"authSha256"`
	CredentialExpiresAtMs int64  `json:"credentialExpiresAtMs"`
	QuotaObservedAtMs     int64  `json:"quotaObservedAtMs"`
	IdentityHash          string `json:"identityHash"`
	WorkflowRevision      uint64 `json:"workflowRevision"`
}
type desktopTaskBinding struct {
	Home             string `json:"home"`
	IdentityHash     string `json:"identityHash"`
	WorkflowRevision uint64 `json:"workflowRevision"`
}

func (hub *Hub) desktopBindingEnabled() bool {
	return hub.config.WorkflowPreferencesPath != "" || hub.config.WorkflowCatalogPath != "" || hub.config.WorkflowProfileID != 0
}
func lowerSHA(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func sameDesktopDirectory(left, right string) bool {
	if !filepath.IsAbs(left) || !filepath.IsAbs(right) {
		return false
	}
	l, e := os.Stat(left)
	r, f := os.Stat(right)
	return e == nil && f == nil && l.IsDir() && r.IsDir() && os.SameFile(l, r)
}

// Hold all admitted inputs through spawn on Windows. Missing, stale, remapped,
// replaced or concurrently writable inputs fail closed, without refreshing or
// making a network request from the Hub.
func (hub *Hub) readDesktopBinding(task *Task) (*desktopTaskBinding, *desktopAccountBinding, func(), error) {
	var releases []func()
	release := func() {
		for i := len(releases) - 1; i >= 0; i-- {
			releases[i]()
		}
	}
	fail := func() (*desktopTaskBinding, *desktopAccountBinding, func(), error) {
		release()
		return nil, nil, nil, errDispatchPolicyUnavailable
	}
	if hub.config.WorkflowPreferencesPath == "" || hub.config.WorkflowCatalogPath == "" || hub.config.WorkflowProfileID == 0 || task == nil {
		return fail()
	}
	read := func(path string, private bool) ([]byte, error) {
		file, close, err := openDesktopSource(path, private)
		if err != nil {
			return nil, err
		}
		releases = append(releases, close)
		data, err := io.ReadAll(io.LimitReader(file, 2*1024*1024+1))
		if err != nil || len(data) > 2*1024*1024 {
			return nil, errDispatchPolicyUnavailable
		}
		return data, nil
	}
	workflowData, err := read(hub.config.WorkflowPreferencesPath, false)
	if err != nil {
		return fail()
	}
	workflow, err := decodeDesktopWorkflow(workflowData, hub.config.WorkflowProfileID)
	if err != nil {
		return fail()
	}
	if err = workflow.allows(task, time.Now()); err != nil {
		release()
		return nil, nil, nil, err
	}
	home, err := hub.accountHome(task.AccountAlias)
	if err != nil || task.AccountAlias == "system" {
		return fail()
	}
	catalogData, err := read(hub.config.WorkflowCatalogPath, false)
	if err != nil {
		return fail()
	}
	// Other settings are unrelated; require the one current Codex profile by ID.
	var catalog struct {
		Profiles struct {
			Entries []struct {
				ID   uint64  `json:"id"`
				Root string  `json:"root"`
				Kind *string `json:"kind"`
			} `json:"entries"`
		} `json:"profiles"`
	}
	if json.Unmarshal(catalogData, &catalog) != nil {
		return fail()
	}
	matches := 0
	for _, entry := range catalog.Profiles.Entries {
		if entry.ID == hub.config.WorkflowProfileID {
			matches++
			if entry.Kind != nil && *entry.Kind != "codex" || !sameDesktopDirectory(entry.Root, home) {
				return fail()
			}
		}
	}
	if matches != 1 {
		return fail()
	}
	managerData, err := read(hub.managerSnapshotPath, true)
	if err != nil {
		return fail()
	}
	var manager managerSnapshotFile
	if json.Unmarshal(managerData, &manager) != nil {
		return fail()
	}
	var profile *managerProfile
	for i := range manager.Profiles {
		p := &manager.Profiles[i]
		if p.Name == task.AccountAlias {
			if profile != nil {
				return fail()
			}
			profile = p
		}
	}
	if profile == nil || profile.IsSystemProfile || !sameDesktopDirectory(profile.CodexHomePath, home) || profile.WindowsBinding == nil || profile.LastSnapshot == nil {
		return fail()
	}
	binding := *profile.WindowsBinding
	now := time.Now().UnixMilli()
	if !lowerSHA(binding.AuthSHA256) || !lowerSHA(binding.IdentityHash) || binding.CredentialExpiresAtMs <= now+30000 || binding.QuotaObservedAtMs > now+5000 || binding.QuotaObservedAtMs < now-45000 || binding.WorkflowRevision != *workflow.Revision {
		return fail()
	}
	observed := appleReferenceTime(profile.LastSnapshot.FetchedAt)
	if observed == nil || observed.UnixMilli() != binding.QuotaObservedAtMs || profile.LastSnapshot.QuotaReadSucceeded == nil || !*profile.LastSnapshot.QuotaReadSucceeded {
		return fail()
	}
	// Match AccountIdentity::identity_hash: the native writer already normalized email.
	accountIDHash := sha256.Sum256([]byte(profile.LastSnapshot.Email + "\x00" + profile.LastSnapshot.AccountID))
	if profile.LastSnapshot.Email == "" || profile.LastSnapshot.AccountID == "" || hex.EncodeToString(accountIDHash[:]) != binding.IdentityHash {
		return fail()
	}
	// The native writer proves JWT identity. A changed actual auth file must go
	// through that writer again; the Hub cannot accept a replacement by its name.
	auth, err := read(filepath.Join(home, "auth.json"), true)
	if err != nil {
		return fail()
	}
	hash := sha256.Sum256(auth)
	if hex.EncodeToString(hash[:]) != binding.AuthSHA256 {
		return fail()
	}
	frozen := &desktopTaskBinding{Home: filepath.Clean(home), IdentityHash: binding.IdentityHash, WorkflowRevision: binding.WorkflowRevision}
	return frozen, &binding, release, nil
}

func (hub *Hub) freezeDesktopTask(task *Task) error {
	if !hub.desktopBindingEnabled() {
		return nil
	}
	frozen, _, release, err := hub.readDesktopBinding(task)
	if err != nil {
		return err
	}
	defer release()
	task.DesktopBinding = frozen
	return nil
}
func (hub *Hub) approveDesktopTask(task *Task) error {
	if !hub.desktopBindingEnabled() {
		return nil
	}
	frozen, binding, release, err := hub.readDesktopBinding(task)
	if err != nil {
		return err
	}
	defer release()
	if task.DesktopBinding == nil || *task.DesktopBinding != *frozen {
		return errDispatchPolicyUnavailable
	}
	// Same identity may have refreshed credentials/official quota after create.
	// Freeze those exact verified inputs at approval, never at final spawn.
	task.DesktopApproval = binding
	return nil
}
func (hub *Hub) lockDesktopSpawn(task *Task) (func(), error) {
	if !hub.desktopBindingEnabled() {
		return func() {}, nil
	}
	frozen, binding, release, err := hub.readDesktopBinding(task)
	if err != nil {
		return nil, err
	}
	if task.DesktopBinding == nil || task.DesktopApproval == nil || *task.DesktopBinding != *frozen || *task.DesktopApproval != *binding {
		release()
		return nil, errDispatchPolicyUnavailable
	}
	if !hub.approvalQuotaReadyLocked(task.AccountAlias, time.Now().UTC()) {
		release()
		return nil, errAccountQuotaReserve
	}
	return release, nil
}
