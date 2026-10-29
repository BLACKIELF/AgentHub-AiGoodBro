package main

import (
	"context"
	"errors"
	"math"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/registry"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/thinking"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

const egressErrorCode = "aigoodbro_egress_forbidden"

var identityDigest = regexp.MustCompile(`^[a-fA-F0-9]{64}$`)

type networkCommand struct {
	Command      string `json:"command"`
	RunID        string `json:"runID,omitempty"`
	IdentityHash string `json:"identityHash,omitempty"`
	ProfileID    string `json:"profileID,omitempty"`
	RequestID    string `json:"requestID,omitempty"`
}

type forbiddenObservation struct {
	id, model, identity        string
	at, until                  time.Time
	generation, epoch, version uint64
}

type networkRecovery struct {
	rt                     *runtime
	events                 *events
	settings               egressSettings
	identityMu             sync.RWMutex
	identities             map[string]string
	ctx                    context.Context
	cancel                 context.CancelFunc
	mu                     sync.Mutex
	streaks                map[string][]forbiddenObservation
	pending                map[string]forbiddenObservation
	wake                   chan struct{}
	gate                   sync.Mutex
	started, stopped       bool
	work                   sync.WaitGroup
	watchdogMu             sync.Mutex
	probeEvery, watchEvery time.Duration
}

func newNetworkRecovery(rt *runtime, s startup, e *events) *networkRecovery {
	ctx, cancel := context.WithCancel(context.Background())
	identities := make(map[string]string, len(s.AccountIdentityHashes))
	for id, hash := range s.AccountIdentityHashes {
		identities[id] = strings.ToLower(hash)
	}
	return &networkRecovery{rt: rt, events: e, settings: s.Egress, identities: identities, ctx: ctx, cancel: cancel, streaks: map[string][]forbiddenObservation{}, pending: map[string]forbiddenObservation{}, wake: make(chan struct{}, 1), probeEvery: 2 * time.Minute, watchEvery: 3 * time.Minute}
}

// The result policy holds this account's lock through OnResult. Never acquire
// another account lock here: results on different accounts can finish together.
func (n *networkRecovery) observe(r auth.Result) {
	if n == nil || r.Model == "" {
		return
	}
	a, ok := n.rt.manager.GetByID(r.AuthID)
	if !ok || (r.CredentialVersion != 0 && r.CredentialVersion != a.CredentialVersion) || (r.RegistrationEpoch != 0 && r.RegistrationEpoch != a.RegistrationEpoch) {
		return
	}
	model := networkModelKey(r.Model)
	ms := a.ModelStates[model]
	priorQuota, _ := r.Options.Metadata["aigoodbro.egress-prior-quota"].(bool)
	valid := !r.Success && plainForbidden(r.Error) && plainForbidden(errorForModel(ms)) && ms.NextRetryAfter.After(time.Now()) && (!ms.Quota.Exceeded || (ms.Quota.Reason == "cloudflare challenge" && !priorQuota)) && !a.Disabled && a.Status != auth.StatusDisabled && identityDigest.MatchString(n.identity(r.AuthID))
	n.mu.Lock()
	defer n.mu.Unlock()
	if !valid {
		delete(n.streaks, model)
		return
	}
	now := time.Now()
	observation := forbiddenObservation{id: r.AuthID, model: model, identity: n.identity(r.AuthID), at: ms.UpdatedAt, until: ms.UpdatedAt.Add(5 * time.Minute), generation: a.Generation, epoch: a.RegistrationEpoch, version: a.CredentialVersion}
	streak := n.streaks[model][:0]
	for _, prior := range n.streaks[model] {
		if now.Sub(prior.at) <= time.Minute && prior.id != r.AuthID {
			streak = append(streak, prior)
		}
	}
	streak = append(streak, observation)
	n.streaks[model] = streak
	unique := map[string]bool{}
	for _, prior := range streak {
		unique[prior.identity] = true
	}
	if len(unique) < 3 {
		return
	}
	for _, prior := range streak {
		n.pending[prior.id+"\x00"+model] = prior
	}
	select {
	case n.wake <- struct{}{}:
	default:
	}
}

func networkModelKey(model string) string {
	model = strings.TrimSpace(model)
	if parsed := strings.TrimSpace(thinking.ParseSuffix(model).ModelName); parsed != "" {
		return parsed
	}
	return model
}

func errorForModel(ms *auth.ModelState) *auth.Error {
	if ms == nil {
		return nil
	}
	return ms.LastError
}
func plainForbidden(e *auth.Error) bool {
	if e == nil || e.HTTPStatus != 403 || e.IsRequestScoped() {
		return false
	}
	switch e.Code {
	case auth.ErrorCodeForceCooldown, auth.ErrorCodeConnectionLifecycle, auth.ErrorCodeTransientTransport:
		return false
	}
	return true
}
func egressModel(ms *auth.ModelState) bool {
	return ms != nil && ms.Status != auth.StatusDisabled && ms.LastError != nil && ms.LastError.HTTPStatus == 403 && ms.LastError.Code == egressErrorCode && !ms.Quota.Exceeded
}
func sameAuthVersion(a *auth.Auth, generation, epoch, version uint64) bool {
	return a != nil && !a.Disabled && a.Status != auth.StatusDisabled && a.Generation == generation && a.RegistrationEpoch == epoch && a.CredentialVersion == version
}

func (n *networkRecovery) applyPending() bool {
	n.mu.Lock()
	pending := n.pending
	n.pending = map[string]forbiddenObservation{}
	n.mu.Unlock()
	changed := false
	for _, o := range pending {
		if n.ctx.Err() != nil {
			break
		}
		account := n.rt.recovery.account(o.id)
		if account == nil {
			continue
		}
		account.mu.Lock()
		a, _ := n.rt.manager.GetByID(o.id)
		if !sameAuthVersion(a, o.generation, o.epoch, o.version) {
			account.mu.Unlock()
			continue
		}
		ms := a.ModelStates[o.model]
		if ms == nil || !plainForbidden(ms.LastError) || (ms.Quota.Exceeded && ms.Quota.Reason != "cloudflare challenge") || !ms.UpdatedAt.Equal(o.at) || !ms.NextRetryAfter.After(time.Now()) {
			account.mu.Unlock()
			continue
		}
		ms.NextRetryAfter = minTime(ms.NextRetryAfter, o.until)
		failure := *ms.LastError
		failure.Code = egressErrorCode
		ms.LastError = &failure
		if ms.Quota.Reason == "cloudflare challenge" {
			ms.Quota.Exceeded = false
			ms.Quota.Reason = ""
			ms.Quota.NextRecoverAt = time.Time{}
			ms.Quota.BackoffLevel = 0
			otherQuota := false
			for _, sibling := range a.ModelStates {
				if sibling != nil && sibling.Quota.Exceeded {
					otherQuota = true
				}
			}
			if !otherQuota && a.Quota.Reason == "quota" {
				a.Quota.Exceeded = false
				a.Quota.Reason = ""
				a.Quota.NextRecoverAt = time.Time{}
				a.Quota.BackoffLevel = 0
			}
		}
		if plainForbidden(a.LastError) && a.UpdatedAt.Equal(o.at) {
			f := *a.LastError
			f.Code = egressErrorCode
			a.LastError = &f
		}
		updateEgressAvailability(a)
		updated, err := n.commitVerified(n.ctx, a)
		if err == nil && updated != nil {
			n.rt.manager.PersistCooldownStates(n.ctx)
			n.emitAccount(updated, "waiting")
			changed = true
		}
		account.mu.Unlock()
	}
	return changed
}

func (n *networkRecovery) commitVerified(ctx context.Context, edited *auth.Auth) (*auth.Auth, error) {
	updated, committed, err := n.rt.manager.Modify(ctx, edited.ID, edited.RegistrationEpoch, func(current *auth.Auth) error {
		if !sameAuthVersion(current, edited.Generation, edited.RegistrationEpoch, edited.CredentialVersion) {
			return errors.New("egress_state_changed")
		}
		*current = *edited
		return nil
	})
	if err != nil || !committed {
		return nil, errors.New("egress_state_changed")
	}
	return updated, nil
}

func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}

// Recompute only availability derived from model states. Quota and independent
// auth failures remain untouched; an empty model map must never reach Update.
func updateEgressAvailability(a *auth.Auth) {
	if a.Quota.Exceeded || a.Disabled || a.Status == auth.StatusDisabled || (a.LastError != nil && a.LastError.HTTPStatus == 401) {
		return
	}
	if len(a.ModelStates) == 0 {
		return
	}
	allUnavailable := true
	earliest := time.Time{}
	var latest *auth.ModelState
	for _, ms := range a.ModelStates {
		if ms == nil {
			continue
		}
		if ms.Status != auth.StatusDisabled && (!ms.Unavailable || !ms.NextRetryAfter.After(time.Now())) {
			allUnavailable = false
		}
		if ms.Unavailable && ms.NextRetryAfter.After(time.Now()) && (earliest.IsZero() || ms.NextRetryAfter.Before(earliest)) {
			earliest = ms.NextRetryAfter
		}
		if ms.LastError != nil && (latest == nil || ms.UpdatedAt.After(latest.UpdatedAt)) {
			latest = ms
		}
	}
	a.Unavailable = allUnavailable
	if allUnavailable {
		a.NextRetryAfter = earliest
	} else {
		a.NextRetryAfter = time.Time{}
	}
	if a.LastError != nil && a.LastError.Code == egressErrorCode {
		if latest == nil {
			a.LastError = nil
			a.StatusMessage = ""
			a.Status = auth.StatusActive
		} else {
			e := *latest.LastError
			a.LastError = &e
			a.StatusMessage = latest.StatusMessage
		}
	}
}

func (n *networkRecovery) emitAccount(a *auth.Auth, probe string) {
	if a == nil {
		return
	}
	v := event{Event: "account", ProfileID: a.ID, State: "ready"}
	if a.LastError != nil {
		v.State = "temporary_error"
		if a.LastError.HTTPStatus == 401 {
			v.State = "login_expired"
		}
	}
	if a.Quota.Exceeded {
		v.State = "quota"
	}
	until := a.NextRetryAfter
	for _, ms := range a.ModelStates {
		if ms == nil {
			continue
		}
		if ms.NextRetryAfter.After(until) {
			until = ms.NextRetryAfter
		}
		if egressModel(ms) {
			v.CooldownKind = "egress"
			v.ProbeState = probe
			if v.State == "ready" {
				v.State = "temporary_error"
			}
		}
	}
	if until.After(time.Now()) {
		v.CooldownUntil = until.Unix()
	}
	n.events.emit(v)
}

func egressProofObserved(reply bridgeReply, identity string, started, now time.Time) (time.Time, bool) {
	if !reply.OK || reply.Error != "" || reply.LeaseID != "" || reply.AccessToken != "" || reply.AccountID != "" || reply.ExpiresAt != 0 || reply.Resolution != "" || reply.RetryAt != 0 || reply.CreditFallback || len(reply.Order) != 0 || len(reply.LastResortIDs) != 0 || len(reply.DeferredIDs) != 0 || reply.QuotaObservedAt != 0 || !identityDigest.MatchString(reply.ProbeIdentityHash) || !strings.EqualFold(reply.ProbeIdentityHash, identity) || math.IsNaN(reply.ProbeObservedAt) || math.IsInf(reply.ProbeObservedAt, 0) {
		return time.Time{}, false
	}
	if reply.ProbeStatus != "reachable" && reply.ProbeStatus != "unreachable" && reply.ProbeStatus != "unauthorized" {
		return time.Time{}, false
	}
	if reply.ProbeObservedAt <= 0 || reply.ProbeObservedAt > float64(now.Add(time.Second).UnixNano())/1e9 || reply.ProbeObservedAt < float64(now.Add(-2*time.Minute).UnixNano())/1e9 {
		return time.Time{}, false
	}
	observed := time.Unix(0, int64(reply.ProbeObservedAt*1e9))
	return observed, !observed.Before(started.Add(-time.Millisecond))
}

func (n *networkRecovery) probeAccounts(ctx context.Context, profile string, force bool) {
	bounded, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	var work sync.WaitGroup
	defer work.Wait()
	// Match the host's two read-only credential probe slots. Queue the rest
	// here so a pool-wide recovery does not turn healthy accounts into busy.
	slots := make(chan struct{}, 2)
	for _, id := range n.rt.registeredIDs() {
		if bounded.Err() != nil {
			return
		}
		if profile != "" && id != profile {
			continue
		}
		select {
		case slots <- struct{}{}:
		case <-bounded.Done():
			return
		}
		work.Add(1)
		go func(id string) { defer work.Done(); defer func() { <-slots }(); n.probeAccount(bounded, id, force) }(id)
	}
}
func (n *networkRecovery) probeAccount(ctx context.Context, id string, force bool) {
	account := n.rt.recovery.account(id)
	if account == nil || !identityDigest.MatchString(n.identity(id)) {
		return
	}
	if _, err := uuid.Parse(id); err != nil {
		return
	}
	if !account.mu.TryLock() {
		return
	}
	before, _ := n.rt.manager.GetByID(id)
	models := map[string]time.Time{}
	if before != nil && !before.Disabled && before.Status != auth.StatusDisabled {
		for model, ms := range before.ModelStates {
			if egressModel(ms) {
				models[model] = ms.UpdatedAt
			}
		}
	}
	if len(models) == 0 || account.egressProbing || account.active != 0 || (!force && time.Now().Before(account.egressNextCheck)) {
		account.mu.Unlock()
		return
	}
	account.egressProbing = true
	account.egressNextCheck = time.Now().Add(2 * time.Minute)
	n.emitAccount(before, "probing")
	account.mu.Unlock()
	started := time.Now()
	proofCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	reply, err := n.rt.selector.bridge.call(proofCtx, "egress_probe", uuid.NewString(), id, "")
	validContext := proofCtx.Err() == nil
	cancel()
	account.mu.Lock()
	defer account.mu.Unlock()
	account.egressProbing = false
	current, _ := n.rt.manager.GetByID(id)
	observed, valid := egressProofObserved(reply, n.identity(id), started, time.Now())
	if err != nil || !validContext || ctx.Err() != nil || !valid || reply.ProbeStatus != "reachable" {
		n.emitAccount(current, "failed")
		return
	}
	if account.active != 0 || !sameAuthVersion(current, before.Generation, before.RegistrationEpoch, before.CredentialVersion) {
		n.emitAccount(current, "waiting")
		return
	}
	recovered := []string{}
	for model, cutoff := range models {
		ms := current.ModelStates[model]
		if !egressModel(ms) || !ms.UpdatedAt.Equal(cutoff) || !observed.After(cutoff) {
			continue
		}
		ms.Status = auth.StatusActive
		ms.StatusMessage = ""
		ms.Unavailable = false
		ms.NextRetryAfter = time.Time{}
		ms.LastError = nil
		ms.UpdatedAt = observed
		recovered = append(recovered, model)
	}
	if len(recovered) == 0 {
		n.emitAccount(current, "waiting")
		return
	}
	updateEgressAvailability(current)
	updated, updateErr := n.commitVerified(ctx, current)
	if updateErr != nil || updated == nil {
		latest, _ := n.rt.manager.GetByID(id)
		n.emitAccount(latest, "failed")
		return
	}
	// Registry publication is guarded by the SDK generation as well as the
	// account lock, and targets only the model states proven above.
	_, epoch := registry.GetGlobalRegistry().GetModelsAndEpochForClient(id)
	projections := []registry.ClientModelProjection{}
	for _, model := range recovered {
		projections = append(projections, registry.ClientModelProjection{ModelID: model})
	}
	registry.GetGlobalRegistry().ApplyClientModelProjections(id, epoch, updated.Generation, projections)
	n.rt.manager.PersistCooldownStates(ctx)
	n.emitAccount(updated, "waiting")
}

func (n *networkRecovery) start() {
	n.gate.Lock()
	defer n.gate.Unlock()
	if n.started || n.stopped {
		return
	}
	n.started = true
	n.work.Add(1)
	go func() {
		defer n.work.Done()
		probe := time.NewTicker(n.probeEvery)
		defer probe.Stop()
		watch := time.NewTicker(n.watchEvery)
		defer watch.Stop()
		for {
			select {
			case <-n.ctx.Done():
				return
			case <-n.wake:
				if n.applyPending() {
					n.launch(func() { n.checkEgress(n.ctx, true, "") })
				}
			case <-probe.C:
				n.launch(func() { n.probeAccounts(n.ctx, "", false) })
			case <-watch.C:
				n.launch(func() { n.checkEgress(n.ctx, true, "") })
			}
		}
	}()
}
func (n *networkRecovery) launch(f func()) bool {
	n.gate.Lock()
	defer n.gate.Unlock()
	if n.stopped {
		return false
	}
	n.work.Add(1)
	go func() { defer n.work.Done(); f() }()
	return true
}
func (n *networkRecovery) command(c networkCommand) {
	switch c.Command {
	case "probe":
		if c.ProfileID != "" {
			if n.identity(c.ProfileID) == "" {
				return
			}
			if _, err := uuid.Parse(c.ProfileID); err != nil {
				return
			}
		}
		n.launch(func() { n.probeAccounts(n.ctx, c.ProfileID, true) })
	case "self_check":
		if _, err := uuid.Parse(c.RequestID); err != nil || c.RequestID == "" {
			return
		}
		if !n.launch(func() { n.checkEgress(n.ctx, false, c.RequestID) }) {
			n.events.emit(event{Event: "egress", State: "unavailable", RequestID: c.RequestID})
		}
	}
}
func (n *networkRecovery) close() {
	n.gate.Lock()
	n.stopped = true
	n.cancel()
	n.gate.Unlock()
	n.work.Wait()
}
