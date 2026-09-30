import Combine
import Foundation

/// The public application carries only channel identifiers. GitHub authorizes
/// writes using the maintainer's existing local CLI login, never a bundled key.
enum PublisherMessagePublishing {
    static let owner = "BLACKIELF"
    static let ownerID = 134_734_669
    static let repository = "BLACKIELF/AgentHub-AiGoodBro"
    static let branch = "codex/announcements"
    static let path = "Resources/AppMessages/messages-v1.json"
    static let feedURL = URL(string: "https://raw.githubusercontent.com/\(repository)/\(branch)/\(path)")!
    static let pageURL = URL(string: "https://github.com/\(repository)/blob/\(branch)/\(path)")!
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexAccountManagerNext/publisher-messages")

    enum Failure: Error {
        case unavailable, forbidden, invalidMessage, invalidFeed, conflict, uncertain
        func text(_ language: WidgetLanguage) -> String {
            switch self {
            case .unavailable: return language.text("发布服务暂不可用，请检查本机 GitHub 登录。", "Publishing is unavailable. Check your local GitHub sign-in.")
            case .forbidden: return language.text("仅维护者 BLACKIELF 可以发布消息。", "Only maintainer BLACKIELF can publish messages.")
            case .invalidMessage: return language.text("请填写标题和正文，并检查长度与详情网址。", "Enter a title and message within the limits and check the details URL.")
            case .invalidFeed: return language.text("公告源异常，未覆盖远端内容。", "The announcement feed is invalid; remote content was preserved.")
            case .conflict: return language.text("公告源已变化，请再次发布；同一消息不会重复添加。", "The feed changed. Publish again; the same message will not be added twice.")
            case .uncertain: return language.text("发布结果待确认。再次点击将先核对原消息，不会重复添加。", "Publication is unconfirmed. Retry checks the original message before adding anything.")
            }
        }
    }
    struct Response {
        let status: Int
        let data: Data
    }
    typealias API = (String, String, [String: Any]?) throws -> Response
    struct Outbox: Codable {
        var version = 1
        var pending: PublisherMessage?
    }

    static func message(title: String, body: String, link: String, now: Date = Date(), id: UUID = UUID()) throws -> PublisherMessage {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = link.isEmpty ? nil : URL(string: link)
        guard link.isEmpty || url.map(PublisherMessage.allowedURL) == true else { throw Failure.invalidMessage }
        // JSON uses second precision so readback equality survives serialization.
        let time = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        let value = PublisherMessage(
            id: "notice-" + id.uuidString.lowercased(), title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines), publishedAt: time,
            expiresAt: time.addingTimeInterval(30 * 86_400), url: url)
        do { _ = try PublisherMessageFeed.decode(encode(.init(version: 1, messages: [value]))) } catch { throw Failure.invalidMessage }
        return value
    }
    static func encode(_ feed: PublisherMessageFeed) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(feed)
    }
    static func verifyOwner(api: API) throws {
        let user = try api("GET", "user", nil)
        guard user.status == 200, let identity = try JSONSerialization.jsonObject(with: user.data) as? [String: Any],
            identity["id"] as? Int == ownerID, identity["login"] as? String == owner
        else { throw Failure.forbidden }
        let repo = try api("GET", "repos/" + repository, nil)
        guard repo.status == 200, let object = try JSONSerialization.jsonObject(with: repo.data) as? [String: Any],
            object["full_name"] as? String == repository,
            (object["owner"] as? [String: Any])?["id"] as? Int == ownerID,
            (object["permissions"] as? [String: Any])?["admin"] as? Bool == true
        else { throw Failure.forbidden }
    }
    private static func readFeed(api: API) throws -> (sha: String, feed: PublisherMessageFeed) {
        let response = try api("GET", "repos/\(repository)/contents/\(path)?ref=codex%2Fannouncements", nil)
        guard response.status == 200,
            let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any], value["type"] as? String == "file",
            value["encoding"] as? String == "base64", let sha = value["sha"] as? String,
            sha.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression) != nil,
            let content = value["content"] as? String,
            let data = Data(base64Encoded: content.filter { !$0.isWhitespace }), data.count <= 64 * 1024
        else { throw Failure.invalidFeed }
        return try (sha, PublisherMessageFeed.decode(data))
    }
    static func publish(_ message: PublisherMessage, api: API, now: Date = Date()) throws {
        try verifyOwner(api: api)
        let existing = try readFeed(api: api)
        if let prior = existing.feed.messages.first(where: { $0.id == message.id }) {
            guard prior == message else { throw Failure.conflict }
            return
        }
        guard message.isActive(at: now) else { throw Failure.invalidMessage }
        let feed = PublisherMessageFeed(version: 1, messages: existing.feed.messages.filter { $0.expiresAt > now } + [message])
        let data = try encode(feed)
        do { _ = try PublisherMessageFeed.decode(data) } catch { throw Failure.invalidFeed }
        // Recheck the identity before the mutation; GitHub also enforces write access.
        try verifyOwner(api: api)
        let response: Response
        do {
            response = try api(
                "PUT", "repos/\(repository)/contents/\(path)",
                ["branch": branch, "sha": existing.sha, "message": "Publish AiGoodBro notice " + message.id, "content": data.base64EncodedString()])
        } catch {
            if let recovered = try? readFeed(api: api), recovered.feed.messages.contains(message) { return }
            throw Failure.uncertain
        }
        guard response.status == 200 || response.status == 201 else {
            if response.status == 409 || response.status == 422 { throw Failure.conflict }
            if response.status == 401 || response.status == 403 { throw Failure.forbidden }
            throw Failure.uncertain
        }
        guard let readback = try? readFeed(api: api), readback.feed.messages.contains(message) else { throw Failure.uncertain }
    }

    static func cliAPI() throws -> API {
        guard let executable = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first(where: FileManager.default.isExecutableFile) else {
            throw Failure.unavailable
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_HOST"] = "github.com"
        environment["GH_DEBUG"] = nil
        environment["GH_PAGER"] = "cat"
        let frozenEnvironment = environment
        return { method, endpoint, payload in
            var arguments = ["api", "--hostname", "github.com", "--include", "--method", method, endpoint]
            var temporary: URL?
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            if let payload {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aigoodbro-publish-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                temporary = folder
                let file = folder.appendingPathComponent("request.json")
                try JSONSerialization.data(withJSONObject: payload).write(to: file, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                arguments += ["--input", file.path]
            }
            let output = try BoundedLocalProcess.run(
                executable: URL(fileURLWithPath: executable), arguments: arguments, environment: frozenEnvironment,
                maximumOutputBytes: 256 * 1024, timeout: 20, allowedExitCodes: [0, 1])
            let text = String(decoding: output, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            guard let divider = text.range(of: "\n\n"),
                let firstLine = text.split(separator: "\n").first,
                let status = firstLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
            else { throw Failure.unavailable }
            return Response(status: status, data: Data(text[divider.upperBound...].utf8))
        }
    }

    static var configuredOnThisMac: Bool {
        guard let data = try? DispatchParticipationSync.readBoundedRegularFile(directory.appendingPathComponent("owner-v1.json"), maximumBytes: 1024),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["githubUserID"] as? Int == ownerID
    }
    static func saveOutbox(_ pending: PublisherMessage?, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try DispatchParticipationSync.withSnapshotLock(at: url) {
            let previous = try DispatchParticipationSync.readBoundedRegularFile(url, maximumBytes: 16 * 1024, allowMissing: true)
            let data = try JSONEncoder().encode(Outbox(pending: pending))
            try DispatchParticipationSync.writeSnapshot(data, at: url, replacing: previous)
        }
    }
}

@MainActor
final class PublisherMessageComposer: ObservableObject {
    @Published var title = ""
    @Published var body = ""
    @Published var link = ""
    @Published private(set) var authorized = false
    @Published private(set) var busy = false
    @Published private(set) var pending: PublisherMessage?
    @Published private(set) var status: String?
    @Published private(set) var published = false
    let configured: Bool
    private let outbox = PublisherMessagePublishing.directory.appendingPathComponent("outbox-v1.json")
    private var storageBlocked = false

    init(preview: Bool = false) {
        configured = !preview && PublisherMessagePublishing.configuredOnThisMac
        guard configured else { return }
        do {
            if let data = try DispatchParticipationSync.readBoundedRegularFile(outbox, maximumBytes: 16 * 1024, allowMissing: true) {
                let saved = try JSONDecoder().decode(PublisherMessagePublishing.Outbox.self, from: data)
                guard saved.version == 1 else { throw PublisherMessagePublishing.Failure.invalidMessage }
                pending = saved.pending
                if let pending {
                    _ = try PublisherMessageFeed.decode(PublisherMessagePublishing.encode(.init(version: 1, messages: [pending])))
                    title = pending.title
                    body = pending.body
                    link = pending.url?.absoluteString ?? ""
                }
            }
        } catch {
            storageBlocked = true
            status = WidgetLanguage.storedOrAutomatic().text("本机待发记录读取失败，已保留原文件。", "The local outbox could not be read; its file was preserved.")
        }
    }
    var valid: Bool { (try? PublisherMessagePublishing.message(title: title, body: body, link: link)) != nil }
    var canPublish: Bool { authorized && !busy && !storageBlocked && (pending != nil || valid) }
    func checkAccess() async {
        guard configured, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await Task.detached { try PublisherMessagePublishing.verifyOwner(api: PublisherMessagePublishing.cliAPI()) }.value
            authorized = true
        } catch {
            authorized = false
            status = (error as? PublisherMessagePublishing.Failure ?? .unavailable).text(.storedOrAutomatic())
        }
    }
    func publish() async {
        guard canPublish else { return }
        busy = true
        published = false
        defer { busy = false }
        do {
            let message = try pending ?? PublisherMessagePublishing.message(title: title, body: body, link: link)
            try PublisherMessagePublishing.saveOutbox(message, at: outbox)
            pending = message
            try await Task.detached { try PublisherMessagePublishing.publish(message, api: PublisherMessagePublishing.cliAPI()) }.value
            try PublisherMessagePublishing.saveOutbox(nil, at: outbox)
            pending = nil
            title = ""
            body = ""
            link = ""
            published = true
            status = WidgetLanguage.storedOrAutomatic().text("已发布。在线新版客户端将在下次检查时收到。", "Published. Online updated clients receive it at their next check.")
        } catch {
            if (error as? PublisherMessagePublishing.Failure) == .forbidden { authorized = false }
            status = (error as? PublisherMessagePublishing.Failure ?? .uncertain).text(.storedOrAutomatic())
        }
    }
}
