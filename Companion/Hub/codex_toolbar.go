package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
)

const (
	maxCodexAttachmentBytes      = 20 * 1024 * 1024
	maxCodexImageAttachmentBytes = 10 * 1024 * 1024
	maxCodexAttachmentCount      = 16
)

var (
	errAttachmentTooLarge   = errors.New("attachment_too_large")
	errAttachmentType       = errors.New("attachment_type_unsupported")
	errAttachmentStorage    = errors.New("attachment_storage")
	errAttachmentUnresolved = errors.New("attachment_unresolved")
)

type CodexSandboxOptionDTO struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

type CodexModelDTO struct {
	Model          string `json:"model"`
	DisplayName    string `json:"displayName"`
	IsDefault      bool   `json:"isDefault"`
	SupportsImages bool   `json:"supportsImages"`
}

type CodexThreadSettingsDTO struct {
	SandboxMode      string `json:"sandboxMode"`
	Model            string `json:"model"`
	AppServerUpdated bool   `json:"appServerUpdated"`
}

type CodexAttachmentDTO struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Size    int64  `json:"size"`
	IsImage bool   `json:"isImage"`
}

type codexAttachment struct {
	CodexAttachmentDTO
	Path string
}

type codexAttachmentSpec struct {
	Extension string
	MIME      string
	IsImage   bool
	MaxBytes  int64
}

type appModelWire struct {
	Model           string   `json:"model"`
	DisplayName     string   `json:"displayName"`
	Hidden          bool     `json:"hidden"`
	IsDefault       bool     `json:"isDefault"`
	InputModalities []string `json:"inputModalities"`
}

type appModelPage struct {
	Data       []appModelWire `json:"data"`
	NextCursor *string        `json:"nextCursor"`
}

func validStoredCodexSandbox(mode string) bool {
	return mode == "" || mode == "read-only" || mode == "workspace-write"
}

// narrowCodexSandbox applies the hub mode as a hard upper bound. On invalid or
// broader input it returns the configured cap together with errInvalid.
func narrowCodexSandbox(capMode, requested string) (string, error) {
	if capMode != "read-only" && capMode != "workspace-write" {
		return "read-only", errInvalid
	}
	if requested == "" {
		return capMode, nil
	}
	if requested != "read-only" && requested != "workspace-write" {
		return capMode, errInvalid
	}
	if capMode == "read-only" && requested != "read-only" {
		return "read-only", errInvalid
	}
	return requested, nil
}

func codexSandboxOptions(capMode string) []CodexSandboxOptionDTO {
	if capMode == "workspace-write" {
		return []CodexSandboxOptionDTO{
			{Value: "workspace-write", Label: "工作区可写（默认）"},
			{Value: "read-only", Label: "只读"},
		}
	}
	return []CodexSandboxOptionDTO{{Value: "read-only", Label: "只读（默认）"}}
}

func codexSandboxPolicy(mode, cwd string) map[string]any {
	if mode == "workspace-write" {
		return map[string]any{
			"type": "workspaceWrite", "writableRoots": []string{cwd}, "networkAccess": false,
			"excludeTmpdirEnvVar": false, "excludeSlashTmp": false,
		}
	}
	return map[string]any{"type": "readOnly", "networkAccess": false}
}

func normalizeCodexModel(requested string, models []CodexModelDTO) (string, error) {
	requested = strings.TrimSpace(requested)
	if requested == "" {
		return "", nil
	}
	if !codexModelPattern.MatchString(requested) {
		return "", errInvalid
	}
	for _, model := range models {
		if model.Model == requested {
			return requested, nil
		}
	}
	return "", errInvalid
}

func (board *CodexBoard) setThreadSettings(publicRef, sandboxMode, model string) (CodexThreadSettingsDTO, error) {
	effectiveSandbox, err := narrowCodexSandbox(board.config.Mode, sandboxMode)
	if err != nil {
		return CodexThreadSettingsDTO{}, err
	}

	board.mutationMu.Lock()
	defer board.mutationMu.Unlock()
	if !board.canMutate() {
		return CodexThreadSettingsDTO{}, errConflict
	}
	board.mu.Lock()
	defer board.mu.Unlock()
	if board.blocked {
		return CodexThreadSettingsDTO{}, errConflict
	}
	internalID := board.reverse[publicRef]
	thread := board.threads[internalID]
	if internalID == "" || thread == nil || thread.IsSubagent || thread.SourceKind != "desktop" {
		return CodexThreadSettingsDTO{}, errNotFound
	}
	effectiveModel, err := normalizeCodexModel(model, board.models)
	if err != nil {
		return CodexThreadSettingsDTO{}, err
	}
	next := cloneThreadRefs(board.refs)
	record := next[internalID]
	record.SandboxMode = effectiveSandbox
	record.Model = effectiveModel
	next[internalID] = record
	if err := saveThreadRefs(board.config.DataDir, next); err != nil {
		board.blockLocked("thread_refs_write_uncertain")
		return CodexThreadSettingsDTO{}, err
	}
	board.refs = next
	thread.SandboxMode = effectiveSandbox
	thread.Model = effectiveModel
	board.updatedAt = time.Now().UTC()
	return CodexThreadSettingsDTO{SandboxMode: effectiveSandbox, Model: effectiveModel}, nil
}

func (board *CodexBoard) updateThreadSettings(ctx context.Context, publicRef, sandboxMode, model string) (CodexThreadSettingsDTO, error) {
	board.controlMu.Lock()
	defer board.controlMu.Unlock()
	settings, err := board.setThreadSettings(publicRef, sandboxMode, model)
	if err != nil {
		return CodexThreadSettingsDTO{}, err
	}
	board.broadcastUpdate()
	err = board.withDesktopControl(ctx, publicRef, func(client *appServerClient, target codexControlTarget) error {
		requestContext, cancel := context.WithTimeout(ctx, 8*time.Second)
		defer cancel()
		params := map[string]any{
			"threadId":      target.ThreadID,
			"sandboxPolicy": codexSandboxPolicy(settings.SandboxMode, target.Cwd),
		}
		if settings.Model == "" {
			params["model"] = nil
		} else {
			params["model"] = settings.Model
		}
		return client.call(requestContext, "thread/settings/update", params, nil)
	})
	if err != nil {
		// The private hub setting remains persisted and every hub-started turn still
		// sends it explicitly. The response tells the UI the live app-server sticky
		// setting was not updated, so this never fails silently.
		return settings, nil
	}
	settings.AppServerUpdated = true
	return settings, nil
}

func attachmentSpec(name, declaredContentType string) (codexAttachmentSpec, error) {
	extension := strings.ToLower(filepath.Ext(name))
	declared := strings.ToLower(strings.TrimSpace(strings.SplitN(declaredContentType, ";", 2)[0]))
	specs := map[string]codexAttachmentSpec{
		".png":  {Extension: ".png", MIME: "image/png", IsImage: true, MaxBytes: maxCodexImageAttachmentBytes},
		".jpg":  {Extension: ".jpg", MIME: "image/jpeg", IsImage: true, MaxBytes: maxCodexImageAttachmentBytes},
		".jpeg": {Extension: ".jpeg", MIME: "image/jpeg", IsImage: true, MaxBytes: maxCodexImageAttachmentBytes},
		".gif":  {Extension: ".gif", MIME: "image/gif", IsImage: true, MaxBytes: maxCodexImageAttachmentBytes},
		".webp": {Extension: ".webp", MIME: "image/webp", IsImage: true, MaxBytes: maxCodexImageAttachmentBytes},
		".pdf":  {Extension: ".pdf", MIME: "application/pdf", MaxBytes: maxCodexAttachmentBytes},
		".txt":  {Extension: ".txt", MIME: "text/plain", MaxBytes: maxCodexAttachmentBytes},
		".md":   {Extension: ".md", MIME: "text/plain", MaxBytes: maxCodexAttachmentBytes},
	}
	spec, ok := specs[extension]
	if !ok {
		return codexAttachmentSpec{}, errAttachmentType
	}
	if declared == "" || declared == "application/octet-stream" || declared == spec.MIME || extension == ".md" && declared == "text/markdown" {
		return spec, nil
	}
	return codexAttachmentSpec{}, errAttachmentType
}

func validateAttachmentContent(spec codexAttachmentSpec, sample []byte) error {
	detected := strings.ToLower(strings.TrimSpace(strings.SplitN(http.DetectContentType(sample), ";", 2)[0]))
	if detected == spec.MIME {
		return nil
	}
	return errAttachmentType
}

func sanitizeAttachmentName(name string) (string, error) {
	name = filepath.Base(strings.TrimSpace(name))
	if name == "" || name == "." || name == ".." {
		return "", errAttachmentType
	}
	var builder strings.Builder
	for _, character := range []rune(name)[:min(len([]rune(name)), 120)] {
		if unicode.IsLetter(character) || unicode.IsDigit(character) || strings.ContainsRune(" ._-", character) {
			builder.WriteRune(character)
		} else {
			builder.WriteRune('_')
		}
	}
	cleaned := strings.Trim(builder.String(), " .")
	if cleaned == "" || cleaned == "." || cleaned == ".." {
		return "", errAttachmentType
	}
	return cleaned, nil
}

func ensurePrivateAttachmentDir(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		if err := os.Mkdir(path, 0o700); err != nil {
			return errAttachmentStorage
		}
		return nil
	}
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() || privateDirectoryPermissions(path) != nil {
		return errAttachmentStorage
	}
	return nil
}

func (board *CodexBoard) attachmentThreadAllowed(publicRef string) bool {
	if !board.hub.healthy() {
		return false
	}
	board.mu.RLock()
	defer board.mu.RUnlock()
	if board.blocked {
		return false
	}
	internalID := board.reverse[publicRef]
	thread := board.threads[internalID]
	if internalID == "" || thread == nil {
		return false
	}
	_, allowed := board.desktopControlCwd(thread)
	return allowed
}

func (board *CodexBoard) storeAttachment(publicRef, originalName, declaredContentType string, source io.Reader) (CodexAttachmentDTO, error) {
	if !board.attachmentThreadAllowed(publicRef) {
		return CodexAttachmentDTO{}, errNotFound
	}
	cleanedName, err := sanitizeAttachmentName(originalName)
	if err != nil {
		return CodexAttachmentDTO{}, err
	}
	spec, err := attachmentSpec(cleanedName, declaredContentType)
	if err != nil {
		return CodexAttachmentDTO{}, err
	}
	base := filepath.Join(board.config.DataDir, "codex-attachments")
	threadDir := filepath.Join(base, publicRef)
	if err := ensurePrivateAttachmentDir(base); err != nil {
		return CodexAttachmentDTO{}, err
	}
	if err := ensurePrivateAttachmentDir(threadDir); err != nil {
		return CodexAttachmentDTO{}, err
	}
	file, err := os.CreateTemp(threadDir, ".upload-*")
	if err != nil {
		return CodexAttachmentDTO{}, errAttachmentStorage
	}
	temporary := file.Name()
	cleanup := func() {
		_ = file.Close()
		_ = os.Remove(temporary)
	}
	if err := file.Chmod(0o600); err != nil {
		cleanup()
		return CodexAttachmentDTO{}, errAttachmentStorage
	}
	written, err := io.Copy(file, io.LimitReader(source, spec.MaxBytes+1))
	if err != nil {
		cleanup()
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return CodexAttachmentDTO{}, tooLarge
		}
		return CodexAttachmentDTO{}, errAttachmentStorage
	}
	if written > spec.MaxBytes {
		cleanup()
		return CodexAttachmentDTO{}, errAttachmentTooLarge
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		cleanup()
		return CodexAttachmentDTO{}, errAttachmentStorage
	}
	sample := make([]byte, min(written, 512))
	if _, err := io.ReadFull(file, sample); err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		cleanup()
		return CodexAttachmentDTO{}, errAttachmentStorage
	}
	if err := validateAttachmentContent(spec, sample); err != nil {
		cleanup()
		return CodexAttachmentDTO{}, err
	}
	if err := file.Sync(); err != nil || file.Close() != nil {
		cleanup()
		return CodexAttachmentDTO{}, errAttachmentStorage
	}
	id, err := newID()
	if err != nil {
		_ = os.Remove(temporary)
		return CodexAttachmentDTO{}, errAttachmentStorage
	}
	destination := filepath.Join(threadDir, id+"--"+cleanedName)
	if err := os.Rename(temporary, destination); err != nil {
		_ = os.Remove(temporary)
		return CodexAttachmentDTO{}, errAttachmentStorage
	}
	directory, err := os.Open(threadDir)
	if err != nil {
		_ = os.Remove(destination)
		return CodexAttachmentDTO{}, errAttachmentStorage
	}
	syncErr := directory.Sync()
	closeErr := directory.Close()
	if syncErr != nil || closeErr != nil {
		_ = os.Remove(destination)
		return CodexAttachmentDTO{}, errAttachmentStorage
	}
	return CodexAttachmentDTO{ID: id, Name: cleanedName, Size: written, IsImage: spec.IsImage}, nil
}

func (board *CodexBoard) resolveAttachments(publicRef string, ids []string) ([]codexAttachment, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	if len(ids) > maxCodexAttachmentCount || !board.attachmentThreadAllowed(publicRef) {
		return nil, errInvalid
	}
	threadDir := filepath.Join(board.config.DataDir, "codex-attachments", publicRef)
	info, err := os.Lstat(threadDir)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return nil, errAttachmentUnresolved
	}
	entries, err := os.ReadDir(threadDir)
	if err != nil {
		return nil, errAttachmentUnresolved
	}
	seen := make(map[string]bool, len(ids))
	result := make([]codexAttachment, 0, len(ids))
	for _, id := range ids {
		if seen[id] || !canonicalThreadIDPattern.MatchString(id) {
			return nil, errInvalid
		}
		seen[id] = true
		prefix := id + "--"
		matches := make([]os.DirEntry, 0, 1)
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), prefix) {
				matches = append(matches, entry)
			}
		}
		if len(matches) != 1 {
			return nil, errAttachmentUnresolved
		}
		name := strings.TrimPrefix(matches[0].Name(), prefix)
		spec, err := attachmentSpec(name, "")
		if err != nil {
			return nil, errAttachmentUnresolved
		}
		path := filepath.Join(threadDir, matches[0].Name())
		fileInfo, err := os.Lstat(path)
		if err != nil || fileInfo.Mode()&os.ModeSymlink != 0 || !fileInfo.Mode().IsRegular() || fileInfo.Size() > spec.MaxBytes || !pathContains(threadDir, path) {
			return nil, errAttachmentUnresolved
		}
		file, err := os.Open(path)
		if err != nil {
			return nil, errAttachmentUnresolved
		}
		sample := make([]byte, min(fileInfo.Size(), 512))
		_, readErr := io.ReadFull(file, sample)
		closeErr := file.Close()
		if readErr != nil && !errors.Is(readErr, io.EOF) && !errors.Is(readErr, io.ErrUnexpectedEOF) || closeErr != nil || validateAttachmentContent(spec, sample) != nil {
			return nil, errAttachmentUnresolved
		}
		result = append(result, codexAttachment{
			CodexAttachmentDTO: CodexAttachmentDTO{ID: id, Name: name, Size: fileInfo.Size(), IsImage: spec.IsImage},
			Path:               path,
		})
	}
	return result, nil
}

func (board *CodexBoard) removeAttachments(publicRef string, ids []string) {
	attachments, err := board.resolveAttachments(publicRef, ids)
	if err != nil {
		return
	}
	for _, attachment := range attachments {
		_ = os.Remove(attachment.Path)
	}
}

func codexMessageInput(text string, attachments []codexAttachment) []map[string]any {
	paths := make([]string, 0, len(attachments))
	for _, attachment := range attachments {
		if !attachment.IsImage {
			paths = append(paths, fmt.Sprintf("- %s: %s", attachment.Name, attachment.Path))
		}
	}
	if len(paths) > 0 {
		if text != "" {
			text += "\n\n"
		}
		text += "[用户附件路径]\n" + strings.Join(paths, "\n")
	}
	input := make([]map[string]any, 0, len(attachments)+1)
	if text != "" {
		input = append(input, map[string]any{"type": "text", "text": text, "text_elements": []any{}})
	}
	for _, attachment := range attachments {
		if attachment.IsImage {
			input = append(input, map[string]any{"type": "localImage", "path": attachment.Path})
		}
	}
	return input
}

func (client *appServerClient) listModels(ctx context.Context) ([]appModelWire, error) {
	result := make([]appModelWire, 0)
	var cursor string
	for {
		params := map[string]any{"includeHidden": false, "limit": 100}
		if cursor != "" {
			params["cursor"] = cursor
		}
		var page appModelPage
		if err := client.call(ctx, "model/list", params, &page); err != nil {
			return nil, err
		}
		result = append(result, page.Data...)
		if len(result) >= 200 || page.NextCursor == nil || *page.NextCursor == "" {
			return result[:min(len(result), 200)], nil
		}
		cursor = *page.NextCursor
	}
}

func (board *CodexBoard) refreshModels(ctx context.Context, client *appServerClient) {
	requestContext, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	raw, err := client.listModels(requestContext)
	if err != nil {
		return
	}
	models := make([]CodexModelDTO, 0, len(raw))
	seen := make(map[string]bool, len(raw))
	for _, item := range raw {
		if item.Hidden || seen[item.Model] || !codexModelPattern.MatchString(item.Model) {
			continue
		}
		seen[item.Model] = true
		displayName := strings.Join(strings.Fields(item.DisplayName), " ")
		if displayName == "" {
			displayName = item.Model
		}
		displayName = board.safeLabel(&displayName)
		supportsImages := false
		for _, modality := range item.InputModalities {
			if modality == "image" {
				supportsImages = true
			}
		}
		models = append(models, CodexModelDTO{Model: item.Model, DisplayName: displayName, IsDefault: item.IsDefault, SupportsImages: supportsImages})
	}
	sort.SliceStable(models, func(i, j int) bool {
		if models[i].IsDefault != models[j].IsDefault {
			return models[i].IsDefault
		}
		return models[i].DisplayName < models[j].DisplayName
	})
	board.mu.Lock()
	board.models = models
	board.updatedAt = time.Now().UTC()
	board.mu.Unlock()
}
