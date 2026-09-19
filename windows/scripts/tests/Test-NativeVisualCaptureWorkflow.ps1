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
$windowConfig = Join-Path $repositoryRoot 'windows\apps\codexu-tauri\src-tauri\tauri.conf.json'
$mainSource = Join-Path $repositoryRoot 'windows\apps\codexu-tauri\src-tauri\src\main.rs'
$preflightOutput = Join-Path $repositoryRoot (
  '.local-artifacts\windows-visual-captures\preflight-contract-' + [guid]::NewGuid().ToString('N')
)
$preflightResult = Join-Path $repositoryRoot (
  '.local-artifacts\windows-visual-captures\preflight-result-' +
  [guid]::NewGuid().ToString('N') + '.json'
)
$blockedPreflightResult = Join-Path $repositoryRoot (
  '.local-artifacts\windows-visual-captures\preflight-blocked-' +
  [guid]::NewGuid().ToString('N') + '.json'
)

Assert-True (Test-Path -LiteralPath $entry -PathType Leaf) 'The formal native visual capture entry point is missing.'
Assert-True (Test-Path -LiteralPath $windowConfig -PathType Leaf) 'The Tauri window configuration is missing.'
Assert-True (Test-Path -LiteralPath $mainSource -PathType Leaf) 'The Tauri startup source is missing.'

$tokens = $null
$parseErrors = $null
$entryAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $entry,
  [ref]$tokens,
  [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) 'The native visual capture entry point has PowerShell parse errors.'
function Import-EntryFunction {
  param([string] $Name)
  $definition = @(
    $entryAst.FindAll(
      {
        param($ast)
        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $ast.Name -eq $Name
      },
      $true
    )
  )[0]
  Assert-True ($null -ne $definition) "The $Name function is missing."
  Invoke-Expression $definition.Extent.Text
}

Import-EntryFunction -Name 'Assert-PreflightReady'
Import-EntryFunction -Name 'Get-WindowsSdkRootCandidates'
Import-EntryFunction -Name 'Get-CaptureCompiler'

$sdkFixtureRoot = Join-Path $repositoryRoot (
  '.local-artifacts\windows-visual-captures\sdk-fixture-' + [guid]::NewGuid().ToString('N')
)
$sdkFixtureMetadata = Join-Path $sdkFixtureRoot 'UnionMetadata\10.0.26100.0\Windows.winmd'
New-Item -ItemType Directory -Path (Split-Path -Parent $sdkFixtureMetadata) | Out-Null
Set-Content -LiteralPath $sdkFixtureMetadata -Value 'synthetic metadata' -Encoding UTF8
try {
  $syntheticCompiler = Get-CaptureCompiler -ExplicitWindowsSdkRoot $sdkFixtureRoot
  Assert-True (
    $syntheticCompiler.windows_metadata -eq $sdkFixtureMetadata
  ) 'An explicit Windows SDK root did not resolve its versioned metadata.'
  Assert-True (
    $syntheticCompiler.windows_sdk_source -eq 'parameter'
  ) 'An explicit Windows SDK root did not record its discovery source.'
} finally {
  Remove-Item -LiteralPath $sdkFixtureRoot -Recurse -Force
}

function New-SyntheticPrerequisites {
  return [ordered]@{
    windows = $true
    cargo = $true
    cargo_toolchain = $true
    git = $true
    helper_source = $true
    csharp_compiler = $true
    windows_metadata = $true
    windows_metadata_version = '10.0.26100.0'
    ui_automation = $true
    native_driver = $true
  }
}
$missingCargo = [ordered]@{
  required_rust_toolchain = '1.97.1-x86_64-pc-windows-msvc'
  prerequisites = New-SyntheticPrerequisites
}
$missingCargo.prerequisites.cargo = $false
$missingCargo.prerequisites.cargo_toolchain = $false
try {
  Assert-PreflightReady -Preflight $missingCargo
  throw 'A missing cargo executable passed preflight.'
} catch {
  Assert-True (
    $_.Exception.Message.Contains('cargo was not found in PATH')
  ) 'Missing cargo did not produce an actionable PATH diagnostic.'
  Assert-True (
    -not $_.Exception.Message.Contains('required Rust toolchain')
  ) 'Missing cargo incorrectly reported a second toolchain problem.'
}

$missingToolchain = [ordered]@{
  required_rust_toolchain = '1.97.1-x86_64-pc-windows-msvc'
  prerequisites = New-SyntheticPrerequisites
}
$missingToolchain.prerequisites.cargo_toolchain = $false
try {
  Assert-PreflightReady -Preflight $missingToolchain
  throw 'A missing pinned Rust toolchain passed preflight.'
} catch {
  Assert-True (
    $_.Exception.Message.Contains("required Rust toolchain '1.97.1-x86_64-pc-windows-msvc' is unavailable")
  ) 'Missing pinned toolchain did not name the required version.'
  Assert-True (
    $_.Exception.Message.Contains('rustup toolchain install 1.97.1-x86_64-pc-windows-msvc')
  ) 'Missing pinned toolchain did not include the repair command.'
}

$config = Get-Content -LiteralPath $windowConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$mainWindow = @($config.app.windows | Where-Object { $_.label -eq 'main' })[0]
Assert-True ($null -ne $mainWindow) 'The Tauri main window configuration is missing.'
Assert-True (-not [bool]$mainWindow.visible) 'The main window must be hidden until startup explicitly shows it.'
Assert-True (-not [bool]$mainWindow.focus) 'The main window must not request focus during native capture startup.'
$mainSourceText = Get-Content -LiteralPath $mainSource -Raw -Encoding UTF8
Assert-True (
  $mainSourceText -match '(?s)if background_capture.*?prepare_background_capture_window\(\&window\).*?show_background_capture_window\(\&window\).*?else.*?window\.show\(\).*?window\.set_focus\(\)'
) 'Startup must use the native non-activating show path for capture, while only normal startup requests focus.'
Assert-True (
  $mainSourceText -match '(?s)fn show_background_capture_window.*?SW_SHOWNOACTIVATE.*?HWND_BOTTOM.*?SWP_NOACTIVATE'
) 'Background startup must show the exact HWND with Win32 non-activation flags before the capture workflow can observe it.'
$backgroundBranch = [regex]::Match(
  $mainSourceText,
  '(?s)if background_capture\s*\{.*?\}\s*else'
).Value
Assert-True (
  $backgroundBranch -notmatch 'window\.show\(\)'
) 'Background startup must not call Tauri window.show, because that asynchronous path can activate the window before z-order correction.'

$output = @(
  & $entry `
    -PreflightOnly `
    -OutputRoot $preflightOutput `
    -PreflightResultPath $preflightResult
)

$manifestLine = @($output | Where-Object { "$_".StartsWith('NATIVE_VISUAL_PREFLIGHT=') })
Assert-True ($manifestLine.Count -eq 1) 'Preflight did not emit exactly one machine-readable manifest.'
$manifest = "$($manifestLine[0])".Substring('NATIVE_VISUAL_PREFLIGHT='.Length) | ConvertFrom-Json
$result = Get-Content -LiteralPath $preflightResult -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($result.schema_version -eq 1) 'The preflight result file used the wrong schema version.'
Assert-True ($result.status -eq 'ready') 'The preflight result file did not record readiness.'
Assert-True ([bool]$result.diagnostic_write_performed) 'The preflight result did not record its diagnostic write.'
Assert-True (-not [bool]$result.runtime_writes_performed) 'The preflight result reported runtime writes.'
Assert-True ($result.manifest.output_root -eq $manifest.output_root) 'File and stdout preflight manifests disagree.'

$blockedResultWritten = $false
try {
  & $entry `
    -PreflightOnly `
    -OutputRoot $preflightOutput `
    -PreflightResultPath $blockedPreflightResult `
    -WindowsSdkRoot (Join-Path $sdkFixtureRoot 'missing') | Out-Null
} catch {
  $blockedResultWritten = Test-Path -LiteralPath $blockedPreflightResult -PathType Leaf
}
Assert-True $blockedResultWritten 'A blocked preflight did not publish its diagnostic result file.'
$blockedResult = Get-Content -LiteralPath $blockedPreflightResult -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($blockedResult.status -eq 'blocked') 'A failed preflight did not record blocked status.'
Assert-True (
  "$($blockedResult.error)".Contains('windows_metadata')
) 'A blocked preflight result omitted the missing Windows metadata diagnostic.'

Assert-True ($manifest.capture_engine -eq 'Windows.Graphics.Capture') 'Preflight selected the wrong capture engine.'
Assert-True ($manifest.targeting -eq 'exact HWND') 'Preflight did not declare exact-HWND targeting.'
Assert-Sequence @($manifest.capture_runs) @('fullscreen') 'Preflight capture-run coverage changed.'
Assert-True (@($manifest.client_sizes).Count -eq 0) 'Preflight retained obsolete fixed client-size runs.'
Assert-Sequence @($manifest.surfaces) @('Overview', 'Tasks', 'AI Leadership', 'Usage', 'Projects', 'Skills') 'Preflight surface coverage changed.'
Assert-True (
  $manifest.window_mode -eq 'maximized exact HWND'
) 'Preflight did not require a maximized exact-HWND window for every capture.'
Assert-True (
  $manifest.activation_mode -eq 'non-activating'
) 'Preflight did not require non-activating window presentation.'
Assert-True (
  $manifest.foreground_policy -eq 'preserve active window'
) 'Preflight did not require preserving the active user window.'
Assert-True (
  $manifest.z_order_policy -eq 'background'
) 'Preflight did not require background window layering.'
Assert-True (
  $manifest.startup_window_mode -eq 'hidden until explicitly shown; background activation forbidden'
) 'Preflight did not require hidden startup with explicit background activation protection.'
Assert-True (
  $manifest.capture_argument -eq '--codexu-native-capture-background'
) 'Preflight did not declare the capture-only background argument.'
Assert-True (
  $manifest.taskbar_policy -eq 'excluded'
) 'Preflight did not require taskbar exclusion for capture windows.'
Assert-True (
  $manifest.alt_tab_policy -eq 'excluded'
) 'Preflight did not require Alt-Tab exclusion for capture windows.'
Assert-True (
  $manifest.overview_file -eq 'fullscreen/overview.png'
) 'Preflight changed the fullscreen Overview file contract.'
Assert-True (
  $manifest.surface_capture_mode -eq 'maximized panel viewport sequence'
) 'Preflight did not select maximized panel viewport sequences.'
Assert-True (
  [double]$manifest.segment_overlap_ratio -eq 0.2
) 'Preflight changed the required segment overlap.'
Assert-True (
  [int]$manifest.max_segments_per_surface -eq 12
) 'Preflight changed the bounded segment limit.'
Assert-True (
  $manifest.surface_file_pattern -eq '<surface>-<segment:00>.png'
) 'Preflight changed the segment file contract.'
Assert-True (
  $manifest.projects_capture_mode -eq 'first panel viewport'
) 'Preflight did not limit Projects to its first panel viewport.'
Assert-True ($manifest.app_executable_relative -eq 'windows/target/release/codexu-tauri.exe') 'Preflight selected the wrong release executable.'
Assert-True ($manifest.required_rust_toolchain -eq '1.97.1-x86_64-pc-windows-msvc') 'Preflight selected the wrong required Rust toolchain.'
Assert-True ($manifest.build_command -eq 'cargo +1.97.1-x86_64-pc-windows-msvc tauri build --no-bundle') 'Preflight selected the wrong release build command.'
Assert-True ([bool]$manifest.prerequisites.cargo_toolchain) 'Preflight did not validate the pinned Rust toolchain.'
Assert-True ([bool]$manifest.prerequisites.csharp_compiler) 'Preflight did not locate the C# compiler.'
Assert-True ([bool]$manifest.prerequisites.windows_metadata) 'Preflight did not locate Windows SDK metadata.'
Assert-True (
  "$($manifest.prerequisites.windows_metadata_version)" -match '^\d+\.\d+\.\d+\.\d+$'
) 'Preflight did not select versioned Windows UnionMetadata.'
Assert-True ([bool]$manifest.prerequisites.ui_automation) 'Preflight did not validate UI Automation.'
Assert-True ([bool]$manifest.prerequisites.native_driver) 'Preflight did not load the native sizing and renderer driver.'
Assert-True (-not [bool]$manifest.writes_performed) 'Preflight unexpectedly wrote runtime artifacts.'
Assert-True (-not (Test-Path -LiteralPath $preflightOutput)) 'Preflight created the requested runtime output directory.'

$singleSurfaceOutput = Join-Path $repositoryRoot (
  '.local-artifacts\windows-visual-captures\preflight-single-surface-' +
  [guid]::NewGuid().ToString('N')
)
$singleSurfaceLines = @(
  & $entry `
    -PreflightOnly `
    -Surface 'Skills' `
    -OutputRoot $singleSurfaceOutput
)
$singleSurfaceManifestLine = @(
  $singleSurfaceLines | Where-Object { "$($_)".StartsWith('NATIVE_VISUAL_PREFLIGHT=') }
)
Assert-True (
  $singleSurfaceManifestLine.Count -eq 1
) 'Single-surface preflight did not emit exactly one manifest line.'
$singleSurfaceManifest = "$($singleSurfaceManifestLine[0])".Substring(
  'NATIVE_VISUAL_PREFLIGHT='.Length
) | ConvertFrom-Json
Assert-Sequence `
  @($singleSurfaceManifest.surfaces) `
  @('Skills') `
  'Single-surface preflight selected extra Dashboard surfaces.'
Assert-True (
  $null -eq $singleSurfaceManifest.overview_file
) 'Single-surface preflight retained an unrelated Overview capture.'
Assert-True (
  $singleSurfaceManifest.surface_capture_mode -eq 'maximized first panel viewport'
) 'Single-surface preflight did not select exactly one maximized panel viewport.'
Assert-True (
  -not (Test-Path -LiteralPath $singleSurfaceOutput)
) 'Single-surface preflight created the requested runtime output directory.'

$defaultOutput = @(
  & $entry -PreflightOnly
)
$defaultManifestLine = @(
  $defaultOutput | Where-Object { "$_".StartsWith('NATIVE_VISUAL_PREFLIGHT=') }
)
Assert-True ($defaultManifestLine.Count -eq 1) 'Default preflight did not emit exactly one manifest.'
$defaultManifest = "$($defaultManifestLine[0])".Substring(
  'NATIVE_VISUAL_PREFLIGHT='.Length
) | ConvertFrom-Json
$defaultLeaf = Split-Path -Leaf $defaultManifest.output_root
Assert-True (
  $defaultLeaf -match '^\d{4}-\d{2}-\d{2}-\d{6}-\d{3}-native-workflow$'
) 'The default timestamped output directory name was not literal and stable.'
Assert-True (
  -not (Test-Path -LiteralPath $defaultManifest.output_root)
) 'Default preflight created its proposed runtime output directory.'

$outsideRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'codexu-native-visual-invalid-' + [guid]::NewGuid().ToString('N')
)
$invalidRejected = $false
try {
  & $entry -PreflightOnly -OutputRoot $outsideRoot | Out-Null
} catch {
  $invalidRejected = $_.Exception.Message.Contains(
    'OutputRoot must be a new child of .local-artifacts/windows-visual-captures.'
  )
}
Assert-True $invalidRejected 'An output path outside .local-artifacts was accepted.'
Assert-True (-not (Test-Path -LiteralPath $outsideRoot)) 'The rejected output path was created.'

Remove-Item -LiteralPath $preflightResult -Force
Remove-Item -LiteralPath $blockedPreflightResult -Force

Write-Output 'PASS: native visual capture preflight and local-artifact boundary'
