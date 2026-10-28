#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$scriptPath = Join-Path $root 'windows\apps\codexu-tauri\src-tauri\src\commands\app_update.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'Update transport must parse in this PowerShell host.'
$endpoint = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-Endpoint'
}, $true)
Assert-True ($null -ne $endpoint) 'Production endpoint validation is missing.'
Invoke-Expression $endpoint.Extent.Text
$initial = 'https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v3.0.0/package.exe'
Assert-True (Test-Endpoint $initial $false $initial) 'The fixed initial HTTPS release endpoint was rejected.'
Assert-True (Test-Endpoint 'https://release-assets.githubusercontent.com/github-production-release-asset-2e65be/1/asset?signature=synthetic' $true $initial) 'The GitHub asset redirect was rejected.'
foreach ($url in @('http://github.com/asset', 'https://evil.invalid/asset', 'https://release-assets.githubusercontent.com/not-a-release', 'https://user@release-assets.githubusercontent.com/github-production-release-asset-test', 'https://release-assets.githubusercontent.com:8443/github-production-release-asset-test')) {
    Assert-True (-not (Test-Endpoint $url $true $initial)) 'An unrelated or non-HTTPS redirect was accepted.'
}
$fixture = Join-Path $root ('.local-artifacts\update-transport-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$hostBinary = (Get-Process -Id $PID).Path
try {
    # Each request is rejected before HttpClient is constructed. No real
    # download, account lookup, external message or installer is invoked.
    $cases = @(
        @{ url = 'http://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v3.0.0/pkg.exe'; maximum_bytes = 128 },
        @{ url = 'https://evil.invalid/pkg.exe'; maximum_bytes = 128 },
        @{ url = 'https://github.com/OTHER/repo/releases/download/v3.0.0/pkg.exe'; maximum_bytes = 128 },
        @{ url = ($initial + '?redirect=1'); maximum_bytes = 128 },
        @{ url = ($initial + '#fragment'); maximum_bytes = 128 },
        @{ url = $initial; maximum_bytes = 0 },
        @{ url = $initial; maximum_bytes = 1073741825 },
        @{ url = 'https://api.github.com/repos/BLACKIELF/AgentHub-AiGoodBro/releases/latest'; maximum_bytes = 128; output_path = (Join-Path $fixture 'api.json') }
    )
    foreach ($case in $cases) {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $hostBinary
        $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        try {
            Assert-True ($process.Start()) 'Could not start the isolated transport process.'
            $out = $process.StandardOutput.ReadToEndAsync()
            $err = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.Write(($case | ConvertTo-Json -Compress))
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(10000)) {
                $process.Kill()
                $null = $process.WaitForExit(5000)
                throw 'An invalid request reached a slow transport path.'
            }
            Assert-True ($process.ExitCode -eq 1) 'Invalid transport input did not fail closed.'
            Assert-True ($out.Result.Length -eq 0 -and $err.Result -eq 'update_transport_failed') 'Transport errors leaked private input or fabricated success.'
        } finally { $process.Dispose() }
    }
    Assert-True (@(Get-ChildItem -LiteralPath $fixture -Force).Count -eq 0) 'Rejected requests unexpectedly created a file.'
} finally { [IO.Directory]::Delete($fixture, $true) }
Write-Host 'PASS: update transport syntax, redirect allowlist and isolated invalid-input rejection.'
