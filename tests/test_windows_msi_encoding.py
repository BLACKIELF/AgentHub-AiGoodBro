"""Encoding regressions; Windows additionally exercises real MSI COM, no install."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("msi_encoding", ROOT / "windows/scripts/check-msi-encoding.py")
encoding = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(encoding)


class MsiEncodingTests(unittest.TestCase):
    def test_actual_source_names_and_separate_codepages(self):
        result = encoding.check_inputs(ROOT, source_only=True)
        self.assertEqual(result["databaseCodepage"], 936)
        self.assertEqual(result["summaryCodepage"], 1252)
        self.assertEqual(len(result["nonCp1252Resources"]), 7)
        for path in result["nonCp1252Resources"]:
            with self.assertRaises(UnicodeEncodeError):
                path.encode("cp1252")

    def test_unsupported_unicode_is_not_replaced(self):
        for value in ("安装说明.md", "来源-1013v1.json", "AiGoodBro", "C:/fixture/English"):
            encoding.check_text(value, "fixture")
        for value in ("unsupported-😀.md", "nul\0name"):
            with self.assertRaises(ValueError):
                encoding.check_text(value, "fixture")

    def test_all_resources_must_exist_in_release_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tauri = root / "windows/apps/codexu-tauri/src-tauri"
            tauri.mkdir(parents=True)
            original = ROOT / "windows/apps/codexu-tauri/src-tauri"
            for name in ("tauri.conf.json", "tauri.windows.conf.json", "Cargo.toml"):
                shutil.copyfile(original / name, tauri / name)
            shutil.copytree(original / "installer", tauri / "installer")
            shutil.copytree(ROOT / "Resources/SkillLibrary", root / "Resources/SkillLibrary")
            with self.assertRaisesRegex(ValueError, "directory missing"):
                encoding.check_inputs(root)
            for name in ("proxy", "token-monitor", "companion-hub", "provider-pool"):
                folder = tauri / "resources" / name
                folder.mkdir(parents=True)
                (folder / "synthetic.txt").write_text("not a native payload")
            self.assertEqual(encoding.check_inputs(root)["resourceFiles"], 28)
            (folder / "unsupported-😀.txt").write_text("fixture")
            with self.assertRaisesRegex(ValueError, "CP936 string rejected"):
                encoding.check_inputs(root)

    def test_rendered_xml_decodes_numeric_entities_before_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wxs = '<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi"><Product Codepage="936" Name="AiGoodBro"/></Wix>'
            wxl = '<WixLocalization Codepage="936"><String Id="TauriLanguage">1033</String><String Id="TauriCodepage">1252</String></WixLocalization>'
            (root / "main.wxs").write_text(wxs)
            (root / "locale.wxl").write_text(wxl)
            self.assertEqual(len(encoding.check_generated(root)), 2)
            (root / "main.wxs").write_text(wxs.replace("AiGoodBro", "&#x1f600;"))
            with self.assertRaisesRegex(ValueError, "CP936 string rejected"):
                encoding.check_generated(root)
            (root / "main.wxs").write_text(wxs)
            (root / "locale.wxl").write_text(wxl.replace("1252", "936"))
            with self.assertRaisesRegex(ValueError, "summary/language"):
                encoding.check_generated(root)

    def test_pinned_english_localization_complete_charset_audit(self):
        policy = json.loads((ROOT / "windows/apps/codexu-tauri/src-tauri/installer/SOURCE.json").read_text())["encoding_contract"]
        self.assertEqual([(x["sha256"], x["valueCount"], x["allValuesAscii"], x["nonAsciiCodepoints"]) for x in policy["localizationSources"]], [
            ("b0131df8e8dee16041d211200e79546c53866fe9854df50b734b9352ed0c4cb0", 1686, True, []),
            ("1f279883252cce68dfbf60e93eb60d1c247414ebc4b8492e5aa4c331ee5065c3", 65, True, []),
            ("34df49db31a56913337132beaf54135a3f675a9085724b7781ec0a32fd523815", 12, True, []),
        ])

    @unittest.skipUnless(os.name == "nt", "Real MSI COM requires Windows; host checks do not replace it")
    def test_real_com_database_codepage_mapping_and_installed_bytes(self):
        pwsh = shutil.which("pwsh")
        self.assertIsNotNone(pwsh, "Windows must not skip the native COM contract")
        harness = r'''
param([string]$Repo, [string]$Root)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $Repo 'windows/scripts/MsiEncoding.ps1')
$msi = Join-Path $Root 'synthetic.msi'
$engine = New-Object -ComObject WindowsInstaller.Installer
$db = $null; $summary = $null
try {
    $db = $engine.OpenDatabase($msi, 3)
    [IO.File]::WriteAllText((Join-Path $Root 'set-codepage.idt'), "`r`n`r`n936`t_ForceCodepage`r`n", [Text.Encoding]::ASCII)
    [void]$db.Import($Root, 'set-codepage.idt')
    function Sql([string]$Query) {
        $view = $db.OpenView($Query)
        try { [void]$view.Execute() }
        finally { [void]$view.Close(); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
    }
    Sql 'CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(0) LOCALIZABLE PRIMARY KEY `Property`)'
    Sql 'CREATE TABLE `Directory` (`Directory` CHAR(72) NOT NULL, `Directory_Parent` CHAR(72), `DefaultDir` CHAR(255) NOT NULL LOCALIZABLE PRIMARY KEY `Directory`)'
    Sql 'CREATE TABLE `Component` (`Component` CHAR(72) NOT NULL, `Directory_` CHAR(72) NOT NULL PRIMARY KEY `Component`)'
    Sql 'CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `Component_` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL LOCALIZABLE, `FileSize` LONG NOT NULL PRIMARY KEY `File`)'
    foreach ($pair in @(@('ProductCode','{66FFBEF7-2A27-4F5C-ADBD-BA2945B34D05}'),@('UpgradeCode','{6CD62AC1-9AD0-5E9E-A4E1-C78C6A73FD03}'),@('ProductLanguage','1033'),@('ProductVersion','3.0.0'))) {
        Sql ("INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('" + $pair[0] + "', '" + $pair[1] + "')")
    }
    Sql "INSERT INTO ``Directory`` (``Directory``, ``Directory_Parent``, ``DefaultDir``) VALUES ('INSTALLDIR', '', 'Fixture')"
    Sql "INSERT INTO ``Directory`` (``Directory``, ``Directory_Parent``, ``DefaultDir``) VALUES ('Skills', 'INSTALLDIR', 'SKILLS|skill-library')"
    $index = 0; $install = Join-Path $Root 'installed'
    foreach ($relative in @(Get-MsiUnicodeResourcePaths)) {
        $parts = $relative.Split('/'); $index++
        Sql ("INSERT INTO ``Directory`` (``Directory``, ``Directory_Parent``, ``DefaultDir``) VALUES ('D$index', 'Skills', '" + $parts[1] + "')")
        Sql "INSERT INTO ``Component`` (``Component``, ``Directory_``) VALUES ('C$index', 'D$index')"
        $source = Join-Path (Join-Path $Repo 'Resources/SkillLibrary') ($parts[1] + '/' + $parts[2])
        $length = (Get-Item -LiteralPath $source).Length
        Sql ("INSERT INTO ``File`` (``File``, ``Component_``, ``FileName``, ``FileSize``) VALUES ('F$index', 'C$index', 'SHORT$index|" + $parts[2] + "', $length)")
        $destination = Join-Path $install $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        [IO.File]::Copy($source, $destination)
    }
    $summary = $db.SummaryInformation(2)
    $summary.Property(1) = 1252
    $summary.Property(7) = 'x64;1033'
    [void]$summary.Persist()
    [void]$db.Commit()
} finally {
    foreach ($com in @($summary, $db, $engine)) { if ($null -ne $com) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) } }
}
$evidence = @(Get-MsiEncodingEvidence -MsiPath $msi -SourceRoot $Repo -EvidenceDirectory $Root)
if ($evidence.Count -ne 1 -or $evidence[0].resources.Count -ne 7) { throw 'COM output/mapping coverage mismatch.' }
$rows = @(Assert-MsiUnicodeResources -Evidence $evidence[0] -InstallRoot $install)
if ($rows.Count -ne 7) { throw 'Native resource readback coverage mismatch.' }
[IO.File]::AppendAllText((Join-Path $install $rows[0].relativePath), 'changed')
$rejected = $false
try { $null = Assert-MsiUnicodeResources -Evidence $evidence[0] -InstallRoot $install } catch { $rejected = $true }
if (-not $rejected) { throw 'Altered installed bytes were accepted.' }
foreach ($bad in @('936', "936`t_ForceCodepage", "`n`n936`tOther`n")) {
    $rejected = $false
    try { $null = Read-MsiCodepageExport $bad } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid codepage export accepted.' }
}
Write-Output 'PASS: actual MSI COM CP936/summary1252, seven target mappings, byte mismatch refusal'
'''
        with tempfile.TemporaryDirectory(prefix="agb-msi-encoding-") as temporary:
            script = Path(temporary) / "contract.ps1"
            script.write_text(harness, encoding="utf-8")
            result = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(script), str(ROOT), temporary], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: actual MSI COM CP936/summary1252", result.stdout)


if __name__ == "__main__":
    unittest.main()
