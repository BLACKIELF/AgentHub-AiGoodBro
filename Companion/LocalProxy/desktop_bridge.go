package main

import (
	"bufio"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

const desktopBridgeArgument = "--aigoodbro-desktop-bridge"

// Keep the gateway and input transform beside the signed backend, not above it.
func prepareDesktopBridge() (string, func(), error) {
	self, err := os.Executable()
	if err != nil {
		return "", nil, err
	}
	input, output, err := os.Pipe()
	if err != nil {
		return "", nil, err
	}
	defer input.Close()
	defer output.Close()
	backendOutput, backendWriter, err := os.Pipe()
	if err != nil {
		return "", nil, err
	}
	defer backendOutput.Close()
	defer backendWriter.Close()
	ready, readyOutput, err := os.Pipe()
	if err != nil {
		return "", nil, err
	}
	defer ready.Close()
	defer readyOutput.Close()
	cmd := exec.Command(self, desktopBridgeArgument)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.ExtraFiles = []*os.File{readyOutput, output, backendOutput}
	if err := cmd.Start(); err != nil {
		return "", nil, err
	}
	cleanup := func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }
	_ = output.Close()
	_ = readyOutput.Close()
	if err := ready.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		cleanup()
		return "", nil, err
	}
	line, err := bufio.NewReader(io.LimitReader(ready, 256)).ReadString('\n')
	endpoint := strings.TrimSuffix(line, "\n")
	if err != nil || !desktopEndpoint(endpoint) {
		cleanup()
		return "", nil, errors.New("desktop bridge did not become ready")
	}
	if err := syscall.Dup2(int(input.Fd()), int(os.Stdin.Fd())); err != nil {
		cleanup()
		return "", nil, err
	}
	if err := syscall.Dup2(int(backendWriter.Fd()), int(os.Stdout.Fd())); err != nil {
		cleanup()
		return "", nil, err
	}
	return endpoint, cleanup, nil
}

func runDesktopBridge(connectionPath string) int {
	parent := os.Getppid()
	if parent <= 1 {
		return 78
	}
	c, err := readDesktopConnection(connectionPath)
	if err != nil {
		return 78
	}
	gateway, endpoint, err := startDesktopGateway(c, os.Environ())
	if err != nil {
		return 78
	}
	defer gateway.Close()
	ready := os.NewFile(3, "desktop-bridge-ready")
	if _, err := io.WriteString(ready, endpoint+"\n"); err != nil {
		_ = ready.Close()
		return 78
	}
	_ = ready.Close()
	backendInput := os.NewFile(4, "desktop-backend-input")
	backendOutput := os.NewFile(5, "desktop-backend-output")
	defer backendInput.Close()
	defer backendOutput.Close()
	rpc := &desktopRPCBridge{backend: backendInput, client: os.Stdout}
	defer rpc.close()
	inputDone := make(chan error, 1)
	go func() {
		defer backendInput.Close()
		inputDone <- forwardDesktopLines(os.Stdin, rpc.fromClient)
	}()
	outputDone := make(chan error, 1)
	go func() { outputDone <- forwardDesktopLines(backendOutput, rpc.fromBackend) }()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)
	var timer *time.Timer
	var timeout <-chan time.Time
	terminated := false
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	for {
		select {
		case <-ticker.C:
			if os.Getppid() != parent {
				return 0
			}
		case <-signals:
			return 0
		case <-outputDone:
			return 0
		case <-inputDone:
			inputDone = nil
			timer = time.NewTimer(3 * time.Second)
			timeout = timer.C
		case <-timeout:
			if os.Getppid() != parent {
				return 0
			}
			if !terminated {
				_ = syscall.Kill(parent, syscall.SIGTERM)
				terminated = true
				timer.Reset(2 * time.Second)
			} else {
				_ = syscall.Kill(parent, syscall.SIGKILL)
				return 0
			}
		}
	}
}
