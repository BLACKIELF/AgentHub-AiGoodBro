package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type TaskState string

const (
	stateAwaitingApproval     TaskState = "awaiting_approval"
	stateStarting             TaskState = "starting"
	stateRunning              TaskState = "running"
	stateCancelRequested      TaskState = "cancel_requested"
	stateSucceeded            TaskState = "succeeded"
	stateFailed               TaskState = "failed"
	stateCancelled            TaskState = "cancelled"
	stateUncertain            TaskState = "uncertain"
	stateBlockedConfiguration TaskState = "blocked_configuration"
)

var (
	errConflict                  = errors.New("conflict")
	errBusy                      = errors.New("project_busy")
	errAccountBusy               = errors.New("account_busy")
	errInvalid                   = errors.New("invalid_request")
	errNotFound                  = errors.New("not_found")
	errAccountQuotaReserve       = errors.New("account_quota_reserve")
	errDispatchDisabled          = errors.New("account_dispatch_disabled")
	errDispatchPolicyUnavailable = errors.New("dispatch_policy_unavailable")
)

const (
	maxTaskPromptBytes                = 64 * 1024
	defaultApprovalQuotaMaxAgeSeconds = 300
	minimumApprovalQuotaMaxAgeSeconds = 60
	maximumApprovalQuotaMaxAgeSeconds = 3600
	presetRoleName                    = "next_preset_worker"
)

type inputHashes struct {
	OriginalBriefSHA256       string `json:"originalBriefSHA256"`
	CollaborationPolicySHA256 string `json:"collaborationPolicySHA256"`
	EffectiveInputSHA256      string `json:"effectiveInputSHA256"`
}

type subagentExecution struct {
	RequestedMode     string `json:"requestedMode"`
	RequestedRole     string `json:"requestedRole,omitempty"`
	RequestedModel    string `json:"requestedModel,omitempty"`
	RequestedEffort   string `json:"requestedEffort,omitempty"`
	ConcurrentThreads int    `json:"concurrentThreads,omitempty"`
	RoleSHA256        string `json:"roleSHA256,omitempty"`
	CLISHA256         string `json:"cliSHA256,omitempty"`
	Observed          any    `json:"observed,omitempty"`
}

type Config struct {
	Listen                     string            `json:"listen"`
	DataDir                    string            `json:"dataDir"`
	TokenFile                  string            `json:"tokenFile"`
	KimiAutomationsDir         string            `json:"kimiAutomationsDir"`
	ApprovalTTLSeconds         int               `json:"approvalTTLSeconds"`
	ApprovalQuotaMaxAgeSeconds int               `json:"approvalQuotaMaxAgeSeconds"`
	Mode                       string            `json:"mode"`
	RequireToken               *bool             `json:"requireToken"`
	ClaudeMaxBudgetUSD         float64           `json:"claudeMaxBudgetUSD"`
	AccountStrategy            string            `json:"accountStrategy"`
	Accounts                   []AccountConfig   `json:"accounts"`
	Commands                   map[string]string `json:"commands"`
	Projects                   map[string]string `json:"projects"`
}

type AccountConfig struct {
	Alias            string `json:"alias"`
	Home             string `json:"home"`
	DispatchDisabled bool   `json:"dispatchDisabled,omitempty"`
}

type Task struct {
	DispatchLeaseID              string               `json:"dispatchLeaseId,omitempty"`
	ID                           string               `json:"id"`
	Version                      uint64               `json:"version"`
	Agent                        string               `json:"agent"`
	Project                      string               `json:"project"`
	AccountAlias                 string               `json:"accountAlias,omitempty"`
	State                        TaskState            `json:"state"`
	ActionHash                   string               `json:"actionHash"`
	PromptHash                   string               `json:"promptHash"`
	ResumeOf                     string               `json:"resumeOf,omitempty"`
	SessionID                    string               `json:"sessionId,omitempty"`
	SessionVerified              bool                 `json:"sessionVerified,omitempty"`
	PID                          int                  `json:"pid,omitempty"`
	ReasonCode                   string               `json:"reasonCode,omitempty"`
	ResultNote                   string               `json:"resultNote,omitempty"`
	ExecutionPreference          *executionPreference `json:"executionPreference,omitempty"`
	EffectiveExecutionPreference *executionPreference `json:"effectiveExecutionPreference,omitempty"`
	InputHashes                  *inputHashes         `json:"inputHashes,omitempty"`
	SubagentExecution            *subagentExecution   `json:"subagentExecution,omitempty"`
	CreatedAt                    time.Time            `json:"createdAt"`
	UpdatedAt                    time.Time            `json:"updatedAt"`
	ApprovalExpiresAt            time.Time            `json:"approvalExpiresAt"`
}

type TaskDTO struct {
	ID                           string               `json:"id"`
	Version                      uint64               `json:"version"`
	Agent                        string               `json:"agent"`
	Project                      string               `json:"project"`
	Account                      string               `json:"accountAlias,omitempty"`
	State                        TaskState            `json:"state"`
	ActionHash                   string               `json:"actionHash,omitempty"`
	CanResume                    bool                 `json:"canResume"`
	ReasonCode                   string               `json:"reasonCode,omitempty"`
	ResultNote                   string               `json:"resultNote,omitempty"`
	ExecutionPreference          *executionPreference `json:"executionPreference,omitempty"`
	EffectiveExecutionPreference *executionPreference `json:"effectiveExecutionPreference,omitempty"`
	InputHashes                  *inputHashes         `json:"inputHashes,omitempty"`
	SubagentExecution            *subagentExecution   `json:"subagentExecution,omitempty"`
	CreatedAt                    time.Time            `json:"createdAt"`
	UpdatedAt                    time.Time            `json:"updatedAt"`
	ApprovalExpiresAt            time.Time            `json:"approvalExpiresAt"`
	ApprovalExpired              bool                 `json:"approvalExpired"`
}

func (task *Task) dto() TaskDTO {
	return task.dtoAt(time.Now().UTC())
}

func (task *Task) dtoAt(now time.Time) TaskDTO {
	return TaskDTO{
		ID:                           task.ID,
		Version:                      task.Version,
		Agent:                        task.Agent,
		Project:                      task.Project,
		Account:                      task.AccountAlias,
		State:                        task.State,
		ActionHash:                   task.ActionHash,
		CanResume:                    task.SessionID != "" && task.SessionVerified && task.State.terminal(),
		ReasonCode:                   task.ReasonCode,
		ResultNote:                   task.ResultNote,
		ExecutionPreference:          task.ExecutionPreference,
		EffectiveExecutionPreference: task.EffectiveExecutionPreference,
		InputHashes:                  task.InputHashes,
		SubagentExecution:            task.SubagentExecution,
		CreatedAt:                    task.CreatedAt,
		UpdatedAt:                    task.UpdatedAt,
		ApprovalExpiresAt:            task.ApprovalExpiresAt,
		ApprovalExpired:              task.approvalExpired(now),
	}
}

func (task *Task) approvalExpired(now time.Time) bool {
	return task.State == stateAwaitingApproval && !task.ApprovalExpiresAt.IsZero() && !task.ApprovalExpiresAt.After(now)
}

func (state TaskState) terminal() bool {
	switch state {
	case stateSucceeded, stateFailed, stateCancelled, stateBlockedConfiguration:
		return true
	default:
		return false
	}
}

func (state TaskState) holdsLease() bool {
	switch state {
	case stateStarting, stateRunning, stateCancelRequested, stateUncertain:
		return true
	default:
		return false
	}
}

func (task *Task) holdsAccountLeaseAt(now time.Time) bool {
	if task.AccountAlias == "" || task.AccountAlias == "system" {
		return false
	}
	if task.State == stateAwaitingApproval {
		return !task.approvalExpired(now)
	}
	return task.State.holdsLease()
}

var allowedTransitions = map[TaskState]map[TaskState]bool{
	stateAwaitingApproval: {
		stateStarting: true, stateCancelled: true, stateBlockedConfiguration: true,
	},
	stateStarting: {
		stateRunning: true, stateCancelRequested: true, stateBlockedConfiguration: true, stateUncertain: true,
	},
	stateRunning: {
		stateSucceeded: true, stateFailed: true, stateCancelRequested: true, stateUncertain: true,
	},
	stateCancelRequested:      {stateCancelled: true, stateUncertain: true},
	stateUncertain:            {stateFailed: true},
	stateBlockedConfiguration: {stateCancelled: true},
}

type PublicEvent struct {
	Seq           uint64        `json:"seq,omitempty"`
	Version       int           `json:"version"`
	TaskID        string        `json:"taskId,omitempty"`
	FindingID     string        `json:"findingId,omitempty"`
	Type          string        `json:"type"`
	From          TaskState     `json:"from,omitempty"`
	To            TaskState     `json:"to,omitempty"`
	ReasonCode    string        `json:"reasonCode,omitempty"`
	OccurredAt    time.Time     `json:"occurredAt"`
	Task          *TaskDTO      `json:"task,omitempty"`
	Finding       *FindingDTO   `json:"finding,omitempty"`
	FindingChange *FindingEvent `json:"findingEvent,omitempty"`
	Stream        string        `json:"stream,omitempty"`
	OutputKind    string        `json:"outputKind,omitempty"`
	MessageOffset int           `json:"messageOffset,omitempty"`
	Text          string        `json:"text,omitempty"`
}

type requestRecord struct {
	RequestHash string `json:"requestHash"`
	BodyHash    string `json:"bodyHash"`
	TaskID      string `json:"taskId,omitempty"`
	FindingID   string `json:"findingId,omitempty"`
}

type journalEvent struct {
	RecordKind   string         `json:"recordKind,omitempty"`
	Event        PublicEvent    `json:"event"`
	Record       *Task          `json:"record,omitempty"`
	Finding      *Finding       `json:"finding,omitempty"`
	FindingEvent *FindingEvent  `json:"findingEvent,omitempty"`
	Request      *requestRecord `json:"request,omitempty"`
}

func validateJournalEnvelope(entry journalEvent) (string, error) {
	kind := entry.RecordKind
	if kind == "" {
		kind = "task"
	}
	switch kind {
	case "task":
		if entry.Record == nil || entry.Finding != nil || entry.FindingEvent != nil || entry.Event.TaskID != entry.Record.ID || entry.Event.FindingID != "" || entry.Event.Task == nil || entry.Event.Finding != nil || entry.Event.FindingChange != nil || entry.Event.Version != 1 || entry.Event.To != entry.Record.State || entry.Event.ReasonCode != entry.Record.ReasonCode || !entry.Event.OccurredAt.Equal(entry.Record.UpdatedAt) || entry.Event.Stream != "" || entry.Event.Text != "" || !strings.HasPrefix(entry.Event.Type, "task.") {
			return "", errInvalid
		}
		// Do not compare the full event snapshot with the current DTO. DTOs evolve,
		// and older journal snapshots must remain replayable when fields are added.
		// The explicit envelope checks above cover the integrity-critical fields.
		if entry.Request != nil && (entry.Request.TaskID != entry.Record.ID || entry.Request.FindingID != "") {
			return "", errInvalid
		}
	case "finding":
		if entry.Record != nil || entry.Finding == nil || entry.FindingEvent == nil || entry.Event.FindingID != entry.Finding.ID || entry.Event.TaskID != "" || entry.Event.Task != nil || entry.Event.Finding == nil || entry.Event.FindingChange == nil || entry.Event.Version != 1 || entry.Event.From != "" || entry.Event.To != "" || entry.Event.ReasonCode != "" || entry.Event.Stream != "" || entry.Event.Text != "" || entry.Event.Type != "finding."+entry.FindingEvent.EventType || !entry.Event.OccurredAt.Equal(entry.Finding.UpdatedAt) {
			return "", errInvalid
		}
		// Do not compare full snapshots with current DTOs. Explicit envelope and
		// transition checks preserve integrity without breaking schema evolution.
		if entry.FindingEvent.FindingID != entry.Finding.ID || entry.Request != nil && (entry.Request.FindingID != entry.Finding.ID || entry.Request.TaskID != "") {
			return "", errInvalid
		}
	default:
		return "", errInvalid
	}
	if entry.Request != nil && (!validDigest(entry.Request.RequestHash) || !validDigest(entry.Request.BodyHash)) {
		return "", errInvalid
	}
	return kind, nil
}

func validDigest(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

type Store struct {
	file    *os.File
	lastSeq uint64
	records []journalEvent
	events  []PublicEvent
	failed  bool
}

func openStore(dataDir string) (*Store, error) {
	if err := ensurePrivateDir(dataDir); err != nil {
		return nil, err
	}
	path := filepath.Join(dataDir, "events.ndjson")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|os.O_APPEND, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open_journal")
	}
	info, err := file.Stat()
	if err != nil || info.Mode().Perm()&0o077 != 0 {
		file.Close()
		return nil, fmt.Errorf("journal_permissions")
	}
	if err := lockFile(file); err != nil {
		file.Close()
		return nil, fmt.Errorf("journal_locked")
	}
	if err := truncateIncompleteTail(file, info.Size()); err != nil {
		unlockFile(file)
		file.Close()
		return nil, err
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		unlockFile(file)
		file.Close()
		return nil, fmt.Errorf("journal_seek")
	}
	store := &Store{file: file}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		var entry journalEvent
		if err := json.Unmarshal(scanner.Bytes(), &entry); err != nil {
			store.Close()
			return nil, fmt.Errorf("journal_corrupt")
		}
		kind, err := validateJournalEnvelope(entry)
		if err != nil || entry.Event.Seq != store.lastSeq+1 {
			store.Close()
			return nil, fmt.Errorf("journal_sequence")
		}
		entry.RecordKind = kind
		store.lastSeq = entry.Event.Seq
		store.records = append(store.records, entry)
		store.events = append(store.events, entry.Event)
	}
	if err := scanner.Err(); err != nil {
		store.Close()
		return nil, fmt.Errorf("journal_read")
	}
	if _, err := file.Seek(0, io.SeekEnd); err != nil {
		store.Close()
		return nil, fmt.Errorf("journal_seek")
	}
	return store, nil
}

func truncateIncompleteTail(file *os.File, size int64) error {
	if size == 0 {
		return nil
	}
	var last [1]byte
	if _, err := file.ReadAt(last[:], size-1); err != nil {
		return fmt.Errorf("journal_read")
	}
	if last[0] == '\n' {
		return nil
	}
	buffer := make([]byte, 64*1024)
	for end := size; end > 0; {
		start := end - int64(len(buffer))
		if start < 0 {
			start = 0
		}
		chunk := buffer[:end-start]
		n, err := file.ReadAt(chunk, start)
		if err != nil && !errors.Is(err, io.EOF) {
			return fmt.Errorf("journal_read")
		}
		if index := bytes.LastIndexByte(chunk[:n], '\n'); index >= 0 {
			if err := file.Truncate(start + int64(index) + 1); err != nil {
				return fmt.Errorf("journal_recover")
			}
			if err := file.Sync(); err != nil {
				return fmt.Errorf("journal_sync")
			}
			return nil
		}
		end = start
	}
	if err := file.Truncate(0); err != nil {
		return fmt.Errorf("journal_recover")
	}
	if err := file.Sync(); err != nil {
		return fmt.Errorf("journal_sync")
	}
	return nil
}

func ensurePrivateDir(path string) error {
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(path, 0o700); err != nil {
			return fmt.Errorf("data_dir_create")
		}
		return nil
	}
	if err != nil || !info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("data_dir_permissions")
	}
	return nil
}

func (store *Store) append(entry journalEvent) (PublicEvent, error) {
	if store.failed || store.file == nil {
		return PublicEvent{}, fmt.Errorf("journal_unavailable")
	}
	if _, err := validateJournalEnvelope(entry); err != nil {
		return PublicEvent{}, err
	}
	entry.Event.Seq = store.lastSeq + 1
	line, err := json.Marshal(entry)
	if err != nil {
		return PublicEvent{}, err
	}
	line = append(line, '\n')
	n, err := store.file.Write(line)
	if err != nil || n != len(line) {
		store.failed = true
		return PublicEvent{}, fmt.Errorf("journal_write")
	}
	if err := store.file.Sync(); err != nil {
		store.failed = true
		return PublicEvent{}, fmt.Errorf("journal_sync")
	}
	store.lastSeq = entry.Event.Seq
	store.records = append(store.records, entry)
	store.events = append(store.events, entry.Event)
	return entry.Event, nil
}

func (store *Store) eventsAfter(seq uint64) []PublicEvent {
	if seq >= store.lastSeq {
		return nil
	}
	result := make([]PublicEvent, 0)
	for _, event := range store.events {
		if event.Seq > seq {
			result = append(result, event)
		}
	}
	return result
}

func (store *Store) Close() error {
	if store == nil || store.file == nil {
		return nil
	}
	_ = unlockFile(store.file)
	err := store.file.Close()
	store.file = nil
	return err
}

type processHandle struct {
	pid          int
	process      *os.Process
	done         chan struct{}
	exitOnce     sync.Once
	exitDone     chan struct{}
	stopOnce     sync.Once
	stopDone     chan struct{}
	groupStopped bool
}

type Hub struct {
	mu                  sync.Mutex
	config              Config
	store               *Store
	messageStore        *taskMessageStore
	tasks               map[string]*Task
	findings            map[string]*Finding
	findingEvents       map[string][]FindingEvent
	requests            map[string]requestRecord
	pendingPrompts      map[string]string
	handles             map[string]*processHandle
	leases              map[string]string
	accountCursor       int
	accountUsed         map[string]uint64
	accountTick         uint64
	managerSnapshotPath string
	activityDirectory   string
	dispatchPolicyPath  string
	subscribers         map[chan PublicEvent]struct{}
	sensitiveValues     []string
	closed              bool
	poisoned            bool
	storeClosed         bool
}

func newHub(config Config, sensitive ...string) (*Hub, error) {
	store, err := openStore(config.DataDir)
	if err != nil {
		return nil, err
	}
	hub := &Hub{
		config:              config,
		store:               store,
		tasks:               make(map[string]*Task),
		findings:            make(map[string]*Finding),
		findingEvents:       make(map[string][]FindingEvent),
		requests:            make(map[string]requestRecord),
		pendingPrompts:      make(map[string]string),
		handles:             make(map[string]*processHandle),
		leases:              make(map[string]string),
		accountUsed:         make(map[string]uint64),
		subscribers:         make(map[chan PublicEvent]struct{}),
		managerSnapshotPath: defaultManagerSnapshotPath(),
	}
	values := append(sensitive, config.DataDir, config.TokenFile, config.KimiAutomationsDir)
	for _, project := range config.Projects {
		values = append(values, project)
	}
	for _, account := range config.Accounts {
		values = append(values, account.Home)
	}
	if home, err := os.UserHomeDir(); err == nil {
		values = append(values, home)
	}
	seen := make(map[string]bool)
	for _, value := range values {
		if value != "" && !seen[value] {
			seen[value] = true
			hub.sensitiveValues = append(hub.sensitiveValues, value)
		}
	}
	sort.Slice(hub.sensitiveValues, func(i, j int) bool {
		return len(hub.sensitiveValues[i]) > len(hub.sensitiveValues[j])
	})
	for _, entry := range store.records {
		switch entry.RecordKind {
		case "task":
			copy := *entry.Record
			hub.tasks[copy.ID] = &copy
		case "finding":
			copy := *entry.Finding
			previous := hub.findings[copy.ID]
			if err := validateFindingReplay(hub, previous, &copy, entry.FindingEvent); err != nil {
				store.Close()
				return nil, fmt.Errorf("journal_finding_invalid")
			}
			hub.findings[copy.ID] = &copy
			hub.findingEvents[copy.ID] = append(hub.findingEvents[copy.ID], *entry.FindingEvent)
		}
		if entry.Request != nil {
			if _, exists := hub.requests[entry.Request.RequestHash]; exists {
				store.Close()
				return nil, fmt.Errorf("journal_request_duplicate")
			}
			hub.requests[entry.Request.RequestHash] = *entry.Request
		}
	}
	for _, task := range hub.tasks {
		if task.State.holdsLease() {
			if owner := hub.conflictingProjectOwnerLocked(task.Project, task.ID); owner != "" {
				store.Close()
				return nil, fmt.Errorf("multiple_active_tasks")
			}
			hub.leases[task.Project] = task.ID
		}
	}
	for _, task := range hub.tasks {
		switch task.State {
		case stateAwaitingApproval:
			if err := hub.transitionLocked(task, stateBlockedConfiguration, "restart_prompt_unavailable", "task.recovered", nil); err != nil {
				store.Close()
				return nil, err
			}
		case stateStarting, stateRunning, stateCancelRequested:
			if err := hub.transitionLocked(task, stateUncertain, "restart_process_unverified", "task.uncertain", nil); err != nil {
				store.Close()
				return nil, err
			}
		}
	}
	accountOwners := make(map[string]string)
	for _, task := range hub.tasks {
		if !task.holdsAccountLeaseAt(time.Now().UTC()) {
			continue
		}
		if owner := accountOwners[task.AccountAlias]; owner != "" && owner != task.ID {
			store.Close()
			return nil, fmt.Errorf("multiple_active_account_tasks")
		}
		accountOwners[task.AccountAlias] = task.ID
	}
	messageStore, err := openTaskMessageStore(config.DataDir)
	if err != nil {
		store.Close()
		return nil, err
	}
	hub.messageStore = messageStore
	return hub, nil
}

type Overview struct {
	Version  string    `json:"version"`
	Seq      uint64    `json:"seq"`
	Agents   []string  `json:"agents"`
	Accounts []string  `json:"accounts"`
	Projects []string  `json:"projects"`
	Tasks    []TaskDTO `json:"tasks"`
}

func (hub *Hub) overview() Overview {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	agents := make([]string, 0, len(hub.config.Commands))
	for name := range hub.config.Commands {
		agents = append(agents, name)
	}
	accounts := make([]string, 0, len(hub.config.Accounts))
	for _, account := range hub.config.Accounts {
		accounts = append(accounts, account.Alias)
	}
	projects := make([]string, 0, len(hub.config.Projects))
	for name := range hub.config.Projects {
		projects = append(projects, name)
	}
	tasks := make([]TaskDTO, 0, len(hub.tasks))
	now := time.Now().UTC()
	for _, task := range hub.tasks {
		tasks = append(tasks, task.dtoAt(now))
	}
	sort.Strings(agents)
	sort.Strings(accounts)
	sort.Strings(projects)
	sort.Slice(tasks, func(i, j int) bool { return tasks[i].UpdatedAt.After(tasks[j].UpdatedAt) })
	return Overview{Version: version, Seq: hub.store.lastSeq, Agents: agents, Accounts: accounts, Projects: projects, Tasks: tasks}
}

func (hub *Hub) conflictingProjectOwnerLocked(project, excludingTaskID string) string {
	target, ok := hub.config.Projects[project]
	if !ok {
		return ""
	}
	target = filepath.Clean(target)
	for leasedProject, owner := range hub.leases {
		if owner == "" || owner == excludingTaskID {
			continue
		}
		if leasedRoot, ok := hub.config.Projects[leasedProject]; ok && filepath.Clean(leasedRoot) == target {
			return owner
		}
	}
	return ""
}

type CreateRequest struct {
	DispatchLeaseID string `json:"dispatchLeaseId,omitempty"`
	RequestID       string `json:"requestId"`
	Agent           string `json:"agent"`
	Project         string `json:"project"`
	AccountAlias    string `json:"accountAlias,omitempty"`
	Prompt          string `json:"prompt"`
}

func (hub *Hub) create(request CreateRequest) (TaskDTO, error) {
	return hub.createFrom(request, "")
}

func (hub *Hub) createFrom(request CreateRequest, resumeOf string) (TaskDTO, error) {
	if err := validateRequestID(request.RequestID); err != nil || request.Prompt == "" || len(request.Prompt) > maxTaskPromptBytes {
		return TaskDTO{}, errInvalid
	}
	unlockActivity, err := hub.lockDispatchActivity()
	if err != nil {
		return TaskDTO{}, err
	}
	defer unlockActivity()
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if hub.closed || hub.poisoned {
		return TaskDTO{}, errConflict
	}
	if _, ok := hub.config.Commands[request.Agent]; !ok {
		return TaskDTO{}, errInvalid
	}
	if _, ok := hub.config.Projects[request.Project]; !ok {
		return TaskDTO{}, errInvalid
	}
	if request.Agent == "kimi" {
		if request.AccountAlias != "" && request.AccountAlias != "system" {
			return TaskDTO{}, errInvalid
		}
		request.AccountAlias = "system"
	} else if request.AccountAlias != "" && !hub.hasAccountAlias(request.AccountAlias) {
		return TaskDTO{}, errInvalid
	}
	promptHash := hashText(request.Prompt)
	bodyHash := hashParts("create", request.Agent, request.Project, request.AccountAlias, promptHash, resumeOf)
	if request.DispatchLeaseID != "" {
		bodyHash = hashParts(bodyHash, request.DispatchLeaseID)
	}
	if task, found, err := hub.dedupeLocked(request.RequestID, bodyHash); found || err != nil {
		if task == nil {
			return TaskDTO{}, err
		}
		return task.dto(), err
	}
	selection, reason := hub.selectAccountForCreateLocked(request.AccountAlias, request.DispatchLeaseID)
	if reason != "" {
		if reason == errAccountBusy.Error() {
			return TaskDTO{}, errAccountBusy
		}
		if reason == errAccountQuotaReserve.Error() {
			return TaskDTO{}, errAccountQuotaReserve
		}
		if reason == errDispatchDisabled.Error() {
			return TaskDTO{}, errDispatchDisabled
		}
		if reason == errDispatchPolicyUnavailable.Error() {
			return TaskDTO{}, errDispatchPolicyUnavailable
		}
		return TaskDTO{}, errors.New(reason)
	}
	accountAlias := selection.alias
	if err := hub.dispatchActivityAllowed(accountAlias, request.Project, request.DispatchLeaseID, "", time.Now().UTC()); err != nil {
		return TaskDTO{}, err
	}
	var preference *executionPreference
	if request.Agent == "codex" && accountAlias != "system" {
		frozen, err := readManagerExecutionPreference(hub.managerSnapshotPath, hub.config.Accounts, accountAlias)
		if err != nil {
			return TaskDTO{}, errInvalid
		}
		preference = &frozen
	}
	now := time.Now().UTC()
	taskID, err := newID()
	if err != nil {
		return TaskDTO{}, err
	}
	policy := ""
	var frozenHashes *inputHashes
	var frozenSubagents *subagentExecution
	var effectivePreference *executionPreference
	if preference != nil {
		strategy := derivedExecutionStrategy(*preference)
		effective := strategy.Main
		effectivePreference = &effective
		policy = presetCollaborationPolicy(preference.SubagentMode, strategy.SubagentsEnabled)
		effectiveInput := policy + request.Prompt
		frozenHashes = &inputHashes{
			OriginalBriefSHA256:       promptHash,
			CollaborationPolicySHA256: hashText(policy),
			EffectiveInputSHA256:      hashText(effectiveInput),
		}
		frozenSubagents = &subagentExecution{RequestedMode: preference.SubagentMode}
		if strategy.SubagentsEnabled {
			roleData := generatedPresetRole(strategy.SubagentModel, strategy.SubagentReasoningEffort)
			roleSHA := hashText(string(roleData))
			cliSHA, err := hub.validatePresetCapability(preference.SubagentMode, roleSHA)
			if err != nil {
				return TaskDTO{}, errInvalid
			}
			if err := hub.freezePresetRole(taskID, roleData); err != nil {
				return TaskDTO{}, errInvalid
			}
			frozenSubagents = &subagentExecution{RequestedMode: preference.SubagentMode, RequestedRole: presetRoleName,
				RequestedModel: strategy.SubagentModel, RequestedEffort: strategy.SubagentReasoningEffort, ConcurrentThreads: 1,
				RoleSHA256: roleSHA, CLISHA256: cliSHA}
		}
	}
	task := &Task{
		DispatchLeaseID:              request.DispatchLeaseID,
		ID:                           taskID,
		Version:                      1,
		Agent:                        request.Agent,
		Project:                      request.Project,
		AccountAlias:                 accountAlias,
		State:                        stateAwaitingApproval,
		PromptHash:                   promptHash,
		ResumeOf:                     resumeOf,
		ExecutionPreference:          preference,
		EffectiveExecutionPreference: effectivePreference,
		InputHashes:                  frozenHashes,
		SubagentExecution:            frozenSubagents,
		CreatedAt:                    now,
		UpdatedAt:                    now,
		ApprovalExpiresAt:            now.Add(time.Duration(hub.config.ApprovalTTLSeconds) * time.Second),
	}
	if resumeOf != "" {
		parent := hub.tasks[resumeOf]
		if parent == nil || parent.Agent != task.Agent || parent.Project != task.Project || parent.SessionID == "" || !parent.SessionVerified || !parent.State.terminal() {
			return TaskDTO{}, errConflict
		}
		task.SessionID = parent.SessionID
		task.SessionVerified = true
	} else if task.Agent == "claude" {
		task.SessionID, err = newID()
		if err != nil {
			return TaskDTO{}, err
		}
	}
	task.ActionHash = taskActionHash(task)
	requestRecord := &requestRecord{RequestHash: hashText(request.RequestID), BodyHash: bodyHash, TaskID: task.ID}
	dto := task.dto()
	entry := journalEvent{
		RecordKind: "task",
		Event:      PublicEvent{Version: 1, TaskID: task.ID, Type: "task.created", To: task.State, OccurredAt: now, Task: &dto},
		Record:     task,
		Request:    requestRecord,
	}
	if persistTaskMessages(task.Agent) {
		if err := hub.appendTaskMessageLocked(task.ID, "user", hub.maskOutput(request.Prompt), now); err != nil {
			return TaskDTO{}, err
		}
	}
	event, err := hub.store.append(entry)
	if err != nil {
		hub.poisonLocked()
		return TaskDTO{}, err
	}
	hub.tasks[task.ID] = task
	hub.requests[requestRecord.RequestHash] = *requestRecord
	hub.pendingPrompts[task.ID] = request.Prompt
	hub.commitAccountSelectionLocked(selection)
	hub.broadcastLocked(event)
	return task.dto(), nil
}

func (hub *Hub) resume(parentID string, request CreateRequest) (TaskDTO, error) {
	hub.mu.Lock()
	if hub.closed || hub.poisoned {
		hub.mu.Unlock()
		return TaskDTO{}, errConflict
	}
	parent := hub.tasks[parentID]
	if parent == nil {
		hub.mu.Unlock()
		return TaskDTO{}, errNotFound
	}
	request.Agent = parent.Agent
	request.Project = parent.Project
	request.AccountAlias = parent.AccountAlias
	hub.mu.Unlock()
	return hub.createFrom(request, parentID)
}

type ApproveRequest struct {
	RequestID  string `json:"requestId"`
	ActionHash string `json:"actionHash"`
}

func (hub *Hub) approve(taskID string, request ApproveRequest) (TaskDTO, error) {
	return hub.approveAt(taskID, request, time.Now().UTC())
}

func (hub *Hub) approveAt(taskID string, request ApproveRequest, now time.Time) (TaskDTO, error) {
	if validateRequestID(request.RequestID) != nil || request.ActionHash == "" {
		return TaskDTO{}, errInvalid
	}
	unlockActivity, err := hub.lockDispatchActivity()
	if err != nil {
		return TaskDTO{}, err
	}
	defer unlockActivity()
	hub.mu.Lock()
	if hub.closed || hub.poisoned {
		hub.mu.Unlock()
		return TaskDTO{}, errConflict
	}
	task := hub.tasks[taskID]
	if task == nil {
		hub.mu.Unlock()
		return TaskDTO{}, errNotFound
	}
	bodyHash := hashParts("approve", taskID, request.ActionHash)
	if existing, found, err := hub.dedupeLocked(request.RequestID, bodyHash); found || err != nil {
		var dto TaskDTO
		if existing != nil {
			dto = existing.dto()
		}
		hub.mu.Unlock()
		if existing == nil {
			return TaskDTO{}, err
		}
		return dto, err
	}
	if task.State != stateAwaitingApproval || task.ActionHash != request.ActionHash || task.ActionHash != taskActionHash(task) {
		hub.mu.Unlock()
		return TaskDTO{}, errConflict
	}
	if task.Agent == "codex" && task.AccountAlias != "system" {
		preference, err := normalizedExecutionPreference(task.ExecutionPreference)
		if err != nil {
			hub.mu.Unlock()
			return TaskDTO{}, errInvalid
		}
		if task.ExecutionPreference != nil && task.ExecutionPreference.SubagentMode != "" && task.EffectiveExecutionPreference == nil {
			hub.mu.Unlock()
			return TaskDTO{}, errInvalid
		}
		strategy, err := frozenTaskExecutionStrategy(task, preference)
		if err != nil {
			hub.mu.Unlock()
			return TaskDTO{}, errInvalid
		}
		if strategy.SubagentsEnabled {
			if task.InputHashes == nil || task.SubagentExecution == nil || task.SubagentExecution.RequestedMode != preference.SubagentMode {
				hub.mu.Unlock()
				return TaskDTO{}, errInvalid
			}
			roleSHA, roleErr := hashRegularFile(hub.frozenPresetRolePath(task.ID))
			if roleErr != nil || roleSHA != task.SubagentExecution.RoleSHA256 {
				hub.mu.Unlock()
				return TaskDTO{}, errInvalid
			}
		}
	}
	requestRecord := &requestRecord{RequestHash: hashText(request.RequestID), BodyHash: bodyHash, TaskID: task.ID}
	if task.approvalExpired(now) {
		err := hub.transitionLocked(task, stateBlockedConfiguration, "approval_expired", "task.blocked", requestRecord)
		delete(hub.pendingPrompts, task.ID)
		dto := task.dto()
		hub.mu.Unlock()
		return dto, err
	}
	if _, ok := hub.pendingPrompts[task.ID]; !ok {
		err := hub.transitionLocked(task, stateBlockedConfiguration, "prompt_unavailable", "task.blocked", requestRecord)
		dto := task.dto()
		hub.mu.Unlock()
		return dto, err
	}
	if owner := hub.conflictingProjectOwnerLocked(task.Project, task.ID); owner != "" {
		hub.mu.Unlock()
		return TaskDTO{}, errBusy
	}
	if err := hub.dispatchActivityAllowed(task.AccountAlias, task.Project, task.DispatchLeaseID, task.ID, now); err != nil {
		hub.mu.Unlock()
		return TaskDTO{}, err
	}
	if err := hub.dispatchAllowedLocked(task.AccountAlias); err != nil {
		hub.mu.Unlock()
		return TaskDTO{}, err
	}
	if task.Agent == "codex" && task.AccountAlias != "system" && !hub.approvalQuotaReadyLocked(task.AccountAlias, now) {
		hub.mu.Unlock()
		return TaskDTO{}, errAccountQuotaReserve
	}
	selection, reason := hub.selectAccountForApprovalLocked(task)
	if reason != "" {
		if reason == errAccountBusy.Error() {
			hub.mu.Unlock()
			return TaskDTO{}, errAccountBusy
		}
		if reason == errDispatchDisabled.Error() {
			hub.mu.Unlock()
			return TaskDTO{}, errDispatchDisabled
		}
		if reason == errDispatchPolicyUnavailable.Error() {
			hub.mu.Unlock()
			return TaskDTO{}, errDispatchPolicyUnavailable
		}
		err := hub.transitionLocked(task, stateBlockedConfiguration, reason, "task.blocked", requestRecord)
		delete(hub.pendingPrompts, task.ID)
		dto := task.dto()
		hub.mu.Unlock()
		return dto, err
	}
	task.AccountAlias = selection.alias
	hub.leases[task.Project] = task.ID
	err = hub.transitionLocked(task, stateStarting, "approval_granted", "task.approved", requestRecord)
	if err != nil {
		delete(hub.leases, task.Project)
		hub.mu.Unlock()
		return TaskDTO{}, err
	}
	dto := task.dto()
	hub.mu.Unlock()
	go hub.runTask(task.ID)
	return dto, nil
}

func (hub *Hub) approvalQuotaReadyLocked(alias string, now time.Time) bool {
	if alias == "" {
		return false
	}
	overview, err := readManagerOverview(hub.managerSnapshotPath, hub.config.Accounts, now)
	if err != nil {
		return false
	}
	matches := 0
	qualified := false
	for _, account := range overview.Accounts {
		if account.Source != "matched_alias" || account.Alias != alias {
			continue
		}
		matches++
		if matches > 1 || !account.DispatchWindowOpen || account.FetchedAt == nil || account.SevenDayResetsAt == nil ||
			account.SevenDayUsedPercent == nil || account.FiveHourUsedPercent == nil || account.FiveHourResetsAt == nil ||
			account.QuotaReadSucceeded == nil || !*account.QuotaReadSucceeded ||
			account.AutomaticSwitchParticipation != nil && !*account.AutomaticSwitchParticipation ||
			account.LastQuotaReadFailureAt != nil && !account.LastQuotaReadFailureAt.Before(*account.FetchedAt) ||
			strings.TrimSpace(account.Plan) == "" || strings.EqualFold(strings.TrimSpace(account.Plan), "free") {
			continue
		}
		age := now.Sub(*account.FetchedAt)
		fiveUsed, sevenUsed := *account.FiveHourUsedPercent, *account.SevenDayUsedPercent
		// Closed ranges also reject non-finite values; both windows are required.
		qualified = age >= -5*time.Second && age <= time.Duration(hub.config.ApprovalQuotaMaxAgeSeconds)*time.Second &&
			fiveUsed >= 0 && fiveUsed <= 70 && sevenUsed >= 0 && sevenUsed <= 85 &&
			account.FiveHourResetsAt.After(now) && account.SevenDayResetsAt.After(now)
	}
	return matches == 1 && qualified
}

type CancelRequest struct {
	RequestID       string `json:"requestId"`
	ExpectedVersion uint64 `json:"expectedVersion"`
}

func (hub *Hub) cancel(taskID string, request CancelRequest) (TaskDTO, error) {
	if validateRequestID(request.RequestID) != nil || request.ExpectedVersion == 0 {
		return TaskDTO{}, errInvalid
	}
	hub.mu.Lock()
	if hub.closed || hub.poisoned {
		hub.mu.Unlock()
		return TaskDTO{}, errConflict
	}
	task := hub.tasks[taskID]
	if task == nil {
		hub.mu.Unlock()
		return TaskDTO{}, errNotFound
	}
	bodyHash := hashParts("cancel", taskID, strconv.FormatUint(request.ExpectedVersion, 10))
	if existing, found, err := hub.dedupeLocked(request.RequestID, bodyHash); found || err != nil {
		var dto TaskDTO
		if existing != nil {
			dto = existing.dto()
		}
		hub.mu.Unlock()
		if existing == nil {
			return TaskDTO{}, err
		}
		return dto, err
	}
	if task.Version != request.ExpectedVersion {
		hub.mu.Unlock()
		return TaskDTO{}, errConflict
	}
	requestRecord := &requestRecord{RequestHash: hashText(request.RequestID), BodyHash: bodyHash, TaskID: task.ID}
	if task.State == stateBlockedConfiguration {
		delete(hub.pendingPrompts, task.ID)
		err := hub.transitionLocked(task, stateCancelled, "cancelled_blocked_configuration", "task.cancelled", requestRecord)
		dto := task.dto()
		hub.mu.Unlock()
		return dto, err
	}
	if task.State.terminal() {
		err := hub.persistUpdateLocked(task, task.ReasonCode, "task.cancel_noop", requestRecord)
		dto := task.dto()
		hub.mu.Unlock()
		return dto, err
	}
	if task.State == stateAwaitingApproval {
		delete(hub.pendingPrompts, task.ID)
		err := hub.transitionLocked(task, stateCancelled, "cancelled_before_start", "task.cancelled", requestRecord)
		dto := task.dto()
		hub.mu.Unlock()
		return dto, err
	}
	if task.State != stateStarting && task.State != stateRunning {
		hub.mu.Unlock()
		return TaskDTO{}, errConflict
	}
	err := hub.transitionLocked(task, stateCancelRequested, "operator_cancel", "task.cancel_requested", requestRecord)
	handle := hub.handles[task.ID]
	dto := task.dto()
	hub.mu.Unlock()
	if err == nil && handle != nil {
		go terminateProcess(handle)
	}
	return dto, err
}

type ResolveRequest struct {
	RequestID        string `json:"requestId"`
	ExpectedVersion  uint64 `json:"expectedVersion"`
	ConfirmedStopped bool   `json:"confirmedStopped"`
}

func (hub *Hub) resolve(taskID string, request ResolveRequest) (TaskDTO, error) {
	if validateRequestID(request.RequestID) != nil || request.ExpectedVersion == 0 || !request.ConfirmedStopped {
		return TaskDTO{}, errInvalid
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if hub.closed || hub.poisoned {
		return TaskDTO{}, errConflict
	}
	task := hub.tasks[taskID]
	if task == nil {
		return TaskDTO{}, errNotFound
	}
	bodyHash := hashParts("resolve", taskID, strconv.FormatUint(request.ExpectedVersion, 10), "confirmed_stopped")
	if existing, found, err := hub.dedupeLocked(request.RequestID, bodyHash); found || err != nil {
		if existing == nil {
			return TaskDTO{}, err
		}
		return existing.dto(), err
	}
	if task.State != stateUncertain || task.Version != request.ExpectedVersion {
		return TaskDTO{}, errConflict
	}
	requestRecord := &requestRecord{RequestHash: hashText(request.RequestID), BodyHash: bodyHash, TaskID: task.ID}
	if err := hub.transitionLocked(task, stateFailed, "operator_confirmed_stopped", "task.resolved", requestRecord); err != nil {
		return TaskDTO{}, err
	}
	delete(hub.leases, task.Project)
	return task.dto(), nil
}

func (hub *Hub) dedupeLocked(requestID, bodyHash string) (*Task, bool, error) {
	record, found := hub.requests[hashText(requestID)]
	if !found {
		return nil, false, nil
	}
	if record.BodyHash != bodyHash {
		return nil, true, errConflict
	}
	task := hub.tasks[record.TaskID]
	if task == nil {
		return nil, true, errConflict
	}
	return task, true, nil
}

func (hub *Hub) transitionLocked(task *Task, to TaskState, reason, eventType string, request *requestRecord) error {
	if !allowedTransitions[task.State][to] {
		return errConflict
	}
	before := *task
	from := task.State
	task.State = to
	task.Version++
	task.ReasonCode = reason
	task.UpdatedAt = time.Now().UTC()
	if to.terminal() {
		task.PID = 0
	}
	dto := task.dto()
	record := *task
	event, err := hub.store.append(journalEvent{
		RecordKind: "task",
		Event:      PublicEvent{Version: 1, TaskID: task.ID, Type: eventType, From: from, To: to, ReasonCode: reason, OccurredAt: task.UpdatedAt, Task: &dto},
		Record:     &record,
		Request:    request,
	})
	if err != nil {
		*task = before
		hub.poisonLocked()
		return err
	}
	if request != nil {
		hub.requests[request.RequestHash] = *request
	}
	hub.broadcastLocked(event)
	return nil
}

func (hub *Hub) persistUpdateLocked(task *Task, reason, eventType string, request *requestRecord) error {
	before := *task
	task.Version++
	task.ReasonCode = reason
	task.UpdatedAt = time.Now().UTC()
	dto := task.dto()
	record := *task
	event, err := hub.store.append(journalEvent{
		RecordKind: "task",
		Event:      PublicEvent{Version: 1, TaskID: task.ID, Type: eventType, From: task.State, To: task.State, ReasonCode: reason, OccurredAt: task.UpdatedAt, Task: &dto},
		Record:     &record,
		Request:    request,
	})
	if err != nil {
		*task = before
		hub.poisonLocked()
		return err
	}
	if request != nil {
		hub.requests[request.RequestHash] = *request
	}
	hub.broadcastLocked(event)
	return nil
}

func (hub *Hub) runTask(taskID string) {
	hub.mu.Lock()
	if hub.closed || hub.poisoned {
		hub.mu.Unlock()
		return
	}
	task := hub.tasks[taskID]
	if task == nil {
		hub.mu.Unlock()
		return
	}
	if task.State == stateCancelRequested {
		delete(hub.pendingPrompts, task.ID)
		if hub.transitionLocked(task, stateCancelled, "cancelled_before_spawn", "task.cancelled", nil) == nil {
			delete(hub.leases, task.Project)
		}
		hub.mu.Unlock()
		return
	}
	prompt, ok := hub.pendingPrompts[task.ID]
	if !ok {
		if hub.transitionLocked(task, stateBlockedConfiguration, "prompt_unavailable", "task.blocked", nil) == nil {
			delete(hub.leases, task.Project)
		}
		hub.mu.Unlock()
		return
	}
	cmd, err := hub.commandFor(task, prompt)
	if err != nil {
		delete(hub.pendingPrompts, task.ID)
		if hub.transitionLocked(task, stateBlockedConfiguration, "agent_unavailable", "task.blocked", nil) == nil {
			delete(hub.leases, task.Project)
		}
		hub.mu.Unlock()
		return
	}
	stdout, stdoutWriter, err := os.Pipe()
	if err != nil {
		delete(hub.pendingPrompts, task.ID)
		if hub.transitionLocked(task, stateBlockedConfiguration, "stdout_unavailable", "task.blocked", nil) == nil {
			delete(hub.leases, task.Project)
		}
		hub.mu.Unlock()
		return
	}
	stderr, stderrWriter, err := os.Pipe()
	if err != nil {
		_ = stdout.Close()
		_ = stdoutWriter.Close()
		delete(hub.pendingPrompts, task.ID)
		if hub.transitionLocked(task, stateBlockedConfiguration, "stderr_unavailable", "task.blocked", nil) == nil {
			delete(hub.leases, task.Project)
		}
		hub.mu.Unlock()
		return
	}
	defer stdout.Close()
	defer stderr.Close()
	cmd.Stdout = stdoutWriter
	cmd.Stderr = stderrWriter
	configureProcessGroup(cmd)
	if err := hub.dispatchAllowedLocked(task.AccountAlias); err != nil {
		_ = stdout.Close()
		_ = stdoutWriter.Close()
		_ = stderr.Close()
		_ = stderrWriter.Close()
		delete(hub.pendingPrompts, task.ID)
		if hub.transitionLocked(task, stateBlockedConfiguration, err.Error(), "task.blocked", nil) == nil {
			delete(hub.leases, task.Project)
		}
		hub.mu.Unlock()
		return
	}
	if err := cmd.Start(); err != nil {
		_ = stdout.Close()
		_ = stdoutWriter.Close()
		_ = stderr.Close()
		_ = stderrWriter.Close()
		delete(hub.pendingPrompts, task.ID)
		if hub.transitionLocked(task, stateBlockedConfiguration, "agent_start_failed", "task.blocked", nil) == nil {
			delete(hub.leases, task.Project)
		}
		hub.mu.Unlock()
		return
	}
	_ = stdoutWriter.Close()
	_ = stderrWriter.Close()
	delete(hub.pendingPrompts, task.ID)
	task.PID = cmd.Process.Pid
	handle := &processHandle{
		pid:      cmd.Process.Pid,
		process:  cmd.Process,
		done:     make(chan struct{}),
		exitDone: make(chan struct{}),
		stopDone: make(chan struct{}),
	}
	defer close(handle.done)
	hub.handles[task.ID] = handle
	if err := hub.transitionLocked(task, stateRunning, "process_started", "task.running", nil); err != nil {
		delete(hub.handles, task.ID)
		hub.mu.Unlock()
		go terminateProcess(handle)
		_ = cmd.Wait()
		_ = markExitedAndVerify(handle)
		_ = stdout.Close()
		_ = stderr.Close()
		return
	}
	agent := task.Agent
	hub.mu.Unlock()

	var readers sync.WaitGroup
	readers.Add(2)
	go func() {
		defer readers.Done()
		hub.scanOutput(taskID, agent, "stdout", stdout)
	}()
	go func() {
		defer readers.Done()
		hub.scanOutput(taskID, agent, "stderr", stderr)
	}()
	readersDone := make(chan struct{})
	go func() {
		readers.Wait()
		close(readersDone)
	}()
	waitErr := cmd.Wait()
	groupStopped := markExitedAndVerify(handle)
	readersComplete := true
	select {
	case <-readersDone:
	case <-time.After(2 * time.Second):
		readersComplete = false
		_ = stdout.Close()
		_ = stderr.Close()
		select {
		case <-readersDone:
		case <-time.After(250 * time.Millisecond):
		}
	}

	hub.mu.Lock()
	defer hub.mu.Unlock()
	delete(hub.handles, taskID)
	if hub.storeClosed {
		return
	}
	task = hub.tasks[taskID]
	if task == nil {
		return
	}
	if !readersComplete {
		if task.State == stateRunning || task.State == stateCancelRequested {
			_ = hub.transitionLocked(task, stateUncertain, "output_stream_unverified", "task.uncertain", nil)
		}
		return
	}
	if !groupStopped {
		if task.State == stateRunning || task.State == stateCancelRequested {
			_ = hub.transitionLocked(task, stateUncertain, "process_group_unverified", "task.uncertain", nil)
		}
		return
	}
	switch task.State {
	case stateCancelRequested:
		if hub.transitionLocked(task, stateCancelled, "process_cancelled", "task.cancelled", nil) == nil {
			delete(hub.leases, task.Project)
		}
	case stateRunning:
		var transitionErr error
		if waitErr == nil {
			transitionErr = hub.transitionLocked(task, stateSucceeded, "process_exit_zero", "task.succeeded", nil)
		} else {
			transitionErr = hub.transitionLocked(task, stateFailed, "process_exit_nonzero", "task.failed", nil)
		}
		if transitionErr == nil {
			delete(hub.leases, task.Project)
		}
	default:
		if task.State.holdsLease() {
			_ = hub.transitionLocked(task, stateUncertain, "unexpected_process_state", "task.uncertain", nil)
		}
	}
}

func (hub *Hub) commandFor(task *Task, prompt string) (*exec.Cmd, error) {
	configured := hub.config.Commands[task.Agent]
	command, err := exec.LookPath(configured)
	if err != nil {
		return nil, err
	}
	project := hub.config.Projects[task.Project]
	accountHome, err := hub.accountHome(task.AccountAlias)
	if err != nil {
		return nil, err
	}
	var args []string
	var stdin io.Reader
	switch task.Agent {
	case "codex":
		args = []string{"-C", project, "-s", hub.config.Mode, "-a", "never", "exec", "--ignore-user-config", "--ignore-rules"}
		if task.AccountAlias != "system" {
			preference, err := normalizedExecutionPreference(task.ExecutionPreference)
			if err != nil {
				return nil, err
			}
			strategy, err := frozenTaskExecutionStrategy(task, preference)
			if err != nil {
				return nil, errInvalid
			}
			effective := strategy.Main
			poolArgs := []string{
				"-m", effective.Model,
				"-c", "model_reasoning_effort=\"" + effective.ReasoningEffort + "\"",
				"-c", "service_tier=\"" + effective.ServiceTier + "\"",
			}
			if strategy.SubagentsEnabled {
				if task.SubagentExecution == nil || task.InputHashes == nil {
					return nil, errInvalid
				}
				rolePath := hub.frozenPresetRolePath(task.ID)
				roleSHA, err := hashRegularFile(rolePath)
				if err != nil || roleSHA != task.SubagentExecution.RoleSHA256 {
					return nil, errInvalid
				}
				cliSHA, err := hashRegularFile(command)
				if err != nil || cliSHA != task.SubagentExecution.CLISHA256 {
					return nil, errInvalid
				}
				poolArgs = append(poolArgs,
					"-c", "agents.enabled=true",
					"-c", "features.multi_agent_v2=true",
					"-c", fmt.Sprintf("agents.max_concurrent_threads_per_session=%d", task.SubagentExecution.ConcurrentThreads),
					"-c", "agents.default_subagent_model="+strconv.Quote(strategy.SubagentModel),
					"-c", "agents.default_subagent_reasoning_effort="+strconv.Quote(strategy.SubagentReasoningEffort),
					"-c", "agents.next_preset_worker.description=\"Next managed preset implementation worker\"",
					"-c", "agents.next_preset_worker.config_file="+strconv.Quote(rolePath))
			} else {
				poolArgs = append(poolArgs, "-c", "agents.enabled=false", "-c", "features.multi_agent_v2=false")
			}
			if effective.ServiceTier == "fast" {
				poolArgs = append(poolArgs, "--enable", "fast_mode")
			} else {
				poolArgs = append(poolArgs, "--disable", "fast_mode")
			}
			args = append(poolArgs, args...)
			if strategy.SubagentsEnabled {
				prompt = presetCollaborationPolicy(preference.SubagentMode, true) + prompt
			}
			if task.InputHashes != nil && hashText(prompt) != task.InputHashes.EffectiveInputSHA256 {
				return nil, errInvalid
			}
		}
		if task.ResumeOf != "" {
			if task.SessionID == "" {
				return nil, errConflict
			}
			args = append(args, "resume", "--json", task.SessionID, "-")
		} else {
			args = append(args, "--json", "--color", "never", "-")
		}
	case "claude":
		if hub.config.Mode != "read-only" {
			return nil, fmt.Errorf("claude_workspace_write_unsupported")
		}
		args = []string{
			"-p", "--input-format", "text", "--output-format", "stream-json",
			"--include-partial-messages", "--verbose", "--permission-mode", "dontAsk",
			"--max-budget-usd", strconv.FormatFloat(hub.config.ClaudeMaxBudgetUSD, 'f', -1, 64),
			"--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-chrome",
			"--tools", "Read,Glob,Grep",
		}
		if task.ResumeOf != "" {
			if task.SessionID == "" {
				return nil, errConflict
			}
			args = append(args, "--resume", task.SessionID)
		} else {
			args = append(args, "--session-id", task.SessionID)
		}
	case "kimi":
		args = []string{"--output-format", "stream-json"}
		if task.ResumeOf != "" {
			if task.SessionID == "" {
				return nil, errConflict
			}
			args = append(args, "--session", task.SessionID)
		}
		args = append(args, "--prompt", prompt)
	default:
		return nil, errInvalid
	}
	if task.Agent != "kimi" {
		stdin = strings.NewReader(prompt)
	}
	cmd := exec.Command(command, args...)
	cmd.Dir = project
	cmd.Env = safeEnvironment(task.Agent, accountHome)
	cmd.Stdin = stdin
	cmd.WaitDelay = 2 * time.Second
	return cmd, nil
}

func safeEnvironment(agent, accountHome string) []string {
	allowed := map[string]bool{
		"HOME": true, "PATH": true, "TMPDIR": true, "LANG": true, "LC_ALL": true,
		"TERM": true, "USER": true, "SHELL": true, "CODEX_HOME": true, "CLAUDE_CONFIG_DIR": true,
	}
	result := make([]string, 0, len(allowed))
	for _, item := range os.Environ() {
		key, _, ok := strings.Cut(item, "=")
		if agent == "kimi" && key == "CODEX_HOME" {
			continue
		}
		if ok && (allowed[key] || strings.HasPrefix(key, "LC_")) {
			result = append(result, item)
		}
	}
	if agent == "codex" && accountHome != "" {
		result = upsertEnv(result, "CODEX_HOME", accountHome)
	}
	return result
}

func upsertEnv(values []string, key, value string) []string {
	prefix := key + "="
	for index, item := range values {
		if strings.HasPrefix(item, prefix) {
			values[index] = prefix + value
			return values
		}
	}
	return append(values, prefix+value)
}

func (hub *Hub) hasAccountAlias(alias string) bool {
	for _, account := range hub.config.Accounts {
		if account.Alias == alias {
			return true
		}
	}
	return false
}

type accountSelection struct {
	alias          string
	nextCursor     int
	advancesCursor bool
}

func (hub *Hub) dispatchDisabledAliasesLocked() (map[string]bool, error) {
	if hub.dispatchPolicyPath == "" {
		disabled := make(map[string]bool, len(hub.config.Accounts))
		for _, account := range hub.config.Accounts {
			disabled[account.Alias] = account.DispatchDisabled
		}
		return disabled, nil
	}
	candidate, err := loadConfig(hub.dispatchPolicyPath)
	if err != nil || len(candidate.Accounts) != len(hub.config.Accounts) {
		return nil, errDispatchPolicyUnavailable
	}
	candidateHomes := make(map[string]string, len(candidate.Accounts))
	disabled := make(map[string]bool, len(candidate.Accounts))
	for _, account := range candidate.Accounts {
		candidateHomes[account.Alias] = filepath.Clean(account.Home)
		disabled[account.Alias] = account.DispatchDisabled
	}
	for _, account := range hub.config.Accounts {
		if candidateHomes[account.Alias] != filepath.Clean(account.Home) {
			return nil, errDispatchPolicyUnavailable
		}
	}
	return disabled, nil
}

func (hub *Hub) dispatchAllowedLocked(alias string) error {
	disabled, err := hub.dispatchDisabledAliasesLocked()
	if err != nil {
		return err
	}
	if alias != "" && alias != "system" && disabled[alias] {
		return errDispatchDisabled
	}
	return nil
}

func (hub *Hub) selectAccountLocked(task *Task) (string, string) {
	selection, reason := hub.planAccountSelectionLocked(task.AccountAlias, task.ID)
	if reason != "" {
		return selection.alias, reason
	}
	if err := hub.validateAccountAliasLocked(selection.alias); err != nil {
		return selection.alias, err.Error()
	}
	hub.commitAccountSelectionLocked(selection)
	return selection.alias, ""
}

func (hub *Hub) selectAccountForCreateLocked(requestedAlias string, leaseID ...string) (accountSelection, string) {
	return hub.planAccountSelectionLocked(requestedAlias, "", leaseID...)
}

func (hub *Hub) selectAccountForApprovalLocked(task *Task) (accountSelection, string) {
	selection, reason := hub.planAccountSelectionLocked(task.AccountAlias, task.ID, task.DispatchLeaseID)
	if reason != "" {
		return selection, reason
	}
	if err := hub.validateAccountAliasLocked(selection.alias); err != nil {
		return selection, err.Error()
	}
	return selection, ""
}

func (hub *Hub) planAccountSelectionLocked(requestedAlias, excludingTaskID string, ownLease ...string) (accountSelection, string) {
	selection := accountSelection{alias: requestedAlias, nextCursor: hub.accountCursor}
	disabled, err := hub.dispatchDisabledAliasesLocked()
	if err != nil {
		return selection, errDispatchPolicyUnavailable.Error()
	}
	exceeded := hub.quotaExceededAliasesLocked()
	busy := hub.busyAccountAliasesLocked(time.Now().UTC(), excludingTaskID)
	leaseID := ""
	if len(ownLease) > 0 {
		leaseID = ownLease[0]
	}
	localBusy, err := hub.activityBusyAliases(leaseID)
	if err != nil {
		return selection, errDispatchPolicyUnavailable.Error()
	}
	for alias := range localBusy {
		busy[alias] = true
	}
	if selection.alias != "" && disabled[selection.alias] {
		return selection, errDispatchDisabled.Error()
	}
	if selection.alias != "" && busy[selection.alias] {
		return selection, errAccountBusy.Error()
	}
	if selection.alias == "" {
		unavailable := make(map[string]bool, len(exceeded)+len(busy))
		for accountAlias := range exceeded {
			unavailable[accountAlias] = true
		}
		for accountAlias := range busy {
			unavailable[accountAlias] = true
		}
		switch hub.config.AccountStrategy {
		case "", "system":
			selection.alias = "system"
		case "round_robin":
			selection.alias, selection.nextCursor = hub.nextRoundRobinAliasLocked(unavailable, disabled)
			selection.advancesCursor = selection.alias != ""
		case "least_recently_used":
			selection.alias = hub.nextLeastRecentlyUsedAliasLocked(unavailable, disabled)
		default:
			return selection, "account_strategy_invalid"
		}
	}
	if selection.alias == "" {
		for _, account := range hub.config.Accounts {
			if !disabled[account.Alias] && !exceeded[account.Alias] && busy[account.Alias] {
				return selection, errAccountBusy.Error()
			}
		}
		return selection, errAccountQuotaReserve.Error()
	}
	if exceeded[selection.alias] {
		return selection, errAccountQuotaReserve.Error()
	}
	return selection, ""
}

func (hub *Hub) commitAccountSelectionLocked(selection accountSelection) {
	if selection.advancesCursor {
		hub.accountCursor = selection.nextCursor
	}
	if selection.alias != "" && selection.alias != "system" {
		hub.accountTick++
		hub.accountUsed[selection.alias] = hub.accountTick
	}
}

func (hub *Hub) busyAccountAliasesLocked(now time.Time, excludingTaskID string) map[string]bool {
	busy := make(map[string]bool)
	for _, task := range hub.tasks {
		if task.ID == excludingTaskID || !task.holdsAccountLeaseAt(now) {
			continue
		}
		busy[task.AccountAlias] = true
	}
	return busy
}

func (hub *Hub) nextRoundRobinAliasLocked(unavailable, disabled map[string]bool) (string, int) {
	if len(hub.config.Accounts) == 0 {
		return "", hub.accountCursor
	}
	cursor := hub.accountCursor
	for range hub.config.Accounts {
		account := hub.config.Accounts[cursor%len(hub.config.Accounts)]
		cursor = (cursor + 1) % len(hub.config.Accounts)
		if !disabled[account.Alias] && !unavailable[account.Alias] {
			return account.Alias, cursor
		}
	}
	return "", hub.accountCursor
}

func (hub *Hub) nextLeastRecentlyUsedAliasLocked(unavailable, disabled map[string]bool) string {
	if len(hub.config.Accounts) == 0 {
		return ""
	}
	best := ""
	var bestTick uint64
	for _, account := range hub.config.Accounts {
		if disabled[account.Alias] || unavailable[account.Alias] {
			continue
		}
		tick := hub.accountUsed[account.Alias]
		if best == "" || tick < bestTick {
			best = account.Alias
			bestTick = tick
		}
	}
	return best
}

func (hub *Hub) quotaExceededAliasesLocked() map[string]bool {
	exceeded := make(map[string]bool)
	overview, err := readManagerOverview(hub.managerSnapshotPath, hub.config.Accounts, time.Now())
	if err != nil {
		// A broken snapshot cannot establish eligibility for any pool candidate.
		for _, account := range hub.config.Accounts {
			exceeded[account.Alias] = true
		}
		return exceeded
	}
	for _, account := range overview.Accounts {
		// Missing values may create a draft, but known failed, opted-out, invalid, or low quota may not.
		if !account.DispatchWindowOpen || account.AutomaticSwitchParticipation != nil && !*account.AutomaticSwitchParticipation ||
			account.QuotaReadSucceeded != nil && !*account.QuotaReadSucceeded ||
			account.LastQuotaReadFailureAt != nil && (account.FetchedAt == nil || !account.LastQuotaReadFailureAt.Before(*account.FetchedAt)) ||
			account.FiveHourUsedPercent != nil && !(*account.FiveHourUsedPercent >= 0 && *account.FiveHourUsedPercent <= 70) ||
			account.SevenDayUsedPercent != nil && !(*account.SevenDayUsedPercent >= 0 && *account.SevenDayUsedPercent <= 85) {
			exceeded[account.Alias] = true
		}
	}
	return exceeded
}

func (hub *Hub) validateAccountAliasLocked(alias string) error {
	if alias == "" || alias == "system" {
		return nil
	}
	home, err := hub.accountHome(alias)
	if err != nil {
		return err
	}
	info, err := os.Stat(home)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("account_home_unavailable")
	}
	authPath := filepath.Join(home, "auth.json")
	authInfo, err := os.Stat(authPath)
	if err != nil || !authInfo.Mode().IsRegular() {
		return fmt.Errorf("account_auth_unavailable")
	}
	return nil
}

func (hub *Hub) accountHome(alias string) (string, error) {
	if alias == "" || alias == "system" {
		return "", nil
	}
	for _, account := range hub.config.Accounts {
		if account.Alias == alias {
			return account.Home, nil
		}
	}
	return "", fmt.Errorf("account_unknown")
}

func (hub *Hub) scanOutput(taskID, agent, stream string, reader io.Reader) {
	buffered := bufio.NewReaderSize(reader, 64*1024)
	var line strings.Builder
	truncated := false
	for {
		fragment, prefix, err := buffered.ReadLine()
		if len(fragment) > 0 {
			remaining := 256*1024 - line.Len()
			if remaining > 0 {
				if len(fragment) > remaining {
					line.Write(fragment[:remaining])
					truncated = true
				} else {
					line.Write(fragment)
				}
			} else {
				truncated = true
			}
		}
		if !prefix && (line.Len() > 0 || truncated) {
			raw := line.String()
			if truncated {
				raw += "…[line_truncated]"
			}
			hub.handleOutputLine(taskID, agent, stream, raw)
			line.Reset()
			truncated = false
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				hub.broadcastLive(PublicEvent{
					Version: 1, TaskID: taskID, Type: "agent.output", OccurredAt: time.Now().UTC(),
					Stream: stream, Text: "[output_stream_error]",
				})
			}
			return
		}
	}
}

func (hub *Hub) handleOutputLine(taskID, agent, stream, raw string) {
	persistedChunk := extractPersistedAssistantChunk(agent, stream, raw)
	outputKind := ""
	if persistedChunk != "" {
		outputKind = "assistant"
	}
	if stream == "stdout" {
		if note := extractResultNote(agent, raw); note != "" {
			hub.setResultNote(taskID, note)
		}
	}
	if sessionID := extractSessionID(agent, raw); sessionID != "" {
		hub.bindSession(taskID, sessionID)
		return
	}
	if suppressOutput(raw) {
		return
	}
	if agent == "kimi" && stream == "stdout" {
		if text, recognized := extractKimiOutput(raw); recognized {
			if text == "" {
				return
			}
			raw = text
		}
	}
	masked := hub.maskOutput(raw)
	hub.mu.Lock()
	defer hub.mu.Unlock()
	messageOffset := 0
	if persistedChunk != "" {
		messageOffset = hub.messageStore.assistantRuneCount(taskID)
		if err := hub.appendTaskMessageLocked(taskID, "assistant", hub.maskOutput(persistedChunk), time.Now().UTC()); err != nil {
			return
		}
	}
	hub.broadcastLocked(PublicEvent{
		Version: 1, TaskID: taskID, Type: "agent.output", OccurredAt: time.Now().UTC(),
		Stream: stream, OutputKind: outputKind, MessageOffset: messageOffset, Text: masked,
	})
}

func extractResultNote(agent, line string) string {
	var event struct {
		Type    string `json:"type"`
		Role    string `json:"role"`
		Content string `json:"content"`
		Item    struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"item"`
		Message struct {
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal([]byte(line), &event) != nil {
		return ""
	}
	var text string
	switch {
	case agent == "codex" && event.Type == "item.completed" && event.Item.Type == "agent_message":
		text = event.Item.Text
	case agent == "claude" && event.Type == "assistant" && event.Message.Role == "assistant":
		var parts []string
		for _, content := range event.Message.Content {
			if content.Type == "text" && content.Text != "" {
				parts = append(parts, content.Text)
			}
		}
		text = strings.Join(parts, " ")
	case agent == "kimi" && event.Role == "assistant":
		text = event.Content
	}
	return summarizeResultNote(text)
}

func extractKimiOutput(line string) (string, bool) {
	var event struct {
		Role         string `json:"role"`
		Type         string `json:"type"`
		Content      string `json:"content"`
		ErrorMessage string `json:"error_message"`
	}
	if json.Unmarshal([]byte(line), &event) != nil {
		return "", false
	}
	switch event.Role {
	case "assistant":
		return event.Content, true
	case "tool":
		if event.Content == "" {
			return "", true
		}
		return "[tool] " + event.Content, true
	case "meta":
		if event.Type == "turn.step.retrying" && event.ErrorMessage != "" {
			return "[retry] " + event.ErrorMessage, true
		}
		return "", true
	default:
		return "", false
	}
}

func summarizeResultNote(value string) string {
	value = strings.TrimSpace(strings.NewReplacer("\r\n", " ", "\r", " ", "\n", " ").Replace(value))
	runes := []rune(value)
	if len(runes) > 200 {
		value = string(runes[:200])
	}
	return value
}

func (hub *Hub) setResultNote(taskID, note string) {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if task := hub.tasks[taskID]; task != nil {
		task.ResultNote = note
	}
}

func extractSessionID(agent, line string) string {
	var value map[string]any
	if json.Unmarshal([]byte(line), &value) != nil {
		return ""
	}
	var session string
	if agent == "codex" && value["type"] == "thread.started" {
		session, _ = value["thread_id"].(string)
	}
	if agent == "claude" && value["type"] == "system" && value["subtype"] == "init" {
		session, _ = value["session_id"].(string)
	}
	if agent == "kimi" && value["role"] == "meta" && value["type"] == "session.resume_hint" {
		session, _ = value["session_id"].(string)
	}
	if !validSessionID(session) {
		return ""
	}
	return session
}

var sessionPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{8,128}$`)

func validSessionID(value string) bool { return sessionPattern.MatchString(value) }

func (hub *Hub) bindSession(taskID, sessionID string) {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if hub.storeClosed {
		return
	}
	task := hub.tasks[taskID]
	if task == nil {
		return
	}
	if task.SessionID != "" && task.SessionID != sessionID {
		before := *task
		task.SessionID = ""
		task.SessionVerified = false
		if (task.State == stateRunning || task.State == stateCancelRequested) &&
			hub.transitionLocked(task, stateUncertain, "session_mismatch", "task.uncertain", nil) == nil {
			if handle := hub.handles[taskID]; handle != nil {
				go terminateProcess(handle)
			}
		} else {
			*task = before
		}
		return
	}
	if task.SessionVerified {
		return
	}
	before := *task
	task.SessionID = sessionID
	task.SessionVerified = true
	if err := hub.persistUpdateLocked(task, "session_bound", "task.session_bound", nil); err != nil {
		*task = before
	}
}

var (
	secretPattern        = regexp.MustCompile(`(?i)(bearer\s+|"?api[_-]?key"?\s*[:=]\s*"?|"?secret"?\s*[:=]\s*"?|"?token"?\s*[:=]\s*"?|"?password"?\s*[:=]\s*"?)([^\s\",}]+)`)
	sessionOutputPattern = regexp.MustCompile(`(?i)("?(session[_-]?id|thread[_-]?id)"?\s*[:=]\s*"?)([A-Za-z0-9_-]{8,128})`)
	authorizationPattern = regexp.MustCompile(`(?i)("?authorization"?\s*[:=]\s*"?)(basic|bearer)\s+[A-Za-z0-9._~+/-]+=*`)
	rawTokenPattern      = regexp.MustCompile(`(?i)(sk-[A-Za-z0-9_-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})`)
	quotedPathPattern    = regexp.MustCompile(`(["'])(/[^"'\r\n]+)(["'])`)
	privatePathPattern   = regexp.MustCompile(`(^|[\s(=:\[])(/(Users|Volumes|private|tmp|opt|var|etc|usr|Library|Applications|System|home)/[^"'\r\n]*)`)
)

func maskOutput(value string) string {
	return maskOutputWith(value, nil)
}

func (hub *Hub) maskOutput(value string) string {
	return maskOutputWith(value, hub.sensitiveValues)
}

func maskOutputWith(value string, sensitive []string) string {
	for _, item := range sensitive {
		value = strings.ReplaceAll(value, item, "[REDACTED]")
	}
	value = redactStructuredOutput(value)
	value = secretPattern.ReplaceAllString(value, "$1[REDACTED]")
	value = sessionOutputPattern.ReplaceAllString(value, "$1[REDACTED]")
	value = authorizationPattern.ReplaceAllString(value, "$1[REDACTED]")
	value = rawTokenPattern.ReplaceAllString(value, "[REDACTED]")
	value = quotedPathPattern.ReplaceAllString(value, "$1[LOCAL_PATH]$3")
	value = privatePathPattern.ReplaceAllString(value, "$1[LOCAL_PATH]")
	if len(value) > 16*1024 {
		value = value[:16*1024] + "…[truncated]"
	}
	return value
}

func redactStructuredOutput(value string) string {
	var decoded any
	if json.Unmarshal([]byte(value), &decoded) != nil || !redactSensitiveFields(decoded) {
		return value
	}
	encoded, err := json.Marshal(decoded)
	if err != nil {
		return value
	}
	return string(encoded)
}

func redactSensitiveFields(value any) bool {
	changed := false
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if sensitiveOutputKey(key) {
				typed[key] = "[REDACTED]"
				changed = true
				continue
			}
			changed = redactSensitiveFields(child) || changed
		}
	case []any:
		for _, child := range typed {
			changed = redactSensitiveFields(child) || changed
		}
	}
	return changed
}

func sensitiveOutputKey(key string) bool {
	normalized := strings.NewReplacer("_", "", "-", "", ".", "").Replace(strings.ToLower(key))
	switch normalized {
	case "apikey", "authorization", "token", "accesstoken", "refreshtoken", "authtoken", "idtoken",
		"password", "secret", "credentials", "sessionid", "threadid":
		return true
	default:
		return strings.HasSuffix(normalized, "password") || strings.HasSuffix(normalized, "secret") || strings.HasSuffix(normalized, "apikey")
	}
}

func suppressOutput(line string) bool {
	var value map[string]any
	if json.Unmarshal([]byte(line), &value) != nil {
		return false
	}
	if value["type"] == "user" {
		return true
	}
	if message, ok := value["message"].(map[string]any); ok && message["role"] == "user" {
		return true
	}
	return false
}

func stopHandle(handle *processHandle) bool {
	handle.stopOnce.Do(func() {
		exited := false
	signals:
		for _, step := range []struct {
			signal  os.Signal
			timeout time.Duration
		}{{syscall.SIGINT, 2 * time.Second}, {syscall.SIGTERM, 2 * time.Second}, {syscall.SIGKILL, time.Second}} {
			select {
			case <-handle.exitDone:
				exited = true
				break signals
			default:
			}
			_ = handle.process.Signal(step.signal)
			timer := time.NewTimer(step.timeout)
			select {
			case <-handle.exitDone:
				exited = true
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				break signals
			case <-timer.C:
			}
		}
		if exited {
			handle.groupStopped = waitProcessGroupGone(handle.pid, 250*time.Millisecond)
		}
		close(handle.stopDone)
	})
	<-handle.stopDone
	return handle.groupStopped
}

func markExitedAndVerify(handle *processHandle) bool {
	handle.exitOnce.Do(func() { close(handle.exitDone) })
	return waitProcessGroupGone(handle.pid, 250*time.Millisecond)
}

func terminateProcess(handle *processHandle) {
	_ = stopHandle(handle)
}

func waitProcessGroupGone(pid int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		alive, err := processGroupAlive(pid)
		if err == nil && !alive {
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	alive, err := processGroupAlive(pid)
	return err == nil && !alive
}

func (hub *Hub) subscribe(after uint64) ([]PublicEvent, <-chan PublicEvent, func()) {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	backlog := hub.store.eventsAfter(after)
	channel := make(chan PublicEvent, 256)
	if hub.closed || hub.poisoned {
		close(channel)
		return backlog, channel, func() {}
	}
	hub.subscribers[channel] = struct{}{}
	cancel := func() {
		hub.mu.Lock()
		defer hub.mu.Unlock()
		if _, ok := hub.subscribers[channel]; ok {
			delete(hub.subscribers, channel)
			close(channel)
		}
	}
	return backlog, channel, cancel
}

func (hub *Hub) broadcastLocked(event PublicEvent) {
	for subscriber := range hub.subscribers {
		select {
		case subscriber <- event:
		default:
			delete(hub.subscribers, subscriber)
			close(subscriber)
		}
	}
}

func (hub *Hub) broadcastLive(event PublicEvent) {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	hub.broadcastLocked(event)
}

func (hub *Hub) poisonLocked() {
	if hub.poisoned {
		return
	}
	hub.poisoned = true
	clear(hub.pendingPrompts)
	for subscriber := range hub.subscribers {
		delete(hub.subscribers, subscriber)
		close(subscriber)
	}
	for _, handle := range hub.handles {
		go terminateProcess(handle)
	}
}

func (hub *Hub) healthy() bool {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	return !hub.closed && !hub.poisoned && !hub.storeClosed
}

func (hub *Hub) shutdown(ctx context.Context) {
	hub.mu.Lock()
	if hub.closed {
		hub.mu.Unlock()
		return
	}
	hub.closed = true
	clear(hub.pendingPrompts)
	for subscriber := range hub.subscribers {
		delete(hub.subscribers, subscriber)
		close(subscriber)
	}
	handles := make([]*processHandle, 0, len(hub.handles))
	handled := make(map[string]bool, len(hub.handles))
	for taskID, handle := range hub.handles {
		handled[taskID] = true
		task := hub.tasks[taskID]
		if task != nil && (task.State == stateStarting || task.State == stateRunning) {
			_ = hub.transitionLocked(task, stateCancelRequested, "server_shutdown", "task.cancel_requested", nil)
		}
		handles = append(handles, handle)
	}
	for taskID, task := range hub.tasks {
		if handled[taskID] || task.State != stateStarting {
			continue
		}
		if hub.transitionLocked(task, stateCancelRequested, "server_shutdown_before_spawn", "task.cancel_requested", nil) == nil &&
			hub.transitionLocked(task, stateCancelled, "server_shutdown_before_spawn", "task.cancelled", nil) == nil {
			delete(hub.leases, task.Project)
		}
	}
	hub.mu.Unlock()
	for _, handle := range handles {
		go terminateProcess(handle)
	}
	for _, handle := range handles {
		select {
		case <-handle.done:
		case <-ctx.Done():
			hub.mu.Lock()
			for taskID, active := range hub.handles {
				if active == handle {
					task := hub.tasks[taskID]
					if task != nil && task.State == stateCancelRequested {
						_ = hub.transitionLocked(task, stateUncertain, "shutdown_timeout", "task.uncertain", nil)
					}
				}
			}
			hub.storeClosed = true
			hub.mu.Unlock()
			_ = hub.store.Close()
			_ = hub.messageStore.Close()
			return
		}
	}
	hub.mu.Lock()
	hub.storeClosed = true
	hub.mu.Unlock()
	_ = hub.store.Close()
	_ = hub.messageStore.Close()
}

func hashText(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func presetCollaborationPolicy(mode string, enabled bool) string {
	if !enabled {
		return ""
	}
	return "Next collaboration preset: " + mode + ". You are the primary planner and final reviewer; your model, reasoning effort, service tier, sandbox, and approval policy remain unchanged. Delegate implementation only when useful, use only the next_preset_worker role, do not request fork_context=true, and do not specify model or reasoning-effort overrides in spawn requests. Keep the collaboration one level deep as a working convention. Open only one next_preset_worker child thread at a time and review its result before continuing. The configured child-thread ceiling is 1; do not describe this convention as an unbypassable whole-tree security boundary.\n\n"
}

func generatedPresetRole(model, effort string) []byte {
	return []byte("model = \"" + model + "\"\nmodel_reasoning_effort = \"" + effort + "\"\n")
}

func hashRegularFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 1024*1024*1024 {
		return "", fmt.Errorf("file_invalid")
	}
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

type codexCapabilityReport struct {
	Status                 string    `json:"status"`
	CheckedAt              time.Time `json:"checkedAt"`
	CLISHA256              string    `json:"cliSHA256"`
	WorkerRoleSHA256       string    `json:"workerRoleSHA256"`
	SupportedSubagentModes []string  `json:"supportedSubagentModes"`
}

func (hub *Hub) validatePresetCapability(mode, roleSHA string) (string, error) {
	command, err := exec.LookPath(hub.config.Commands["codex"])
	if err != nil {
		return "", fmt.Errorf("codex_capability_unavailable")
	}
	cliSHA, err := hashRegularFile(command)
	if err != nil {
		return "", fmt.Errorf("codex_capability_unavailable")
	}
	data, err := os.ReadFile(filepath.Join(hub.config.DataDir, "codex-capability.json"))
	if err != nil || len(data) > 64*1024 {
		return "", fmt.Errorf("codex_capability_unavailable")
	}
	var report codexCapabilityReport
	if json.Unmarshal(data, &report) != nil || report.Status != "passed" || report.CLISHA256 != cliSHA || report.WorkerRoleSHA256 != roleSHA || report.CheckedAt.After(time.Now().UTC()) || time.Since(report.CheckedAt) > time.Hour {
		return "", fmt.Errorf("codex_capability_invalid")
	}
	for _, supported := range report.SupportedSubagentModes {
		if supported == mode {
			return cliSHA, nil
		}
	}
	return "", fmt.Errorf("subagent_mode_unsupported")
}

func (hub *Hub) freezePresetRole(taskID string, data []byte) error {
	directory := filepath.Join(hub.config.DataDir, "task-resources", taskID)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("preset_role_freeze")
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("preset_role_freeze")
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return fmt.Errorf("preset_role_freeze")
	}
	path := filepath.Join(directory, presetRoleName+".toml")
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("preset_role_freeze")
	}
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		return fmt.Errorf("preset_role_freeze")
	}
	return nil
}

func (hub *Hub) frozenPresetRolePath(taskID string) string {
	return filepath.Join(hub.config.DataDir, "task-resources", taskID, presetRoleName+".toml")
}

func taskActionHash(task *Task) string {
	preference := executionPreference{}
	if task.ExecutionPreference != nil {
		preference = *task.ExecutionPreference
	}
	result := hashParts(
		task.ID, task.Agent, task.Project, task.AccountAlias, task.PromptHash, task.ResumeOf,
		preference.Model, preference.ReasoningEffort, preference.ServiceTier,
	)
	if preference.SubagentMode != "" || task.InputHashes != nil || task.SubagentExecution != nil {
		result = hashParts(result, preference.SubagentMode)
	}
	if preference.CustomPresets != nil {
		encoded, _ := json.Marshal(preference.CustomPresets)
		result = hashParts(result, hashText(string(encoded)))
	}
	if task.EffectiveExecutionPreference != nil {
		effective := task.EffectiveExecutionPreference
		result = hashParts(result, effective.Model, effective.ReasoningEffort, effective.ServiceTier, effective.SubagentMode)
	}
	if task.InputHashes != nil {
		result = hashParts(result, task.InputHashes.OriginalBriefSHA256, task.InputHashes.CollaborationPolicySHA256, task.InputHashes.EffectiveInputSHA256)
	}
	if task.SubagentExecution != nil {
		result = hashParts(result, task.SubagentExecution.RequestedMode, task.SubagentExecution.RoleSHA256, task.SubagentExecution.CLISHA256)
	}
	if task.DispatchLeaseID != "" {
		return hashParts(result, task.DispatchLeaseID)
	}
	return result
}

func hashParts(parts ...string) string { return hashText(strings.Join(parts, "\x00")) }

var requestIDPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{8,128}$`)

func validateRequestID(value string) error {
	if !requestIDPattern.MatchString(value) {
		return errInvalid
	}
	return nil
}

func newID() (string, error) {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", bytes[0:4], bytes[4:6], bytes[6:8], bytes[8:10], bytes[10:16]), nil
}
