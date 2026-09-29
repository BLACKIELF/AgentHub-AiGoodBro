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
            let message = try Publisher.message(title: "Synthetic notice", body: "Synthetic public content", link: "", now: now)
            wrongOwner = true
            do {
                try Publisher.publish(message, api: api, now: now)
                return false
            } catch Publisher.Failure.forbidden {} catch { return false }
            guard puts == 0 else { return false }
            wrongOwner = false
            try Publisher.publish(message, api: api, now: now)
            guard puts == 1, feed.messages == [message] else { return false }
            try Publisher.publish(message, api: api, now: now)
            guard puts == 1 else { return false }
            let another = try Publisher.message(title: "Another", body: "Preserves existing notice", link: "https://aigoodbro.com", now: now)
            conflict = true
            do {
                try Publisher.publish(another, api: api, now: now)
                return false
            } catch Publisher.Failure.conflict {} catch { return false }
            guard feed.messages == [message] else { return false }
            conflict = false
            ambiguousSuccess = true
            try Publisher.publish(another, api: api, now: now)
            guard feed.messages == [message, another] else { return false }
            let final = try Publisher.message(title: "Pending", body: "Uncertain write", link: "", now: now)
            ambiguousSuccess = false
            errorBeforeWrite = true
            do {
                try Publisher.publish(final, api: api, now: now)
                return false
            } catch Publisher.Failure.uncertain {} catch { return false }
            guard feed.messages == [message, another] else { return false }
            for link in ["https://github.com.attacker.invalid/BLACKIELF/repo", "file:///tmp/test", "https://example.invalid"] {
                do {
                    _ = try Publisher.message(title: "Synthetic", body: "Fixture", link: link, now: now)
                    return false
                } catch Publisher.Failure.invalidMessage {} catch { return false }
            }
            do {
                _ = try Publisher.message(title: "", body: "Fixture", link: "", now: now)
                return false
            } catch Publisher.Failure.invalidMessage {} catch { return false }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-outbox-test-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let outbox = root.appendingPathComponent("outbox.json")
            try Publisher.saveOutbox(final, at: outbox)
            let restored = try JSONDecoder().decode(Publisher.Outbox.self, from: Data(contentsOf: outbox))
            guard restored.pending == final else { return false }
            try Publisher.saveOutbox(nil, at: outbox)
            guard try JSONDecoder().decode(Publisher.Outbox.self, from: Data(contentsOf: outbox)).pending == nil else { return false }
        } catch { return false }
        print("Publisher write self-test passed: owner identity, CAS conflict, readback, retry dedupe, ambiguous writes, validation and persistent outbox")
        return true
    }
}
