#!/usr/bin/env python3
"""Execute frozen production refresh entry/guards/completion with recording doubles.

Only the selected Swift fragments are compiled, without the app, readers, account
configuration, UserDefaults or provider calls. Mutants must compile and then fail
the same behavioral assertions; the live production sources are never modified.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def extract(source, needle):
    start = source.index(needle)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"Unclosed production declaration: {needle}")


def completion_tail(refresh):
    """The complete final segment of the real main-queue completion closure."""
    begin = refresh.index("                self.isRefreshing = false")
    end = refresh.rfind("\n            }")
    assert end > begin, "production refresh completion boundary changed"
    return refresh[begin:end]


FIXTURE = r'''
import Foundation
struct RefreshCall: Equatable {
    let queue: Bool
    let warmUp: Bool
    let automation: Bool
}
final class TaskClientDouble {
    enum Reason { case startup }
    var starts = 0
    var threadReads = 0
    func start(reason: Reason) { starts += 1 }
    func refreshThreads() { threadReads += 1 }
}
enum Phase { case idle, loading }
struct EngineState { var phase = Phase.idle }
final class UsageStoreDouble {
    var hasStarted = true
    var isPreview = false
    var isLoggingIn = false
    var isLaunchingCodex = false
    var isAccountSwitchTransactionActive = false
    var isRefreshing = false
    var hasPendingRefresh = false
    var lastFullRefreshCompletedAt: Date?
    let accountSnapshotRefreshInterval: TimeInterval = 1234
    var onAccountSnapshotRefresh: ((TimeInterval) -> Void)?
    var fullRefreshTimers = 0
    var warmUpTimers = 0
    var switchEvaluations = 0
    var calls: [RefreshCall] = []
    var engineState = EngineState()
    var isRefreshingAccountQuotas = false
    var refreshingProfileIDs: Set<String> = []
    let taskClient = TaskClientDouble()
    func scheduleFullRefreshTimer() { fullRefreshTimers += 1 }
    func scheduleWarmUpTimer() { warmUpTimers += 1 }
    func evaluateAutomaticAccountSwitch() { switchEvaluations += 1 }
    REFRESH_GUARDS_AND_SIGNATURE
    DOCK_ENTRY
    func finish(scheduleWarmUpAfterRefresh: Bool, allowsAccountAutomation: Bool) {
        COMPLETION_TAIL
    }
}
struct DockPreferences { var enabled = true }
struct SettingsDouble { var edgeDock = DockPreferences() }
final class LocalAccountsDouble { var refreshing: Set<String> = [] }
final class AppDelegateDouble {
    var floatingBubbleShuttingDown = false
    var settings = SettingsDouble()
    let store = UsageStoreDouble()
    let localCLIAccounts = LocalAccountsDouble()
    var projections = 0
    func edgeDockRefreshTargets() -> [String: Set<String>] {
        ["codex": ["synthetic-codex"], "claude": ["synthetic-claude"]]
    }
    func syncEdgeDock() { projections += 1 }
    DOCK_ALL
    func triggerAll() async { await refreshEdgeDockAll() }
}
@main struct Fixture {
    static func main() async {
        var failures = 0
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if value { print("PASS \(message)") }
            else { failures += 1; print("FAIL \(message)") }
        }
        func prepare() -> UsageStoreDouble {
            let store = UsageStoreDouble()
            store.isRefreshing = true
            return store
        }
        let entry = UsageStoreDouble()
        var ages: [TimeInterval] = []
        entry.onAccountSnapshotRefresh = { ages.append($0) }
        entry.refreshEdgeDockSnapshotsNow()
        check(entry.calls == [RefreshCall(queue: false, warmUp: false, automation: false)],
              "production dock entry requests neither warm-up nor account automation")
        check(ages == [0], "production dock entry requests immediate selected-account snapshots")
        let blocked: [(String, (UsageStoreDouble) -> Void)] = [
            ("not started", { $0.hasStarted = false }),
            ("preview", { $0.isPreview = true }),
            ("login", { $0.isLoggingIn = true }),
            ("launch", { $0.isLaunchingCodex = true }),
            ("account transaction", { $0.isAccountSwitchTransactionActive = true }),
        ]
        for (name, block) in blocked {
            let store = UsageStoreDouble()
            var reads = 0
            store.onAccountSnapshotRefresh = { _ in reads += 1 }
            block(store)
            store.refreshEdgeDockSnapshotsNow()
            check(store.calls.isEmpty && reads == 0, "production dock entry blocks \(name)")
        }
        let busy = UsageStoreDouble()
        busy.isRefreshing = true
        busy.refresh(queueIfBusy: true, allowsAccountAutomation: false)
        check(busy.hasPendingRefresh && busy.calls.isEmpty, "production busy guard only queues pending work")

        for warmUp in [false, true] {
            let store = prepare()
            var completedAges: [TimeInterval] = []
            store.onAccountSnapshotRefresh = { completedAges.append($0) }
            store.finish(scheduleWarmUpAfterRefresh: warmUp, allowsAccountAutomation: false)
            check(store.warmUpTimers == 0 && store.switchEvaluations == 0,
                  "automation=false suppresses warm-up and switch for schedule=\(warmUp)")
            check(!store.isRefreshing && store.lastFullRefreshCompletedAt != nil
                  && store.fullRefreshTimers == 1 && completedAges == [1234],
                  "automation=false preserves refresh completion, timer and snapshot publication")
            check(store.taskClient.starts == 0 && store.taskClient.threadReads == 0,
                  "automation=false cannot enter task snapshot callbacks that evaluate switching")
        }
        let ordinary = UsageStoreDouble()
        ordinary.refresh()
        check(ordinary.calls == [RefreshCall(queue: false, warmUp: true, automation: true)],
              "ordinary refresh defaults still allow existing automation and warm-up")
        ordinary.finish(scheduleWarmUpAfterRefresh: ordinary.calls[0].warmUp,
                        allowsAccountAutomation: ordinary.calls[0].automation)
        check(ordinary.warmUpTimers == 1 && ordinary.switchEvaluations == 1
              && ordinary.taskClient.starts == 1 && ordinary.taskClient.threadReads == 1,
              "ordinary default refresh preserves warm-up, task reads and switch evaluation")
        let ordinaryNoWarm = prepare()
        ordinaryNoWarm.finish(scheduleWarmUpAfterRefresh: false, allowsAccountAutomation: true)
        check(ordinaryNoWarm.warmUpTimers == 0 && ordinaryNoWarm.switchEvaluations == 1,
              "ordinary no-warm refresh preserves its prior switch behavior")

        let pendingDock = UsageStoreDouble()
        pendingDock.refreshEdgeDockSnapshotsNow()
        var current = pendingDock.calls[0]
        for _ in 0..<3 {
            pendingDock.isRefreshing = true
            pendingDock.hasPendingRefresh = true
            pendingDock.finish(scheduleWarmUpAfterRefresh: current.warmUp,
                               allowsAccountAutomation: current.automation)
            current = pendingDock.calls.last!
        }
        pendingDock.finish(scheduleWarmUpAfterRefresh: current.warmUp,
                           allowsAccountAutomation: current.automation)
        check(pendingDock.calls.count == 4
              && pendingDock.calls.allSatisfy { !$0.warmUp && !$0.automation },
              "every production pending recursion preserves dock automation=false")
        check(pendingDock.warmUpTimers == 0 && pendingDock.switchEvaluations == 0
              && !pendingDock.hasPendingRefresh,
              "multi-hop pending dock chain never schedules warm-up or evaluates switching")
        check(pendingDock.taskClient.starts == 0 && pendingDock.taskClient.threadReads == 0,
              "pending dock chain never enters task snapshot automation callbacks")

        let pendingOrdinary = prepare()
        pendingOrdinary.hasPendingRefresh = true
        pendingOrdinary.finish(scheduleWarmUpAfterRefresh: false, allowsAccountAutomation: true)
        check(pendingOrdinary.calls == [RefreshCall(queue: false, warmUp: true, automation: true)]
              && pendingOrdinary.switchEvaluations == 0 && pendingOrdinary.warmUpTimers == 0,
              "ordinary pending recursion retains its original default warm-up policy")
        let ordinaryNext = pendingOrdinary.calls[0]
        pendingOrdinary.finish(scheduleWarmUpAfterRefresh: ordinaryNext.warmUp,
                               allowsAccountAutomation: ordinaryNext.automation)
        check(pendingOrdinary.warmUpTimers == 1 && pendingOrdinary.switchEvaluations == 1
              && pendingOrdinary.taskClient.starts == 1 && pendingOrdinary.taskClient.threadReads == 1,
              "ordinary pending chain still evaluates existing automation on final completion")

        let app = AppDelegateDouble()
        await app.triggerAll()
        check(app.store.calls == [RefreshCall(queue: false, warmUp: false, automation: false)]
              && app.projections == 1,
              "production async dock callback reaches gated reader entry and completed projection")
        app.settings.edgeDock.enabled = false
        await app.triggerAll()
        app.settings.edgeDock.enabled = true
        app.floatingBubbleShuttingDown = true
        await app.triggerAll()
        check(app.store.calls.count == 1 && app.projections == 1,
              "production async dock callback blocks disabled and shutting-down surfaces")
        print("RESULT checks=\(checks) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
'''


def swift_fixture(usage, app):
    refresh = extract(usage, "    func refresh(queueIfBusy:")
    guard_end = refresh.index("        refreshStatisticsEngine()")
    recording_refresh = refresh[:guard_end] + """        calls.append(RefreshCall(queue: queueIfBusy, warmUp: scheduleWarmUpAfterRefresh,
                                 automation: allowsAccountAutomation))
    }"""
    return (FIXTURE.replace("REFRESH_GUARDS_AND_SIGNATURE", recording_refresh)
            .replace("DOCK_ENTRY", extract(usage, "    func refreshEdgeDockSnapshotsNow()"))
            .replace("COMPLETION_TAIL", completion_tail(refresh))
            .replace("DOCK_ALL", extract(app, "    private func refreshEdgeDockAll()")))


def replace_once(source, old, new):
    assert source.count(old) == 1, f"Mutation target is not unique: {old}"
    return source.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", type=Path)
    args = parser.parse_args()
    usage_path = ROOT / "Sources/CodexUsageWidget/Services/UsageStore.swift"
    app_path = ROOT / "Sources/CodexUsageWidget/App/AppLifecycle.swift"
    usage, app = usage_path.read_text(), app_path.read_text()
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(s.encode()).hexdigest()
              for p, s in [(usage_path, usage), (app_path, app)]}
    print("FROZEN SOURCE SHA256 " + json.dumps(hashes, sort_keys=True), flush=True)
    dock_sync = extract(app, "    private func setupEdgeDockSync()")
    fast_sync = dock_sync[dock_sync.index("        Publishers.MergeMany(["):dock_sync.index("        let hub =")]
    for publisher in ["changed(store.$isRefreshing)", "changed(store.$refreshingProfileIDs)",
                      "changed(localCLIAccounts.$refreshing)"]:
        assert publisher in fast_sync, f"Dock busy publisher missing from fast sync: {publisher}"
    assert ".throttle(for: .milliseconds(220)" in fast_sync
    assert ".sink { [weak self] _ in self?.syncEdgeDockIfChanged() }" in fast_sync
    assert "onRefreshAll: { [weak self] in await self?.refreshEdgeDockAll() }" in app
    print("PASS production dock busy publishers use the fast dock sink and callback is awaited", flush=True)
    variants = [("production", usage, None),
                ("missing-account-automation-gate", replace_once(usage,
                  "} else if allowsAccountAutomation {", "} else {"),
                 "FAIL automation=false suppresses warm-up and switch"),
                ("missing-warm-up-gate", replace_once(usage,
                  "if scheduleWarmUpAfterRefresh && allowsAccountAutomation {",
                  "if scheduleWarmUpAfterRefresh {"),
                 "FAIL automation=false suppresses warm-up and switch for schedule=true"),
                ("lost-pending-false", replace_once(usage,
                  "scheduleWarmUpAfterRefresh: allowsAccountAutomation,\n                        allowsAccountAutomation: allowsAccountAutomation)",
                  "scheduleWarmUpAfterRefresh: allowsAccountAutomation)"),
                 "FAIL every production pending recursion preserves dock automation=false")]
    outcomes = []
    with tempfile.TemporaryDirectory(prefix="dock-refresh-policy-1008v1-") as name:
        temp = Path(name)
        home = temp / "home"
        home.mkdir()
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), CODEX_HOME=str(home / ".codex"))
        for label, source, expected_failure in variants:
            swift = swift_fixture(source, app)
            swift_path = temp / (label + ".swift")
            swift_path.write_text(swift)
            binary = temp / label
            built = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                                    "-module-cache-path", str(temp / "modules"),
                                    str(swift_path), "-o", str(binary)],
                                   env=env, capture_output=True, text=True, timeout=120)
            assert built.returncode == 0, f"Fixture must compile ({label}):\n{built.stdout}{built.stderr}"
            result = subprocess.run([str(binary)], env=env, capture_output=True, text=True, timeout=15)
            if expected_failure is None:
                assert result.returncode == 0, result.stdout + result.stderr
                print(result.stdout, end="", flush=True)
            else:
                assert result.returncode == 1 and expected_failure in result.stdout, (
                    f"Mutant {label} must fail behavioral assertions, not compilation:\n"
                    f"{result.returncode}\n{result.stdout}{result.stderr}")
                print("PASS behavioral regression rejects mutant " + label, flush=True)
            outcomes.append({"variant": label, "exitCode": result.returncode,
                             "expectedFailure": expected_failure, "output": result.stdout})
            if args.artifact_dir:
                args.artifact_dir.mkdir(parents=True, exist_ok=True)
                (args.artifact_dir / (label + ".swift")).write_text(swift)
                (args.artifact_dir / (label + ".log")).write_text(result.stdout + result.stderr)
    if args.artifact_dir:
        (args.artifact_dir / "refresh-policy-result-1008v1.json").write_text(
            json.dumps({"sourceSha256": hashes, "productionPass": True,
                        "mutantsRejected": 3, "dockBusyFastWiringPass": True,
                        "sourceEdited": False, "outcomes": outcomes}, indent=2) + "\n")
    print("BOUNDARY: frozen production entry, guard/signature, completion tail and async callback; "
          "recording doubles only; no app, real configuration, account readers or provider calls")


if __name__ == "__main__":
    main()
