#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
  param([bool] $Condition, [string] $Message)
  if (-not $Condition) { throw $Message }
}

$entry = Join-Path $PSScriptRoot '..\Capture-NativeVisuals.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $entry, [ref]$tokens, [ref]$errors
)
Assert-True ($errors.Count -eq 0) 'Capture script must parse before testing.'
$driver = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Initialize-NativeVisualDriver'
}, $true)
Assert-True ($null -ne $driver) 'Production native driver is missing.'
Invoke-Expression $driver.Extent.Text
Initialize-NativeVisualDriver

function Test-Candidate {
  param([uint32] $ProcessId, [bool] $Visible, [IntPtr] $Owner, [string] $ClassName)
  return [NativeVisualCaptureDriver]::IsTaskMainWindowCandidate(
    4242, $ProcessId, $Visible, $Owner, $ClassName
  )
}

# Cold start: the visible Tao message window precedes the hidden real UI.
Assert-True (-not (Test-Candidate 4242 $true 0 'Tao Thread Event Target')) 'Tao message window was accepted.'
Assert-True (-not (Test-Candidate 4242 $false 0 'Tauri Window')) 'Hidden Tauri UI was accepted.'
Assert-True ([NativeVisualCaptureDriver]::SelectUniqueTaskWindow([IntPtr[]]@()) -eq [IntPtr]::Zero) 'Cold start must keep waiting.'
# The same UI becomes visible after startup, without changing foreground.
Assert-True (Test-Candidate 4242 $true 0 'Tauri Window') 'Ready task UI was rejected.'
Assert-True ([NativeVisualCaptureDriver]::SelectUniqueTaskWindow([IntPtr[]]@(123)) -eq [IntPtr]123) 'Wrong ready window selected.'
Assert-True (-not (Test-Candidate 9000 $true 0 'Tauri Window')) 'Another process window was accepted.'
Assert-True (-not (Test-Candidate 4242 $true 456 'Tauri Window')) 'Owned popup was accepted.'
Assert-True (-not (Test-Candidate 4242 $true 0 'Other Window')) 'Unexpected class was accepted.'
$ambiguousRejected = $false
try {
  [NativeVisualCaptureDriver]::SelectUniqueTaskWindow([IntPtr[]]@(123, 456)) | Out-Null
} catch {
  $ambiguousRejected = $_.Exception.ToString().Contains('refusing ambiguous capture')
}
Assert-True $ambiguousRejected 'Multiple eligible windows must fail closed.'

$wait = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Wait-TaskWindow'
}, $true)
Assert-True ($null -ne $wait) 'Production wait loop is missing.'
$source = $wait.Extent.Text
Assert-True (-not $source.Contains('.MainWindowHandle')) 'Wait loop must not use the ambiguous .NET main window cache.'
Assert-True ($source.Contains('FindTaskMainWindow($Process.Id)')) 'Wait loop must use the owned process selector.'
Assert-True ($source.Contains('AddSeconds(60)')) 'Window deadline must not be extended.'
Assert-True ($source.Contains('Assert-ForegroundPreserved')) 'Foreground guard must remain active.'
Assert-True ($source.Contains('$Process.HasExited')) 'Exited application must fail promptly.'

# Exercise EnumWindows with real HWNDs: a visible Tao message window appears
# first while the task UI is still hidden. No focus or on-screen UI is needed.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class NativeWindowSelectionFixture
{
    private delegate IntPtr WindowProcedure(IntPtr h, uint m, IntPtr w, IntPtr l);
    private static readonly WindowProcedure Procedure = DefWindowProc;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WindowClass
    {
        public uint Style;
        public WindowProcedure Procedure;
        public int ClassExtra, WindowExtra;
        public IntPtr Instance, Icon, Cursor, Background;
        public string MenuName, ClassName;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClass(ref WindowClass value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(uint ex, string name, string title,
        uint style, int x, int y, int width, int height, IntPtr parent,
        IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")]
    public static extern bool DestroyWindow(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string name);
    public static IntPtr Create(string className)
    {
        var instance = GetModuleHandle(null);
        var c = new WindowClass { Procedure = Procedure, Instance = instance, ClassName = className };
        if (RegisterClass(ref c) == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        var h = CreateWindowEx(0x08000080, className, "", 0x80000000,
            -30000, -30000, 1, 1, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        if (h == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        return h;
    }
}
'@
$messageWindow = [IntPtr]::Zero
$mainWindow = [IntPtr]::Zero
$foreground = [NativeVisualCaptureDriver]::GetForegroundWindowHandle()
try {
  $messageWindow = [NativeWindowSelectionFixture]::Create('Tao Thread Event Target')
  $mainWindow = [NativeWindowSelectionFixture]::Create('Tauri Window')
  [void][NativeWindowSelectionFixture]::ShowWindow($messageWindow, 4)
  for ($poll = 0; $poll -lt 5; $poll++) {
    Assert-True ([NativeVisualCaptureDriver]::FindTaskMainWindow($PID) -eq [IntPtr]::Zero) 'Live cold start selected the Tao window before the UI appeared.'
    Start-Sleep -Milliseconds 50
  }
  [void][NativeWindowSelectionFixture]::ShowWindow($mainWindow, 4)
  Assert-True ([NativeVisualCaptureDriver]::FindTaskMainWindow($PID) -eq $mainWindow) 'Live selector did not choose the revealed task UI.'
  Assert-True ([NativeVisualCaptureDriver]::GetForegroundWindowHandle() -eq $foreground) 'Window selection fixture changed foreground.'
} finally {
  if ($mainWindow -ne [IntPtr]::Zero) { [void][NativeWindowSelectionFixture]::DestroyWindow($mainWindow) }
  if ($messageWindow -ne [IntPtr]::Zero) { [void][NativeWindowSelectionFixture]::DestroyWindow($messageWindow) }
}
Write-Output 'PASS: native window selection (cold start, PID, visibility, owner, class, ambiguity and wait-loop wiring)'
