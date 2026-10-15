final class RoutingStorage: MessageChannelCredentialStoring {
    var configured = true
    func load(_ kind: MessageChannelKind, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void) {
        let value = kind == .telegram
            ? MessageChannelCredential(secret: "1234567890:AAExampleSyntheticToken0000000000000", target: "-100200300")
            : MessageChannelCredential(secret: "01234567-89ab-cdef-0123-456789abcdef", target: nil)
        completion(.success(configured ? value : nil))
    }
    func save(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) { completion(.success(())) }
}
final class RoutingTransport: MessageChannelTransport {
    var calls = 0
    var failTelegram = false
    var uncertain = false
    var beforeResponse: (() async -> Void)?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        let body = String(data: request.httpBody!, encoding: .utf8)!
        precondition(body.contains("Public reset announcement"))
        precondition(body.contains("Public fixture wording") && body.contains("Announced at:") && body.contains("https:"))
        precondition(!body.contains("completed") && !body.contains("fixture-private-content"))
        if let beforeResponse { await beforeResponse() }
        if uncertain { throw URLError(.timedOut) }
        let telegram = request.url!.host == TelegramMessageChannel.apiHost
        let response = telegram ? (failTelegram ? #"{"ok":false,"error_code":400}"# : #"{"ok":true,"result":{"message_id":1}}"#) : #"{"errcode":0}"#
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@main struct RoutingFixture {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("next-routing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "next-routing-fixture-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = RoutingStorage(), transport = RoutingTransport()
        let controller = MessageChannelsController(defaults: defaults, storage: storage, transport: { transport })
        controller.start()
        precondition(controller.publicResetRevision(.telegram) == nil)
        controller.setEnabled(true, for: .telegram)
        storage.configured = false
        controller.setEnabled(true, for: .weChat)
        precondition(controller.publicResetRevision(.weChat) == nil)
        let monitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: directory)
        var results: [PublicResetChannelResult] = []
        monitor.configure(notifyLocally: { _ in .inAppOnly }, canSend: { false }, send: { _ in .failure(.cancelled) },
            channelRevision: { controller.publicResetRevision($0) }, sendChannel: { event, kind, revision in
                await controller.sendPublicReset(event, to: kind, revision: revision, shouldSend: { true })
            }, onChannelResult: { result in
                precondition(Thread.isMainThread)
                results.append(result)
                controller.recordPublicResetChannelResult(result)
            })
        let now = Date()
        @Sendable func page(_ count: Int) -> PublicResetPage {
            var rows: [PublicResetAnnouncement] = []
            for n in 1...count {
                let source = PublicResetAnnouncement.Source(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/\(n)"))
                let kind: PublicResetAnnouncement.Kind = n % 2 == 0 ? .banked : .regular
                rows.append(PublicResetAnnouncement(id: String(n), resetType: kind,
                    announcedAt: now.addingTimeInterval(Double(n - 100)), text: "Public fixture wording", source: source))
            }
            return PublicResetPage(data: rows, pagination: .init(hasMore: false, nextCursor: nil), meta: .init(apiVersion: "v1", generatedAt: now))
        }
        func ledger(_ kind: MessageChannelKind) throws -> PublicResetDeliveryLedger {
            try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: Data(contentsOf: directory.appendingPathComponent("public-reset-"+kind.rawValue+"/delivery-v1.json")))
        }
        await monitor.deliverChannel(page(1), kind: .telegram)
        await monitor.deliverChannel(page(1), kind: .weChat)
        precondition(transport.calls == 0)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("public-reset-wechat").path))
        await monitor.deliverChannel(page(2), kind: .telegram)
        precondition(transport.calls == 1)
        precondition(monitor.channelResults[.telegram]?.state == .accepted)
        precondition(controller.statusText == results.last?.statusText)
        storage.configured = true
        controller.setEnabled(false, for: .weChat)
        controller.setEnabled(true, for: .weChat)
        await monitor.deliverChannel(page(2), kind: .weChat)
        precondition(transport.calls == 1)
        transport.failTelegram = true
        async let tg: Void = monitor.deliverChannel(page(3), kind: .telegram)
        async let wc: Void = monitor.deliverChannel(page(3), kind: .weChat)
        _ = await (tg, wc)
        precondition(monitor.channelResults[.telegram]?.state == .failed)
        let t = try ledger(.telegram), w = try ledger(.weChat)
        precondition(t.records["3"] == .uncertain && w.records["3"] == .sent && w.records["2"] == .baseline)
        await monitor.deliverChannel(page(3), kind: .telegram)
        await monitor.deliverChannel(page(3), kind: .weChat)
        precondition(transport.calls == 3)
        transport.failTelegram = false; transport.uncertain = true
        await monitor.deliverChannel(page(4), kind: .telegram)
        precondition(monitor.channelResults[.telegram]?.state == .uncertain)
        transport.uncertain = false
        await monitor.deliverChannel(page(4), kind: .telegram)
        precondition(transport.calls == 4)
        transport.beforeResponse = { @MainActor in controller.setEnabled(false, for: .telegram) }
        await monitor.deliverChannel(page(5), kind: .telegram)
        let changed = try ledger(.telegram)
        precondition(changed.records["5"] == .uncertain)
        precondition(controller.publicResetRevision(.telegram) == nil)
        transport.beforeResponse = nil
        controller.setEnabled(true, for: .telegram)
        let rev = controller.publicResetRevision(.telegram)!
        controller.setEnabled(false, for: .telegram)
        controller.setEnabled(true, for: .telegram)
        let stale = await controller.sendPublicReset(page(5).data[0], to: .telegram, revision: rev, shouldSend: { true })
        precondition(stale == .failure(.cancelled) && transport.calls == 5)
        // Independent ledger corruption cannot suppress the healthy channel.
        try Data("broken".utf8).write(to: directory.appendingPathComponent("public-reset-telegram/delivery-v1.json"))
        await monitor.deliverChannel(page(6), kind: .telegram)
        precondition(monitor.channelResults[.telegram]?.state == .ledgerFailed)
        precondition(results.last?.errorCategory == .ledger)
        await monitor.deliverChannel(page(6), kind: .weChat)
        let healthy = try ledger(.weChat)
        precondition(healthy.records["6"] == .sent)
        // Business-code parsing is the adapters' real implementation.
        precondition(WeChatMessageChannel.parseResponseBody(Data(#"{"errcode":40014}"#.utf8)) == .rejected(code: 40014, description: nil))
        precondition(WeChatMessageChannel.parseResponseBody(Data(#"{"errcode":true}"#.utf8)) == .invalid)
        precondition(TelegramMessageChannel.parseResponseBody(Data(#"{"ok":false,"error_code":400}"#.utf8)) == .rejected(code: 400, description: nil))
        // A fresh monitor reuses durable history; interrupted and duplicate-only
        // outcomes must never become confirmed sends or automatic retries.
        var persisted = try ledger(.weChat)
        persisted.records["7"] = .sending
        try PrivateLocalFileStore.write(JSONEncoder().encode(persisted), to: directory.appendingPathComponent("public-reset-wechat/delivery-v1.json"))
        let fresh = PublicResetAnnouncementMonitor(preview: true, supportDirectory: directory)
        var attempted = 0
        fresh.configure(notifyLocally: { _ in .retry }, canSend: { false }, send: { _ in .failure(.transportFailed) },
            channelRevision: { controller.publicResetRevision($0) }, sendChannel: { _, _, _ in
                attempted += 1
                return .success(.duplicateSkipped)
            })
        await fresh.deliverChannel(page(7), kind: .weChat)
        precondition(attempted == 0)
        await fresh.deliverChannel(page(8), kind: .weChat)
        await fresh.deliverChannel(page(8), kind: .weChat)
        let restored = try ledger(.weChat)
        precondition(attempted == 1 && restored.records["7"] == .uncertain && restored.records["8"] == .uncertain)
        let actorPassed = await PublicResetAnnouncementMonitor.mainActorDeliverySelfTest(now: Date())
        let nativePassed = await PublicResetAnnouncementMonitor.deliverySelfTest(now: Date())
        precondition(actorPassed && nativePassed)
        try await PublicResetLifecycleFixture.run()
        try await MessageTestAdmissionFixture.run()
        try await PublicResetContextFixture.run()
        controller.stop()
        print("PASS public-reset routing: enabled/unconfigured, independent baselines, no backfill, durable dedupe, independent failure/corruption, business errors, uncertain and stale revision")
    }
}
