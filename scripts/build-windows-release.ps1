#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [string]$OutputDirectory,
    # The readiness entry point records these checks before invoking packaging.
    [switch]$SkipValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Version.StartsWith("v")) {
    $Version = $Version.Substring(1)
}

if ($Version -notmatch '^\d+\.\d+\.\d+([\-+][0-9A-Za-z.-]+)?$') {
    throw "Version must be a semantic version, for example 1.2.1 or 1.2.1-beta.1: $Version"
}

# Ask the runtime instead of the `OS` environment variable: that variable is set
# for interactive Windows sessions but is absent in some hosted/curated shells, and
# the readiness entry point already gates on the same platform check.
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw "The Windows packaging script must run on a Windows runner."
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$WindowsRoot = Join-Path $RepoRoot "windows"
$AppRoot = Join-Path $WindowsRoot "apps\codexu-tauri"
$WebRoot = Join-Path $AppRoot "web"
$ManifestPath = Join-Path $AppRoot "src-tauri\Cargo.toml"
$CargoLockPath = Join-Path $WindowsRoot "Cargo.lock"
$NpmLockPath = Join-Path $WebRoot "package-lock.json"

foreach ($RequiredPath in @($WindowsRoot, $WebRoot, $ManifestPath, $CargoLockPath, $NpmLockPath)) {
    if (-not (Test-Path -LiteralPath $RequiredPath)) {
        throw "Required Windows project path is missing: $RequiredPath"
    }
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RepoRoot "dist\windows"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @()
    )

    Write-Host "> $FilePath $($ArgumentList -join ' ')"
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Select-FreshBundle {
    param([object[]] $Files, [string] $ReleaseVersion, [DateTime] $StartedUtc)
    $pattern = '_' + [regex]::Escape($ReleaseVersion) + '_x64(?:_|-)'
    return $Files |
        Where-Object { $_.LastWriteTimeUtc -ge $StartedUtc -and $_.Name -match $pattern } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    throw "rustup is required to build the Windows release."
}
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "cargo is required to build the Windows release."
}
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "npm is required to build the Windows release."
}

$Toolchain = "1.97.1-x86_64-pc-windows-msvc"
$InstalledToolchains = (& rustup toolchain list | Out-String)
if ($InstalledToolchains -notmatch [regex]::Escape($Toolchain)) {
    Invoke-Checked "rustup" @("toolchain", "install", $Toolchain, "--profile", "minimal", "--component", "rustfmt")
}

if (-not $SkipValidation) {
    Push-Location $WindowsRoot
    try {
        Invoke-Checked "cargo" @("+$Toolchain", "fmt", "--all", "--", "--check")
        Invoke-Checked "cargo" @("+$Toolchain", "test", "--workspace", "--locked")
    }
    finally {
        Pop-Location
    }

    Push-Location $WebRoot
    try {
        Invoke-Checked "npm" @("ci", "--no-audit", "--no-fund")
        Invoke-Checked "npm" @("test")
        Invoke-Checked "npm" @("run", "build")
    }
    finally {
        Pop-Location
    }
}

$BuildStartedUtc = [DateTime]::UtcNow
$TauriConfig = '{"version":"' + $Version + '"}'
Push-Location $AppRoot
try {
    if (-not (Get-Command cargo-tauri -ErrorAction SilentlyContinue)) {
        $TauriInstalled = $true
        try {
            & cargo "+$Toolchain" "tauri" "--version" *> $null
            $TauriInstalled = ($LASTEXITCODE -eq 0)
        }
        catch {
            $TauriInstalled = $false
        }
        if (-not $TauriInstalled) {
            Invoke-Checked "cargo" @("+$Toolchain", "install", "tauri-cli", "--version", "2.6.2", "--locked")
        }
    }

    Invoke-Checked "cargo" @(
        "+$Toolchain", "tauri", "build",
        "--config", $TauriConfig,
        "--bundles", "msi,nsis"
    )
}
finally {
    Pop-Location
}

$BundleRoots = @(
    (Join-Path $WindowsRoot "target\release\bundle"),
    (Join-Path $AppRoot "target\release\bundle")
) | Where-Object { Test-Path -LiteralPath $_ }

if (-not $BundleRoots) {
    throw "Tauri did not produce a release bundle directory."
}

$Msi = Select-FreshBundle -Files @($BundleRoots |
    ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_ "msi") -Filter "*.msi" -File -ErrorAction SilentlyContinue }) `
    -ReleaseVersion $Version -StartedUtc $BuildStartedUtc
$Nsis = Select-FreshBundle -Files @($BundleRoots |
    ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_ "nsis") -Filter "*-setup.exe" -File -ErrorAction SilentlyContinue }) `
    -ReleaseVersion $Version -StartedUtc $BuildStartedUtc

if (-not $Msi) {
    throw "No fresh MSI installer matching the requested version was produced."
}
if (-not $Nsis) {
    throw "No fresh NSIS setup executable matching the requested version was produced."
}

$Artifacts = @(
    @{ Source = $Msi.FullName; Name = "CodexAccountManagerNext-$Version-windows-x86_64.msi" },
    @{ Source = $Nsis.FullName; Name = "CodexAccountManagerNext-$Version-windows-x86_64-setup.exe" }
)
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

foreach ($Artifact in $Artifacts) {
    $Destination = Join-Path $OutputDirectory $Artifact.Name
    Copy-Item -LiteralPath $Artifact.Source -Destination $Destination -Force
    $Hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    $ChecksumPath = "$Destination.sha256"
    [System.IO.File]::WriteAllText($ChecksumPath, "$Hash  $($Artifact.Name)$([Environment]::NewLine)", $Utf8NoBom)
    Write-Host "Wrote $Destination"
    Write-Host "Wrote $ChecksumPath"
}

$Manifest = [ordered]@{
    product = "Codex Account Manager Next"
    version = $Version
    target = "windows-x86_64"
    installers = @($Artifacts.Name)
    generated_utc = [DateTime]::UtcNow.ToString("o")
}
[System.IO.File]::WriteAllText(
    (Join-Path $OutputDirectory "manifest.json"),
    ($Manifest | ConvertTo-Json -Depth 4),
    $Utf8NoBom
)

Write-Host "Windows release artifacts verified for Codex Account Manager Next $Version"
