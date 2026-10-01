// AiGoodBro's optional, isolated Responses proxy. Upstream service startup is
// deliberately not used: no OAuth lifecycle, watcher, management or updater.
package main

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	internalconfig "github.com/router-for-me/CLIProxyAPI/v8/internal/config"
	"github.com/router-for-me/CLIProxyAPI/v8/internal/registry"
	provider "github.com/router-for-me/CLIProxyAPI/v8/internal/runtime/executor"
	_ "github.com/router-for-me/CLIProxyAPI/v8/internal/translator"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/api/handlers"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/api/handlers/openai"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/config"
	logrus "github.com/sirupsen/logrus"
)

type startup struct {
	SchemaVersion   int    `json:"schemaVersion"`
	RunID           string `json:"runID"`
	ControlSocket   string `json:"controlSocket"`
	ControlKey      string `json:"controlKey"`
	ClientKey       string `json:"clientKey"`
	Port            int    `json:"port"`
	StateDirectory  string `json:"stateDirectory"`
	NetworkProxy    string `json:"networkProxy,omitempty"`
	CreditFallback  bool   `json:"creditFallback,omitempty"`
	DesktopFallback bool   `json:"desktopFallback,omitempty"`
	Accounts        []struct {
		ID string `json:"id"`
	} `json:"accounts"`
	Models []string `json:"models"`
}
type event struct {
	Event         string `json:"event"`
	Port          int    `json:"port,omitempty"`
	ProfileID     string `json:"profileID,omitempty"`
	State         string `json:"state,omitempty"`
	CooldownUntil int64  `json:"cooldownUntil,omitempty"`
	ErrorCode     string `json:"errorCode,omitempty"`
	ErrorDetail   string `json:"errorDetail,omitempty"`
}
type events struct {
	mu  sync.Mutex
	out io.Writer
}

func (e *events) emit(v event) {
	e.mu.Lock()
	defer e.mu.Unlock()
	_ = json.NewEncoder(e.out).Encode(v)
}

var identifier = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

func (s startup) validate() error {
	if s.SchemaVersion != 1 || !identifier.MatchString(s.RunID) || s.Port != 0 || len(s.ControlKey) < 24 || len(s.ClientKey) < 24 || len(s.Accounts) == 0 || len(s.Accounts) > 100 || len(s.Models) == 0 || len(s.Models) > 100 || s.ControlSocket == "" || s.StateDirectory == "" {
		return errors.New("invalid_startup")
	}
	if _, err := parseNetworkProxy(s.NetworkProxy); err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, a := range s.Accounts {
		if !identifier.MatchString(a.ID) || seen[a.ID] {
			return errors.New("invalid_startup")
		}
		seen[a.ID] = true
	}
	for _, m := range s.Models {
		if len(m) > 128 || strings.TrimSpace(m) != m || m == "" || strings.ContainsAny(m, "/\\\r\n\x00") {
			return errors.New("invalid_startup")
		}
	}
	return nil
}

type noRefresh struct{}

func (noRefresh) ShouldRefresh(time.Time, *auth.Auth) bool { return false }

type scopeKey struct{}
type lease struct{ ProfileID, ID string }
type requestScope struct {
	orderOnce          sync.Once
	orderQueried       bool // Protected by mu; causes a bounded, idempotent snapshot cleanup.
	order              []string
	orderErr           error
	pickMu             sync.Mutex
	heartbeatPeriod    time.Duration // Zero selects the fixed production interval; shortened only by unit tests.
	id                 string
	cancel             context.CancelFunc
	ctx                context.Context
	bridge             *bridge
	events             *events
	responseHeader     http.Header
	mu                 sync.Mutex
	leases             []lease
	usedProfiles       map[string]struct{}
	admissionUncertain bool
	done               chan struct{}
	exited             chan struct{}
}

func (s *requestScope) add(l lease) {
	s.mu.Lock()
	s.leases = append(s.leases, l)
	if s.usedProfiles == nil {
		s.usedProfiles = map[string]struct{}{}
	}
	s.usedProfiles[l.ProfileID] = struct{}{}
	s.mu.Unlock()
}
func (s *requestScope) markAdmissionUncertain(profileID string) {
	s.mu.Lock()
	if s.usedProfiles == nil {
		s.usedProfiles = map[string]struct{}{}
	}
	if profileID != "" {
		s.usedProfiles[profileID] = struct{}{}
	}
	s.admissionUncertain = true
	s.mu.Unlock()
}
func (s *requestScope) retryAfter() {
	if s.responseHeader != nil {
		s.responseHeader.Set("Retry-After", "1")
	}
}
func (s *requestScope) hasUsedProfiles() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.usedProfiles) > 0
}
func (s *requestScope) hasAdmissionUncertainty() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.admissionUncertain
}
func (s *requestScope) profileUsed(profileID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.usedProfiles[profileID]
	return ok
}
func (s *requestScope) snapshot() []lease {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]lease(nil), s.leases...)
}
func (s *requestScope) heartbeatInterval() time.Duration {
	if s.heartbeatPeriod > 0 {
		return s.heartbeatPeriod
	}
	return 20 * time.Second
}
func (s *requestScope) heartbeats() {
	defer close(s.exited)
	ticker := time.NewTicker(s.heartbeatInterval())
	defer ticker.Stop()
	for {
		select {
		case <-s.done:
			return
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			for _, l := range s.snapshot() {
				if s.ctx.Err() != nil {
					return
				}
				r, err := s.bridge.call(s.ctx, "heartbeat", s.id, l.ProfileID, l.ID)
				if err == nil && r.Error == "control_busy" && s.ctx.Err() != nil {
					return // Cancelled before any heartbeat mutation; release follows.
				}
				if err != nil || !r.OK {
					s.events.emit(event{Event: "error", ErrorCode: "lease_heartbeat_failed"})
					s.cancel()
					return
				}
				if s.ctx.Err() != nil {
					return
				}
			}
		}
	}
}
func (s *requestScope) close() {
	close(s.done)
	s.cancel()
	<-s.exited
	var wg sync.WaitGroup
	for _, l := range s.snapshot() {
		wg.Add(1)
		go func(l lease) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
			defer cancel()
			r, err := s.bridge.call(ctx, "release", s.id, l.ProfileID, l.ID)
			if err != nil || !r.OK {
				s.events.emit(event{Event: "error", ErrorCode: "lease_release_unknown"})
			}
		}(l)
	}
	wg.Wait()
	s.mu.Lock()
	queried := s.orderQueried
	s.mu.Unlock()
	if queried {
		// Completion is memory-only, idempotent and cannot affect a lease.
		// A failed cleanup is safe: the host expires this request snapshot.
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_, _ = s.bridge.call(ctx, "order_end", s.id, "", "")
		cancel()
	}
}
func scopeFrom(ctx context.Context) *requestScope {
	if s, ok := ctx.Value(scopeKey{}).(*requestScope); ok {
		return s
	}
	if c, ok := ctx.Value("gin").(*gin.Context); ok && c.Request != nil {
		s, _ := c.Request.Context().Value(scopeKey{}).(*requestScope)
		return s
	}
	return nil
}

type selector struct {
	order     []string
	commands  []string
	bridge    *bridge
	events    *events
	baseURL   string
	waitFor   time.Duration // Zero uses the bounded production admission wait.
	pollEvery time.Duration // Zero uses the production polling interval.
}

func (s *selector) Pick(ctx context.Context, _, _ string, _ executor.Options, candidates []*auth.Auth) (*auth.Auth, error) {
	scope := scopeFrom(ctx)
	if scope == nil {
		return nil, &auth.Error{Code: "unavailable", Message: "request admission unavailable", HTTPStatus: 503}
	}
	scope.pickMu.Lock()
	defer scope.pickMu.Unlock()
	if err := pickContextError(ctx, scope); err != nil {
		return nil, err
	}
	if scope.hasUsedProfiles() {
		scope.markAdmissionUncertain("")
	}
	// All accounts in s.order were registered at startup from the verified
	// managed pool. The host returns the currently participating subset for
	// this request; later membership changes cannot alter its retry order.
	scope.orderOnce.Do(func() {
		scope.mu.Lock()
		scope.orderQueried = true
		scope.mu.Unlock()
		reply, err := s.bridge.call(scope.ctx, "order", scope.id, s.order[0], "")
		if err != nil || !reply.OK || !validAccountSubset(s.order, reply.Order) {
			scope.orderErr = &auth.Error{Code: "unavailable", Message: "account order unavailable", HTTPStatus: 503}
			return
		}
		scope.order = reply.Order
	})
	if err := pickContextError(ctx, scope); err != nil {
		return nil, err
	}
	if scope.orderErr != nil {
		return nil, scope.orderErr
	}
	if len(scope.order) == 0 {
		return nil, admissionError("no_accounts", "no participating accounts")
	}
	byID := map[string]*auth.Auth{}
	for _, a := range candidates {
		byID[a.ID] = a
	}
	commands := s.commands
	if len(commands) == 0 {
		commands = []string{"acquire"}
	}
	waitFor, pollEvery := s.admissionWait()
	waitDeadline := time.Now().Add(waitFor)
	rejections := map[string]bool{}
	for {
		sawBusy := false
		sawQuota := false
		sawUncertain := false
		for _, command := range commands {
			for _, id := range scope.order {
				if err := pickContextError(ctx, scope); err != nil {
					return nil, err
				}
				a := byID[id]
				if a == nil || scope.profileUsed(id) {
					continue
				}
				// Check before each acquire. Once sent, the RPC gets its own 25s
				// bridge bound so HTTP cancellation cannot abandon an ambiguous lease.
				if !waitDeadline.IsZero() && !time.Now().Before(waitDeadline) {
					return nil, admissionError("account_busy", "eligible accounts remain busy")
				}
				if err := pickContextError(ctx, scope); err != nil {
					return nil, err
				}
				reply, err := s.bridge.call(scope.ctx, command, scope.id, id, "")
				if err != nil {
					return nil, s.reconcileAcquire(scope, id, acquireFailureDetail(err))
				}
				if !reply.OK {
					if reply.Error == "admission_unknown" {
						return nil, s.reconcileAcquire(scope, id, "admission_unknown")
					}
					if err := pickContextError(ctx, scope); err != nil {
						return nil, err
					}
					if reply.Error == "stage_not_applicable" {
						continue
					}
					if reply.Error == "control_busy" {
						return nil, admissionError("account_busy", "proxy control channel is busy")
					}
					if reply.Error == "admission_deadline" {
						scope.retryAfter()
						return nil, admissionError("account_busy", "account admission timed out")
					}
					state := safeState(reply.Error)
					rejections[admissionRejectionDetail(reply.Error)] = true
					if state == "busy" || state == "credentials_busy" {
						sawBusy = true
					} else if state == "quota" {
						sawQuota = true
					} else {
						sawUncertain = true
						scope.markAdmissionUncertain("")
					}
					if reply.Error == "identity" || reply.Error == "login_expired" {
						scope.markAdmissionUncertain(id)
					}
					s.events.emit(event{Event: "account", ProfileID: id, State: state, CooldownUntil: reply.RetryAt})
					continue
				}
				if reply.LeaseID == "" {
					return nil, s.reconcileAcquire(scope, id, "missing_lease")
				}
				scope.add(lease{id, reply.LeaseID})
				if err := pickContextError(ctx, scope); err != nil {
					return nil, err
				}
				if reply.AccessToken == "" || reply.AccountID == "" || reply.ExpiresAt <= time.Now().Add(30*time.Second).Unix() {
					s.events.emit(event{Event: "account", ProfileID: id, State: "login_expired"})
					sawUncertain = true
					scope.markAdmissionUncertain(id)
					continue
				}
				out := a.Clone()
				out.Runtime = noRefresh{}
				out.Metadata = map[string]any{"type": "codex", "access_token": reply.AccessToken, "account_id": reply.AccountID, "expired": time.Unix(reply.ExpiresAt, 0).UTC().Format(time.RFC3339)}
				if s.baseURL != "" {
					out.Attributes["base_url"] = s.baseURL
				}
				s.events.emit(event{Event: "account", ProfileID: id, State: "current"})
				return out, nil
			}
		}
		if err := pickContextError(ctx, scope); err != nil {
			return nil, err
		}
		if !sawBusy {
			if sawQuota && !sawUncertain && !scope.hasAdmissionUncertainty() {
				return nil, admissionError("quota", "all eligible account quotas are exhausted")
			}
			message := "account admission unavailable"
			// Fixed messages explain known refusals without exposing identities,
			// credentials or arbitrary host error text. Admission policy is unchanged.
			for _, detail := range admissionRejectionDetails {
				if rejections[detail] {
					message += "; " + detail
				}
			}
			return nil, admissionError("unavailable", message)
		}
		remaining := time.Until(waitDeadline)
		if remaining <= 0 {
			return nil, admissionError("account_busy", "eligible accounts remain busy")
		}
		delay := pollEvery
		if delay > remaining {
			delay = remaining
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			stopAdmissionTimer(timer)
			return nil, pickContextError(ctx, scope)
		case <-scope.ctx.Done():
			stopAdmissionTimer(timer)
			return nil, pickContextError(ctx, scope)
		case <-timer.C:
		}
	}
}

func acquireFailureDetail(err error) string {
	switch err.Error() {
	case "bridge_timeout":
		return "timeout"
	case "bridge_eof":
		return "eof"
	case "bridge_decode", "bridge_invalid":
		return "decode"
	default:
		return "unavailable"
	}
}

func (s *selector) reconcileAcquire(scope *requestScope, profileID, detail string) error {
	// A separate maintenance exchange either cancels the exact reservation or
	// installs a durable deny marker before a delayed reservation can run.
	reply, err := s.bridge.call(context.Background(), "acquire_resolve", scope.id, profileID, "")
	if err == nil && reply.OK && (reply.Resolution == "abandoned" || reply.Resolution == "not_reserved") &&
		reply.Error == "" && reply.LeaseID == "" && reply.AccessToken == "" && reply.AccountID == "" && reply.ExpiresAt == 0 && len(reply.Order) == 0 {
		scope.markAdmissionUncertain(profileID)
		scope.retryAfter()
		s.events.emit(event{Event: "error", ErrorCode: "lease_acquire_reconciled", ErrorDetail: detail})
		return admissionError("account_busy", "account admission timed out; retry request")
	}
	s.events.emit(event{Event: "error", ErrorCode: "lease_acquire_unknown", ErrorDetail: detail})
	scope.cancel()
	return admissionError("unavailable", "account admission unavailable")
}

func pickContextError(ctx context.Context, scope *requestScope) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return scope.ctx.Err()
}

func stopAdmissionTimer(timer *time.Timer) {
	if !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
}

func admissionError(code, message string) *auth.Error {
	return &auth.Error{Code: code, Message: message, HTTPStatus: 503}
}

var admissionRejectionDetails = []string{
	"account identity could not be verified",
	"account sign-in needs renewal",
	"quota data missing or stale",
	"remaining subscription quota must be used before credits",
	"account quota or permitted credit balance exhausted",
	"eligible accounts are occupied",
	"proxy is stopping",
	"local account checks unavailable",
}

func admissionRejectionDetail(code string) string {
	switch code {
	case "identity":
		return admissionRejectionDetails[0]
	case "login_expired":
		return admissionRejectionDetails[1]
	case "quota_unknown":
		return admissionRejectionDetails[2]
	case "subscription_pending":
		return admissionRejectionDetails[3]
	case "quota":
		return admissionRejectionDetails[4]
	case "busy", "credentials_busy":
		return admissionRejectionDetails[5]
	case "stopping":
		return admissionRejectionDetails[6]
	default:
		return admissionRejectionDetails[7]
	}
}

func (s *selector) admissionWait() (time.Duration, time.Duration) {
	waitFor := s.waitFor
	if waitFor <= 0 {
		waitFor = 60 * time.Second
	}
	pollEvery := s.pollEvery
	if pollEvery <= 0 {
		pollEvery = 500 * time.Millisecond
	}
	return waitFor, pollEvery
}

// An empty order is a valid stopped-admission state, but unknown or repeated
// IDs must never reach a credential or lease operation.
func validAccountSubset(registered, order []string) bool {
	if len(order) > len(registered) {
		return false
	}
	remaining := make(map[string]bool, len(registered))
	for _, id := range registered {
		remaining[id] = true
	}
	for _, id := range order {
		if !remaining[id] {
			return false
		}
		delete(remaining, id)
	}
	return true
}

func admissionCommands(credits, desktop bool) []string {
	commands := []string{"acquire"}
	// Exhaust every enrolled subscription before any paid-credit pass.
	if desktop {
		commands = append(commands, "acquire_desktop")
	}
	if credits {
		commands = append(commands, "acquire_credit_primary", "acquire_credit_secondary")
	}
	// Desktop remains last within both the subscription and credit phases.
	if desktop && credits {
		commands = append(commands, "acquire_desktop_credit_primary", "acquire_desktop_credit_secondary")
	}
	return commands
}
func safeState(code string) string {
	switch code {
	case "busy", "credentials_busy", "quota", "quota_unknown", "login_expired", "subscription_pending":
		return code
	default:
		return "temporary_error"
	}
}

type hook struct {
	auth.NoopHook
	events  *events
	manager *auth.Manager
}

func (h *hook) OnResult(_ context.Context, r auth.Result) {
	state := "ready"
	code := ""
	var until int64
	if !r.Success {
		state = "temporary_error"
		code = "upstream_failed"
		if r.Error != nil {
			if r.Error.IsRequestScoped() {
				// A rejected request does not establish account or quota failure.
				state = "ready"
				code = "request_rejected"
			} else {
				switch r.Error.HTTPStatus {
				case 429:
					state = "quota"
					code = "quota"
				case 401, 403:
					if r.Error.HTTPStatus == 403 && imageLocalPath(r.Options.Alt) != "" && r.Error.IsRequestScoped() {
						break // Image permission denial is not proof of an expired login.
					}
					state = "login_expired"
					code = "login_expired"
				}
			}
		}
	}
	if a, ok := h.manager.GetByID(r.AuthID); ok {
		if a.NextRetryAfter.After(time.Now()) {
			until = a.NextRetryAfter.Unix()
		}
		for _, ms := range a.ModelStates {
			if ms.NextRetryAfter.After(time.Now()) && ms.NextRetryAfter.Unix() > until {
				until = ms.NextRetryAfter.Unix()
			}
		}
	}
	h.events.emit(event{Event: "account", ProfileID: r.AuthID, State: state, ErrorCode: code, CooldownUntil: until})
}

type transportProvider struct {
	transport http.RoundTripper
	origin    string
}

func (t transportProvider) RoundTripperFor(a *auth.Auth) http.RoundTripper {
	exp, _ := a.AccessTokenExpirationTime()
	return &guardTransport{base: t.transport, origin: t.origin, expiry: exp}
}

type guardTransport struct {
	base   http.RoundTripper
	origin string
	expiry time.Time
}

func (t *guardTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL.Scheme+"://"+r.URL.Host != t.origin || r.URL.User != nil || r.Method != "POST" || !(strings.HasSuffix(r.URL.Path, "/responses") || strings.HasSuffix(r.URL.Path, "/responses/compact") || imageUpstreamPath(r.URL.Path)) || (!t.expiry.IsZero() && !t.expiry.After(time.Now().Add(5*time.Second))) {
		return nil, errors.New("upstream_request_blocked")
	}
	resp, err := t.base.RoundTrip(r)
	if resp != nil && resp.StatusCode >= 300 && resp.StatusCode < 400 {
		resp.Header.Del("Location")
	}
	return resp, err
}

type runtime struct {
	closeOnce sync.Once
	modelMu   sync.Mutex
	models    map[string]*registry.ModelInfo
	selector  *selector // Retained so isolated runtime fixtures can shorten admission waits.
	store     *cooldownStore
	transport *http.Transport
	handler   http.Handler
	manager   *auth.Manager
	ids       []string
	cancel    context.CancelFunc
	requests  sync.WaitGroup
	gate      sync.Mutex
	stopping  bool
}

func newRuntime(s startup, e *events, testBaseURL string) (*runtime, error) {
	if err := s.validate(); err != nil {
		return nil, err
	}
	store, err := newCooldownStore(s.StateDirectory)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	b := &bridge{socket: s.ControlSocket, key: s.ControlKey, runID: s.RunID}
	sel := &selector{bridge: b, events: e, baseURL: testBaseURL, commands: admissionCommands(s.CreditFallback, s.DesktopFallback)}
	for _, a := range s.Accounts {
		sel.order = append(sel.order, a.ID)
	}
	h := &hook{events: e}
	m := auth.NewManager(nil, sel, h)
	h.manager = m
	cfg := &config.Config{}
	cfg.Codex.DisableCodexCloaking = true
	cfg.Codex.StreamBootstrapBuffering = true
	// This upstream response rejects the requested model/client combination.
	// Preserve it and stop this request instead of poisoning every credential
	// with the SDK's default twelve-hour model-support cooldown.
	cfg.OAuthRequestScopedErrors = map[string][]internalconfig.RequestScopedErrorRule{
		"codex": {{Status: http.StatusBadRequest, Match: []string{"model is not supported when using Codex with a ChatGPT account"}, Action: "stop"}},
	}
	cfg.SaveCooldownStatus = true
	cfg.RequestRetry = 0
	cfg.MaxRetryCredentials = len(s.Accounts)
	cfg.MaxRetryInterval = 0
	m.SetConfig(cfg)
	m.SetRetryConfig(0, 0, len(s.Accounts))
	m.SetCooldownStateStore(store)
	origin := "https://chatgpt.com"
	if testBaseURL != "" {
		origin = testBaseURL
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	if proxyURL, _ := parseNetworkProxy(s.NetworkProxy); proxyURL != nil {
		transport.Proxy = http.ProxyURL(proxyURL)
	}
	transports := transportProvider{transport, origin}
	m.SetRoundTripperProvider(transports)
	imageBaseURL := "https://chatgpt.com/backend-api/codex"
	if testBaseURL != "" {
		imageBaseURL = testBaseURL
	}
	m.RegisterExecutor(&imageExecutor{CodexExecutor: provider.NewCodexExecutor(cfg), transports: transports, baseURL: imageBaseURL})
	rt := &runtime{selector: sel, manager: m, ids: sel.order, cancel: cancel, store: store, transport: transport, models: make(map[string]*registry.ModelInfo)}
	// This is a discovery seed, not the set of models Desktop may request.
	for _, model := range append(append([]string(nil), s.Models...), nativeImageModel) {
		rt.models[model] = proxyModelInfo(model)
	}
	for _, id := range sel.order {
		_, err = m.Register(context.Background(), &auth.Auth{ID: id, Provider: "codex", Status: auth.StatusActive, Attributes: map[string]string{"priority": "0"}, Metadata: map[string]any{"type": "codex"}, Runtime: noRefresh{}})
		if err != nil {
			cancel()
			return nil, errors.New("account_registration_failed")
		}
		models := make([]*registry.ModelInfo, 0, len(rt.models))
		for _, model := range rt.models {
			models = append(models, model)
		}
		registry.GetGlobalRegistry().RegisterClient(id, "codex", models)
		m.RefreshSchedulerEntry(id)
	}
	if err = m.RestoreCooldownStates(context.Background()); err != nil {
		rt.close()
		return nil, errors.New("cooldown_restore_failed")
	}
	base := handlers.NewBaseAPIHandlers(&cfg.SDKConfig, m)
	base.SetModelRouterHost(codexModelRoute{})
	responses := openai.NewOpenAIResponsesAPIHandler(base)
	router := gin.New()
	router.RedirectTrailingSlash = false
	router.RedirectFixedPath = false
	router.Use(func(c *gin.Context) {
		if c.Request.Header.Get("Upgrade") != "" || subtle.ConstantTimeCompare([]byte(c.GetHeader("Authorization")), []byte("Bearer "+s.ClientKey)) != 1 {
			c.AbortWithStatus(401)
			return
		}
		if !((c.Request.Method == "POST" && (c.Request.URL.Path == "/v1/responses" || c.Request.URL.Path == "/responses" || c.Request.URL.Path == "/v1/responses/compact" || c.Request.URL.Path == "/responses/compact" || imageLocalPath(c.Request.URL.Path) != "")) || (c.Request.Method == "GET" && c.Request.URL.Path == "/v1/models")) {
			c.AbortWithStatus(404)
			return
		}
		rt.gate.Lock()
		if rt.stopping {
			rt.gate.Unlock()
			c.AbortWithStatus(503)
			return
		}
		rt.requests.Add(1)
		rt.gate.Unlock()
		defer rt.requests.Done()
		deadline := time.Now().Add(15 * time.Minute)
		controller := http.NewResponseController(c.Writer)
		_ = controller.SetReadDeadline(deadline)
		_ = controller.SetWriteDeadline(deadline)
		requestCtx, requestCancel := context.WithTimeout(c.Request.Context(), 15*time.Minute)
		stop := context.AfterFunc(ctx, requestCancel)
		defer stop()
		requestID, idErr := uuid.NewV7()
		if idErr != nil {
			requestCancel()
			c.AbortWithStatus(http.StatusServiceUnavailable)
			return
		}
		scope := &requestScope{id: requestID.String(), cancel: requestCancel, ctx: requestCtx, bridge: b, events: e, responseHeader: c.Writer.Header(), done: make(chan struct{}), exited: make(chan struct{})}
		c.Request = c.Request.WithContext(context.WithValue(requestCtx, scopeKey{}, scope))
		// Desktop can replay large image histories. Do not impose a second,
		// local body-size cap on Responses or compaction requests.
		go scope.heartbeats()
		defer scope.close()
		c.Next()
	})
	router.POST("/v1/responses", rt.withResponseModel(responses.Responses))
	router.POST("/responses", rt.withResponseModel(responses.Responses))
	router.POST("/v1/responses/compact", rt.withResponseModel(responses.Compact))
	router.POST("/responses/compact", rt.withResponseModel(responses.Compact))
	for _, path := range []string{"/v1/images/generations", "/v1/images/edits", "/images/generations", "/images/edits"} {
		router.POST(path, imageHandler(m))
	}
	router.GET("/v1/models", func(c *gin.Context) {
		models := make([]map[string]string, 0, len(s.Models))
		for _, model := range s.Models {
			models = append(models, map[string]string{"id": model, "object": "model", "owned_by": "openai"})
		}
		c.JSON(200, gin.H{"object": "list", "data": models})
	})
	rt.handler = router
	return rt, nil
}
func (rt *runtime) close() {
	rt.closeOnce.Do(func() {
		rt.gate.Lock()
		rt.stopping = true
		rt.gate.Unlock()
		rt.cancel()
		rt.requests.Wait()
		for _, id := range rt.ids {
			registry.GetGlobalRegistry().UnregisterClient(id)
		}
		if rt.transport != nil {
			rt.transport.CloseIdleConnections()
		}
		if rt.store != nil {
			_ = rt.store.root.Close()
		}
	})
}

func main() {
	if connectionPath, enabled := os.LookupEnv("AIGOODBRO_PROXY_CONNECTION_FILE"); enabled {
		if len(os.Args) == 2 && os.Args[1] == desktopBridgeArgument {
			os.Exit(runDesktopBridge(connectionPath))
		}
		os.Exit(runDesktopAdapter(connectionPath, os.Args[1:]))
	}
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		_, _ = io.WriteString(os.Stdout, "AiGoodBro Local Proxy 1001v3; CLIProxyAPI v8.0.2\n")
		return
	}
	logrus.SetOutput(io.Discard)
	log.SetOutput(io.Discard)
	gin.SetMode(gin.ReleaseMode)
	gin.DefaultWriter = io.Discard
	gin.DefaultErrorWriter = io.Discard
	e := &events{out: os.Stdout}
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	if !scanner.Scan() {
		e.emit(event{Event: "error", ErrorCode: "invalid_startup"})
		return
	}
	var s startup
	if json.Unmarshal(scanner.Bytes(), &s) != nil {
		e.emit(event{Event: "error", ErrorCode: "invalid_startup"})
		return
	}
	rt, err := newRuntime(s, e, "")
	if err != nil {
		e.emit(event{Event: "error", ErrorCode: "startup_failed"})
		return
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		rt.close()
		e.emit(event{Event: "error", ErrorCode: "listen_failed"})
		return
	}
	server := &http.Server{Handler: rt.handler, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 15 * time.Minute, WriteTimeout: 15 * time.Minute, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 64 << 10, ErrorLog: log.New(io.Discard, "", 0)}
	done := make(chan struct{})
	go func() { defer close(done); _ = server.Serve(listener) }()
	e.emit(event{Event: "ready", Port: listener.Addr().(*net.TCPAddr).Port})
	stop := make(chan struct{}, 1)
	go func() {
		for scanner.Scan() {
			var v struct {
				Command string `json:"command"`
			}
			if json.Unmarshal(scanner.Bytes(), &v) != nil || v.Command == "stop" {
				break
			}
		}
		stop <- struct{}{}
	}()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, os.Interrupt)
	select {
	case <-stop:
	case <-sig:
	case <-done:
	}
	_ = server.Close()
	rt.close()
	signal.Stop(sig)
	e.emit(event{Event: "stopped"})
}
