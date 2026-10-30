#!/usr/bin/env pwsh
# Runs only on a fresh GitHub-hosted Windows runner, never on the user's Mac/PC.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('msi', 'nsis')][string]$InstallerKind,
    [Parameter(Mandatory = $true)][string]$OldPackageDirectory,
    [Parameter(Mandatory = $true)][string]$NewPackageDirectory,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or -not $env:RUNNER_TEMP) {
    throw 'Installer upgrade validation is restricted to an isolated GitHub-hosted Windows runner.'
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid package version.' }
$runnerRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
function Owned-Path([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($runnerRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Validation path must be inside RUNNER_TEMP.' }
    $cursor = $full
    while ($cursor.Length -ge $runnerRoot.Length) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Validation path contains a reparse point.' }
        $cursor = Split-Path -Parent $cursor
    }
    return $full
}
$oldRoot = Owned-Path $OldPackageDirectory
$newRoot = Owned-Path $NewPackageDirectory
$output = Owned-Path $OutputDirectory
if (Test-Path -LiteralPath $output) { throw 'Refuse to reuse an upgrade evidence directory.' }
New-Item -ItemType Directory -Path $output | Out-Null
$install = Owned-Path (Join-Path $runnerRoot ('aigoodbro-upgrade-' + $InstallerKind + '-' + [guid]::NewGuid().ToString('N')))
$oldName = if ($InstallerKind -eq 'msi') { 'CodexAccountManagerNext-3.0.0-windows-x86_64.msi' } else { 'CodexAccountManagerNext-3.0.0-windows-x86_64-setup.exe' }
$oldHash = if ($InstallerKind -eq 'msi') { '94dd1031429dfb1d708ebc97d4c2a6e4a02077326b794985c64dc1326b580260' } else { 'bb5fd4f19f54ca1d323d6b305829b88b2ad064d030e97950e11b9884dd4fd8ab' }
$newName = if ($InstallerKind -eq 'msi') { "AiGoodBro-$Version-windows-x86_64.msi" } else { "AiGoodBro-$Version-windows-x86_64-setup.exe" }
$oldFile = Owned-Path (Join-Path $oldRoot $oldName)
$newFile = Owned-Path (Join-Path $newRoot $newName)
function Hash-File([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
if ((Hash-File $oldFile) -cne $oldHash) { throw 'Old installer is not the exact accepted 2905a422 artifact.' }
$newHash = Hash-File $newFile
$checksum = (Get-Content -LiteralPath ($newFile + '.sha256') -Raw).Trim()
if ($checksum -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$' -or $Matches[1].ToLowerInvariant() -cne $newHash -or $Matches[2] -cne $newName) { throw 'New installer checksum/name mismatch.' }
$manifest = Get-Content -LiteralPath (Join-Path $newRoot 'manifest.json') -Raw | ConvertFrom-Json
if ($manifest.product -cne 'AiGoodBro' -or $manifest.version -cne $Version -or $manifest.target -cne 'windows-x86_64') { throw 'New installer manifest does not match the AiGoodBro Windows candidate.' }
$registryRoots = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
function Registrations {
    $rows = @()
    foreach ($root in $registryRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $root)) {
            $value = Get-ItemProperty -LiteralPath $item.PSPath
            $name = if ($value.PSObject.Properties['DisplayName']) { [string]$value.DisplayName } else { '' }
            if ($name -in @('AiGoodBro', 'Codex Account Manager Next')) {
                $rows += [pscustomobject]@{ key = $item.PSChildName; path = $item.PSPath; displayName = $name; installLocation = $(if ($value.PSObject.Properties['InstallLocation']) { [string]$value.InstallLocation } else { '' }) }
            }
        }
    }
    return $rows
}
function Run-Values {
    $rows = @()
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $key = Get-Item -LiteralPath $root
        foreach ($name in $key.GetValueNames()) { $rows += [pscustomobject]@{ root=$root; name=$name; value=[string]$key.GetValue($name) } }
    }
    return @($rows | Sort-Object root, name)
}
function Assert-NoApp {
    if (@(Get-Process -Name 'codexu-tauri' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Installer unexpectedly launched the application.' }
}
function Execute-Installer([string]$File, [string[]]$Arguments, [string]$Phase) {
    Assert-NoApp
    # No /R and no AUTOLAUNCHAPP: the app must never run in this acceptance job.
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
    if (-not $process.WaitForExit(180000)) {
        $process.Kill($true)
        throw "$Phase timed out."
    }
    $process.Refresh()
    if ($process.ExitCode -notin @(0, 3010)) { throw "$Phase failed with exit code $($process.ExitCode)." }
    Assert-NoApp
}
$shortcutRoots = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms')) | Where-Object { $_ } | Select-Object -Unique
function Shortcuts {
    $rows = @(); $shell = New-Object -ComObject WScript.Shell
    try {
        foreach ($root in $shortcutRoots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -File -ErrorAction Stop)) {
                # Restrict inspection to known brand filenames. Never execute a link.
                if ($file.BaseName -notin @('AiGoodBro', 'Codex Account Manager Next')) { continue }
                $link = $shell.CreateShortcut($file.FullName)
                $rows += [pscustomobject]@{ path=$file.FullName; name=$file.BaseName; target=$link.TargetPath }
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
            }
        }
    } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    return $rows
}
function Assert-Registration([string]$Brand) {
    $rows = @(Registrations)
    if ($rows.Count -ne 1 -or $rows[0].displayName -cne $Brand) { throw 'Expected exactly one matching uninstall registration.' }
    if ($rows[0].installLocation -and [IO.Path]::GetFullPath($rows[0].installLocation).TrimEnd('\') -ine $install.TrimEnd('\')) { throw 'Installer changed the existing installation directory.' }
    if (-not (Test-Path -LiteralPath (Join-Path $install 'codexu-tauri.exe') -PathType Leaf)) { throw 'Installed executable not found at the preserved directory.' }
    return $rows[0]
}
function Assert-RunUnchanged($Expected) {
    if ((ConvertTo-Json -InputObject @(Run-Values) -Depth 3 -Compress) -cne (ConvertTo-Json -InputObject @($Expected) -Depth 3 -Compress)) { throw 'Installers changed autostart registration.' }
}
if (@(Registrations).Count -ne 0 -or @(Shortcuts).Count -ne 0) { throw 'Runner already has an installation/shortcut with this product identity.' }
Assert-NoApp
$runBefore = @(Run-Values)
$receipt = [ordered]@{ schema=1; kind=$InstallerKind; oldRunId=40952488530; oldHead='2905a4227fc543ff07e4e069ce6ff4e6290c1002'; sourceCheckout=$env:GITHUB_SHA; runId=$env:GITHUB_RUN_ID; oldSha256=$oldHash; newSha256=$newHash; version=$Version; success=$false; phases=@(); applicationStarted=$false }
try {
    if ($InstallerKind -eq 'msi') {
        Execute-Installer 'msiexec.exe' @('/i', ('"' + $oldFile + '"'), '/qn', '/norestart', ('INSTALLDIR="' + $install + '"'), '/l*v', ('"' + (Join-Path $output 'old-msi.log') + '"')) 'Old MSI install'
    } else {
        Execute-Installer $oldFile @('/S', ('/D=' + $install)) 'Old NSIS install'
    }
    $oldRegistration = Assert-Registration 'Codex Account Manager Next'
    $oldShortcuts = @(Shortcuts)
    if (@($oldShortcuts | Where-Object { $_.target -ieq (Join-Path $install 'codexu-tauri.exe') }).Count -eq 0) { throw 'Old package did not create its expected owned shortcut.' }
    Assert-RunUnchanged $runBefore
    $receipt.phases += 'old_install_verified'
    if ($InstallerKind -eq 'msi') {
        Execute-Installer 'msiexec.exe' @('/i', ('"' + $newFile + '"'), '/qn', '/norestart', '/l*v', ('"' + (Join-Path $output 'new-msi.log') + '"')) 'New MSI upgrade'
    } else {
        Execute-Installer $newFile @('/S') 'New NSIS upgrade'
    }
    $newRegistration = Assert-Registration 'AiGoodBro'
    $exe = Get-Item -LiteralPath (Join-Path $install 'codexu-tauri.exe')
    if ($exe.VersionInfo.ProductName -cne 'AiGoodBro') { throw 'Installed executable product name is not AiGoodBro.' }
    $helpers = @(Get-ChildItem -LiteralPath $install -Filter 'aigoodbro-local-proxy.exe' -Recurse -File)
    if ($helpers.Count -ne 1) { throw 'Installed helper resource missing or duplicated.' }
    $shortcuts = @(Shortcuts)
    $owned = @($shortcuts | Where-Object { $_.target -ieq $exe.FullName })
    if ($owned.Count -eq 0 -or @($owned | Where-Object { $_.name -cne 'AiGoodBro' }).Count -ne 0) { throw 'Upgrade left an old-brand owned shortcut or no new-brand shortcut.' }
    # Every shortcut this job created must remain owned by the same install.
    if (@($shortcuts | Where-Object { $_.target -ine $exe.FullName }).Count -ne 0) { throw 'Upgrade left a shortcut pointing outside the preserved installation.' }
    Assert-RunUnchanged $runBefore
    $receipt.phases += 'upgrade_identity_brand_path_shortcuts_resources_verified'
    $receipt.oldRegistration = $oldRegistration
    $receipt.newRegistration = $newRegistration
    $receipt.shortcuts = $owned
    $receipt.helperSha256 = Hash-File $helpers[0].FullName
    if ($InstallerKind -eq 'msi') {
        if ($newRegistration.key -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw 'MSI product code malformed.' }
        Execute-Installer 'msiexec.exe' @('/x', $newRegistration.key, '/qn', '/norestart', '/l*v', ('"' + (Join-Path $output 'uninstall-msi.log') + '"')) 'New MSI uninstall'
    } else {
        $uninstaller = Join-Path $install 'uninstall.exe'
        if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'Owned NSIS uninstaller missing.' }
        Execute-Installer $uninstaller @('/S', ('_?=' + $install)) 'New NSIS uninstall'
    }
    if (@(Registrations).Count -ne 0 -or @(Shortcuts).Count -ne 0 -or (Test-Path -LiteralPath $exe.FullName)) { throw 'Uninstall left a product registration, shortcut or executable.' }
    Assert-RunUnchanged $runBefore
    $receipt.phases += 'uninstall_cleanup_verified'
    $receipt.success = $true
} finally {
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'upgrade-receipt.json') -Encoding utf8
}
Write-Output "PASS: $InstallerKind exact old-to-new install upgrade and uninstall; no app launch requested or observed."
