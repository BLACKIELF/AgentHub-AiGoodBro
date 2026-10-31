package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The same lock is used by Next and the dispatch Skill. Acquire it before
// hub.mu: reservers may query Hub while they hold the shared file lock.

type dispatchActivityLease struct {
	LeaseID        string   `json:"leaseId"`
	Owner          string   `json:"ownerThreadId"`
	TaskID         string   `json:"taskId"`
	HubTaskID      string   `json:"hubTaskId"`
	AccountKey     string   `json:"accountKey"`
	AliasKey       string   `json:"aliasKey"`
	ProjectKey     string   `json:"projectKey"`
	Route          string   `json:"route"`
	State          string   `json:"state"`
	CreatedAt      *float64 `json:"createdAt"`
	UpdatedAt      *float64 `json:"updatedAt"`
	HeartbeatDueAt *float64 `json:"heartbeatDueAt"`
}

func activityState(state string) (active, valid bool) {
	switch state {
	case "preparing", "starting", "running", "cancel_requested", "uncertain":
		return true, true
	case "awaiting_acceptance", "accepted", "rejected", "failed", "cancelled":
		return false, true
	default:
		return false, false
	}
}

func (hub *Hub) readDispatchActivity() ([]dispatchActivityLease, error) {
	if hub.activityDirectory == "" {
		return nil, nil
	}
	f, err := openDispatchActivity(filepath.Join(hub.activityDirectory, "dispatch-activity-v1.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, errDispatchPolicyUnavailable
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 2*1024*1024+1))
	if err != nil || len(data) > 2*1024*1024 {
		return nil, errDispatchPolicyUnavailable
	}
	var snapshot struct {
		SchemaVersion int                     `json:"schemaVersion"`
		Leases        []dispatchActivityLease `json:"leases"`
	}
	if json.Unmarshal(data, &snapshot) != nil || snapshot.SchemaVersion != 1 || snapshot.Leases == nil || len(snapshot.Leases) > 2000 {
		return nil, errDispatchPolicyUnavailable
	}
	seen := map[string]bool{}
	for _, lease := range snapshot.Leases {
		_, valid := activityState(lease.State)
		if !valid || lease.LeaseID == "" || seen[lease.LeaseID] || lease.Owner == "" || lease.TaskID == "" {
			return nil, errDispatchPolicyUnavailable
		}
		seen[lease.LeaseID] = true
		for _, value := range []string{lease.AccountKey, lease.AliasKey, lease.ProjectKey} {
			decoded, err := hex.DecodeString(value)
			if err != nil || len(decoded) != 32 || strings.ToLower(value) != value {
				return nil, errDispatchPolicyUnavailable
			}
		}
		for _, value := range []*float64{lease.CreatedAt, lease.UpdatedAt, lease.HeartbeatDueAt} {
			if value == nil || math.IsNaN(*value) || math.IsInf(*value, 0) {
				return nil, errDispatchPolicyUnavailable
			}
		}
	}
	return snapshot.Leases, nil
}

func activityHash(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

// Account identity is hashed in memory only. Different configured aliases for
// the same account must share occupancy even when they use different homes.
func (hub *Hub) activityAccountKeys() (map[string]string, error) {
	keys := map[string]string{}
	if len(hub.config.Accounts) == 0 {
		return keys, nil
	}
	f, err := os.Open(hub.managerSnapshotPath)
	if err != nil {
		return nil, errDispatchPolicyUnavailable
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 2*1024*1024 {
		return nil, errDispatchPolicyUnavailable
	}
	data, err := io.ReadAll(io.LimitReader(f, 2*1024*1024+1))
	if err != nil || len(data) > 2*1024*1024 {
		return nil, errDispatchPolicyUnavailable
	}
	var snapshot managerSnapshotFile
	if json.Unmarshal(data, &snapshot) != nil || len(snapshot.Profiles) > 2000 {
		return nil, errDispatchPolicyUnavailable
	}
	for _, account := range hub.config.Accounts {
		matches := 0
		for _, profile := range snapshot.Profiles {
			if filepath.Clean(profile.CodexHomePath) != filepath.Clean(account.Home) {
				continue
			}
			matches++
			if profile.LastSnapshot != nil {
				if email := strings.ToLower(strings.TrimSpace(profile.LastSnapshot.Email)); email != "" {
					keys[account.Alias] = activityHash(email)
				}
			}
		}
		if matches != 1 {
			delete(keys, account.Alias)
		}
	}
	return keys, nil
}

func (hub *Hub) activityBusyAliases(excludingLeaseID string) (map[string]bool, error) {
	leases, err := hub.readDispatchActivity()
	if err != nil {
		return nil, err
	}
	busy := map[string]bool{}
	if len(leases) == 0 {
		return busy, nil
	}
	accountKeys, err := hub.activityAccountKeys()
	if err != nil {
		return nil, err
	}
	for _, account := range hub.config.Accounts {
		key := activityHash(strings.ToLower(strings.TrimSpace(account.Alias)))
		accountKey := accountKeys[account.Alias]
		if accountKey == "" {
			busy[account.Alias] = true
			continue
		}
		for _, lease := range leases {
			active, _ := activityState(lease.State)
			if active && lease.LeaseID != excludingLeaseID && (lease.AliasKey == key || lease.AccountKey == accountKey) {
				busy[account.Alias] = true
			}
		}
	}
	return busy, nil
}

func (hub *Hub) dispatchActivityAllowed(alias, project, leaseID, taskID string, now time.Time) error {
	leases, err := hub.readDispatchActivity()
	if err != nil {
		return err
	}
	root, err := filepath.EvalSymlinks(hub.config.Projects[project])
	if err != nil {
		return errDispatchPolicyUnavailable
	}
	aliasKey, projectKey := activityHash(strings.ToLower(strings.TrimSpace(alias))), activityHash(filepath.Clean(root))
	accountKey := ""
	if len(leases) > 0 && len(hub.config.Accounts) > 0 {
		keys, err := hub.activityAccountKeys()
		if err != nil || keys[alias] == "" {
			return errDispatchPolicyUnavailable
		}
		accountKey = keys[alias]
	}
	ownFound := leaseID == ""
	for _, lease := range leases {
		active, _ := activityState(lease.State)
		if lease.LeaseID == leaseID && leaseID != "" {
			// Exempt exactly one fresh Hub reservation bound to this account and
			// directory. After creation it must also be bound to this Hub task.
			if lease.State != "preparing" || lease.Route != "hub" || lease.AliasKey != aliasKey || lease.ProjectKey != projectKey ||
				(accountKey != "" && lease.AccountKey != accountKey) ||
				lease.State == "uncertain" || *lease.HeartbeatDueAt < float64(now.UnixNano())/1e9 || *lease.UpdatedAt > float64(now.UnixNano())/1e9+5 ||
				(taskID == "" && lease.HubTaskID != "") || (taskID != "" && lease.HubTaskID != taskID) {
				return errAccountBusy
			}
			ownFound = true
			continue
		}
		if active && (lease.AliasKey == aliasKey || (accountKey != "" && lease.AccountKey == accountKey) || lease.ProjectKey == projectKey) {
			return errAccountBusy
		}
	}
	if !ownFound {
		return errAccountBusy
	}
	return nil
}
