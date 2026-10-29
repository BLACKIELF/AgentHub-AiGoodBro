#!/usr/bin/env python3
"""Exercise the production registry against synthetic failures only.

DISPATCH_REGISTRY_EVIDENCE must point to a writable evidence directory. All
temporary files and compiler caches are created under it, never the live store.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parent.parent
source = repo / "Sources/CodexUsageWidget/Services/DispatchActivityStore.swift"
fixture = repo / "tests/DispatchRegistryDiagnosticsFixture.swift"
evidence = Path(os.environ["DISPATCH_REGISTRY_EVIDENCE"]).resolve()
evidence.mkdir(parents=True, exist_ok=True)

def replace_once(text, original, replacement):
    if text.count(original) != 1:
        raise RuntimeError("production injection point missing or ambiguous")
    return text.replace(original, replacement, 1)

def replace_log_sink(text):
    # Swift formatting may place the fixed format string on the next line.
    # Match only that whitespace; preserve the exact diagnostic and arguments
    # and still reject a missing or duplicated production call.
    pattern = (re.escape('os_log(') + r'\s*' +
               re.escape('"registry_failure stage=%{public}s cause=%{public}s errno=%{public}d",') + r'\s*' +
               re.escape('log: registryLog, type: .error, stage.rawValue, cause.rawValue, systemError)'))
    if len(re.findall(pattern, text)) != 1:
        raise RuntimeError("production log injection point missing or ambiguous")
    return re.sub(pattern, 'RegistryFault.record(stage.rawValue, cause.rawValue, systemError)', text, count=1)

original = source.read_text()
test_source = replace_log_sink(original)
for old, new in [
    ('Darwin.open(directory.appendingPathComponent(Self.stateName).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)',
     'RegistryFault.openRead(directory.appendingPathComponent(Self.stateName).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)'),
    ('try handle.read(upToCount: min(64 * 1024, remaining))',
     'try RegistryFault.read(handle, min(64 * 1024, remaining))'),
    ('Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)',
     'RegistryFault.openTemporary(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)'),
    ('Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)',
     'RegistryFault.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)'),
    ('synced = fsync(fd)', 'synced = RegistryFault.sync(fd)'),
    ('rename(temporary.path, directory.appendingPathComponent(Self.stateName).path)',
     'RegistryFault.rename(temporary.path, directory.appendingPathComponent(Self.stateName).path)'),
]:
    test_source = replace_once(test_source, old, new)

def safe_output(value):
    return re.sub(r"/(?:[^/\s:'\"]+/)+[^:\s'\"]*", "<path>", value)[-6000:]

with tempfile.TemporaryDirectory(prefix="registry-test-", dir=evidence) as temporary:
    folder = Path(temporary)
    state = folder / "isolated-state"
    state.mkdir(mode=0o700)
    (folder / "tmp").mkdir()
    (folder / "modules").mkdir()
    frozen_source = folder / "DispatchActivityStore.swift"
    frozen_source.write_text(test_source)
    binary = folder / "fixture"
    env = {**os.environ, "TMPDIR": str(folder / "tmp"),
           "CLANG_MODULE_CACHE_PATH": str(folder / "modules"),
           "SWIFT_MODULECACHE_PATH": str(folder / "modules"),
           "DISPATCH_REGISTRY_FIXTURE_ROOT": str(state)}
    # Also check the untouched production source and real os_log call. The
    # injected copy below replaces the log sink only to assert its fields.
    typecheck = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-typecheck",
        "-module-cache-path", str(folder / "modules"), str(source), str(fixture)],
        env=env, capture_output=True, text=True, timeout=180)
    if typecheck.returncode:
        print("registry-diagnostics: production typecheck failed\n" + safe_output(typecheck.stderr))
        raise SystemExit(1)
    # Run the untouched logger once using a malformed synthetic registry. The
    # unified-log readback is optional because macOS can restrict access.
    smoke = folder / "RegistryLogSmoke.swift"
    smoke.write_text(fixture.read_text().split("// The runner substitutes", 1)[0] + r'''
@main struct Smoke {
    static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DISPATCH_REGISTRY_FIXTURE_ROOT"]!)
        let folder = root.appendingPathComponent("log-smoke", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("{".utf8).write(to: folder.appendingPathComponent(DispatchActivityStore.stateName))
        do { _ = try DispatchActivityStore(directory: folder).read(); exit(1) } catch is DecodingError {}
        print(getpid())
    }
}
''')
    smoke_binary = folder / "log-smoke"
    smoke_compile = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", str(folder / "modules"), str(source), str(smoke), "-o", str(smoke_binary)],
        env=env, capture_output=True, text=True, timeout=180)
    if smoke_compile.returncode:
        print("registry-diagnostics: real-log smoke compile failed\n" + safe_output(smoke_compile.stderr))
        raise SystemExit(1)
    smoke_result = subprocess.run([str(smoke_binary)], env=env, capture_output=True, text=True, timeout=30)
    if smoke_result.returncode or not smoke_result.stdout.strip().isdigit():
        print("registry-diagnostics: real-log smoke failed")
        raise SystemExit(1)
    predicate = ('processID == ' + smoke_result.stdout.strip() +
                 ' AND subsystem == "com.blackielf.codex-account-manager-next" AND category == "dispatch-activity"')
    log_status = "not observed"
    for _ in range(2):
        query = subprocess.run(["/usr/bin/log", "show", "--last", "2m", "--style", "json", "--predicate", predicate],
            capture_output=True, text=True, timeout=30)
        if query.returncode:
            log_status = "unavailable"
            break
        try:
            events = json.loads(query.stdout)
        except json.JSONDecodeError:
            log_status = "unavailable"
            break
        messages = [event.get("eventMessage", "") for event in events if isinstance(event, dict)]
        if "registry_failure stage=decode cause=invalid errno=0" in messages:
            log_status = "observed fixed diagnostic"
            break
        time.sleep(1)
    print("system log readback: " + log_status)
    compile_result = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", str(folder / "modules"), str(frozen_source), str(fixture), "-o", str(binary)],
        env=env, capture_output=True, text=True, timeout=180)
    if compile_result.returncode:
        print("registry-diagnostics: compile failed\n" + safe_output(compile_result.stderr))
        raise SystemExit(1)
    result = subprocess.run([str(binary)], env=env, capture_output=True, text=True, timeout=60)
    print(safe_output(result.stdout + result.stderr).strip())
    receipt = {
        "production_source_sha256": hashlib.sha256(original.encode()).hexdigest(),
        "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
        "result": "passed" if result.returncode == 0 else "failed",
        "output": safe_output(result.stdout + result.stderr).strip(),
        "system_log_readback": log_status,
        "scope": "isolated fixtures; no live registry mutation or installed runtime validation",
    }
    (evidence / "diagnostics-regression.json").write_text(json.dumps(receipt, indent=2) + "\n")
    raise SystemExit(result.returncode)
