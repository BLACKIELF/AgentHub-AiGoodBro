enum PublicResetContextFixture {
    @MainActor static func run() async throws {
        let now = Date()
        let old = now.addingTimeInterval(-86_400 * 100)
        func event(_ kind: PublicResetAnnouncement.Kind = .regular, id: String = "101",
                   date: Date? = nil, text: String = "Public wording https://evil.invalid/path www.evil.invalid evil.invalid a@b.invalid\u{0} clean\u{202E}text",
                   source: PublicResetAnnouncement.Source? = nil) -> PublicResetAnnouncement {
            .init(id: id, resetType: kind, announcedAt: date ?? old, text: text,
                  source: source ?? .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/101")))
        }
        for kind in [PublicResetAnnouncement.Kind.regular, .banked] {
            let context = try PublicResetContext(announcement: event(kind), now: now)
            precondition(context.announcementID == "101" && context.kind == kind && context.announcedAt == old)
            let status = try MessageTaskStatus(eventKind: kind == .regular ? .publicRegularReset : .publicBankedReset,
                                               occurredAt: now, publicResetContext: context)
            precondition(status.occurredAt == now && status.publicResetContext?.announcedAt == old)
            for language in [WidgetLanguage.en, .zh] {
                let body = status.summary(language)
                precondition(body.contains(MessageNoticeFormat.shortTime(old)))
                precondition(body.hasSuffix(MessageNoticeFormat.footerSuffix))
                precondition(body.contains("Public wording") && !body.contains("evil") && !body.contains("a@b"))
                precondition(body.components(separatedBy: "https://").count == 2)
                precondition(!context.publicText.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.value == 0x202E })
            }
            precondition(status.summary(.en).contains("Third-party"))
            precondition(status.summary(.en).contains(kind == .regular ? "· quota" : "· reset credits"))
            do {
                _ = try MessageTaskStatus(eventKind: .test, occurredAt: now, publicResetContext: context)
                preconditionFailure("public text admitted to private event")
            } catch MessageChannelError.invalidStatus {}
        }
        for sentence in ["Reset all propagated. Sweet dreams.", "额度已刷新。晚安！",
                         "“Reset ready,” she said. Sweet dreams! 🌙✨ 👩‍💻"] {
            let context = try PublicResetContext(announcement: event(text: sentence))
            precondition(context.publicText == sentence)
        }
        for (input, expected) in [
            ("Reset\nall propagated.\tSweet dreams.", "Reset all propagated. Sweet dreams."),
            ("Reset\tall\r\npropagated. Sweet\tdreams.", "Reset all propagated. Sweet dreams."),
            ("额度已刷新。\n晚安！", "额度已刷新。 晚安！"),
            ("“Reset\tready,” she said.\r\nSweet dreams! 🌙✨ 👩‍💻", "“Reset ready,” she said. Sweet dreams! 🌙✨ 👩‍💻")
        ] {
            let context = try PublicResetContext(announcement: event(text: input))
            precondition(context.publicText == expected)
        }
        for link in ["https://evil.invalid/path", "evil.invalid", "a@b.invalid",
                     "ht\u{202E}tps://evil.invalid", "evil\u{0}.invalid", "evil\u{09}.invalid",
                     "evil\n.invalid", "evil\r\n.invalid", "evil\t．invalid", "evil\t\u{200D}.invalid",
                     "evil\u{200B}.invalid", "evil\u{200D}.invalid", "evil。invalid",
                     "ｅｖｉｌ．ｉｎｖａｌｉｄ", "[click](../private)", "javascript:alert(1)",
                     "https://x.com/thsottiaux/status/101"] {
            let context = try PublicResetContext(announcement: event(text: "Before " + link + " After."))
            precondition(context.publicText == "Before After.")
        }
        let chineseBound = try PublicResetContext(announcement: event(text: String(repeating: "额度已刷新。晚安！🌙", count: 400)))
        precondition(!chineseBound.publicText.isEmpty && chineseBound.publicText.count <= 240 && chineseBound.publicText.utf8.count <= 720)
        let summaries: [(PublicResetChannelResult.State, String, String)] = [
            (.accepted, "API accepted only; delivery or reading is not confirmed.", "仅 API 已接受；不代表已送达或已读。"),
            (.failed, "Delivery failed; no automatic resend.", "发送失败；不会自动重发。"),
            (.uncertain, "Delivery uncertain; verification required, no automatic resend.", "发送结果不确定；需要核验，不会自动重发。"),
            (.ledgerFailed, "Delivery ledger read/write failure; delivery paused.", "投递记录读取或写入失败；投递已暂停。")]
        for channel in MessageChannelKind.allCases {
            for (state, en, zh) in summaries {
                for category in [PublicResetChannelResult.ErrorCategory.admission, .rejected, .transport,
                                 .response, .duplicate, .ledger, .interrupted] {
                    let result = PublicResetChannelResult(channel: channel, state: state, checkedAt: now, errorCategory: category)
                    precondition(result.summary(.en) == "Public reset / " + channel.displayName(.en) + ": " + en)
                    precondition(result.summary(.zh) == "公共重置 / " + channel.displayName(.zh) + ": " + zh)
                    precondition(result.safeIssueCode == "public-reset/" + channel.rawValue + "/" + state.rawValue + "/" + category.rawValue)
                    precondition(result.statusText == result.summary(WidgetLanguage.storedOrAutomatic()))
                }
            }
        }
        let bounded = try PublicResetContext(announcement: event(text: String(repeating: "public ", count: 1000)))
        precondition(bounded.publicText.count == 240 && bounded.publicText.utf8.count <= 720)
        let combining = try PublicResetContext(announcement: event(text: "a" + String(repeating: "\u{0301}", count: 4000)))
        precondition(combining.publicText.utf8.count <= 720)
        let observed = try PublicResetContext(announcement: event(id: "observed-1", source: .init(type: "observed", author: nil, url: nil)))
        precondition(observed.sourceURL.absoluteString == "https://codex-resets.com/")
        let observedPost = try PublicResetContext(announcement: event(id: "observed-2", source: .init(type: "observed", author: nil, url: URL(string: "https://x.com/thsottiaux/status/123"))))
        precondition(observedPost.sourceURL.absoluteString == "https://x.com/thsottiaux/status/123")
        for invalid in [event(id: "bad/id"), event(date: now.addingTimeInterval(301)), event(date: .distantPast),
                        event(text: ""), event(text: String(repeating: "a", count: 16_385)),
                        event(source: .init(type: "x_post", author: "other", url: URL(string: "https://x.com/thsottiaux/status/101"))),
                        event(source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/101?q=1"))),
                        event(id: "observed-3", source: .init(type: "observed", author: nil, url: URL(string: "https://evil.invalid/")))] {
            do { _ = try PublicResetContext(announcement: invalid, now: now); preconditionFailure("invalid announcement admitted") }
            catch MessageChannelError.invalidStatus {}
        }
        // Real controller and adapters: old announcement age does not trip dispatch freshness.
        let suite = "next-context-fixture-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = ContextTransport()
        let controller = MessageChannelsController(defaults: defaults, storage: RoutingStorage(), transport: { transport })
        controller.start()
        for channel in [MessageChannelKind.telegram, .weChat] {
            controller.setEnabled(true, for: channel)
            let result = await controller.sendPublicReset(event(text: "Public wording"), to: channel,
                revision: controller.publicResetRevision(channel)!, shouldSend: { true })
            guard case .success(.accepted) = result else { preconditionFailure("old announcement rejected") }
        }
        precondition(transport.bodies.count == 2)
        for body in transport.bodies {
            // Decode JSON to inspect actual outbound string, independent of slash escaping.
            let object = try JSONSerialization.jsonObject(with: body)
            let rendered = String(describing: object)
            precondition(rendered.contains("Public wording") && rendered.contains(MessageNoticeFormat.shortTime(old)))
        }
        controller.stop()
        try await ledgerResults()
        print("PASS public context: restricted construction, age/freshness, both adapter payloads, bounded wording, links/controls, observed fallback and invalid fields")
    }
    @MainActor private static func ledgerResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-context-ledger-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func page(_ ids: [Int]) -> PublicResetPage {
            .init(data: ids.map { id in
                .init(id: String(id), resetType: .regular, announcedAt: now.addingTimeInterval(Double(id - 100)),
                      text: "Queued public wording https://evil.invalid/", source: .init(type: "x_post", author: "thsottiaux",
                      url: URL(string: "https://x.com/thsottiaux/status/\(id)")))
            }, pagination: .init(hasMore: false, nextCursor: nil), meta: .init(apiVersion: "v1", generatedAt: now))
        }
        // Force a real final ledger write failure after API acceptance. It must
        // publish ledgerFailed, never acceptance or a transport-derived string.
        let directory = root.appendingPathComponent("write")
        let file = directory.appendingPathComponent("public-reset-telegram/delivery-v1.json")
        let monitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: directory)
        let revision = UUID()
        var results: [PublicResetChannelResult] = []
        var sends = 0
        monitor.configure(notifyLocally: { _ in .inAppOnly }, canSend: { false }, send: { _ in .failure(.cancelled) },
            channelRevision: { _ in revision }, sendChannel: { _, _, _ in
                sends += 1
                try! FileManager.default.removeItem(at: file)
                try! FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                return .success(.accepted(.init(acceptedAt: now, remoteMessageID: nil)))
            }, onChannelResult: { results.append($0) })
        await monitor.deliverChannel(page([1]), kind: .telegram)
        await monitor.deliverChannel(page([1, 2]), kind: .telegram)
        precondition(sends == 1 && results.count == 1 && results[0].state == .ledgerFailed)
        precondition(results[0].errorCategory == .ledger && results[0].checkedAt >= now)
        precondition(!results[0].statusText.contains("wording") && !results[0].statusText.contains("https"))
        // A queued event absent from the next page retains only bounded public
        // wording in the existing channel ledger; uncertain ID 2 is not retried.
        let queueRoot = root.appendingPathComponent("queue")
        let queue = PublicResetAnnouncementMonitor(preview: true, supportDirectory: queueRoot)
        var delivered: [PublicResetAnnouncement] = []
        queue.configure(notifyLocally: { _ in .inAppOnly }, canSend: { false }, send: { _ in .failure(.cancelled) },
            channelRevision: { _ in revision }, sendChannel: { event, _, _ in
                delivered.append(event)
                if event.id == "2" { return .failure(.transportFailed) }
                return .success(.accepted(.init(acceptedAt: now, remoteMessageID: nil)))
            })
        await queue.deliverChannel(page([1]), kind: .telegram)
        await queue.deliverChannel(page([1, 2, 3]), kind: .telegram)
        await queue.deliverChannel(page([1]), kind: .telegram)
        precondition(delivered.map(\.id) == ["2", "3"])
        precondition(delivered[1].text == "Queued public wording")
        precondition(delivered[1].announcedAt == page([3]).data[0].announcedAt)
        precondition(queue.channelResults[.telegram]?.state == .accepted)
        print("PASS channel results: final ledger-write failure, safe category/time, queued wording across short pages, no uncertain retry")
    }

}
final class ContextTransport: MessageChannelTransport {
    var bodies: [Data] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        bodies.append(request.httpBody!)
        let data = request.url!.host == TelegramMessageChannel.apiHost
            ? Data(#"{"ok":true,"result":{"message_id":1}}"#.utf8) : Data(#"{"errcode":0}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
