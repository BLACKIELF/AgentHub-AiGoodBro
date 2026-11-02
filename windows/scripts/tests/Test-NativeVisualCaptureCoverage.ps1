$ErrorActionPreference = 'Stop'

function Assert-True {
  param([bool] $Condition, [string] $Message)
  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Sequence {
  param([object[]] $Actual, [object[]] $Expected, [string] $Message)
  $actualJson = ConvertTo-Json @($Actual) -Compress
  $expectedJson = ConvertTo-Json @($Expected) -Compress
  if ($actualJson -ne $expectedJson) {
    throw "$Message Expected $expectedJson but received $actualJson."
  }
}

function Protect-WrapperLog {
  param([string] $Path, [string[]] $KnownPaths)

  $contents = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  foreach ($knownPath in $KnownPaths) {
    if (-not [string]::IsNullOrWhiteSpace($knownPath)) {
      $contents = [System.Text.RegularExpressions.Regex]::Replace(
        $contents,
        [System.Text.RegularExpressions.Regex]::Escape($knownPath),
        '<task-path>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
      )
    }
  }
  [System.IO.File]::WriteAllText($Path, $contents, [System.Text.UTF8Encoding]::new($false))
}

if (-not ('NativeVisualCaptureJobRunner' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Diagnostics;

public sealed class NativeVisualCaptureJobResult
{
    public int ProcessId { get; set; }
    public int ExitCode { get; set; }
    public bool TimedOut { get; set; }
    public bool ActiveProcessCountConfirmed { get; set; }
    public uint ActiveProcesses { get; set; }
    public bool UnexpectedDescendantsTerminated { get; set; }
    public long ElapsedMilliseconds { get; set; }
}

public static class NativeVisualCaptureJobRunner
{
    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint CREATE_NO_WINDOW = 0x08000000;
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const uint STARTF_USESHOWWINDOW = 0x00000001;
    private const uint STARTF_USESTDHANDLES = 0x00000100;
    private const ushort SW_HIDE = 0;
    private const int PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x00020002;
    private const int JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9;
    private const int JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION = 1;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;
    private const uint WAIT_FAILED = 0xFFFFFFFF;
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint CREATE_NEW = 1;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;

    private static readonly object RetainedLock = new object();
    private static readonly List<IntPtr[]> RetainedHandles = new List<IntPtr[]>();

    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public uint cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
    {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFileW(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        ref SECURITY_ATTRIBUTES lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr hJob, int JobObjectInfoClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInformation,
        uint cbJobObjectInformationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(
        IntPtr hJob, int JobObjectInfoClass,
        out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION lpJobObjectInformation,
        uint cbJobObjectInformationLength, IntPtr lpReturnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr lpAttributeList, int dwAttributeCount, uint dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute,
        IntPtr lpValue, UIntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(
        string lpApplicationName, StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
        uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr hThread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    private static IntPtr CreateInheritableLog(string path)
    {
        SECURITY_ATTRIBUTES security = new SECURITY_ATTRIBUTES();
        security.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
        security.bInheritHandle = true;
        IntPtr handle = CreateFileW(
            path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
            ref security, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (handle == new IntPtr(-1))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create an owned wrapper log.");
        return handle;
    }

    private static IntPtr CreateInheritableNullInput()
    {
        SECURITY_ATTRIBUTES security = new SECURITY_ATTRIBUTES();
        security.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
        security.bInheritHandle = true;
        IntPtr handle = CreateFileW(
            "NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
            ref security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (handle == new IntPtr(-1))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the null standard-input handle.");
        return handle;
    }

    private static string JsonString(string value)
    {
        if (value == null) return "null";
        return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"")
            .Replace("\r", "\\r").Replace("\n", "\\n") + "\"";
    }

    private static void WriteReceipt(
        string path, string state, string startedUtc, int processId,
        int timeoutMilliseconds, uint? activeProcesses, bool activeConfirmed,
        int? exitCode, string stdoutPath, string stderrPath)
    {
        string temporaryPath = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        string json = "{\r\n" +
            "  \"schema_version\": 1,\r\n" +
            "  \"state\": " + JsonString(state) + ",\r\n" +
            "  \"started_utc\": " + JsonString(startedUtc) + ",\r\n" +
            "  \"updated_utc\": " + JsonString(DateTime.UtcNow.ToString("o")) + ",\r\n" +
            "  \"job_scope\": \"owned_anonymous\",\r\n" +
            "  \"process_id\": " + (processId > 0 ? processId.ToString() : "null") + ",\r\n" +
            "  \"timeout_ms\": " + timeoutMilliseconds.ToString() + ",\r\n" +
            "  \"active_processes\": " + (activeProcesses.HasValue ? activeProcesses.Value.ToString() : "null") + ",\r\n" +
            "  \"active_processes_confirmed\": " + (activeConfirmed ? "true" : "false") + ",\r\n" +
            "  \"exit_code\": " + (exitCode.HasValue ? exitCode.Value.ToString() : "null") + ",\r\n" +
            "  \"stdout_log\": " + JsonString(Path.GetFileName(stdoutPath)) + ",\r\n" +
            "  \"stderr_log\": " + JsonString(Path.GetFileName(stderrPath)) + "\r\n" +
            "}\r\n";
        try
        {
            File.WriteAllText(temporaryPath, json, new UTF8Encoding(false));
            if (File.Exists(path)) File.Replace(temporaryPath, path, null);
            else File.Move(temporaryPath, path);
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    private static bool TryGetActiveProcesses(IntPtr job, out uint active, out int error)
    {
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting = new JOBOBJECT_BASIC_ACCOUNTING_INFORMATION();
        if (!QueryInformationJobObject(
            job, JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION, out accounting,
            (uint)Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)), IntPtr.Zero))
        {
            active = 0;
            error = Marshal.GetLastWin32Error();
            return false;
        }
        active = accounting.ActiveProcesses;
        error = 0;
        return true;
    }

    private static bool WaitForJobEmpty(
        IntPtr job, int timeoutMilliseconds, out uint active, out int queryError)
    {
        Stopwatch timer = Stopwatch.StartNew();
        do
        {
            if (!TryGetActiveProcesses(job, out active, out queryError)) return false;
            if (active == 0) return true;
            int remaining = timeoutMilliseconds - (int)timer.ElapsedMilliseconds;
            if (remaining <= 0) return false;
            Thread.Sleep(Math.Min(100, remaining));
        } while (timer.ElapsedMilliseconds < timeoutMilliseconds);
        active = 0;
        queryError = 0;
        return false;
    }

    private static bool WaitForProcessExit(IntPtr process, int timeoutMilliseconds)
    {
        uint wait = WaitForSingleObject(process, (uint)timeoutMilliseconds);
        if (wait == WAIT_FAILED)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not wait for the capture PowerShell process.");
        return wait == WAIT_OBJECT_0;
    }

    private static void CloseIfValid(ref IntPtr handle)
    {
        if (handle != IntPtr.Zero && handle != new IntPtr(-1))
        {
            CloseHandle(handle);
            handle = IntPtr.Zero;
        }
    }

    private static void RetainForInspection(params IntPtr[] handles)
    {
        lock (RetainedLock) RetainedHandles.Add(handles);
    }

    public static NativeVisualCaptureJobResult Run(
        string executable, string commandLine, string workingDirectory,
        string stdoutPath, string stderrPath, string receiptPath,
        int timeoutMilliseconds)
    {
        if (timeoutMilliseconds < 1 || timeoutMilliseconds > 240000)
            throw new ArgumentOutOfRangeException("timeoutMilliseconds");

        string startedUtc = DateTime.UtcNow.ToString("o");
        IntPtr job = IntPtr.Zero;
        IntPtr process = IntPtr.Zero;
        IntPtr thread = IntPtr.Zero;
        IntPtr stdout = IntPtr.Zero;
        IntPtr stderr = IntPtr.Zero;
        IntPtr stdin = IntPtr.Zero;
        IntPtr attributeList = IntPtr.Zero;
        IntPtr handleList = IntPtr.Zero;
        bool attributesInitialized = false;
        bool processAssigned = false;
        bool retainHandles = false;
        int processId = 0;
        int exitCode = -1;
        int queryError = 0;
        uint rawExitCode = 0;
        uint activeProcesses = 0;
        bool activeConfirmed = false;
        Stopwatch elapsed = Stopwatch.StartNew();

        WriteReceipt(receiptPath, "prepared", startedUtc, 0, timeoutMilliseconds,
            null, false, null, stdoutPath, stderrPath);
        try
        {
            stdout = CreateInheritableLog(stdoutPath);
            stderr = CreateInheritableLog(stderrPath);
            stdin = CreateInheritableNullInput();

            job = CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the owned job object.");
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if (!SetInformationJobObject(
                job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, ref limits,
                (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not set KILL_ON_JOB_CLOSE.");

            IntPtr attributeBytes = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeBytes);
            if (attributeBytes == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not size the child handle whitelist.");
            attributeList = Marshal.AllocHGlobal(attributeBytes);
            if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeBytes))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not initialize the child handle whitelist.");
            attributesInitialized = true;

            handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
            Marshal.WriteIntPtr(handleList, 0, stdin);
            Marshal.WriteIntPtr(handleList, IntPtr.Size, stdout);
            Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, stderr);
            if (!UpdateProcThreadAttribute(
                attributeList, 0, new IntPtr(PROC_THREAD_ATTRIBUTE_HANDLE_LIST),
                handleList, new UIntPtr((uint)(IntPtr.Size * 3)), IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not apply the explicit child handle whitelist.");

            STARTUPINFOEX startup = new STARTUPINFOEX();
            startup.StartupInfo.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFOEX));
            startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
            startup.StartupInfo.wShowWindow = SW_HIDE;
            startup.StartupInfo.hStdInput = stdin;
            startup.StartupInfo.hStdOutput = stdout;
            startup.StartupInfo.hStdError = stderr;
            startup.lpAttributeList = attributeList;
            PROCESS_INFORMATION information;
            if (!CreateProcessW(
                executable, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero,
                true, CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW,
                IntPtr.Zero, workingDirectory, ref startup, out information))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the suspended capture PowerShell process.");

            process = information.hProcess;
            thread = information.hThread;
            processId = (int)information.dwProcessId;
            WriteReceipt(receiptPath, "created_suspended", startedUtc, processId,
                timeoutMilliseconds, null, false, null, stdoutPath, stderrPath);

            if (!AssignProcessToJobObject(job, process))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not assign the suspended capture process to its job.");
            processAssigned = true;
            WriteReceipt(receiptPath, "assigned", startedUtc, processId,
                timeoutMilliseconds, null, false, null, stdoutPath, stderrPath);

            uint previousSuspendCount = ResumeThread(thread);
            if (previousSuspendCount == WAIT_FAILED)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not resume the assigned capture process.");
            CloseIfValid(ref thread);
            WriteReceipt(receiptPath, "running", startedUtc, processId,
                timeoutMilliseconds, null, false, null, stdoutPath, stderrPath);

            CloseIfValid(ref stdout);
            CloseIfValid(ref stderr);
            CloseIfValid(ref stdin);
            if (attributesInitialized)
            {
                DeleteProcThreadAttributeList(attributeList);
                attributesInitialized = false;
            }
            if (attributeList != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(attributeList);
                attributeList = IntPtr.Zero;
            }
            if (handleList != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(handleList);
                handleList = IntPtr.Zero;
            }

            long remainingBudgetMilliseconds = timeoutMilliseconds - elapsed.ElapsedMilliseconds;
            int remainingWaitMilliseconds = (int)Math.Max(0L, remainingBudgetMilliseconds);
            uint waitResult = WaitForSingleObject(process, (uint)remainingWaitMilliseconds);
            // Setup and child execution share one work budget. Job termination and
            // ActiveProcesses confirmation below use their own bounded cleanup allowance.
            bool timedOut = waitResult == WAIT_TIMEOUT ||
                (waitResult == WAIT_OBJECT_0 && elapsed.ElapsedMilliseconds > timeoutMilliseconds);
            if (waitResult == WAIT_FAILED)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not wait for the bounded capture process.");
            if (waitResult != WAIT_OBJECT_0 && !timedOut)
                throw new InvalidOperationException("The bounded capture wait returned an unknown result.");

            if (timedOut)
            {
                WriteReceipt(receiptPath, "timed_out_terminating", startedUtc, processId,
                    timeoutMilliseconds, null, false, null, stdoutPath, stderrPath);
                if (!TerminateJobObject(job, 124))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Timed out and could not terminate the owned job.");
                bool processExited = WaitForProcessExit(process, 10000);
                activeConfirmed = WaitForJobEmpty(job, 10000, out activeProcesses, out queryError);
                if (!processExited || !activeConfirmed || activeProcesses != 0)
                    throw new InvalidOperationException(
                        "Timed out but could not confirm an empty job; active_processes=" +
                        (activeConfirmed ? activeProcesses.ToString() : "unknown") +
                        "; query_error=" + queryError.ToString() + ".");
                WriteReceipt(receiptPath, "timed_out_confirmed", startedUtc, processId,
                    timeoutMilliseconds, activeProcesses, true, 124, stdoutPath, stderrPath);
            }
            else
            {
                if (!GetExitCodeProcess(process, out rawExitCode))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the capture process exit code.");
                exitCode = unchecked((int)rawExitCode);
                activeConfirmed = WaitForJobEmpty(job, 10000, out activeProcesses, out queryError);
                bool unexpectedDescendantsTerminated = false;
                if (!activeConfirmed || activeProcesses != 0)
                {
                    if (!TerminateJobObject(job, 125))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Capture exited with active job processes and termination failed.");
                    bool processExited = WaitForProcessExit(process, 10000);
                    activeConfirmed = WaitForJobEmpty(job, 10000, out activeProcesses, out queryError);
                    if (!processExited || !activeConfirmed || activeProcesses != 0)
                        throw new InvalidOperationException(
                            "Capture exited but job cleanup could not be confirmed; active_processes=" +
                            (activeConfirmed ? activeProcesses.ToString() : "unknown") +
                            "; query_error=" + queryError.ToString() + ".");
                    unexpectedDescendantsTerminated = true;
                }
                WriteReceipt(receiptPath,
                    unexpectedDescendantsTerminated ? "cleanup_failure" : "completed",
                    startedUtc, processId,
                    timeoutMilliseconds, activeProcesses, activeConfirmed, exitCode,
                    stdoutPath, stderrPath);
                NativeVisualCaptureJobResult completed = new NativeVisualCaptureJobResult();
                completed.ProcessId = processId;
                completed.ExitCode = exitCode;
                completed.TimedOut = false;
                completed.ActiveProcessCountConfirmed = activeConfirmed;
                completed.ActiveProcesses = activeProcesses;
                completed.UnexpectedDescendantsTerminated = unexpectedDescendantsTerminated;
                completed.ElapsedMilliseconds = elapsed.ElapsedMilliseconds;
                return completed;
            }

            NativeVisualCaptureJobResult timedOutResult = new NativeVisualCaptureJobResult();
            timedOutResult.ProcessId = processId;
            timedOutResult.ExitCode = 124;
            timedOutResult.TimedOut = true;
            timedOutResult.ActiveProcessCountConfirmed = activeConfirmed;
            timedOutResult.ActiveProcesses = activeProcesses;
            timedOutResult.UnexpectedDescendantsTerminated = false;
            timedOutResult.ElapsedMilliseconds = elapsed.ElapsedMilliseconds;
            return timedOutResult;
        }
        catch (Exception error)
        {
            bool stoppedAndConfirmed = process == IntPtr.Zero;
            int cleanupError = 0;
            if (process != IntPtr.Zero)
            {
                try
                {
                    if (processAssigned)
                    {
                        bool processExited = WaitForSingleObject(process, 0) == WAIT_OBJECT_0;
                        bool empty = TryGetActiveProcesses(job, out activeProcesses, out cleanupError) && activeProcesses == 0;
                        if (!processExited || !empty)
                        {
                            bool terminateSucceeded = TerminateJobObject(job, 126);
                            processExited = WaitForProcessExit(process, 10000);
                            empty = WaitForJobEmpty(job, 10000, out activeProcesses, out cleanupError) && activeProcesses == 0;
                            stoppedAndConfirmed = terminateSucceeded && processExited && empty;
                        }
                        else stoppedAndConfirmed = true;
                    }
                    else
                    {
                        bool processExited = WaitForSingleObject(process, 0) == WAIT_OBJECT_0;
                        if (!processExited)
                        {
                            TerminateProcess(process, 126);
                            processExited = WaitForProcessExit(process, 10000);
                        }
                        stoppedAndConfirmed = processExited;
                    }
                }
                catch
                {
                    stoppedAndConfirmed = false;
                }
            }

            try
            {
                WriteReceipt(receiptPath, stoppedAndConfirmed ? "failed" : "unconfirmed_retained",
                    startedUtc, processId, timeoutMilliseconds,
                    stoppedAndConfirmed && processAssigned ? (uint?)activeProcesses : null,
                    stoppedAndConfirmed && processAssigned && activeProcesses == 0,
                    null, stdoutPath, stderrPath);
            }
            catch
            {
                stoppedAndConfirmed = false;
            }

            if (!stoppedAndConfirmed)
            {
                retainHandles = true;
                RetainForInspection(job, process, thread, stdout, stderr, stdin);
            }
            string failure = "Native capture job wrapper failed; process_id=" +
                (processId > 0 ? processId.ToString() : "unknown") +
                "; stdout_log=" + Path.GetFileName(stdoutPath) +
                "; stderr_log=" + Path.GetFileName(stderrPath) +
                "; guard_receipt=" + Path.GetFileName(receiptPath) +
                (stoppedAndConfirmed ? "." : "; empty job could not be confirmed, so handles and artifacts were retained.") +
                " Cause: " + error.Message;
            throw new InvalidOperationException(failure, error);
        }
        finally
        {
            if (attributesInitialized && attributeList != IntPtr.Zero)
                DeleteProcThreadAttributeList(attributeList);
            if (!retainHandles)
            {
                CloseIfValid(ref thread);
                CloseIfValid(ref process);
                CloseIfValid(ref job);
                CloseIfValid(ref stdout);
                CloseIfValid(ref stderr);
                CloseIfValid(ref stdin);
            }
            if (attributeList != IntPtr.Zero) Marshal.FreeHGlobal(attributeList);
            if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
}
'@
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$entry = Join-Path $repositoryRoot 'windows\scripts\Capture-NativeVisuals.ps1'
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$runScope = ''
if ($env:GITHUB_RUN_ID -match '^\d+$' -and $env:GITHUB_RUN_ATTEMPT -match '^\d+$') {
  $runScope = $env:GITHUB_RUN_ID + '-' + $env:GITHUB_RUN_ATTEMPT + '-'
}
$outputLeaf = 'coverage-contract-' + $runScope + [guid]::NewGuid().ToString('N')
$outputRoot = Join-Path $repositoryRoot ('.local-artifacts\windows-visual-captures\' + $outputLeaf)
$wrapperLogRoot = Split-Path -Parent $outputRoot
$stdoutLogPath = Join-Path $wrapperLogRoot ($outputLeaf + '.wrapper.stdout.log')
$stderrLogPath = Join-Path $wrapperLogRoot ($outputLeaf + '.wrapper.stderr.log')
$guardReceiptPath = Join-Path $wrapperLogRoot ($outputLeaf + '.job-guard.json')
Assert-True (-not (Test-Path -LiteralPath $outputRoot)) 'Coverage OutputRoot must be new and must not be pre-created for wrapper logs.'
foreach ($sidecarPath in @($stdoutLogPath, $stderrLogPath, $guardReceiptPath)) {
  Assert-True (-not (Test-Path -LiteralPath $sidecarPath)) 'Coverage wrapper sidecar path already exists.'
}
if (-not (Test-Path -LiteralPath $wrapperLogRoot -PathType Container)) {
  New-Item -ItemType Directory -Path $wrapperLogRoot -Force | Out-Null
}
$expectedSurfaces = @('Tasks', 'AI Leadership', 'Usage', 'Projects', 'Skills')
$workspaceScreenshotSourcePath = Join-Path $repositoryRoot 'windows\apps\codexu-tauri\src-tauri\src\commands\workspace_screenshot.rs'
$workspaceScreenshotSource = Get-Content -LiteralPath $workspaceScreenshotSourcePath -Raw -Encoding UTF8
$restoreStart = $workspaceScreenshotSource.IndexOf('let restore_result = restore_guard.restore().await;', [System.StringComparison]::Ordinal)
$restoreCheck = -1
$restoreRecord = -1
$saveStart = -1
$saveGate = -1
$pngWrite = -1
$saveRecord = -1
if ($restoreStart -ge 0) {
  $restoreCheck = $workspaceScreenshotSource.IndexOf('restore_result?;', $restoreStart, [System.StringComparison]::Ordinal)
}
if ($restoreCheck -ge 0) {
  $restoreRecord = $workspaceScreenshotSource.IndexOf('order.record_restore_complete()?;', $restoreCheck, [System.StringComparison]::Ordinal)
}
if ($restoreRecord -ge 0) {
  $saveStart = $workspaceScreenshotSource.IndexOf('let path = choose_save_path(', $restoreRecord, [System.StringComparison]::Ordinal)
}
if ($saveStart -ge 0) {
  $saveGate = $workspaceScreenshotSource.IndexOf('order.require_restore_before_save(path)?;', $saveStart, [System.StringComparison]::Ordinal)
}
if ($saveGate -ge 0) {
  $pngWrite = $workspaceScreenshotSource.IndexOf('.persist(path)', $saveGate, [System.StringComparison]::Ordinal)
}
if ($pngWrite -ge 0) {
  $saveRecord = $workspaceScreenshotSource.IndexOf('order.record_save_complete()?;', $pngWrite, [System.StringComparison]::Ordinal)
}
Assert-True (
  $restoreStart -ge 0 -and $restoreCheck -gt $restoreStart -and
  $restoreRecord -gt $restoreCheck -and $saveStart -gt $restoreRecord -and
  $saveGate -gt $saveStart -and $pngWrite -gt $saveGate -and $saveRecord -gt $pngWrite
) 'Native screenshot source does not order restore completion, guarded PNG write and save evidence.'
Assert-True (
  $workspaceScreenshotSource.Contains('argument == "--codexu-native-capture-background"') -and
  $workspaceScreenshotSource.Contains('std::env::var_os(NATIVE_WORKSPACE_SCREENSHOT_TEST_ENV)') -and
  $workspaceScreenshotSource.Contains('capture_root.join("workspace-full.png")') -and
  $workspaceScreenshotSource.Contains('image_path.with_file_name("workspace-order.txt")')
) 'Native screenshot test fixture or order marker escaped its fixed isolated activation.'

$entryLiteral = "'" + $entry.Replace("'", "''") + "'"
$repositoryRootLiteral = "'" + $repositoryRoot.Replace("'", "''") + "'"
$outputRootLiteral = "'" + $outputRoot.Replace("'", "''") + "'"
$childScript = @"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
`$ErrorActionPreference = 'Continue'
`$projectRootForRedaction = $repositoryRootLiteral
`$outputRootForRedaction = $outputRootLiteral
try {
  & $entryLiteral -SkipBuild -ExerciseWorkspaceScreenshot -OutputRoot `$outputRootForRedaction |
    ForEach-Object {
      `$line = [string]`$_
      `$line = [System.Text.RegularExpressions.Regex]::Replace(
        `$line, [System.Text.RegularExpressions.Regex]::Escape(`$projectRootForRedaction),
        '<project-root>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
      )
      `$line = [System.Text.RegularExpressions.Regex]::Replace(
        `$line, [System.Text.RegularExpressions.Regex]::Escape(`$outputRootForRedaction),
        '<task-output-root>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
      )
      [Console]::Out.WriteLine(`$line)
    }
  exit 0
} catch {
  `$details = `$_.Exception.ToString()
  `$details = [System.Text.RegularExpressions.Regex]::Replace(
    `$details, [System.Text.RegularExpressions.Regex]::Escape(`$projectRootForRedaction),
    '<project-root>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  `$details = [System.Text.RegularExpressions.Regex]::Replace(
    `$details, [System.Text.RegularExpressions.Regex]::Escape(`$outputRootForRedaction),
    '<task-output-root>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  [Console]::Error.WriteLine(`$details)
  exit 1
}
"@
$encodedChildScript = [Convert]::ToBase64String(
  [System.Text.Encoding]::Unicode.GetBytes($childScript)
)
$childCommandLine = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
  $encodedChildScript
$nativeRun = [NativeVisualCaptureJobRunner]::Run(
  $powershell,
  $childCommandLine,
  $repositoryRoot,
  $stdoutLogPath,
  $stderrLogPath,
  $guardReceiptPath,
  180000
)
Protect-WrapperLog -Path $stdoutLogPath -KnownPaths @($repositoryRoot, $outputRoot, $entry, $powershell)
Protect-WrapperLog -Path $stderrLogPath -KnownPaths @($repositoryRoot, $outputRoot, $entry, $powershell)
$stdoutText = Get-Content -LiteralPath $stdoutLogPath -Raw -Encoding UTF8
$stderrText = Get-Content -LiteralPath $stderrLogPath -Raw -Encoding UTF8
$output = @($stdoutText -split '\r?\n') + @($stderrText -split '\r?\n')
$exitCode = [int]$nativeRun.ExitCode
if (
  $nativeRun.TimedOut -or $exitCode -ne 0 -or
  -not $nativeRun.ActiveProcessCountConfirmed -or
  [uint32]$nativeRun.ActiveProcesses -ne 0 -or
  $nativeRun.UnexpectedDescendantsTerminated
) {
  Write-Output "Native wrapper stdout log: $stdoutLogPath"
  Write-Output "Native wrapper stderr log: $stderrLogPath"
  $output | Select-Object -Last 80 | ForEach-Object { "$_" } | Write-Output
}
Assert-True (-not $nativeRun.TimedOut) "Native coverage capture exceeded its 180-second work budget. Logs: $stdoutLogPath ; $stderrLogPath"
Assert-True (
  $nativeRun.ActiveProcessCountConfirmed -and [uint32]$nativeRun.ActiveProcesses -eq 0
) 'Native coverage Job Object did not confirm ActiveProcesses == 0.'
Assert-True (-not $nativeRun.UnexpectedDescendantsTerminated) 'Capture exited with task descendants still in its Job Object.'
Assert-True ($exitCode -eq 0) "Native coverage capture failed with exit code $exitCode. Logs: $stdoutLogPath ; $stderrLogPath"
Assert-True (
  (Test-Path -LiteralPath $stdoutLogPath -PathType Leaf) -and
  (Test-Path -LiteralPath $stderrLogPath -PathType Leaf) -and
  (Test-Path -LiteralPath $guardReceiptPath -PathType Leaf)
) 'Native wrapper did not retain its stdout, stderr and Job Object receipt sidecars.'
$guardReceipt = Get-Content -LiteralPath $guardReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
  $guardReceipt.state -eq 'completed' -and
  $guardReceipt.job_scope -eq 'owned_anonymous' -and
  [int]$guardReceipt.timeout_ms -eq 180000 -and
  [bool]$guardReceipt.active_processes_confirmed -and
  [int]$guardReceipt.active_processes -eq 0
) 'Native wrapper guard receipt did not prove bounded completion and an empty owned job.'

$summaryLine = @(
  $stdoutText -split '\r?\n' | Where-Object { "$_".StartsWith('NATIVE_VISUAL_CAPTURE_COMPLETE=') }
)
Assert-True ($summaryLine.Count -eq 1) "Coverage capture did not emit exactly one completion summary. See $stdoutLogPath and $stderrLogPath."

$manifestPath = Join-Path $outputRoot 'manifest.json'
Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'Coverage capture did not write its manifest.'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($manifest.status -eq 'complete') 'Coverage capture manifest is not complete.'
Assert-True (@($manifest.size_runs).Count -eq 0) 'Coverage capture retained obsolete fixed-size runs.'

$fullscreenRun = $manifest.fullscreen_run
Assert-True ($null -ne $fullscreenRun) 'Coverage capture did not record its fullscreen run.'
Assert-True ($fullscreenRun.status -eq 'complete') 'Fullscreen Overview capture is not complete.'
Assert-True (
  [bool]$manifest.workspace_screenshot_test_enabled -and
  $manifest.workspace_screenshot.status -eq 'saved' -and
  [bool]$manifest.workspace_screenshot.saved_feedback_observed -and
  [bool]$manifest.workspace_screenshot.restore_completed_before_save -and
  [bool]$manifest.workspace_screenshot.fixture_removed_after_restore -and
  [bool]$manifest.workspace_screenshot.fixture_pixel_matched -and
  [int]$manifest.workspace_screenshot.height -ge
    ([int]$manifest.workspace_screenshot.client_height + 700) -and
  [int64]$manifest.workspace_screenshot.bytes -gt 0
) 'Production workspace screenshot command did not capture bounded full-height content and restore the DOM before saving.'
$workspaceScreenshotPath = Join-Path $outputRoot $manifest.workspace_screenshot.file
Assert-True (
  (Test-Path -LiteralPath $workspaceScreenshotPath -PathType Leaf) -and
  (Get-Item -LiteralPath $workspaceScreenshotPath).Length -eq
    [int64]$manifest.workspace_screenshot.bytes
) 'Production workspace screenshot did not write the expected private task-local PNG.'
$workspaceScreenshotOrderPath = Join-Path $outputRoot $manifest.workspace_screenshot.order_file
Assert-True (
  $manifest.workspace_screenshot.order_file -eq 'runtime/fullscreen/workspace-order.txt' -and
  (Test-Path -LiteralPath $workspaceScreenshotOrderPath -PathType Leaf) -and
  (Get-Content -LiteralPath $workspaceScreenshotOrderPath -Raw -Encoding ASCII) -ceq 'restored|saved' -and
  $manifest.workspace_screenshot.restore_save_order -ceq 'restored|saved'
) 'Production workspace screenshot did not record restore completion before the shared PNG save path.'
Assert-True (
  $fullscreenRun.storage_before_onboarding.state_root -eq 'runtime/fullscreen/app-state' -and
  [bool]$fullscreenRun.storage_before_onboarding.cache_isolated -and
  [bool]$fullscreenRun.storage_before_onboarding.codex_isolated -and
  $fullscreenRun.storage_before_onboarding.onboarding_status -eq 'pending' -and
  $fullscreenRun.storage_after_onboarding.state_root -eq 'runtime/fullscreen/app-state' -and
  [bool]$fullscreenRun.storage_after_onboarding.cache_isolated -and
  [bool]$fullscreenRun.storage_after_onboarding.codex_isolated -and
  $fullscreenRun.storage_after_onboarding.onboarding_status -eq 'deferred'
) 'Each capture must independently save Pending then Deferred under its own state and cache root.'
Assert-True (
  [bool]$fullscreenRun.onboarding.observed -and
  [bool]$fullscreenRun.onboarding.defer_invoked -and
  [bool]$fullscreenRun.onboarding.dialog_dismissed
) 'Fresh native capture must observe the first-launch guide and invoke its existing defer action.'
Assert-True (
  [bool]$fullscreenRun.accessibility.document_present -and
  [bool]$fullscreenRun.accessibility.dashboard_tab_present -and
  [bool]$fullscreenRun.accessibility.renderer_present
) 'Native capture must verify a real UIA Document, Dashboard tab and renderer.'
Assert-True ([bool]$fullscreenRun.window.maximized) 'Overview was not captured from a maximized window.'
Assert-True ($fullscreenRun.window.title -ceq 'AiGoodBro') 'The rendered native main window still uses the legacy product title.'
Assert-True (
  $fullscreenRun.window.activation_mode -eq 'non-activating' -and
  $fullscreenRun.window.foreground_policy -eq 'preserve active window' -and
  [bool]$fullscreenRun.window.foreground_preserved -and
  $fullscreenRun.window.z_order_policy -eq 'background'
) 'Fullscreen capture changed the active window or foreground policy.'
Assert-True (
  [bool]$fullscreenRun.window.tool_window -and
  $fullscreenRun.window.taskbar_policy -eq 'excluded' -and
  $fullscreenRun.window.alt_tab_policy -eq 'excluded'
) 'Fullscreen capture did not exclude its tool window from task switching surfaces.'
$fullscreenCaptures = @($fullscreenRun.captures)
$overviewCaptures = @($fullscreenCaptures | Where-Object { $_.surface -eq 'Overview' })
Assert-True ($overviewCaptures.Count -eq 1) 'Fullscreen run did not contain exactly one Overview capture.'
Assert-True (
  (Split-Path -Leaf $overviewCaptures[0].file) -eq 'overview.png' -and
  (Split-Path -Leaf (Split-Path -Parent $overviewCaptures[0].file)) -eq 'fullscreen'
) 'Fullscreen Overview changed its screenshots/fullscreen/overview.png contract.'
Assert-True (
  (Test-Path -LiteralPath $overviewCaptures[0].file -PathType Leaf) -and
  [int64]$overviewCaptures[0].bytes -gt 0
) 'Fullscreen Overview wrote an invalid PNG.'
foreach ($surface in $expectedSurfaces) {
  $captures = @($fullscreenRun.captures | Where-Object { $_.surface -eq $surface })
  Assert-True ($captures.Count -ge 1) "Maximized run did not capture $surface."
  Assert-Sequence `
    @($captures | ForEach-Object { [int]$_.segment }) `
    @(1..$captures.Count) `
    "Maximized $surface segments are not contiguous."
  Assert-True ([bool]$captures[0].is_first) "Maximized $surface did not mark its first segment."
  Assert-True ([bool]$captures[0].panel_start_visible) "Maximized $surface did not cover the panel start."
  Assert-True (
    [int]$captures[0].client_height -gt 0
  ) "Maximized $surface did not record its client height."
  Assert-True (
    [int]$captures[0].panel_top_in_client -le
      [int]([int]$captures[0].client_height * 0.25) -or
    [bool]$captures[0].panel_end_visible
  ) "Maximized $surface did not frame the panel start near the viewport top."
  if ($surface -eq 'Projects') {
    Assert-True (
      $captures.Count -eq 1
    ) 'Maximized Projects did not stop after its first panel viewport.'
    Assert-True (
      $captures[0].coverage_mode -eq 'first panel viewport' -and
      [bool]$captures[0].is_last
    ) 'Maximized Projects did not record its first-viewport contract.'
  } else {
    Assert-True ([bool]$captures[-1].is_last) "Maximized $surface did not mark its final segment."
    Assert-True (
      [bool]$captures[-1].panel_end_visible
    ) "Maximized $surface did not establish panel-end coverage."
  }

  foreach ($capture in $captures) {
    Assert-True (
      (Split-Path -Leaf $capture.file) -match '^[a-z0-9-]+-\d{2}\.png$'
    ) "Maximized $surface used an unnumbered segment file."
    Assert-True (
      (Split-Path -Leaf (Split-Path -Parent $capture.file)) -eq 'fullscreen'
    ) "Maximized $surface capture escaped the fullscreen directory."
    Assert-True (
      (Test-Path -LiteralPath $capture.file -PathType Leaf) -and
      [int64]$capture.bytes -gt 0
    ) "Maximized $surface wrote an invalid segment file."
  }
}

$manifestCaptureCount = @($fullscreenRun.captures).Count

Assert-True (
  [int]$manifest.screenshot_count -eq $manifestCaptureCount
) 'Manifest screenshot_count does not match the recorded capture count.'
Assert-True ($manifest.final_process_cleanup -eq 'confirmed') 'Coverage capture did not confirm process cleanup.'

Write-Output 'PASS: maximized native capture covers Dashboard panels with the Projects first-screen exception'
