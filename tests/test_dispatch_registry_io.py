#!/usr/bin/env python3
"""Isolated POSIX-boundary fault probe; never loads the app or live support data.

Compiles production registry + exact maintenance mapping with peripheral
stubs, then sets DYLD_INSERT_LIBRARIES only for each disposable fixture child.
The interposer is armed after reserve and matches only private temporary registry
files in that child's exact fixture directory. This proves an error path, not
that a real incident was caused by a signal or storage failure.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1]
_temporary = tempfile.TemporaryDirectory(prefix="agb-registry-io-")
RUN = Path(_temporary.name)
EXPECT_FIXED = True


def declaration(text, needle):
    start = text.index(needle)
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise ValueError(needle)


def run_checked(command, **kwargs):
    result = subprocess.run(command, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, **kwargs)
    with (RUN / "build.log").open("a") as log:
        log.write(result.stdout)
    if result.returncode:
        raise RuntimeError("isolated compile failed; inspect build.log")
    return result


interposer = r'''
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dlfcn.h>
#include <sys/param.h>

static atomic_int injected = 0, writes = 0, syncs = 0;
int agb_injected_count(void) { return atomic_load(&injected); }
int agb_target_write_count(void) { return atomic_load(&writes); }
int agb_target_fsync_count(void) { return atomic_load(&syncs); }

static bool target(int fd) {
    const char *armed = getenv("AGB_SYSCALL_ARMED");
    const char *root = getenv("AGB_REGISTRY_ROOT");
    if (!armed || strcmp(armed, "1") || !root) return false;
    char path[MAXPATHLEN];
    int saved = errno;
    int result = fcntl(fd, F_GETPATH, path);
    errno = saved;
    if (result != 0) return false;
    size_t root_len = strlen(root);
    if (strncmp(path, root, root_len) || path[root_len] != '/') return false;
    const char *name = path + root_len + 1;
    const char *prefix = ".dispatch-activity-";
    return !strncmp(name, prefix, strlen(prefix))
        && name[strlen(prefix)] && !strchr(name, '/');
}

static bool inject_once(const char *prefix) {
    const char *mode = getenv("AGB_SYSCALL_MODE");
    if (!mode || strncmp(mode, prefix, strlen(prefix))) return false;
    if (strstr(mode, "_always")) {
        atomic_fetch_add(&injected, 1);
        return true;
    }
    int expected = 0;
    return atomic_compare_exchange_strong(&injected, &expected, 1);
}

static ssize_t fault_write(int fd, const void *bytes, size_t count) {
    // dyld does not interpose a call made inside the replacement's own image.
    // Avoid loader reentry from dlsym on an early intercepted system call.
    if (!target(fd)) return write(fd, bytes, count);
    atomic_fetch_add(&writes, 1);
    if (inject_once("write_")) {
        const char *mode = getenv("AGB_SYSCALL_MODE");
        if (!strcmp(mode, "write_short"))
            return write(fd, bytes, count > 1 ? count / 2 : 0);
        if (!strcmp(mode, "write_zero")) return 0;
        errno = strstr(mode, "eintr") ? EINTR : EIO;
        return -1;
    }
    return write(fd, bytes, count);
}

static int fault_fsync(int fd) {
    if (!target(fd)) return fsync(fd);
    atomic_fetch_add(&syncs, 1);
    if (inject_once("fsync_")) {
        const char *mode = getenv("AGB_SYSCALL_MODE");
        errno = strstr(mode, "eintr") ? EINTR : EIO;
        return -1;
    }
    return fsync(fd);
}

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *a, *b; } \
    _interpose_##original __attribute__((section("__DATA,__interpose"))) = \
        { (const void *)(replacement), (const void *)(original) }
INTERPOSE(fault_write, write);
INTERPOSE(fault_fsync, fsync);
'''

stubs = r'''
import Foundation
import Darwin
import CryptoKit
import os.log
enum HubAccountTaskPhase { case maintenance, starting, running, cancelRequested, uncertain, awaitingAcceptance, succeeded, failed, cancelled, unavailable }
struct HubAccountTaskStatus { let phase: HubAccountTaskPhase; let updatedAt: Date? }
enum DispatchParticipationError: Error { case fileAccess }
enum DispatchParticipationPaths {
    static func supportDirectory() -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGB_REGISTRY_ROOT"]!)
    }
}
'''

fixture = r'''
@main struct SyscallFixture {
    static func counter(_ name: String) -> Int32 {
        let image = dlopen(nil, RTLD_NOW)!
        let function = unsafeBitCast(dlsym(image, name)!, to: (@convention(c) () -> Int32).self)
        return function()
    }
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        let mode = env["AGB_SYSCALL_MODE"]!, command = env["AGB_MAINTENANCE_COMMAND"]!
        let expectFixed = env["AGB_EXPECT_FIXED"] == "1"
        let root = DispatchParticipationPaths.supportDirectory()
        precondition(root.path.hasPrefix(env["AGB_EVIDENCE_RUN"]! + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let activity = DispatchActivityStore(directory: root)
        let run = UUID().uuidString, request = UUID().uuidString, profile = "synthetic-profile"
        let lease = try activity.reserveProxy(account: "synthetic-account", alias: "synthetic-alias", runID: run,
            requestID: request, profileID: profile, childPID: getpid())
        try activity.updateProxy(lease, runID: run, requestID: request, profileID: profile, state: "running")
        let state = root.appendingPathComponent(DispatchActivityStore.stateName)
        let before = try Data(contentsOf: state)
        let query = LocalProxyRequest(schemaVersion: 1, runID: run, key: "synthetic-key", command: command,
            requestID: request, profileID: profile, leaseID: lease)
        setenv("AGB_SYSCALL_ARMED", "1", 1)
        let first = MaintenanceHarness.maintainLease(query, run: run, key: "synthetic-key", permittedProfiles: [profile], activity: activity)
        unsetenv("AGB_SYSCALL_ARMED")
        let unchanged = try Data(contentsOf: state) == before
        let fencedBeforeRetry = localProxyReleaseFence.contains(runID: run, profileID: profile)
        let injected = counter("agb_injected_count")
        let writes = counter("agb_target_write_count"), syncs = counter("agb_target_fsync_count")
        var object: [String: Any] = ["mode": mode, "command": command, "firstOK": first.ok,
            "firstError": first.error ?? "", "injections": injected,
            "targetWrites": writes, "targetFsyncs": syncs,
            "originalRegistryUnchanged": unchanged, "fencedBeforeRetry": fencedBeforeRetry]
        if mode == "control" || (expectFixed && ["write_eintr", "write_short", "fsync_eintr"].contains(mode)) {
            precondition(first.ok && injected == (mode == "control" ? 0 : 1))
            precondition(writes == (mode.hasPrefix("write_") ? 2 : 1))
            precondition(syncs == (mode == "fsync_eintr" ? 2 : 1))
        } else {
            let expectedInjections: Int32 = expectFixed && mode.hasSuffix("_always") ? 9 : 1
            precondition(!first.ok && first.error == "registry_unavailable" && injected == expectedInjections)
            precondition(writes == (mode == "write_eintr_always" ? expectedInjections : 1))
            precondition(syncs == (mode.hasPrefix("write_") ? 0 : expectedInjections))
            precondition(unchanged && !fencedBeforeRetry)
            // Exact maintenance resubmission is only a fixture control after
            // the injected error has been removed; production is unmodified.
            let retry = MaintenanceHarness.maintainLease(query, run: run, key: "synthetic-key", permittedProfiles: [profile], activity: activity)
            object["uninjectedControlOK"] = retry.ok
            precondition(retry.ok)
        }
        let terminal = try activity.read().leases.first { $0.leaseId == lease }!.state
        object["finalState"] = terminal
        object["finalFence"] = localProxyReleaseFence.contains(runID: run, profileID: profile)
        precondition(terminal == (command == "release" ? "accepted" : "running"))
        precondition(localProxyReleaseFence.contains(runID: run, profileID: profile) == (command == "release"))
        print(String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
'''

registry_path = "Sources/CodexUsageWidget/Services/DispatchActivityStore.swift"
queue_path = "Sources/CodexUsageWidget/Services/LocalProxyQueueStore.swift"
sync_path = "Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift"
domain_path = "Sources/CodexUsageWidget/Domain/LocalProxyQueue.swift"
paths = [registry_path, queue_path, sync_path, domain_path]
texts = {path: (SOURCE / path).read_text() for path in paths}
frozen = RUN / "frozen"
frozen.mkdir()
for path, text in texts.items():
    (frozen / Path(path).name).write_text(text)
registry = declaration(texts[registry_path], "struct DispatchActivityStore {")
bounded = declaration(texts[sync_path], "    static func readBoundedRegularFile(")
maintain = declaration(texts[queue_path], "    nonisolated private static func maintainLease(")
maintain = maintain.replace("nonisolated private static", "static", 1)
fence = declaration(texts[queue_path], "private final class LocalProxyReleaseFence:")
contracts = "\n".join(declaration(texts[domain_path], needle) for needle in [
    "enum LocalProxyFailure:", "struct LocalProxyRequest:", "struct LocalProxyReply:"])
compiled = stubs + "\nstruct DispatchParticipationSync {\nstatic let maximumConfigurationBytes = 2097152\n" + bounded + "\n}\n"
compiled += registry + "\n" + contracts + "\n" + fence + "\nprivate let localProxyReleaseFence = LocalProxyReleaseFence()\n"
compiled += "enum MaintenanceHarness {\n" + maintain + "\n}\n" + fixture
(RUN / "Fixture.swift").write_text(compiled)
(RUN / "Faults.c").write_text(interposer)
safe_env = {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}
run_checked(["xcrun", "clang", "-dynamiclib", "-O2", "-std=c11", str(RUN / "Faults.c"), "-o", str(RUN / "Faults.dylib")], env=safe_env)
run_checked(["xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(RUN / "modules"), str(RUN / "Fixture.swift"), "-o", str(RUN / "fixture")], env=safe_env)
results = []
for command in ["heartbeat", "release"]:
    for mode in ["control", "write_eintr", "write_short", "fsync_eintr", "write_eio", "fsync_eio", "write_eintr_always", "fsync_eintr_always", "write_zero"]:
        support = (RUN / (command + "-" + mode)).resolve()
        child_env = {**safe_env, "DYLD_INSERT_LIBRARIES": str(RUN / "Faults.dylib"),
                     "AGB_REGISTRY_ROOT": str(support), "AGB_EVIDENCE_RUN": str(RUN.resolve()),
                     "AGB_SYSCALL_MODE": mode, "AGB_MAINTENANCE_COMMAND": command,
                     "AGB_EXPECT_FIXED": "1" if EXPECT_FIXED else "0"}
        try:
            result = subprocess.run([str(RUN / "fixture")], env=child_env, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, timeout=15)
        except subprocess.TimeoutExpired:
            (RUN / (command + "-" + mode + ".log")).write_text("fixture child timed out after 15 seconds\n")
            raise
        (RUN / (command + "-" + mode + ".log")).write_text(result.stdout + result.stderr)
        assert result.returncode == 0, (command, mode, result.returncode)
        row = json.loads(result.stdout)
        results.append(row)
        print(json.dumps(row, sort_keys=True), flush=True)
print("PASS: " + str(len(results)) + " isolated production POSIX-boundary cases; no live state used", flush=True)
_temporary.cleanup()
