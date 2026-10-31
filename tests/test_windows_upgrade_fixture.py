"""Exercise the actual synthetic deferred MSI script without installing anything.

This is a host check of failure-injection evidence only. Windows Installer,
PowerShell path normalization, shortcut rollback and upgrade remain native gates.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "windows/scripts/Test-InstallerUpgrade.ps1"


class RollbackSequenceTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("pwsh"), "Actual PowerShell selector requires pwsh; the same contract runs in the native upgrade job.")
    def test_actual_sequence_selector_contract(self):
        source = SCRIPT.read_text(encoding="utf-8")
        matches = re.findall(
            r"(function Select-RollbackSequenceSlots\b.*?\nTest-RollbackSequenceContract)\nfunction Get-RollbackTransformPath",
            source, re.S)
        self.assertEqual(len(matches), 1)
        # Execute the real selector and its occupied/sparse/exhausted/boundary
        # cases, without the installer's host guard, COM or install operations.
        command = "$ErrorActionPreference = 'Stop'\nSet-StrictMode -Version Latest\n" \
            + matches[0] + "\nWrite-Output 'rollback-sequence-contract-pass'\n"
        result = subprocess.run(
            [shutil.which("pwsh"), "-NoProfile", "-NonInteractive", "-Command", command],
            capture_output=True, text=True, check=True)
        self.assertIn("rollback-sequence-contract-pass", result.stdout)


class RollbackTransformOutputTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "Actual Windows Installer COM requires Windows; no installation is performed.")
    def test_actual_com_single_path_and_original_helper_negative_control(self):
        pwsh = shutil.which("pwsh")
        self.assertIsNotNone(pwsh, "Windows native contract must not skip when pwsh is missing")
        # Execute the real helper against a tiny MSI database, without invoking
        # msiexec. The negative control restores only the five pre-fix output
        # sites: 11 COM method calls at runtime, followed by the intended path.
        harness = r'''
param([string]$SourceScript, [string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This contract requires real Windows Installer COM.' }
$source = [IO.File]::ReadAllText($SourceScript)
function Extract-One([string]$Pattern) {
    $matches = [regex]::Matches($source, $Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($matches.Count -ne 1) { throw 'Expected one original helper definition.' }
    return $matches[0].Groups[1].Value
}
. ([scriptblock]::Create((Extract-One '(function Owned-Path\b.*?\n})\n\$oldRoot')))
. ([scriptblock]::Create((Extract-One '(function Hash-File\([^\n]+)\n')))
. ([scriptblock]::Create((Extract-One '(function Select-RollbackSequenceSlots\b.*?\n})\nfunction Test-RollbackSequenceContract')))
$helper = Extract-One '(function Get-RollbackTransformPath\b.*?\n})\nfunction Assert-ForeignShortcuts'
. ([scriptblock]::Create($helper))
$runnerRoot = [IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\') + '\'
$newFile = Owned-Path (Join-Path $runnerRoot 'synthetic-input.msi')
$engine = $null; $database = $null; $summary = $null
try {
    $engine = New-Object -ComObject WindowsInstaller.Installer
    $database = $engine.OpenDatabase($newFile, 3)
    function Sql([string]$Query) {
        $view = $database.OpenView($Query)
        try { [void]$view.Execute() }
        finally { [void]$view.Close(); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
    }
    Sql 'CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(0) LOCALIZABLE PRIMARY KEY `Property`)'
    Sql 'CREATE TABLE `CustomAction` (`Action` CHAR(72) NOT NULL, `Type` SHORT NOT NULL, `Source` CHAR(72), `Target` CHAR(0) LOCALIZABLE PRIMARY KEY `Action`)'
    Sql 'CREATE TABLE `InstallExecuteSequence` (`Action` CHAR(72) NOT NULL, `Condition` CHAR(255), `Sequence` SHORT PRIMARY KEY `Action`)'
    Sql "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('ProductCode', '{AB63E399-A4C4-44B4-90C5-E2000AFCB729}')"
    Sql "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('UpgradeCode', '{6405DB26-69D4-49EE-8638-E97A1F794138}')"
    Sql "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('ProductVersion', '3.0.0')"
    Sql "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('ProductLanguage', '1033')"
    Sql "INSERT INTO ``CustomAction`` (``Action``, ``Type``, ``Source``, ``Target``) VALUES ('FixtureExisting', 51, 'FixtureMarker', 'never-executed')"
    Sql "INSERT INTO ``InstallExecuteSequence`` (``Action``, ``Condition``, ``Sequence``) VALUES ('RemoveFiles', '', 3500)"
    Sql "INSERT INTO ``InstallExecuteSequence`` (``Action``, ``Condition``, ``Sequence``) VALUES ('FixtureExisting', '0', 6599)"
    Sql "INSERT INTO ``InstallExecuteSequence`` (``Action``, ``Condition``, ``Sequence``) VALUES ('InstallFinalize', '', 6600)"
    $summary = $database.SummaryInformation(4)
    $summary.Property(7) = 'Intel;1033'
    $summary.Property(9) = '{A5DBB17D-AF89-4EE9-8B16-C415AD9A04A6}'
    $summary.Property(14) = 200
    $summary.Property(15) = 0
    [void]$summary.Persist()
    [void]$database.Commit()
} finally {
    foreach ($com in @($summary, $database, $engine)) {
        if ($null -ne $com) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) }
    }
}
$newHash = Hash-File $newFile
$paths = @((Join-Path $runnerRoot 'desktop-old.lnk'), (Join-Path $runnerRoot 'programs-old.lnk'))
$output = Owned-Path (Join-Path $runnerRoot 'fixed')
[void][IO.Directory]::CreateDirectory($output)
$expected = Owned-Path (Join-Path $output 'shortcut-rollback.mst')
$fixed = @(New-RollbackTransform $paths)
$path = Get-RollbackTransformPath -Values $fixed -Expected $expected
if ($path -cne $expected -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -le 0) { throw 'Fixed COM helper did not produce exactly its real MST path.' }
if ((Hash-File $newFile) -cne $newHash) { throw 'Original MSI changed.' }
function Assert-Rejected([object[]]$Values, [string]$Expected) {
    $rejected = $false
    try { $null = Get-RollbackTransformPath -Values $Values -Expected $Expected } catch { $rejected = $true }
    if (-not $rejected) { throw 'Incidental output was accepted as a transform path.' }
}
Assert-Rejected -Values @() -Expected $expected
Assert-Rejected -Values @($null, $expected) -Expected $expected
Assert-Rejected -Values @([DBNull]::Value, $expected) -Expected $expected
Assert-Rejected -Values @(0, $expected) -Expected $expected
Assert-Rejected -Values @($true, $expected) -Expected $expected
Assert-Rejected -Values @('           ' + $expected) -Expected $expected
Assert-Rejected -Values @([pscustomobject]@{ path=$expected }) -Expected $expected
Write-Output 'PASS: actual COM rollback helper single-path output and 7 polluted-output rejections'
$legacy = $helper
foreach ($expression in @('$view.Execute($record)', '$view.Execute()', '$view.Close()', '$changed.Commit()')) {
    $legacy = $legacy.Replace('[void]' + $expression, $expression)
}
if ($legacy -ceq $helper) { throw 'Original-helper negative control was not restored.' }
. ([scriptblock]::Create($legacy))
$output = Owned-Path (Join-Path $runnerRoot 'original-negative-control')
[void][IO.Directory]::CreateDirectory($output)
$expected = Owned-Path (Join-Path $output 'shortcut-rollback.mst')
$originalOutput = @(New-RollbackTransform $paths)
if ($originalOutput.Count -ne 12 -or [string]$originalOutput -cne ('           ' + $expected)) { throw 'Original COM output did not reproduce the 11 leading spaces from run 346.' }
Assert-Rejected -Values $originalOutput -Expected $expected
if ((Hash-File $newFile) -cne $newHash) { throw 'Negative control changed the original MSI.' }
if (@(Get-ChildItem -LiteralPath $runnerRoot -Filter 'aigoodbro-rollback-*.msi').Count -ne 0) { throw 'Temporary transform copy was not released and removed.' }
Write-Output 'PASS: original COM helper reproduces 11 empty outputs; strict path guard rejects it'
'''
        with tempfile.TemporaryDirectory(prefix="aigoodbro-com-output-") as directory:
            path = Path(directory) / "contract.ps1"
            path.write_text(harness, encoding="utf-8")
            result = subprocess.run(
                [pwsh, "-NoProfile", "-NonInteractive", "-File", str(path),
                 "-SourceScript", str(SCRIPT), "-FixtureRoot", directory],
                capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + "\n" + result.stderr)
            self.assertIn("PASS: actual COM rollback helper single-path output", result.stdout)
            self.assertIn("PASS: original COM helper reproduces 11 empty outputs", result.stdout)
            print(result.stdout, end="")


class RollbackExecutionProofTests(unittest.TestCase):
    def run_script(self, data, existing=(), create_error=False):
        source = SCRIPT.read_text(encoding="utf-8")
        matches = re.findall(r"\$failureScript = @'\n(.*?)\n'@", source, re.S)
        self.assertEqual(len(matches), 1)
        fixture = {"source": matches[0], "data": data,
                   "existing": list(existing), "createError": create_error}
        harness = r"""
const vm = require('node:vm');
const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const writes = [], reads = [];
function ActiveXObject(name) {
  if (name !== 'Scripting.FileSystemObject') throw Error('unexpected COM');
  return {
    FileExists(path) { reads.push(path); return input.existing.includes(path); },
    CreateTextFile(path, overwrite, unicode) {
      if (overwrite !== false || unicode !== false) throw Error('unsafe proof open');
      if (input.createError || input.existing.includes(path)) throw Error('proof unavailable');
      const entry = {path, content: '', closed: false}; writes.push(entry);
      return {WriteLine(value) {entry.content += value + '\r\n';},
              Close() {entry.closed = true;}};
    }
  };
}
let error;
try { vm.runInNewContext(input.source, {
  ActiveXObject,
  Session: {Property(name) {
    if (name !== 'CustomActionData') throw Error('unexpected property');
    return input.data;
  }}
}); } catch(e) { error = String(e.message); }
process.stdout.write(JSON.stringify({error, writes, reads}));
"""
        result = subprocess.run(["node", "-e", harness], input=json.dumps(fixture),
                                capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_failure_marker_and_non_overwritten_proof_follow_two_absent_links(self):
        result = self.run_script("C:\\desktop\\old.lnk|C:\\programs\\old.lnk|C:\\task\\proof.txt")
        marker = "AIGOODBRO_SYNTHETIC_ROLLBACK_AFTER_OWNED_LINK_REMOVAL"
        self.assertEqual(result["error"], marker)
        self.assertEqual(result["reads"], ["C:\\desktop\\old.lnk", "C:\\programs\\old.lnk"])
        self.assertEqual(result["writes"], [{"path": "C:\\task\\proof.txt",
                                             "content": marker + "\r\n", "closed": True}])

    def test_either_remaining_link_cannot_emit_success_evidence(self):
        for remaining in ["C:\\desktop\\old.lnk", "C:\\programs\\old.lnk"]:
            with self.subTest(remaining=remaining):
                result = self.run_script("C:\\desktop\\old.lnk|C:\\programs\\old.lnk|C:\\task\\proof.txt", [remaining])
                self.assertEqual(result["error"], "Owned legacy shortcut was not removed")
                self.assertEqual(result["writes"], [])

    def test_malformed_binding_cannot_emit_success_evidence(self):
        for data in ["", "one|two", "same|same|proof", "one|two|", "|two|proof"]:
            with self.subTest(data=data):
                result = self.run_script(data)
                self.assertNotEqual(result["error"], "AIGOODBRO_SYNTHETIC_ROLLBACK_AFTER_OWNED_LINK_REMOVAL")
                self.assertEqual(result["writes"], [])

    def test_existing_or_unwritable_proof_cannot_be_reused(self):
        data = "C:\\desktop\\old.lnk|C:\\programs\\old.lnk|C:\\task\\proof.txt"
        for existing, create_error in [(["C:\\task\\proof.txt"], False), ([], True)]:
            result = self.run_script(data, existing, create_error)
            self.assertEqual(result["error"], "proof unavailable")
            self.assertEqual(result["writes"], [])


if __name__ == "__main__":
    unittest.main()
