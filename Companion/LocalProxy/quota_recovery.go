package main

import (
	"context"
	"math"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

// The SDK filters cooling credentials before our selector sees them. A fresh,
// identity-checked host observation must therefore reconcile stale quota before
// SDK selection. This never refreshes credentials or changes participation.
type quotaRecovery struct {
	mu       sync.RWMutex
	accounts map[string]*quotaRecoveryAccount
	manager  *auth.Manager
}

type quotaRecoveryAccount struct {
	mu              sync.Mutex
	active          int
	nextCheck       time.Time
	egressNextCheck time.Time
	egressProbing   bool
}

const quotaResultLockKey = "aigoodbro.quota-result-lock"
const credentialQuotaErrorCode = "aigoodbro_credential_quota"

type quotaResultLock struct {
	once    sync.Once
	account *quotaRecoveryAccount
}

func newQuotaRecovery(ids []string) *quotaRecovery {
	r := &quotaRecovery{accounts: make(map[string]*quotaRecoveryAccount, len(ids))}
	for _, id := range ids {
		r.accounts[id] = &quotaRecoveryAccount{}
	}
	return r
}

// Serialize ResetQuota with SDK MarkResult, including late streaming failures
// after an HTTP client has disconnected. Metadata is copied and the private
// marker exists only on the post-execution result, never an upstream request.
func (r *quotaRecovery) ApplyResultPolicy(_ context.Context, result auth.Result) auth.Result {
	account := r.account(result.AuthID)
	if account == nil {
		return result
	}
	account.mu.Lock()
	metadata := make(map[string]any, len(result.Options.Metadata)+1)
	for key, value := range result.Options.Metadata {
		metadata[key] = value
	}
	metadata[quotaResultLockKey] = &quotaResultLock{account: account}
	if r.manager != nil {
		if a, ok := r.manager.GetByID(result.AuthID); ok {
			priorQuota := a.Quota.Exceeded
			if ms := a.ModelStates[networkModelKey(result.Model)]; ms != nil {
				priorQuota = priorQuota || ms.Quota.Exceeded
			}
			metadata["aigoodbro.egress-prior-quota"] = priorQuota
		}
	}
	result.Options.Metadata = metadata
	if !result.Success {
		if result.Error == nil {
			result.Error = &auth.Error{}
		} else if result.CredentialScope && result.Error.HTTPStatus == 429 {
			// Exact matching deadlines are not sufficient evidence: an ordinary
			// model 429 may inherit the credential's longer retry deadline. Keep
			// only this local provenance marker, without changing the caller's error.
			switch result.Error.Code {
			case auth.ErrorCodeRequestScoped, auth.ErrorCodeForceCooldown, auth.ErrorCodeConnectionLifecycle, auth.ErrorCodeTransientTransport:
				// Preserve SDK policy classifications, even for malformed results.
			default:
				failure := *result.Error
				failure.Code = credentialQuotaErrorCode
				result.Error = &failure
			}
		}
	}
	return result
}

func finishQuotaResult(result auth.Result) {
	if held, ok := result.Options.Metadata[quotaResultLockKey].(*quotaResultLock); ok {
		held.once.Do(held.account.mu.Unlock)
	}
}

func (s *requestScope) reserveQuotaAccount(id string) {
	if s.recovery == nil {
		return
	}
	account := s.recovery.account(id)
	if account == nil {
		return
	}
	account.mu.Lock()
	defer account.mu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.recoveryReserved == nil {
		s.recoveryReserved = map[string]bool{}
	}
	if !s.recoveryReserved[id] {
		s.recoveryReserved[id] = true
		account.active++
	}
}

func (s *requestScope) releaseQuotaAccounts() {
	if s.recovery == nil {
		return
	}
	s.mu.Lock()
	ids := s.recoveryReserved
	s.recoveryReserved = nil
	s.mu.Unlock()
	for id := range ids {
		account := s.recovery.account(id)
		account.mu.Lock()
		account.active--
		account.mu.Unlock()
	}
}

// ResetQuota is deliberately all-or-nothing in the SDK. Only use it when every
// active error belongs to the same credential-wide quota, preserving unrelated
// model limits, transient backoff, permission failures and disabled identities.
func quotaRecoveryCutoff(a *auth.Auth, now time.Time) (time.Time, bool) {
	if a == nil || a.Disabled || a.Status == auth.StatusDisabled || !a.Quota.Exceeded || a.Quota.Reason != "credential_quota" || !a.Quota.NextRecoverAt.After(now) || !a.NextRetryAfter.Equal(a.Quota.NextRecoverAt) {
		return time.Time{}, false
	}
	if !isCredentialQuotaError(a.LastError) {
		return time.Time{}, false
	}
	cutoff := a.UpdatedAt
	for _, state := range a.ModelStates {
		if state == nil {
			continue
		}
		if state.Status == auth.StatusDisabled {
			return time.Time{}, false
		}
		if !state.NextRetryAfter.After(now) && !state.Quota.NextRecoverAt.After(now) {
			continue
		}
		if !state.Quota.Exceeded || !state.NextRetryAfter.Equal(a.Quota.NextRecoverAt) || !state.Quota.NextRecoverAt.Equal(a.Quota.NextRecoverAt) {
			return time.Time{}, false
		}
		if state.Quota.Reason != "credential_quota" && state.Quota.Reason != "quota" {
			return time.Time{}, false
		}
		if state.LastError == nil {
			// The SDK propagates credential quota to previously clean sibling
			// models without creating an error. Legacy absence is restored as
			// unknown instead, so identical deadlines cannot prove provenance.
			if state.Quota.Reason != "credential_quota" {
				return time.Time{}, false
			}
		} else if !isCredentialQuotaError(state.LastError) {
			return time.Time{}, false
		}
		if state.UpdatedAt.After(cutoff) {
			cutoff = state.UpdatedAt
		}
	}
	return cutoff, !cutoff.IsZero()
}

func isCredentialQuotaError(err *auth.Error) bool {
	return err != nil && err.HTTPStatus == 429 && err.Code == credentialQuotaErrorCode
}

func quotaProofObserved(reply bridgeReply, now time.Time) (time.Time, bool) {
	if !reply.OK || reply.Error != "" || reply.LeaseID != "" || reply.AccessToken != "" || reply.AccountID != "" || reply.ExpiresAt != 0 || reply.Resolution != "" || reply.RetryAt != 0 || reply.CreditFallback || len(reply.Order) != 0 || len(reply.LastResortIDs) != 0 || len(reply.DeferredIDs) != 0 || reply.ProbeStatus != "" || reply.ProbeObservedAt != 0 || reply.ProbeIdentityHash != "" || math.IsNaN(reply.QuotaObservedAt) || math.IsInf(reply.QuotaObservedAt, 0) {
		return time.Time{}, false
	}
	// Bound the float before converting to nanoseconds, including hostile or
	// malformed values outside int64. The host must supply recent evidence.
	if reply.QuotaObservedAt <= 0 || reply.QuotaObservedAt > float64(now.Add(5*time.Second).UnixNano())/1e9 || reply.QuotaObservedAt < float64(now.Add(-5*time.Minute).UnixNano())/1e9 {
		return time.Time{}, false
	}
	return time.Unix(0, int64(reply.QuotaObservedAt*1e9)), true
}

func (rt *runtime) reconcileQuota(ctx context.Context) {
	if rt.recovery == nil {
		return
	}
	scope := scopeFrom(ctx)
	if scope == nil {
		return
	}
	// Recovery is a bounded read-only preflight for this request, even when
	// several accounts need evidence and the host control channel is stalled.
	proofContext, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	for _, id := range rt.registeredIDs() {
		if proofContext.Err() != nil {
			return
		}
		account := rt.recovery.account(id)
		if !account.mu.TryLock() {
			continue
		}
		now := time.Now()
		a, _ := rt.manager.GetByID(id)
		_, recoverable := quotaRecoveryCutoff(a, now)
		if !recoverable || account.active != 0 || now.Before(account.nextCheck) || rt.store.hasIndependentCooldown(id, now) {
			account.mu.Unlock()
			continue
		}
		account.nextCheck = now.Add(time.Minute)
		account.mu.Unlock()
		reply, err := rt.selector.bridge.call(proofContext, "quota_recovery", scope.id, id, "")
		if err != nil {
			continue
		}
		if !account.mu.TryLock() {
			continue // An SDK result began while the host evidence was pending.
		}
		now = time.Now()
		observed, valid := quotaProofObserved(reply, now)
		a, _ = rt.manager.GetByID(id)
		cutoff, recoverable := quotaRecoveryCutoff(a, now)
		if proofContext.Err() == nil && account.active == 0 && recoverable && valid && observed.After(cutoff) && !rt.store.hasIndependentCooldown(id, now) {
			if _, _, resetErr := rt.manager.ResetQuota(ctx, id); resetErr == nil {
				rt.selector.events.emit(event{Event: "account", ProfileID: id, State: "ready"})
			}
		}
		account.mu.Unlock()
	}
}

func (rt *runtime) withQuotaRecovery(next gin.HandlerFunc) gin.HandlerFunc {
	return func(c *gin.Context) {
		rt.reconcileQuota(c.Request.Context())
		next(c)
	}
}

func (rt *runtime) emitRestoredCooldowns() {
	for _, id := range rt.registeredIDs() {
		a, ok := rt.manager.GetByID(id)
		if !ok {
			continue
		}
		until := a.NextRetryAfter
		for _, state := range a.ModelStates {
			if state != nil && state.NextRetryAfter.After(until) {
				until = state.NextRetryAfter
			}
		}
		if !until.After(time.Now()) {
			continue
		}
		if rt.network != nil {
			egress := false
			for _, ms := range a.ModelStates {
				if egressModel(ms) {
					egress = true
					break
				}
			}
			if egress {
				rt.network.emitAccount(a, "waiting")
				continue
			}
		}
		state := "temporary_error"
		if a.Quota.Exceeded {
			state = "quota"
		}
		rt.selector.events.emit(event{Event: "account", ProfileID: id, State: state, CooldownUntil: until.Unix()})
	}
}
