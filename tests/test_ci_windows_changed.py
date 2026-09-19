"""Exercise CI selection against real, isolated Git history."""

import pathlib
import subprocess
import tempfile
import unittest

from scripts.ci_windows_changed import windows_changed


class WindowsCISelectionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="aigoodbro-ci-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = pathlib.Path(cls.temporary.name)
        cls.git("init", "-q")
        cls.base = cls.commit("README.md", "base")
        cls.mac = cls.commit("README.md", "macOS documentation")
        cls.windows = cls.commit("windows/source.txt", "Windows change")
        cls.workflow = cls.commit(".github/workflows/ci.yml", "workflow change")
        cls.palette = cls.commit("Resources/Palettes/example/tokens/light.json", "{}")
        cls.badge = cls.commit("Resources/LeadershipBadges/example.png", "synthetic fixture")
        cls.other_resource = cls.commit("Resources/Other/example.txt", "unrelated resource")
        cls.git("checkout", "-q", "-b", "base-only-change", cls.base)
        cls.diverged_base = cls.commit("windows/source.txt", "base-only Windows change")

    @classmethod
    def git(cls, *args):
        return subprocess.check_output(
            ["git", "-c", "user.name=CI Fixture", "-c", "user.email=ci@example.invalid",
             "-c", "commit.gpgSign=false", "-c", "core.hooksPath=" + str(cls.root / "no-hooks"),
             *args], cwd=cls.root, text=True,
        ).strip()

    @classmethod
    def commit(cls, path, content):
        target = cls.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        cls.git("add", "--", path)
        cls.git("commit", "-q", "-m", "CI fixture")
        return cls.git("rev-parse", "HEAD")

    def push(self, before, after):
        return windows_changed("push", {"before": before, "after": after}, self.root)

    def pull(self, base, head):
        return windows_changed("pull_request", {
            "pull_request": {"base": {"sha": base}, "head": {"sha": head}},
        }, self.root)

    def test_macos_only_changes_skip_windows(self):
        self.assertFalse(self.push(self.base, self.mac))
        self.assertFalse(self.pull(self.base, self.mac))

    def test_windows_changes_run_windows(self):
        self.assertTrue(self.push(self.mac, self.windows))
        self.assertTrue(self.pull(self.base, self.windows))

    def test_workflow_changes_validate_the_gate(self):
        self.assertTrue(self.push(self.windows, self.workflow))

    def test_shared_resources_select_windows_on_push_and_pull(self):
        for before, after in ((self.workflow, self.palette), (self.palette, self.badge)):
            with self.subTest(after=after):
                self.assertTrue(self.push(before, after))
                self.assertTrue(self.pull(before, after))
                self.assertTrue(self.push(after, before))  # Resource deletion.

    def test_unrelated_resources_do_not_select_windows(self):
        self.assertFalse(self.push(self.badge, self.other_resource))
        self.assertFalse(self.pull(self.badge, self.other_resource))

    def test_pr_uses_merge_base_not_unrelated_base_changes(self):
        self.assertFalse(self.pull(self.diverged_base, self.mac))
        self.assertTrue(self.push(self.diverged_base, self.mac))

    def test_removing_windows_code_still_runs_checks(self):
        self.assertTrue(self.push(self.windows, self.mac))

    def test_new_branch_does_not_skip_validation(self):
        self.assertTrue(self.push("0" * 40, self.mac))

    def test_manual_selection_is_explicit(self):
        for value in (False, "false", None):
            self.assertFalse(windows_changed("workflow_dispatch", {"inputs": {"windows": value}}))
        for value in (True, "true"):
            self.assertTrue(windows_changed("workflow_dispatch", {"inputs": {"windows": value}}))

    def test_missing_history_fails_instead_of_skipping(self):
        with self.assertRaises(RuntimeError):
            self.push("f" * 40, self.mac)


if __name__ == "__main__":
    unittest.main()
