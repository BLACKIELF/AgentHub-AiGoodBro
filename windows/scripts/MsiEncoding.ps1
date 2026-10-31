# Read-only native verification; callers own installation and evidence paths.
function Get-MsiUnicodeResourcePaths {
    return @(
        'skill-library/jev-cu/来源-1013v1.json',
        'skill-library/jev-cu/安装说明.md',
        'skill-library/handoff/安装说明.md',
        'skill-library/reverse-engineer-anything/来源-1013v1.json',
        'skill-library/reverse-engineer-anything/安装说明.md',
        'skill-library/oracle/安装说明.md',
        'skill-library/typesafe-ai/安装说明.md'
    )
}
function Read-MsiCodepageExport([string]$Text) {
    # _ForceCodepage is a special read-only export, not a database table.
    if ($Text -notmatch '\A\r?\n\r?\n([0-9]+)\t_ForceCodepage\r?\n?\z') { throw 'Invalid MSI codepage export.' }
    return [int]$Matches[1]
}
function Read-MsiRows($Database, [string]$Sql, [int]$Columns) {
    $view = $null
    try {
        $view = $Database.OpenView($Sql)
        [void]$view.Execute()
        while ($null -ne ($record = $view.Fetch())) {
            try {
                $values = @()
                for ($index = 1; $index -le $Columns; $index++) { $values += [string]$record.StringData($index) }
                # One object per row prevents PowerShell from flattening columns.
                [pscustomobject]@{ values=$values }
            } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }
        }
    } finally {
        if ($null -ne $view) { [void]$view.Close(); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
    }
}
function Resolve-MsiTargetDirectory([string]$Id, $Directories) {
    $parts = @(); $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($Id -cne 'INSTALLDIR') {
        if (-not $seen.Add($Id) -or -not $Directories.ContainsKey($Id)) { throw 'MSI directory is not rooted at INSTALLDIR.' }
        $row = $Directories[$Id]
        # DefaultDir is target[:source], with optional short|long target name.
        $name = ($row[1].Split(':')[0].Split('|') | Select-Object -Last 1)
        if ($name -cne '.') {
            if (-not $name -or $name -in @('..') -or $name -match '[\\/\x00-\x1f]') { throw 'Unsafe MSI directory name.' }
            $parts = @($name) + $parts
        }
        $Id = $row[0]
    }
    return ($parts -join '/')
}
function Get-MsiEncodingEvidence([string]$MsiPath, [string]$SourceRoot, [string]$EvidenceDirectory) {
    $before = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $export = Join-Path $EvidenceDirectory 'msi-codepage.idt'
    if (Test-Path -LiteralPath $export) { throw 'Refuse to overwrite MSI codepage evidence.' }
    $engine = $null; $db = $null; $summary = $null
    try {
        $engine = New-Object -ComObject WindowsInstaller.Installer
        $db = $engine.OpenDatabase($MsiPath, 0)
        [void]$db.Export('_ForceCodepage', $EvidenceDirectory, 'msi-codepage.idt')
        $databaseCodepage = Read-MsiCodepageExport ([IO.File]::ReadAllText($export))
        $summary = $db.SummaryInformation(0)
        $summaryCodepage = [int]$summary.Property(1)
        if ($databaseCodepage -ne 936 -or $summaryCodepage -ne 1252) { throw 'MSI database/summary codepage mismatch.' }
        $properties = @{}
        foreach ($row in @(Read-MsiRows $db 'SELECT `Property`, `Value` FROM `Property`' 2)) { $properties[$row.values[0]] = $row.values[1] }
        if ($properties['ProductLanguage'] -cne '1033' -or $properties['UpgradeCode'] -ine '{6CD62AC1-9AD0-5E9E-A4E1-C78C6A73FD03}') { throw 'MSI language or upgrade identity changed.' }
        $directories = @{}; $components = @{}
        foreach ($row in @(Read-MsiRows $db 'SELECT `Directory`, `Directory_Parent`, `DefaultDir` FROM `Directory`' 3)) { $directories[$row.values[0]] = @($row.values[1], $row.values[2]) }
        foreach ($row in @(Read-MsiRows $db 'SELECT `Component`, `Directory_` FROM `Component`' 2)) { $components[$row.values[0]] = $row.values[1] }
        $expected = @(Get-MsiUnicodeResourcePaths); $resources = @()
        foreach ($row in @(Read-MsiRows $db 'SELECT `File`, `Component_`, `FileName`, `FileSize` FROM `File`' 4)) {
            $name = ($row.values[2].Split('|') | Select-Object -Last 1)
            if ($name -notin @('来源-1013v1.json', '安装说明.md')) { continue }
            if (-not $components.ContainsKey($row.values[1])) { throw 'MSI file has no component.' }
            $relative = (Resolve-MsiTargetDirectory $components[$row.values[1]] $directories) + '/' + $name
            if ($relative -cnotin $expected) { throw 'Unexpected MSI Unicode resource mapping.' }
            $source = Join-Path (Join-Path $SourceRoot 'Resources/SkillLibrary') $relative.Substring('skill-library/'.Length)
            $info = Get-Item -LiteralPath $source
            if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint -or $info.Length -ne [long]$row.values[3]) { throw 'MSI Unicode resource size/source mismatch.' }
            $resources += [pscustomobject]@{ relativePath=$relative; fileKey=$row.values[0]; fileName=$row.values[2]; sourceSize=$info.Length; sourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
        if ($resources.Count -ne 7 -or (@($resources.relativePath | Sort-Object -Unique).Count -ne 7) -or
            (Compare-Object -CaseSensitive $expected @($resources.relativePath))) { throw 'MSI Unicode resources missing or duplicated.' }
        return [pscustomobject]@{ schema=1; msiSha256=$before; databaseCodepage=$databaseCodepage; summaryCodepage=$summaryCodepage; productLanguage=$properties['ProductLanguage']; productCode=$properties['ProductCode']; productVersion=$properties['ProductVersion']; upgradeCode=$properties['UpgradeCode']; resources=$resources }
    } finally {
        foreach ($com in @($summary, $db, $engine)) { if ($null -ne $com) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) } }
        if ((Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $before) { throw 'MSI changed during read-only encoding verification.' }
    }
}
function Assert-MsiUnicodeResources($Evidence, [string]$InstallRoot) {
    $rows = @()
    foreach ($resource in $Evidence.resources) {
        if ($resource.relativePath -cnotin @(Get-MsiUnicodeResourcePaths)) { throw 'Unexpected installed Unicode resource path.' }
        $path = Join-Path $InstallRoot $resource.relativePath
        $cursor = $path
        while ($cursor.Length -gt $InstallRoot.Length) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installed Unicode resource is a reparse point.' }
            $cursor = Split-Path -Parent $cursor
        }
        $file = Get-Item -LiteralPath $path
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($file.Length -ne $resource.sourceSize -or $hash -cne $resource.sourceSha256) { throw 'Installed Unicode resource bytes differ from the source.' }
        $rows += [pscustomobject]@{ relativePath=$resource.relativePath; size=$file.Length; sha256=$hash }
    }
    if ($rows.Count -ne 7) { throw 'Installed Unicode resource coverage incomplete.' }
    return $rows
}
