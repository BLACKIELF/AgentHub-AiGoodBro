#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Version,
    [string] $OutputDirectory,
    [switch] $SkipPackaging,
    [switch] $PlanOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Get-ReleaseReadinessPlan {
    param([string] $Root, [string] $ReleaseVersion, [string] $Output, [string] $Preflight,
        [string] $PowerShell51, [string] $PowerShell7, [bool] $Package)
    $windows = Join-Path $Root 'windows'
    $web = Join-Path $windows 'apps\codexu-tauri\web'
    $plan = [Collections.Generic.List[object]]::new()
    # A default Windows client ships PowerShell 5.1 with the Restricted policy, so
    # every child host must be launched with an explicit process-scoped policy or the
    # release entry point cannot run its own scripts on a freshly installed machine.
    $plan.Add(@{ name = 'native-preflight'; executable = $PowerShell51; directory = $Root; arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'windows\scripts\Capture-NativeVisuals.ps1'), '-PreflightOnly', '-PreflightResultPath', $Preflight) })
    foreach ($hostEntry in @(@{ name = 'ps51'; executable = $PowerShell51 }, @{ name = 'ps7'; executable = $PowerShell7 })) {
        foreach ($test in @('Test-PublicFeedSyntax.ps1', 'Test-NativeWindowSelection.ps1', 'Test-NativeVisualCaptureWorkflow.ps1', 'Test-ReleaseReadiness.ps1')) {
            $plan.Add(@{ name = ($hostEntry.name + ':' + $test); executable = $hostEntry.executable; directory = $Root; arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root ('windows\scripts\tests\' + $test))) })
        }
    }
    $plan.Add(@{ name = 'rust-format'; executable = 'cargo'; directory = $windows; arguments = @('+1.97.1-x86_64-pc-windows-msvc', 'fmt', '--all', '--', '--check') })
    $plan.Add(@{ name = 'rust-tests'; executable = 'cargo'; directory = $windows; arguments = @('+1.97.1-x86_64-pc-windows-msvc', 'test', '--workspace', '--locked') })
    $plan.Add(@{ name = 'web-dependencies'; executable = 'npm.cmd'; directory = $web; arguments = @('ci', '--no-audit', '--no-fund') })
    $plan.Add(@{ name = 'web-tests'; executable = 'npm.cmd'; directory = $web; arguments = @('test') })
    $plan.Add(@{ name = 'web-build'; executable = 'npm.cmd'; directory = $web; arguments = @('run', 'build') })
    # The pinned Playwright CLI reuses the matching browser in its existing cache.
    $plan.Add(@{ name = 'visual-browser'; executable = 'node'; directory = $web; arguments = @('node_modules/@playwright/test/cli.js', 'install', 'chromium') })
    $plan.Add(@{ name = 'visual-baseline'; executable = 'npm.cmd'; directory = $web; arguments = @('run', 'test:visual', '--', '--update-snapshots') })
    $plan.Add(@{ name = 'visual-repeat'; executable = 'npm.cmd'; directory = $web; arguments = @('run', 'test:visual') })
    if ($Package) {
        $plan.Add(@{ name = 'package'; executable = $PowerShell7; directory = $Root; arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $Root 'scripts\build-windows-release.ps1'), '-Version', $ReleaseVersion, '-OutputDirectory', (Join-Path $Output 'packages'), '-SkipValidation') })
    }
    return $plan.ToArray()
}

function Save-ReadinessReport {
    param([Collections.IDictionary] $Report, [string] $Path)
    $writeId = [guid]::NewGuid().ToString('N')
    $temporary = $Path + '.' + $writeId + '.tmp'
    $backup = $Path + '.' + $writeId + '.bak'
    $replaced = $false
    $phase = 'serialize'
    try {
        [IO.File]::WriteAllText($temporary, ($Report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) {
            $phase = 'replace'
            # A PowerShell null can bind to an empty .NET string path. Supply
            # a unique real backup path instead; retain it if replacement fails.
            [IO.File]::Replace($temporary, $Path, $backup)
            $replaced = $true
        } else {
            $phase = 'create'
            [IO.File]::Move($temporary, $Path)
        }
    } catch {
        $cause = $_.Exception.GetBaseException()
        throw ('Readiness report write failed: phase=' + $phase + '; type=' + $cause.GetType().FullName + '; hresult=' + $cause.HResult)
    } finally {
        # These two files are created by this function and are never user data, so
        # remove them through the file APIs: the release entry point must not depend
        # on shell recycle-bin or trash behaviour to retire its own scratch files.
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ($replaced -and [IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
}

function Invoke-ReleaseStep {
    param([Collections.IDictionary] $Step, [Collections.IDictionary] $Report, [string] $ReportPath, [scriptblock] $Runner)
    $record = [ordered]@{ name = $Step.name; tool = [IO.Path]::GetFileName($Step.executable); started_utc = [DateTime]::UtcNow.ToString('o'); finished_utc = $null; status = 'running'; exit_code = $null }
    $Report.steps.Add($record)
    Save-ReadinessReport -Report $Report -Path $ReportPath
    try {
        $code = & $Runner $Step
        if ($code -isnot [int]) { throw 'Runner did not return an actual exit code.' }
        $record.exit_code = $code
        if ($code -ne 0) { throw 'Step returned a failure exit code.' }
        $record.status = 'passed'
    } catch {
        $record.status = 'failed'
        throw ('Release readiness failed at step: ' + $Step.name)
    } finally {
        $record.finished_utc = [DateTime]::UtcNow.ToString('o')
        Save-ReadinessReport -Report $Report -Path $ReportPath
    }
}

function Invoke-ReleasePlan {
    param([object[]] $Plan, [Collections.IDictionary] $Report, [string] $ReportPath, [scriptblock] $Runner)
    foreach ($step in $Plan) { Invoke-ReleaseStep -Step $step -Report $Report -ReportPath $ReportPath -Runner $Runner }
}

function Get-SourceStamp {
    param([string] $Root)
    Push-Location $Root
    try {
        $commit = (& git rev-parse HEAD | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'Git commit unavailable.' }
        $status = (& git status --porcelain=v1 --untracked-files=normal | Out-String)
        if ($LASTEXITCODE -ne 0) { throw 'Git status unavailable.' }
        $diff = (& git diff --binary HEAD -- windows scripts/build-windows-release.ps1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw 'Git diff unavailable.' }
        $untracked = [string]::Join("`n", @(& git ls-files --others --exclude-standard -z -- windows scripts/build-windows-release.ps1))
        if ($LASTEXITCODE -ne 0) { throw 'Git file inventory unavailable.' }
        $untrackedHashes = [Text.StringBuilder]::new()
        foreach ($relative in @($untracked.Split([char]0) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)) {
            $item = Get-Item -LiteralPath (Join-Path $Root $relative) -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Source inventory contains an unsupported link.' }
            $fileHash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            $null = $untrackedHashes.Append($relative).Append('=').Append($fileHash).Append("`n")
        }
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $stamp = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($status + $diff + $untrackedHashes.ToString()))).Replace('-', '').ToLowerInvariant() }
        finally { $hash.Dispose() }
        return [ordered]@{ commit = $commit; dirty = -not [string]::IsNullOrWhiteSpace($status); source_state_sha256 = $stamp }
    } finally { Pop-Location }
}

function Get-ReleasePackageEvidence {
    param([string] $Directory, [string] $ReleaseVersion)
    $manifest = Get-Content -LiteralPath (Join-Path $Directory 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.version -ne $ReleaseVersion -or $manifest.target -ne 'windows-x86_64') { throw 'Package manifest does not match requested version/target.' }
    $expected = @("CodexAccountManagerNext-$ReleaseVersion-windows-x86_64.msi", "CodexAccountManagerNext-$ReleaseVersion-windows-x86_64-setup.exe")
    if (@($manifest.installers).Count -ne 2) { throw 'Expected both installer formats.' }
    $evidence = @()
    foreach ($name in $expected) {
        if ($name -notin @($manifest.installers)) { throw 'Package manifest contains an unexpected installer.' }
        $path = Join-Path $Directory $name
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -le 0 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid release package.' }
        $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $checksum = (Get-Content -LiteralPath ($path + '.sha256') -Raw -Encoding UTF8).Trim()
        if ($checksum -ne "$sha  $name") { throw 'Release package checksum mismatch.' }
        $evidence += [ordered]@{ file = $name; bytes = $item.Length; sha256 = $sha }
    }
    return $evidence
}

$Version = $Version -replace '^v', ''
if ($Version -notmatch '^\d+\.\d+\.\d+([\-+][0-9A-Za-z.-]+)?$') { throw 'Version must be a semantic version.' }
$runId = [guid]::NewGuid().ToString('N')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $repositoryRoot ('.local-artifacts\windows-release-readiness\' + $runId) }
elseif (-not [IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory = Join-Path $repositoryRoot $OutputDirectory }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$preflight = Join-Path $repositoryRoot ('.local-artifacts\windows-visual-captures\readiness-' + $runId + '.json')
if ($PlanOnly) {
    Get-ReleaseReadinessPlan -Root $repositoryRoot -ReleaseVersion $Version -Output $OutputDirectory -Preflight $preflight -PowerShell51 'powershell.exe' -PowerShell7 'pwsh.exe' -Package (-not $SkipPackaging) | ConvertTo-Json -Depth 6
    return
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Choose a new output directory; existing readiness runs are preserved.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$reportPath = Join-Path $OutputDirectory 'report.json'
$report = [ordered]@{
    schema_version = 1; run_id = $runId; version = $Version; status = 'running'
    started_utc = [DateTime]::UtcNow.ToString('o'); finished_utc = $null
    git = $null; source_unchanged = $null; error_code = $null; scope = 'automated_checks_and_packaging'
    powershell_versions = $null
    rust_toolchain = '1.97.1-x86_64-pc-windows-msvc'
    native_preflight_report = '.local-artifacts/windows-visual-captures/readiness-' + $runId + '.json'
    packaging_requested = -not [bool]$SkipPackaging
    steps = [Collections.Generic.List[object]]::new(); packages = @()
    native_runtime = @(
        @{ check = 'interactive-console-and-owned-process-tree'; status = 'not_run'; reason = 'Requires an explicit Windows native session; no login or task is submitted by this script.' },
        @{ check = 'login-switching-and-installed-app-upgrade'; status = 'not_run'; reason = 'No login, identity switching, existing application shutdown, or finished package installation.' },
        @{ check = 'native-window-visual-capture'; status = 'not_run'; reason = 'Only native preflight and synthetic contracts run automatically.' }
    )
}
$oldVisualBrowser = [Environment]::GetEnvironmentVariable('CODEXU_VISUAL_BROWSER', 'Process')
$nativeRunner = {
    param($step)
    Push-Location $step.directory
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        Write-Host ('Running ' + $step.name)
        $executable = $step.executable
        $arguments = [string[]]$step.arguments
        & $executable @arguments | Out-Host
        return [int]$LASTEXITCODE
    } finally { Pop-Location }
}
try {
    Save-ReadinessReport -Report $report -Path $reportPath
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'windows_required' }
    foreach ($command in @('git', 'cargo', 'rustup', 'npm.cmd', 'node', 'powershell.exe', 'pwsh.exe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw ('missing_tool:' + $command) }
    }
    $report.git = Get-SourceStamp -Root $repositoryRoot
    $ps51 = (Get-Command powershell.exe -ErrorAction Stop).Source
    $ps7 = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $version51 = (& $ps51 -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $version51 -notmatch '^5\.1\.') { throw 'powershell51_version_mismatch' }
    $version7 = (& $ps7 -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $version7 -notmatch '^7\.') { throw 'powershell7_version_mismatch' }
    $report.powershell_versions = @{ ps51 = $version51; ps7 = $version7 }
    $plan = @(Get-ReleaseReadinessPlan -Root $repositoryRoot -ReleaseVersion $Version -Output $OutputDirectory -Preflight $preflight -PowerShell51 $ps51 -PowerShell7 $ps7 -Package (-not $SkipPackaging))
    [Environment]::SetEnvironmentVariable('CODEXU_VISUAL_BROWSER', 'chromium', 'Process')
    Invoke-ReleasePlan -Plan $plan -Report $report -ReportPath $reportPath -Runner $nativeRunner
    if (-not $SkipPackaging) { $report.packages = @(Get-ReleasePackageEvidence -Directory (Join-Path $OutputDirectory 'packages') -ReleaseVersion $Version) }
    $after = Get-SourceStamp -Root $repositoryRoot
    $report.source_unchanged = $report.git.commit -eq $after.commit -and $report.git.source_state_sha256 -eq $after.source_state_sha256
    if (-not $report.source_unchanged) { throw 'source_changed_during_validation' }
    $report.status = 'passed'
} catch {
    $report.status = 'failed'
    $failed = @($report.steps | Where-Object { $_.status -eq 'failed' })
    if ($failed.Count -gt 0) { $report.error_code = 'step_failed:' + $failed[-1].name }
    elseif ($_.Exception.Message -match '^(windows_required|missing_tool:[A-Za-z0-9.]+|source_changed_during_validation|powershell51_version_mismatch|powershell7_version_mismatch)$') { $report.error_code = $_.Exception.Message }
    else { $report.error_code = 'readiness_or_artifact_check_failed' }
    throw ('Windows release readiness failed: ' + $report.error_code + '. See report.json for completed steps.')
} finally {
    [Environment]::SetEnvironmentVariable('CODEXU_VISUAL_BROWSER', $oldVisualBrowser, 'Process')
    $report.finished_utc = [DateTime]::UtcNow.ToString('o')
    Save-ReadinessReport -Report $report -Path $reportPath
    Write-Host ('RELEASE_READINESS_REPORT=' + $reportPath)
}
