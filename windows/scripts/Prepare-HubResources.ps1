#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BuildRoot,
    [switch] $RunNativeTests,
    [switch] $VerifiedReuse
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'windows_required' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not [IO.Path]::IsPathRooted($BuildRoot)) { throw 'Choose an absolute task-owned build directory.' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$arguments = @('-B', (Join-Path $root 'windows\hub\prepare.py'), '--build-root', $BuildRoot)
if ($RunNativeTests -and $VerifiedReuse) { throw 'Select native validation or verified reuse.' }
if ($RunNativeTests) { $arguments += '--run-native-tests' }
if ($VerifiedReuse) { $arguments += @('--verify-only', '--require-native') }
& python -B -m unittest discover -s (Join-Path $root 'windows\hub') -p 'test_*.py' -v
if ($LASTEXITCODE -ne 0) { throw 'hub_resource_tests_failed' }
& python @arguments
if ($LASTEXITCODE -ne 0) { throw 'hub_resource_prepare_failed' }
