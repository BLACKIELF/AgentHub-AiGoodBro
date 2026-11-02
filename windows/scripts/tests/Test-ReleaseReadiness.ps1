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
$workspaceTestsEntry = Join-Path $root 'windows\scripts\Invoke-RustWorkspaceTests.ps1'
$companionTestPythonEntry = Join-Path $root 'windows\scripts\Prepare-CompanionTestPython.ps1'
$ciWorkflow = Join-Path $root '.github\workflows\ci.yml'
$releaseWindowsWorkflow = Join-Path $root '.github\workflows\release-windows.yml'
$releasePackagesWorkflow = Join-Path $root '.github\workflows\release-packages.yml'
& python -B (Join-Path $root 'tests\test_windows_branding.py')
if ($LASTEXITCODE -ne 0) { throw 'Windows branding or upgrade identity validation failed.' }
$null = Get-Command pwsh -CommandType Application -ErrorAction Stop
& python -B (Join-Path $root 'tests\test_windows_upgrade_fixture.py')
if ($LASTEXITCODE -ne 0) { throw 'Windows installer rollback fixture contracts failed.' }
& python -B (Join-Path $root 'tests\test_windows_msi_encoding.py')
if ($LASTEXITCODE -ne 0) { throw 'Windows MSI encoding contracts failed.' }
function Read-ScriptAst {
    param([string] $Path)
    $tokens = $null; $errors = $null
    $result = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Release entry point must parse in both PowerShell hosts.'
    return $result
}
$entryAst = Read-ScriptAst $entry
$packageAst = Read-ScriptAst $packageEntry
$workspaceTestsAst = Read-ScriptAst $workspaceTestsEntry
$null = Read-ScriptAst $companionTestPythonEntry
$null = Read-ScriptAst (Join-Path $root 'windows\scripts\Prepare-TokenMonitorResources.ps1')
$workspaceTestsSource = Get-Content -LiteralPath $workspaceTestsEntry -Raw -Encoding UTF8
$companionTestPythonSource = Get-Content -LiteralPath $companionTestPythonEntry -Raw -Encoding UTF8
$packageSource = Get-Content -LiteralPath $packageEntry -Raw -Encoding UTF8
$ciSource = Get-Content -LiteralPath $ciWorkflow -Raw -Encoding UTF8
$releaseWindowsSource = Get-Content -LiteralPath $releaseWindowsWorkflow -Raw -Encoding UTF8
$releasePackagesSource = Get-Content -LiteralPath $releasePackagesWorkflow -Raw -Encoding UTF8
Assert-True ($workspaceTestsSource.Contains('AIGB_WINDOWS_FAKECLI_PATH') -and $workspaceTestsSource.Contains('windows_fake_cli.exe') -and $workspaceTestsSource.Contains('build --locked -p codexu-core --example windows_fake_cli') -and $workspaceTestsSource.Contains('test --locked -p codexu-tauri $companionBridgeFilter -- --nocapture') -and $workspaceTestsSource.Contains('test --workspace --locked -- --skip $companionBridgeFilter')) 'The native workspace gate must build the Windows fake CLI, explicitly run the Companion bridge E2E once, and then run the remaining locked workspace.'
Assert-True ($packageSource.Contains('Invoke-RustWorkspaceTests.ps1') -and $ciSource.Contains('Invoke-RustWorkspaceTests.ps1')) 'CI and standalone Windows package validation must use the same native workspace gate.'
$expectedCompanionWheelName = '(''tzdata-'' + $tzdataVersion + ''-py2.py3-none-any.whl'')'
Assert-True ($companionTestPythonSource.Contains($expectedCompanionWheelName) -and $companionTestPythonSource.Contains('$tempDirectory = Join-Path $env:RUNNER_TEMP') -and $companionTestPythonSource.Contains('New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop') -and $companionTestPythonSource.Contains('Remove-Item -LiteralPath $tempDirectory -Recurse -Force') -and $companionTestPythonSource.Contains('0a10eec6e13ef16b627fabed9a5f2ba61a62b1c67f327305f4e7e412a70b4aec') -and $companionTestPythonSource.Contains('AIGB_WINDOWS_COMPANION_TEST_PYTHON') -and $companionTestPythonSource.Contains('ZoneInfo(''Asia/Shanghai'')')) 'The Companion test interpreter must use the fixed, hash-verified tzdata wheel with a pip-compatible filename in a private temporary directory that is cleaned, then pass the verified absolute Python path.'
Assert-True (-not $workspaceTestsSource.Contains('pip install') -and -not $workspaceTestsSource.Contains('Prepare-CompanionTestPython.ps1')) 'The ordinary workspace-test script must not install dependencies or access the network.'
$windowsRustJob = [regex]::Match($ciSource, '(?ms)^  windows-rust-format:\r?\n(?<body>.*?)(?=^  [A-Za-z0-9_-]+:\s*$|\z)')
Assert-True $windowsRustJob.Success 'The Windows Rust CI job must exist for source preparation ordering checks.'
$windowsRustJobSource = $windowsRustJob.Groups['body'].Value
$releaseWindowsJob = [regex]::Match($releaseWindowsSource, '(?ms)^  windows:\r?\n(?<body>.*?)(?=^  [A-Za-z0-9_-]+:\s*$|\z)')
$releasePackagesJob = [regex]::Match($releasePackagesSource, '(?ms)^  windows:\r?\n(?<body>.*?)(?=^  [A-Za-z0-9_-]+:\s*$|\z)')
Assert-True ($releaseWindowsJob.Success -and $releasePackagesJob.Success) 'Both Windows release workflows must expose their native jobs for test Python prerequisite checks.'
function Assert-CompanionTestPythonOrder {
    param([string] $Source, [string] $Gate, [string] $Name)
    $setup = $Source.IndexOf('actions/setup-python@v5', [StringComparison]::Ordinal)
    $version = $Source.IndexOf('python-version: "3.12"', [StringComparison]::Ordinal)
    $prepare = $Source.IndexOf('Prepare-CompanionTestPython.ps1', [StringComparison]::Ordinal)
    $gateIndex = $Source.IndexOf($Gate, [StringComparison]::Ordinal)
    Assert-True ($setup -ge 0 -and $version -gt $setup -and $prepare -gt $version -and $gateIndex -gt $prepare) ($Name + ' must prepare the pinned Python after setup-python and before its native gate.')
}
Assert-CompanionTestPythonOrder $windowsRustJobSource 'Invoke-RustWorkspaceTests.ps1' 'windows-rust-format'
Assert-CompanionTestPythonOrder $releaseWindowsJob.Groups['body'].Value 'Invoke-ReleaseReadiness.ps1' 'release-windows'
Assert-CompanionTestPythonOrder $releasePackagesJob.Groups['body'].Value 'build-windows-release.ps1' 'release-packages'
$companionBridgeFilter = 'windows_python_receiver_app_backend_routes_two_sessions_and_status_after_disconnect_does_not_repost'
$focusedBridgeGate = $workspaceTestsSource.IndexOf('test --locked -p codexu-tauri $companionBridgeFilter -- --nocapture', [StringComparison]::Ordinal)
$fullWorkspaceGate = $workspaceTestsSource.IndexOf('test --workspace --locked -- --skip $companionBridgeFilter', [StringComparison]::Ordinal)
Assert-True ($focusedBridgeGate -ge 0 -and $fullWorkspaceGate -gt $focusedBridgeGate -and $workspaceTestsSource.Contains($companionBridgeFilter)) 'The Windows Companion bridge E2E must use its frozen exact filter before the remaining workspace suite.'
$companionPrepareSteps = [regex]::Matches($windowsRustJobSource, '(?m)^      - name: Prepare the pinned Windows Companion Skill resources\s*$')
$ps51ContractStep = [regex]::Match($windowsRustJobSource, '(?m)^      - name: Test native visual script contracts with Windows PowerShell 5\.1\s*$')
$ps7ContractStep = [regex]::Match($windowsRustJobSource, '(?m)^      - name: Test native visual script contracts with PowerShell 7\s*$')
Assert-True ($companionPrepareSteps.Count -eq 1) 'The Windows Rust job must generate and verify its Companion payload only once.'
Assert-True ($ps51ContractStep.Success -and $ps7ContractStep.Success -and $companionPrepareSteps[0].Index -lt $ps51ContractStep.Index -and $companionPrepareSteps[0].Index -lt $ps7ContractStep.Index) 'Pinned Companion payloads must be prepared and verified before both PowerShell contract suites enumerate packaged resources.'
$companionGenerateCommands = [regex]::Matches($windowsRustJobSource, '(?m)^          python -B windows/companion/prepare\.py\s*$')
$companionVerifyCommands = [regex]::Matches($windowsRustJobSource, '(?m)^          python -B windows/companion/prepare\.py --verify-only\s*$')
Assert-True ($companionGenerateCommands.Count -eq 1 -and $companionVerifyCommands.Count -eq 1) 'The Windows Rust job must generate Companion resources once and verify that same payload.'
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
    Assert-True (@($plan | Where-Object { $_.name -like 'ps51:*' }).Count -eq 5) 'PowerShell 5.1 contract coverage incomplete.'
    Assert-True (@($plan | Where-Object { $_.name -like 'ps7:*' }).Count -eq 5) 'PowerShell 7 contract coverage incomplete.'
    $names = @($plan | ForEach-Object { $_.name })
    Assert-True ([array]::IndexOf($names, 'proxy-native-resources') -lt [array]::IndexOf($names, 'rust-tests')) 'The actual helper must be built and exercised before workspace validation.'
    Assert-True ('-RunNativeTests' -in $plan[[array]::IndexOf($names, 'proxy-native-resources')].arguments) 'Release validation omitted the real helper fixture tests.'
    Assert-True ([array]::IndexOf($names, 'token-monitor-native-resources') -lt [array]::IndexOf($names, 'rust-tests')) 'The real statistics resources must precede workspace validation.'
    Assert-True ('-RunNativeTests' -in $plan[[array]::IndexOf($names, 'token-monitor-native-resources')].arguments) 'Release validation omitted native statistics process tests.'
    Assert-True ([array]::IndexOf($names, 'provider-pool-native-resources') -lt [array]::IndexOf($names, 'rust-tests')) 'The pinned provider-pool resources must precede the real native Rust helper test.'
    Assert-True ('-RunNativeTests' -in $plan[[array]::IndexOf($names, 'provider-pool-native-resources')].arguments) 'Release validation omitted synthetic native provider tests.'
    Assert-True ([array]::IndexOf($names, 'hub-native-resources') -lt [array]::IndexOf($names, 'rust-tests')) 'The real Hub resources must precede workspace validation.'
    Assert-True ('-RunNativeTests' -in $plan[[array]::IndexOf($names, 'hub-native-resources')].arguments) 'Release validation omitted native Hub execution.'
    $companionPrepare = [array]::IndexOf($names, 'companion-setup-resources')
    $companionVerify = [array]::IndexOf($names, 'companion-setup-verify')
    $executionInterop = [array]::IndexOf($names, 'rust-go-execution-interop')
    $rustTests = [array]::IndexOf($names, 'rust-tests')
    $ps51ReadinessTest = [array]::IndexOf($names, 'ps51:Test-ReleaseReadiness.ps1')
    $ps7ReadinessTest = [array]::IndexOf($names, 'ps7:Test-ReleaseReadiness.ps1')
    Assert-True ($companionPrepare -ge 0 -and $companionPrepare -lt $companionVerify -and $companionVerify -lt $ps51ReadinessTest -and $companionVerify -lt $ps7ReadinessTest) 'Pinned Companion payloads must be prepared and verified before readiness tests enumerate packaged resources.'
    Assert-True ($companionVerify -lt $executionInterop -and $executionInterop -lt $rustTests) 'Rust-to-Go execution interop must run after Companion resource preparation and before workspace validation.'
    Assert-True ($plan[$executionInterop].executable -eq 'python' -and $plan[$executionInterop].arguments[1] -eq (Join-Path $root 'windows\scripts\test_windows_execution_interop.py')) 'The tagged Go test must use the explicit Rust-generated fixture script.'
    Assert-True ($companionVerify -lt $rustTests) 'Pinned Companion payloads must be verified before Rust validation.'
    Assert-True ($plan[$rustTests].executable -eq 'pwsh.exe' -and $plan[$rustTests].arguments[5] -eq $workspaceTestsEntry -and $plan[$rustTests].arguments[7] -eq '1.97.1-x86_64-pc-windows-msvc') 'Release readiness must run the shared Windows fake CLI gate with the pinned toolchain.'
    Assert-True ($plan[$companionPrepare].executable -eq 'python' -and $plan[$companionPrepare].arguments[1] -eq (Join-Path $root 'windows\companion\prepare.py')) 'Companion preparation must use the fixed native payload source.'
    Assert-True ('--verify-only' -in $plan[$companionVerify].arguments) 'Companion readback verification is required.'
    Assert-True ([array]::IndexOf($names, 'visual-baseline') -lt [array]::IndexOf($names, 'visual-repeat')) 'Visual verification must follow baseline creation.'
    Assert-True ($names[-1] -eq 'package') 'Packages must follow successful verification.'
    $reuseIndex = [array]::IndexOf($plan[-1].arguments, '-VerifiedScannerBuildRoot')
    Assert-True ($reuseIndex -ge 0 -and $plan[-1].arguments[$reuseIndex + 1] -eq (Join-Path $fixture 'token-monitor-build\scanner')) 'Packaging must reuse this run''s native-tested scanner, not rebuild a different binary.'
    $poolReuseIndex = [array]::IndexOf($plan[-1].arguments, '-VerifiedProviderPoolBuildRoot')
    Assert-True ($poolReuseIndex -ge 0 -and $plan[-1].arguments[$poolReuseIndex + 1] -eq (Join-Path $fixture 'provider-pool-build')) 'Packaging must reuse this run''s native-tested provider helper.'
    $hubReuseIndex = [array]::IndexOf($plan[-1].arguments, '-VerifiedHubBuildRoot')
    Assert-True ($hubReuseIndex -ge 0 -and $plan[-1].arguments[$hubReuseIndex + 1] -eq (Join-Path $fixture 'hub-build')) 'Packaging must reuse this run''s native-tested Hub.'
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
    $files = @("AiGoodBro-$version-windows-x86_64.msi", "AiGoodBro-$version-windows-x86_64-setup.exe")
    foreach ($name in $files) {
        $path = Join-Path $fixture $name
        [IO.File]::WriteAllText($path, 'synthetic installer fixture, not executable')
        $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText(($path + '.sha256'), "$sha  $name`n")
    }
    @{ product = 'AiGoodBro'; version = $version; target = 'windows-x86_64'; installers = $files } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'manifest.json') -Encoding UTF8
    $evidence = @(Get-ReleasePackageEvidence -Directory $fixture -ReleaseVersion $version)
    Assert-True ($evidence.Count -eq 2 -and $evidence[0].sha256 -match '^[0-9a-f]{64}$') 'Installer evidence must include both hashes.'
    $manifestPath = Join-Path $fixture 'manifest.json'
    $brandedManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
    $legacyManifest = $brandedManifest | ConvertFrom-Json
    $legacyManifest.product = 'Codex Account Manager Next'
    $legacyManifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $rejected = $false
    try { Get-ReleasePackageEvidence -Directory $fixture -ReleaseVersion $version | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Legacy internal product metadata was accepted under renamed AiGoodBro files.'
    $brandedManifest | Set-Content -LiteralPath $manifestPath -Encoding UTF8
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
    $legacy = [pscustomobject]@{ Name = 'Codex Account Manager Next_9.6.9_x64_en-US.msi'; LastWriteTimeUtc = $start.AddSeconds(4) }
    Assert-True ($null -eq (Select-FreshBundle -Files @($legacy) -ReleaseVersion $version -StartedUtc $start)) 'A legacy-branded bundle was accepted as AiGoodBro.'
    Assert-True ($null -eq (Select-FreshBundle -Files @($old, $wrong, $arm) -ReleaseVersion $version -StartedUtc $start)) 'Stale, wrong-version or wrong-architecture package was selected.'
    Assert-True ((Select-FreshBundle -Files @($old, $wrong, $arm, $fresh) -ReleaseVersion $version -StartedUtc $start).LastWriteTimeUtc -eq $fresh.LastWriteTimeUtc) 'The current matching bundle was not selected.'
} finally {
    [IO.Directory]::Delete($fixture, $true)
}
Write-Host 'PASS: release readiness ordering, two hosts, fail-fast reports, hashes and fresh bundle selection.'
