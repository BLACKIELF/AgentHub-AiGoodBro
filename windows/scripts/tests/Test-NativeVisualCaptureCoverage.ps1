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

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$entry = Join-Path $repositoryRoot 'windows\scripts\Capture-NativeVisuals.ps1'
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$runScope = ''
if ($env:GITHUB_RUN_ID -match '^\d+$' -and $env:GITHUB_RUN_ATTEMPT -match '^\d+$') {
  $runScope = $env:GITHUB_RUN_ID + '-' + $env:GITHUB_RUN_ATTEMPT + '-'
}
$outputRoot = Join-Path $repositoryRoot (
  '.local-artifacts\windows-visual-captures\coverage-contract-' + $runScope +
  [guid]::NewGuid().ToString('N')
)
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

$priorErrorPreference = $ErrorActionPreference
try {
  # PowerShell 5.1 otherwise aborts on the first native stderr line, hiding
  # the capture error and preventing the exit-code assertion below.
  $ErrorActionPreference = 'Continue'
  $output = @(
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $entry `
      -SkipBuild `
      -ExerciseWorkspaceScreenshot `
      -OutputRoot $outputRoot 2>&1
  )
  $exitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $priorErrorPreference
}
if ($exitCode -ne 0) {
  $output | ForEach-Object { "$_" } | Write-Output
}
Assert-True ($exitCode -eq 0) "Native coverage capture failed with exit code $exitCode."

$summaryLine = @(
  $output | Where-Object { "$_".StartsWith('NATIVE_VISUAL_CAPTURE_COMPLETE=') }
)
Assert-True ($summaryLine.Count -eq 1) 'Coverage capture did not emit exactly one completion summary.'

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
