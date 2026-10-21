#!/usr/bin/env python3
"""Offline production Hub admission + registry capacity checks.

Only the Hub transport and support-directory boundary are replaced. No app,
helper, live registry, profile, credential or localhost endpoint is accessed.
"""
from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SERVICE = ROOT / "Sources/CodexUsageWidget/Services"


def declaration(source, needle):
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
    raise ValueError(needle)


STUBS = r'''
import Foundation
import Darwin
enum WidgetLanguage {
    case zh, en
    func text(_ zh: String, _ en: String) -> String { self == .zh ? zh : en }
}
enum DispatchParticipationError: Error { case fileAccess }
enum DispatchParticipationPaths {
    static func supportDirectory() -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HUB_CAPACITY_FIXTURE_ROOT"]!)
    }
}
enum HubCapacityFixture {
    static var overview = HubOverview(tasks: [])
}
'''


FIXTURE = r'''
import Foundation
import Darwin
@main struct HubCapacityFixtureMain {
    static func main() async throws {
        precondition(HubWarmUpGateSelfTest.run())
        let activity = DispatchActivityStore.live
        let now = Date()
        func tasks(_ count: Int, alias: String = "fixture-alias", state: String = "running") -> [HubTask] {
            (0..<count).map { _ in HubTask(accountAlias: alias, state: state, createdAt: now, updatedAt: now) }
        }
        func check(_ actual: HubWarmUpAvailability, _ expected: HubWarmUpAvailability, _ name: String) {
            precondition(actual == expected, name)
        }
        func availability(_ count: Int, excluding: String? = nil) async -> HubWarmUpAvailability {
            HubCapacityFixture.overview = HubOverview(tasks: tasks(count))
            return await HubConsoleModel.warmUpAvailability(for: " FIXTURE-ALIAS ", excludingLocalLease: excluding, maxConcurrent: 10)
        }
        check(await availability(9), .idle, "nine Hub tasks leave one slot")
        check(await availability(10), .busy, "ten Hub tasks reach the cap")
        check(await availability(11), .busy, "Hub tasks above the cap stay blocked")

        let run = UUID().uuidString
        let first = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run,
            requestID: UUID().uuidString, profileID: "fixture-profile", childPID: getpid())
        _ = try activity.reserveProxy(account: "other-account", alias: "other-alias", runID: run,
            requestID: UUID().uuidString, profileID: "other-profile", childPID: getpid())
        check(await availability(8), .idle, "one matching local lease plus eight Hub tasks leaves one slot")
        check(await availability(9), .busy, "one matching local lease plus nine Hub tasks reaches the cap")
        check(await availability(9, excluding: first), .idle, "current local reservation is excluded")
        check(await availability(10, excluding: first), .busy, "excluding local reservation never hides Hub occupancy")
        _ = try activity.reserveProxy(account: "fixture-account", alias: "fixture-alias", runID: run,
            requestID: UUID().uuidString, profileID: "fixture-profile", childPID: getpid())
        check(await availability(7), .idle, "two matching local leases plus seven Hub tasks leaves one slot")
        check(await availability(8), .busy, "two matching local leases plus eight Hub tasks reaches the cap")
        check(await availability(8, excluding: first), .idle, "exclusion removes exactly one matching local lease")

        HubCapacityFixture.overview = HubOverview(tasks: tasks(1, state: "future_state"))
        check(await HubConsoleModel.warmUpAvailability(for: "fixture-alias", maxConcurrent: 10), .unavailable,
            "unknown Hub state fails closed with spare slots")
        HubCapacityFixture.overview = HubOverview(tasks: tasks(1, state: "uncertain"))
        check(await HubConsoleModel.warmUpAvailability(for: "fixture-alias", maxConcurrent: 10), .unavailable,
            "uncertain Hub state fails closed with spare slots")
        HubCapacityFixture.overview = HubOverview(tasks: nil)
        check(await HubConsoleModel.warmUpAvailability(for: "fixture-alias", maxConcurrent: 10), .unavailable,
            "missing Hub task evidence fails closed with spare slots")
        print("PASS Hub capacity: every matching task, combined registry leases, cap 10, exact exclusion and unknown evidence")
    }
}
'''


with tempfile.TemporaryDirectory(prefix="agb-hub-capacity-") as temporary:
    folder = Path(temporary).resolve()
    sync = (SERVICE / "DispatchParticipationSync.swift").read_text()
    bounded = declaration(sync, "    static func readBoundedRegularFile(")
    (folder / "Stubs.swift").write_text(
        STUBS + "\nstruct DispatchParticipationSync {\n"
        "static let maximumConfigurationBytes = 2097152\n" + bounded + "\n}\n")
    hub = (SERVICE / "HubConsoleModel.swift").read_text()
    transport = declaration(hub, "    static func fetchInspectionOverview(")
    hub = hub.replace(transport,
        "static func fetchInspectionOverview(timeout: TimeInterval = 6) async throws -> HubOverview { HubCapacityFixture.overview }")
    (folder / "HubConsoleModel.swift").write_text("import Combine\n" + hub)
    (folder / "Fixture.swift").write_text(FIXTURE)
    executable = folder / "fixture"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", str(folder / "modules"), str(folder / "Stubs.swift"),
        str(SERVICE / "DispatchActivityStore.swift"), str(folder / "HubConsoleModel.swift"),
        str(folder / "Fixture.swift"), "-o", str(executable)], check=True)
    environment = {**os.environ, "HUB_CAPACITY_FIXTURE_ROOT": str(folder / "registry")}
    subprocess.run([str(executable)], env=environment, check=True)
