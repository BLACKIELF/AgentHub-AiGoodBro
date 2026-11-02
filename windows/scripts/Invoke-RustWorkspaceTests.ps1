#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $Toolchain = '1.97.1-x86_64-pc-windows-msvc'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The Windows Rust workspace test gate requires a native Windows runner.'
}
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw 'cargo is required for the Windows Rust workspace test gate.'
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$windowsRoot = Join-Path $repositoryRoot 'windows'
$manifest = Join-Path $windowsRoot 'Cargo.toml'
$previousFakeCliPath = [Environment]::GetEnvironmentVariable('AIGB_WINDOWS_FAKECLI_PATH', 'Process')
Push-Location $windowsRoot
try {
    $metadataLines = & cargo "+$Toolchain" metadata --manifest-path $manifest --format-version 1 --no-deps --locked
    if ($LASTEXITCODE -ne 0) { throw ('cargo metadata failed with exit code ' + $LASTEXITCODE) }
    $metadata = ($metadataLines -join "`n") | ConvertFrom-Json
    $targetDirectory = [string]$metadata.target_directory
    if (-not [string]::IsNullOrWhiteSpace($env:CARGO_BUILD_TARGET)) {
        $targetDirectory = Join-Path $targetDirectory $env:CARGO_BUILD_TARGET
    }
    $fakeCliPath = Join-Path $targetDirectory 'debug\examples\windows_fake_cli.exe'

    & cargo "+$Toolchain" build --locked -p codexu-core --example windows_fake_cli
    if ($LASTEXITCODE -ne 0) { throw ('Building the Windows fake CLI failed with exit code ' + $LASTEXITCODE) }
    if (-not (Test-Path -LiteralPath $fakeCliPath -PathType Leaf)) {
        throw 'The Windows fake CLI build succeeded without producing the expected executable.'
    }

    [Environment]::SetEnvironmentVariable('AIGB_WINDOWS_FAKECLI_PATH', $fakeCliPath, 'Process')
    $companionBridgeFilter = 'windows_python_receiver_app_backend_routes_two_sessions_and_status_after_disconnect_does_not_repost'
    & cargo "+$Toolchain" test --locked -p codexu-tauri $companionBridgeFilter -- --nocapture
    if ($LASTEXITCODE -ne 0) { throw ('Windows Companion bridge E2E failed with exit code ' + $LASTEXITCODE) }

    & cargo "+$Toolchain" test --workspace --locked -- --skip $companionBridgeFilter
    if ($LASTEXITCODE -ne 0) { throw ('Windows Rust workspace tests failed with exit code ' + $LASTEXITCODE) }
} finally {
    [Environment]::SetEnvironmentVariable('AIGB_WINDOWS_FAKECLI_PATH', $previousFakeCliPath, 'Process')
    Pop-Location
}
