package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const desktopConnectionLimit = 16 << 10

type desktopConnection struct {
	SchemaVersion   int    `json:"schemaVersion"`
	Endpoint        string `json:"endpoint"`
	ClientKey       string `json:"clientKey"`
	RunID           string `json:"runID"`
	CodexExecutable string `json:"codexExecutable"`
}

// The connection is supplied by the native host, never by Codex or its config.
func readDesktopConnection(path string) (desktopConnection, error) {
	var c desktopConnection
	bad := errors.New("invalid desktop connection")
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return c, bad
	}
	parent, err := os.Lstat(filepath.Dir(path))
	if err != nil || !parent.IsDir() || parent.Mode().Perm() != 0700 || !desktopOwned(parent) {
		return c, bad
	}
	// O_NOFOLLOW plus the identity check prevents a symlink or replacement race.
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return c, bad
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	info, err := f.Stat()
	linkInfo, linkErr := os.Lstat(path)
	if err != nil || linkErr != nil || !os.SameFile(info, linkInfo) || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || !desktopOwned(info) || info.Size() > desktopConnectionLimit {
		return c, bad
	}
	data, err := io.ReadAll(io.LimitReader(f, desktopConnectionLimit+1))
	if err != nil || len(data) > desktopConnectionLimit {
		return c, bad
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&c) != nil || decoder.Decode(new(any)) != io.EOF || c.SchemaVersion != 1 || !identifier.MatchString(c.RunID) || !desktopCleanKey(c.ClientKey) || !desktopEndpoint(c.Endpoint) || !filepath.IsAbs(c.CodexExecutable) {
		return desktopConnection{}, bad
	}
	exe, err := os.Stat(c.CodexExecutable)
	selfPath, selfErr := os.Executable()
	self, selfStatErr := os.Stat(selfPath)
	if err != nil || selfErr != nil || selfStatErr != nil || !exe.Mode().IsRegular() || exe.Mode().Perm()&0111 == 0 || os.SameFile(exe, self) {
		return desktopConnection{}, bad
	}
	return c, nil
}

func desktopOwned(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uint32(os.Getuid())
}

func desktopCleanKey(key string) bool {
	if len(key) < 24 || len(key) > 4096 {
		return false
	}
	for _, ch := range key {
		if ch < 'a' || ch > 'z' {
			if ch < 'A' || ch > 'Z' {
				if ch < '0' || ch > '9' {
					if ch != '_' && ch != '-' && ch != '+' && ch != '/' && ch != '=' {
						return false
					}
				}
			}
		}
	}
	return true
}

func desktopEndpoint(endpoint string) bool {
	const prefix = "http://127.0.0.1:"
	if !strings.HasPrefix(endpoint, prefix) || !strings.HasSuffix(endpoint, "/v1") {
		return false
	}
	portText := strings.TrimSuffix(strings.TrimPrefix(endpoint, prefix), "/v1")
	port, err := strconv.Atoi(portText)
	return err == nil && port >= 1 && port <= 65535 && strconv.Itoa(port) == portText
}

// Locate app-server after the Desktop's global config flags. Other CLI commands
// pass through without changing their configuration.
func desktopAppServerIndex(args []string) int {
	i := 0
	for i < len(args) {
		switch {
		case args[i] == "-c" || args[i] == "--config":
			if i+1 >= len(args) {
				return -1
			}
			i += 2
		case strings.HasPrefix(args[i], "--config=") || strings.HasPrefix(args[i], "-c="):
			i++
		case args[i] == "app-server":
			return i
		default:
			return -1
		}
	}
	return -1
}

func desktopArgs(args []string, index int, endpoint string) []string {
	if index < 0 {
		return append([]string(nil), args...)
	}
	overrides := []string{
		"-c", `model_provider="openai"`,
		"-c", `openai_base_url="` + endpoint + `"`,
		"-c", `features.responses_websockets=false`,
		"-c", `features.responses_websockets_v2=false`,
		"-c", `features.enable_request_compression=false`,
	}
	out := make([]string, 0, len(args)+len(overrides))
	// Desktop also supplies -c after app-server. Codex's subcommand config takes
	// precedence over the global config list, so the provider must be in that
	// same list. Otherwise initialize succeeds but every thread resume fails.
	out = append(out, args...)
	out = append(out, overrides...)
	return out
}

func desktopEnvironment(base []string, codexExecutable string) []string {
	out := make([]string, 0, len(base)+1)
	for _, entry := range base {
		name, _, _ := strings.Cut(entry, "=")
		if name != "AIGOODBRO_PROXY_KEY" && name != "AIGOODBRO_PROXY_CONNECTION_FILE" && name != "CODEX_CLI_PATH" {
			out = append(out, entry)
		}
	}
	// Official plugins discover the signed bundled Node next to CODEX_CLI_PATH.
	// Removing the variable sends them to an unsigned fallback runtime instead.
	out = append(out, "CODEX_CLI_PATH="+codexExecutable)
	return out
}

// Unknown lines are byte-for-byte passthrough. RawMessage preserves all other
// request fields (including model, effort and tool data) on changed methods.
func transformDesktopLine(line []byte) []byte {
	var msg map[string]json.RawMessage
	if json.Unmarshal(line, &msg) != nil || msg == nil {
		return line
	}
	var method string
	if json.Unmarshal(msg["method"], &method) != nil {
		return line
	}
	if method != "thread/start" && method != "thread/resume" && method != "thread/fork" && method != "thread/list" {
		return line
	}
	var params map[string]json.RawMessage
	if json.Unmarshal(msg["params"], &params) != nil || params == nil {
		return line
	}
	if method == "thread/list" {
		params["modelProviders"] = json.RawMessage(`[]`)
	} else {
		// Keep persisted thread metadata compatible with an ordinary Desktop
		// launch after the proxy is disabled. This also repairs legacy resumes.
		params["modelProvider"] = json.RawMessage(`"openai"`)
	}
	encodedParams, err := json.Marshal(params)
	if err != nil {
		return line
	}
	msg["params"] = encodedParams
	encoded, err := json.Marshal(msg)
	if err != nil {
		return line
	}
	if bytes.HasSuffix(line, []byte("\r\n")) {
		return append(encoded, '\r', '\n')
	}
	if bytes.HasSuffix(line, []byte("\n")) {
		return append(encoded, '\n')
	}
	return encoded
}

func forwardDesktopInput(input io.Reader, output io.WriteCloser) error {
	defer output.Close()
	reader := bufio.NewReaderSize(input, 64<<10)
	for {
		var line bytes.Buffer
		for {
			part, err := reader.ReadSlice('\n')
			_, _ = line.Write(part)
			if err == bufio.ErrBufferFull {
				continue
			}
			if line.Len() > 0 {
				if _, writeErr := output.Write(transformDesktopLine(line.Bytes())); writeErr != nil {
					return writeErr
				}
			}
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return err
			}
			break
		}
	}
}

func desktopSignal(cmd *exec.Cmd, sig syscall.Signal) {
	if cmd.Process != nil {
		if err := syscall.Kill(-cmd.Process.Pid, sig); err != nil {
			_ = cmd.Process.Signal(sig)
		}
	}
}

func desktopExitCode(err error) int {
	if err == nil {
		return 0
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			return 128 + int(status.Signal())
		}
		return exit.ExitCode()
	}
	return 127
}

func runDesktopAdapter(connectionPath string, args []string) int {
	c, err := readDesktopConnection(connectionPath)
	if err != nil {
		_, _ = io.WriteString(os.Stderr, "desktop adapter: invalid connection\n")
		return 78
	}
	index := desktopAppServerIndex(args)
	endpoint := c.Endpoint
	if index >= 0 {
		gateway, localEndpoint, err := startDesktopGateway(c, os.Environ())
		if err != nil {
			_, _ = io.WriteString(os.Stderr, "desktop adapter: local gateway unavailable\n")
			return 78
		}
		defer gateway.Close()
		endpoint = localEndpoint
	}
	cmd := exec.Command(c.CodexExecutable, desktopArgs(args, index, endpoint)...)
	cmd.Env = desktopEnvironment(os.Environ(), c.CodexExecutable)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var childInput io.WriteCloser
	if index >= 0 {
		childInput, err = cmd.StdinPipe()
	} else {
		cmd.Stdin = os.Stdin
	}
	if err != nil || cmd.Start() != nil {
		_, _ = io.WriteString(os.Stderr, "desktop adapter: backend start failed\n")
		return 127
	}
	inputDone := make(chan error, 1)
	if childInput != nil {
		go func() { inputDone <- forwardDesktopInput(os.Stdin, childInput) }()
	}
	childDone := make(chan error, 1)
	go func() { childDone <- cmd.Wait() }()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)
	var timer *time.Timer
	var timeout <-chan time.Time
	phase := 0
	for {
		select {
		case err := <-childDone:
			if timer != nil {
				timer.Stop()
			}
			if childInput != nil {
				_ = os.Stdin.Close() // release a reader if Desktop left its pipe open
			}
			return desktopExitCode(err)
		case <-inputDone:
			if phase == 0 {
				phase = 1
				timer = time.NewTimer(3 * time.Second)
				timeout = timer.C
			}
		case sig := <-signals:
			if s, ok := sig.(syscall.Signal); ok {
				desktopSignal(cmd, s)
			}
			if phase == 0 {
				phase = 2
				timer = time.NewTimer(3 * time.Second)
				timeout = timer.C
			}
		case <-timeout:
			if phase == 1 {
				desktopSignal(cmd, syscall.SIGTERM)
				phase = 2
				timer.Reset(2 * time.Second)
			} else {
				desktopSignal(cmd, syscall.SIGKILL)
				timeout = nil
			}
		}
	}
}
