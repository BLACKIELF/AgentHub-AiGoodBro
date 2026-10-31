package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const version = "0910v2-next"
const maxJSONBodyBytes = 72 * 1024
const maxAttachmentRequestBytes = 25 * 1024 * 1024

//go:embed web/index.html
var indexHTML []byte

func main() {
	versionFlag := flag.Bool("version", false, "print the companion version")
	configPath := flag.String("config", "config.json", "path to config")
	initTokenFlag := flag.Bool("init-token", false, "create token file without printing the token")
	flag.Parse()
	if *versionFlag {
		fmt.Println(version)
		return
	}

	config, err := loadConfig(*configPath)
	if err != nil {
		log.Fatal("configuration blocked: ", safeCode(err))
	}
	if *initTokenFlag {
		if err := initToken(config); err != nil {
			log.Fatal("token initialization blocked: ", safeCode(err))
		}
		fmt.Println("token file created")
		return
	}
	token, err := readConfiguredToken(config)
	if err != nil {
		log.Fatal("authentication blocked: ", safeCode(err))
	}
	hub, err := newHub(config, string(token))
	if err != nil {
		log.Fatal("state recovery blocked: ", safeCode(err))
	}
	policyPath, err := filepath.Abs(*configPath)
	if err != nil {
		hub.shutdown(context.Background())
		log.Fatal("configuration blocked: config_path")
	}
	hub.dispatchPolicyPath = policyPath
	hub.activityDirectory = filepath.Dir(defaultManagerSnapshotPath())
	if config.ActivityDirectory != "" {
		hub.activityDirectory = config.ActivityDirectory
	}
	if config.ManagerSnapshotPath != "" {
		hub.managerSnapshotPath = config.ManagerSnapshotPath
	}
	board, err := newCodexBoard(config, hub)
	if err != nil {
		hub.shutdown(context.Background())
		log.Fatal("codex board recovery blocked: ", safeCode(err))
	}
	requireToken := config.RequireToken == nil || *config.RequireToken
	api := &API{hub: hub, board: board, token: token, requireToken: requireToken, requireTokenSet: true, managerSnapshotPath: hub.managerSnapshotPath}
	server := &http.Server{
		Addr:              config.Listen,
		Handler:           api.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 * 1024,
		ErrorLog:          log.New(io.Discard, "", 0),
	}

	ctx, stop := signal.NotifyContext(context.Background(), shutdownSignals()...)
	defer stop()
	listener, err := net.Listen("tcp", config.Listen)
	if err != nil {
		hub.shutdown(context.Background())
		log.Fatal("server stopped: listen_failed")
	}
	if err := writeReadyFile(config.ReadyFile, listener.Addr().String()); err != nil {
		listener.Close()
		hub.shutdown(context.Background())
		log.Fatal("server stopped: ready_file")
	}
	go board.run(ctx)
	errChannel := make(chan error, 1)
	log.Printf("agent remote control %s listening on %s", version, listener.Addr().String())
	go func() {
		errChannel <- server.Serve(listener)
	}()
	serveFailed := false
	select {
	case <-ctx.Done():
	case serveErr := <-errChannel:
		if !errors.Is(serveErr, http.ErrServerClosed) {
			serveFailed = true
		}
	}
	hubContext, cancelHub := context.WithTimeout(context.Background(), 10*time.Second)
	hub.shutdown(hubContext)
	cancelHub()
	serverContext, cancelServer := context.WithTimeout(context.Background(), 3*time.Second)
	_ = server.Shutdown(serverContext)
	cancelServer()
	if serveFailed {
		log.Fatal("server stopped: listen_failed")
	}
}

func loadConfig(path string) (Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return Config{}, fmt.Errorf("config_open")
	}
	defer file.Close()
	limited := &io.LimitedReader{R: file, N: 128*1024 + 1}
	decoder := json.NewDecoder(limited)
	decoder.DisallowUnknownFields()
	var config Config
	if err := decoder.Decode(&config); err != nil {
		return Config{}, fmt.Errorf("config_decode")
	}
	if err := requireEOF(decoder); err != nil {
		return Config{}, fmt.Errorf("config_trailing_data")
	}
	if limited.N == 0 {
		return Config{}, fmt.Errorf("config_too_large")
	}
	if config.Listen == "" {
		config.Listen = "127.0.0.1:8787"
	}
	if err := validateConfiguredListen(config); err != nil {
		return Config{}, err
	}
	if config.ApprovalTTLSeconds == 0 {
		config.ApprovalTTLSeconds = 300
	}
	if config.ApprovalTTLSeconds < 30 || config.ApprovalTTLSeconds > 3600 {
		return Config{}, fmt.Errorf("approval_ttl")
	}
	if config.ApprovalQuotaMaxAgeSeconds == 0 {
		config.ApprovalQuotaMaxAgeSeconds = defaultApprovalQuotaMaxAgeSeconds
	}
	if config.ApprovalQuotaMaxAgeSeconds < minimumApprovalQuotaMaxAgeSeconds || config.ApprovalQuotaMaxAgeSeconds > maximumApprovalQuotaMaxAgeSeconds {
		return Config{}, fmt.Errorf("approval_quota_max_age")
	}
	if config.Mode == "" {
		config.Mode = "read-only"
	}
	if config.Mode != "read-only" && config.Mode != "workspace-write" {
		return Config{}, fmt.Errorf("mode_invalid")
	}
	if config.AccountStrategy == "" {
		config.AccountStrategy = "system"
	}
	if config.AccountStrategy != "system" && config.AccountStrategy != "round_robin" && config.AccountStrategy != "least_recently_used" {
		return Config{}, fmt.Errorf("account_strategy_invalid")
	}
	if config.ClaudeMaxBudgetUSD <= 0 || config.ClaudeMaxBudgetUSD > 100 {
		return Config{}, fmt.Errorf("claude_budget")
	}
	if config.Commands == nil {
		config.Commands = map[string]string{"codex": "codex", "claude": "claude", "kimi": "kimi"}
	}
	for name, command := range config.Commands {
		if (name != "codex" && name != "claude" && name != "kimi") || strings.TrimSpace(command) == "" {
			return Config{}, fmt.Errorf("command_invalid")
		}
	}
	if config.Commands["codex"] == "" {
		return Config{}, fmt.Errorf("command_missing")
	}
	if len(config.Projects) == 0 {
		return Config{}, fmt.Errorf("projects_missing")
	}
	configFile, err := filepath.Abs(path)
	if err != nil {
		return Config{}, fmt.Errorf("config_path")
	}
	base := filepath.Dir(configFile)
	tokenRequired := config.RequireToken == nil || *config.RequireToken
	if config.DataDir == "" {
		config.DataDir = "./var"
	}
	if tokenRequired && config.TokenFile == "" {
		config.TokenFile = "./var/token"
	}
	for _, value := range []*string{&config.ManagerSnapshotPath, &config.ActivityDirectory, &config.ReadyFile, &config.WorkflowPreferencesPath, &config.WorkflowCatalogPath} {
		if *value != "" {
			*value = resolveRelative(base, *value)
		}
	}
	if strings.HasSuffix(config.Listen, ":0") && (config.ReadyFile == "" || !tokenRequired) {
		return Config{}, fmt.Errorf("listen_ready_required")
	}
	config.DataDir = resolveRelative(base, config.DataDir)
	if tokenRequired {
		config.TokenFile = resolveRelative(base, config.TokenFile)
	}
	if config.KimiAutomationsDir != "" {
		if !filepath.IsAbs(config.KimiAutomationsDir) {
			return Config{}, fmt.Errorf("kimi_automations_dir_invalid")
		}
		config.KimiAutomationsDir = filepath.Clean(config.KimiAutomationsDir)
	}
	resolvedAccounts := make([]AccountConfig, 0, len(config.Accounts))
	accountAliases := make(map[string]bool, len(config.Accounts))
	for _, account := range config.Accounts {
		if !projectAliasPattern.MatchString(account.Alias) || !filepath.IsAbs(account.Home) {
			return Config{}, fmt.Errorf("account_invalid")
		}
		if accountAliases[account.Alias] || account.Alias == "system" {
			return Config{}, fmt.Errorf("account_invalid")
		}
		accountAliases[account.Alias] = true
		resolvedAccounts = append(resolvedAccounts, AccountConfig{
			Alias: account.Alias, Home: filepath.Clean(account.Home), DispatchDisabled: account.DispatchDisabled,
		})
	}
	config.Accounts = resolvedAccounts
	resolvedProjects := make(map[string]string, len(config.Projects))
	for alias, root := range config.Projects {
		if !projectAliasPattern.MatchString(alias) || !filepath.IsAbs(root) {
			return Config{}, fmt.Errorf("project_invalid")
		}
		resolved, err := filepath.EvalSymlinks(root)
		if err != nil {
			return Config{}, fmt.Errorf("project_unavailable")
		}
		info, err := os.Stat(resolved)
		if err != nil || !info.IsDir() || filepath.Clean(resolved) == string(filepath.Separator) {
			return Config{}, fmt.Errorf("project_unavailable")
		}
		resolvedProjects[alias] = filepath.Clean(resolved)
	}
	config.Projects = resolvedProjects
	for _, root := range resolvedProjects {
		if pathContains(root, config.DataDir) || (tokenRequired && pathContains(root, config.TokenFile)) {
			return Config{}, fmt.Errorf("storage_inside_project")
		}
	}
	return config, nil
}

func pathContains(root, target string) bool {
	relative, err := filepath.Rel(root, target)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

var projectAliasPattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,40}$`)

func validateLoopback(address string) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil || port == "" {
		return fmt.Errorf("listen_invalid")
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("listen_not_loopback")
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil || portNumber < 1 || portNumber > 65535 {
		return fmt.Errorf("listen_invalid")
	}
	return nil
}

func resolveRelative(base, path string) string {
	if filepath.IsAbs(path) {
		return filepath.Clean(path)
	}
	return filepath.Clean(filepath.Join(base, path))
}

func initToken(config Config) error {
	if err := ensurePrivateDir(config.DataDir); err != nil {
		return err
	}
	if filepath.Dir(config.TokenFile) != config.DataDir {
		if err := ensurePrivateDir(filepath.Dir(config.TokenFile)); err != nil {
			return err
		}
	}
	random := make([]byte, 32)
	if _, err := rand.Read(random); err != nil {
		return fmt.Errorf("token_random")
	}
	file, err := openPrivateFile(config.TokenFile, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("token_exists_or_unwritable")
	}
	defer file.Close()
	if _, err := fmt.Fprintln(file, hex.EncodeToString(random)); err != nil {
		return fmt.Errorf("token_write")
	}
	if err := file.Sync(); err != nil {
		return fmt.Errorf("token_sync")
	}
	return nil
}

func readToken(path string) ([]byte, error) {
	file, err := openPrivateFile(path, os.O_RDONLY, 0)
	if err != nil {
		return nil, fmt.Errorf("token_read")
	}
	defer file.Close()
	if privateFilePermissions(file) != nil {
		return nil, fmt.Errorf("token_permissions")
	}
	value, err := io.ReadAll(io.LimitReader(file, 257))
	if err != nil {
		return nil, fmt.Errorf("token_read")
	}
	if len(value) > 256 {
		return nil, fmt.Errorf("token_length")
	}
	value = []byte(strings.TrimSpace(string(value)))
	if len(value) < 32 || len(value) > 256 {
		return nil, fmt.Errorf("token_length")
	}
	return value, nil
}

func readConfiguredToken(config Config) ([]byte, error) {
	if config.RequireToken != nil && !*config.RequireToken {
		return nil, nil
	}
	return readToken(config.TokenFile)
}

func safeCode(err error) string {
	if err == nil {
		return "ok"
	}
	value := err.Error()
	if len(value) > 64 || strings.ContainsAny(value, "/\\\n\r") {
		return "internal_error"
	}
	return value
}

type API struct {
	hub                 *Hub
	board               *CodexBoard
	token               []byte
	requireToken        bool
	requireTokenSet     bool
	managerSnapshotPath string
	now                 func() time.Time
}

func (api *API) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", api.handleIndex)
	mux.HandleFunc("/healthz", api.handleHealth)
	mux.HandleFunc("/api/overview", api.auth(api.handleOverview))
	mux.HandleFunc("/api/events", api.auth(api.handleEvents))
	mux.HandleFunc("/api/tasks", api.auth(api.handleCreate))
	mux.HandleFunc("/api/tasks/", api.auth(api.handleTaskAction))
	mux.HandleFunc("/api/requests/", api.auth(api.handleRequestLookup))
	mux.HandleFunc("/api/codex/overview", api.auth(api.handleCodexOverview))
	mux.HandleFunc("/api/codex/threads/", api.auth(api.handleCodexThreadAction))
	mux.HandleFunc("/api/codex/findings", api.auth(api.handleCodexFindings))
	mux.HandleFunc("/api/codex/findings/", api.auth(api.handleCodexFindingAction))
	mux.HandleFunc("/api/manager/overview", api.auth(api.handleManagerOverview))
	mux.HandleFunc("/api/kimi/tasks", api.auth(api.handleKimiTasks))
	return api.securityHeaders(mux)
}

func (api *API) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Cache-Control", "no-store")
		response.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'none'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		response.Header().Set("Referrer-Policy", "no-referrer")
		response.Header().Set("X-Content-Type-Options", "nosniff")
		response.Header().Set("X-Frame-Options", "DENY")
		next.ServeHTTP(response, request)
	})
}

func (api *API) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(response http.ResponseWriter, request *http.Request) {
		if !api.requireTokenSet || api.requireToken {
			parts := strings.Fields(request.Header.Get("Authorization"))
			if len(parts) != 2 || parts[0] != "Bearer" || subtle.ConstantTimeCompare([]byte(parts[1]), api.token) != 1 {
				writeError(response, http.StatusUnauthorized, "unauthorized")
				return
			}
		}
		if request.Method != http.MethodGet && !sameOrigin(request) {
			writeError(response, http.StatusForbidden, "origin_rejected")
			return
		}
		next(response, request)
	}
}

func sameOrigin(request *http.Request) bool {
	origin := request.Header.Get("Origin")
	if origin == "" {
		return true
	}
	parsed, err := url.Parse(origin)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return false
	}
	return strings.EqualFold(parsed.Host, request.Host)
}

func (api *API) handleIndex(response http.ResponseWriter, request *http.Request) {
	if request.URL.Path != "/" || request.Method != http.MethodGet {
		http.NotFound(response, request)
		return
	}
	response.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = response.Write(indexHTML)
}

func (api *API) handleHealth(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	if !api.hub.healthy() {
		writeJSON(response, http.StatusServiceUnavailable, map[string]string{"status": "blocked", "version": version})
		return
	}
	writeJSON(response, http.StatusOK, map[string]string{"status": "ok", "version": version})
}

func (api *API) handleOverview(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	writeJSON(response, http.StatusOK, api.hub.overview())
}

func (api *API) handleManagerOverview(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	path := api.managerSnapshotPath
	if path == "" {
		path = defaultManagerSnapshotPath()
	}
	now := time.Now()
	if api.now != nil {
		now = api.now()
	}
	overview, err := readManagerOverview(path, api.hub.config.Accounts, now)
	if err != nil {
		writeError(response, http.StatusServiceUnavailable, errManagerSnapshotUnavailable.Error())
		return
	}
	writeJSON(response, http.StatusOK, overview)
}

func (api *API) handleKimiTasks(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	writeJSON(response, http.StatusOK, readKimiTasks(api.hub.config.KimiAutomationsDir))
}

func (api *API) handleCreate(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	var body CreateRequest
	if err := decodeJSON(response, request, &body); err != nil {
		writeError(response, http.StatusBadRequest, "invalid_request")
		return
	}
	task, err := api.hub.create(body)
	writeTaskResult(response, task, err, http.StatusCreated)
}

func (api *API) handleTaskAction(response http.ResponseWriter, request *http.Request) {
	parts := strings.Split(strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/tasks/"), "/"), "/")
	if len(parts) != 2 || parts[0] == "" {
		writeError(response, http.StatusNotFound, "not_found")
		return
	}
	taskID, action := parts[0], parts[1]
	if action == "messages" && request.Method == http.MethodGet {
		conversation, err := api.hub.taskConversation(taskID)
		if err != nil {
			writeBoardError(response, err)
			return
		}
		writeJSON(response, http.StatusOK, conversation)
		return
	}
	if request.Method != http.MethodPost {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	switch action {
	case "approve":
		var body ApproveRequest
		if decodeJSON(response, request, &body) != nil {
			writeError(response, http.StatusBadRequest, "invalid_request")
			return
		}
		task, err := api.hub.approve(taskID, body)
		writeTaskResult(response, task, err, http.StatusOK)
	case "cancel":
		var body CancelRequest
		if decodeJSON(response, request, &body) != nil {
			writeError(response, http.StatusBadRequest, "invalid_request")
			return
		}
		task, err := api.hub.cancel(taskID, body)
		writeTaskResult(response, task, err, http.StatusOK)
	case "resume":
		var body CreateRequest
		if decodeJSON(response, request, &body) != nil {
			writeError(response, http.StatusBadRequest, "invalid_request")
			return
		}
		task, err := api.hub.resume(taskID, body)
		writeTaskResult(response, task, err, http.StatusCreated)
	case "resolve":
		var body ResolveRequest
		if decodeJSON(response, request, &body) != nil {
			writeError(response, http.StatusBadRequest, "invalid_request")
			return
		}
		task, err := api.hub.resolve(taskID, body)
		writeTaskResult(response, task, err, http.StatusOK)
	default:
		writeError(response, http.StatusNotFound, "not_found")
	}
}

func (api *API) handleCodexOverview(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	if api.board == nil {
		writeError(response, http.StatusServiceUnavailable, "codex_board_unavailable")
		return
	}
	writeJSON(response, http.StatusOK, api.board.overview())
}

func (api *API) handleCodexThreadAction(response http.ResponseWriter, request *http.Request) {
	if api.board == nil {
		writeError(response, http.StatusServiceUnavailable, "codex_board_unavailable")
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/codex/threads/"), "/"), "/")
	if len(parts) == 1 && request.Method == http.MethodGet && canonicalThreadIDPattern.MatchString(parts[0]) {
		content, err := api.board.threadContent(request.Context(), parts[0])
		if err != nil {
			writeBoardError(response, err)
			return
		}
		writeJSON(response, http.StatusOK, content)
		return
	}
	if len(parts) == 2 && parts[1] == "attachments" && canonicalThreadIDPattern.MatchString(parts[0]) {
		api.handleCodexAttachmentUpload(response, request, parts[0])
		return
	}
	if request.Method != http.MethodPost {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	if len(parts) != 2 || !canonicalThreadIDPattern.MatchString(parts[0]) {
		writeError(response, http.StatusNotFound, "not_found")
		return
	}
	var err error
	switch parts[1] {
	case "messages":
		var body struct {
			RequestID   string   `json:"requestId"`
			Text        string   `json:"text"`
			Attachments []string `json:"attachments,omitempty"`
		}
		if decodeJSON(response, request, &body) != nil {
			writeError(response, http.StatusBadRequest, "invalid_request")
			return
		}
		var status string
		status, err = api.board.sendMessage(request.Context(), parts[0], body.RequestID, body.Text, body.Attachments)
		if err == nil {
			writeJSON(response, http.StatusOK, map[string]string{"status": status})
			return
		}
	case "interrupt":
		var body struct{}
		if decodeJSON(response, request, &body) != nil {
			writeError(response, http.StatusBadRequest, "invalid_request")
			return
		}
		err = api.board.interrupt(request.Context(), parts[0])
		if err == nil {
			writeJSON(response, http.StatusOK, map[string]string{"status": "interrupt_requested"})
			return
		}
	case "open":
		err = api.board.open(parts[0])
		if err == nil {
			writeJSON(response, http.StatusOK, map[string]string{"status": "opened"})
			return
		}
	case "review":
		var body struct {
			State ReviewState `json:"state"`
		}
		if decodeJSON(response, request, &body) != nil {
			writeError(response, http.StatusBadRequest, "invalid_request")
			return
		}
		err = api.board.setReview(parts[0], body.State)
		if err == nil {
			writeJSON(response, http.StatusOK, map[string]ReviewState{"state": body.State})
			return
		}
	case "settings":
		var body struct {
			SandboxMode string `json:"sandboxMode"`
			Model       string `json:"model"`
		}
		if decodeJSON(response, request, &body) != nil {
			writeError(response, http.StatusBadRequest, "invalid_request")
			return
		}
		var settings CodexThreadSettingsDTO
		settings, err = api.board.updateThreadSettings(request.Context(), parts[0], body.SandboxMode, body.Model)
		if err == nil {
			writeJSON(response, http.StatusOK, settings)
			return
		}
	default:
		writeError(response, http.StatusNotFound, "not_found")
		return
	}
	writeBoardError(response, err)
}

func (api *API) handleCodexAttachmentUpload(response http.ResponseWriter, request *http.Request, publicRef string) {
	if request.Method != http.MethodPost {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	if request.ContentLength > maxAttachmentRequestBytes {
		writeError(response, http.StatusRequestEntityTooLarge, "attachment_request_too_large")
		return
	}
	request.Body = http.MaxBytesReader(response, request.Body, maxAttachmentRequestBytes)
	reader, err := request.MultipartReader()
	if err != nil {
		writeError(response, http.StatusBadRequest, "invalid_request")
		return
	}
	uploaded := make([]CodexAttachmentDTO, 0, 4)
	rollback := func() {
		ids := make([]string, 0, len(uploaded))
		for _, attachment := range uploaded {
			ids = append(ids, attachment.ID)
		}
		api.board.removeAttachments(publicRef, ids)
	}
	for {
		part, partErr := reader.NextPart()
		if errors.Is(partErr, io.EOF) {
			break
		}
		if partErr != nil {
			rollback()
			var tooLarge *http.MaxBytesError
			if errors.As(partErr, &tooLarge) {
				writeError(response, http.StatusRequestEntityTooLarge, "attachment_request_too_large")
			} else {
				writeError(response, http.StatusBadRequest, "invalid_request")
			}
			return
		}
		if part.FormName() != "files" || part.FileName() == "" || len(uploaded) >= maxCodexAttachmentCount {
			_ = part.Close()
			rollback()
			writeError(response, http.StatusBadRequest, "invalid_request")
			return
		}
		attachment, storeErr := api.board.storeAttachment(publicRef, part.FileName(), part.Header.Get("Content-Type"), part)
		closeErr := part.Close()
		if storeErr != nil || closeErr != nil {
			rollback()
			writeAttachmentError(response, storeErr)
			return
		}
		uploaded = append(uploaded, attachment)
	}
	if len(uploaded) == 0 {
		writeError(response, http.StatusBadRequest, "invalid_request")
		return
	}
	writeJSON(response, http.StatusCreated, map[string][]CodexAttachmentDTO{"attachments": uploaded})
}

func writeAttachmentError(response http.ResponseWriter, err error) {
	var tooLarge *http.MaxBytesError
	switch {
	case errors.As(err, &tooLarge):
		writeError(response, http.StatusRequestEntityTooLarge, "attachment_request_too_large")
	case errors.Is(err, errAttachmentTooLarge):
		writeError(response, http.StatusRequestEntityTooLarge, "attachment_too_large")
	case errors.Is(err, errAttachmentType):
		writeError(response, http.StatusUnsupportedMediaType, "attachment_type_unsupported")
	case errors.Is(err, errNotFound):
		writeError(response, http.StatusNotFound, "not_found")
	case errors.Is(err, errInvalid):
		writeError(response, http.StatusBadRequest, "invalid_request")
	default:
		writeError(response, http.StatusInternalServerError, "attachment_storage_failed")
	}
}

func (api *API) handleCodexFindings(response http.ResponseWriter, request *http.Request) {
	if api.board == nil {
		writeError(response, http.StatusServiceUnavailable, "codex_board_unavailable")
		return
	}
	switch request.Method {
	case http.MethodGet:
		writeJSON(response, http.StatusOK, api.hub.findingSnapshot())
	case http.MethodPost:
		var body CreateFindingRequest
		if decodeJSON(response, request, &body) != nil {
			writeError(response, http.StatusBadRequest, "invalid_request")
			return
		}
		release, ok := api.board.beginFindingMutation()
		if !ok {
			writeError(response, http.StatusConflict, "codex_board_blocked")
			return
		}
		defer release()
		if !api.board.hasPublicRef(body.ThreadPublicRef) {
			writeError(response, http.StatusNotFound, "thread_not_found")
			return
		}
		finding, err := api.hub.createFinding(body)
		writeFindingResult(response, finding, err, http.StatusCreated)
	default:
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
	}
}

func (api *API) handleCodexFindingAction(response http.ResponseWriter, request *http.Request) {
	if api.board == nil {
		writeError(response, http.StatusServiceUnavailable, "codex_board_unavailable")
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(request.URL.Path, "/api/codex/findings/"), "/"), "/")
	if len(parts) == 1 && request.Method == http.MethodGet && canonicalThreadIDPattern.MatchString(parts[0]) {
		details, err := api.hub.findingDetails(parts[0])
		if err != nil {
			writeBoardError(response, err)
			return
		}
		writeJSON(response, http.StatusOK, details)
		return
	}
	if len(parts) != 2 || parts[1] != "events" || request.Method != http.MethodPost || !canonicalThreadIDPattern.MatchString(parts[0]) {
		writeError(response, http.StatusNotFound, "not_found")
		return
	}
	var body ChangeFindingRequest
	if decodeJSON(response, request, &body) != nil {
		writeError(response, http.StatusBadRequest, "invalid_request")
		return
	}
	release, ok := api.board.beginFindingMutation()
	if !ok {
		writeError(response, http.StatusConflict, "codex_board_blocked")
		return
	}
	defer release()
	finding, err := api.hub.changeFinding(parts[0], body)
	writeFindingResult(response, finding, err, http.StatusOK)
}

func (api *API) handleEvents(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	after, err := strconv.ParseUint(request.URL.Query().Get("after"), 10, 64)
	if request.URL.Query().Get("after") == "" {
		after = 0
		err = nil
	}
	if err != nil {
		writeError(response, http.StatusBadRequest, "invalid_cursor")
		return
	}
	flusher, ok := response.(http.Flusher)
	if !ok {
		writeError(response, http.StatusInternalServerError, "stream_unavailable")
		return
	}
	response.Header().Set("Content-Type", "application/x-ndjson; charset=utf-8")
	response.Header().Set("X-Accel-Buffering", "no")
	backlog, events, unsubscribe := api.hub.subscribe(after)
	defer unsubscribe()
	encoder := json.NewEncoder(response)
	for _, event := range backlog {
		if encoder.Encode(event) != nil {
			return
		}
	}
	flusher.Flush()
	heartbeat := time.NewTicker(15 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case event, open := <-events:
			if !open || encoder.Encode(event) != nil {
				return
			}
			flusher.Flush()
		case <-heartbeat.C:
			if encoder.Encode(PublicEvent{Version: 1, Type: "heartbeat", OccurredAt: time.Now().UTC()}) != nil {
				return
			}
			flusher.Flush()
		case <-request.Context().Done():
			return
		}
	}
}

func decodeJSON(response http.ResponseWriter, request *http.Request, target any) error {
	request.Body = http.MaxBytesReader(response, request.Body, maxJSONBodyBytes)
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	return requireEOF(decoder)
}

func requireEOF(decoder *json.Decoder) error {
	var extra any
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return fmt.Errorf("trailing_data")
	}
	return err
}

func writeTaskResult(response http.ResponseWriter, task TaskDTO, err error, successStatus int) {
	if err == nil {
		writeJSON(response, successStatus, task)
		return
	}
	switch {
	case errors.Is(err, errInvalid):
		writeError(response, http.StatusBadRequest, "invalid_request")
	case errors.Is(err, errNotFound):
		writeError(response, http.StatusNotFound, "not_found")
	case errors.Is(err, errBusy):
		writeError(response, http.StatusConflict, "project_busy")
	case errors.Is(err, errAccountBusy):
		writeError(response, http.StatusConflict, "account_busy")
	case errors.Is(err, errAccountQuotaReserve):
		writeError(response, http.StatusConflict, "account_quota_reserve")
	case errors.Is(err, errDispatchDisabled):
		writeError(response, http.StatusConflict, "account_dispatch_disabled")
	case errors.Is(err, errDispatchPolicyUnavailable):
		writeError(response, http.StatusServiceUnavailable, "dispatch_policy_unavailable")
	case errors.Is(err, errConflict):
		writeError(response, http.StatusConflict, "conflict")
	default:
		writeError(response, http.StatusInternalServerError, "internal_error")
	}
}

func writeFindingResult(response http.ResponseWriter, finding FindingDTO, err error, successStatus int) {
	if err == nil {
		writeJSON(response, successStatus, finding)
		return
	}
	writeBoardError(response, err)
}

func writeBoardError(response http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errInvalid):
		writeError(response, http.StatusBadRequest, "invalid_request")
	case errors.Is(err, errNotFound):
		writeError(response, http.StatusNotFound, "not_found")
	case errors.Is(err, errObserverUnavailable):
		writeError(response, http.StatusServiceUnavailable, "codex_content_unavailable")
	case errors.Is(err, errControlUnavailable):
		writeError(response, http.StatusServiceUnavailable, "codex_control_unavailable")
	case errors.Is(err, errControlUncertain):
		writeError(response, http.StatusConflict, "codex_control_uncertain")
	case errors.Is(err, errConflict):
		writeError(response, http.StatusConflict, "conflict")
	default:
		writeError(response, http.StatusInternalServerError, "internal_error")
	}
}

func writeError(response http.ResponseWriter, status int, code string) {
	writeJSON(response, status, map[string]string{"error": code})
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}
