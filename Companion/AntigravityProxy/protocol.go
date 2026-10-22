package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strings"
	"sync"
)

const maxIPCBytes = 1 << 20

var accountIDPattern = regexp.MustCompile(`^(ag|claude|kimi|xai)-[a-f0-9]{32}$`)
var opaqueIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{20,128}$`)
var modelPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// Credentials travel only through the private parent/child pipes. They are
// never placed in argv, environment, application events, files or HTTP replies.
type credential struct {
	Provider         string `json:"provider"`
	AccountID        string `json:"accountID"`
	Generation       string `json:"generation"`
	MaskedIdentity   string `json:"maskedIdentity"`
	AccessToken      string `json:"accessToken"`
	RefreshToken     string `json:"refreshToken"`
	ProjectID        string `json:"projectID"`
	ExpiresAt        int64  `json:"expiresAt"`
	IDToken          string `json:"idToken,omitempty"`
	DeviceID         string `json:"deviceID,omitempty"`
	AccountSubject   string `json:"accountSubject,omitempty"`
	OrganizationID   string `json:"organizationID,omitempty"`
	RefreshExpiresAt int64  `json:"refreshExpiresAt,omitempty"`
}

func (c credential) validate() error {
	if !accountIDPattern.MatchString(c.AccountID) || !opaqueIDPattern.MatchString(c.Generation) || len(c.MaskedIdentity) > 160 ||
		c.AccessToken == "" || len(c.AccessToken) > 16384 || c.RefreshToken == "" || len(c.RefreshToken) > 16384 ||
		(c.Provider == "antigravity" && c.ProjectID == "") || len(c.ProjectID) > 1024 || c.ExpiresAt <= 0 ||
		len(c.IDToken) > 16384 || len(c.DeviceID) > 1024 || len(c.AccountSubject) > 1024 || len(c.OrganizationID) > 1024 ||
		!validProviderAccount(c.Provider, c.AccountID) {
		return errors.New("invalid_credential")
	}
	return nil
}

type accountView struct {
	ID               string   `json:"id"`
	Provider         string   `json:"provider"`
	MaskedIdentity   string   `json:"maskedIdentity"`
	Generation       string   `json:"generation"`
	Enabled          bool     `json:"enabled"`
	ConcurrencyLimit int      `json:"concurrencyLimit"`
	InFlight         int      `json:"inFlight"`
	State            string   `json:"state"`
	CooldownUntil    int64    `json:"cooldownUntil,omitempty"`
	LastError        string   `json:"lastError,omitempty"`
	Models           []string `json:"models"`
}

type savedAccount struct {
	Credential       credential `json:"credential"`
	Enabled          bool       `json:"enabled"`
	ConcurrencyLimit int        `json:"concurrencyLimit"`
	CooldownUntil    int64      `json:"cooldownUntil,omitempty"`
}

type startup struct {
	SchemaVersion int            `json:"schemaVersion"`
	ClientKey     string         `json:"clientKey"`
	Port          int            `json:"port"`
	NetworkProxy  string         `json:"networkProxy,omitempty"`
	Accounts      []savedAccount `json:"accounts"`
}

func (s startup) validate() error {
	if s.SchemaVersion != 1 || len(s.ClientKey) < 32 || len(s.ClientKey) > 256 ||
		(s.Port != 0 && (s.Port < 1024 || s.Port > 65535)) || len(s.Accounts) > 100 {
		return errors.New("invalid_startup")
	}
	seen := map[string]bool{}
	for _, a := range s.Accounts {
		if a.Credential.validate() != nil || seen[a.Credential.AccountID] || a.ConcurrencyLimit < 1 || a.ConcurrencyLimit > 8 || a.CooldownUntil < 0 {
			return errors.New("invalid_account")
		}
		seen[a.Credential.AccountID] = true
	}
	return validateProxy(s.NetworkProxy)
}

// The command vocabulary is deliberately closed: no paths, shell commands,
// arbitrary config, HTTP management or credential export operations exist.
type command struct {
	Command          string `json:"command"`
	Provider         string `json:"provider,omitempty"`
	RequestID        string `json:"requestID,omitempty"`
	AccountID        string `json:"accountID,omitempty"`
	Generation       string `json:"generation,omitempty"`
	Enabled          bool   `json:"enabled,omitempty"`
	ConcurrencyLimit int    `json:"concurrencyLimit,omitempty"`
	OK               bool   `json:"ok,omitempty"`
}

type event struct {
	Event          string              `json:"event"`
	Provider       string              `json:"provider,omitempty"`
	Providers      []string            `json:"providers,omitempty"`
	ProviderModels map[string][]string `json:"providerModels,omitempty"`
	UserCode       string              `json:"userCode,omitempty"`
	RequestID      string              `json:"requestID,omitempty"`
	SessionID      string              `json:"sessionID,omitempty"`
	AccountID      string              `json:"accountID,omitempty"`
	Generation     string              `json:"generation,omitempty"`
	Port           int                 `json:"port,omitempty"`
	URL            string              `json:"url,omitempty"`
	Code           string              `json:"code,omitempty"`
	Purpose        string              `json:"purpose,omitempty"`
	Accounts       []accountView       `json:"accounts,omitempty"`
	Models         []string            `json:"models,omitempty"`
	Credential     *credential         `json:"credential,omitempty"`
}

func validProviderAccount(provider, id string) bool {
	prefix := map[string]string{"antigravity": "ag-", "claude": "claude-", "kimi": "kimi-", "xai": "xai-"}[provider]
	return prefix != "" && strings.HasPrefix(id, prefix) && accountIDPattern.MatchString(id)
}

type events struct {
	mu  sync.Mutex
	out io.Writer
}

func (e *events) emit(v event) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return json.NewEncoder(e.out).Encode(v)
}

func randomID() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("random_source_unavailable")
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
