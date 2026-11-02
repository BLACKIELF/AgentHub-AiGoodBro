#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:GITHUB_ENV) -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'This preparation step is only for a GitHub-hosted test runner.'
}

# PyPI release metadata pins this universal wheel by SHA256: https://pypi.org/pypi/tzdata/2026.6/json
$tzdataVersion = '2026.6'
$wheelUrl = 'https://files.pythonhosted.org/packages/0a/66/9a06c2227fedfd4919f0eaaa8b94377d9730882a7e4f95823c9a331ab5e1/tzdata-2026.6-py2.py3-none-any.whl'
$wheelSha256 = '0a10eec6e13ef16b627fabed9a5f2ba61a62b1c67f327305f4e7e412a70b4aec'
$tempDirectory = Join-Path $env:RUNNER_TEMP ('aigb-companion-tzdata-' + [guid]::NewGuid().ToString('N'))
$wheelPath = Join-Path $tempDirectory ('tzdata-' + $tzdataVersion + '-py2.py3-none-any.whl')
$pythonCommand = Get-Command python -CommandType Application -ErrorAction Stop
$pythonPath = [IO.Path]::GetFullPath($pythonCommand.Source)

try {
    New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri $wheelUrl -OutFile $wheelPath
    $actualHash = (Get-FileHash -LiteralPath $wheelPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $wheelSha256) {
        throw ('Pinned tzdata wheel SHA256 mismatch: ' + $actualHash)
    }

    & $pythonPath -m pip install --disable-pip-version-check --no-input --no-deps --no-index --force-reinstall $wheelPath
    if ($LASTEXITCODE -ne 0) { throw ('Pinned tzdata installation failed with exit code ' + $LASTEXITCODE) }

    $probe = "import importlib.metadata as metadata,sys; from zoneinfo import ZoneInfo; assert sys.version_info[:2] == (3,12); assert metadata.version('tzdata') == '$tzdataVersion'; ZoneInfo('Asia/Shanghai'); print(sys.executable)"
    $reportedPython = (& $pythonPath -I -B -c $probe | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($reportedPython)) {
        throw 'Pinned setup-python interpreter failed the isolated Asia/Shanghai timezone probe.'
    }

    [Environment]::SetEnvironmentVariable('AIGB_WINDOWS_COMPANION_TEST_PYTHON', $pythonPath, 'Process')
    [IO.File]::AppendAllText(
        $env:GITHUB_ENV,
        ('AIGB_WINDOWS_COMPANION_TEST_PYTHON=' + $pythonPath + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host ('Verified Companion test Python: ' + $pythonPath)
    Write-Host ('Verified tzdata ' + $tzdataVersion + ' wheel SHA256: ' + $actualHash)
}
finally {
    if (Test-Path -LiteralPath $tempDirectory -PathType Container) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}
