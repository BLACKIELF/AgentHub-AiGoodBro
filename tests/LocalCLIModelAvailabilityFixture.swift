import Darwin
import Foundation

enum WidgetLanguage {
    case zh
    case en
    var isChinese: Bool { self == .zh }
    var locale: Locale { Locale(identifier: isChinese ? "zh_CN" : "en_US") }
    static func storedOrAutomatic() -> Self { .zh }
    func text(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
    func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
    }
}

private enum FixtureFailure: Error { case assertion(String) }

private func expect(_ condition: Bool, _ label: String) throws {
    guard condition else { throw FixtureFailure.assertion(label) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    guard actual == expected else { throw FixtureFailure.assertion("\(label): \(actual) != \(expected)") }
}

private let hashA = "sha256:" + String(repeating: "ab", count: 32)
private let envA = "synthetic-env-0001"
private let envB = "synthetic-env-0002"
private let acctA = "synthetic-acct-0001"
private let acctB = "synthetic-acct-0002"
private let tz = TimeZone(secondsFromGMT: 8 * 3600)!
private let now = Date(timeIntervalSince1970: 1_789_092_000) // 2026-09-11T02:00:00Z

@main
struct LocalCLIModelAvailabilityFixture {
    static func main() throws {
        try testMissingFileIsUntested()
        try testWrongIdentityRejected()
        try testMalformedCurrentEnvironmentRejected()
        try testWrongModelDoesNotUnlockProvider()
        try testExpiredEvidenceInvalid()
        try testFutureTestInvalid()
        try testUnknownEndDateIsNotExpired()
        try testFreeExpiredIndependentOfTestStatus()
        try testMissingSourceRejected()
        try testSymlinkRejected()
        try testOversizedRejected()
        try testInvalidVersionRejected()
        try testMinimumReturnBoundaries()
        try testEmailIdentityRejected()
        try testNonPublicSourceURLRejected()
        try testFutureFreeStart()
        try testDocumentedCatalogIsNotDispatch()
        try testPresentationLanguages()
        try testInjectedBindingAndNow()
        try testRejectedLoadPreservesOriginalFile()
        try testUnstatedDeadlineCopy()
        try testTimezoneUnstatedForCivilDeadline()
        try testGrokAliasIsNotRemapped()
        try testReceiptBridgeContract()
        print("local-cli-model-availability-fixture: ok")
    }

    private static func testMissingFileIsUntested() throws {
        try withRoot { root in
            let snapshot = LocalCLIModelAvailabilityStore.load(root: root, now: now, binding: binding())
            try expect(snapshot.origin == .missing, "missing file origin")
            try expect(snapshot.evidence.isEmpty, "missing file has no evidence")
            try expect(
                LocalCLIModelDispatch.reason(snapshot: snapshot, binding: binding(), now: now) == .untested,
                "missing file is untested")
            try expect(
                !LocalCLIModelDispatch.allows(snapshot: snapshot, binding: binding(), now: now),
                "untested is not dispatchable")
        }
    }

    private static func testWrongIdentityRejected() throws {
        let snapshot = try loaded(evidence: [passedEvidence(account: acctB)])
        try expect(
            LocalCLIModelDispatch.reason(snapshot: snapshot, binding: binding(account: acctA), now: now)
                == .identityMismatch,
            "wrong account fingerprint")
        try expect(
            !LocalCLIModelDispatch.allows(snapshot: snapshot, binding: binding(account: acctA), now: now),
            "wrong identity cannot dispatch")
    }

    private static func testMalformedCurrentEnvironmentRejected() throws {
        let snapshot = try loaded(evidence: [passedEvidence()])
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        for badHash in ["SHA256:NOTHEX", "", String(repeating: "f", count: 65)] {
            var current = binding()
            current.executableHash = badHash
            check(
                LocalCLIModelDispatch.reason(snapshot: snapshot, binding: current, now: now) == .invalidEvidence,
                "present malformed executable hash cannot be treated as absent")
        }
        for badVersion in ["", String(repeating: "v", count: 65), "invalid\u{0000}version"] {
            var current = binding()
            current.cliVersion = badVersion
            check(
                LocalCLIModelDispatch.reason(snapshot: snapshot, binding: current, now: now) == .invalidEvidence,
                "present malformed CLI version cannot be treated as absent")
        }
        var optional = binding()
        optional.executableHash = nil
        optional.cliVersion = nil
        check(
            LocalCLIModelDispatch.reason(snapshot: snapshot, binding: optional, now: now) == .eligible,
            "absent optional environment fields keep the documented fingerprint-only contract")
        var wrong = binding()
        wrong.executableHash = "sha256:" + String(repeating: "cd", count: 32)
        check(
            LocalCLIModelDispatch.reason(snapshot: snapshot, binding: wrong, now: now) == .environmentMismatch,
            "valid but different executable remains an environment mismatch")
        wrong = binding()
        wrong.cliVersion = "9.9.9"
        check(
            LocalCLIModelDispatch.reason(snapshot: snapshot, binding: wrong, now: now) == .environmentMismatch,
            "valid but different version remains an environment mismatch")
        check(
            LocalCLIModelDispatch.reason(snapshot: snapshot, binding: binding(), now: now) == .eligible,
            "matching environment remains eligible")
        try expect(failures.isEmpty, failures.joined(separator: "; "))
    }

    private static func testWrongModelDoesNotUnlockProvider() throws {
        let snapshot = try loaded(evidence: [
            passedEvidence(model: "deepseek-v4.1-flash"),
        ])
        let other = binding(model: "hy3")
        try expect(
            LocalCLIModelDispatch.reason(snapshot: snapshot, binding: other, now: now) == .untested,
            "other model stays untested")
        try expect(
            LocalCLIModelDispatch.allows(snapshot: snapshot, binding: binding(model: "deepseek-v4.1-flash"), now: now),
            "tested model remains eligible")
        try expect(
            LocalCLIModelDispatch.passingModelIDs(
                snapshot: snapshot, provider: .workBuddy, accountFingerprint: acctA,
                environmentFingerprint: envA, now: now) == ["deepseek-v4.1-flash"],
            "passing set is only the tested model")
        let rows = LocalCLIModelAvailabilityPresentation.rows(
            snapshot: snapshot, provider: .workBuddy, binding: other, now: now, timeZone: tz)
        let hy3 = try row(rows, "hy3")
        try expect(!hy3.dispatchEligible, "hy3 not eligible from flash pass")
        try expect(hy3.testStatus == .untested, "hy3 untested")
    }

    private static func testExpiredEvidenceInvalid() throws {
        var evidence = passedEvidence()
        evidence = LocalCLIModelTestEvidence(
            provider: evidence.provider, modelID: evidence.modelID, requestedModel: evidence.requestedModel,
            observedActualModel: evidence.observedActualModel, cliVersion: evidence.cliVersion,
            executableHash: evidence.executableHash, environmentFingerprint: evidence.environmentFingerprint,
            accountFingerprint: evidence.accountFingerprint, matched: evidence.matched, toolCalls: evidence.toolCalls,
            exitCode: evidence.exitCode, testedAt: now.addingTimeInterval(-3_600),
            validUntil: now.addingTimeInterval(-1), recordedStatus: .passed)
        let snapshot = try loaded(evidence: [evidence])
        try expect(
            LocalCLIModelDispatch.reason(snapshot: snapshot, binding: binding(), now: now) == .expired,
            "expired validUntil")
        try expect(
            LocalCLIModelEvidenceContract.resolvedStatus(evidence, now: now) == .invalid,
            "expired passed record becomes invalid")
    }

    private static func testFutureTestInvalid() throws {
        var evidence = passedEvidence()
        evidence = LocalCLIModelTestEvidence(
            provider: evidence.provider, modelID: evidence.modelID, requestedModel: evidence.requestedModel,
            observedActualModel: evidence.observedActualModel, cliVersion: evidence.cliVersion,
            executableHash: evidence.executableHash, environmentFingerprint: evidence.environmentFingerprint,
            accountFingerprint: evidence.accountFingerprint, matched: evidence.matched, toolCalls: evidence.toolCalls,
            exitCode: evidence.exitCode, testedAt: now.addingTimeInterval(3_600),
            validUntil: now.addingTimeInterval(7_200), recordedStatus: .passed)
        let snapshot = try loaded(evidence: [evidence])
        try expect(
            LocalCLIModelDispatch.reason(snapshot: snapshot, binding: binding(), now: now) == .futureTest,
            "future testedAt")
    }

    private static func testUnknownEndDateIsNotExpired() throws {
        let fact = LocalCLIFreeFact(
            provider: .workBuddy, modelIDs: ["hy3"], label: "HY3", source: .userConfirmed, sourceURL: nil,
            confirmedOn: LocalCLIDocumentedFreeFacts.confirmedOn, startsOn: .unknown, endsOn: .unknown, sortIndex: 2)
        try expect(
            LocalCLIFreeWindow.state(fact, now: now, timeZone: tz) == .unknown,
            "nil endsOn stays unknown, not expired")
        let deadline = LocalCLIModelAvailabilityPresentation.deadlineText(
            .unknown, window: .unknown, language: .zh)
        try expect(deadline.contains("未注明"), "unstated deadline text")
        try expect(!deadline.contains("未知"), "unstated is not 未知")
        try expect(!deadline.contains("永久"), "unstated is not permanent")
        try expect(!deadline.contains("已过期"), "unknown is not expired")
    }

    private static func testFreeExpiredIndependentOfTestStatus() throws {
        let expiredFree = LocalCLIFreeFact(
            provider: .openCode, modelIDs: ["mimo-v2.5-free"], label: "mimo-v2.5-free", source: .official,
            sourceURL: nil, confirmedOn: LocalCLIDocumentedFreeFacts.confirmedOn, startsOn: .unknown,
            endsOn: .civil(LocalCLICivilInstant(year: 2026, month: 9, day: 1, hour: 0, minute: 0)), sortIndex: 0)
        try expect(
            LocalCLIFreeWindow.state(expiredFree, now: now, timeZone: tz) == .expired,
            "past endsOn is expired")
        let evidence = passedEvidence(provider: .openCode, model: "mimo-v2.5-free")
        let snapshot = try loaded(evidence: [evidence], freeFacts: [expiredFree])
        try expect(
            LocalCLIModelDispatch.allows(
                snapshot: snapshot, binding: binding(provider: .openCode, model: "mimo-v2.5-free"), now: now),
            "expired free does not demote a passing model test")
        let rows = LocalCLIModelAvailabilityPresentation.rows(
            snapshot: snapshot, provider: .openCode,
            binding: binding(provider: .openCode, model: "mimo-v2.5-free"),
            now: now, timeZone: tz, includeDocumentedFreeFacts: false)
        let row = try row(rows, "mimo-v2.5-free")
        try expect(row.window == .expired, "free window expired")
        try expect(row.testStatus == .passed, "test status still passed")
        try expect(row.dispatchEligible, "dispatch still uses test evidence")
        try expect(
            LocalCLIModelAvailabilityPresentation.deadlineText(row.deadline, window: row.window, language: .zh)
                .contains("已过期"),
            "expired deadline label")
    }

    private static func testMissingSourceRejected() throws {
        let json = """
            {"version":1,"evidence":[],"freeFacts":[{"provider":"openCode","modelID":"mimo-v2.5-free","label":"mimo-v2.5-free","confirmedOn":"2026-09-11"}]}
            """
        switch LocalCLIModelAvailabilityStore.decode(Data(json.utf8), now: now) {
        case .success:
            throw FixtureFailure.assertion("missing source must reject")
        case .failure(let failure):
            try expect(failure == .invalidContent, "missing source is invalidContent")
        }
    }

    private static func testSymlinkRejected() throws {
        try withRoot { root in
            let file = root.appendingPathComponent(LocalCLIModelAvailabilityLimits.fileName)
            let target = root.appendingPathComponent("target.json")
            try Data("{\"version\":1,\"evidence\":[],\"freeFacts\":[]}".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            let snapshot = LocalCLIModelAvailabilityStore.load(root: root, now: now)
            guard case .rejected("symlink") = snapshot.origin else {
                throw FixtureFailure.assertion("symlink origin \(snapshot.origin)")
            }
            try expect(snapshot.evidence.isEmpty, "symlink yields no evidence")
        }
        try withRoot { root in
            let real = root.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            let linkedRoot = root.appendingPathComponent("linked-root")
            try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: real)
            let snapshot = LocalCLIModelAvailabilityStore.load(root: linkedRoot, now: now)
            guard case .rejected("symlink") = snapshot.origin else {
                throw FixtureFailure.assertion("symlink root origin \(snapshot.origin)")
            }
        }
    }

    private static func testOversizedRejected() throws {
        try withRoot { root in
            let file = root.appendingPathComponent(LocalCLIModelAvailabilityLimits.fileName)
            try Data(repeating: 0x7B, count: LocalCLIModelAvailabilityLimits.maximumFileBytes + 1).write(to: file)
            let snapshot = LocalCLIModelAvailabilityStore.load(root: root, now: now)
            guard case .rejected("oversized") = snapshot.origin else {
                throw FixtureFailure.assertion("oversized origin \(snapshot.origin)")
            }
        }
    }

    private static func testInvalidVersionRejected() throws {
        switch LocalCLIModelAvailabilityStore.decode(Data("{\"version\":2,\"evidence\":[],\"freeFacts\":[]}".utf8), now: now)
        {
        case .success:
            throw FixtureFailure.assertion("version 2 must reject")
        case .failure(let failure):
            try expect(failure == .invalidVersion, "version mismatch")
        }
    }

    private static func testMinimumReturnBoundaries() throws {
        let unmatched = mutate(passedEvidence(), matched: false)
        let tools = mutate(passedEvidence(), toolCalls: 1)
        let exit = mutate(passedEvidence(), exitCode: 1)
        try expect(!LocalCLIModelEvidenceContract.minimumReturnHolds(unmatched), "matched false")
        try expect(!LocalCLIModelEvidenceContract.minimumReturnHolds(tools), "toolCalls != 0")
        try expect(!LocalCLIModelEvidenceContract.minimumReturnHolds(exit), "exitCode != 0")
        for evidence in [unmatched, tools, exit] {
            let snapshot = try loaded(evidence: [evidence])
            try expect(
                LocalCLIModelDispatch.reason(snapshot: snapshot, binding: binding(), now: now)
                    == .invalidMinimumReturn,
                "minimum return blocks dispatch")
        }
    }

    private static func testEmailIdentityRejected() throws {
        let json = object([
            "version": 1,
            "evidence": [
                [
                    "provider": "workBuddy",
                    "modelID": "hy3",
                    "requestedModel": "hy3",
                    "observedActualModel": "hy3",
                    "cliVersion": "2.137.1",
                    "executableHash": hashA,
                    "environmentFingerprint": envA,
                    "accountFingerprint": "user@example.invalid",
                    "matched": true,
                    "toolCalls": 0,
                    "exitCode": 0,
                    "testedAt": iso(now.addingTimeInterval(-60)),
                    "validUntil": iso(now.addingTimeInterval(3_600)),
                    "status": "passed",
                ]
            ],
            "freeFacts": [],
        ])
        switch LocalCLIModelAvailabilityStore.decode(json, now: now) {
        case .success:
            throw FixtureFailure.assertion("email fingerprint must reject")
        case .failure(let failure):
            try expect(failure == .invalidContent, "email identity is invalidContent")
        }
        try expect(LocalCLIModelEvidenceContract.fingerprint("user@example.invalid") == nil, "example.invalid email")
        try expect(LocalCLIModelEvidenceContract.fingerprint(acctA) == acctA, "synthetic fingerprint allowed")
    }

    private static func testNonPublicSourceURLRejected() throws {
        let json = object([
            "version": 1,
            "evidence": [],
            "freeFacts": [
                [
                    "provider": "openCode",
                    "modelID": "mimo-v2.5-free",
                    "label": "mimo-v2.5-free",
                    "source": "official",
                    "sourceURL": "https://example.invalid/pricing",
                    "confirmedOn": "2026-09-11",
                ]
            ],
        ])
        switch LocalCLIModelAvailabilityStore.decode(json, now: now) {
        case .success:
            throw FixtureFailure.assertion("non-public sourceURL must reject")
        case .failure(let failure):
            try expect(failure == .invalidContent, "example.invalid URL rejected")
        }
    }

    private static func testFutureFreeStart() throws {
        let fact = LocalCLIFreeFact(
            provider: .workBuddy, modelIDs: ["hy4-preview-f"], label: "HY4", source: .userConfirmed, sourceURL: nil,
            confirmedOn: LocalCLIDocumentedFreeFacts.confirmedOn,
            startsOn: .civil(LocalCLICivilInstant(year: 2026, month: 12, day: 1, hour: nil, minute: nil)),
            endsOn: .unknown, sortIndex: 1)
        try expect(LocalCLIFreeWindow.state(fact, now: now, timeZone: tz) == .upcoming, "future startsOn")
        let text = LocalCLIModelAvailabilityPresentation.deadlineText(.unknown, window: .upcoming, language: .en)
        try expect(text.contains("not started"), "upcoming english")
    }

    private static func testDocumentedCatalogIsNotDispatch() throws {
        try expectEqual(
            LocalCLIDocumentedFreeFacts.workBuddy.map(\.label),
            ["DeepSeek 4 Flash", "HY4", "HY3"],
            "WorkBuddy original labels")
        try expectEqual(
            LocalCLIDocumentedFreeFacts.workBuddy.map(\.primaryModelID),
            ["deepseek-v4.1-flash", "hy4-preview-f", "hy3"],
            "WorkBuddy model order")
        try expect(LocalCLIDocumentedFreeFacts.openCodeMimoFree.label == "mimo-v2.5-free", "OpenCode original free id")
        try expect(LocalCLIDocumentedFreeFacts.openCodeMimoFree.source == .official, "OpenCode official")
        try expect(
            LocalCLIDocumentedFreeFacts.zcodeGLM53Flash.endsOn.displayText == "2026-09-15 23:59",
            "ZCode stated deadline")
        try expect(LocalCLIDocumentedFreeFacts.zcodeGLM53Flash.sourceURL?.host == "zcode.z.ai", "ZCode public URL")
        try expect(
            LocalCLIFreeWindow.state(LocalCLIDocumentedFreeFacts.zcodeGLM53Flash, now: now, timeZone: tz) == .active,
            "ZCode trial still inside stated window on 2026-09-11")
        let empty = LocalCLIModelAvailabilitySnapshot.empty
        try expect(
            !LocalCLIModelDispatch.allows(
                snapshot: empty, binding: binding(provider: .zcode, model: "glm-5.3-flash"), now: now),
            "catalog does not make ZCode requestable")
        let rows = LocalCLIModelAvailabilityPresentation.rows(
            snapshot: empty, provider: .zcode, binding: binding(provider: .zcode, model: "glm-5.3-flash"),
            now: now, timeZone: tz)
        let flash = try row(rows, "glm-5.3-flash")
        try expect(flash.originalFreeWord == "GLM-5.3/Flash", "ZCode original label")
        try expect(!flash.dispatchEligible, "ZCode catalog row is not requestable")
        try expect(flash.testStatus == .untested, "ZCode remains untested without evidence")
        let later = Date(timeIntervalSince1970: 1_789_545_600) // 2026-09-16T08:00:00Z, after 23:59+08
        try expect(
            LocalCLIFreeWindow.state(LocalCLIDocumentedFreeFacts.zcodeGLM53Flash, now: later, timeZone: tz)
                == .expired,
            "ZCode trial expired after stated 23:59")
    }

    private static func testPresentationLanguages() throws {
        try expect(
            LocalCLIModelAvailabilityPresentation.heading(.zh) == "模型可用性",
            "zh heading")
        try expect(
            LocalCLIModelAvailabilityPresentation.heading(.en) == "Model availability",
            "en heading")
        try expect(
            LocalCLIModelAvailabilityPresentation.dispatchText(false, language: .zh) == "不可用于受管派单",
            "zh not eligible")
        try expect(
            LocalCLIModelAvailabilityPresentation.dispatchText(false, language: .en)
                == "Not eligible for managed dispatch",
            "en not eligible")
        try expect(
            LocalCLIModelAvailabilityPresentation.testText(status: .untested, testedAt: nil, language: .zh)
                .contains("未测试"),
            "zh untested")
        try expect(
            LocalCLIModelAvailabilityPresentation.sourceText(.userConfirmed, language: .en) == "Source user confirmed",
            "en user confirmed")
    }

    private static func testRejectedLoadPreservesOriginalFile() throws {
        try withRoot { root in
            let file = root.appendingPathComponent(LocalCLIModelAvailabilityLimits.fileName)
            let original = Data("{\"version\":2,\"evidence\":[],\"freeFacts\":[]}".utf8)
            try original.write(to: file)
            let before = try Data(contentsOf: file)
            let snapshot = LocalCLIModelAvailabilityStore.load(root: root, now: now)
            guard case .rejected("invalid_version") = snapshot.origin else {
                throw FixtureFailure.assertion("invalid version origin \(snapshot.origin)")
            }
            try expect(snapshot.evidence.isEmpty, "rejected snapshot has no in-memory evidence")
            try expect(!LocalCLIModelDispatch.allows(snapshot: snapshot, binding: binding(), now: now),
                "rejected file cannot dispatch")
            let after = try Data(contentsOf: file)
            try expect(after == before, "invalid version must keep original bytes")
            try expect(FileManager.default.fileExists(atPath: file.path), "original file remains")
        }
        try withRoot { root in
            let file = root.appendingPathComponent(LocalCLIModelAvailabilityLimits.fileName)
            let original = Data("{\"version\":1,\"evidence\":[],\"freeFacts\":[{\"provider\":\"openCode\",\"modelID\":\"mimo-v2.5-free\",\"label\":\"mimo-v2.5-free\",\"confirmedOn\":\"2026-09-11\"}]}".utf8)
            try original.write(to: file)
            let snapshot = LocalCLIModelAvailabilityStore.load(root: root, now: now)
            guard case .rejected("invalid_content") = snapshot.origin else {
                throw FixtureFailure.assertion("missing source origin \(snapshot.origin)")
            }
            try expect(try Data(contentsOf: file) == original, "missing source keeps original bytes")
        }
        try withRoot { root in
            let file = root.appendingPathComponent(LocalCLIModelAvailabilityLimits.fileName)
            let payload = object([
                "version": 1,
                "evidence": [[
                    "provider": "workBuddy", "modelID": "hy3", "requestedModel": "hy3",
                    "observedActualModel": "hy3", "cliVersion": "2.137.1", "executableHash": hashA,
                    "environmentFingerprint": envA, "accountFingerprint": "user@example.invalid",
                    "matched": true, "toolCalls": 0, "exitCode": 0,
                    "testedAt": iso(now.addingTimeInterval(-60)),
                    "validUntil": iso(now.addingTimeInterval(3_600)), "status": "passed",
                ]],
                "freeFacts": [],
            ])
            try payload.write(to: file)
            let snapshot = LocalCLIModelAvailabilityStore.load(root: root, now: now)
            guard case .rejected = snapshot.origin else {
                throw FixtureFailure.assertion("email identity origin \(snapshot.origin)")
            }
            try expect(try Data(contentsOf: file) == payload, "email identity keeps original bytes")
        }
        try withRoot { root in
            let file = root.appendingPathComponent(LocalCLIModelAvailabilityLimits.fileName)
            let target = root.appendingPathComponent("target.json")
            let original = Data("{\"version\":1,\"evidence\":[],\"freeFacts\":[]}".utf8)
            try original.write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            let snapshot = LocalCLIModelAvailabilityStore.load(root: root, now: now)
            guard case .rejected("symlink") = snapshot.origin else {
                throw FixtureFailure.assertion("symlink origin \(snapshot.origin)")
            }
            try expect(try Data(contentsOf: target) == original, "symlink target kept")
            var isDir: ObjCBool = false
            try expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), "symlink name kept")
        }
        try withRoot { root in
            let file = root.appendingPathComponent(LocalCLIModelAvailabilityLimits.fileName)
            let original = Data(repeating: 0x7B, count: LocalCLIModelAvailabilityLimits.maximumFileBytes + 1)
            try original.write(to: file)
            let snapshot = LocalCLIModelAvailabilityStore.load(root: root, now: now)
            guard case .rejected("oversized") = snapshot.origin else {
                throw FixtureFailure.assertion("oversized origin \(snapshot.origin)")
            }
            try expect(try Data(contentsOf: file) == original, "oversized file kept")
        }
    }

    private static func testUnstatedDeadlineCopy() throws {
        let zh = LocalCLIModelAvailabilityPresentation.deadlineText(.unknown, window: .unknown, language: .zh)
        let en = LocalCLIModelAvailabilityPresentation.deadlineText(.unknown, window: .unknown, language: .en)
        try expect(zh == "截止 未注明", "zh unstated")
        try expect(en == "End date not stated", "en unstated")
        let rows = LocalCLIModelAvailabilityPresentation.rows(
            snapshot: .empty, provider: .workBuddy, binding: binding(), now: now, timeZone: tz)
        let flash = try row(rows, "deepseek-v4.1-flash")
        try expect(flash.originalFreeWord == "DeepSeek 4 Flash", "keep original free label")
        try expect(
            LocalCLIModelAvailabilityPresentation.deadlineText(flash.deadline, window: flash.window, language: .zh)
                == "截止 未注明",
            "WorkBuddy catalog deadline unstated")
        let open = LocalCLIModelAvailabilityPresentation.rows(
            snapshot: .empty, provider: .openCode,
            binding: binding(provider: .openCode, model: "mimo-v2.5-free"), now: now, timeZone: tz)
        let mimo = try row(open, "mimo-v2.5-free")
        try expect(mimo.originalFreeWord == "mimo-v2.5-free", "keep original free id")
        try expect(
            LocalCLIModelAvailabilityPresentation.deadlineText(mimo.deadline, window: mimo.window, language: .zh)
                == "截止 未注明",
            "OpenCode catalog deadline unstated")
    }

    private static func testTimezoneUnstatedForCivilDeadline() throws {
        let text = LocalCLIModelAvailabilityPresentation.deadlineText(
            LocalCLIDocumentedFreeFacts.zcodeGLM53Flash.endsOn, window: .active, language: .zh)
        try expect(text.contains("2026-09-15 23:59"), "keep stated civil deadline")
        try expect(text.contains("时区未注明"), "civil deadline timezone unstated")
        try expect(!text.contains("未知"), "do not say 未知")
        let rows = LocalCLIModelAvailabilityPresentation.rows(
            snapshot: .empty, provider: .zcode,
            binding: binding(provider: .zcode, model: "glm-5.3-flash"), now: now, timeZone: tz)
        let flash = try row(rows, "glm-5.3-flash")
        try expect(flash.sourceURL?.host == "zcode.z.ai", "keep public source URL")
        try expect(
            LocalCLIModelAvailabilityPresentation.sourceURLText(flash.sourceURL, language: .zh)?
                .contains("https://zcode.z.ai") == true,
            "source URL text")
        try expect(flash.startsOn == .unknown, "ZCode start unstated")
        try expect(LocalCLIModelAvailabilityPresentation.startText(flash.startsOn, language: .zh) == nil,
            "omit unstated start")
    }

    private static func testGrokAliasIsNotRemapped() throws {
        try expect(
            LocalCLIDocumentedModelAliases.admittedModelID(provider: .grok, requested: "grok-4.6-build")
                == "grok-4.6-build",
            "canonical grok admitted")
        try expect(
            LocalCLIDocumentedModelAliases.admittedModelID(provider: .grok, requested: "grok-4.6") == nil,
            "grok-4.6 alias not invented")
        try expect(
            LocalCLIDocumentedModelAliases.admittedModelID(provider: .grok, requested: "grok-4.5") == nil,
            "grok-4.5 stays untested")
        try expect(
            LocalCLIDocumentedModelAliases.admittedModelID(provider: .grok, requested: "grok-4") == nil,
            "no prefix wildcard")
        try expect(!LocalCLIDocumentedModelAliases.remapsGrok46Alias("grok-4.6"), "no remap")
        let snapshot = try loaded(evidence: [
            passedEvidence(provider: .grok, model: "grok-4.6-build"),
        ])
        try expect(
            LocalCLIModelDispatch.allows(
                snapshot: snapshot, binding: binding(provider: .grok, model: "grok-4.6-build"), now: now),
            "canonical grok evidence can dispatch")
        try expect(
            LocalCLIModelDispatch.reason(
                snapshot: snapshot, binding: binding(provider: .grok, model: "grok-4.6"), now: now)
                == .untested,
            "grok-4.6 request stays untested")
        try expect(
            LocalCLIModelDispatch.reason(
                snapshot: snapshot, binding: binding(provider: .grok, model: "grok-4.5"), now: now)
                == .untested,
            "grok-4.5 stays untested")
        let aliasEvidence = try loaded(evidence: [passedEvidence(provider: .grok, model: "grok-4.6")])
        try expect(
            !LocalCLIModelDispatch.allows(
                snapshot: aliasEvidence, binding: binding(provider: .grok, model: "grok-4.6"), now: now),
            "grok-4.6 evidence does not admit alias")
        try expect(
            !LocalCLIModelDispatch.allows(
                snapshot: aliasEvidence, binding: binding(provider: .grok, model: "grok-4.6-build"), now: now),
            "alias evidence does not unlock canonical")
    }

    private static func testReceiptBridgeContract() throws {
        let marker = "synthetic-marker-0911v11"
        let expectation = LocalCLIModelReceiptBridge.Expectation(
            provider: .grok, modelID: "grok-4.6-build", environmentFingerprint: envA,
            accountFingerprint: acctA, executableHash: hashA, randomMarker: marker, now: now,
            cliVersion: "1.0.25")
        let complete = receiptJSON(marker: marker)
        switch LocalCLIModelReceiptBridge.normalize(data: object(complete), expectation: expectation) {
        case .accepted(let evidence):
            try expect(evidence.modelID == "grok-4.6-build", "canonical model")
            try expect(evidence.toolCalls == 0, "zero tools")
            try expect(evidence.exitCode == 0, "zero exit")
            try expect(evidence.matched, "exact marker matched")
            try expect(
                LocalCLIModelReceiptBridge.dispatchAllows(
                    .accepted(evidence),
                    binding: binding(provider: .grok, model: "grok-4.6-build", cliVersion: "1.0.25"),
                    now: now),
                "normalized grok evidence dispatchable")
        case let other:
            throw FixtureFailure.assertion("complete receipt \(other)")
        }

        var missingMarker = complete
        missingMarker.removeValue(forKey: "randomMarker")
        switch LocalCLIModelReceiptBridge.normalize(data: object(missingMarker), expectation: expectation) {
        case .untested(let field):
            try expect(field == "randomMarker", "missing marker is untested")
        default:
            throw FixtureFailure.assertion("missing marker must be untested")
        }
        try expect(
            !LocalCLIModelReceiptBridge.dispatchAllows(
                .untested("randomMarker"), binding: binding(provider: .grok, model: "grok-4.6-build"), now: now),
            "untested receipt cannot dispatch")

        var handwritten = complete
        handwritten["randomMarker"] = "guessed-marker"
        switch LocalCLIModelReceiptBridge.normalize(data: object(handwritten), expectation: expectation) {
        case .invalid(let reason):
            try expect(reason == "marker_mismatch", "guessed marker invalid")
        default:
            throw FixtureFailure.assertion("guessed marker must be invalid")
        }

        for model in ["grok-4.6", "grok-4.5", "grok-4.6-preview"] {
            var alias = complete
            alias["requestedModel"] = model
            alias["actualModel"] = model
            switch LocalCLIModelReceiptBridge.normalize(data: object(alias), expectation: expectation) {
            case .untested(let field):
                try expect(field == "alias_not_admitted", "\(model) not remapped")
            default:
                throw FixtureFailure.assertion("\(model) must stay untested")
            }
        }

        var wrongActual = complete
        wrongActual["actualModel"] = "grok-4.6"
        switch LocalCLIModelReceiptBridge.normalize(data: object(wrongActual), expectation: expectation) {
        case .invalid(let reason):
            try expect(reason == "model_mismatch", "requested/actual must match")
        default:
            throw FixtureFailure.assertion("wrong actual must be invalid")
        }

        var tools = complete
        tools["toolsDisabled"] = false
        tools.removeValue(forKey: "toolCalls")
        switch LocalCLIModelReceiptBridge.normalize(data: object(tools), expectation: expectation) {
        case .invalid(let reason):
            try expect(reason == "tools_enabled", "tools must be disabled")
        default:
            throw FixtureFailure.assertion("tools enabled must be invalid")
        }

        var exit = complete
        exit["exitCode"] = 1
        switch LocalCLIModelReceiptBridge.normalize(data: object(exit), expectation: expectation) {
        case .invalid(let reason):
            try expect(reason == "nonzero_exit", "nonzero exit")
        default:
            throw FixtureFailure.assertion("nonzero exit must be invalid")
        }

        var identity = complete
        identity["accountKey"] = acctB
        switch LocalCLIModelReceiptBridge.normalize(data: object(identity), expectation: expectation) {
        case .invalid(let reason):
            try expect(reason == "identity_mismatch", "wrong account")
        default:
            throw FixtureFailure.assertion("wrong account must be invalid")
        }

        var missingProduct = complete
        missingProduct.removeValue(forKey: "product")
        switch LocalCLIModelReceiptBridge.normalize(data: object(missingProduct), expectation: expectation) {
        case .untested(let field):
            try expect(field == "product", "missing product untested")
        default:
            throw FixtureFailure.assertion("missing product must be untested")
        }

        try withRoot { root in
            let file = root.appendingPathComponent("grok-4.6-build.json")
            let original = object(complete)
            try original.write(to: file)
            let accepted = LocalCLIModelReceiptBridge.normalizeFile(url: file, expectation: expectation)
            guard case .accepted = accepted else {
                throw FixtureFailure.assertion("file receipt \(accepted)")
            }
            try expect(try Data(contentsOf: file) == original, "accepted receipt file kept")

            let link = root.appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            let rejected = LocalCLIModelReceiptBridge.normalizeFile(url: link, expectation: expectation)
            guard case .invalid("symlink") = rejected else {
                throw FixtureFailure.assertion("symlink receipt \(rejected)")
            }
            try expect(try Data(contentsOf: file) == original, "symlink target kept after reject")
        }
    }

    private static func receiptJSON(marker: String) -> [String: Any] {
        [
            "schemaVersion": 1,
            "product": "grok",
            "requestedModel": "grok-4.6-build",
            "actualModel": "grok-4.6-build",
            "executableSHA256": String(hashA.dropFirst(7)),
            "cliVersion": "1.0.25",
            "accountKey": acctA,
            "environmentKey": envA,
            "isolatedEnvironment": true,
            "toolsDisabled": true,
            "exitCode": 0,
            "outputMatched": true,
            "randomMarker": marker,
            "capturedAt": now.addingTimeInterval(-60).timeIntervalSince1970,
        ]
    }

    private static func testInjectedBindingAndNow() throws {
        try withRoot { root in
            let payload = object([
                "version": 1,
                "evidence": [evidenceJSON()],
                "freeFacts": [
                    [
                        "provider": "workBuddy",
                        "modelID": "deepseek-v4.1-flash",
                        "label": "DeepSeek 4 Flash",
                        "source": "userConfirmed",
                        "confirmedOn": "2026-09-11",
                        "startsOn": NSNull(),
                        "endsOn": NSNull(),
                        "sortIndex": 0,
                    ]
                ],
            ])
            try payload.write(to: root.appendingPathComponent(LocalCLIModelAvailabilityLimits.fileName))
            let current = binding()
            let snapshot = LocalCLIModelAvailabilityStore.load(root: root, now: now, binding: current)
            try expect(snapshot.origin == .loaded, "loaded origin")
            try expect(LocalCLIModelDispatch.allows(snapshot: snapshot, binding: current, now: now), "injected now")
            try expect(
                !LocalCLIModelDispatch.allows(
                    snapshot: snapshot, binding: binding(environment: envB), now: now),
                "injected env mismatch")
            let envMismatch = LocalCLIModelDispatch.reason(
                snapshot: snapshot, binding: binding(environment: envB), now: now)
            try expect(envMismatch == .environmentMismatch, "environment mismatch reason")
        }
    }

    private static func passedEvidence(
        provider: LocalCLIKind = .workBuddy,
        model: String = "deepseek-v4.1-flash",
        account: String = acctA,
        environment: String = envA
    ) -> LocalCLIModelTestEvidence {
        LocalCLIModelTestEvidence(
            provider: provider, modelID: model, requestedModel: model, observedActualModel: model,
            cliVersion: "2.137.1", executableHash: hashA, environmentFingerprint: environment,
            accountFingerprint: account, matched: true, toolCalls: 0, exitCode: 0,
            testedAt: now.addingTimeInterval(-60), validUntil: now.addingTimeInterval(3_600),
            recordedStatus: .passed)
    }

    private static func mutate(
        _ evidence: LocalCLIModelTestEvidence,
        matched: Bool? = nil,
        toolCalls: Int? = nil,
        exitCode: Int? = nil
    ) -> LocalCLIModelTestEvidence {
        LocalCLIModelTestEvidence(
            provider: evidence.provider, modelID: evidence.modelID, requestedModel: evidence.requestedModel,
            observedActualModel: evidence.observedActualModel, cliVersion: evidence.cliVersion,
            executableHash: evidence.executableHash, environmentFingerprint: evidence.environmentFingerprint,
            accountFingerprint: evidence.accountFingerprint, matched: matched ?? evidence.matched,
            toolCalls: toolCalls ?? evidence.toolCalls, exitCode: exitCode ?? evidence.exitCode,
            testedAt: evidence.testedAt, validUntil: evidence.validUntil, recordedStatus: evidence.recordedStatus)
    }

    private static func binding(
        provider: LocalCLIKind = .workBuddy,
        model: String = "deepseek-v4.1-flash",
        account: String = acctA,
        environment: String = envA,
        cliVersion: String = "2.137.1"
    ) -> LocalCLICurrentBinding {
        LocalCLICurrentBinding(
            provider: provider, modelID: model, environmentFingerprint: environment,
            accountFingerprint: account, cliVersion: cliVersion, executableHash: hashA)
    }

    private static func loaded(
        evidence: [LocalCLIModelTestEvidence],
        freeFacts: [LocalCLIFreeFact] = []
    ) throws -> LocalCLIModelAvailabilitySnapshot {
        let data = object([
            "version": 1,
            "evidence": evidence.map(evidenceJSON),
            "freeFacts": freeFacts.map(freeJSON),
        ])
        switch LocalCLIModelAvailabilityStore.decode(data, now: now) {
        case .success(let snapshot):
            return snapshot
        case .failure(let failure):
            throw FixtureFailure.assertion("decode \(failure)")
        }
    }

    private static func evidenceJSON(_ evidence: LocalCLIModelTestEvidence? = nil) -> [String: Any] {
        let item = evidence ?? passedEvidence()
        return [
            "provider": item.provider.rawValue,
            "modelID": item.modelID,
            "requestedModel": item.requestedModel,
            "observedActualModel": item.observedActualModel,
            "cliVersion": item.cliVersion,
            "executableHash": item.executableHash,
            "environmentFingerprint": item.environmentFingerprint,
            "accountFingerprint": item.accountFingerprint,
            "matched": item.matched,
            "toolCalls": item.toolCalls,
            "exitCode": item.exitCode,
            "testedAt": iso(item.testedAt),
            "validUntil": iso(item.validUntil),
            "status": item.recordedStatus.rawValue,
        ]
    }

    private static func freeJSON(_ fact: LocalCLIFreeFact) -> [String: Any] {
        var record: [String: Any] = [
            "provider": fact.provider.rawValue,
            "modelIDs": fact.modelIDs,
            "label": fact.label,
            "source": fact.source.rawValue,
            "confirmedOn": fact.confirmedOn.displayText,
            "sortIndex": fact.sortIndex,
        ]
        if let url = fact.sourceURL { record["sourceURL"] = url.absoluteString }
        record["startsOn"] = jsonInstant(fact.startsOn)
        record["endsOn"] = jsonInstant(fact.endsOn)
        return record
    }

    private static func jsonInstant(_ instant: LocalCLIOptionalInstant) -> Any {
        switch instant {
        case .unknown: NSNull()
        case .civil(let civil): civil.hasClock ? civil.displayText.replacingOccurrences(of: " ", with: "T") : civil.displayText
        case .absolute(let date): iso(date)
        }
    }

    private static func evidenceJSON() -> [String: Any] { evidenceJSON(nil) }

    private static func row(_ rows: [LocalCLIModelAvailabilityRow], _ modelID: String) throws -> LocalCLIModelAvailabilityRow {
        guard let row = rows.first(where: { $0.modelID == modelID }) else {
            throw FixtureFailure.assertion("missing row \(modelID)")
        }
        return row
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func object(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "model-availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
