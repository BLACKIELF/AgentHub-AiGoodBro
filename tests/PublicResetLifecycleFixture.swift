/// Cancellation deliberately does not resume these gates. Tests control the
/// exact completion order and await the actual monitor task's cleanup.
@MainActor
private final class LifecycleGate<Value> {
    var calls = 0
    private var pending: [Int: CheckedContinuation<Value, Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func take() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            calls += 1
            pending[calls] = continuation
            let ready = observers.filter { $0.0 <= calls }
            observers.removeAll { $0.0 <= calls }
            ready.forEach { $0.1.resume() }
        }
    }
    func wait(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func finish(_ call: Int, _ value: Value) { pending.removeValue(forKey: call)!.resume(returning: value) }
    func fail(_ call: Int) { pending.removeValue(forKey: call)!.resume(throwing: PublicResetFailure.retryLater(900)) }
}

@MainActor
enum PublicResetLifecycleFixture {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func page(_ count: Int) -> PublicResetPage {
            let now = Date()
            let rows = (1...count).map { n in
                PublicResetAnnouncement(id: String(n), resetType: .regular,
                    announcedAt: now.addingTimeInterval(Double(n - 100)), text: "fixture",
                    source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/\(n)")))
            }
            return .init(data: rows, pagination: .init(hasMore: false, nextCursor: nil), meta: .init(apiVersion: "v1", generatedAt: now))
        }
        func configure(_ monitor: PublicResetAnnouncementMonitor) {
            monitor.configure(notifyLocally: { _ in .inAppOnly }, canSend: { false }, send: { _ in .failure(.cancelled) })
        }
        // 1. Synchronous configure -> stop invalidates even a not-yet-started task.
        let firstGate = LifecycleGate<PublicResetPage>()
        let first = PublicResetAnnouncementMonitor(preview: true, supportDirectory: root.appendingPathComponent("first"),
            fixtureScheduling: true, fetchPage: { try await firstGate.take() })
        configure(first)
        let cancelled = first.lifecycleTask!
        precondition(first.checking && first.lifecycleSnapshot.scheduled)
        first.stop()
        precondition(!first.checking && !first.lifecycleSnapshot.active && !first.lifecycleSnapshot.scheduled)
        await cancelled.value
        precondition(firstGate.calls == 0 && !first.lifecycleSnapshot.active)
        print("PASS lifecycle 1: configure then stop leaves no scheduled or active check")

        // 2. stop -> configure admits only the new generation, immediately.
        configure(first)
        let current = first.lifecycleTask!
        await firstGate.wait(1)
        precondition(first.lifecycleSnapshot.epoch == 3 && first.checking && first.lifecycleSnapshot.scheduled)
        firstGate.finish(1, page(1))
        await current.value
        precondition(first.latest?.id == "1" && !first.checking && !first.lifecycleSnapshot.active && firstGate.calls == 1)
        first.stop()
        print("PASS lifecycle 2: stop then configure admits only the new generation")

        // 3a. An old successful fetch, and separately an old error, complete
        // while the new generation owns checking/task. Neither may publish.
        for fail in [false, true] {
            let gate = LifecycleGate<PublicResetPage>()
            let monitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: root.appendingPathComponent("fetch-\(fail)"),
                fixtureScheduling: true, fetchPage: { try await gate.take() })
            configure(monitor)
            let old = monitor.lifecycleTask!
            await gate.wait(1)
            let admission = monitor.deliveryAdmission()
            monitor.stop(); configure(monitor)
            let new = monitor.lifecycleTask!
            await gate.wait(2)
            let status = monitor.status, date = monitor.checkedAt
            if fail { gate.fail(1) } else { gate.finish(1, page(2)) }
            await old.value
            precondition(!admission() && monitor.latest == nil && monitor.status == status && monitor.checkedAt == date)
            precondition(monitor.checking && monitor.lifecycleSnapshot.active && monitor.lifecycleSnapshot.scheduled)
            gate.finish(2, page(1))
            await new.value
            precondition(monitor.latest?.id == "1" && !monitor.checking && !monitor.lifecycleSnapshot.active)
            monitor.stop()
        }
        // 3b. Exercise each admitted delivery path, a late accepted callback,
        // and a queued second event that must not be sent by the old generation.
        for route in ["native", "feishu", "telegram", "wechat"] {
            let directory = root.appendingPathComponent(route)
            let gate = LifecycleGate<PublicResetPage>()
            let delivery = LifecycleGate<Bool>()
            let monitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: directory,
                fixtureScheduling: true, fetchPage: { try await gate.take() })
            var admission: (() -> Bool)?
            var publishedResults: [PublicResetChannelResult] = []
            var sends = 0
            let revision = UUID()
            func heldSend() async {
                sends += 1
                admission = monitor.deliveryAdmission()
                _ = try? await delivery.take()
            }
            func configureRoute() {
                monitor.configure(notifyLocally: { _ in
                    if route == "native" { await heldSend() }
                    return .submitted
                }, canSend: { route == "feishu" }, send: { _ in
                    await heldSend(); return .success(())
                }, channelRevision: { $0.rawValue == route ? revision : nil }, sendChannel: { _, _, _ in
                    await heldSend(); return .success(.accepted(.init(acceptedAt: Date(), remoteMessageID: nil)))
                }, onChannelResult: { publishedResults.append($0) })
            }
            configureRoute()
            let baseline = monitor.lifecycleTask!
            await gate.wait(1); gate.finish(1, page(1)); await baseline.value
            monitor.check()
            let old = monitor.lifecycleTask!
            await gate.wait(2); gate.finish(2, page(3))
            await delivery.wait(1)
            precondition(sends == 1 && admission!())
            monitor.stop(); configureRoute()
            let new = monitor.lifecycleTask!
            await gate.wait(3)
            let latest = monitor.latest, status = monitor.status, local = monitor.localStatus, date = monitor.checkedAt
            let channelResults = monitor.channelResults
            let resultCount = publishedResults.count
            let uncertain = monitor.uncertainDeliveryIDs
            delivery.finish(1, true)
            await old.value
            precondition(!admission!() && sends == 1)
            precondition(monitor.channelResults == channelResults && publishedResults.count == resultCount)
            precondition(monitor.latest == latest && monitor.status == status && monitor.localStatus == local && monitor.checkedAt == date)
            precondition(monitor.uncertainDeliveryIDs == uncertain && monitor.checking && monitor.lifecycleSnapshot.active)
            let file = route == "native" ? "public-reset-local-v1.json" : route == "feishu" ? "public-reset-delivery-v1.json" : "public-reset-\(route)/delivery-v1.json"
            let ledger = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: Data(contentsOf: directory.appendingPathComponent(file)))
            precondition(ledger.records["2"] == .uncertain && ledger.records["3"] == .pending)
            // End the new task with a controlled error; no further sends.
            gate.fail(3); await new.value
            precondition(!monitor.checking && !monitor.lifecycleSnapshot.active && sends == 1)
            monitor.stop()
        }
        print("PASS lifecycle 3: stale fetch/error and all four delivery completions preserve current state/task, reject old admission, and durably settle uncertain")

        // 4. A persisted marker is delivery metadata, never announcement text.
        // Without a source row no sending reservation is taken. A later
        // verified page restores the original in memory and sends it once.
        let originalAt = Date().addingTimeInterval(-120)
        let original = PublicResetAnnouncement(
            id: "2001", resetType: .banked, announcedAt: originalAt,
            text: "Day 15/ Synthetic complete reset announcement.",
            source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/2001")))
        let head = PublicResetAnnouncement(
            id: "2002", resetType: .regular, announcedAt: originalAt.addingTimeInterval(60), text: "Synthetic latest post",
            source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/2002")))
        let markerDirectory = root.appendingPathComponent("source-text")
        let markerURL = markerDirectory.appendingPathComponent("public-reset-delivery-v1.json")
        var seeded = PublicResetDeliveryLedger()
        seeded.initialized = true
        seeded.records = [original.id: .pending, head.id: .baseline]
        seeded.newestObservedAt = head.announcedAt
        seeded.hydrate([original])
        try PrivateLocalFileStore.write(JSONEncoder().encode(seeded), to: markerURL)
        var fetchedRows = [head]
        let sourceMonitor = PublicResetAnnouncementMonitor(
            preview: true, supportDirectory: markerDirectory, fixtureScheduling: true,
            fetchPage: { .init(data: fetchedRows, pagination: .init(hasMore: false, nextCursor: nil),
                meta: .init(apiVersion: "v1", generatedAt: Date())) })
        var originalsSent: [PublicResetAnnouncement] = []
        sourceMonitor.configure(notifyLocally: { _ in .inAppOnly }, canSend: { true }, send: { event in
            originalsSent.append(event)
            return .success(())
        })
        await sourceMonitor.lifecycleTask!.value
        let unresolvedBytes = try Data(contentsOf: markerURL)
        let unresolved = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: unresolvedBytes)
        precondition(originalsSent.isEmpty && unresolved.records[original.id] == .pending)
        precondition(!String(data: unresolvedBytes, encoding: .utf8)!.contains("Synthetic complete"))
        fetchedRows = [head, original]
        sourceMonitor.check()
        await sourceMonitor.lifecycleTask!.value
        let delivered = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: Data(contentsOf: markerURL))
        precondition(originalsSent == [original] && delivered.records[original.id] == .sent && delivered.payloads?[original.id] == nil)
        sourceMonitor.check()
        await sourceMonitor.lifecycleTask!.value
        precondition(originalsSent == [original])
        sourceMonitor.stop()
        print("PASS lifecycle 4: missing source stays pending without reservation; verified source restores exact original in memory, sends once, and never persists original text")

        // 5. Optional channels must not turn a legacy durable marker into a
        // successful send when a current short page lacks its original row.
        for kind in MessageChannelKind.allCases {
            let directory = root.appendingPathComponent("legacy-marker-" + kind.rawValue)
            let file = directory.appendingPathComponent("public-reset-" + kind.rawValue + "/delivery-v1.json")
            var pending = PublicResetDeliveryLedger()
            pending.initialized = true
            pending.records = [original.id: .pending, head.id: .baseline]
            pending.newestObservedAt = head.announcedAt
            pending.hydrate([original])
            try PrivateLocalFileStore.write(JSONEncoder().encode(pending), to: file)
            var historyCalls = 0
            let monitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: directory,
                fetchHistoryPage: { cursor, timeout in
                    historyCalls += 1
                    precondition(cursor == "older" && timeout > 0 && timeout <= 30)
                    return .init(data: [original], pagination: .init(hasMore: false, nextCursor: nil),
                        meta: .init(apiVersion: "v1", generatedAt: Date()))
                })
            defer { monitor.stop() }
            let revision = UUID()
            var sent: [PublicResetAnnouncement] = []
            monitor.configure(notifyLocally: { _ in .inAppOnly }, canSend: { false }, send: { _ in .failure(.cancelled) },
                channelRevision: { $0 == kind ? revision : nil }, sendChannel: { event, _, _ in
                    sent.append(event)
                    return .success(.accepted(.init(acceptedAt: Date(), remoteMessageID: nil)))
                })
            let shortPage = PublicResetPage(data: [head], pagination: .init(hasMore: false, nextCursor: nil),
                meta: .init(apiVersion: "v1", generatedAt: Date()))
            await monitor.deliverChannel(shortPage, kind: kind)
            let unresolved = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: Data(contentsOf: file))
            guard sent.isEmpty, historyCalls == 0, unresolved.records[original.id] == .pending else {
                throw NSError(domain: "Legacy marker sent: channel=\(kind.rawValue), received=\(sent.map(\.text)), phase=\(unresolved.records[original.id]?.rawValue ?? "missing")", code: 1)
            }
            let recoverable = PublicResetPage(data: [head], pagination: .init(hasMore: true, nextCursor: "older"), meta: shortPage.meta)
            await monitor.deliverChannel(recoverable, kind: kind)
            await monitor.deliverChannel(recoverable, kind: kind)
            let delivered = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: Data(contentsOf: file))
            precondition(historyCalls == 1 && sent == [original] && delivered.records[original.id] == .sent)

            // A safe projection is already sufficient, even on a short page;
            // terminal uncertain markers must never enter recovery or send.
            for phase in [PublicResetDeliveryLedger.Phase.pending, .uncertain] {
                var retained = pending
                retained.records[original.id] = phase
                let cached = PublicResetAnnouncement(
                    id: original.id, resetType: original.resetType, announcedAt: original.announcedAt,
                    text: phase == .pending ? "Synthetic retained safe excerpt" : "public-announcement", source: original.source)
                retained.payloads?[original.id] = cached
                try PrivateLocalFileStore.write(JSONEncoder().encode(retained), to: file)
                let beforeCalls = historyCalls, beforeSends = sent.count
                await monitor.deliverChannel(recoverable, kind: kind)
                let after = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: Data(contentsOf: file))
                precondition(historyCalls == beforeCalls)
                if phase == .pending {
                    precondition(sent.count == beforeSends + 1 && sent.last == cached && after.records[original.id] == .sent)
                } else {
                    precondition(sent.count == beforeSends && after.records[original.id] == .uncertain)
                }
            }
        }
        print("PASS lifecycle 5: all optional markers stay pending without a source, recover exact original once, reuse cached safe text without history reads, and never replay uncertain records")

        // 6. Fully disjoint heads must reach recovery before history-gap
        // admission. Its original four-page bound and cursor resume still hold.
        let disjointDirectory = root.appendingPathComponent("disjoint-legacy-marker")
        let disjointFile = disjointDirectory.appendingPathComponent("public-reset-personal-wechat/delivery-v1.json")
        var disjoint = PublicResetDeliveryLedger()
        disjoint.initialized = true
        disjoint.records = [original.id: .pending]
        disjoint.newestObservedAt = original.announcedAt
        disjoint.hydrate([original])
        try PrivateLocalFileStore.write(JSONEncoder().encode(disjoint), to: disjointFile)
        var requested: [String] = []
        let disjointMonitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: disjointDirectory,
            fetchHistoryPage: { cursor, timeout in
                requested.append(cursor)
                precondition(timeout > 0 && timeout <= 30)
                let number = Int(cursor)!
                let row = number == 6 ? original : PublicResetAnnouncement(
                    id: String(3000 + number), resetType: .regular,
                    announcedAt: head.announcedAt.addingTimeInterval(-Double(number)), text: "Synthetic intermediate source",
                    source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/\(3000 + number)")))
                return .init(data: [row], pagination: .init(hasMore: number < 6, nextCursor: number < 6 ? String(number + 1) : nil),
                    meta: .init(apiVersion: "v1", generatedAt: Date()))
            })
        defer { disjointMonitor.stop() }
        let disjointRevision = UUID()
        var disjointSent: [PublicResetAnnouncement] = []
        disjointMonitor.configure(notifyLocally: { _ in .inAppOnly }, canSend: { false }, send: { _ in .failure(.cancelled) },
            channelRevision: { $0 == .personalWeChat ? disjointRevision : nil }, sendChannel: { event, _, _ in
                disjointSent.append(event)
                return .success(.accepted(.init(acceptedAt: Date(), remoteMessageID: nil)))
            })
        let disjointHead = PublicResetPage(data: [head], pagination: .init(hasMore: true, nextCursor: "2"),
            meta: .init(apiVersion: "v1", generatedAt: Date()))
        await disjointMonitor.deliverChannel(disjointHead, kind: .personalWeChat)
        let partial = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: Data(contentsOf: disjointFile))
        precondition(requested == ["2", "3", "4", "5"] && disjointSent.isEmpty)
        precondition(partial.records[original.id] == .pending && partial.records[head.id] == nil && partial.historyCheckpoint?.cursor == "6")
        await disjointMonitor.deliverChannel(disjointHead, kind: .personalWeChat)
        let resumed = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: Data(contentsOf: disjointFile))
        precondition(requested == ["2", "3", "4", "5", "6"] && disjointSent == [original])
        precondition(resumed.records[original.id] == .sent && resumed.records[head.id] == nil)
        await disjointMonitor.deliverChannel(disjointHead, kind: .personalWeChat)
        precondition(requested.count == 5 && disjointSent == [original])
        print("PASS lifecycle 6: fully disjoint optional history recovers before admission, stops after four pages, resumes its saved cursor, sends original once, and never admits a history gap")

        // 7. A credential revision changed during source recovery cannot take a
        // sending reservation or convert an unsent record to uncertain.
        let staleDirectory = root.appendingPathComponent("stale-source-recovery")
        let staleFile = staleDirectory.appendingPathComponent("public-reset-telegram/delivery-v1.json")
        try PrivateLocalFileStore.write(JSONEncoder().encode(disjoint), to: staleFile)
        let historyGate = LifecycleGate<PublicResetPage>()
        let staleMonitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: staleDirectory,
            fetchHistoryPage: { _, _ in try await historyGate.take() })
        defer { staleMonitor.stop() }
        var staleRevision = UUID(), staleSends = 0
        staleMonitor.configure(notifyLocally: { _ in .inAppOnly }, canSend: { false }, send: { _ in .failure(.cancelled) },
            channelRevision: { $0 == .telegram ? staleRevision : nil }, sendChannel: { _, _, _ in
                staleSends += 1
                return .success(.accepted(.init(acceptedAt: Date(), remoteMessageID: nil)))
            })
        let staleDelivery = Task { @MainActor in await staleMonitor.deliverChannel(disjointHead, kind: .telegram) }
        await historyGate.wait(1)
        staleRevision = UUID()
        historyGate.finish(1, .init(data: [original], pagination: .init(hasMore: false, nextCursor: nil), meta: disjointHead.meta))
        await staleDelivery.value
        let stale = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: Data(contentsOf: staleFile))
        precondition(staleSends == 0 && stale.records[original.id] == .pending && stale.payloads?[original.id]?.text == "public-announcement")
        print("PASS lifecycle 7: revision changed during source recovery leaves original marker pending without send or uncertain reservation")
    }
}
