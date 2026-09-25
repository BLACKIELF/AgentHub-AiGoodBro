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
Write-Output 'PASS: native window selection (cold start, PID, visibility, owner, class, ambiguity and wait-loop wiring)'
