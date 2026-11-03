#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $BuildRoot,
    [switch] $RunNativeTests,
    [switch] $VerifiedReuse,
    [switch] $AllowDependencyDownload
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'windows_required' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not [IO.Path]::IsPathRooted($BuildRoot)) { throw 'Choose an absolute task-owned build directory.' }
if ($RunNativeTests -and $VerifiedReuse) { throw 'Select native validation or verified reuse.' }
$arguments = @('-B', (Join-Path $root 'windows\provider-pool\prepare.py'), '--build-root', [IO.Path]::GetFullPath($BuildRoot))
if ($RunNativeTests) { $arguments += '--run-native-tests' }
if ($VerifiedReuse) { $arguments += @('--verify-only', '--require-native') }
if ($AllowDependencyDownload) { $arguments += '--allow-dependency-download' }
& python -B -m unittest discover -s (Join-Path $root 'windows\provider-pool') -p 'test_*.py' -v
if ($LASTEXITCODE -ne 0) { throw 'provider_pool_resource_tests_failed' }
& python @arguments
if ($LASTEXITCODE -ne 0) { throw 'provider_pool_resource_prepare_failed' }
