package main

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	auth "github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Tokens and upstream error text are intentionally unrepresentable here.
type safeCooldown struct {
	ID       string    `json:"id"`
	Model    string    `json:"model,omitempty"`
	Until    time.Time `json:"until"`
	Reason   string    `json:"reason,omitempty"`
	Exceeded bool      `json:"exceeded,omitempty"`
	Recover  time.Time `json:"recover,omitempty"`
	Backoff  int       `json:"backoff,omitempty"`
}
type cooldownStore struct {
	mu   sync.Mutex
	root *os.Root
}

func newCooldownStore(dir string) (*cooldownStore, error) {
	if !filepath.IsAbs(dir) || filepath.Clean(dir) != dir {
		return nil, errors.New("invalid_state_directory")
	}
	// Reject symlinks in every component before opening an anchored directory handle.
	part := string(filepath.Separator)
	for _, name := range strings.Split(strings.TrimPrefix(dir, part), part) {
		part = filepath.Join(part, name)
		info, err := os.Lstat(part)
		if os.IsNotExist(err) {
			if err = os.Mkdir(part, 0700); err != nil {
				return nil, err
			}
			info, err = os.Lstat(part)
		}
		if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return nil, errors.New("invalid_state_directory")
		}
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, err
	}
	f, err := root.Open(".")
	if err != nil {
		root.Close()
		return nil, err
	}
	err = f.Chmod(0700)
	f.Close()
	if err != nil {
		root.Close()
		return nil, err
	}
	return &cooldownStore{root: root}, nil
}
func (s *cooldownStore) Load(ctx context.Context) ([]auth.CooldownStateRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	f, err := s.root.OpenFile("cooldown.json", os.O_RDONLY|syscall.O_NOFOLLOW, 0600)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 1<<20 {
		return nil, errors.New("invalid_cooldown")
	}
	if err = f.Chmod(0600); err != nil {
		return nil, err
	}
	var rows []safeCooldown
	if json.NewDecoder(io.LimitReader(f, (1<<20)+1)).Decode(&rows) != nil {
		return nil, errors.New("invalid_cooldown")
	}
	out := make([]auth.CooldownStateRecord, 0, len(rows))
	for _, r := range rows {
		if !identifier.MatchString(r.ID) || len(r.Model) > 128 {
			return nil, errors.New("invalid_cooldown")
		}
		if !r.Until.After(time.Now()) {
			continue
		}
		reason := safeReason(r.Reason)
		out = append(out, auth.CooldownStateRecord{Provider: "codex", AuthID: r.ID, Model: r.Model, Status: "error", NextRetryAfter: r.Until, Reason: reason, Quota: auth.QuotaState{Exceeded: r.Exceeded, Reason: reason, NextRecoverAt: r.Recover, BackoffLevel: r.Backoff}})
	}
	return out, nil
}
func safeReason(s string) string {
	switch s {
	case "rate_limit", "quota_exceeded", "credential_quota", "usage_limit_reached", "unauthorized", "forbidden", "temporary_error":
		return s
	default:
		return "temporary_error"
	}
}
func (s *cooldownStore) Save(ctx context.Context, records []auth.CooldownStateRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	rows := make([]safeCooldown, 0, len(records))
	for _, r := range records {
		if !identifier.MatchString(r.AuthID) || len(r.Model) > 128 || !r.NextRetryAfter.After(time.Now()) {
			continue
		}
		reason := r.Reason
		if r.Quota.Reason != "" {
			reason = r.Quota.Reason
		}
		rows = append(rows, safeCooldown{r.AuthID, r.Model, r.NextRetryAfter, safeReason(reason), r.Quota.Exceeded, r.Quota.NextRecoverAt, r.Quota.BackoffLevel})
	}
	name := ".cooldown-" + uuid.NewString()
	f, err := s.root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	defer s.root.Remove(name)
	if err = json.NewEncoder(f).Encode(rows); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return s.root.Rename(name, "cooldown.json")
}
