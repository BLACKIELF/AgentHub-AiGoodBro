package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

const maxIPCBytes = 1 << 20

// Snapshot JSON has a joint 32 MiB budget, independent of the unchanged 1 MiB
// command/credential budget. Per-field bounds do not promise every maximum
// combination fits. Oversized snapshots fail closed; no account is truncated.
const maxSnapshotBytes = 32 << 20

var errSnapshotTooLarge = errors.New("snapshot_too_large")

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

// Length-prefixed UTF-8 fields match the native host without depending on JSON
// key ordering. This digest is private IPC/Keychain CAS metadata, never telemetry.
func (c credential) fingerprint() string {
	fields := []string{c.Provider, c.AccountID, c.Generation, c.MaskedIdentity, c.AccessToken, c.RefreshToken,
		c.ProjectID, strconv.FormatInt(c.ExpiresAt, 10), c.IDToken, c.DeviceID, c.AccountSubject,
		c.OrganizationID, strconv.FormatInt(c.RefreshExpiresAt, 10)}
	h := sha256.New()
	_, _ = io.WriteString(h, "aigoodbro-proxy-credential-v1\x00")
	for _, field := range fields {
		_, _ = io.WriteString(h, strconv.Itoa(len(field))+":"+field)
	}
	return hex.EncodeToString(h.Sum(nil))
}

type pendingRefresh struct {
	BaseFingerprint string     `json:"baseFingerprint"`
	Credential      credential `json:"credential"`
}

func (p pendingRefresh) matchesPromoted(active credential) bool {
	decoded, err := hex.DecodeString(p.BaseFingerprint)
	return err == nil && len(decoded) == sha256.Size && p.Credential == active && active.validate() == nil &&
		active.Provider == "xai" && active.AccountSubject != "" && active.AccountID == providerAccountID(active.Provider, active.AccountSubject)
}

func (p pendingRefresh) validFor(active credential) bool {
	c := p.Credential
	return len(p.BaseFingerprint) == 64 && p.BaseFingerprint == active.fingerprint() &&
		c.validate() == nil && c.Provider == "xai" && c.Provider == active.Provider &&
		c.AccountID == active.AccountID && c.Generation == active.Generation && c.MaskedIdentity == active.MaskedIdentity &&
		c.AccountSubject != "" && c.AccountSubject == active.AccountSubject && c.AccountID == providerAccountID(c.Provider, c.AccountSubject) &&
		c.ProjectID == active.ProjectID && c.DeviceID == active.DeviceID && c.OrganizationID == active.OrganizationID &&
		c.RefreshExpiresAt == active.RefreshExpiresAt
}

type accountView struct {
	ID                    string        `json:"id"`
	Provider              string        `json:"provider"`
	MaskedIdentity        string        `json:"maskedIdentity"`
	Generation            string        `json:"generation"`
	Enabled               bool          `json:"enabled"`
	ConcurrencyLimit      int           `json:"concurrencyLimit"`
	InFlight              int           `json:"inFlight"`
	State                 string        `json:"state"`
	CooldownUntil         int64         `json:"cooldownUntil,omitempty"`
	LastError             string        `json:"lastError,omitempty"`
	Models                []string      `json:"models"`
	ModelDetails          []modelDetail `json:"modelDetails,omitempty"`
	ModelDetailsUpdatedAt int64         `json:"modelDetailsUpdatedAt,omitempty"`
	SharedWindows         []quotaWindow `json:"sharedWindows,omitempty"`
	QuotaIssue            string        `json:"quotaIssue,omitempty"`
}

type savedAccount struct {
	Credential       credential      `json:"credential"`
	PendingRefresh   *pendingRefresh `json:"pendingRefresh,omitempty"`
	Enabled          bool            `json:"enabled"`
	ConcurrencyLimit int             `json:"concurrencyLimit"`
	CooldownUntil    int64           `json:"cooldownUntil,omitempty"`
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
		if a.PendingRefresh != nil && !a.PendingRefresh.validFor(a.Credential) && !a.PendingRefresh.matchesPromoted(a.Credential) {
			return errors.New("invalid_pending_refresh")
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
	Event                         string              `json:"event"`
	Provider                      string              `json:"provider,omitempty"`
	Providers                     []string            `json:"providers,omitempty"`
	ProviderModels                map[string][]string `json:"providerModels,omitempty"`
	UserCode                      string              `json:"userCode,omitempty"`
	RequestID                     string              `json:"requestID,omitempty"`
	SessionID                     string              `json:"sessionID,omitempty"`
	AccountID                     string              `json:"accountID,omitempty"`
	Generation                    string              `json:"generation,omitempty"`
	Port                          int                 `json:"port,omitempty"`
	URL                           string              `json:"url,omitempty"`
	Code                          string              `json:"code,omitempty"`
	Purpose                       string              `json:"purpose,omitempty"`
	Accounts                      []accountView       `json:"accounts,omitempty"`
	Models                        []string            `json:"models,omitempty"`
	Credential                    *credential         `json:"credential,omitempty"`
	ExpectedCredentialFingerprint string              `json:"expectedCredentialFingerprint,omitempty"`
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
	data, err := encodeEvent(v)
	if err != nil {
		if errors.Is(err, errSnapshotTooLarge) {
			// The native host treats this fixed code as fatal and stops the
			// helper. No part of the rejected snapshot reaches stdout.
			_, _ = io.WriteString(e.out, "{\"event\":\"error\",\"code\":\"snapshot_too_large\"}\n")
		}
		return err
	}
	_, err = e.out.Write(append(data, '\n'))
	return err
}

func encodeEvent(v event) ([]byte, error) {
	if v.Event != "snapshot" {
		data, err := json.Marshal(v)
		if err == nil && len(data) >= maxIPCBytes {
			err = errors.New("ipc_event_too_large")
		}
		return data, err
	}
	// Encode accounts separately so an extreme product of legal field counts
	// cannot first allocate a gigabyte JSON frame. Buffer grows only as needed.
	accounts := v.Accounts
	v.Accounts = nil
	header, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var buffer bytes.Buffer
	write := func(data []byte) error {
		if len(data) > maxSnapshotBytes-buffer.Len() {
			return errSnapshotTooLarge
		}
		_, err := buffer.Write(data)
		return err
	}
	if err = write(header[:len(header)-1]); err != nil {
		return nil, err
	}
	if len(accounts) > 0 {
		if err = write([]byte(",\"accounts\":[")); err != nil {
			return nil, err
		}
		for i, account := range accounts {
			if i > 0 {
				if err = write([]byte(",")); err != nil {
					return nil, err
				}
			}
			encoded, err := json.Marshal(account)
			if err != nil {
				return nil, err
			}
			if err = write(encoded); err != nil {
				return nil, err
			}
		}
		if err = write([]byte("]")); err != nil {
			return nil, err
		}
	}
	if err = write([]byte("}")); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

func randomID() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("random_source_unavailable")
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
