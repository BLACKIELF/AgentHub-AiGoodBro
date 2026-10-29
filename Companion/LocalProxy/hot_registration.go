package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/registry"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

func (s *selector) registeredIDs() []string {
	s.poolMu.RLock()
	defer s.poolMu.RUnlock()
	return append([]string(nil), s.order...)
}
func (rt *runtime) registeredIDs() []string {
	if rt.selector == nil {
		return append([]string(nil), rt.ids...)
	}
	return rt.selector.registeredIDs()
}
func (r *quotaRecovery) account(id string) *quotaRecoveryAccount {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.accounts[id]
}
func (n *networkRecovery) identity(id string) string {
	n.identityMu.RLock()
	defer n.identityMu.RUnlock()
	return n.identities[id]
}

// Refuse a residual cooldown instead of replaying RestoreCooldownStates over
// accounts that may currently be streaming. Hot registration never clears it.
func (s *cooldownStore) checkHotCooldown(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	f, err := s.root.OpenFile("cooldown.json", os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil && !os.IsNotExist(err) {
		return errors.New("cooldown_unavailable")
	}
	if err == nil {
		defer f.Close()
		info, err := f.Stat()
		if err != nil || !info.Mode().IsRegular() || info.Size() > 1<<20 {
			return errors.New("cooldown_unavailable")
		}
		var rows []safeCooldown
		if json.NewDecoder(io.LimitReader(f, (1<<20)+1)).Decode(&rows) != nil {
			return errors.New("cooldown_unavailable")
		}
		for _, row := range rows {
			if row.ID == id && (row.Until.After(time.Now()) || row.Recover.After(time.Now()) || (row.Independent != nil && (row.Independent.Status == auth.StatusDisabled || row.Independent.Until.After(time.Now()) || row.Independent.Recover.After(time.Now())))) {
				return errors.New("cooldown_pending")
			}
		}
	}
	return nil
}

// stdin is the inherited, host-owned control pipe. No credentials are accepted
// here: a placeholder becomes eligible only after the host acknowledges this
// exact run/identity and includes it in a later request's membership snapshot.
func (rt *runtime) registerAccount(c networkCommand, out *events) {
	response := event{Event: "account_registered", RunID: c.RunID, RequestID: c.RequestID, ProfileID: c.ProfileID, IdentityHash: c.IdentityHash, State: "rejected"}
	// Emit only after admission/model locks are released. A stalled stdout
	// reader must never block shutdown or active request model registration.
	defer func() { out.emit(response) }()
	if c.Command != "register_account" || c.RunID != rt.runID || !identifier.MatchString(c.ProfileID) || !identityDigest.MatchString(c.IdentityHash) {
		response.ErrorCode = "identity"
		return
	}
	if _, err := uuid.Parse(c.RequestID); err != nil {
		response.ErrorCode = "identity"
		return
	}
	rt.modelMu.Lock()
	defer rt.modelMu.Unlock()
	rt.gate.Lock()
	defer rt.gate.Unlock()
	if rt.stopping {
		response.ErrorCode = "stopping"
		return
	}
	identity := strings.ToLower(c.IdentityHash)
	ids := rt.registeredIDs()
	for _, id := range ids {
		known := rt.network.identity(id)
		if id == c.ProfileID {
			if known == identity {
				response.State = "registered"
			} else {
				response.ErrorCode = "identity"
			}
			return
		}
		if known == identity {
			response.ErrorCode = "duplicate_identity"
			return
		}
	}
	if len(ids) >= 100 {
		response.ErrorCode = "pool_full"
		return
	}
	if _, exists := rt.manager.GetByID(c.ProfileID); exists {
		response.ErrorCode = "identity"
		return
	}
	if err := rt.store.checkHotCooldown(c.ProfileID); err != nil {
		response.ErrorCode = err.Error()
		return
	}
	if _, err := rt.manager.Register(context.Background(), &auth.Auth{ID: c.ProfileID, Provider: "codex", Status: auth.StatusActive, Attributes: map[string]string{"priority": "0"}, Metadata: map[string]any{"type": "codex"}, Runtime: noRefresh{}}); err != nil {
		rt.manager.Remove(context.Background(), c.ProfileID)
		response.ErrorCode = "registration_failed"
		return
	}
	// Only successful registration binds the cooldown identity. A failed
	// manager mutation leaves neither a host-admissible ID nor a new binding.
	rt.store.mu.Lock()
	if rt.store.identities == nil {
		rt.store.identities = map[string]string{}
	}
	rt.store.identities[c.ProfileID] = identity
	rt.store.mu.Unlock()
	models := make([]*registry.ModelInfo, 0, len(rt.models))
	for _, model := range rt.models {
		models = append(models, model)
	}
	rt.recovery.mu.Lock()
	rt.recovery.accounts[c.ProfileID] = &quotaRecoveryAccount{}
	rt.recovery.mu.Unlock()
	rt.network.identityMu.Lock()
	rt.network.identities[c.ProfileID] = identity
	rt.network.identityMu.Unlock()
	registry.GetGlobalRegistry().RegisterClient(c.ProfileID, "codex", models)
	rt.manager.RefreshSchedulerEntry(c.ProfileID)
	rt.manager.SetRetryConfig(0, 0, len(ids)+1)
	rt.selector.poolMu.Lock()
	rt.selector.order = append(rt.selector.order, c.ProfileID)
	rt.selector.poolMu.Unlock()
	response.State = "registered"
}
