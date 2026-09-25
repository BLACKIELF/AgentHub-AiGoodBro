"""Synthetic selected-profile and deadline regressions; no live accounts or APIs."""
import base64
import copy
from datetime import datetime, timezone
import io
import contextlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import next_dispatch_activity as activity
import next_dispatch_preflight as pre

class ProfileWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "profile"; self.home.mkdir()
        self.now = datetime.now(timezone.utc)
        apple = self.now.timestamp() - pre.APPLE_EPOCH_OFFSET
        self.profile = {"id":"fixture-profile", "name":"fixture@example.invalid", "codexHomePath":str(self.home),
            "isSystemProfile":False, "automaticSwitchParticipation":True,
            "lastSnapshot":{"email":"fixture@example.invalid", "accountID":"fixture-account", "planType":"prolite",
                "quotaReadSucceeded":True, "fetchedAt":apple, "creditBalance":"0", "fiveHour":None,
                "sevenDay":{"usedPercent":10, "resetsAt":apple + 3600}}}
        self.mapping = {"schemaVersion":1,"snapshotMaxAgeSeconds":45,"minimumRemainingPercent":{"fiveHour":0,"sevenDay":0},
            "centralAliases":["system"],"hubProjects":{},"accounts":[{"code":"A","alias":"other","profileId":"other","priority":1}]}
        self.policy = {"schemaVersion":1,"excludedPlanTypes":["pro"],"accountRules":[]}
        self.overview = {"accounts":[],"projects":[],"tasks":[]}
        self.write_auth()

    def write_auth(self, email="fixture@example.invalid", account="fixture-account"):
        payload = base64.urlsafe_b64encode(json.dumps({"email":email}).encode()).decode().rstrip("=")
        (self.home / "auth.json").write_text(json.dumps({"auth_mode":"chatgpt","tokens":{"account_id":account,"id_token":"head." + payload + ".tail"}}))

    def context(self):
        snapshot = {"profiles":[self.profile]}
        with patch.object(pre, "mapping_source", return_value=(copy.deepcopy(self.mapping),self.root,False)), \
             patch.object(pre, "load_json", side_effect=lambda p: snapshot if p == pre.DEFAULT_SNAPSHOT else self.policy):
            return activity.profile_context(pre, self.profile["id"])

    def report(self, allow=True):
        mapping, snapshot, account, profile = self.context()
        return pre.build_report(snapshot,mapping,self.overview,self.now,self.root,45,{"hubAvailable":True},
            requested_code=account["code"],allow_unreported_five_hour=allow)

    def test_unmapped_selection_is_transient_and_missing_window_stays_null(self):
        original = copy.deepcopy(self.mapping)
        mapping, _, account, _ = self.context()
        self.assertIsNone(account["code"])
        self.assertTrue(mapping["profileSelectionUnmapped"])
        self.assertEqual(self.mapping, original)
        self.assertFalse(self.report(False)["preflightPassed"])
        report = self.report()
        self.assertTrue(report["preflightPassed"])
        self.assertIsNone(report["selected"]["fiveHour"])
        self.assertEqual(report["selected"]["quotaException"],"explicit_prolite_unreported_five_hour")

    def test_exception_does_not_hide_bad_quota_evidence(self):
        original = copy.deepcopy(self.profile["lastSnapshot"])
        cases = [
            {"quotaReadSucceeded":False}, {"fetchedAt":original["fetchedAt"]-46},
            {"fetchedAt":original["fetchedAt"]+20}, {"planType":"plus"}, {"planType":None},
            {"creditBalance":None}, {"creditBalance":True}, {"creditBalance":"1"}, {"creditBalanceUnlimited":True},
            {"sevenDay":None}, {"sevenDay":{"usedPercent":100,"resetsAt":original["fetchedAt"]+3600}},
            {"sevenDay":{"usedPercent":10,"resetsAt":original["fetchedAt"]-1}},
            {"fiveHour":{}}, {"fiveHour":{"usedPercent":True,"resetsAt":original["fetchedAt"]+3600}},
            {"fiveHour":{"usedPercent":100,"resetsAt":original["fetchedAt"]+3600}},
        ]
        for change in cases:
            with self.subTest(change=change):
                self.profile["lastSnapshot"] = {**original,**change}
                self.assertFalse(self.report()["preflightPassed"])
        self.profile["lastSnapshot"] = original
        self.profile["lastQuotaReadFailureAt"] = original["fetchedAt"] + 1
        self.assertFalse(self.report()["preflightPassed"])

    def test_mapped_profile_preserves_code_and_policy(self):
        self.mapping["accounts"] = [{"code":"B","alias":"fixture","profileId":self.profile["id"],"priority":2,"active":True}]
        mapping, _, account, _ = self.context()
        self.assertEqual(account["code"],"B")
        self.assertFalse(mapping["profileSelectionUnmapped"])
        self.mapping["accounts"][0]["active"] = False
        with self.assertRaisesRegex(activity.ActivityError,"not_in_dispatch_pool"): self.context()

    def test_system_disabled_and_global_profiles_are_rejected(self):
        for field,value in (("isSystemProfile",True),("automaticSwitchParticipation",False),("codexHomePath",str(Path.home()/".codex"))):
            old=self.profile[field]; self.profile[field]=value
            with self.assertRaises(activity.ActivityError): self.context()
            self.profile[field]=old

    def test_identity_mismatch_api_auth_and_symlink_are_rejected(self):
        activity.verify_profile_credentials(self.profile)
        for email,account in (("other@example.invalid","fixture-account"),("fixture@example.invalid","other")):
            self.write_auth(email,account)
            with self.assertRaisesRegex(activity.ActivityError,"credentials_mismatch"):
                activity.verify_profile_credentials(self.profile)
        self.write_auth()
        auth=self.home/"auth.json"; value=json.loads(auth.read_text()); value["auth_mode"]="api_key"; auth.write_text(json.dumps(value))
        with self.assertRaises(activity.ActivityError): activity.verify_profile_credentials(self.profile)
        auth.rename(self.home/"target"); auth.symlink_to(self.home/"target")
        with self.assertRaises(activity.ActivityError): activity.verify_profile_credentials(self.profile)

    def test_unknown_hub_identity_blocks_other_alias_activity(self):
        mapping,_,account,_=self.context()
        busy={**self.overview,"tasks":[{"state":"running","id":"task","accountAlias":"other","project":"other"}]}
        with patch.object(pre,"fetch_hub",return_value=(busy,None)):
            with self.assertRaisesRegex(activity.ActivityError,"identity_unverified"):
                activity.hub_gate(pre,mapping,account["alias"],self.root)
        with patch.object(pre,"fetch_hub",return_value=(self.overview,None)):
            self.assertEqual(activity.hub_gate(pre,mapping,account["alias"],self.root),self.overview)

    def test_deadline_stops_only_owned_process_and_never_accepts_exit_zero(self):
        registry=activity.Registry(self.root/"state")
        lease=registry.reserve(account_key=activity.digest("fixture"),alias_key=activity.digest("fixture"),code=None,
            project=activity.project_key(self.root),owner="fixture-owner",task="fixture-task",route="direct")
        child=self.root/"child.py"
        child.write_text("import signal,time,sys\nsignal.signal(signal.SIGTERM,lambda *_:sys.exit(0))\ntime.sleep(10)\n")
        result=activity.supervise(registry,lease,[sys.executable,str(child)],self.root,max_runtime_seconds=0.3)
        saved=registry.read()["leases"][0]
        self.assertEqual(saved["state"],"cancelled")
        self.assertFalse(activity.group_has_live_process(saved["processGroupID"]))
        self.assertEqual(result,0)

    def test_normal_completion_and_invalid_deadline(self):
        registry=activity.Registry(self.root/"state")
        lease=registry.reserve(account_key=activity.digest("fixture"),alias_key=activity.digest("fixture"),code=None,
            project=activity.project_key(self.root),owner="fixture-owner",task="fixture-task",route="direct")
        with self.assertRaisesRegex(activity.ActivityError,"invalid_runtime_deadline"):
            activity.supervise(registry,lease,[sys.executable,"-c","pass"],self.root,max_runtime_seconds=float("nan"))
        self.assertEqual(registry.read()["leases"][0]["state"],"preparing")
        self.assertEqual(activity.supervise(registry,lease,[sys.executable,"-c","pass"],self.root,max_runtime_seconds=2),0)
        self.assertEqual(registry.read()["leases"][0]["state"],"awaiting_acceptance")

    def test_cli_requires_exactly_one_selector(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                activity.parser().parse_args(["reserve","--code","A","--profile-id","fixture","--cwd",str(self.root),"--owner","o","--task-id","t","--route","direct"])
        for value in ("nan","inf","0","86401"):
            with self.assertRaises(Exception): activity.positive_runtime(value)

if __name__ == "__main__": unittest.main()
