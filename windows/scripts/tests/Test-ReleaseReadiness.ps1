#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$entry = Join-Path $root 'windows\scripts\Invoke-ReleaseReadiness.ps1'
$packageEntry = Join-Path $root 'scripts\build-windows-release.ps1'
function Read-ScriptAst {
    param([string] $Path)
    $tokens = $null; $errors = $null
    $result = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Release entry point must parse in both PowerShell hosts.'
    return $result
}
$entryAst = Read-ScriptAst $entry
$packageAst = Read-ScriptAst $packageEntry
function Import-TestedFunction {
    param($Ast, [string] $Name)
    $definition = $Ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }.GetNewClosure(), $true)
    Assert-True ($null -ne $definition) ('Missing tested function: ' + $Name)
    Invoke-Expression $definition.Extent.Text
}
. Import-TestedFunction $entryAst 'Get-ReleaseReadinessPlan'
. Import-TestedFunction $entryAst 'Save-ReadinessReport'
. Import-TestedFunction $entryAst 'Invoke-ReleaseStep'
. Import-TestedFunction $entryAst 'Invoke-ReleasePlan'
. Import-TestedFunction $entryAst 'Get-ReleasePackageEvidence'
. Import-TestedFunction $packageAst 'Select-FreshBundle'

$fixture = Join-Path $root ('.local-artifacts\release-readiness-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    # Test persistence directly, so failures before the second synthetic step
    # cannot be misdiagnosed as executing beyond that step.
    $replacePath = Join-Path $fixture 'replace-report.json'
    $replaceReport = [ordered]@{ generation = 1 }
    Save-ReadinessReport -Report $replaceReport -Path $replacePath
    foreach ($generation in @(2, 3)) {
        $replaceReport.generation = $generation
        Save-ReadinessReport -Report $replaceReport -Path $replacePath
        $readBack = Get-Content -LiteralPath $replacePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($readBack.generation -eq $generation) 'Atomic report replacement did not preserve the new generation.'
    }
    # Windows wildcard filtering can match the report itself for a trailing .*.
    $replaceResidualPattern = '^replace-report\.json\.[0-9a-f]{32}\.(tmp|bak)$'
    $replaceLeftovers = @(Get-ChildItem -LiteralPath $fixture -File | Where-Object { $_.Name -match $replaceResidualPattern })
    Assert-True ($replaceLeftovers.Count -eq 0) ('Successful report replacement left temporary or backup files: ' + (@($replaceLeftovers | ForEach-Object { $_.Name }) -join ', '))
    $syntheticLeftoverName = 'replace-report.json.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $syntheticLeftoverPath = Join-Path $fixture $syntheticLeftoverName
    [IO.File]::WriteAllText($syntheticLeftoverPath, 'synthetic residual fixture')
    $replaceLeftovers = @(Get-ChildItem -LiteralPath $fixture -File | Where-Object { $_.Name -match $replaceResidualPattern })
    Assert-True ($replaceLeftovers.Count -eq 1 -and $replaceLeftovers[0].Name -eq $syntheticLeftoverName) ('Residual detection missed its synthetic file or included the report: ' + (@($replaceLeftovers | ForEach-Object { $_.Name }) -join ', '))
    [IO.File]::Delete($syntheticLeftoverPath)
    $replaceLeftovers = @(Get-ChildItem -LiteralPath $fixture -File | Where-Object { $_.Name -match $replaceResidualPattern })
    Assert-True ($replaceLeftovers.Count -eq 0) ('Residual detection did not return to empty after fixture cleanup: ' + (@($replaceLeftovers | ForEach-Object { $_.Name }) -join ', '))

    $plan = @(Get-ReleaseReadinessPlan -Root $root -ReleaseVersion '9.6.9' -Output $fixture -Preflight (Join-Path $fixture 'preflight.json') -PowerShell51 'powershell.exe' -PowerShell7 'pwsh.exe' -Package $true)
    Assert-True ($plan[0].name -eq 'native-preflight' -and '-PreflightOnly' -in $plan[0].arguments) 'Default native step must only preflight.'
    Assert-True (@($plan | Where-Object { $_.name -like 'ps51:*' }).Count -eq 4) 'PowerShell 5.1 contract coverage incomplete.'
    Assert-True (@($plan | Where-Object { $_.name -like 'ps7:*' }).Count -eq 4) 'PowerShell 7 contract coverage incomplete.'
    $names = @($plan | ForEach-Object { $_.name })
    Assert-True ([array]::IndexOf($names, 'visual-baseline') -lt [array]::IndexOf($names, 'visual-repeat')) 'Visual verification must follow baseline creation.'
    Assert-True ($names[-1] -eq 'package') 'Packages must follow successful verification.'
    Assert-True ('--update-snapshots' -notin $plan[[array]::IndexOf($names, 'visual-repeat')].arguments) 'The second visual run must compare the existing baseline.'
    $withoutPackage = @(Get-ReleaseReadinessPlan -Root $root -ReleaseVersion '9.6.9' -Output $fixture -Preflight 'synthetic.json' -PowerShell51 'powershell.exe' -PowerShell7 'pwsh.exe' -Package $false)
    Assert-True (@($withoutPackage | Where-Object { $_.name -eq 'package' }).Count -eq 0) 'SkipPackaging still ran packaging.'
    foreach ($step in $plan) {
        Assert-True ($step.executable -notmatch '(taskkill|msiexec|Stop-Process)') 'Readiness must not kill existing apps or install finished packages.'
        Assert-True ('login' -notin $step.arguments -and 'logout' -notin $step.arguments) 'Readiness must not alter login.'
    }

    $shortPlan = @(
        @{ name = 'first'; executable = 'synthetic'; arguments = @(); directory = $fixture },
        @{ name = 'second'; executable = 'synthetic'; arguments = @(); directory = $fixture },
        @{ name = 'never-after-failure'; executable = 'synthetic'; arguments = @(); directory = $fixture }
    )
    $report = [ordered]@{ steps = [Collections.Generic.List[object]]::new() }
    $reportPath = Join-Path $fixture 'report.json'
    $runner = { param($step) if ($step.name -eq 'second') { return [int]23 }; return [int]0 }
    $failed = $false
    $failureDiagnostic = 'none'
    try { Invoke-ReleasePlan -Plan $shortPlan -Report $report -ReportPath $reportPath -Runner $runner }
    catch { $failed = $true; $failureDiagnostic = $_.Exception.GetType().FullName + ': ' + $_.Exception.Message }
    Assert-True $failed 'A failed child process did not stop the release plan.'
    $stepDiagnostic = @($report.steps | ForEach-Object { $_.name + ':' + $_.status + ':exit=' + $_.exit_code }) -join ', '
    Assert-True ($report.steps.Count -eq 2) ('Expected exactly first and second step records; actual count=' + $report.steps.Count + '; records=[' + $stepDiagnostic + ']; caught=' + $failureDiagnostic)
    Assert-True ($report.steps[0].status -eq 'passed' -and $report.steps[1].status -eq 'failed') 'Step outcomes were not recorded honestly.'
    $saved = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($saved.steps[1].exit_code -eq 23 -and $null -ne $saved.steps[1].finished_utc) 'Actual failure code/timing missing from durable report.'
    $report = [ordered]@{ steps = [Collections.Generic.List[object]]::new() }
    try { Invoke-ReleasePlan -Plan $shortPlan -Report $report -ReportPath $reportPath -Runner { param($step) throw 'synthetic launch failure' } } catch {}
    Assert-True ($report.steps.Count -eq 1 -and $null -eq $report.steps[0].exit_code -and $report.steps[0].status -eq 'failed') 'Launch failure must not become a fabricated exit code or pass.'

    $version = '9.6.9'
    $files = @("CodexAccountManagerNext-$version-windows-x86_64.msi", "CodexAccountManagerNext-$version-windows-x86_64-setup.exe")
    foreach ($name in $files) {
        $path = Join-Path $fixture $name
        [IO.File]::WriteAllText($path, 'synthetic installer fixture, not executable')
        $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText(($path + '.sha256'), "$sha  $name`n")
    }
    @{ version = $version; target = 'windows-x86_64'; installers = $files } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'manifest.json') -Encoding UTF8
    $evidence = @(Get-ReleasePackageEvidence -Directory $fixture -ReleaseVersion $version)
    Assert-True ($evidence.Count -eq 2 -and $evidence[0].sha256 -match '^[0-9a-f]{64}$') 'Installer evidence must include both hashes.'
    [IO.File]::AppendAllText((Join-Path $fixture $files[0]), 'tampered')
    $rejected = $false
    try { Get-ReleasePackageEvidence -Directory $fixture -ReleaseVersion $version | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Tampered installer content passed its checksum.'
    $rejected = $false
    try { Get-ReleasePackageEvidence -Directory $fixture -ReleaseVersion '9.6.8' | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Another release version was accepted.'

    $start = [DateTime]::UtcNow
    $old = [pscustomobject]@{ Name = 'AiGoodBro_9.6.9_x64_en-US.msi'; LastWriteTimeUtc = $start.AddSeconds(-1) }
    $wrong = [pscustomobject]@{ Name = 'AiGoodBro_9.6.8_x64_en-US.msi'; LastWriteTimeUtc = $start.AddSeconds(2) }
    $arm = [pscustomobject]@{ Name = 'AiGoodBro_9.6.9_arm64_en-US.msi'; LastWriteTimeUtc = $start.AddSeconds(3) }
    $fresh = [pscustomobject]@{ Name = 'AiGoodBro_9.6.9_x64_en-US.msi'; LastWriteTimeUtc = $start.AddSeconds(1) }
    Assert-True ($null -eq (Select-FreshBundle -Files @($old, $wrong, $arm) -ReleaseVersion $version -StartedUtc $start)) 'Stale, wrong-version or wrong-architecture package was selected.'
    Assert-True ((Select-FreshBundle -Files @($old, $wrong, $arm, $fresh) -ReleaseVersion $version -StartedUtc $start).LastWriteTimeUtc -eq $fresh.LastWriteTimeUtc) 'The current matching bundle was not selected.'
} finally {
    [IO.Directory]::Delete($fixture, $true)
}
Write-Host 'PASS: release readiness ordering, two hosts, fail-fast reports, hashes and fresh bundle selection.'
