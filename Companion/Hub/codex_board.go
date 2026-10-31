package main

import (
	"bufio"
	"bytes"
	"context"
	crand "crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

type CodexObserverMode string

const (
	observerUnavailable CodexObserverMode = "unavailable"
	observerHistoryOnly CodexObserverMode = "history_only"
	observerSharedLive  CodexObserverMode = "shared_live"
)

type CodexRuntimeState string

const (
	runtimeNeedsInput CodexRuntimeState = "needs_input"
	runtimeWorking    CodexRuntimeState = "working"
	runtimeReady      CodexRuntimeState = "ready"
	runtimeError      CodexRuntimeState = "error"
	runtimeNotLoaded  CodexRuntimeState = "not_loaded"
)

type LatestTurnState string

const (
	turnInProgress  LatestTurnState = "inProgress"
	turnCompleted   LatestTurnState = "completed"
	turnInterrupted LatestTurnState = "interrupted"
	turnFailed      LatestTurnState = "failed"
	turnUnknown     LatestTurnState = "unknown"
)

type ReviewState string

const (
	reviewUnreviewed ReviewState = "unreviewed"
	reviewAccepted   ReviewState = "accepted"
	reviewBlocked    ReviewState = "blocked"
)

type ObservedThread struct {
	InternalID       string
	RootInternalID   string
	ParentInternalID string
	Cwd              string
	PublicRef        string
	Title            string
	SourceKind       string
	ProjectAlias     string
	ParentPublicRef  string
	RootPublicRef    string
	AgentNickname    string
	AgentRole        string
	RuntimeState     CodexRuntimeState
	AggregateState   CodexRuntimeState
	LatestTurnState  LatestTurnState
	ActiveTurnID     string
	RuntimeUpdatedAt time.Time
	TurnUpdatedAt    time.Time
	ReviewState      ReviewState
	SandboxMode      string
	Model            string
	UpdatedAt        time.Time
	IsSubagent       bool
}

type ObservedThreadDTO struct {
	PublicRef       string            `json:"publicRef"`
	Title           string            `json:"title"`
	SourceKind      string            `json:"sourceKind"`
	ProjectAlias    string            `json:"projectAlias"`
	ParentPublicRef string            `json:"parentPublicRef,omitempty"`
	RootPublicRef   string            `json:"rootPublicRef"`
	AgentNickname   string            `json:"agentNickname,omitempty"`
	AgentRole       string            `json:"agentRole,omitempty"`
	RuntimeState    CodexRuntimeState `json:"runtimeState"`
	AggregateState  CodexRuntimeState `json:"aggregateState"`
	LatestTurnState LatestTurnState   `json:"latestTurnState"`
	ReviewState     ReviewState       `json:"reviewState"`
	SandboxMode     string            `json:"sandboxMode"`
	Model           string            `json:"model"`
	UpdatedAt       time.Time         `json:"updatedAt"`
	IsSubagent      bool              `json:"isSubagent"`
	CanMessage      bool              `json:"canMessage"`
	CanInterrupt    bool              `json:"canInterrupt"`
}

type CodexThreadContentDTO struct {
	Turns     []CodexTurnContentDTO `json:"turns"`
	HasMore   bool                  `json:"hasMore"`
	Truncated bool                  `json:"truncated"`
}

type CodexTurnContentDTO struct {
	Status      LatestTurnState       `json:"status"`
	StartedAt   *time.Time            `json:"startedAt,omitempty"`
	CompletedAt *time.Time            `json:"completedAt,omitempty"`
	Items       []CodexContentItemDTO `json:"items"`
}

type CodexContentItemDTO struct {
	Kind   string `json:"kind"`
	Text   string `json:"text"`
	Status string `json:"status,omitempty"`
}

func (thread *ObservedThread) dto() ObservedThreadDTO {
	return ObservedThreadDTO{
		PublicRef: thread.PublicRef, Title: thread.Title, SourceKind: thread.SourceKind, ProjectAlias: thread.ProjectAlias,
		ParentPublicRef: thread.ParentPublicRef, RootPublicRef: thread.RootPublicRef,
		AgentNickname: thread.AgentNickname, AgentRole: thread.AgentRole,
		RuntimeState: thread.RuntimeState, AggregateState: thread.AggregateState,
		LatestTurnState: thread.LatestTurnState, ReviewState: thread.ReviewState,
		SandboxMode: thread.SandboxMode, Model: thread.Model,
		UpdatedAt: thread.UpdatedAt, IsSubagent: thread.IsSubagent,
	}
}

type threadRefRecord struct {
	PublicRef   string      `json:"publicRef"`
	ReviewState ReviewState `json:"reviewState"`
	SandboxMode string      `json:"sandboxMode,omitempty"`
	Model       string      `json:"model,omitempty"`
}

type threadRefFile struct {
	Version int                        `json:"version"`
	Threads map[string]threadRefRecord `json:"threads"`
}

type CodexObserverStatus struct {
	Mode      CodexObserverMode `json:"mode"`
	Code      string            `json:"code"`
	Notice    string            `json:"notice,omitempty"`
	UpdatedAt time.Time         `json:"updatedAt,omitempty"`
}

// 固定提示码，服务端不下发原始错误文本，避免把内部细节泄露到界面。
const (
	noticeThreadsTruncated        = "threads_truncated"
	noticeSubAgentUnsupported     = "sub_agent_tree_unsupported"
	noticeSubAgentQueryDegraded   = "sub_agent_query_degraded"
	noticeLoadedThreadReadSkipped = "loaded_thread_read_degraded"
)

type CodexOverview struct {
	Observer       CodexObserverStatus     `json:"observer"`
	Threads        []ObservedThreadDTO     `json:"threads"`
	Findings       []FindingDTO            `json:"findings"`
	SandboxOptions []CodexSandboxOptionDTO `json:"sandboxOptions"`
	Models         []CodexModelDTO         `json:"models"`
}

type pendingRuntimeUpdate struct {
	State CodexRuntimeState
	At    time.Time
}

type pendingTurnUpdate struct {
	State  LatestTurnState
	TurnID string
	At     time.Time
}

type CodexBoard struct {
	mu             sync.RWMutex
	clientMu       sync.RWMutex
	controlMu      sync.Mutex // ponytail: one control lock; use per-thread locks only if remote write throughput matters.
	mutationMu     sync.RWMutex
	config         Config
	hub            *Hub
	refs           map[string]threadRefRecord
	reverse        map[string]string
	threads        map[string]*ObservedThread
	pendingRuntime map[string]pendingRuntimeUpdate
	pendingTurns   map[string]pendingTurnUpdate
	refreshNow     chan struct{}
	mode           CodexObserverMode
	code           string
	notice         string
	updatedAt      time.Time
	lastOpen       time.Time
	blocked        bool
	opener         func(string) error
	client         *appServerClient
	models         []CodexModelDTO
}

var (
	canonicalThreadIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	contentThreadIDPattern   = regexp.MustCompile(`(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b`)
	codexModelPattern        = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/-]{0,99}$`)
	emailPattern             = regexp.MustCompile(`(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}`)
	errObserverUnavailable   = errors.New("observer_unavailable")
	errControlUnavailable    = errors.New("control_unavailable")
	errControlUncertain      = errors.New("control_uncertain")
)

func newCodexBoard(config Config, hub *Hub) (*CodexBoard, error) {
	refs, exists, err := loadThreadRefs(config.DataDir)
	if err != nil {
		return nil, err
	}
	if !exists && hub.findingCount() > 0 {
		return nil, fmt.Errorf("thread_refs_missing")
	}
	refsChanged := false
	for internalID, record := range refs {
		effective, normalizeErr := narrowCodexSandbox(config.Mode, record.SandboxMode)
		if normalizeErr != nil || effective != record.SandboxMode && record.SandboxMode != "" {
			record.SandboxMode = effective
			refs[internalID] = record
			refsChanged = true
		}
	}
	if refsChanged {
		if err := saveThreadRefs(config.DataDir, refs); err != nil {
			return nil, err
		}
	}
	board := &CodexBoard{
		config: config, hub: hub, refs: refs, reverse: make(map[string]string), threads: make(map[string]*ObservedThread),
		pendingRuntime: make(map[string]pendingRuntimeUpdate), pendingTurns: make(map[string]pendingTurnUpdate),
		refreshNow: make(chan struct{}, 1),
		mode:       observerUnavailable, code: "observer_starting", opener: openCodexDesktopThread,
	}
	for internalID, record := range refs {
		board.reverse[record.PublicRef] = internalID
	}
	for _, finding := range hub.findingSnapshot() {
		if board.reverse[finding.ThreadPublicRef] == "" {
			return nil, fmt.Errorf("thread_refs_missing")
		}
	}
	return board, nil
}

func loadThreadRefs(dataDir string) (map[string]threadRefRecord, bool, error) {
	path := filepath.Join(dataDir, "thread-refs.json")
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return make(map[string]threadRefRecord), false, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || privateDirectoryPermissions(dataDir) != nil || info.Size() > 2*1024*1024 {
		return nil, false, fmt.Errorf("thread_refs_permissions")
	}
	file, err := openPrivateFile(path, os.O_RDONLY, 0)
	if err != nil {
		return nil, false, fmt.Errorf("thread_refs_read")
	}
	defer file.Close()
	if privateFilePermissions(file) != nil {
		return nil, false, fmt.Errorf("thread_refs_permissions")
	}
	decoder := json.NewDecoder(io.LimitReader(file, 2*1024*1024+1))
	decoder.DisallowUnknownFields()
	var stored threadRefFile
	if decoder.Decode(&stored) != nil || requireEOF(decoder) != nil || stored.Version != 1 || stored.Threads == nil {
		return nil, false, fmt.Errorf("thread_refs_corrupt")
	}
	seen := make(map[string]bool, len(stored.Threads))
	for internalID, record := range stored.Threads {
		if !canonicalThreadIDPattern.MatchString(internalID) || !canonicalThreadIDPattern.MatchString(record.PublicRef) || !validReviewState(record.ReviewState) || !validStoredCodexSandbox(record.SandboxMode) || (record.Model != "" && !codexModelPattern.MatchString(record.Model)) || seen[record.PublicRef] {
			return nil, false, fmt.Errorf("thread_refs_corrupt")
		}
		seen[record.PublicRef] = true
	}
	return stored.Threads, true, nil
}

func saveThreadRefs(dataDir string, refs map[string]threadRefRecord) error {
	file, err := createPrivateTemp(dataDir)
	if err != nil {
		return fmt.Errorf("thread_refs_write")
	}
	temporary := file.Name()
	cleanup := func() {
		file.Close()
		_ = os.Remove(temporary)
	}
	if err := file.Chmod(0o600); err != nil {
		cleanup()
		return fmt.Errorf("thread_refs_permissions")
	}
	encoder := json.NewEncoder(file)
	if err := encoder.Encode(threadRefFile{Version: 1, Threads: refs}); err != nil {
		cleanup()
		return fmt.Errorf("thread_refs_write")
	}
	if err := file.Sync(); err != nil {
		cleanup()
		return fmt.Errorf("thread_refs_write")
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("thread_refs_write")
	}
	if err := replacePrivateFile(temporary, filepath.Join(dataDir, "thread-refs.json")); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("thread_refs_write")
	}
	if syncPrivateDirectory(dataDir) != nil {
		return fmt.Errorf("thread_refs_sync")
	}
	return nil
}

func cloneThreadRefs(source map[string]threadRefRecord) map[string]threadRefRecord {
	result := make(map[string]threadRefRecord, len(source))
	for key, value := range source {
		result[key] = value
	}
	return result
}

func validReviewState(state ReviewState) bool {
	return state == reviewUnreviewed || state == reviewAccepted || state == reviewBlocked
}

func (board *CodexBoard) overview() CodexOverview {
	board.clientMu.RLock()
	defer board.clientMu.RUnlock()
	sharedClient := board.client != nil && board.client.mode == observerSharedLive && board.client.live()
	board.mu.RLock()
	threads := make([]ObservedThreadDTO, 0, len(board.threads))
	for _, thread := range board.threads {
		dto := thread.dto()
		if sharedClient && board.mode == observerSharedLive {
			if _, allowed := board.desktopControlCwd(thread); allowed {
				action := codexControlAction(thread)
				dto.CanMessage = action != ""
				dto.CanInterrupt = action == "steer"
			}
		}
		threads = append(threads, dto)
	}
	status := CodexObserverStatus{Mode: board.mode, Code: board.code, Notice: board.notice, UpdatedAt: board.updatedAt}
	models := append([]CodexModelDTO(nil), board.models...)
	board.mu.RUnlock()
	sort.Slice(threads, func(i, j int) bool {
		if threads[i].IsSubagent != threads[j].IsSubagent {
			return !threads[i].IsSubagent
		}
		return threads[i].UpdatedAt.After(threads[j].UpdatedAt)
	})
	return CodexOverview{
		Observer: status, Threads: threads, Findings: board.hub.findingSnapshot(),
		SandboxOptions: codexSandboxOptions(board.config.Mode), Models: models,
	}
}

func (board *CodexBoard) desktopControlCwd(thread *ObservedThread) (string, bool) {
	if thread == nil {
		return "", false
	}
	root, ok := board.config.Projects[thread.ProjectAlias]
	if thread.SourceKind != "desktop" || thread.IsSubagent || !ok || !filepath.IsAbs(thread.Cwd) {
		return "", false
	}
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", false
	}
	resolved, err := filepath.EvalSymlinks(thread.Cwd)
	if err != nil {
		return "", false
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.IsDir() || !pathContains(root, resolved) {
		return "", false
	}
	return filepath.Clean(resolved), true
}

func codexControlAction(thread *ObservedThread) string {
	if thread == nil {
		return ""
	}
	if (thread.RuntimeState == runtimeWorking || thread.RuntimeState == runtimeNeedsInput) && thread.LatestTurnState == turnInProgress && canonicalThreadIDPattern.MatchString(thread.ActiveTurnID) {
		return "steer"
	}
	if thread.RuntimeState == runtimeReady && thread.LatestTurnState != turnInProgress && thread.ActiveTurnID == "" {
		return "start"
	}
	return ""
}

func (board *CodexBoard) hasPublicRef(publicRef string) bool {
	board.mu.RLock()
	internalID := board.reverse[publicRef]
	valid := !board.blocked && internalID != "" && board.threads[internalID] != nil
	board.mu.RUnlock()
	return valid && board.hub.healthy()
}

func (board *CodexBoard) threadContent(ctx context.Context, publicRef string) (CodexThreadContentDTO, error) {
	board.mu.RLock()
	internalID := board.reverse[publicRef]
	valid := !board.blocked && internalID != "" && board.threads[internalID] != nil
	board.mu.RUnlock()
	if !valid {
		return CodexThreadContentDTO{}, errNotFound
	}

	board.clientMu.RLock()
	client := board.client
	board.clientMu.RUnlock()
	if client == nil || !client.live() {
		return CodexThreadContentDTO{}, errObserverUnavailable
	}
	// A large or malformed history reply must not disconnect the live observer.
	if client.ws != nil {
		isolated, err := startSocketAppServerClient(ctx, board, client.socketPath, client.codexHome)
		if err != nil {
			return CodexThreadContentDTO{}, errObserverUnavailable
		}
		defer isolated.close()
		client = isolated
	}
	content, err := client.threadContent(ctx, internalID, board.hub)
	if err != nil {
		return CodexThreadContentDTO{}, errObserverUnavailable
	}
	return content, nil
}

func (board *CodexBoard) publishClient(client *appServerClient) {
	board.clientMu.Lock()
	board.client = client
	board.clientMu.Unlock()
}

func (board *CodexBoard) retireClient(client *appServerClient) {
	board.clientMu.Lock()
	if board.client == client {
		board.client = nil
	}
	client.close()
	board.clientMu.Unlock()
}

type codexControlTarget struct {
	ThreadID    string
	Cwd         string
	ActiveTurn  string
	Action      string
	SandboxMode string
	Model       string
}

const maxCodexMessageBytes = 32 * 1024

func (board *CodexBoard) sendMessage(ctx context.Context, publicRef, requestID, text string, attachmentIDs []string) (string, error) {
	text = strings.TrimSpace(text)
	if validateRequestID(requestID) != nil || (text == "" && len(attachmentIDs) == 0) || len([]byte(text)) > maxCodexMessageBytes {
		return "", errInvalid
	}
	attachments, err := board.resolveAttachments(publicRef, attachmentIDs)
	if err != nil {
		return "", err
	}
	board.controlMu.Lock()
	defer board.controlMu.Unlock()

	status := ""
	err = board.withDesktopControl(ctx, publicRef, func(client *appServerClient, target codexControlTarget) error {
		requestContext, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		input := codexMessageInput(text, attachments)
		switch target.Action {
		case "steer":
			if err := client.call(requestContext, "turn/steer", map[string]any{
				"threadId": target.ThreadID, "expectedTurnId": target.ActiveTurn, "input": input, "clientUserMessageId": requestID,
			}, nil); err != nil {
				return codexControlCallError(err, true)
			}
			status = "steered"
			return nil
		case "start":
			if err := client.ensureThreadResumed(requestContext, target); err != nil {
				return codexControlCallError(err, false)
			}
			startedAt := time.Now().UTC()
			var started struct {
				Turn struct {
					ID string `json:"id"`
				} `json:"turn"`
			}
			params := map[string]any{
				"threadId": target.ThreadID, "cwd": target.Cwd, "input": input, "clientUserMessageId": requestID,
				"sandboxPolicy": codexSandboxPolicy(target.SandboxMode, target.Cwd),
			}
			if target.Model != "" {
				params["model"] = target.Model
			}
			if err := client.call(requestContext, "turn/start", params, &started); err != nil {
				return codexControlCallError(err, true)
			}
			if !canonicalThreadIDPattern.MatchString(started.Turn.ID) {
				return errControlUncertain
			}
			board.recordStartedTurn(target.ThreadID, started.Turn.ID, startedAt)
			status = "started"
			return nil
		default:
			return errConflict
		}
	})
	if errors.Is(err, errControlUncertain) {
		board.requestRefresh()
	}
	return status, err
}

func (board *CodexBoard) interrupt(ctx context.Context, publicRef string) error {
	board.controlMu.Lock()
	defer board.controlMu.Unlock()
	err := board.withDesktopControl(ctx, publicRef, func(client *appServerClient, target codexControlTarget) error {
		if target.Action != "steer" {
			return errConflict
		}
		requestContext, cancel := context.WithTimeout(ctx, 8*time.Second)
		defer cancel()
		if err := client.call(requestContext, "turn/interrupt", map[string]any{
			"threadId": target.ThreadID, "turnId": target.ActiveTurn,
		}, nil); err != nil {
			return codexControlCallError(err, true)
		}
		return nil
	})
	if errors.Is(err, errControlUncertain) {
		board.requestRefresh()
	}
	return err
}

func (board *CodexBoard) withDesktopControl(ctx context.Context, publicRef string, use func(*appServerClient, codexControlTarget) error) error {
	if !board.hub.healthy() {
		return errConflict
	}
	board.clientMu.RLock()
	defer board.clientMu.RUnlock()
	client := board.client
	if client == nil || client.mode != observerSharedLive || !client.live() {
		return errControlUnavailable
	}

	board.mu.RLock()
	if board.blocked || board.mode != observerSharedLive {
		board.mu.RUnlock()
		return errControlUnavailable
	}
	internalID := board.reverse[publicRef]
	thread := board.threads[internalID]
	if internalID == "" || thread == nil {
		board.mu.RUnlock()
		return errNotFound
	}
	resolvedCwd, allowed := board.desktopControlCwd(thread)
	if !allowed {
		board.mu.RUnlock()
		return errConflict
	}
	target := codexControlTarget{
		ThreadID: internalID, Cwd: resolvedCwd, ActiveTurn: thread.ActiveTurnID, Action: codexControlAction(thread),
		SandboxMode: thread.SandboxMode, Model: thread.Model,
	}
	observedState := thread.RuntimeState
	board.mu.RUnlock()
	if target.Action == "" {
		return errConflict
	}
	// History from another app-server cannot establish that its Desktop is idle.
	fresh, err := client.readThread(ctx, target.ThreadID)
	if err != nil || fresh.ID != target.ThreadID {
		return errControlUnavailable
	}
	freshCwd, err := filepath.EvalSymlinks(fresh.Cwd)
	if err != nil || filepath.Clean(freshCwd) != target.Cwd || runtimeStateFromApp(fresh.Status) != observedState {
		board.requestRefresh()
		return errConflict
	}
	return use(client, target)
}

func (board *CodexBoard) recordStartedTurn(threadID, turnID string, startedAt time.Time) {
	now := time.Now().UTC()
	board.mu.Lock()
	thread := board.threads[threadID]
	changed := thread != nil && board.mode == observerSharedLive && !thread.TurnUpdatedAt.After(startedAt)
	if changed {
		thread.ActiveTurnID = turnID
		thread.LatestTurnState = turnInProgress
		thread.TurnUpdatedAt = now
		if !thread.RuntimeUpdatedAt.After(startedAt) {
			thread.RuntimeState = runtimeWorking
			thread.RuntimeUpdatedAt = now
		}
		thread.UpdatedAt = now
		recomputeAggregates(board.threads)
		board.updatedAt = now
	}
	board.mu.Unlock()
	if changed {
		board.broadcastUpdate()
	}
}

func codexControlCallError(err error, mayHaveMutated bool) error {
	if err != nil && strings.HasPrefix(err.Error(), "app_server_response") {
		return errConflict
	}
	if mayHaveMutated {
		return errControlUncertain
	}
	return errControlUnavailable
}

func (board *CodexBoard) requestRefresh() {
	select {
	case board.refreshNow <- struct{}{}:
	default:
	}
}

func (board *CodexBoard) canMutate() bool {
	board.mu.RLock()
	allowed := !board.blocked
	board.mu.RUnlock()
	return allowed && board.hub.healthy()
}

func (board *CodexBoard) isBlocked() bool {
	return !board.canMutate()
}

func (board *CodexBoard) beginFindingMutation() (func(), bool) {
	board.mutationMu.RLock()
	if !board.canMutate() {
		board.mutationMu.RUnlock()
		return nil, false
	}
	return board.mutationMu.RUnlock, true
}

func (board *CodexBoard) setReview(publicRef string, state ReviewState) error {
	if !validReviewState(state) {
		return errInvalid
	}
	board.mutationMu.Lock()
	defer board.mutationMu.Unlock()
	if !board.canMutate() {
		return errConflict
	}
	board.mu.Lock()
	if board.blocked {
		board.mu.Unlock()
		return errConflict
	}
	internalID := board.reverse[publicRef]
	thread := board.threads[internalID]
	if internalID == "" || thread == nil {
		board.mu.Unlock()
		return errNotFound
	}
	next := cloneThreadRefs(board.refs)
	record := next[internalID]
	record.ReviewState = state
	next[internalID] = record
	if err := saveThreadRefs(board.config.DataDir, next); err != nil {
		board.blockLocked("thread_refs_write_uncertain")
		board.mu.Unlock()
		board.broadcastUpdate()
		return err
	}
	board.refs = next
	thread.ReviewState = state
	board.updatedAt = time.Now().UTC()
	board.mu.Unlock()
	board.broadcastUpdate()
	return nil
}

func (board *CodexBoard) open(publicRef string) error {
	board.mutationMu.RLock()
	defer board.mutationMu.RUnlock()
	if !board.canMutate() {
		return errConflict
	}
	board.mu.Lock()
	if board.blocked {
		board.mu.Unlock()
		return errConflict
	}
	internalID := board.reverse[publicRef]
	thread := board.threads[internalID]
	if thread == nil || time.Since(board.lastOpen) < 2*time.Second {
		board.mu.Unlock()
		if thread == nil {
			return errNotFound
		}
		return errConflict
	}
	if thread.IsSubagent {
		internalID = thread.RootInternalID
	}
	if !canonicalThreadIDPattern.MatchString(internalID) {
		board.mu.Unlock()
		return errInvalid
	}
	board.lastOpen = time.Now()
	opener := board.opener
	board.mu.Unlock()
	if err := opener(internalID); err != nil {
		return errConflict
	}
	log.Printf("codex thread open requested ref=%s", publicRef)
	return nil
}

func (board *CodexBoard) broadcastUpdate() {
	board.hub.broadcastLive(PublicEvent{Version: 1, Type: "codex.updated", OccurredAt: time.Now().UTC()})
}

type FindingWorkState string

const (
	findingActive     FindingWorkState = "active"
	findingTriaged    FindingWorkState = "triaged"
	findingInProgress FindingWorkState = "in_progress"
	findingResolved   FindingWorkState = "resolved"
	findingIgnored    FindingWorkState = "ignored"
)

type FindingResolution string

const (
	resolutionFixed         FindingResolution = "fixed"
	resolutionWontFix       FindingResolution = "wontfix"
	resolutionDuplicate     FindingResolution = "duplicate"
	resolutionFalsePositive FindingResolution = "false_positive"
	resolutionStale         FindingResolution = "stale"
)

type FixVerification string

const (
	verificationUnverified FixVerification = "unverified"
	verificationVerified   FixVerification = "verified"
	verificationFailed     FixVerification = "failed"
)

type Finding struct {
	ID              string             `json:"id"`
	Version         uint64             `json:"version"`
	ThreadPublicRef string             `json:"threadPublicRef"`
	Title           string             `json:"title"`
	WorkState       FindingWorkState   `json:"workState"`
	Resolution      *FindingResolution `json:"resolution"`
	FixVerification FixVerification    `json:"fixVerification"`
	CreatedAt       time.Time          `json:"createdAt"`
	UpdatedAt       time.Time          `json:"updatedAt"`
}

type FindingDTO struct {
	ID              string             `json:"id"`
	Version         uint64             `json:"version"`
	ThreadPublicRef string             `json:"threadPublicRef"`
	Title           string             `json:"title"`
	WorkState       FindingWorkState   `json:"workState"`
	Resolution      *FindingResolution `json:"resolution"`
	FixVerification FixVerification    `json:"fixVerification"`
	CreatedAt       time.Time          `json:"createdAt"`
	UpdatedAt       time.Time          `json:"updatedAt"`
}

func (finding *Finding) dto() FindingDTO {
	var resolution *FindingResolution
	if finding.Resolution != nil {
		copy := *finding.Resolution
		resolution = &copy
	}
	return FindingDTO{
		ID: finding.ID, Version: finding.Version, ThreadPublicRef: finding.ThreadPublicRef,
		Title: finding.Title, WorkState: finding.WorkState, Resolution: resolution,
		FixVerification: finding.FixVerification, CreatedAt: finding.CreatedAt, UpdatedAt: finding.UpdatedAt,
	}
}

type FindingEvent struct {
	FindingID    string             `json:"findingId"`
	EventType    string             `json:"eventType"`
	FromState    FindingWorkState   `json:"fromState,omitempty"`
	ToState      FindingWorkState   `json:"toState"`
	Resolution   *FindingResolution `json:"resolution,omitempty"`
	Actor        string             `json:"actor"`
	Reason       string             `json:"reason,omitempty"`
	EvidenceKind string             `json:"evidenceKind,omitempty"`
	EvidenceRef  string             `json:"evidenceRef,omitempty"`
	Timestamp    time.Time          `json:"timestamp"`
}

type FindingDetails struct {
	Finding FindingDTO     `json:"finding"`
	Events  []FindingEvent `json:"events"`
}

type CreateFindingRequest struct {
	RequestID       string `json:"requestId"`
	ThreadPublicRef string `json:"threadPublicRef"`
	Title           string `json:"title"`
}

type ChangeFindingRequest struct {
	RequestID       string            `json:"requestId"`
	ExpectedVersion uint64            `json:"expectedVersion"`
	EventType       string            `json:"eventType"`
	Resolution      FindingResolution `json:"resolution,omitempty"`
	Reason          string            `json:"reason,omitempty"`
	EvidenceKind    string            `json:"evidenceKind,omitempty"`
	EvidenceRef     string            `json:"evidenceRef,omitempty"`
}

var findingCodePattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)

func validFindingSnapshot(finding *Finding) bool {
	if finding == nil || !canonicalThreadIDPattern.MatchString(finding.ID) || !canonicalThreadIDPattern.MatchString(finding.ThreadPublicRef) || finding.Version == 0 || finding.Title == "" || finding.CreatedAt.IsZero() || finding.UpdatedAt.Before(finding.CreatedAt) {
		return false
	}
	switch finding.WorkState {
	case findingActive, findingTriaged:
		return finding.Resolution == nil && (finding.FixVerification == verificationUnverified || finding.FixVerification == verificationFailed)
	case findingInProgress:
		return finding.Resolution == nil && finding.FixVerification == verificationUnverified
	case findingResolved:
		return finding.Resolution != nil && *finding.Resolution == resolutionFixed && (finding.FixVerification == verificationUnverified || finding.FixVerification == verificationVerified)
	case findingIgnored:
		return finding.Resolution != nil && validIgnoredResolution(*finding.Resolution) && finding.FixVerification == verificationUnverified
	default:
		return false
	}
}

func validIgnoredResolution(resolution FindingResolution) bool {
	switch resolution {
	case resolutionWontFix, resolutionDuplicate, resolutionFalsePositive, resolutionStale:
		return true
	default:
		return false
	}
}

func validateFindingReplay(hub *Hub, previous, next *Finding, event *FindingEvent) error {
	if !validFindingSnapshot(next) || !hub.validFindingTitle(next.Title) || event == nil || event.FindingID != next.ID || event.ToState != next.WorkState || event.Actor != "operator" || !event.Timestamp.Equal(next.UpdatedAt) || !findingCodeOrEmpty(event.Reason) || hub.maskOutput(event.Reason) != event.Reason || hub.maskOutput(event.EvidenceRef) != event.EvidenceRef || !sameResolution(event.Resolution, next.Resolution) {
		return errInvalid
	}
	if previous == nil {
		if event.EventType != "created" || event.FromState != "" || event.EvidenceKind != "" || event.EvidenceRef != "" || next.Version != 1 || next.WorkState != findingActive || next.Resolution != nil || next.FixVerification != verificationUnverified || !next.CreatedAt.Equal(next.UpdatedAt) {
			return errInvalid
		}
		return nil
	}
	if previous.ID != next.ID || previous.ThreadPublicRef != next.ThreadPublicRef || previous.Title != next.Title || previous.Version+1 != next.Version || !previous.CreatedAt.Equal(next.CreatedAt) || !next.UpdatedAt.After(previous.UpdatedAt) || event.FromState != previous.WorkState {
		return errInvalid
	}
	if event.EventType != "verified" && (event.EvidenceKind != "" || event.EvidenceRef != "") {
		return errInvalid
	}
	switch event.EventType {
	case "triaged":
		if previous.WorkState != findingActive || next.WorkState != findingTriaged || next.Resolution != nil || next.FixVerification != previous.FixVerification {
			return errInvalid
		}
	case "started":
		if (previous.WorkState != findingActive && previous.WorkState != findingTriaged) || next.WorkState != findingInProgress || next.Resolution != nil || next.FixVerification != verificationUnverified {
			return errInvalid
		}
	case "resolved":
		if previous.WorkState != findingInProgress || next.WorkState != findingResolved || next.Resolution == nil || *next.Resolution != resolutionFixed || next.FixVerification != verificationUnverified {
			return errInvalid
		}
	case "verified":
		if previous.WorkState != findingResolved || previous.Resolution == nil || *previous.Resolution != resolutionFixed || previous.FixVerification != verificationUnverified || next.WorkState != findingResolved || next.Resolution == nil || *next.Resolution != resolutionFixed || next.FixVerification != verificationVerified || !validEvidence(event.EvidenceKind, event.EvidenceRef) {
			return errInvalid
		}
	case "ignored":
		if (previous.WorkState != findingActive && previous.WorkState != findingTriaged && previous.WorkState != findingInProgress) || next.WorkState != findingIgnored || next.Resolution == nil || !validIgnoredResolution(*next.Resolution) || next.FixVerification != verificationUnverified {
			return errInvalid
		}
	case "reopened":
		expectedVerification := verificationUnverified
		if previous.Resolution != nil && *previous.Resolution == resolutionFixed {
			expectedVerification = verificationFailed
		}
		if (previous.WorkState != findingResolved && previous.WorkState != findingIgnored) || next.WorkState != findingActive || next.Resolution != nil || next.FixVerification != expectedVerification || event.Reason == "" {
			return errInvalid
		}
	default:
		return errInvalid
	}
	return nil
}

func sameResolution(a, b *FindingResolution) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

func validEvidence(kind, reference string) bool {
	if !findingCodePattern.MatchString(reference) {
		return false
	}
	return kind == "test" || kind == "reproduction" || kind == "user_acceptance"
}

func (hub *Hub) findingCount() int {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	return len(hub.findings)
}

func (hub *Hub) findingSnapshot() []FindingDTO {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	result := make([]FindingDTO, 0, len(hub.findings))
	for _, finding := range hub.findings {
		result = append(result, finding.dto())
	}
	sort.Slice(result, func(i, j int) bool { return result[i].UpdatedAt.After(result[j].UpdatedAt) })
	return result
}

func (hub *Hub) findingDetails(id string) (FindingDetails, error) {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	finding := hub.findings[id]
	if finding == nil {
		return FindingDetails{}, errNotFound
	}
	events := append([]FindingEvent(nil), hub.findingEvents[id]...)
	return FindingDetails{Finding: finding.dto(), Events: events}, nil
}

func (hub *Hub) createFinding(request CreateFindingRequest) (FindingDTO, error) {
	title := strings.TrimSpace(request.Title)
	if validateRequestID(request.RequestID) != nil || !canonicalThreadIDPattern.MatchString(request.ThreadPublicRef) || !hub.validFindingTitle(title) {
		return FindingDTO{}, errInvalid
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if hub.closed || hub.poisoned {
		return FindingDTO{}, errConflict
	}
	bodyHash := hashParts("finding.create", request.ThreadPublicRef, title)
	if existing, found, err := hub.dedupeFindingLocked(request.RequestID, bodyHash); found || err != nil {
		if existing == nil {
			return FindingDTO{}, err
		}
		return existing.dto(), err
	}
	id, err := newID()
	if err != nil {
		return FindingDTO{}, err
	}
	now := time.Now().UTC()
	finding := &Finding{ID: id, Version: 1, ThreadPublicRef: request.ThreadPublicRef, Title: title, WorkState: findingActive, FixVerification: verificationUnverified, CreatedAt: now, UpdatedAt: now}
	change := &FindingEvent{FindingID: id, EventType: "created", ToState: findingActive, Actor: "operator", Timestamp: now}
	record := &requestRecord{RequestHash: hashText(request.RequestID), BodyHash: bodyHash, FindingID: id}
	if err := hub.persistFindingLocked(finding, change, record); err != nil {
		return FindingDTO{}, err
	}
	return finding.dto(), nil
}

func (hub *Hub) validFindingTitle(title string) bool {
	return title != "" && strings.TrimSpace(title) == title && len([]rune(title)) <= 240 && !strings.ContainsAny(title, "\r\n") && !emailPattern.MatchString(title) && hub.maskOutput(title) == title
}

func (hub *Hub) changeFinding(id string, request ChangeFindingRequest) (FindingDTO, error) {
	if validateRequestID(request.RequestID) != nil || request.ExpectedVersion == 0 || !findingCodeOrEmpty(request.Reason) || !findingCodeOrEmpty(request.EvidenceRef) || hub.maskOutput(request.Reason) != request.Reason || hub.maskOutput(request.EvidenceRef) != request.EvidenceRef {
		return FindingDTO{}, errInvalid
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if hub.closed || hub.poisoned {
		return FindingDTO{}, errConflict
	}
	finding := hub.findings[id]
	if finding == nil {
		return FindingDTO{}, errNotFound
	}
	bodyHash := hashParts("finding.change", id, request.EventType, string(request.Resolution), request.Reason, request.EvidenceKind, request.EvidenceRef, fmt.Sprint(request.ExpectedVersion))
	if existing, found, err := hub.dedupeFindingLocked(request.RequestID, bodyHash); found || err != nil {
		if existing == nil {
			return FindingDTO{}, err
		}
		return existing.dto(), err
	}
	if finding.Version != request.ExpectedVersion {
		return FindingDTO{}, errConflict
	}
	before := *finding
	from := finding.WorkState
	if err := applyFindingChange(finding, request); err != nil {
		*finding = before
		return FindingDTO{}, err
	}
	finding.Version++
	finding.UpdatedAt = time.Now().UTC()
	if !finding.UpdatedAt.After(before.UpdatedAt) {
		finding.UpdatedAt = before.UpdatedAt.Add(time.Nanosecond)
	}
	change := &FindingEvent{
		FindingID: finding.ID, EventType: request.EventType, FromState: from, ToState: finding.WorkState,
		Resolution: finding.Resolution, Actor: "operator", Reason: request.Reason,
		EvidenceKind: request.EvidenceKind, EvidenceRef: request.EvidenceRef, Timestamp: finding.UpdatedAt,
	}
	record := &requestRecord{RequestHash: hashText(request.RequestID), BodyHash: bodyHash, FindingID: finding.ID}
	if err := hub.persistFindingLocked(finding, change, record); err != nil {
		*finding = before
		return FindingDTO{}, err
	}
	return finding.dto(), nil
}

func findingCodeOrEmpty(value string) bool {
	return value == "" || findingCodePattern.MatchString(value)
}

func applyFindingChange(finding *Finding, request ChangeFindingRequest) error {
	switch request.EventType {
	case "triaged":
		if finding.WorkState != findingActive || request.Resolution != "" || request.EvidenceKind != "" || request.EvidenceRef != "" {
			return errConflict
		}
		finding.WorkState = findingTriaged
	case "started":
		if (finding.WorkState != findingActive && finding.WorkState != findingTriaged) || request.Resolution != "" || request.EvidenceKind != "" || request.EvidenceRef != "" {
			return errConflict
		}
		finding.WorkState = findingInProgress
		finding.Resolution = nil
		finding.FixVerification = verificationUnverified
	case "resolved":
		if finding.WorkState != findingInProgress || request.Resolution != resolutionFixed || request.EvidenceKind != "" || request.EvidenceRef != "" {
			return errConflict
		}
		resolution := resolutionFixed
		finding.WorkState = findingResolved
		finding.Resolution = &resolution
		finding.FixVerification = verificationUnverified
	case "verified":
		if finding.WorkState != findingResolved || finding.Resolution == nil || *finding.Resolution != resolutionFixed || finding.FixVerification != verificationUnverified || request.Resolution != "" || !validEvidence(request.EvidenceKind, request.EvidenceRef) {
			return errConflict
		}
		finding.FixVerification = verificationVerified
	case "ignored":
		if (finding.WorkState != findingActive && finding.WorkState != findingTriaged && finding.WorkState != findingInProgress) || !validIgnoredResolution(request.Resolution) || request.EvidenceKind != "" || request.EvidenceRef != "" {
			return errConflict
		}
		resolution := request.Resolution
		finding.WorkState = findingIgnored
		finding.Resolution = &resolution
		finding.FixVerification = verificationUnverified
	case "reopened":
		if (finding.WorkState != findingResolved && finding.WorkState != findingIgnored) || request.Reason == "" || request.Resolution != "" || request.EvidenceKind != "" || request.EvidenceRef != "" {
			return errConflict
		}
		failed := finding.Resolution != nil && *finding.Resolution == resolutionFixed
		finding.WorkState = findingActive
		finding.Resolution = nil
		finding.FixVerification = verificationUnverified
		if failed {
			finding.FixVerification = verificationFailed
		}
	default:
		return errInvalid
	}
	if !validFindingSnapshot(finding) {
		return errConflict
	}
	return nil
}

func (hub *Hub) dedupeFindingLocked(requestID, bodyHash string) (*Finding, bool, error) {
	record, found := hub.requests[hashText(requestID)]
	if !found {
		return nil, false, nil
	}
	if record.BodyHash != bodyHash || record.FindingID == "" || record.TaskID != "" {
		return nil, true, errConflict
	}
	finding := hub.findings[record.FindingID]
	if finding == nil {
		return nil, true, errConflict
	}
	return finding, true, nil
}

func (hub *Hub) persistFindingLocked(finding *Finding, change *FindingEvent, request *requestRecord) error {
	if !validFindingSnapshot(finding) {
		return errConflict
	}
	dto := finding.dto()
	record := *finding
	changeCopy := *change
	event, err := hub.store.append(journalEvent{
		RecordKind: "finding",
		Event:      PublicEvent{Version: 1, FindingID: finding.ID, Type: "finding." + change.EventType, OccurredAt: finding.UpdatedAt, Finding: &dto, FindingChange: &changeCopy},
		Finding:    &record, FindingEvent: &changeCopy, Request: request,
	})
	if err != nil {
		hub.poisonLocked()
		return err
	}
	hub.findings[finding.ID] = finding
	hub.findingEvents[finding.ID] = append(hub.findingEvents[finding.ID], changeCopy)
	if request != nil {
		hub.requests[request.RequestHash] = *request
	}
	hub.broadcastLocked(event)
	return nil
}

type appThreadStatus struct {
	Type        string   `json:"type"`
	ActiveFlags []string `json:"activeFlags"`
}

type appThreadWire struct {
	ID              string          `json:"id"`
	Name            *string         `json:"name"`
	Cwd             string          `json:"cwd"`
	ParentThreadID  *string         `json:"parentThreadId"`
	AgentNickname   *string         `json:"agentNickname"`
	AgentRole       *string         `json:"agentRole"`
	Source          json.RawMessage `json:"source"`
	Status          appThreadStatus `json:"status"`
	CreatedAt       int64           `json:"createdAt"`
	UpdatedAt       int64           `json:"updatedAt"`
	LatestTurnState LatestTurnState `json:"-"`
	SpawnParentID   string          `json:"-"`
	IsSpawn         bool            `json:"-"`
	SourceKind      string          `json:"-"`
}

type appThreadPage struct {
	Data       []appThreadWire `json:"data"`
	NextCursor *string         `json:"nextCursor"`
}

type appIDPage struct {
	Data       []string `json:"data"`
	NextCursor *string  `json:"nextCursor"`
}

type appThreadReadResponse struct {
	Thread appThreadWire `json:"thread"`
}

type appTurnWire struct {
	ID     string          `json:"id"`
	Status LatestTurnState `json:"status"`
}

type appTurnPage struct {
	Data []appTurnWire `json:"data"`
}

type appUserInputWire struct {
	Type string `json:"type"`
	Text string `json:"text"`
	Name string `json:"name"`
}

type appThreadItemWire struct {
	Type             string             `json:"type"`
	Text             string             `json:"text"`
	Content          []appUserInputWire `json:"content"`
	Command          string             `json:"command"`
	AggregatedOutput *string            `json:"aggregatedOutput"`
	Status           string             `json:"status"`
}

type appTurnContentWire struct {
	ID     string              `json:"id"`
	Items  []appThreadItemWire `json:"items"`
	Status LatestTurnState     `json:"status"`
	Error  *struct {
		Message string `json:"message"`
	} `json:"error"`
	StartedAt   *int64 `json:"startedAt"`
	CompletedAt *int64 `json:"completedAt"`
}

type appTurnContentPage struct {
	Data       []appTurnContentWire `json:"data"`
	NextCursor *string              `json:"nextCursor"`
}

type appThreadItemPage struct {
	Data []struct {
		TurnID string            `json:"turnId"`
		Item   appThreadItemWire `json:"item"`
	} `json:"data"`
	NextCursor *string `json:"nextCursor"`
}

func classifyAppThread(thread *appThreadWire) string {
	var top string
	if json.Unmarshal(thread.Source, &top) == nil {
		switch top {
		case "cli", "vscode", "exec", "appServer":
			if top == "cli" || top == "exec" {
				thread.SourceKind = "cli"
			} else {
				thread.SourceKind = "desktop"
			}
			return "root"
		default:
			return ""
		}
	}
	var wrapper struct {
		SubAgent json.RawMessage `json:"subAgent"`
	}
	if json.Unmarshal(thread.Source, &wrapper) != nil || len(wrapper.SubAgent) == 0 {
		return ""
	}
	var source struct {
		ThreadSpawn *struct {
			ParentThreadID string  `json:"parent_thread_id"`
			AgentNickname  *string `json:"agent_nickname"`
			AgentRole      *string `json:"agent_role"`
			Depth          *int    `json:"depth"`
		} `json:"thread_spawn"`
	}
	if json.Unmarshal(wrapper.SubAgent, &source) != nil || source.ThreadSpawn == nil || source.ThreadSpawn.Depth == nil || *source.ThreadSpawn.Depth < 1 || thread.ParentThreadID == nil || *thread.ParentThreadID != source.ThreadSpawn.ParentThreadID {
		return ""
	}
	thread.IsSpawn = true
	thread.SpawnParentID = source.ThreadSpawn.ParentThreadID
	thread.SourceKind = "desktop"
	if thread.AgentNickname == nil {
		thread.AgentNickname = source.ThreadSpawn.AgentNickname
	}
	if thread.AgentRole == nil {
		thread.AgentRole = source.ThreadSpawn.AgentRole
	}
	return "spawn"
}

func runtimeStateFromApp(status appThreadStatus) CodexRuntimeState {
	switch status.Type {
	case "active":
		for _, flag := range status.ActiveFlags {
			if flag == "waitingOnUserInput" || flag == "waitingOnApproval" {
				return runtimeNeedsInput
			}
		}
		return runtimeWorking
	case "idle":
		return runtimeReady
	case "systemError":
		return runtimeError
	default:
		return runtimeNotLoaded
	}
}

func runtimePriority(state CodexRuntimeState) int {
	switch state {
	case runtimeNeedsInput:
		return 5
	case runtimeError:
		return 4
	case runtimeWorking:
		return 3
	case runtimeReady:
		return 2
	default:
		return 1
	}
}

func (board *CodexBoard) replaceAppThreads(raw []appThreadWire, loaded map[string]bool, mode CodexObserverMode, observedAt time.Time) error {
	board.mutationMu.Lock()
	defer board.mutationMu.Unlock()
	board.mu.Lock()
	defer board.mu.Unlock()
	if board.blocked {
		return errConflict
	}

	allowed := make(map[string]appThreadWire, len(raw))
	for _, item := range raw {
		if !canonicalThreadIDPattern.MatchString(item.ID) {
			continue
		}
		kind := classifyAppThread(&item)
		if kind == "root" || kind == "spawn" {
			allowed[item.ID] = item
		}
	}
	for id, item := range allowed {
		if !item.IsSpawn {
			continue
		}
		parent := allowed[item.SpawnParentID]
		if parent.ID == "" {
			delete(allowed, id)
		}
	}

	nextRefs := cloneThreadRefs(board.refs)
	refsChanged := false
	for internalID := range allowed {
		if _, ok := nextRefs[internalID]; ok {
			continue
		}
		publicRef, err := newID()
		if err != nil {
			return err
		}
		nextRefs[internalID] = threadRefRecord{PublicRef: publicRef, ReviewState: reviewUnreviewed}
		refsChanged = true
	}
	if refsChanged {
		if err := saveThreadRefs(board.config.DataDir, nextRefs); err != nil {
			board.blockLocked("thread_refs_write_uncertain")
			return err
		}
	}

	next := make(map[string]*ObservedThread, len(allowed))
	for internalID, item := range allowed {
		rootID, ok := rootThreadID(internalID, allowed)
		if !ok {
			continue
		}
		record := nextRefs[internalID]
		rootRecord := nextRefs[rootID]
		parentRef := ""
		if item.IsSpawn && item.ParentThreadID != nil {
			parentRef = nextRefs[*item.ParentThreadID].PublicRef
		}
		state := runtimeStateFromApp(item.Status)
		if mode != observerSharedLive || !loaded[internalID] {
			state = runtimeNotLoaded
		}
		runtimeUpdatedAt := time.Time{}
		if previous := board.threads[internalID]; mode == observerSharedLive && previous != nil && previous.RuntimeUpdatedAt.After(observedAt) {
			state = previous.RuntimeState
			runtimeUpdatedAt = previous.RuntimeUpdatedAt
		}
		if pending := board.pendingRuntime[internalID]; mode == observerSharedLive && pending.At.After(observedAt) && pending.At.After(runtimeUpdatedAt) {
			state = pending.State
			runtimeUpdatedAt = pending.At
		}
		updatedAt := time.Unix(item.UpdatedAt, 0).UTC()
		if item.UpdatedAt <= 0 {
			updatedAt = time.Unix(item.CreatedAt, 0).UTC()
		}
		turnState := validTurnState(item.LatestTurnState)
		activeTurnID := ""
		turnUpdatedAt := time.Time{}
		if previous := board.threads[internalID]; turnState == turnUnknown && previous != nil {
			turnState = previous.LatestTurnState
			if mode == observerSharedLive {
				activeTurnID = previous.ActiveTurnID
			}
			turnUpdatedAt = previous.TurnUpdatedAt
		}
		if pending := board.pendingTurns[internalID]; mode == observerSharedLive && pending.At.After(observedAt) && pending.At.After(turnUpdatedAt) {
			if pending.State == turnInProgress && canonicalThreadIDPattern.MatchString(pending.TurnID) {
				turnState = turnInProgress
				activeTurnID = pending.TurnID
				turnUpdatedAt = pending.At
			} else if pending.TurnID == activeTurnID && activeTurnID != "" {
				turnState = validTurnState(pending.State)
				activeTurnID = ""
				turnUpdatedAt = pending.At
			}
		}
		if state == runtimeReady && turnState != turnInProgress {
			activeTurnID = ""
		}
		if runtimeUpdatedAt.After(updatedAt) {
			updatedAt = runtimeUpdatedAt
		}
		if turnUpdatedAt.After(updatedAt) {
			updatedAt = turnUpdatedAt
		}
		cwd := item.Cwd
		if cwd == "" {
			if previous := board.threads[internalID]; previous != nil {
				cwd = previous.Cwd
			}
		}
		sandboxMode := record.SandboxMode
		if sandboxMode == "" {
			sandboxMode = board.config.Mode
		}
		next[internalID] = &ObservedThread{
			InternalID: internalID, RootInternalID: rootID, Cwd: cwd, PublicRef: record.PublicRef,
			ParentInternalID: item.SpawnParentID,
			Title:            board.safeThreadTitle(item.Name, item.SourceKind), SourceKind: item.SourceKind, ProjectAlias: board.projectAlias(cwd),
			ParentPublicRef: parentRef, RootPublicRef: rootRecord.PublicRef,
			AgentNickname: board.safeLabel(item.AgentNickname), AgentRole: board.safeLabel(item.AgentRole),
			RuntimeState: state, AggregateState: state, LatestTurnState: turnState, ActiveTurnID: activeTurnID,
			RuntimeUpdatedAt: runtimeUpdatedAt, TurnUpdatedAt: turnUpdatedAt,
			ReviewState: record.ReviewState, SandboxMode: sandboxMode, Model: record.Model,
			UpdatedAt: updatedAt, IsSubagent: item.IsSpawn,
		}
	}
	recomputeAggregates(next)
	board.refs = nextRefs
	board.reverse = make(map[string]string, len(nextRefs))
	for internalID, record := range nextRefs {
		board.reverse[record.PublicRef] = internalID
	}
	board.threads = next
	clear(board.pendingRuntime)
	clear(board.pendingTurns)
	board.mode = mode
	if mode == observerSharedLive {
		board.code = "ok"
	} else {
		board.code = "shared_daemon_unavailable"
	}
	board.updatedAt = time.Now().UTC()
	return nil
}

func rootThreadID(id string, threads map[string]appThreadWire) (string, bool) {
	seen := make(map[string]bool)
	current := id
	for len(seen) <= len(threads) {
		if seen[current] {
			return "", false
		}
		seen[current] = true
		thread, ok := threads[current]
		if !ok {
			return "", false
		}
		if !thread.IsSpawn {
			return current, true
		}
		current = thread.SpawnParentID
	}
	return "", false
}

func recomputeAggregates(threads map[string]*ObservedThread) {
	for _, thread := range threads {
		thread.AggregateState = thread.RuntimeState
	}
	for pass := 0; pass < len(threads); pass++ {
		changed := false
		for _, child := range threads {
			parent := threads[child.ParentInternalID]
			if parent != nil && runtimePriority(child.AggregateState) > runtimePriority(parent.AggregateState) {
				parent.AggregateState = child.AggregateState
				changed = true
			}
		}
		if !changed {
			break
		}
	}
}

func validTurnState(state LatestTurnState) LatestTurnState {
	switch state {
	case turnInProgress, turnCompleted, turnInterrupted, turnFailed:
		return state
	default:
		return turnUnknown
	}
}

func (board *CodexBoard) safeLabel(value *string) string {
	if value == nil {
		return ""
	}
	label := strings.Join(strings.Fields(*value), " ")
	label = emailPattern.ReplaceAllString(label, "[ACCOUNT]")
	label = board.hub.maskOutput(label)
	runes := []rune(label)
	if len(runes) > 60 {
		label = string(runes[:60]) + "…"
	}
	return label
}

func (board *CodexBoard) safeThreadTitle(value *string, sourceKind string) string {
	if value == nil || strings.TrimSpace(*value) == "" {
		if sourceKind == "cli" {
			return "命令行任务"
		}
		return "未命名任务"
	}
	title := strings.Join(strings.Fields(*value), " ")
	title = emailPattern.ReplaceAllString(title, "[ACCOUNT]")
	title = board.hub.maskOutput(title)
	runes := []rune(title)
	if len(runes) > 180 {
		title = string(runes[:180]) + "…"
	}
	return title
}

func (board *CodexBoard) projectAlias(cwd string) string {
	bestAlias := "未归类"
	bestLength := -1
	for alias, root := range board.config.Projects {
		if pathContains(root, cwd) && len(root) > bestLength {
			bestAlias = alias
			bestLength = len(root)
		}
	}
	return bestAlias
}

// setObserverNotice 记录本次刷新的降级提示；顶层任务数据不受影响。
func (board *CodexBoard) setObserverNotice(notices []string) {
	if len(notices) == 0 {
		board.mu.Lock()
		if board.notice != "" {
			board.notice = ""
			board.updatedAt = time.Now().UTC()
		}
		board.mu.Unlock()
		return
	}
	seen := make(map[string]bool, len(notices))
	ordered := make([]string, 0, len(notices))
	for _, item := range notices {
		if item == "" || seen[item] {
			continue
		}
		seen[item] = true
		ordered = append(ordered, item)
	}
	if len(ordered) == 0 {
		return
	}
	board.mu.Lock()
	board.notice = strings.Join(ordered, ",")
	board.updatedAt = time.Now().UTC()
	board.mu.Unlock()
}

func (board *CodexBoard) setUnavailable(code string) {
	board.mu.Lock()
	if board.blocked {
		board.mu.Unlock()
		board.broadcastUpdate()
		return
	}
	board.mode = observerUnavailable
	board.code = code
	board.updatedAt = time.Now().UTC()
	for _, thread := range board.threads {
		thread.RuntimeState = runtimeNotLoaded
		thread.ActiveTurnID = ""
		if thread.LatestTurnState == turnInProgress {
			thread.LatestTurnState = turnUnknown
		}
	}
	clear(board.pendingRuntime)
	clear(board.pendingTurns)
	recomputeAggregates(board.threads)
	board.mu.Unlock()
	board.broadcastUpdate()
}

func (board *CodexBoard) blockLocked(code string) {
	board.blocked = true
	board.mode = observerUnavailable
	board.code = code
	board.updatedAt = time.Now().UTC()
	board.threads = make(map[string]*ObservedThread)
	clear(board.pendingRuntime)
	clear(board.pendingTurns)
}

func (board *CodexBoard) mergeLatestTurns(states map[string]appTurnWire, queryStarted time.Time) {
	board.mu.Lock()
	if board.blocked {
		board.mu.Unlock()
		return
	}
	for id, latest := range states {
		if thread := board.threads[id]; thread != nil && !thread.TurnUpdatedAt.After(queryStarted) {
			thread.LatestTurnState = validTurnState(latest.Status)
			thread.ActiveTurnID = ""
			if thread.LatestTurnState == turnInProgress && canonicalThreadIDPattern.MatchString(latest.ID) {
				thread.ActiveTurnID = latest.ID
			}
			thread.TurnUpdatedAt = time.Now().UTC()
		}
	}
	board.updatedAt = time.Now().UTC()
	board.mu.Unlock()
}

func (board *CodexBoard) handleNotification(mode CodexObserverMode, method string, params json.RawMessage) {
	if mode != observerSharedLive {
		return
	}
	board.mu.Lock()
	if board.blocked || board.mode == observerHistoryOnly {
		board.mu.Unlock()
		return
	}
	changed := false
	switch method {
	case "thread/started":
		select {
		case board.refreshNow <- struct{}{}:
		default:
		}
	case "thread/status/changed":
		var notification struct {
			ThreadID string          `json:"threadId"`
			Status   appThreadStatus `json:"status"`
		}
		if json.Unmarshal(params, &notification) == nil && canonicalThreadIDPattern.MatchString(notification.ThreadID) {
			now := time.Now().UTC()
			if thread := board.threads[notification.ThreadID]; thread != nil {
				thread.RuntimeState = runtimeStateFromApp(notification.Status)
				thread.RuntimeUpdatedAt = now
				thread.UpdatedAt = now
				changed = true
			} else if len(board.pendingRuntime) < 1024 {
				board.pendingRuntime[notification.ThreadID] = pendingRuntimeUpdate{State: runtimeStateFromApp(notification.Status), At: now}
			}
		}
	case "turn/started", "turn/completed":
		var notification struct {
			ThreadID string `json:"threadId"`
			TurnID   string `json:"turnId"`
			Turn     struct {
				ID     string          `json:"id"`
				Status LatestTurnState `json:"status"`
			} `json:"turn"`
		}
		decoded := json.Unmarshal(params, &notification) == nil
		if notification.Turn.ID == "" {
			notification.Turn.ID = notification.TurnID
		}
		if decoded && canonicalThreadIDPattern.MatchString(notification.ThreadID) && canonicalThreadIDPattern.MatchString(notification.Turn.ID) {
			now := time.Now().UTC()
			turnState := validTurnState(notification.Turn.Status)
			if method == "turn/started" {
				turnState = turnInProgress
			} else if turnState == turnUnknown {
				turnState = turnCompleted
			}
			if thread := board.threads[notification.ThreadID]; thread != nil {
				if method == "turn/started" {
					thread.LatestTurnState = turnInProgress
					thread.ActiveTurnID = notification.Turn.ID
					thread.RuntimeState = runtimeWorking
					thread.TurnUpdatedAt = now
					thread.RuntimeUpdatedAt = now
					thread.UpdatedAt = now
					changed = true
				} else if thread.ActiveTurnID == notification.Turn.ID {
					thread.LatestTurnState = turnState
					thread.ActiveTurnID = ""
					if turnState == turnFailed {
						thread.RuntimeState = runtimeError
					} else {
						thread.RuntimeState = runtimeReady
					}
					thread.TurnUpdatedAt = now
					thread.RuntimeUpdatedAt = now
					thread.UpdatedAt = now
					changed = true
				}
			} else if method == "turn/started" && len(board.pendingTurns) < 1024 {
				board.pendingTurns[notification.ThreadID] = pendingTurnUpdate{State: turnInProgress, TurnID: notification.Turn.ID, At: now}
				if len(board.pendingRuntime) < 1024 {
					board.pendingRuntime[notification.ThreadID] = pendingRuntimeUpdate{State: runtimeWorking, At: now}
				}
			} else if pending := board.pendingTurns[notification.ThreadID]; pending.State == turnInProgress && pending.TurnID == notification.Turn.ID {
				board.pendingTurns[notification.ThreadID] = pendingTurnUpdate{State: turnState, TurnID: notification.Turn.ID, At: now}
				if len(board.pendingRuntime) < 1024 {
					runtimeState := runtimeReady
					if turnState == turnFailed {
						runtimeState = runtimeError
					}
					board.pendingRuntime[notification.ThreadID] = pendingRuntimeUpdate{State: runtimeState, At: now}
				}
			}
		}
	}
	if changed {
		recomputeAggregates(board.threads)
		board.updatedAt = time.Now().UTC()
	}
	board.mu.Unlock()
	if changed {
		board.broadcastUpdate()
	}
}

type appRPCResult struct {
	Result json.RawMessage
	Err    error
}

type subAgentSupport int

const (
	subAgentUnknown subAgentSupport = iota
	subAgentSupported
	subAgentUnsupported
)

// subAgentUnsupportedError 只把明确的协议/能力类错误视为“版本不支持”，
// 其余错误按本次降级处理，下一轮刷新会重试。
func subAgentUnsupportedError(err error) bool {
	if err == nil {
		return false
	}
	text := strings.ToLower(err.Error())
	for _, marker := range []string{"method", "sourcekinds", "source", "capability", "unsupported", "not found", "unknown", "invalid"} {
		if strings.Contains(text, marker) {
			return true
		}
	}
	return false
}

type appServerClient struct {
	socketPath string
	codexHome  string
	mu         sync.Mutex
	writeMu    sync.Mutex
	encoder    *json.Encoder
	ws         *wsOverUnixSocket
	input      io.WriteCloser
	pending    map[int64]chan appRPCResult
	resumed    map[string]bool
	nextID     int64
	done       chan struct{}
	failOnce   sync.Once
	cancel     context.CancelFunc
	board      *CodexBoard
	mode       CodexObserverMode
	subAgents  subAgentSupport
}

func (client *appServerClient) live() bool {
	select {
	case <-client.done:
		return false
	default:
		return true
	}
}

func (client *appServerClient) ensureThreadResumed(ctx context.Context, target codexControlTarget) error {
	client.mu.Lock()
	resumed := client.resumed != nil && client.resumed[target.ThreadID]
	client.mu.Unlock()
	if resumed {
		return nil
	}
	var response appThreadReadResponse
	params := map[string]any{
		"threadId": target.ThreadID, "cwd": target.Cwd, "excludeTurns": true, "sandbox": target.SandboxMode,
	}
	if target.Model != "" {
		params["model"] = target.Model
	}
	if err := client.call(ctx, "thread/resume", params, &response); err != nil {
		return err
	}
	if response.Thread.ID != target.ThreadID {
		return fmt.Errorf("app_server_thread_mismatch")
	}
	client.mu.Lock()
	if client.resumed == nil {
		client.resumed = make(map[string]bool)
	}
	client.resumed[target.ThreadID] = true
	client.mu.Unlock()
	return nil
}

type wsOverUnixSocket struct {
	conn   net.Conn
	reader *bufio.Reader
}

type wsFrame struct {
	fin     bool
	opcode  byte
	payload []byte
}

func startAppServerClient(parent context.Context, board *CodexBoard) (*appServerClient, error) {
	return startSharedAppServerClient(parent, board)
}

func startSharedAppServerClient(parent context.Context, board *CodexBoard) (*appServerClient, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("codex_home_unavailable")
	}
	return startSharedAppServerClientFromHome(parent, board, home)
}

func startSharedAppServerClientFromHome(parent context.Context, board *CodexBoard, home string) (*appServerClient, error) {
	codexHome := filepath.Join(home, ".codex")
	socket, err := sharedAppServerSocket(codexHome)
	if err != nil {
		return nil, err
	}
	return startSocketAppServerClient(parent, board, socket, codexHome)
}

func sharedAppServerSocket(codexHome string) (string, error) {
	socket := filepath.Join(codexHome, "app-server-control", "app-server-control.sock")
	info, err := os.Lstat(socket)
	if err != nil {
		return "", fmt.Errorf("app_server_socket_unavailable")
	}
	if info.Mode()&os.ModeSymlink != 0 || info.Mode()&os.ModeSocket == 0 {
		return "", fmt.Errorf("app_server_socket_invalid")
	}
	return socket, nil
}

func startSocketAppServerClient(parent context.Context, board *CodexBoard, socket, codexHome string) (*appServerClient, error) {
	ws, err := dialAppServerWebSocket(parent, socket)
	if err != nil {
		return nil, err
	}
	client := &appServerClient{
		ws: ws, pending: make(map[int64]chan appRPCResult), nextID: 2,
		done: make(chan struct{}), cancel: func() { _ = ws.closeWithCode(1000, "client closing") }, board: board, mode: observerSharedLive,
		socketPath: socket, codexHome: codexHome,
	}
	go client.readLoop(nil)
	if err := initializeAppServerClient(parent, client, codexHome); err != nil {
		client.close()
		return nil, err
	}
	return client, nil
}

func initializeAppServerClient(parent context.Context, client *appServerClient, codexHome string) error {
	initializeContext, cancelInitialize := context.WithTimeout(parent, 8*time.Second)
	defer cancelInitialize()
	var initialized struct {
		CodexHome      string `json:"codexHome"`
		PlatformFamily string `json:"platformFamily"`
		PlatformOS     string `json:"platformOs"`
		UserAgent      string `json:"userAgent"`
	}
	if err := client.callWithID(initializeContext, 1, "initialize", map[string]any{
		"clientInfo":   map[string]string{"name": "agent-remote-control", "title": "Agent Remote Control", "version": version},
		"capabilities": map[string]any{"experimentalApi": true, "optOutNotificationMethods": []string{}},
	}, &initialized); err != nil || filepath.Clean(initialized.CodexHome) != filepath.Clean(codexHome) || initialized.PlatformFamily == "" || initialized.PlatformOS == "" || initialized.UserAgent == "" {
		client.close()
		return fmt.Errorf("app_server_initialize")
	}
	if err := client.notify("initialized", nil); err != nil {
		return fmt.Errorf("app_server_initialize")
	}
	return nil
}

func dialAppServerWebSocket(ctx context.Context, socket string) (*wsOverUnixSocket, error) {
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", socket)
	if err != nil {
		return nil, fmt.Errorf("app_server_socket_unavailable")
	}
	ws := &wsOverUnixSocket{conn: conn, reader: bufio.NewReader(conn)}
	if err := ws.handshake(); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return ws, nil
}

func (ws *wsOverUnixSocket) handshake() error {
	keyBytes := make([]byte, 16)
	if _, err := crand.Read(keyBytes); err != nil {
		return fmt.Errorf("app_server_handshake")
	}
	key := base64.StdEncoding.EncodeToString(keyBytes)
	request := "GET / HTTP/1.1\r\n" +
		"Host: localhost\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n\r\n"
	if _, err := io.WriteString(ws.conn, request); err != nil {
		return fmt.Errorf("app_server_handshake")
	}
	status, headers, err := readWebSocketUpgrade(ws.reader)
	if err != nil || !strings.Contains(status, " 101 ") {
		return fmt.Errorf("app_server_handshake")
	}
	if !strings.EqualFold(headers["upgrade"], "websocket") || !strings.Contains(strings.ToLower(headers["connection"]), "upgrade") {
		return fmt.Errorf("app_server_handshake")
	}
	expected := websocketAccept(key)
	if headers["sec-websocket-accept"] != expected {
		return fmt.Errorf("app_server_handshake")
	}
	return nil
}

func readWebSocketUpgrade(reader *bufio.Reader) (string, map[string]string, error) {
	status, err := reader.ReadString('\n')
	if err != nil {
		return "", nil, err
	}
	status = strings.TrimSpace(status)
	headers := make(map[string]string)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return "", nil, err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			return status, headers, nil
		}
		name, value, ok := strings.Cut(line, ":")
		if !ok {
			return "", nil, fmt.Errorf("invalid_header")
		}
		headers[strings.ToLower(strings.TrimSpace(name))] = strings.TrimSpace(value)
	}
}

func websocketAccept(key string) string {
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(sum[:])
}

func (ws *wsOverUnixSocket) writeTextMessage(payload []byte) error {
	return ws.writeFrame(0x1, payload)
}

func (ws *wsOverUnixSocket) writeControlFrame(opcode byte, payload []byte) error {
	if len(payload) > 125 {
		payload = payload[:125]
	}
	return ws.writeFrame(opcode, payload)
}

func (ws *wsOverUnixSocket) writeFrame(opcode byte, payload []byte) error {
	header := make([]byte, 2, 14)
	header[0] = 0x80 | (opcode & 0x0f)
	header[1] = 0x80
	switch {
	case len(payload) < 126:
		header[1] |= byte(len(payload))
	case len(payload) <= 65535:
		header[1] |= 126
		extra := make([]byte, 2)
		binary.BigEndian.PutUint16(extra, uint16(len(payload)))
		header = append(header, extra...)
	default:
		header[1] |= 127
		extra := make([]byte, 8)
		binary.BigEndian.PutUint64(extra, uint64(len(payload)))
		header = append(header, extra...)
	}
	mask := make([]byte, 4)
	if _, err := crand.Read(mask); err != nil {
		return fmt.Errorf("app_server_write")
	}
	header = append(header, mask...)
	masked := append([]byte(nil), payload...)
	for index := range masked {
		masked[index] ^= mask[index%4]
	}
	if _, err := ws.conn.Write(header); err != nil {
		return fmt.Errorf("app_server_write")
	}
	if _, err := ws.conn.Write(masked); err != nil {
		return fmt.Errorf("app_server_write")
	}
	return nil
}

func (ws *wsOverUnixSocket) readTextMessage() ([]byte, error) {
	var assembled bytes.Buffer
	opcode := byte(0)
	for {
		frame, err := ws.readFrame()
		if err != nil {
			return nil, err
		}
		switch frame.opcode {
		case 0x8:
			_ = ws.writeControlFrame(0x8, frame.payload)
			return nil, fmt.Errorf("app_server_disconnected")
		case 0x9:
			if err := ws.writeControlFrame(0xA, frame.payload); err != nil {
				return nil, err
			}
			continue
		case 0xA:
			continue
		case 0x1, 0x0:
			if frame.opcode == 0x1 {
				opcode = frame.opcode
			} else if opcode == 0 {
				return nil, fmt.Errorf("app_server_frame")
			}
			if len(frame.payload) > 4*1024*1024-assembled.Len() {
				return nil, fmt.Errorf("app_server_frame")
			}
			if _, err := assembled.Write(frame.payload); err != nil {
				return nil, fmt.Errorf("app_server_frame")
			}
			if frame.fin {
				if opcode != 0x1 {
					return nil, fmt.Errorf("app_server_frame")
				}
				return assembled.Bytes(), nil
			}
		default:
			return nil, fmt.Errorf("app_server_frame")
		}
	}
}

func (ws *wsOverUnixSocket) readFrame() (wsFrame, error) {
	var header [2]byte
	if _, err := io.ReadFull(ws.reader, header[:]); err != nil {
		return wsFrame{}, fmt.Errorf("app_server_disconnected")
	}
	fin := header[0]&0x80 != 0
	opcode := header[0] & 0x0f
	masked := header[1]&0x80 != 0
	lengthCode := int(header[1] & 0x7f)
	if masked {
		return wsFrame{}, fmt.Errorf("app_server_frame")
	}
	length, err := readWebSocketLength(ws.reader, lengthCode)
	if err != nil {
		return wsFrame{}, err
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(ws.reader, payload); err != nil {
		return wsFrame{}, fmt.Errorf("app_server_disconnected")
	}
	return wsFrame{fin: fin, opcode: opcode, payload: payload}, nil
}

func readWebSocketLength(reader io.Reader, lengthCode int) (int, error) {
	switch lengthCode {
	case 126:
		var extended [2]byte
		if _, err := io.ReadFull(reader, extended[:]); err != nil {
			return 0, fmt.Errorf("app_server_disconnected")
		}
		return int(binary.BigEndian.Uint16(extended[:])), nil
	case 127:
		var extended [8]byte
		if _, err := io.ReadFull(reader, extended[:]); err != nil {
			return 0, fmt.Errorf("app_server_disconnected")
		}
		length := binary.BigEndian.Uint64(extended[:])
		if length > 4*1024*1024 {
			return 0, fmt.Errorf("app_server_frame")
		}
		return int(length), nil
	default:
		return lengthCode, nil
	}
}

func (ws *wsOverUnixSocket) closeWithCode(code uint16, reason string) error {
	payload := make([]byte, 2+len(reason))
	binary.BigEndian.PutUint16(payload[:2], code)
	copy(payload[2:], reason)
	if err := ws.writeControlFrame(0x8, payload); err != nil {
		_ = ws.conn.Close()
		return err
	}
	return ws.conn.Close()
}

func (client *appServerClient) readLoop(reader io.Reader) {
	if client.ws != nil {
		for {
			payload, err := client.ws.readTextMessage()
			if err != nil {
				client.fail(err)
				return
			}
			client.handleRPCMessage(payload)
		}
	}
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		client.handleRPCMessage(scanner.Bytes())
	}
	client.fail(fmt.Errorf("app_server_disconnected"))
}

func (client *appServerClient) handleRPCMessage(payload []byte) {
	var message struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
		Result json.RawMessage `json:"result"`
		Error  json.RawMessage `json:"error"`
	}
	if json.Unmarshal(payload, &message) != nil {
		return
	}
	if message.Method != "" {
		if len(message.ID) == 0 {
			client.board.handleNotification(client.mode, message.Method, message.Params)
		} else {
			client.rejectServerRequest(message.ID)
		}
		return
	}
	var id int64
	if json.Unmarshal(message.ID, &id) != nil {
		return
	}
	client.mu.Lock()
	channel := client.pending[id]
	delete(client.pending, id)
	client.mu.Unlock()
	if channel == nil {
		return
	}
	if len(message.Error) > 0 && string(message.Error) != "null" {
		var errPayload struct {
			Message string `json:"message"`
		}
		detail := "app_server_response"
		if json.Unmarshal(message.Error, &errPayload) == nil && errPayload.Message != "" {
			detail = "app_server_response: " + errPayload.Message
		}
		channel <- appRPCResult{Err: errors.New(detail)}
	} else {
		channel <- appRPCResult{Result: message.Result}
	}
}

func (client *appServerClient) rejectServerRequest(id json.RawMessage) {
	client.writeMu.Lock()
	err := client.writeMessage(map[string]any{
		"id":    id,
		"error": map[string]any{"code": -32601, "message": "unsupported_server_request"},
	})
	client.writeMu.Unlock()
	if err != nil {
		client.fail(err)
	}
}

func (client *appServerClient) fail(err error) {
	client.failOnce.Do(func() {
		client.mu.Lock()
		pending := client.pending
		client.pending = make(map[int64]chan appRPCResult)
		close(client.done)
		client.mu.Unlock()
		for _, channel := range pending {
			channel <- appRPCResult{Err: err}
		}
	})
}

func (client *appServerClient) close() {
	client.cancel()
	if client.input != nil {
		_ = client.input.Close()
	}
	if client.ws != nil {
		_ = client.ws.closeWithCode(1000, "client closing")
	}
	client.fail(fmt.Errorf("app_server_closed"))
}

func (client *appServerClient) notify(method string, params any) error {
	message := map[string]any{"method": method}
	if params != nil {
		message["params"] = params
	}
	client.writeMu.Lock()
	defer client.writeMu.Unlock()
	err := client.writeMessage(message)
	if err != nil {
		client.fail(err)
		return err
	}
	return nil
}

func (client *appServerClient) call(ctx context.Context, method string, params any, target any) error {
	client.mu.Lock()
	id := client.nextID
	client.nextID++
	client.mu.Unlock()
	return client.callWithID(ctx, id, method, params, target)
}

func (client *appServerClient) callWithID(ctx context.Context, id int64, method string, params any, target any) error {
	channel := make(chan appRPCResult, 1)
	client.mu.Lock()
	select {
	case <-client.done:
		client.mu.Unlock()
		return fmt.Errorf("app_server_disconnected")
	case <-ctx.Done():
		client.mu.Unlock()
		return fmt.Errorf("app_server_timeout")
	default:
	}
	client.pending[id] = channel
	client.mu.Unlock()
	client.writeMu.Lock()
	err := client.writeMessage(map[string]any{"id": id, "method": method, "params": params})
	client.writeMu.Unlock()
	if err != nil {
		client.mu.Lock()
		delete(client.pending, id)
		client.mu.Unlock()
		client.fail(err)
		return fmt.Errorf("app_server_write")
	}
	select {
	case result := <-channel:
		if result.Err != nil {
			return result.Err
		}
		if target == nil {
			return nil
		}
		if json.Unmarshal(result.Result, target) != nil {
			return fmt.Errorf("app_server_decode")
		}
		return nil
	case <-ctx.Done():
		client.mu.Lock()
		delete(client.pending, id)
		client.mu.Unlock()
		return fmt.Errorf("app_server_timeout")
	}
}

func (client *appServerClient) writeMessage(message any) error {
	if client.ws != nil {
		payload, err := json.Marshal(message)
		if err != nil {
			return err
		}
		return client.ws.writeTextMessage(payload)
	}
	if client.encoder == nil {
		return fmt.Errorf("app_server_write")
	}
	return client.encoder.Encode(message)
}

// listThreads 拉取线程清单；超过 1000 条时截断并返回 truncated=true，
// 不再让超大清单拖垮整轮刷新。
func (client *appServerClient) listThreads(ctx context.Context, params map[string]any) ([]appThreadWire, bool, error) {
	result := make([]appThreadWire, 0)
	var cursor string
	for {
		pageParams := make(map[string]any, len(params)+1)
		for key, value := range params {
			pageParams[key] = value
		}
		if cursor != "" {
			pageParams["cursor"] = cursor
		}
		var page appThreadPage
		requestContext, cancel := context.WithTimeout(ctx, 8*time.Second)
		err := client.call(requestContext, "thread/list", pageParams, &page)
		cancel()
		if err != nil {
			return nil, false, err
		}
		result = append(result, page.Data...)
		if len(result) >= 1000 {
			return result[:1000], true, nil
		}
		if page.NextCursor == nil || *page.NextCursor == "" {
			return result, false, nil
		}
		cursor = *page.NextCursor
	}
}

func (client *appServerClient) loadedThreadIDs(ctx context.Context) (map[string]bool, bool, error) {
	result := make(map[string]bool)
	var cursor string
	for {
		params := map[string]any{"limit": 250}
		if cursor != "" {
			params["cursor"] = cursor
		}
		var page appIDPage
		requestContext, cancel := context.WithTimeout(ctx, 8*time.Second)
		err := client.call(requestContext, "thread/loaded/list", params, &page)
		cancel()
		if err != nil {
			return nil, false, err
		}
		for _, id := range page.Data {
			if canonicalThreadIDPattern.MatchString(id) {
				result[id] = true
			}
		}
		if len(result) >= 1000 {
			return result, true, nil
		}
		if page.NextCursor == nil || *page.NextCursor == "" {
			return result, false, nil
		}
		cursor = *page.NextCursor
	}
}

func (client *appServerClient) latestTurn(ctx context.Context, threadID string) appTurnWire {
	var page appTurnPage
	requestContext, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if client.call(requestContext, "thread/turns/list", map[string]any{
		"threadId": threadID, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded",
	}, &page) != nil || len(page.Data) == 0 {
		return appTurnWire{Status: turnUnknown}
	}
	page.Data[0].Status = validTurnState(page.Data[0].Status)
	return page.Data[0]
}

func (client *appServerClient) threadContent(ctx context.Context, threadID string, hub *Hub) (CodexThreadContentDTO, error) {
	var page appTurnContentPage
	requestContext, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	if err := client.call(requestContext, "thread/turns/list", map[string]any{
		"threadId": threadID, "limit": 8, "sortDirection": "desc", "itemsView": "summary",
	}, &page); err != nil {
		return CodexThreadContentDTO{}, err
	}
	// Keep a useful, bounded display if an individual item page cannot be read.
	summaries := page
	summaries.Data = append([]appTurnContentWire(nil), page.Data...)
	summaryFallback := func() (CodexThreadContentDTO, error) {
		result := boundedThreadContent(summaries, hub)
		result.Truncated = true
		return result, nil
	}
	scanned := 0
	truncated := false
	for index := range page.Data {
		if scanned >= 64 {
			truncated = true
			break
		}
		turn := &page.Data[index]
		if turn.ID == "" {
			return summaryFallback()
		}
		var items []appThreadItemWire
		cursor := ""
		seen := make(map[string]bool)
		for scanned < 64 {
			limit := min(16, 64-scanned)
			params := map[string]any{"threadId": threadID, "turnId": turn.ID, "limit": limit, "sortDirection": "desc"}
			if cursor != "" {
				params["cursor"] = cursor
			}
			var itemPage appThreadItemPage
			if err := client.call(requestContext, "thread/items/list", params, &itemPage); err != nil {
				return summaryFallback()
			}
			if len(itemPage.Data) > limit {
				return summaryFallback()
			}
			for _, entry := range itemPage.Data {
				if entry.TurnID != turn.ID {
					return summaryFallback()
				}
				items = append(items, entry.Item)
			}
			scanned += len(itemPage.Data)
			if itemPage.NextCursor == nil || *itemPage.NextCursor == "" {
				break
			}
			next := *itemPage.NextCursor
			if len(itemPage.Data) == 0 || seen[next] || next == cursor {
				return summaryFallback()
			}
			seen[next] = true
			cursor = next
			if scanned >= 64 {
				truncated = true
			}
		}
		for left, right := 0, len(items)-1; left < right; left, right = left+1, right-1 {
			items[left], items[right] = items[right], items[left]
		}
		turn.Items = items
	}
	result := boundedThreadContent(page, hub)
	result.Truncated = result.Truncated || truncated
	return result, nil
}

func boundedThreadContent(page appTurnContentPage, hub *Hub) CodexThreadContentDTO {
	result := CodexThreadContentDTO{Turns: make([]CodexTurnContentDTO, 0, len(page.Data))}
	result.HasMore = page.NextCursor != nil && *page.NextCursor != ""
	remaining := 64 * 1024
	items := 0
	for _, turn := range page.Data {
		view := CodexTurnContentDTO{
			Status: validTurnState(turn.Status), StartedAt: unixTime(turn.StartedAt), CompletedAt: unixTime(turn.CompletedAt),
			Items: make([]CodexContentItemDTO, 0, len(turn.Items)+1),
		}
		for index := len(turn.Items) - 1; index >= 0; index-- {
			item := turn.Items[index]
			if items >= 64 || remaining <= 0 {
				result.Truncated = true
				break
			}
			kind, text := threadItemText(item)
			if kind == "" || text == "" {
				continue
			}
			text, clipped := safeThreadContent(hub, text, remaining)
			if text == "" {
				continue
			}
			if clipped {
				result.Truncated = true
			}
			remaining -= len([]rune(text))
			view.Items = append(view.Items, CodexContentItemDTO{Kind: kind, Text: text, Status: item.Status})
			items++
		}
		for left, right := 0, len(view.Items)-1; left < right; left, right = left+1, right-1 {
			view.Items[left], view.Items[right] = view.Items[right], view.Items[left]
		}
		if turn.Error != nil && turn.Error.Message != "" && items < 64 && remaining > 0 {
			text, clipped := safeThreadContent(hub, turn.Error.Message, remaining)
			if text != "" {
				if clipped {
					result.Truncated = true
				}
				remaining -= len([]rune(text))
				view.Items = append(view.Items, CodexContentItemDTO{Kind: "error", Text: text})
				items++
			}
		}
		result.Turns = append(result.Turns, view)
	}
	return result
}

func threadItemText(item appThreadItemWire) (string, string) {
	switch item.Type {
	case "userMessage":
		parts := make([]string, 0, len(item.Content))
		for _, input := range item.Content {
			switch input.Type {
			case "text":
				parts = append(parts, input.Text)
			case "image", "localImage":
				parts = append(parts, "[图片]")
			case "audio", "localAudio":
				parts = append(parts, "[音频]")
			case "skill":
				parts = append(parts, "[Skill] "+input.Name)
			case "mention":
				parts = append(parts, "@"+input.Name)
			}
		}
		return "user", strings.TrimSpace(strings.Join(parts, "\n"))
	case "agentMessage":
		return "assistant", strings.TrimSpace(item.Text)
	case "plan":
		return "plan", strings.TrimSpace(item.Text)
	case "commandExecution":
		parts := make([]string, 0, 2)
		if strings.TrimSpace(item.Command) != "" {
			parts = append(parts, "$ "+strings.TrimSpace(item.Command))
		}
		if item.AggregatedOutput != nil && strings.TrimSpace(*item.AggregatedOutput) != "" {
			parts = append(parts, strings.TrimSpace(*item.AggregatedOutput))
		}
		return "command", strings.Join(parts, "\n")
	default:
		return "", ""
	}
}

func safeThreadContent(hub *Hub, value string, remaining int) (string, bool) {
	value = contentThreadIDPattern.ReplaceAllString(value, "[THREAD]")
	value = emailPattern.ReplaceAllString(value, "[ACCOUNT]")
	value = strings.TrimSpace(hub.maskOutput(value))
	runes := []rune(value)
	limit := max(0, min(remaining, 8*1024))
	if len(runes) <= limit {
		return value, false
	}
	marker := []rune("\n…[内容已截断]")
	if limit <= len(marker) {
		return string(runes[:limit]), true
	}
	return string(runes[:limit-len(marker)]) + string(marker), true
}

func unixTime(value *int64) *time.Time {
	if value == nil || *value <= 0 {
		return nil
	}
	timestamp := time.Unix(*value, 0).UTC()
	return &timestamp
}

func (client *appServerClient) readThread(ctx context.Context, threadID string) (appThreadWire, error) {
	var response appThreadReadResponse
	requestContext, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := client.call(requestContext, "thread/read", map[string]any{"threadId": threadID, "includeTurns": false}, &response); err != nil {
		return appThreadWire{}, err
	}
	if response.Thread.ID != threadID {
		return appThreadWire{}, fmt.Errorf("app_server_thread_mismatch")
	}
	return response.Thread, nil
}

func (board *CodexBoard) refreshFromAppServer(ctx context.Context, client *appServerClient) error {
	observedAt := time.Now().UTC()
	notices := make([]string, 0, 3)
	roots, rootsTruncated, err := client.listThreads(ctx, map[string]any{
		"limit": 250, "sortKey": "recency_at", "sortDirection": "desc",
		"sourceKinds": []string{"cli", "vscode", "exec", "appServer"},
	})
	if err != nil {
		return err
	}
	if rootsTruncated {
		notices = append(notices, noticeThreadsTruncated)
	}
	// 子 Agent 树失败不再拖垮整轮刷新：能力缺失按“不支持”记忆并跳过，
	// 其他错误按本次降级处理，下一轮重试。
	var spawns []appThreadWire
	if client.subAgents == subAgentUnsupported {
		notices = append(notices, noticeSubAgentUnsupported)
	} else {
		spawnList, spawnsTruncated, spawnErr := client.listThreads(ctx, map[string]any{
			"limit": 250, "sortKey": "recency_at", "sortDirection": "desc",
			"sourceKinds": []string{"subAgentThreadSpawn"},
		})
		if spawnErr != nil {
			if subAgentUnsupportedError(spawnErr) {
				client.subAgents = subAgentUnsupported
				notices = append(notices, noticeSubAgentUnsupported)
			} else {
				notices = append(notices, noticeSubAgentQueryDegraded)
			}
			spawns = nil
		} else {
			client.subAgents = subAgentSupported
			spawns = spawnList
			if spawnsTruncated {
				notices = append(notices, noticeThreadsTruncated)
			}
		}
	}
	threads := append(roots, spawns...)
	loaded := make(map[string]bool)
	if client.mode == observerSharedLive {
		loaded, loadedTruncated, err := client.loadedThreadIDs(ctx)
		if err != nil {
			return err
		}
		if loadedTruncated {
			notices = append(notices, noticeThreadsTruncated)
		}
		seen := make(map[string]bool, len(threads))
		for _, thread := range threads {
			seen[thread.ID] = true
		}
		for id := range loaded {
			if seen[id] {
				continue
			}
			thread, readErr := client.readThread(ctx, id)
			if readErr != nil {
				// 单个已加载线程读取失败只跳过该线程，不放弃其余数据。
				notices = append(notices, noticeLoadedThreadReadSkipped)
				continue
			}
			threads = append(threads, thread)
			seen[id] = true
		}
	}
	board.setObserverNotice(notices)
	if err := board.replaceAppThreads(threads, loaded, client.mode, observedAt); err != nil {
		return err
	}
	board.broadcastUpdate()
	queryStarted := observedAt
	turns := make(map[string]appTurnWire, len(threads))
	for _, thread := range threads {
		turns[thread.ID] = appTurnWire{Status: turnUnknown}
	}
	// ponytail: cap turn lookups; paginate details only if inventories above 250 become common.
	for index := range threads {
		if index >= 250 || ctx.Err() != nil {
			break
		}
		turns[threads[index].ID] = client.latestTurn(ctx, threads[index].ID)
	}
	board.mergeLatestTurns(turns, queryStarted)
	board.broadcastUpdate()
	return nil
}

func promoteHistoryClient(
	ctx context.Context,
	board *CodexBoard,
	history *appServerClient,
	start func(context.Context, *CodexBoard) (*appServerClient, error),
	refresh func(context.Context, *appServerClient) error,
) (*appServerClient, bool) {
	candidate, err := start(ctx, board)
	if err != nil {
		return history, false
	}
	refreshContext, cancelRefresh := context.WithTimeout(ctx, 60*time.Second)
	err = refresh(refreshContext, candidate)
	cancelRefresh()
	if err != nil {
		candidate.close()
		return history, false
	}
	board.publishClient(candidate)
	history.close()
	return candidate, true
}

func (board *CodexBoard) run(ctx context.Context) {
	backoff := time.Second
	for {
		if ctx.Err() != nil || board.isBlocked() {
			return
		}
		client, err := startAppServerClient(ctx, board)
		if err != nil {
			board.setUnavailable("observer_connect_failed")
			if !waitContext(ctx, backoff) {
				return
			}
			backoff = minDuration(backoff*2, 30*time.Second)
			continue
		}
		refreshContext, cancelRefresh := context.WithTimeout(ctx, 60*time.Second)
		err = board.refreshFromAppServer(refreshContext, client)
		cancelRefresh()
		if err != nil {
			client.close()
			board.setUnavailable("observer_refresh_failed")
			if board.isBlocked() {
				return
			}
			if !waitContext(ctx, backoff) {
				return
			}
			backoff = minDuration(backoff*2, 30*time.Second)
			continue
		}
		board.refreshModels(ctx, client)
		board.publishClient(client)
		backoff = time.Second
		ticker := time.NewTicker(60 * time.Second)
		probeTicker := time.NewTicker(10 * time.Second)
		connected := true
		for connected {
			select {
			case <-ctx.Done():
				ticker.Stop()
				probeTicker.Stop()
				board.retireClient(client)
				return
			case <-client.done:
				connected = false
			case <-board.refreshNow:
				refreshContext, cancelRefresh := context.WithTimeout(ctx, 60*time.Second)
				if board.refreshFromAppServer(refreshContext, client) != nil {
					connected = false
				}
				cancelRefresh()
			case <-ticker.C:
				refreshContext, cancelRefresh := context.WithTimeout(ctx, 60*time.Second)
				if board.refreshFromAppServer(refreshContext, client) != nil {
					connected = false
				} else {
					board.refreshModels(refreshContext, client)
				}
				cancelRefresh()
			case <-probeTicker.C:
				if client.mode == observerHistoryOnly {
					var promoted bool
					client, promoted = promoteHistoryClient(ctx, board, client, startSharedAppServerClient, board.refreshFromAppServer)
					if promoted {
						board.refreshModels(ctx, client)
					}
				}
			}
		}
		ticker.Stop()
		probeTicker.Stop()
		board.retireClient(client)
		board.setUnavailable("observer_disconnected")
		if board.isBlocked() {
			return
		}
		if !waitContext(ctx, backoff) {
			return
		}
		backoff = minDuration(backoff*2, 30*time.Second)
	}
}

func waitContext(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
