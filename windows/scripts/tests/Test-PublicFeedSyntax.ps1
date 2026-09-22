$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../../apps/codexu-tauri/src-tauri/src/commands/public_feed.ps1'
$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path).Path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Public-feed script has $($parseErrors.Count) syntax errors" }
Write-Host 'Public-feed script parses successfully.'
