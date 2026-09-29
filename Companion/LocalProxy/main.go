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
	orderOnce       sync.Once
	order           []string
	orderErr        error
	heartbeatPeriod time.Duration // Zero selects the fixed production interval; shortened only by unit tests.
	id              string
	cancel          context.CancelFunc
	ctx             context.Context
	bridge          *bridge
	events          *events
	mu              sync.Mutex
	leases          []lease
	done            chan struct{}
	exited          chan struct{}
}

func (s *requestScope) add(l lease) { s.mu.Lock(); s.leases = append(s.leases, l); s.mu.Unlock() }
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
				r, err := s.bridge.call(s.ctx, "heartbeat", s.id, l.ProfileID, l.ID)
				if err != nil || !r.OK {
					s.events.emit(event{Event: "error", ErrorCode: "lease_heartbeat_failed"})
					s.cancel()
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
	order    []string
	commands []string
	bridge   *bridge
	events   *events
	baseURL  string
}

func (s *selector) Pick(ctx context.Context, _, _ string, _ executor.Options, candidates []*auth.Auth) (*auth.Auth, error) {
	scope := scopeFrom(ctx)
	if scope == nil {
		return nil, &auth.Error{Code: "unavailable", Message: "request admission unavailable", HTTPStatus: 503}
	}
	// Freeze the host's current order once per request. A live reorder affects
	// subsequent requests, never the retry order or lease of one already started.
	scope.orderOnce.Do(func() {
		reply, err := s.bridge.call(scope.ctx, "order", scope.id, s.order[0], "")
		if err != nil || !reply.OK || !sameAccounts(s.order, reply.Order) {
			scope.orderErr = &auth.Error{Code: "unavailable", Message: "account order unavailable", HTTPStatus: 503}
			return
		}
		scope.order = reply.Order
	})
	if scope.orderErr != nil {
		return nil, scope.orderErr
	}
	byID := map[string]*auth.Auth{}
	for _, a := range candidates {
		byID[a.ID] = a
	}
	commands := s.commands
	if len(commands) == 0 {
		commands = []string{"acquire"}
	}
	for _, command := range commands {
		for _, id := range scope.order {
			a := byID[id]
			if a == nil {
				continue
			}
			reply, err := s.bridge.call(scope.ctx, command, scope.id, id, "")
			if err != nil {
				s.events.emit(event{Event: "error", ErrorCode: "lease_acquire_unknown"})
				scope.cancel()
				return nil, &auth.Error{Code: "unavailable", Message: "account admission unavailable", HTTPStatus: 503}
			}
			if !reply.OK {
				state := safeState(reply.Error)
				s.events.emit(event{Event: "account", ProfileID: id, State: state, CooldownUntil: reply.RetryAt})
				continue
			}
			if reply.LeaseID == "" {
				s.events.emit(event{Event: "error", ErrorCode: "lease_acquire_unknown"})
				scope.cancel()
				return nil, &auth.Error{Code: "unavailable", Message: "account admission unavailable", HTTPStatus: 503}
			}
			scope.add(lease{id, reply.LeaseID})
			if reply.AccessToken == "" || reply.AccountID == "" || reply.ExpiresAt <= time.Now().Add(30*time.Second).Unix() {
				s.events.emit(event{Event: "account", ProfileID: id, State: "login_expired"})
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
	return nil, &auth.Error{Code: "unavailable", Message: "no eligible account available", HTTPStatus: 503}
}

func sameAccounts(registered, order []string) bool {
	if len(order) != len(registered) {
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
	return len(remaining) == 0
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
	rt := &runtime{manager: m, ids: sel.order, cancel: cancel, store: store, transport: transport}
	for _, id := range sel.order {
		_, err = m.Register(context.Background(), &auth.Auth{ID: id, Provider: "codex", Status: auth.StatusActive, Attributes: map[string]string{"priority": "0"}, Metadata: map[string]any{"type": "codex"}, Runtime: noRefresh{}})
		if err != nil {
			cancel()
			return nil, errors.New("account_registration_failed")
		}
		models := make([]*registry.ModelInfo, 0, len(s.Models))
		// Native image_gen uses a separate model and endpoint. Keep it out of
		// Desktop's text-model menu while sharing the same admission/cooldowns.
		for _, model := range append(append([]string(nil), s.Models...), nativeImageModel) {
			models = append(models, &registry.ModelInfo{ID: model, Object: "model", OwnedBy: "openai", Type: "codex", DisplayName: model})
		}
		registry.GetGlobalRegistry().RegisterClient(id, "codex", models)
		m.RefreshSchedulerEntry(id)
	}
	if err = m.RestoreCooldownStates(context.Background()); err != nil {
		rt.close()
		return nil, errors.New("cooldown_restore_failed")
	}
	base := handlers.NewBaseAPIHandlers(&cfg.SDKConfig, m)
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
		scope := &requestScope{id: uuid.NewString(), cancel: requestCancel, ctx: requestCtx, bridge: b, events: e, done: make(chan struct{}), exited: make(chan struct{})}
		c.Request = c.Request.WithContext(context.WithValue(requestCtx, scopeKey{}, scope))
		// Desktop can replay large image histories. Do not impose a second,
		// local body-size cap on Responses or compaction requests.
		go scope.heartbeats()
		defer scope.close()
		c.Next()
	})
	router.POST("/v1/responses", responses.Responses)
	router.POST("/responses", responses.Responses)
	router.POST("/v1/responses/compact", responses.Compact)
	router.POST("/responses/compact", responses.Compact)
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
		_, _ = io.WriteString(os.Stdout, "AiGoodBro Local Proxy 0928v1; CLIProxyAPI v8.0.2\n")
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
