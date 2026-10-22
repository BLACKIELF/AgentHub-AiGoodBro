// AiGoodBro's private Antigravity adapter. This does not start the upstream
// service, file token store, watchers, updater, plugins or management handlers.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	logrus "github.com/sirupsen/logrus"
)

type application struct {
	ctx             context.Context
	pool            *pool
	backend         *backendRouter
	events          *events
	mu              sync.Mutex
	pending         map[string]chan bool
	authSession     string
	authCancel      context.CancelFunc
	catalogRequests chan struct{}
}

func (a *application) snapshot() {
	accounts, _ := a.pool.snapshots()
	catalogs := map[string][]string{}
	for _, provider := range a.backend.names() {
		_, catalogs[provider] = a.pool.snapshotsForProvider(provider)
	}
	_ = a.events.emit(event{Event: "snapshot", Accounts: accounts, Models: catalogs["antigravity"], ProviderModels: catalogs})
}

func (a *application) persist(ctx context.Context, c credential, purpose, session string) error {
	id := randomID()
	result := make(chan bool, 1)
	a.mu.Lock()
	a.pending[id] = result
	a.mu.Unlock()
	defer func() { a.mu.Lock(); delete(a.pending, id); a.mu.Unlock() }()
	if err := a.events.emit(event{Event: "persist_credential", RequestID: id, SessionID: session, Purpose: purpose,
		Provider: c.Provider, AccountID: c.AccountID, Generation: c.Generation, Credential: &c}); err != nil {
		return errors.New("credential_store_unavailable")
	}
	timer := time.NewTimer(15 * time.Second)
	defer timer.Stop()
	select {
	case ok := <-result:
		if ok {
			return nil
		}
		return errors.New("credential_store_rejected")
	case <-ctx.Done():
		return ctx.Err()
	case <-a.ctx.Done():
		return a.ctx.Err()
	case <-timer.C:
		return errors.New("credential_store_timeout")
	}
}

func (a *application) requestCatalog() {
	select {
	case a.catalogRequests <- struct{}{}:
	default:
	}
}

func (a *application) catalogLoop() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-a.ctx.Done():
			return
		case <-a.catalogRequests:
		case <-ticker.C:
		}
		a.pool.refreshCatalogs(a.ctx, a.backend, a.persist)
	}
}

// Only fixed stage codes and numeric HTTP status may cross the private pipe.
// Never forward an upstream error string, response body, or credential.
func authResultCode(err error) string {
	if err == nil {
		return "ok"
	}
	if errors.Is(err, context.Canceled) {
		return "oauth_cancelled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "oauth_timeout"
	}
	var stage oauthStageError
	if errors.As(err, &stage) {
		if stage.status >= 400 && stage.status <= 599 {
			return fmt.Sprintf("%s_http_%d", stage.code, stage.status)
		}
		return stage.code
	}
	switch err.Error() {
	case "account_exists", "oauth_listener_unavailable", "oauth_browser_unavailable",
		"oauth_denied", "oauth_state_mismatch", "oauth_identity_failed",
		"oauth_identity_mismatch", "oauth_invalid_credential", "oauth_project_failed",
		"oauth_request_failed", "oauth_token_exchange_failed", "oauth_token_rejected",
		"oauth_transport_failed", "oauth_verification_url_rejected",
		"credential_store_unavailable", "credential_store_rejected", "credential_store_timeout":
		return err.Error()
	}
	return "oauth_failed"
}

func (a *application) beginAuth(session, provider string) {
	if !opaqueIDPattern.MatchString(session) {
		return
	}
	b := a.backend.providers[provider]
	if b == nil {
		_ = a.events.emit(event{Event: "auth_result", Provider: provider, SessionID: session, Code: "provider_unavailable"})
		return
	}
	a.mu.Lock()
	if a.authCancel != nil {
		a.mu.Unlock()
		_ = a.events.emit(event{Event: "auth_result", Provider: provider, SessionID: session, Code: "oauth_busy"})
		return
	}
	ctx, cancel := context.WithCancel(a.ctx)
	a.authSession, a.authCancel = session, cancel
	a.mu.Unlock()
	go func() {
		defer cancel()
		c, err := b.signIn(ctx, func(prompt authPrompt) error {
			return a.events.emit(event{Event: "open_browser", Provider: provider, SessionID: session, URL: prompt.URL, UserCode: prompt.UserCode})
		})
		code := "oauth_failed"
		if err == nil && (c.Provider != provider || c.validate() != nil) {
			err = errors.New("oauth_invalid_credential")
		}
		if err == nil {
			a.pool.mu.Lock()
			existing := a.pool.entries[c.AccountID] != nil
			a.pool.mu.Unlock()
			if existing {
				err = errors.New("account_exists")
				code = "account_exists"
			}
		}
		if err == nil && ctx.Err() != nil {
			err = ctx.Err()
		}
		if err == nil {
			err = a.persist(ctx, c, "add", session)
		}
		if err == nil {
			if a.pool.add(savedAccount{Credential: c, Enabled: true, ConcurrencyLimit: 1}) {
				code = "ok"
				a.snapshot()
				a.requestCatalog()
			} else {
				code = "account_exists"
			}
		} else {
			code = authResultCode(err)
		}
		a.mu.Lock()
		if a.authSession == session {
			a.authSession = ""
			a.authCancel = nil
		}
		a.mu.Unlock()
		result := event{Event: "auth_result", Provider: provider, SessionID: session, Code: code}
		if code == "ok" {
			result.AccountID = c.AccountID
		}
		_ = a.events.emit(result)
	}()
}

func (a *application) handle(c command) bool {
	switch c.Command {
	case "auth":
		provider := c.Provider
		if provider == "" {
			provider = "antigravity"
		}
		a.beginAuth(c.RequestID, provider)
	case "cancel_auth":
		a.mu.Lock()
		if a.authSession == c.RequestID && a.authCancel != nil {
			a.authCancel()
		}
		a.mu.Unlock()
	case "persist_result":
		a.mu.Lock()
		if channel := a.pending[c.RequestID]; channel != nil {
			select {
			case channel <- c.OK:
			default:
			}
		}
		a.mu.Unlock()
	case "remove":
		a.pool.remove(c.AccountID, c.Generation)
	case "set_enabled":
		a.pool.setEnabled(c.AccountID, c.Generation, c.Enabled, c.ConcurrencyLimit)
		if c.Enabled {
			a.requestCatalog()
		}
	case "snapshot":
		a.snapshot()
	case "refresh_models":
		a.requestCatalog()
	case "shutdown":
		return false
	default:
		_ = a.events.emit(event{Event: "error", Code: "invalid_command"})
	}
	return true
}

func decodeStrict(line []byte, value any) error {
	d := json.NewDecoder(bytes.NewReader(line))
	d.DisallowUnknownFields()
	if err := d.Decode(value); err != nil {
		return err
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("extra_json")
	}
	return nil
}

func run(ctx context.Context, in io.Reader, out io.Writer) error {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 4096), maxIPCBytes)
	if !scanner.Scan() {
		return errors.New("missing_startup")
	}
	var configuration startup
	if decodeStrict(scanner.Bytes(), &configuration) != nil || configuration.validate() != nil {
		return errors.New("invalid_startup")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	a := &application{ctx: ctx, pool: newPool(configuration.Accounts), backend: newBackendRouter(configuration.NetworkProxy),
		events: &events{out: out}, pending: map[string]chan bool{}, catalogRequests: make(chan struct{}, 1)}
	a.pool.changed = a.snapshot
	g := &gateway{pool: a.pool, backend: a.backend, persist: a.persist, key: configuration.ClientKey}
	server, port, err := startGateway(ctx, configuration.Port, g)
	if err != nil {
		return err
	}
	defer server.Close()
	_ = a.events.emit(event{Event: "ready", Port: port, Providers: a.backend.names()})
	a.snapshot()
	go a.catalogLoop()
	a.requestCatalog()
	done := make(chan struct{})
	go func() {
		defer close(done)
		for scanner.Scan() {
			var c command
			if decodeStrict(scanner.Bytes(), &c) != nil {
				_ = a.events.emit(event{Event: "error", Code: "invalid_command"})
				continue
			}
			if !a.handle(c) {
				return
			}
		}
	}()
	select {
	case <-ctx.Done():
	case <-done:
	}
	return nil
}

func main() {
	// Upstream diagnostics can include upstream bodies and account data. stdout
	// is reserved for the private structured IPC; stderr is never a log sink.
	log.SetOutput(io.Discard)
	logrus.SetOutput(io.Discard)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, os.Stdin, os.Stdout); err != nil {
		_ = (&events{out: os.Stdout}).emit(event{Event: "error", Code: "startup_failed"})
		os.Exit(1)
	}
}
