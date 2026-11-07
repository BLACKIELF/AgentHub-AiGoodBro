import Foundation

struct ModelInferencePerformanceHistory: Equatable {}
struct AgentTokenShare: Equatable {}
enum TaskRuntimeState { case recorded }
enum TaskSourceKind { case fixture }
enum TaskDisplayState { case fixture }
enum TaskStateBasis { case fixture }
enum WidgetLanguage { case fixture
    static func storedOrAutomatic() -> Self { .fixture }
    func text(_ zh: String, _ en: String) -> String { en }
}
struct FeishuMaskedAccount { let value: String }
struct FeishuMessageOptions { var includesAccountLabel = true }
enum FeishuWebhookError: Error { case invalidNotification, cancelled, transportFailed, invalidResponse, httpStatus(Int), rejected(Int), missingWebhook }
struct Credential { let endpoint = URL(string: "https://fixture.invalid/not-real")!; let generation: UInt64 = 1 }
struct FakeBytes: AsyncSequence {
    typealias Element = UInt8
    struct Iterator: AsyncIteratorProtocol {
        var values = Array("{\"code\":0}".utf8)
        mutating func next() async throws -> UInt8? { values.isEmpty ? nil : values.removeFirst() }
    }
    struct ByteTask { func cancel() {} }
    let task = ByteTask()
    func makeAsyncIterator() -> Iterator { Iterator() }
}
@MainActor final class FakeSession {
    var posts = 0
    var beforePost: (() -> Void)?
    var failTransport = false
    func bytes(for request: URLRequest) async throws -> (FakeBytes, URLResponse) {
        posts += 1
        beforePost?()
        if failTransport { throw FeishuWebhookError.transportFailed }
        return (FakeBytes(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class FeishuWebhookService {
    static let maximumResponseBytes = 4096
    let session = FakeSession()
    var currentGeneration: UInt64 = 1
    var credentialRead: ((Result<Credential, FeishuWebhookError>) -> Void)?
    var admissionCalls = 0
    static func parseResponse(_ data: Data) -> Result<Void, FeishuWebhookError> { .success(()) }
    static func manualResetPayload(_ value: CodexManualResetNotice, sourceAccount: FeishuMaskedAccount, messageOptions: FeishuMessageOptions) throws -> Data {
        guard value.isValid else { throw FeishuWebhookError.invalidNotification }
        return Data("{}".utf8)
    }
    func readCredential(completion: @escaping (Result<Credential, FeishuWebhookError>) -> Void) { credentialRead = completion }
    func isCurrentCredential(_ generation: UInt64) -> Bool { generation == currentGeneration }
    func finishCredential() { let callback = credentialRead; credentialRead = nil; callback?(.success(Credential())) }
__SENDER_METHODS__
}
struct Identity { let accountID: String }
struct Profile {
    let id: String
    var account: String
    let codexHomeURL = URL(fileURLWithPath: "/synthetic-profile")
    struct Snapshot { let accountID: String? }
    var lastSnapshot: Snapshot? { .init(accountID: account) }
    func matchesRecordedCredential(_ identity: Identity) -> Bool { identity.accountID == account }
}
struct ProfileStore { var profiles: [Profile] }
enum CodexOfficialProfileReader {
    static var identity: Identity? = .init(accountID: "synthetic-account")
    static func credentialIdentity(codexHomeURL: URL) -> Identity? { identity }
}
enum CodexResetCreditController {
    struct ManualResetConfirmation {
        let eventID: String, profileID: String, accountKey: String
        let confirmedAt: Date
    }
}
@MainActor final class Harness {
    var hasStarted = true, isPreview = false, enabled = true, configured = true
    var configurationRevision = UUID(), resetNoticeRunRevision = UUID()
    var profileStore = ProfileStore(profiles: [.init(id: "synthetic-profile", account: "synthetic-account")])
    let resetNoticeDeliveryStore: CodexResetNoticeDeliveryStore
    let feishuWebhookService = FeishuWebhookService()
    var feishuMessageOptions = FeishuMessageOptions()
    var feishuNotificationMessage = "unchanged"
    var resetNoticeTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    init(_ directory: URL) { resetNoticeDeliveryStore = .init(directory: directory) }
    func maskedAccount(for profile: Profile) -> FeishuMaskedAccount? { .init(value: "Masked account") }
    func resetNoticeChannels(expiry: Bool) -> [CodexResetNoticeChannel] { enabled ? [.feishu] : [] }
    func resetNoticeRevision(_ channel: CodexResetNoticeChannel, expiry: Bool, requiringReadiness: Bool = true) -> UUID? {
        hasStarted && !isPreview && enabled && (!requiringReadiness || configured) ? configurationRevision : nil
    }
    func retry() { queuePendingManualResetNotices() }
__USAGE_METHODS__
}
@main struct ManualResetNoticeFixture {
    static var checks = 0
    static func expect(_ condition: Bool, _ description: String) {
        checks += 1
        precondition(condition, description)
    }
    @MainActor static func tick() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(nanoseconds: 2_000_000) }
    static func receipt(_ key: String = "one", profile: String = "synthetic-profile", account: String = "synthetic-account") -> CodexResetCreditController.ManualResetConfirmation {
        .init(eventID: "manual-reset-" + CodexResetNoticeKey.hash(key), profileID: profile, accountKey: CodexResetNoticeKey.hash(account), confirmedAt: Date().addingTimeInterval(-1))
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manual-runtime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let good = Harness(root.appendingPathComponent("good"))
        let event = receipt()
        good.recordManualResetConfirmed(event)
        good.recordManualResetConfirmed(event)
        await tick()
        expect(good.resetNoticeTasks.count == 1, "double callback has one task")
        good.feishuWebhookService.finishCredential()
        await tick()
        expect(good.feishuWebhookService.session.posts == 1, "confirmed success sends once")
        expect(try good.resetNoticeDeliveryStore.read().records.values.first?.phase == .sent, "accepted success persisted")
        expect(good.feishuNotificationMessage.contains("API accepted"), "accepted reports API only")
        good.recordManualResetConfirmed(event)
        await tick()
        expect(good.feishuWebhookService.session.posts == 1, "sent duplicate never sends")
        let disabled = Harness(root.appendingPathComponent("disabled"))
        disabled.enabled = false
        disabled.recordManualResetConfirmed(event)
        await tick()
        expect(disabled.resetNoticeTasks.isEmpty && disabled.feishuWebhookService.session.posts == 0, "disabled never queues")
        expect(try disabled.resetNoticeDeliveryStore.read().records.values.first?.phase == .baseline, "disabled records fact not intent")
        disabled.enabled = true; disabled.retry(); await tick()
        expect(disabled.resetNoticeTasks.isEmpty, "later enable never retroactively queues")
        let identity = Harness(root.appendingPathComponent("identity"))
        identity.recordManualResetConfirmed(receipt(account: "wrong"))
        identity.recordManualResetConfirmed(receipt(profile: "wrong"))
        expect(try identity.resetNoticeDeliveryStore.read().records.isEmpty, "wrong profile/account denied")
        CodexOfficialProfileReader.identity = nil
        identity.recordManualResetConfirmed(event)
        expect(identity.resetNoticeTasks.isEmpty, "missing credential identity denied")
        CodexOfficialProfileReader.identity = .init(accountID: "synthetic-account")
        let changed = Harness(root.appendingPathComponent("changed"))
        changed.recordManualResetConfirmed(event); await tick()
        changed.enabled = false; changed.configurationRevision = UUID()
        changed.feishuWebhookService.finishCredential(); await tick()
        expect(changed.feishuWebhookService.session.posts == 0, "disabled during credential read means zero POST")
        expect(try changed.resetNoticeDeliveryStore.pendingManualResets().count == 1, "zero POST retains pending")
        let late = Harness(root.appendingPathComponent("late"))
        late.recordManualResetConfirmed(event); await tick()
        late.feishuWebhookService.session.beforePost = { late.configurationRevision = UUID() }
        late.feishuWebhookService.finishCredential(); await tick()
        expect(try late.resetNoticeDeliveryStore.read().records.values.first?.phase == .uncertain, "revision changes after POST are uncertain")
        late.retry(); await tick()
        expect(late.feishuWebhookService.session.posts == 1, "uncertain not automatically replayed")
        let lost = Harness(root.appendingPathComponent("lost"))
        lost.recordManualResetConfirmed(event); await tick()
        lost.feishuWebhookService.session.failTransport = true
        lost.feishuWebhookService.finishCredential(); await tick()
        expect(try lost.resetNoticeDeliveryStore.read().records.values.first?.phase == .uncertain, "transport error conservatively uncertain")
        let stopped = Harness(root.appendingPathComponent("stopped"))
        stopped.recordManualResetConfirmed(event); await tick()
        stopped.hasStarted = false; stopped.resetNoticeRunRevision = UUID()
        stopped.feishuWebhookService.finishCredential(); await tick()
        expect(stopped.feishuWebhookService.session.posts == 0, "stop prevents pending POST")
        let failed = Harness(root.appendingPathComponent("failed"))
        try FileManager.default.createDirectory(at: failed.resetNoticeDeliveryStore.url, withIntermediateDirectories: true)
        failed.recordManualResetConfirmed(event)
        expect(failed.resetNoticeTasks.isEmpty && failed.feishuNotificationMessage.contains("unavailable"), "persist failure never sends or claims delivery")
        let revoked = Harness(root.appendingPathComponent("revoked"))
        revoked.recordManualResetConfirmed(event); await tick()
        CodexOfficialProfileReader.identity = .init(accountID: "changed-account")
        revoked.feishuWebhookService.finishCredential(); await tick()
        expect(revoked.feishuWebhookService.session.posts == 0, "identity change during queue prevents POST")
        CodexOfficialProfileReader.identity = .init(accountID: "synthetic-account")
        let staleRecord = Harness(root.appendingPathComponent("stale-record"))
        staleRecord.recordManualResetConfirmed(event); await tick()
        staleRecord.feishuWebhookService.session.beforePost = {
            _ = try? staleRecord.resetNoticeDeliveryStore.recoverInterruptedSends()
        }
        staleRecord.feishuWebhookService.finishCredential(); await tick()
        expect(!staleRecord.feishuNotificationMessage.contains("API accepted") && staleRecord.feishuNotificationMessage.contains("record changed"), "rejected receipt persistence never claims accepted")
        expect(try staleRecord.resetNoticeDeliveryStore.read().records.values.first?.phase == .uncertain, "stale callback leaves uncertain phase untouched")
        let failedRecord = Harness(root.appendingPathComponent("failed-record"))
        failedRecord.recordManualResetConfirmed(event); await tick()
        failedRecord.feishuWebhookService.session.beforePost = {
            try? FileManager.default.removeItem(at: failedRecord.resetNoticeDeliveryStore.url)
            try? FileManager.default.createDirectory(at: failedRecord.resetNoticeDeliveryStore.url, withIntermediateDirectories: true)
        }
        failedRecord.feishuWebhookService.finishCredential(); await tick()
        expect(!failedRecord.feishuNotificationMessage.contains("API accepted") && failedRecord.feishuNotificationMessage.contains("resend is paused"), "disk failure after POST preserves uncertain wording and no retry")
        // Run the actual sender with a gate that changes between credential
        // completion admission and the separately scheduled transport Task.
        let sender = FeishuWebhookService()
        var gates = 0
        var cancelled = false
        sender.sendManualReset(.init(eventHash: String(repeating: "a", count: 64), profileHash: String(repeating: "b", count: 64), confirmedAt: Date()), sourceAccount: .init(value: "Masked"), messageOptions: .init(), shouldSend: {
            gates += 1
            return gates == 1
        }) { result in if case .failure(.cancelled) = result { cancelled = true } }
        sender.finishCredential(); await tick()
        expect(gates == 2 && cancelled, "actual transport Task repeats admission after scheduling")
        expect(sender.session.posts == 0, "changed option between tasks causes zero POST")
        print("PASS manual notice runtime: \(checks) checks; real callback/queue/transport-task admission, synthetic I/O")
    }
}
