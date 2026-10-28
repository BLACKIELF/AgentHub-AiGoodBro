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
foreach ($tool in @('python', 'go')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw ('missing_tool:' + $tool) }
}
function Invoke-ProxyBuildCommand {
    param([string] $Executable, [string[]] $Arguments)
    & $Executable @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw ('proxy_validation_failed:' + $Executable + ':' + $LASTEXITCODE) }
}
Push-Location $root
$previousHelper = [Environment]::GetEnvironmentVariable('AIGOODBRO_TEST_PROXY_HELPER', 'Process')
$previousEvidenceDriver = [Environment]::GetEnvironmentVariable('AIGOODBRO_TEST_GO_EVIDENCE_DRIVER', 'Process')
$previousPython = [Environment]::GetEnvironmentVariable('AIGOODBRO_TEST_PYTHON', 'Process')
try {
    Invoke-ProxyBuildCommand 'python' @('windows/proxy/prepare-resource.py', '--build-root', $BuildRoot, '--target', 'windows-amd64')
    if ($RunNativeTests) {
        Invoke-ProxyBuildCommand 'python' @('windows/proxy/build.py', '--build-root', $BuildRoot, '--target', 'windows-amd64', 'test', '-mod=readonly', '-run', '^TestWindows', '.')
        Invoke-ProxyBuildCommand 'python' @('windows/proxy/build.py', '--build-root', $BuildRoot, '--target', 'windows-amd64', 'vet', '-mod=readonly', './...')
        # Only synthetic account/credential fixtures are used. The packaged
        # helper must be the fresh, source-verified candidate from this run.
        $env:AIGOODBRO_TEST_PROXY_HELPER = Join-Path $root 'windows\apps\codexu-tauri\src-tauri\resources\proxy\aigoodbro-local-proxy.exe'
        Invoke-ProxyBuildCommand 'cargo' @('+1.97.1-x86_64-pc-windows-msvc', 'test', '--manifest-path', 'windows/Cargo.toml', '--locked', '-p', 'codexu-core', '--lib', 'actual_helper', '--', '--ignored')
        $env:AIGOODBRO_TEST_GO_EVIDENCE_DRIVER = Join-Path $root 'windows\proxy\evidence-fixture.py'
        $env:AIGOODBRO_TEST_PYTHON = (Get-Command python).Source
        Invoke-ProxyBuildCommand 'cargo' @('+1.97.1-x86_64-pc-windows-msvc', 'test', '--manifest-path', 'windows/Cargo.toml', '--locked', '-p', 'codexu-core', '--test', 'managed_accounts', 'actual_go_desktop_evidence_is_accepted_by_real_account_manager', '--', '--ignored', '--exact')
        Invoke-ProxyBuildCommand 'cargo' @('+1.97.1-x86_64-pc-windows-msvc', 'test', '--manifest-path', 'windows/Cargo.toml', '--locked', '-p', 'codexu-core', '--test', 'managed_accounts', 'actual_helper_service_run_is_accepted_by_real_account_manager', '--', '--ignored', '--exact')
    }
} finally {
    [Environment]::SetEnvironmentVariable('AIGOODBRO_TEST_PROXY_HELPER', $previousHelper, 'Process')
    [Environment]::SetEnvironmentVariable('AIGOODBRO_TEST_GO_EVIDENCE_DRIVER', $previousEvidenceDriver, 'Process')
    [Environment]::SetEnvironmentVariable('AIGOODBRO_TEST_PYTHON', $previousPython, 'Process')
    Pop-Location
}
