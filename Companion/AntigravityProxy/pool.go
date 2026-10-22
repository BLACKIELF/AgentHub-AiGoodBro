package main

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

const catalogTTL = 15 * time.Minute

type poolEntry struct {
	view        accountView
	credential  credential
	catalogAt   time.Time
	preparation sync.Mutex
	requests    map[string]context.CancelFunc
}

type pool struct {
	mu      sync.Mutex
	entries map[string]*poolEntry
	order   []string
	cursor  int
	now     func() time.Time
	changed func()
}

func newPool(accounts []savedAccount) *pool {
	p := &pool{entries: map[string]*poolEntry{}, now: time.Now, changed: func() {}}
	for _, a := range accounts {
		p.add(a)
	}
	return p
}

func (p *pool) add(a savedAccount) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.entries[a.Credential.AccountID] != nil || len(p.entries) >= 100 {
		return false
	}
	p.entries[a.Credential.AccountID] = &poolEntry{
		view: accountView{ID: a.Credential.AccountID, Provider: a.Credential.Provider, Generation: a.Credential.Generation,
			MaskedIdentity: a.Credential.MaskedIdentity, Enabled: a.Enabled,
			ConcurrencyLimit: a.ConcurrencyLimit, CooldownUntil: a.CooldownUntil, State: "checking", Models: []string{}},
		credential: a.Credential, requests: map[string]context.CancelFunc{},
	}
	p.order = append(p.order, a.Credential.AccountID)
	return true
}

func (p *pool) remove(id, generation string) {
	p.mu.Lock()
	e := p.entries[id]
	if e != nil && e.view.Generation == generation {
		delete(p.entries, id)
		for _, cancel := range e.requests {
			cancel()
		}
		for i, value := range p.order {
			if value == id {
				p.order = append(p.order[:i], p.order[i+1:]...)
				break
			}
		}
	}
	p.mu.Unlock()
	p.changed()
}

func (p *pool) setEnabled(id, generation string, enabled bool, limit int) {
	p.mu.Lock()
	if e := p.entries[id]; e != nil && e.view.Generation == generation {
		e.view.Enabled = enabled
		if limit >= 1 && limit <= 8 {
			e.view.ConcurrencyLimit = limit
		}
	}
	p.mu.Unlock()
	p.changed()
}

func (p *pool) snapshots() ([]accountView, []string) {
	return p.snapshotsForProvider("")
}

func (p *pool) snapshotsForProvider(provider string) ([]accountView, []string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	rows := make([]accountView, 0, len(p.entries))
	models := map[string]bool{}
	now := p.now()
	for _, id := range p.order {
		e := p.entries[id]
		if e == nil || (provider != "" && e.view.Provider != provider) {
			continue
		}
		v := e.view
		v.Models = append([]string{}, e.view.Models...)
		switch {
		case !v.Enabled:
			v.State = "disabled"
		case v.State == "reauth_required":
		case v.CooldownUntil > now.Unix():
			v.State = "cooling"
		case v.InFlight > 0:
			v.State = "busy"
		case len(v.Models) == 0 || e.catalogAt.IsZero() || now.Sub(e.catalogAt) > catalogTTL:
			v.State = "checking"
		default:
			v.State = "ready"
		}
		if v.Enabled && v.State != "reauth_required" && !e.catalogAt.IsZero() && now.Sub(e.catalogAt) <= catalogTTL {
			for _, m := range v.Models {
				models[m] = true
			}
		}
		rows = append(rows, v)
	}
	all := make([]string, 0, len(models))
	for m := range models {
		all = append(all, m)
	}
	sort.Strings(all)
	return rows, all
}

type lease struct {
	pool   *pool
	entry  *poolEntry
	id     string
	ctx    context.Context
	cancel context.CancelFunc
	once   sync.Once
}

func (p *pool) acquire(ctx context.Context, model string, tried map[string]bool) (*lease, error) {
	return p.acquireProvider(ctx, "antigravity", model, tried)
}

func (p *pool) acquireProvider(ctx context.Context, provider, model string, tried map[string]bool) (*lease, error) {
	p.mu.Lock()
	now := p.now()
	var selected *poolEntry
	chosen := -1
	modelFound := false
	for offset := 0; offset < len(p.order); offset++ {
		i := (p.cursor + offset) % len(p.order)
		e := p.entries[p.order[i]]
		if e == nil || e.view.Provider != provider || !e.view.Enabled || e.view.State == "reauth_required" ||
			e.catalogAt.IsZero() || now.Sub(e.catalogAt) > catalogTTL {
			continue
		}
		found := false
		for _, m := range e.view.Models {
			if m == model {
				found = true
				break
			}
		}
		if !found {
			continue
		}
		modelFound = true
		if tried[e.view.ID] || e.view.CooldownUntil > now.Unix() || e.view.InFlight >= e.view.ConcurrencyLimit {
			continue
		}
		if selected == nil || e.view.InFlight < selected.view.InFlight {
			selected, chosen = e, i
		}
	}
	if selected == nil {
		p.mu.Unlock()
		if !modelFound {
			return nil, errors.New("model_unavailable")
		}
		return nil, errors.New("pool_busy_or_cooling")
	}
	leaseCtx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	l := &lease{pool: p, entry: selected, id: randomID(), ctx: leaseCtx, cancel: cancel}
	selected.view.InFlight++
	selected.requests[l.id] = cancel
	p.cursor = (chosen + 1) % len(p.order)
	p.mu.Unlock()
	p.changed()
	return l, nil
}

func (l *lease) finish(err error) {
	l.once.Do(func() {
		l.cancel()
		p := l.pool
		p.mu.Lock()
		if p.entries[l.entry.view.ID] == l.entry {
			delete(l.entry.requests, l.id)
			l.entry.view.InFlight--
			p.recordErrorLocked(l.entry, err)
		}
		p.mu.Unlock()
		p.changed()
	})
}

func (p *pool) recordErrorLocked(e *poolEntry, err error) {
	if err == nil {
		e.view.LastError = ""
		return
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return
	}
	status := statusCode(err)
	switch status {
	case 401, 403:
		e.view.State = "reauth_required"
		e.view.LastError = "reauth_required"
	case 429:
		delay := time.Minute
		var retry interface{ RetryAfter() *time.Duration }
		if errors.As(err, &retry) && retry.RetryAfter() != nil {
			delay = *retry.RetryAfter()
		}
		if delay < time.Second {
			delay = time.Second
		}
		if delay > 24*time.Hour {
			delay = 24 * time.Hour
		}
		e.view.CooldownUntil = p.now().Add(delay).Unix()
		e.view.LastError = "rate_limited"
	default:
		if status >= 500 {
			e.view.CooldownUntil = p.now().Add(5 * time.Second).Unix()
		}
		e.view.LastError = "upstream_unavailable"
	}
}

func statusCode(err error) int {
	var s interface{ StatusCode() int }
	if errors.As(err, &s) {
		return s.StatusCode()
	}
	return 502
}

func (p *pool) current(e *poolEntry) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.entries[e.view.ID] == e
}

// prepare serializes refresh per identity and waits for durable Keychain ACK.
// Removal changes the entry identity, fencing every late OAuth/refresh result.
func (p *pool) prepare(ctx context.Context, e *poolEntry, b backend, persist func(context.Context, credential, string, string) error) (credential, error) {
	e.preparation.Lock()
	defer e.preparation.Unlock()
	p.mu.Lock()
	if p.entries[e.view.ID] != e {
		p.mu.Unlock()
		return credential{}, context.Canceled
	}
	c := e.credential
	p.mu.Unlock()
	if c.ExpiresAt <= p.now().Add(10*time.Minute).Unix() {
		updated, err := b.refresh(ctx, c)
		if err != nil {
			return credential{}, err
		}
		if updated.Provider != c.Provider || updated.Generation != c.Generation || updated.AccountID != c.AccountID || updated.validate() != nil {
			return credential{}, errors.New("invalid_refresh")
		}
		if !p.current(e) {
			return credential{}, context.Canceled
		}
		if err := persist(ctx, updated, "refresh", ""); err != nil {
			if updated.RefreshToken != c.RefreshToken {
				return credential{}, upstreamError{status: 401}
			}
			return credential{}, err
		}
		p.mu.Lock()
		if p.entries[e.view.ID] != e {
			p.mu.Unlock()
			return credential{}, context.Canceled
		}
		e.credential = updated
		c = updated
		p.mu.Unlock()
	}
	return c, nil
}

func (p *pool) refreshCatalogs(ctx context.Context, b backend, persist func(context.Context, credential, string, string) error) {
	p.mu.Lock()
	entries := make([]*poolEntry, 0, len(p.entries))
	for _, e := range p.entries {
		if e.view.Enabled && e.view.State != "reauth_required" {
			entries = append(entries, e)
		}
	}
	p.mu.Unlock()
	jobs := make(chan *poolEntry)
	var workers sync.WaitGroup
	for range 4 {
		workers.Go(func() {
			for e := range jobs {
				callCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
				c, err := p.prepare(callCtx, e, b, persist)
				var models []string
				if err == nil {
					models, err = b.models(callCtx, c)
				}
				cancel()
				p.mu.Lock()
				if p.entries[e.view.ID] == e {
					if err == nil {
						e.view.Models = models
						e.catalogAt = p.now()
						e.view.State = "ready"
						e.view.LastError = ""
					} else {
						p.recordErrorLocked(e, err)
					}
				}
				p.mu.Unlock()
				p.changed()
			}
		})
	}
	for _, e := range entries {
		select {
		case jobs <- e:
		case <-ctx.Done():
			close(jobs)
			workers.Wait()
			return
		}
	}
	close(jobs)
	workers.Wait()
}
