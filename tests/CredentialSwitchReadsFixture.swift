let fm = FileManager.default
let directory = fm.temporaryDirectory.appendingPathComponent("aigoodbro-switch-reader-" + UUID().uuidString)
try fm.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: directory) }
var checks = 0
var failures = 0
func check(_ description: String, _ operation: () throws -> Bool) {
    checks += 1
    do {
        if try !operation() {
            failures += 1
            print("FAIL: " + description)
        }
    } catch {
        failures += 1
        print("FAIL: " + description)
    }
}
let auth = try bundle(200)
let file = directory.appendingPathComponent("auth.json")
let missing = directory.appendingPathComponent("missing.json")
let profile = CodexProfile(isSystemProfile: false, codexHomeURL: directory)
try auth.write(to: file)
check("valid managed credential remains readable") { try CodexAccountActions.validatedManagedAuth(at: file, profile: profile) == auth }
check("valid current credential remains readable") { try CodexAccountActions.authState(at: file) == .data(auth) }
check("missing current credential retains missing state") { try CodexAccountActions.authState(at: missing) == .missing }
check("missing managed credential rejects") {
    do {
        _ = try CodexAccountActions.validatedManagedAuth(at: missing, profile: profile)
        return false
    } catch { return true }
}
func padded(_ bytes: Int) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: auth) as! [String: Any]
    object["padding"] = ""
    let baseSize = try JSONSerialization.data(withJSONObject: object).count
    object["padding"] = String(repeating: "x", count: bytes - baseSize)
    return try JSONSerialization.data(withJSONObject: object)
}
let atLimit = try padded(1_048_576)
try atLimit.write(to: file)
check("managed read accepts exactly one MiB") { try CodexAccountActions.validatedManagedAuth(at: file, profile: profile) == atLimit }
check("current read accepts exactly one MiB") { try CodexAccountActions.authState(at: file) == .data(atLimit) }
try padded(1_048_577).write(to: file)
check("managed read rejects one byte over budget") {
    do {
        _ = try CodexAccountActions.validatedManagedAuth(at: file, profile: profile)
        return false
    } catch { return true }
}
check("current read rejects one byte over budget") {
    do {
        _ = try CodexAccountActions.authState(at: file)
        return false
    } catch { return true }
}
try auth.write(to: file)
let link = directory.appendingPathComponent("linked-auth.json")
try fm.createSymbolicLink(at: link, withDestinationURL: file)
for path in [link, directory] {
    check("managed read rejects nonregular input") {
        do {
            _ = try CodexAccountActions.validatedManagedAuth(at: path, profile: profile)
            return false
        } catch { return true }
    }
    check("current read rejects nonregular input") {
        do {
            _ = try CodexAccountActions.authState(at: path)
            return false
        } catch { return true }
    }
}
print("Credential switch readers: \(checks) assertions, \(failures) failures")
exit(failures == 0 ? 0 : 1)
