package main

import (
	"context"
	"reflect"
	"testing"
	"time"
)

func TestCatalogCannotUndoConcurrentCredentialFailure(t *testing.T) {
	for _, change := range []string{"revoked", "refreshed"} {
		t.Run(change, func(t *testing.T) {
			p := readyPool(1)
			e := p.entries[p.order[0]]
			started, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
			b := &fakeBackend{modelsFn: func(context.Context, credential) ([]string, error) {
				close(started)
				<-release
				return []string{"synthetic-stale-model"}, nil
			}}
			go func() { p.refreshCatalogs(context.Background(), b, noPersist); close(done) }()
			<-started
			if change == "revoked" {
				lease, err := p.acquire(context.Background(), testModel, nil)
				if err != nil {
					t.Fatal("fixture lease unavailable")
				}
				lease.finish(upstreamError{status: 401})
			} else {
				advanced := time.Now().Add(2 * time.Hour)
				p.now = func() time.Time { return advanced }
				refresh := &fakeBackend{refreshFn: func(_ context.Context, c credential) (credential, error) {
					c.AccessToken = "synthetic-current-access"
					c.ExpiresAt = advanced.Add(time.Hour).Unix()
					return c, nil
				}}
				if _, err := p.prepare(context.Background(), e, refresh, noPersist); err != nil {
					t.Fatal("concurrent refresh failed")
				}
			}
			close(release)
			<-done
			if !reflect.DeepEqual(e.view.Models, []string{testModel}) {
				t.Fatal("late catalog replaced a revoked or newer credential's models")
			}
			if change == "revoked" && (e.view.State != "reauth_required" || e.view.LastError != "reauth_required") {
				t.Fatal("late catalog undid the real lease's revocation")
			}
		})
	}
}

func TestCatalogCancellationPreservesObservationsButDeadlineMarksUnknown(t *testing.T) {
	for _, cancelled := range []bool{true, false} {
		t.Run(map[bool]string{true: "cancelled", false: "deadline"}[cancelled], func(t *testing.T) {
			p := readyPool(1)
			e := p.entries[p.order[0]]
			fraction := 0.6
			e.view.ModelDetails = []modelDetail{{ID: testModel, DisplayName: "Fixture", RemainingFraction: &fraction}}
			e.view.SharedWindows = []quotaWindow{{ID: "fixture-window", Pool: "Fixture", Label: "5 hours", RemainingFraction: &fraction}}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			started, done := make(chan struct{}), make(chan struct{})
			b := &fakeBackend{modelsFn: func(ctx context.Context, _ credential) ([]string, error) {
				close(started)
				if cancelled {
					<-ctx.Done()
					return nil, ctx.Err()
				}
				return nil, context.DeadlineExceeded
			}}
			go func() { p.refreshCatalogs(ctx, b, noPersist); close(done) }()
			<-started
			if cancelled {
				cancel()
			}
			<-done
			if cancelled {
				if e.view.ModelDetails[0].RemainingFraction == nil || len(e.view.SharedWindows) != 1 || e.view.LastError != "" {
					t.Fatal("active cancellation erased valid observations")
				}
			} else if e.view.ModelDetails[0].RemainingFraction != nil || len(e.view.SharedWindows) != 0 || e.view.State == "reauth_required" {
				t.Fatal("timeout did not retain identity while marking quota unknown")
			}
		})
	}
}
