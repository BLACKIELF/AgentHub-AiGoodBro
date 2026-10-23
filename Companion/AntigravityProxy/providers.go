package main

import (
	"context"
	"errors"
	"sort"

	executor "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
)

type authPrompt struct {
	URL string
	// A device user-code is intentionally visible. A device_code or OAuth
	// authorization code is secret and must never be included here.
	UserCode string
}

type authBackend interface {
	backend
	signIn(context.Context, func(authPrompt) error) (credential, error)
}

// Registration happens only during Go init, never through an external config,
// plugin, HTTP request or parent command. Omitted adapters are unavailable.
var backendFactories = map[string]func(string) authBackend{
	"antigravity": func(proxy string) authBackend { return newBackend(proxy) },
}

func registerBackend(provider string, factory func(string) authBackend) {
	if provider != "claude" && provider != "kimi" && provider != "xai" {
		panic("invalid_provider_registration")
	}
	if factory == nil || backendFactories[provider] != nil {
		panic("duplicate_provider_registration")
	}
	backendFactories[provider] = factory
}

type backendRouter struct{ providers map[string]authBackend }

func newBackendRouter(proxy string) *backendRouter {
	r := &backendRouter{providers: map[string]authBackend{}}
	for id, factory := range backendFactories {
		r.providers[id] = factory(proxy)
	}
	return r
}
func (r *backendRouter) names() []string {
	names := make([]string, 0, len(r.providers))
	for id := range r.providers {
		names = append(names, id)
	}
	sort.Strings(names)
	return names
}
func (r *backendRouter) forCredential(c credential) (authBackend, error) {
	b := r.providers[c.Provider]
	if b == nil {
		return nil, errors.New("provider_unavailable")
	}
	return b, nil
}
func (r *backendRouter) refresh(ctx context.Context, c credential) (credential, error) {
	b, e := r.forCredential(c)
	if e != nil {
		return credential{}, e
	}
	return b.refresh(ctx, c)
}
func (r *backendRouter) models(ctx context.Context, c credential) ([]string, error) {
	b, e := r.forCredential(c)
	if e != nil {
		return nil, e
	}
	return b.models(ctx, c)
}
func (r *backendRouter) execute(ctx context.Context, c credential, q executor.Request, o executor.Options) (executor.Response, error) {
	b, e := r.forCredential(c)
	if e != nil {
		return executor.Response{}, e
	}
	return b.execute(ctx, c, q, o)
}
func (r *backendRouter) stream(ctx context.Context, c credential, q executor.Request, o executor.Options) (*executor.StreamResult, error) {
	b, e := r.forCredential(c)
	if e != nil {
		return nil, e
	}
	return b.stream(ctx, c, q, o)
}
func (r *backendRouter) count(ctx context.Context, c credential, q executor.Request, o executor.Options) (executor.Response, error) {
	b, e := r.forCredential(c)
	if e != nil {
		return executor.Response{}, e
	}
	return b.count(ctx, c, q, o)
}
