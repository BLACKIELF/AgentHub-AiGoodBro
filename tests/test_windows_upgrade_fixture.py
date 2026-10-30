"""Exercise the actual synthetic deferred MSI script without installing anything.

This is a host check of failure-injection evidence only. Windows Installer,
PowerShell path normalization, shortcut rollback and upgrade remain native gates.
"""
import json
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "windows/scripts/Test-InstallerUpgrade.ps1"


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
