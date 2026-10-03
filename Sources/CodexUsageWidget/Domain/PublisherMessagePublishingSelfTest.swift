import Foundation

enum PublisherMessagePublishingSelfTest {
    static func run() -> Bool {
        typealias Publisher = PublisherMessagePublishing
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var feed = PublisherMessageFeed(version: 1, messages: [])
        var puts = 0
        var wrongOwner = false
        var conflict = false
        var ambiguousSuccess = false
        var errorBeforeWrite = false
        var stage = "message_creation"
        func fail(_ category: String) -> Bool {
            print("Publisher write self-test failed: stage=\(stage) category=\(category) puts=\(puts) messages=\(feed.messages.count)")
            return false
        }
        func response(_ status: Int, _ json: [String: Any]) throws -> Publisher.Response {
            .init(status: status, data: try JSONSerialization.data(withJSONObject: json))
        }
        let api: Publisher.API = { method, endpoint, payload in
            if endpoint == "user" {
                return try response(200, ["login": Publisher.owner, "id": wrongOwner ? 1 : Publisher.ownerID])
            }
            if endpoint == "repos/" + Publisher.repository {
                return try response(200, ["full_name": Publisher.repository, "owner": ["id": Publisher.ownerID], "permissions": ["admin": true]])
            }
            if method == "GET" {
                return try response(
                    200, ["type": "file", "encoding": "base64", "sha": String(repeating: "a", count: 40), "content": try Publisher.encode(feed).base64EncodedString()])
            }
            guard method == "PUT", payload?["branch"] as? String == Publisher.branch,
                payload?["sha"] as? String == String(repeating: "a", count: 40),
                let content = payload?["content"] as? String, let data = Data(base64Encoded: content)
            else { throw Publisher.Failure.invalidFeed }
            puts += 1
            if conflict { return try response(409, [:]) }
            if errorBeforeWrite { throw Publisher.Failure.unavailable }
            feed = try PublisherMessageFeed.decode(data)
            if ambiguousSuccess { throw Publisher.Failure.unavailable }
            return try response(200, [:])
        }
        do {
            stage = "message_creation"
            let message = try Publisher.message(title: "Synthetic notice", body: "Synthetic public content", link: "", now: now)
            wrongOwner = true
            stage = "wrong_owner_refusal"
            do {
                try Publisher.publish(message, api: api, now: now)
                return fail("unexpected_success")
            } catch Publisher.Failure.forbidden {} catch { return fail("unexpected_error") }
            stage = "wrong_owner_no_write"
            guard puts == 0 else { return fail("invariant_failed") }
            wrongOwner = false
            stage = "owner_verified_first_write"
            try Publisher.publish(message, api: api, now: now)
            stage = "owner_verified_first_write_result"
            guard puts == 1, feed.messages == [message] else { return fail("invariant_failed") }
            stage = "duplicate_retry"
            try Publisher.publish(message, api: api, now: now)
            stage = "duplicate_retry_no_second_write"
            guard puts == 1 else { return fail("invariant_failed") }
            stage = "second_message_creation"
            let another = try Publisher.message(title: "Another", body: "Preserves existing notice", link: "https://aigoodbro.com", now: now)
            conflict = true
            stage = "conflict_rejection"
            do {
                try Publisher.publish(another, api: api, now: now)
                return fail("unexpected_success")
            } catch Publisher.Failure.conflict {} catch { return fail("unexpected_error") }
            stage = "conflict_preserves_feed"
            guard feed.messages == [message] else { return fail("invariant_failed") }
            conflict = false
            ambiguousSuccess = true
            stage = "ambiguous_write_recovery"
            try Publisher.publish(another, api: api, now: now)
            stage = "ambiguous_write_readback"
            guard feed.messages == [message, another] else { return fail("invariant_failed") }
            stage = "pending_message_creation"
            let final = try Publisher.message(title: "Pending", body: "Uncertain write", link: "", now: now)
            ambiguousSuccess = false
            errorBeforeWrite = true
            stage = "prewrite_failure_handling"
            do {
                try Publisher.publish(final, api: api, now: now)
                return fail("unexpected_success")
            } catch Publisher.Failure.uncertain {} catch { return fail("unexpected_error") }
            stage = "prewrite_failure_preserves_feed"
            guard feed.messages == [message, another] else { return fail("invariant_failed") }
            stage = "invalid_link_validation"
            for link in ["https://github.com.attacker.invalid/BLACKIELF/repo", "file:///tmp/test", "https://example.invalid"] {
                do {
                    _ = try Publisher.message(title: "Synthetic", body: "Fixture", link: link, now: now)
                    return fail("unexpected_success")
                } catch Publisher.Failure.invalidMessage {} catch { return fail("unexpected_error") }
            }
            stage = "empty_title_validation"
            do {
                _ = try Publisher.message(title: "", body: "Fixture", link: "", now: now)
                return fail("unexpected_success")
            } catch Publisher.Failure.invalidMessage {} catch { return fail("unexpected_error") }
            stage = "outbox_write"
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-outbox-test-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let outbox = root.appendingPathComponent("outbox.json")
            try Publisher.saveOutbox(final, at: outbox)
            stage = "outbox_restore"
            let restored = try JSONDecoder().decode(Publisher.Outbox.self, from: Data(contentsOf: outbox))
            guard restored.pending == final else { return fail("invariant_failed") }
            stage = "outbox_clear"
            try Publisher.saveOutbox(nil, at: outbox)
            stage = "outbox_clear_result"
            guard try JSONDecoder().decode(Publisher.Outbox.self, from: Data(contentsOf: outbox)).pending == nil else { return fail("invariant_failed") }
        } catch { return fail("unexpected_error") }
        print("Publisher write self-test passed: owner identity, CAS conflict, readback, retry dedupe, ambiguous writes, validation and persistent outbox")
        return true
    }
}
