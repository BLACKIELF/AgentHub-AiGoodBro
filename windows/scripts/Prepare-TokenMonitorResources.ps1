#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BuildRoot,
    [switch] $RunNativeTests
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'windows_required' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not [IO.Path]::IsPathRooted($BuildRoot)) { throw 'Choose an absolute task-owned build directory.' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (Test-Path -LiteralPath $BuildRoot) { throw 'Choose a new Token Monitor build directory; previous receipts are preserved.' }
foreach ($tool in @('python', 'cargo')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw ('missing_tool:' + $tool) }
}
function Invoke-StatisticsBuildCommand {
    param([string] $Executable, [string[]] $Arguments, [switch] $RequireTests)
    $commandOutput = @()
    & $Executable @Arguments | Tee-Object -Variable commandOutput | Out-Host
    if ($LASTEXITCODE -ne 0) { throw ('statistics_validation_failed:' + $Executable + ':' + $LASTEXITCODE) }
    if ($RequireTests -and (($commandOutput -join "`n") -notmatch 'test result: ok\. [1-9][0-9]* passed; 0 failed;')) { throw 'statistics_native_test_selection_empty' }
}
$names = @('RUSTUP_TOOLCHAIN', 'TOKEN_MONITOR_TEST_ENGINE', 'TOKEN_MONITOR_TEST_NATIVE', 'TOKEN_MONITOR_TEST_SCANNER_SHA256', 'AIGOODBRO_TM_TEST_RESOURCES', 'AIGOODBRO_TOKEN_MONITOR_RESOURCE_SHA256')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
New-Item -ItemType Directory -Path $BuildRoot | Out-Null
Push-Location $root
try {
    $env:RUSTUP_TOOLCHAIN = '1.97.1-x86_64-pc-windows-msvc'
    $cache = Join-Path $root '.local-artifacts\windows-token-monitor-assets'
    $scanner = Join-Path $BuildRoot 'scanner'
    $staged = Join-Path $BuildRoot 'resources'
    Invoke-StatisticsBuildCommand 'python' @('windows/token-monitor/build_scanner.py', '--output', $scanner, '--cache', $cache, '--target', 'x86_64-pc-windows-msvc', '--target-dir', (Join-Path $root '.local-artifacts\windows-token-monitor-target'), '--download', '--jobs', '2')
    Invoke-StatisticsBuildCommand 'python' @('windows/token-monitor/prepare.py', '--output', $staged, '--cache', $cache, '--scanner', (Join-Path $scanner 'tokscale.exe'), '--scanner-receipt', (Join-Path $scanner 'SCANNER-RECEIPT.json'), '--arch', 'x64', '--download')
    $manifest = Join-Path $staged 'WINDOWS-RESOURCES.json'
    $pin = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($pin -notmatch '^[0-9a-f]{64}$') { throw 'statistics_resource_hash_invalid' }
    $env:AIGOODBRO_TOKEN_MONITOR_RESOURCE_SHA256 = $pin
    $env:TOKEN_MONITOR_TEST_ENGINE = Join-Path $staged 'engine'
    $env:TOKEN_MONITOR_TEST_NATIVE = '1'
    $resourceManifest = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $env:TOKEN_MONITOR_TEST_SCANNER_SHA256 = $resourceManifest.scannerSHA256
    $env:AIGOODBRO_TM_TEST_RESOURCES = $staged
    # The real pinned engine and scanner are exercised only on isolated fixtures.
    Invoke-StatisticsBuildCommand (Join-Path $staged 'runtime\node.exe') @('--test', 'windows/token-monitor/tests/service.test.cjs')
    if ($RunNativeTests) {
        Invoke-StatisticsBuildCommand 'cargo' @('test', '--manifest-path', 'windows/Cargo.toml', '-p', 'codexu-core', '--test', 'token_monitor', '--locked') -RequireTests
        foreach ($test in @('token_monitor::process::native_tests::owned_job_ends_its_descendants_and_leaves_unrelated_child_alive', 'token_monitor::process::native_tests::held_resource_blocks_write_delete_and_replace_until_release', 'token_monitor::tests::staged_node_and_scanner_native_smoke')) {
            Invoke-StatisticsBuildCommand 'cargo' @('test', '--manifest-path', 'windows/Cargo.toml', '-p', 'codexu-core', '--test', 'token_monitor', '--locked', $test, '--', '--ignored', '--exact', '--test-threads=1') -RequireTests
        }
    }
    $destination = Join-Path $root 'windows\apps\codexu-tauri\src-tauri\resources\token-monitor'
    $backup = Join-Path $BuildRoot 'previous-resources'
    if (Test-Path -LiteralPath $destination) {
        $old = Get-Item -LiteralPath $destination -Force
        if (-not $old.PSIsContainer -or ($old.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'statistics_resource_destination_invalid' }
        Move-Item -LiteralPath $destination -Destination $backup
    }
    try {
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($destination)) | Out-Null
        Move-Item -LiteralPath $staged -Destination $destination
    } catch {
        if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $destination)) {
            Move-Item -LiteralPath $backup -Destination $destination
        }
        throw
    }
    [IO.File]::WriteAllText((Join-Path $BuildRoot 'resource-pin.txt'), ($pin + "`n"), [Text.UTF8Encoding]::new($false))
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
        [IO.File]::AppendAllText($env:GITHUB_ENV, ('AIGOODBRO_TOKEN_MONITOR_RESOURCE_SHA256=' + $pin + "`n"), [Text.UTF8Encoding]::new($false))
    }
    Write-Host ('TOKEN_MONITOR_RESOURCE_SHA256=' + $pin)
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    Pop-Location
}
