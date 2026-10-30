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
function Execute-Installer([string]$File, [string[]]$Arguments, [string]$Phase, [int[]]$ExpectedExitCodes = @(0, 3010)) {
    Assert-NoApp
    # No /R and no AUTOLAUNCHAPP: the app must never run in this acceptance job.
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
    if (-not $process.WaitForExit(180000)) {
        $process.Kill($true)
        throw "$Phase timed out."
    }
    $process.Refresh()
    if ($process.ExitCode -notin $ExpectedExitCodes) { throw "$Phase failed with exit code $($process.ExitCode)." }
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
function Normalize-InstallLocation([string]$Value) {
    # NSIS writes one quoted absolute path; do not trim arbitrary quotes or
    # interpret relative paths against the validator's working directory.
    if ($Value.StartsWith('"') -or $Value.EndsWith('"')) {
        if ($Value.Length -lt 2 -or -not ($Value.StartsWith('"') -and $Value.EndsWith('"'))) { throw 'Unpaired InstallLocation quotes.' }
        $Value = $Value.Substring(1, $Value.Length - 2)
    }
    if (-not $Value -or $Value.Contains('"') -or $Value -match '[\x00-\x1f]' -or $Value.Trim() -cne $Value -or
        $Value -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/:*?"<>|]+\\[^\\/:*?"<>|]+(?:\\|$))' -or
        -not [IO.Path]::IsPathFullyQualified($Value)) { throw 'InstallLocation is not one absolute path.' }
    return [IO.Path]::GetFullPath($Value).TrimEnd('\')
}
function Test-InstallLocationContract {
    $expected = 'C:\AiGoodBro fixture\installed'
    foreach ($value in @($expected, ('"' + $expected + '"'), ($expected + '\'), 'C:\AiGoodBro fixture\prior\..\installed')) {
        if ((Normalize-InstallLocation $value) -cne $expected) { throw 'InstallLocation positive fixture failed.' }
    }
    foreach ($value in @('', 'relative', 'C:relative', '\rooted', '"C:\broken', 'C:\broken"', '""C:\nested""', 'C:\in"side', ' C:\leading', '"relative"')) {
        $rejected = $false
        try { $null = Normalize-InstallLocation $value } catch { $rejected = $true }
        if (-not $rejected) { throw 'InstallLocation negative fixture was accepted.' }
    }
}
Test-InstallLocationContract
function Assert-Registration([string]$Brand) {
    $rows = @(Registrations)
    if ($rows.Count -ne 1 -or $rows[0].displayName -cne $Brand) { throw 'Expected exactly one matching uninstall registration.' }
    if ($rows[0].installLocation -and (Normalize-InstallLocation $rows[0].installLocation) -ine $install.TrimEnd('\')) { throw 'Installer changed the existing installation directory.' }
    if (-not (Test-Path -LiteralPath (Join-Path $install 'codexu-tauri.exe') -PathType Leaf)) { throw 'Installed executable not found at the preserved directory.' }
    return $rows[0]
}
function Assert-RunUnchanged($Expected) {
    if ((ConvertTo-Json -InputObject @(Run-Values) -Depth 3 -Compress) -cne (ConvertTo-Json -InputObject @($Expected) -Depth 3 -Compress)) { throw 'Installers changed autostart registration.' }
}
function Select-RollbackSequenceSlots([int]$RemoveFilesSequence, [int]$FinalizeSequence, [int[]]$Occupied) {
    # MSI sequence numbers are signed 16-bit values. Select only inside the
    # install-script interval; never move or overwrite an existing action.
    if ($RemoveFilesSequence -le 0 -or $FinalizeSequence -gt 32767 -or $FinalizeSequence -le $RemoveFilesSequence) { throw 'Invalid MSI rollback sequence boundaries.' }
    $used = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($sequence in $Occupied) { [void]$used.Add($sequence) }
    $free = [System.Collections.Generic.List[int]]::new()
    for ($sequence = $FinalizeSequence - 1; $sequence -gt $RemoveFilesSequence -and $free.Count -lt 2; $sequence--) {
        if (-not $used.Contains($sequence)) { $free.Add($sequence) }
    }
    if ($free.Count -ne 2) { throw 'MSI rollback fixture requires two unused sequence slots after RemoveFiles and before InstallFinalize.' }
    return [pscustomobject]@{ data = $free[1]; failure = $free[0] }
}
function Test-RollbackSequenceContract {
    foreach ($case in @(
        @{ removeAt=3500; finalizeAt=6600; occupied=@(3500, 6600); data=6598; failure=6599 },
        @{ removeAt=3500; finalizeAt=6600; occupied=@(3500, 6598, 6599, 6600); data=6596; failure=6597 },
        @{ removeAt=10; finalizeAt=16; occupied=@(-1, 11, 13, 15); data=12; failure=14 },
        @{ removeAt=10; finalizeAt=13; occupied=@(); data=11; failure=12 },
        @{ removeAt=32763; finalizeAt=32767; occupied=@(32766); data=32764; failure=32765 }
    )) {
        $selected = Select-RollbackSequenceSlots -RemoveFilesSequence $case.removeAt -FinalizeSequence $case.finalizeAt -Occupied $case.occupied
        if ($selected.data -ne $case.data -or $selected.failure -ne $case.failure -or
            $selected.data -le $case.removeAt -or $selected.failure -ge $case.finalizeAt -or
            $selected.data -ge $selected.failure -or $selected.data -in $case.occupied -or $selected.failure -in $case.occupied) { throw 'MSI rollback sequence positive fixture failed.' }
    }
    foreach ($case in @(
        @{ removeAt=0; finalizeAt=5; occupied=@() },
        @{ removeAt=10; finalizeAt=10; occupied=@() },
        @{ removeAt=12; finalizeAt=10; occupied=@() },
        @{ removeAt=10; finalizeAt=32768; occupied=@() },
        @{ removeAt=10; finalizeAt=12; occupied=@() },
        @{ removeAt=10; finalizeAt=14; occupied=@(11, 12, 13) },
        @{ removeAt=10; finalizeAt=15; occupied=@(11, 12, 14) }
    )) {
        $rejected = $false
        try { $null = Select-RollbackSequenceSlots -RemoveFilesSequence $case.removeAt -FinalizeSequence $case.finalizeAt -Occupied $case.occupied } catch { $rejected = $true }
        if (-not $rejected) { throw 'MSI rollback sequence negative fixture was accepted.' }
    }
    Write-Output 'PASS: rollback sequence selector contract (5 positive, 7 negative)'
}
Test-RollbackSequenceContract
function Get-RollbackTransformPath([object[]]$Values, [string]$Expected) {
    if ($Values.Count -ne 1 -or $Values[0] -isnot [string] -or $Values[0] -cne $Expected) {
        throw 'Rollback transform must return exactly its one original path; incidental output is not a path.'
    }
    return $Values[0]
}
function New-RollbackTransform([string[]]$ShortcutPaths) {
    if ($ShortcutPaths.Count -ne 2 -or @($ShortcutPaths | Select-Object -Unique).Count -ne 2 -or @($ShortcutPaths | Where-Object { $_ -match '[|\[\]\r\n]' }).Count) { throw 'Rollback fixture requires two exact shortcut paths.' }
    $copy = Owned-Path (Join-Path $runnerRoot ('aigoodbro-rollback-' + [guid]::NewGuid().ToString('N') + '.msi'))
    $transform = Owned-Path (Join-Path $output 'shortcut-rollback.mst')
    $proof = Owned-Path (Join-Path $output 'shortcut-rollback-proof.txt')
    if ((Test-Path -LiteralPath $proof) -or $proof -match '[|\[\]\r\n]') { throw 'Refuse unsafe or reused rollback execution proof.' }
    Copy-Item -LiteralPath $newFile -Destination $copy
    $engine = $null; $original = $null; $changed = $null
    # Type 37 is literal JScript; 1024 defers it into the MSI install script.
    # The marker is emitted only after the real RemoveFiles action removed both
    # owned links. An unrelated early install failure cannot satisfy this test.
    $failureScript = @'
var paths = Session.Property("CustomActionData").split("|");
if (paths.length !== 3 || paths[0] === paths[1] || !paths[2]) throw new Error("Invalid rollback fixture paths");
var fs = new ActiveXObject("Scripting.FileSystemObject");
for (var i = 0; i < 2; i++) {
    if (!paths[i] || fs.FileExists(paths[i])) throw new Error("Owned legacy shortcut was not removed");
}
var proof = fs.CreateTextFile(paths[2], false, false);
proof.WriteLine("AIGOODBRO_SYNTHETIC_ROLLBACK_AFTER_OWNED_LINK_REMOVAL");
proof.Close();
throw new Error("AIGOODBRO_SYNTHETIC_ROLLBACK_AFTER_OWNED_LINK_REMOVAL");
'@
    try {
        $engine = New-Object -ComObject WindowsInstaller.Installer
        $original = $engine.OpenDatabase($newFile, 0)
        $changed = $engine.OpenDatabase($copy, 1)
        function Execute-MsiInsert([string]$Sql, [object[]]$Values) {
            $view = $changed.OpenView($Sql); $record = $engine.CreateRecord($Values.Count)
            try {
                for ($i = 0; $i -lt $Values.Count; $i++) {
                    if ($Values[$i] -is [int]) { $record.IntegerData($i + 1) = $Values[$i] }
                    elseif ($null -ne $Values[$i]) { $record.StringData($i + 1) = [string]$Values[$i] }
                }
                [void]$view.Execute($record)
            } finally { [void]$view.Close(); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
        }
        $sequenceRows = @()
        $view = $changed.OpenView('SELECT `Action`, `Sequence` FROM `InstallExecuteSequence`')
        try {
            [void]$view.Execute()
            while ($null -ne ($record = $view.Fetch())) {
                try { $sequenceRows += [pscustomobject]@{ action = $record.StringData(1); sequence = [int]$record.IntegerData(2) } }
                finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }
            }
        }
        finally { [void]$view.Close(); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
        $removeFiles = @($sequenceRows | Where-Object { $_.action -ceq 'RemoveFiles' })
        $finalize = @($sequenceRows | Where-Object { $_.action -ceq 'InstallFinalize' })
        $sequenceDiagnostic = [ordered]@{ schema=1; newInstallerSha256=$newHash; actions=$sequenceRows; selectedSlots=$null }
        try {
            if ($removeFiles.Count -ne 1 -or $finalize.Count -ne 1) { throw 'MSI rollback sequence boundaries missing or duplicated.' }
            $slots = Select-RollbackSequenceSlots -RemoveFilesSequence $removeFiles[0].sequence -FinalizeSequence $finalize[0].sequence -Occupied @($sequenceRows | ForEach-Object { $_.sequence })
            $sequenceDiagnostic.selectedSlots = $slots
        } finally {
            $sequenceDiagnostic | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Owned-Path (Join-Path $output 'rollback-sequence.json')) -Encoding utf8
        }
        Execute-MsiInsert 'INSERT INTO `CustomAction` (`Action`, `Type`, `Source`, `Target`) VALUES (?, ?, ?, ?)' @('AgbFixtureRollbackData', 51, 'AgbFixtureRollbackFailure', ((@($ShortcutPaths) + @($proof)) -join '|'))
        Execute-MsiInsert 'INSERT INTO `CustomAction` (`Action`, `Type`, `Source`, `Target`) VALUES (?, ?, ?, ?)' @('AgbFixtureRollbackFailure', (37 + 1024), $null, $failureScript)
        Execute-MsiInsert 'INSERT INTO `InstallExecuteSequence` (`Action`, `Condition`, `Sequence`) VALUES (?, ?, ?)' @('AgbFixtureRollbackData', 'WIX_UPGRADE_DETECTED AND NOT Installed', $slots.data)
        Execute-MsiInsert 'INSERT INTO `InstallExecuteSequence` (`Action`, `Condition`, `Sequence`) VALUES (?, ?, ?)' @('AgbFixtureRollbackFailure', 'WIX_UPGRADE_DETECTED AND NOT Installed', $slots.failure)
        [void]$changed.Commit()
        if (-not $changed.GenerateTransform($original, $transform)) { throw 'MSI rollback transform contained no changes.' }
        # No suppressed transform errors; pin language, product, all three
        # version fields with equality, and UpgradeCode to this exact MSI.
        [void]$changed.CreateTransformSummaryInfo($original, $transform, 0, (1 + 2 + 32 + 256 + 2048))
    } finally {
        foreach ($com in @($changed, $original, $engine)) { if ($null -ne $com) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) } }
        if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy }
    }
    if ((Hash-File $newFile) -cne $newHash) { throw 'Rollback fixture changed the original new MSI.' }
    return $transform
}
function Assert-ForeignShortcuts([string]$Phase) {
    foreach ($entry in $foreignShortcuts) {
        if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf) -or (Hash-File $entry.path) -cne $entry.beforeSha256) { throw "Foreign shortcut changed during $Phase." }
        $found = @(Shortcuts | Where-Object { $_.path -ieq $entry.path -and $_.target -ieq $entry.target })
        if ($found.Count -ne 1) { throw "Foreign shortcut target changed during $Phase." }
        $entry[$Phase] = Hash-File $entry.path
    }
}
if (@(Registrations).Count -ne 0 -or @(Shortcuts).Count -ne 0) { throw 'Runner already has an installation/shortcut with this product identity.' }
Assert-NoApp
$runBefore = @(Run-Values)
$receipt = [ordered]@{ schema=1; kind=$InstallerKind; oldRunId=40952488530; oldHead='2905a4227fc543ff07e4e069ce6ff4e6290c1002'; sourceCheckout=$env:GITHUB_SHA; runId=$env:GITHUB_RUN_ID; oldSha256=$oldHash; newSha256=$newHash; version=$Version; success=$false; phases=@(); applicationStarted=$false }
$foreignShortcuts = @()
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
        $oldOwned = @($oldShortcuts | Where-Object { $_.name -ceq 'Codex Account Manager Next' -and $_.target -ieq (Join-Path $install 'codexu-tauri.exe') })
        if ($oldOwned.Count -ne 2) { throw 'MSI rollback fixture requires the original two owned shortcuts.' }
        $desktopCandidates = @('Desktop', 'CommonDesktopDirectory' | ForEach-Object { Join-Path ([Environment]::GetFolderPath($_)) 'Codex Account Manager Next.lnk' })
        $programCandidates = @('Programs', 'CommonPrograms' | ForEach-Object { Join-Path ([Environment]::GetFolderPath($_)) 'Codex Account Manager Next\Codex Account Manager Next.lnk' })
        if (@($oldOwned | Where-Object { $_.path -in $desktopCandidates }).Count -ne 1 -or @($oldOwned | Where-Object { $_.path -in $programCandidates }).Count -ne 1) { throw 'Old shortcuts are not the two fixed legacy migration paths.' }
        $snapshots = @($oldOwned | ForEach-Object { [ordered]@{ path=$_.path; target=$_.target; beforeSha256=(Hash-File $_.path); restoredSha256=$null } })
        $oldExeHash = Hash-File (Join-Path $install 'codexu-tauri.exe')
        $transformOutput = @(New-RollbackTransform @($snapshots | ForEach-Object { $_.path }))
        $transform = Get-RollbackTransformPath -Values $transformOutput -Expected (Owned-Path (Join-Path $output 'shortcut-rollback.mst'))
        Write-Output 'PASS: native rollback transform single-path output'
        $rollbackLog = Join-Path $output 'rollback-msi.log'
        Execute-Installer 'msiexec.exe' @('/i', ('"' + $newFile + '"'), ('TRANSFORMS="' + $transform + '"'), '/qn', '/norestart', '/l*v', ('"' + $rollbackLog + '"')) 'Synthetic MSI rollback' @(1603)
        $marker = 'AIGOODBRO_SYNTHETIC_ROLLBACK_AFTER_OWNED_LINK_REMOVAL'
        if (-not (Get-Content -LiteralPath $rollbackLog -Raw).Contains($marker)) { throw 'MSI failed without reaching the post-removal rollback fixture.' }
        $proof = Owned-Path (Join-Path $output 'shortcut-rollback-proof.txt')
        if (-not (Test-Path -LiteralPath $proof -PathType Leaf) -or [IO.File]::ReadAllText($proof) -cne ($marker + "`r`n")) { throw 'Missing post-removal native execution proof.' }
        $restored = Assert-Registration 'Codex Account Manager Next'
        if ($restored.key -cne $oldRegistration.key -or (Hash-File (Join-Path $install 'codexu-tauri.exe')) -cne $oldExeHash) { throw 'Rollback did not restore the original installation.' }
        foreach ($entry in $snapshots) {
            if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf) -or (Hash-File $entry.path) -cne $entry.beforeSha256) { throw 'Rollback did not restore original shortcut bytes.' }
            $entry.restoredSha256 = Hash-File $entry.path
        }
        if (@(Shortcuts).Count -ne 2) { throw 'Rollback left additional product shortcuts.' }
        Assert-RunUnchanged $runBefore
        $receipt.shortcutMigration = [ordered]@{ schema=1; rollback=[ordered]@{ exitCode=1603; marker=$marker; removedBeforeFailure=$true; transformSha256=(Hash-File $transform); executionProofFile='shortcut-rollback-proof.txt'; executionProofSha256=(Hash-File $proof); newInstallerSha256Before=$newHash; newInstallerSha256After=(Hash-File $newFile); oldRegistrationPreserved=$true; oldExecutableSha256Before=$oldExeHash; oldExecutableSha256After=(Hash-File (Join-Path $install 'codexu-tauri.exe')); ownedShortcuts=$snapshots }; foreign=[ordered]@{ shortcuts=@(); unchangedAfterUpgrade=$false; unchangedAfterUninstall=$false; fixtureCleanupVerified=$false } }
        $foreignTarget = Owned-Path (Join-Path $output 'synthetic-foreign-target.txt')
        [IO.File]::WriteAllText($foreignTarget, 'Synthetic shortcut target; never executed.')
        $shell = New-Object -ComObject WScript.Shell
        try {
            foreach ($entry in $snapshots) {
                $link = $shell.CreateShortcut($entry.path)
                try { $link.TargetPath = $foreignTarget; $link.Save() } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
                $foreignShortcuts += [ordered]@{ path=$entry.path; target=$foreignTarget; beforeSha256=(Hash-File $entry.path); afterUpgradeSha256=$null; afterUninstallSha256=$null }
            }
        } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
        $receipt.shortcutMigration.foreign.shortcuts = $foreignShortcuts
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
    if ($InstallerKind -eq 'msi' -and $owned.Count -ne 2) { throw 'MSI upgrade did not retain both new-brand shortcut surfaces.' }
    # Only the two explicitly-created, byte-preserved foreign fixtures may lie
    # outside this install; every other unexpected target remains a failure.
    Assert-ForeignShortcuts 'afterUpgradeSha256'
    $foreignPaths = @($foreignShortcuts | ForEach-Object { $_.path })
    if (@($shortcuts | Where-Object { $_.target -ine $exe.FullName -and $_.path -notin $foreignPaths }).Count -ne 0) { throw 'Upgrade left an unexpected shortcut pointing outside the preserved installation.' }
    if ($InstallerKind -eq 'msi') { $receipt.shortcutMigration.foreign.unchangedAfterUpgrade = $true }
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
    Assert-ForeignShortcuts 'afterUninstallSha256'
    if (@(Registrations).Count -ne 0 -or @(Shortcuts | Where-Object { $_.path -notin $foreignPaths }).Count -ne 0 -or (Test-Path -LiteralPath $exe.FullName)) { throw 'Uninstall left a product registration, owned shortcut or executable.' }
    if ($InstallerKind -eq 'msi') { $receipt.shortcutMigration.foreign.unchangedAfterUninstall = $true }
    foreach ($entry in $foreignShortcuts) {
        if ((Hash-File $entry.path) -cne $entry.beforeSha256) { throw 'Refuse to clean a changed synthetic shortcut.' }
        Remove-Item -LiteralPath $entry.path
    }
    if (@(Shortcuts).Count -ne 0) { throw 'Synthetic shortcut cleanup left a product-name shortcut.' }
    if ($InstallerKind -eq 'msi') { $receipt.shortcutMigration.foreign.fixtureCleanupVerified = $true }
    Assert-RunUnchanged $runBefore
    $receipt.phases += 'uninstall_cleanup_verified'
    $receipt.success = $true
} finally {
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'upgrade-receipt.json') -Encoding utf8
}
Write-Output "PASS: $InstallerKind exact old-to-new install upgrade and uninstall; no app launch requested or observed."
