"""Release identity contracts: new labels must not create a second installation."""

import hashlib
import json
import pathlib
import re
import subprocess
import tempfile
import unittest
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]
TAURI = ROOT / "windows/apps/codexu-tauri/src-tauri"
UPGRADE_CODE = "6cd62ac1-9ad0-5e9e-a4e1-c78c6a73fd03"


class WindowsBranding(unittest.TestCase):
    def test_display_brand_keeps_upgrade_and_storage_identity(self):
        config = json.loads((TAURI / "tauri.conf.json").read_text(encoding="utf-8"))
        self.assertEqual(config["productName"], "AiGoodBro")
        self.assertEqual(config["app"]["windows"][0]["title"], "AiGoodBro")
        self.assertEqual(config["identifier"], "com.blackielf.codex-account-manager-next.windows")
        wix = config["bundle"]["windows"]["wix"]
        self.assertEqual(wix["upgradeCode"], UPGRADE_CODE)
        self.assertEqual(str(uuid.uuid5(uuid.NAMESPACE_DNS, "Codex Account Manager Next.exe.app.x64")), UPGRADE_CODE)
        self.assertNotEqual(str(uuid.uuid5(uuid.NAMESPACE_DNS, "AiGoodBro.exe.app.x64")), UPGRADE_CODE)
        self.assertEqual(wix["template"], "installer/wix-main.wxs")
        self.assertEqual(config["bundle"]["windows"]["nsis"]["template"], "installer/nsis-installer.nsi")
        self.assertEqual(config["bundle"]["windows"]["nsis"]["installMode"], "currentUser")
        self.assertIn('.join("CodexAccountManagerNext")', (TAURI / "src/app_state.rs").read_text(encoding="utf-8"))
        self.assertIn('<title>AiGoodBro</title>', (TAURI.parent / "web/index.html").read_text(encoding="utf-8"))
        settings = (TAURI / "src/commands/settings.rs").read_text(encoding="utf-8")
        self.assertIn('"设置 — AiGoodBro"', settings)
        self.assertIn('"Settings — AiGoodBro"', settings)

    def test_installer_changes_reconstruct_exact_pinned_upstream(self):
        directory = TAURI / "installer"
        receipt = json.loads((directory / "SOURCE.json").read_text(encoding="utf-8"))
        expected = {
            "nsis-installer.nsi": "fb8e9bb406dc6862a939f71258c14a08c4aa5361",
            "wix-main.wxs": "a11b2ec4381cb05fb0d340b17ef5197ad951529c",
        }
        self.assertEqual(receipt["ref"], "tauri-cli-v2.6.2")
        for name, blob in expected.items():
            with self.subTest(name=name):
                local = (directory / name).read_bytes()
                record = receipt["files"][name]
                self.assertEqual(hashlib.sha256(local).hexdigest(), record["local_sha256"])
                source = local.decode()
                for change in reversed(record["replacements"]):
                    self.assertEqual(source.count(change["after"]), change["count"])
                    source = source.replace(change["after"], change["before"])
                raw = source.encode()
                self.assertEqual(hashlib.sha256(raw).hexdigest(), record["upstream_sha256"])
                self.assertEqual(hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest(), blob)

    def test_new_and_old_update_asset_names_remain_supported(self):
        source = (ROOT / "windows/crates/codexu-core/src/updates.rs").read_text(encoding="utf-8")
        for prefix in ("AiGoodBro", "CodexAccountManagerNext"):
            for suffix in (".msi", "-setup.exe"):
                self.assertIn(prefix + '-{version}-windows-x86_64' + suffix, source)

    def test_wix_registry_paths_have_no_empty_segments(self):
        source = (TAURI / "installer/wix-main.wxs").read_text(encoding="utf-8")
        keys = re.findall(r'<Registry(?:Search|Key|Value)\b[^>]*\bKey="([^"]+)"', source)
        # Dynamic Handlebars paths retain the upstream escaping contract.
        keys = [key for key in keys if "{{" not in key]
        self.assertGreaterEqual(len(keys), 10)
        for key in keys:
            with self.subTest(key=key):
                self.assertNotIn("", key.split("\\"), "WiX registry keys use literal single separators")
        legacy = "Software\\Codex Account Manager Next contributors\\Codex Account Manager Next"
        self.assertEqual(keys.count(legacy), 6)

    def test_msi_legacy_link_plan_only_schedules_exact_owned_plain_files(self):
        source = (TAURI / "installer/wix-main.wxs").read_text(encoding="utf-8")
        script = re.search(r'<CustomAction Id="PlanLegacyBrandShortcuts"[^>]+><!\[CDATA\[(.*?)\]\]></CustomAction>', source, re.S).group(1)
        self.assertIn('Before="RemoveFiles">WIX_UPGRADE_DETECTED AND NOT Installed</Custom>', source)
        # Execute the shipped JScript with a narrow COM adapter; the Windows
        # upgrade lane separately exercises real MSI/WSH, foreign links, rollback.
        harness = r'''
const vm = require("node:vm"), assert = require("node:assert/strict"), path = require("node:path").win32;
let script = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
// JScript supports indexed COM property setters; Node needs this narrow adapter.
assert.equal(script.split("Session.Property(row[3]) = folder;").length,2);
script=script.replace("Session.Property(row[3]) = folder;", "Session.SetProperty(row[3], folder);");
const legacy = "Codex Account Manager Next.lnk";
const props = {INSTALLDIR:"D:\\Apps\\AiGoodBro\\", DesktopFolder:"C:\\Users\\Public\\Desktop\\", ProgramMenuFolder:"C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\"};
const normalize = x => path.resolve(x).toLowerCase();
const links = [path.join(props.DesktopFolder,legacy), path.join(props.ProgramMenuFolder,"Codex Account Manager Next",legacy)].map(normalize);
const expected = "D:\\Apps\\AiGoodBro\\codexu-tauri.exe";
function run(targets, reparses=[], changedProps={}, databaseError=false, metadataError=false) {
  const queries=[], touched=[];
  const files = new Map(targets.map((x,i) => [links[i],x]).filter(x=>x[1]!==null));
  const fs = {GetAbsolutePathName:path.resolve, BuildPath:path.join,
    FileExists:x=>files.has(normalize(x)), GetParentFolderName:path.dirname,
    GetFile:x=>{if(metadataError)throw Error("metadata unavailable");return {Attributes:reparses.includes(normalize(x))?1024:0};},
    GetFolder:x=>{if(metadataError)throw Error("metadata unavailable");return {Attributes:reparses.includes(normalize(x))?1024:0};}};
  const shell={CreateShortcut:x=>{touched.push(normalize(x)); const target=files.get(normalize(x)); if(target===false)throw Error("unreadable link"); return {TargetPath:target};}};
  const propertyWrites={};
  const Session={Property:x=>({...props,...changedProps,...propertyWrites})[x],SetProperty:(k,v)=>propertyWrites[k]=v,Database:{OpenView:q=>({Execute(){if(databaseError)throw Error("insert failed");queries.push(q);},Close(){}})}};
  vm.runInNewContext(script,{Session,ActiveXObject:function(name){if(name==="Scripting.FileSystemObject")return fs;if(name==="WScript.Shell")return shell;throw Error("unexpected COM");}});
  for(const q of queries){assert.match(q,/^INSERT INTO `RemoveFile` /);assert.match(q,/, 1\) TEMPORARY$/);assert.equal(q.includes("D:"),false);assert.equal(q.includes("*"),false);
    const prop=q.match(/, '([^']+)', 1\) TEMPORARY$/)[1];
    const index=prop==="AiGoodBroLegacyDesktopDirectory"?0:1;
    assert.equal(normalize(propertyWrites[prop]),normalize(path.dirname(links[index])));}
  return {queries,touched};
}
let r=run([expected,expected.toUpperCase()]);assert.equal(r.queries.length,2);
assert.match(r.queries[0],/'ApplicationShortcutDesktop'.*'AiGoodBroLegacyDesktopDirectory'/);
assert.match(r.queries[1],/'ApplicationShortcut'.*'AiGoodBroLegacyProgramsDirectory'/);
assert.equal(run([null,null]).queries.length,0);
assert.equal(run([expected,expected],[],{AiGoodBroLegacyDesktopDirectory:"C:\\unrelated"}).queries.length,2);
assert.equal(run([expected,expected],[],{},false,true).queries.length,0);
for(const foreign of ["D:\\Apps\\AiGoodBro2\\codexu-tauri.exe",expected+".other","D:\\other.exe","codexu-tauri.exe","",false])assert.equal(run([foreign,foreign]).queries.length,0);
assert.equal(run([expected,expected],[links[0]]).queries.length,1);
assert.equal(run([expected,expected],[normalize(path.dirname(links[1]))]).queries.length,1);
assert.throws(()=>run([expected,expected],[],{INSTALLDIR:"relative"}),/absolute installer path/);
assert.throws(()=>run([expected,expected],[],{},true),/insert failed/);
console.log("PASS: shipped legacy-link planner exact ownership, absent/foreign/malformed/reparse refusal, fixed temporary rows, database failure propagation");
'''
        result = subprocess.run(["node", "-e", harness], input=json.dumps(script), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(__import__("os").name != "nt", "Bash checksum contract runs on Unix; native package contracts run on Windows")
    def test_cross_platform_assets_require_new_names_and_real_checksums(self):
        with tempfile.TemporaryDirectory(prefix="aigoodbro-brand-") as temporary:
            folder = pathlib.Path(temporary)
            names = ["AiGoodBro-9.6.9-mac-arm64.dmg", "AiGoodBro-9.6.9-mac-x86_64.dmg",
                     "AiGoodBro-9.6.9-windows-x86_64.msi", "AiGoodBro-9.6.9-windows-x86_64-setup.exe"]
            for name in names:
                data = ("synthetic checksum fixture: " + name).encode()
                (folder / name).write_bytes(data)
                (folder / (name + ".sha256")).write_text(hashlib.sha256(data).hexdigest() + "  " + name + "\n")
            command = ["bash", str(ROOT / "scripts/check-cross-platform-release-assets.sh"), "9.6.9", str(folder)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (folder / names[2]).rename(folder / names[2].replace("AiGoodBro", "CodexAccountManagerNext"))
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (folder / names[2].replace("AiGoodBro", "CodexAccountManagerNext")).rename(folder / names[2])
            (folder / names[2]).write_bytes(b"tampered")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
