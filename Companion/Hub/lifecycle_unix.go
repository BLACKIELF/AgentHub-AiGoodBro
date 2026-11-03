//go:build !windows

package main

import (
	"os"
	"os/exec"
	"syscall"
	"time"
)

type ownedProcess struct{}

func startOwnedCommand(cmd *exec.Cmd) (*ownedProcess, error) {
	configureProcessGroup(cmd)
	return nil, cmd.Start()
}
func releaseOwnedProcess(_ *ownedProcess)        {}
func retainsUncertainOwnedProcess() bool         { return false }
func ownedResolutionReady(_ *processHandle) bool { return false }
func shutdownCompletions(handle *processHandle) []<-chan struct{} {
	return []<-chan struct{}{handle.done}
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

func addPlatformEnvironment(_ map[string]bool) {}
func platformEnvironmentKey(key string) string { return key }
func shutdownSignals() []os.Signal             { return []os.Signal{os.Interrupt, syscall.SIGTERM} }
