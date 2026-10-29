//go:build windows

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"golang.org/x/sys/windows"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"
)

const desktopConnectionLimit = 16 << 10
const desktopBridgeArgument = "--aigoodbro-desktop-bridge"

type desktopConnection struct {
	SchemaVersion    int    `json:"schemaVersion"`
	Endpoint         string `json:"endpoint"`
	ClientKey        string `json:"clientKey"`
	RunID            string `json:"runID"`
	CodexExecutable  string `json:"codexExecutable"`
	NetworkProxy     string `json:"networkProxy,omitempty"`
	EvidenceEndpoint string `json:"evidenceEndpoint"`
	EvidenceKey      string `json:"evidenceKey"`
	WriterID         string `json:"writerID"`
}
type desktopConnectionContext struct{}

func desktopEvidenceRun(expected desktopEvidenceConfig) (string, error) {
	c, err := readDesktopConnection(os.Getenv("AIGOODBRO_PROXY_CONNECTION_FILE"))
	if err != nil || c.WriterID != expected.WriterID || c.EvidenceEndpoint != expected.Address || c.EvidenceKey != expected.Key {
		return "", errors.New("desktop_connection_changed")
	}
	return c.RunID, nil
}
func desktopCurrentConnection(previous desktopConnection) (desktopConnection, error) {
	path := os.Getenv("AIGOODBRO_PROXY_CONNECTION_FILE")
	current, err := readDesktopConnection(path)
	if err != nil || current.WriterID != previous.WriterID || current.EvidenceEndpoint != previous.EvidenceEndpoint || current.EvidenceKey != previous.EvidenceKey || current.CodexExecutable != previous.CodexExecutable {
		return desktopConnection{}, errors.New("desktop_connection_changed")
	}
	return current, nil
}
func desktopRequestConnection(ctx context.Context, c desktopConnection) desktopConnection {
	if current, ok := ctx.Value(desktopConnectionContext{}).(desktopConnection); ok {
		return current
	}
	return c
}

func readDesktopConnection(path string) (desktopConnection, error) {
	var c desktopConnection
	bad := errors.New("invalid desktop connection")
	if err := privateDirectory(filepath.Dir(path), false); err != nil {
		return c, bad
	}
	f, err := desktopOpenFile(path)
	if err != nil {
		return c, bad
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > desktopConnectionLimit {
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
	if _, err = parseNetworkProxy(c.NetworkProxy); err != nil {
		return desktopConnection{}, bad
	}
	if !identifier.MatchString(c.WriterID) || !desktopCleanKey(c.EvidenceKey) || !strings.HasPrefix(c.EvidenceEndpoint, "tcp:127.0.0.1:") {
		return desktopConnection{}, bad
	}
	if err = windowsPath(c.CodexExecutable, false); err != nil {
		return desktopConnection{}, bad
	}
	exe, err := os.Stat(c.CodexExecutable)
	selfPath, selfErr := os.Executable()
	self, selfStatErr := os.Stat(selfPath)
	if err != nil || selfErr != nil || selfStatErr != nil || !exe.Mode().IsRegular() || os.SameFile(exe, self) {
		return desktopConnection{}, bad
	}
	return c, nil
}

// Windows has no exec replacement. Keep the real backend's inherited stdio
// and its own child handle. A private Job Object owns backend descendants.
// No shell, global configuration or token file is modified.
func runDesktopAdapter(connectionPath string, args []string) int {
	c, err := readDesktopConnection(connectionPath)
	if err != nil {
		_, _ = io.WriteString(os.Stderr, "desktop adapter: invalid connection\n")
		return 78
	}
	index := desktopAppServerIndex(args)
	endpoint := c.Endpoint
	var closeGateway func()
	if index >= 0 {
		gateway, localEndpoint, err := startDesktopGateway(c, os.Environ())
		if err != nil {
			_, _ = io.WriteString(os.Stderr, "desktop adapter: local gateway unavailable\n")
			return 78
		}
		endpoint = localEndpoint
		closeGateway = func() { _ = gateway.Close() }
		defer closeGateway()
	}
	command := exec.Command(c.CodexExecutable, desktopArgs(args, index, endpoint)...)
	command.Env = desktopEnvironment(os.Environ(), c.CodexExecutable)
	command.Stderr = os.Stderr
	if index < 0 {
		command.Stdin, command.Stdout = os.Stdin, os.Stdout
		if err := command.Start(); err != nil {
			return 127
		}
		closeJob, err := ownWindowsBackend(command.Process)
		if err != nil {
			_ = command.Process.Kill()
			_ = command.Wait()
			return 127
		}
		defer closeJob()
		if err := command.Wait(); err != nil {
			if exit, ok := err.(*exec.ExitError); ok {
				return exit.ExitCode()
			}
			return 127
		}
		return 0
	}
	input, err := command.StdinPipe()
	if err != nil {
		return 127
	}
	output, err := command.StdoutPipe()
	if err != nil {
		input.Close()
		return 127
	}
	if err = command.Start(); err != nil {
		input.Close()
		output.Close()
		return 127
	}
	defer input.Close()
	defer output.Close()
	closeJob, err := ownWindowsBackend(command.Process)
	if err != nil {
		_ = command.Process.Kill()
		_ = command.Wait()
		return 127
	}
	defer closeJob()
	rpc := &desktopRPCBridge{backend: input, client: os.Stdout}
	defer rpc.close()
	evidence := newDesktopEvidence(desktopEvidenceConfig{Address: c.EvidenceEndpoint, Key: c.EvidenceKey, WriterID: c.WriterID, RunID: c.RunID}, os.Getenv("CODEX_HOME"), rpc.writeBackend)
	evidence.start()
	defer evidence.close()
	inputDone := make(chan error, 1)
	outputDone := make(chan error, 1)
	backendDone := make(chan error, 1)
	go func() {
		defer input.Close()
		inputDone <- forwardDesktopLines(os.Stdin, func(line []byte) error {
			evidence.fromClient(line)
			err := rpc.fromClient(line)
			evidence.afterClient(line, err)
			return err
		})
	}()
	go func() {
		outputDone <- forwardDesktopLines(output, func(line []byte) error {
			if evidence.fromBackend(line) {
				return nil
			}
			return rpc.fromBackend(line)
		})
	}()
	// Wait on the held process without Cmd.Wait closing stdout before the RPC
	// reader drains its final buffered lines. No os/exec copying goroutines are
	// used here: stdin/stdout are explicit pipes and stderr is an inherited file.
	go func() {
		state, err := command.Process.Wait()
		if err == nil && !state.Success() {
			err = &exec.ExitError{ProcessState: state}
		}
		backendDone <- err
	}()
	var deadline <-chan time.Time
	var timer *time.Timer
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	for {
		select {
		case err := <-backendDone:
			closeJob()
			if outputDone != nil {
				select {
				case <-outputDone:
				case <-time.After(2 * time.Second):
					_ = output.Close()
				}
			}
			if err != nil {
				if exit, ok := err.(*exec.ExitError); ok {
					return exit.ExitCode()
				}
				return 127
			}
			return 0
		case <-inputDone:
			inputDone = nil
			timer = time.NewTimer(3 * time.Second)
			deadline = timer.C
		case <-outputDone:
			outputDone = nil
		case <-deadline:
			closeJob()
			_ = command.Process.Kill()
			deadline = nil
		}
	}
}

// The POSIX sibling bridge entry is never used by the Windows adapter.
func runDesktopBridge(string) int { return 78 }

func ownWindowsBackend(process *os.Process) (func(), error) {
	job, err := attachWindowsBackend(process)
	if err != nil {
		return nil, err
	}
	return job.close, nil
}

type windowsBackendJob struct {
	handle windows.Handle
	once   sync.Once
}

func (job *windowsBackendJob) close() {
	job.once.Do(func() { _ = windows.CloseHandle(job.handle) })
}

func attachWindowsBackend(process *os.Process) (*windowsBackendJob, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, err
	}
	owned := &windowsBackendJob{handle: job}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		owned.close()
		return nil, err
	}
	var assignErr error
	// Go 1.26 pins the process handle for this callback. No PID lookup can
	// accidentally attach a reused unrelated PID to a kill-on-close job.
	err = process.WithHandle(func(handle uintptr) { assignErr = windows.AssignProcessToJobObject(job, windows.Handle(handle)) })
	if err != nil {
		owned.close()
		return nil, err
	}
	if assignErr != nil {
		owned.close()
		return nil, assignErr
	}
	return owned, nil
}
