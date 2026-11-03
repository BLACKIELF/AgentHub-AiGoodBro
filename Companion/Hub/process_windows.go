//go:build windows

package main

import (
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
	_ "time/tzdata"
	"unsafe"
)

type ownedProcess struct {
	mu     sync.Mutex
	job    windows.Handle
	closed bool
	empty  bool
}

type jobAccounting struct {
	TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime int64
	TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses     uint32
}

func startOwnedCommand(cmd *exec.Cmd) (*ownedProcess, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, err
	}
	owned := &ownedProcess{job: job}
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		releaseOwnedProcess(owned)
		return nil, err
	}
	// No breakaway flags: descendants stay in this owned nested Job. Suspension
	// closes the race between CreateProcess and assignment before any user code.
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_SUSPENDED | windows.CREATE_NO_WINDOW, HideWindow: true}
	if err := cmd.Start(); err != nil {
		releaseOwnedProcess(owned)
		return nil, err
	}
	failed := func(err error) (*ownedProcess, error) {
		cmd.Process.Kill()
		releaseOwnedProcess(owned)
		cmd.Wait()
		return nil, err
	}
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(cmd.Process.Pid))
	if err != nil {
		return failed(err)
	}
	defer windows.CloseHandle(process)
	if err := windows.AssignProcessToJobObject(job, process); err != nil {
		return failed(err)
	}
	if err := resumeOwnedPrimaryThread(uint32(cmd.Process.Pid)); err != nil {
		return failed(err)
	}
	return owned, nil
}
func resumeOwnedPrimaryThread(pid uint32) error {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.ThreadEntry32{Size: uint32(unsafe.Sizeof(windows.ThreadEntry32{}))}
	var threadID uint32
	for err = windows.Thread32First(snapshot, &entry); err == nil; err = windows.Thread32Next(snapshot, &entry) {
		if entry.OwnerProcessID == pid {
			if threadID != 0 {
				return fmt.Errorf("suspended_thread_ambiguous")
			}
			threadID = entry.ThreadID
		}
	}
	if err != windows.ERROR_NO_MORE_FILES || threadID == 0 {
		return fmt.Errorf("suspended_thread_missing")
	}
	thread, err := windows.OpenThread(windows.THREAD_SUSPEND_RESUME|windows.THREAD_QUERY_LIMITED_INFORMATION, false, threadID)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(thread)
	// The suspended process handle remains open throughout. Verify thread ownership
	// again after opening it so a recycled thread ID cannot resume another process.
	owner, _, callErr := windows.NewLazySystemDLL("kernel32.dll").NewProc("GetProcessIdOfThread").Call(uintptr(thread))
	if uint32(owner) != pid {
		return fmt.Errorf("thread_identity: %w", callErr)
	}
	previous, err := windows.ResumeThread(thread)
	if err != nil || previous != 1 {
		return fmt.Errorf("thread_resume")
	}
	return nil
}
func (owned *ownedProcess) isEmpty() (bool, error) {
	if owned == nil {
		return false, fmt.Errorf("job_missing")
	}
	owned.mu.Lock()
	defer owned.mu.Unlock()
	if owned.closed {
		return owned.empty, nil
	}
	var accounting jobAccounting
	if err := windows.QueryInformationJobObject(owned.job, windows.JobObjectBasicAccountingInformation, uintptr(unsafe.Pointer(&accounting)), uint32(unsafe.Sizeof(accounting)), nil); err != nil {
		return false, err
	}
	owned.empty = accounting.ActiveProcesses == 0
	return owned.empty, nil
}
func waitOwnedGone(owned *ownedProcess, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for {
		empty, err := owned.isEmpty()
		if err == nil && empty {
			return true
		}
		if !time.Now().Before(deadline) {
			return false
		}
		time.Sleep(25 * time.Millisecond)
	}
}
func releaseOwnedProcess(owned *ownedProcess) {
	if owned == nil {
		return
	}
	owned.mu.Lock()
	defer owned.mu.Unlock()
	if owned.closed {
		return
	}
	windows.CloseHandle(owned.job)
	owned.closed = true
}

func retainsUncertainOwnedProcess() bool { return true }
func ownedResolutionReady(handle *processHandle) bool {
	if handle == nil || handle.owned == nil {
		return false
	}
	empty, err := handle.owned.isEmpty()
	return err == nil && empty
}
func shutdownCompletions(handle *processHandle) []<-chan struct{} {
	return []<-chan struct{}{handle.done, handle.stopDone}
}
func stopHandle(handle *processHandle) bool {
	handle.stopOnce.Do(func() {
		if handle.owned != nil {
			handle.owned.mu.Lock()
			if !handle.owned.closed {
				windows.TerminateJobObject(handle.owned.job, 1)
			}
			handle.owned.mu.Unlock()
			handle.groupStopped = waitOwnedGone(handle.owned, 5*time.Second)
		}
		close(handle.stopDone)
	})
	<-handle.stopDone
	return handle.groupStopped
}
func markExitedAndVerify(handle *processHandle) bool {
	handle.exitOnce.Do(func() { close(handle.exitDone) })
	return waitOwnedGone(handle.owned, 250*time.Millisecond)
}
func terminateProcess(handle *processHandle) { _ = stopHandle(handle) }
func addPlatformEnvironment(allowed map[string]bool) {
	for _, key := range []string{"SYSTEMROOT", "WINDIR", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "PATHEXT", "COMSPEC", "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMDATA"} {
		allowed[key] = true
	}
}
func platformEnvironmentKey(key string) string { return strings.ToUpper(key) }
func shutdownSignals() []os.Signal             { return []os.Signal{os.Interrupt} }
func openCodexDesktopThread(threadID string) error {
	if !canonicalThreadIDPattern.MatchString(threadID) {
		return errInvalid
	}
	uri, err := windows.UTF16PtrFromString("codex://threads/" + threadID)
	if err != nil {
		return err
	}
	verb, _ := windows.UTF16PtrFromString("open")
	return windows.ShellExecute(0, verb, uri, nil, nil, windows.SW_SHOWNORMAL)
}
