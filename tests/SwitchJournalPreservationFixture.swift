let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("aigoodbro-journal-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let file = root.appendingPathComponent("auth.json")
let original = try bundle(200)
let target = try bundle(300, account: "workspace-target")
let externalA = try bundle(400, account: "workspace-external-a")
let externalB = try bundle(500, account: "workspace-external-b")
private let journal = CodexAccountActions.PendingSwitchJournal(
    originalAuth: .data(original), targetAuthFingerprint: CodexAccountActions.authFingerprint(target),
    targetIdentity: CodexOfficialProfileReader.credentialIdentity(fromAuthData: target)!,
    originalCodexWasRunning: false, originalDaemonWasRunning: false)
var checks = 0
var failures = 0
func check(_ label: String, _ value: Bool) {
    checks += 1
    if !value {
        failures += 1
        print("FAIL: " + label)
    }
}
private func verifyExternal(_ label: String, first: CodexAccountActions.AuthState, second: Data?, shouldClear: Bool) throws {
    if let second { try second.write(to: file, options: .atomic) } else if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
    CodexAccountActions.cleanupCount = 0
    var threw = false
    do {
        try CodexAccountActions.cleanupExternal(currentAuth: first, journal: journal, systemAuthURL: file, fileManager: fm)
    } catch { threw = true }
    let after = try CodexCredentialTransaction.read(file)
    check(label, threw != shouldClear && CodexAccountActions.cleanupCount == (shouldClear ? 1 : 0) && after == second)
}
private let signedOut = CodexAccountActions.PendingSwitchJournal(
    originalAuth: .missing, targetAuthFingerprint: CodexAccountActions.authFingerprint(target),
    targetIdentity: CodexOfficialProfileReader.credentialIdentity(fromAuthData: target)!,
    originalCodexWasRunning: false, originalDaemonWasRunning: false)
check(
    "originally signed out still takes originalAlreadyPresent", CodexAccountActions.pendingSwitchRecoveryDecision(current: .missing, journal: signedOut) == .originalAlreadyPresent)
try verifyExternal("missing current retains journal without restoring auth", first: .missing, second: nil, shouldClear: false)
try verifyExternal("corrupt current retains journal without overwriting bytes", first: .data(Data("{".utf8)), second: Data("{".utf8), shouldClear: false)
try verifyExternal("stable third account permits cleanup and preserves its auth", first: .data(externalA), second: externalA, shouldClear: true)
try verifyExternal("third account A to B before readback retains journal", first: .data(externalA), second: externalB, shouldClear: false)
try verifyExternal("third account disappearing before readback retains journal", first: .data(externalA), second: nil, shouldClear: false)
try verifyExternal("third account changing back to original retains journal", first: .data(externalA), second: original, shouldClear: false)
try verifyExternal("third account changing to target retains journal", first: .data(externalA), second: target, shouldClear: false)
print("Switch journal preservation: \(checks) assertions, \(failures) failures")
exit(failures == 0 ? 0 : 1)
