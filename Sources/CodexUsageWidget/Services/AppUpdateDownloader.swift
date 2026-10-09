import AppKit
import Combine
import CryptoKit
import Foundation

enum AppUpdateDownloadState: Equatable {
    case idle
    case preparing
    case downloading(received: Int64, total: Int64)
    case verifying
    case downloaded(URL)
    case cancelled
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .downloading, .verifying: return true
        default: return false
        }
    }
}

enum AppUpdateDownloadPolicy {
    static let maximumPackageSize: Int64 = 1_073_741_824
    static let maximumChecksumSize: Int64 = 16_384
    private static let repositories = ["agenthub-aigoodbro", "codex-account-manager-next"]

    struct Plan {
        let release: GitHubReleaseInfo
        let asset: GitHubReleaseAsset
        let sha256: String?
        let checksumAsset: GitHubReleaseAsset?
    }

    struct Identity: Equatable {
        let releaseURL: URL
        let tag: String
        let assetURL: URL
        let assetName: String
        let size: Int64
        let digest: String?
        let checksumAsset: GitHubReleaseAsset?
    }

    static func identity(release: GitHubReleaseInfo, asset: GitHubReleaseAsset) -> Identity {
        Identity(
            releaseURL: release.htmlURL, tag: release.tagName, assetURL: asset.browserDownloadURL,
            assetName: asset.name, size: asset.size, digest: asset.digest,
            checksumAsset: release.assets.first { $0.name == asset.name + ".sha256" })
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func plan(release: GitHubReleaseInfo, asset: GitHubReleaseAsset, currentVersion: String, architecture: AppArchitecture = .current) throws -> Plan {
        guard !release.draft, release.publishedAt != nil, let latest = release.version,
            let current = AppVersion(currentVersion), latest > current,
            !AppUpdateReleasePolicy.blocksLegacyRelease(latest, currentVersion: currentVersion),
            trustedReleaseURL(release.htmlURL, tag: release.tagName)
        else { throw Failure(message: "版本尚未发布或来源不匹配，无法下载。 / Release is unpublished or its source does not match.") }
        guard asset.isDMG, architecture != .unknown, asset.architecture == architecture,
            release.assets.contains(asset), safeFilename(asset.name),
            asset.name.lowercased().contains("-\(latest.description.lowercased())-"),
            asset.size > 0, asset.size <= maximumPackageSize,
            trustedAssetURL(asset.browserDownloadURL, release: release, filename: asset.name)
        else { throw Failure(message: "安装包来源、架构或大小不匹配。 / Package source, architecture or size does not match.") }

        let checksum = release.assets.first { $0.name == asset.name + ".sha256" }
        if let raw = asset.digest {
            guard let hash = sha256Digest(raw) else {
                throw Failure(message: "GitHub 提供的 SHA256 校验信息无效。 / GitHub supplied an invalid SHA256 digest.")
            }
            return Plan(release: release, asset: asset, sha256: hash, checksumAsset: nil)
        }
        guard let checksum, checksum.size > 0, checksum.size <= maximumChecksumSize,
            trustedAssetURL(checksum.browserDownloadURL, release: release, filename: checksum.name)
        else { throw Failure(message: "此版本未提供 SHA256 校验信息，暂不能安全下载。 / This release has no SHA256 checksum; download is unavailable.") }
        return Plan(release: release, asset: asset, sha256: nil, checksumAsset: checksum)
    }

    static func trustedReleaseURL(_ url: URL, tag: String) -> Bool {
        guard secure(url), url.host?.lowercased() == "github.com", url.query == nil,
            url.fragment == nil, !tag.contains("/"), !tag.isEmpty
        else { return false }
        let parts = url.pathComponents
        return parts.count == 6 && parts[1].lowercased() == "blackielf"
            && repositories.contains(parts[2].lowercased())
            && parts[3] == "releases" && parts[4] == "tag" && parts[5] == tag
    }

    static func trustedAssetURL(_ url: URL, release: GitHubReleaseInfo, filename: String) -> Bool {
        guard trustedReleaseURL(release.htmlURL, tag: release.tagName), secure(url),
            url.host?.lowercased() == "github.com", url.query == nil, url.fragment == nil,
            safeFilename(filename)
        else { return false }
        let parts = url.pathComponents
        let releaseParts = release.htmlURL.pathComponents
        return parts.count == 7 && parts[1].lowercased() == releaseParts[1].lowercased()
            && parts[2].lowercased() == releaseParts[2].lowercased()
            && parts[3] == "releases" && parts[4] == "download"
            && parts[5] == release.tagName && parts[6] == filename
    }

    static func trustedRedirectURL(_ url: URL, release: GitHubReleaseInfo, filename: String) -> Bool {
        if trustedAssetURL(url, release: release, filename: filename) { return true }
        guard secure(url), url.fragment == nil,
            ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host?.lowercased() ?? "")
        else { return false }
        return url.path.hasPrefix("/github-production-release-asset-")
    }

    static func sha256Digest(_ raw: String) -> String? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else { return nil }
        return normalizedHash(String(parts[1]))
    }

    static func checksumHash(_ data: Data, filename: String) -> String? {
        guard data.count <= maximumChecksumSize, let raw = String(data: data, encoding: .utf8) else { return nil }
        let lines = raw.split(whereSeparator: \.isNewline)
        guard lines.count == 1 else { return nil }
        let fields = lines[0].split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard fields.count == 2, let hash = normalizedHash(String(fields[0])) else { return nil }
        let recordedPath = fields[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        guard !recordedPath.split(separator: "/").contains(".."),
            (recordedPath as NSString).lastPathComponent == filename
        else { return nil }
        return hash
    }

    private static func normalizedHash(_ hash: String) -> String? {
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return hash.lowercased()
    }

    private static func secure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    private static func safeFilename(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 240 && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func selfTest() -> Bool {
        let filename = "AiGoodBro-9.6.80-mac-arm64.dmg"
        let hash = String(repeating: "a", count: 64)
        let asset = GitHubReleaseAsset(
            name: filename, browserDownloadURL: URL(string: "https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v9.6.80/\(filename)")!, size: 4, contentType: nil,
            digest: "sha256:\(hash)")
        let release = GitHubReleaseInfo(
            tagName: "v9.6.80", name: "Update", htmlURL: URL(string: "https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/v9.6.80")!, publishedAt: Date(),
            prerelease: false, draft: false, body: "", assets: [asset])
        guard (try? plan(release: release, asset: asset, currentVersion: "9.6.79", architecture: .arm64))?.sha256 == hash,
            (try? plan(release: release, asset: asset, currentVersion: "9.6.80", architecture: .arm64)) == nil,
            (try? plan(release: release, asset: asset, currentVersion: "9.6.79", architecture: .x8664)) == nil,
            checksumHash(Data("\(hash)  dist/\(filename)\n".utf8), filename: filename) == hash,
            checksumHash(Data("\(hash)  wrong.dmg\n".utf8), filename: filename) == nil,
            sha256Digest("sha256:xyz") == nil,
            !trustedRedirectURL(URL(string: "https://example.com/\(filename)")!, release: release, filename: filename),
            !trustedAssetURL(URL(string: "https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v9.6.79/\(filename)")!, release: release, filename: filename),
            trustedRedirectURL(
                URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset-123/abc?token=test")!, release: release, filename: filename)
        else { return false }
        return true
    }
}

/// One downloader across all About, Settings and automatic update entry points.
/// Public methods and published state are used on the main thread; transfer work is serial.
final class AppUpdateDownloader: NSObject, ObservableObject, URLSessionDataDelegate {
    static let shared = AppUpdateDownloader()
    @Published private(set) var state: AppUpdateDownloadState = .idle
    @Published private(set) var releaseID: String?
    @Published private(set) var assetName: String?
    @Published private(set) var downloadIdentity: AppUpdateDownloadPolicy.Identity?

    private let configuration: URLSessionConfiguration
    private let downloadsDirectory: URL?
    private let workQueue = DispatchQueue(label: "com.blackielf.codex-account-manager-next.update-download")
    private let generationLock = NSLock()
    private var storedGeneration: UUID?
    private var generation: UUID? {
        get {
            generationLock.lock()
            defer { generationLock.unlock() }
            return storedGeneration
        }
        set {
            generationLock.lock()
            storedGeneration = newValue
            generationLock.unlock()
        }
    }
    private var transfer: Transfer?
    private var completed: (id: UUID, identity: AppUpdateDownloadPolicy.Identity, url: URL, size: Int64, hash: String)?

    private final class Transfer {
        let id: UUID
        let plan: AppUpdateDownloadPolicy.Plan
        var session: URLSession!
        var task: URLSessionDataTask?
        var checksumPhase: Bool
        var expectedHash: String?
        var checksumData = Data()
        var received: Int64 = 0
        var responseAccepted = false
        var redirects = 0
        var lastProgressAt: TimeInterval = 0
        var directory: URL?
        var partialURL: URL?
        var file: FileHandle?
        var hasher = SHA256()

        init(id: UUID, plan: AppUpdateDownloadPolicy.Plan) {
            self.id = id
            self.plan = plan
            checksumPhase = plan.sha256 == nil
            expectedHash = plan.sha256
        }
        var activeAsset: GitHubReleaseAsset { checksumPhase ? plan.checksumAsset! : plan.asset }
    }

    init(configuration: URLSessionConfiguration = .ephemeral, downloadsDirectory: URL? = nil) {
        self.configuration = configuration
        self.downloadsDirectory = downloadsDirectory
        super.init()
    }

    func start(release: GitHubReleaseInfo, asset: GitHubReleaseAsset, currentVersion: String) {
        guard !state.isBusy else { return }
        let id = UUID()
        generation = id
        releaseID = release.id
        assetName = asset.name
        downloadIdentity = AppUpdateDownloadPolicy.identity(release: release, asset: asset)
        state = .preparing
        workQueue.async { [weak self] in
            guard let self else { return }
            guard self.generation == id else { return }
            self.cleanupTransfer()
            self.completed = nil
            do {
                let plan = try AppUpdateDownloadPolicy.plan(release: release, asset: asset, currentVersion: currentVersion)
                let transfer = Transfer(id: id, plan: plan)
                let config = self.configuration.copy() as! URLSessionConfiguration
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 30 * 60
                let delegates = OperationQueue()
                delegates.maxConcurrentOperationCount = 1
                delegates.underlyingQueue = self.workQueue
                transfer.session = URLSession(configuration: config, delegate: self, delegateQueue: delegates)
                self.transfer = transfer
                try self.requestNextAsset(transfer)
            } catch {
                self.fail(id, Self.failureMessage(error))
            }
        }
    }

    func cancel() {
        guard state.isBusy, let id = generation else { return }
        generation = nil
        state = .cancelled
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.transfer?.id == id {
                self.cleanupTransfer()
            } else if self.completed?.id == id, let url = self.completed?.url {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                self.completed = nil
            }
        }
    }

    func openDownloadedPackage() {
        guard let downloadIdentity else { return }
        openDownloadedPackage(matching: downloadIdentity)
    }

    func openDownloadedPackage(release: GitHubReleaseInfo, asset: GitHubReleaseAsset) {
        openDownloadedPackage(matching: AppUpdateDownloadPolicy.identity(release: release, asset: asset))
    }

    private func openDownloadedPackage(matching identity: AppUpdateDownloadPolicy.Identity) {
        guard identity == downloadIdentity else {
            state = .failed("更新安装包信息已变化，请重新下载。 / Update package metadata changed; download it again.")
            return
        }
        guard case .downloaded(let url) = state, let id = generation else { return }
        state = .verifying
        workQueue.async { [weak self] in
            guard let self, let completed = self.completed, completed.id == id, completed.identity == identity, completed.url == url else { return }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                    Int64(values.fileSize ?? -1) == completed.size
                else { throw AppUpdateDownloadPolicy.Failure(message: "安装包已变化，请重新下载。 / Package changed; download it again.") }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                var hasher = SHA256()
                while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
                guard Self.hex(hasher.finalize()) == completed.hash else {
                    throw AppUpdateDownloadPolicy.Failure(message: "安装包校验失败，请重新下载。 / Package checksum failed; download it again.")
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.state = NSWorkspace.shared.open(url) ? .downloaded(url) : .failed("无法打开安装包。 / Unable to open the package.")
                }
            } catch { self.fail(id, Self.failureMessage(error)) }
        }
    }

    private func requestNextAsset(_ transfer: Transfer) throws {
        guard generation == transfer.id else {
            cleanupTransfer()
            return
        }
        transfer.received = 0
        transfer.redirects = 0
        transfer.responseAccepted = false
        if !transfer.checksumPhase {
            let downloads = try downloadsDirectory ?? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let parent = downloads.resolvingSymlinksInPath().appendingPathComponent("AiGoodBro Updates", isDirectory: true)
            if FileManager.default.fileExists(atPath: parent.path) {
                let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw AppUpdateDownloadPolicy.Failure(message: "下载目录不可用。 / The update download directory is unavailable.")
                }
            } else {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let directory = parent.appendingPathComponent("\(transfer.plan.release.versionLabel)-\(transfer.id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            transfer.directory = directory
            let partial = directory.appendingPathComponent("download.part")
            guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw AppUpdateDownloadPolicy.Failure(message: "无法保存安装包。 / Unable to save the package.")
            }
            transfer.partialURL = partial
            transfer.file = try FileHandle(forWritingTo: partial)
            publish(.downloading(received: 0, total: transfer.plan.asset.size), id: transfer.id)
        }
        var request = URLRequest(url: transfer.activeAsset.browserDownloadURL)
        request.setValue("AiGoodBro/\(AppVersion.current())", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        transfer.task = transfer.session.dataTask(with: request)
        transfer.task?.resume()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let transfer, generation == transfer.id, transfer.session === session, transfer.task === task,
            let url = request.url, transfer.redirects < 5,
            AppUpdateDownloadPolicy.trustedRedirectURL(url, release: transfer.plan.release, filename: transfer.activeAsset.name)
        else {
            completionHandler(nil)
            if let transfer, transfer.session === session { fail(transfer.id, "下载跳转来源不受信任。 / Untrusted download redirect.") }
            return
        }
        transfer.redirects += 1
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        sanitized.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(sanitized)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer, generation == transfer.id, transfer.session === session, transfer.task === dataTask else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let url = http.url,
            AppUpdateDownloadPolicy.trustedRedirectURL(url, release: transfer.plan.release, filename: transfer.activeAsset.name),
            http.expectedContentLength == transfer.activeAsset.size,
            http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true
        else {
            completionHandler(.cancel)
            fail(transfer.id, "下载响应或文件大小不匹配。 / Download response or file size does not match.")
            return
        }
        transfer.responseAccepted = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer, generation == transfer.id, transfer.session === session, transfer.task === dataTask, transfer.responseAccepted else { return }
        guard Int64(data.count) <= transfer.activeAsset.size - transfer.received else {
            fail(transfer.id, "下载文件超过声明大小，已停止。 / Download exceeds its declared size.")
            return
        }
        do {
            if transfer.checksumPhase {
                transfer.checksumData.append(data)
            } else {
                try transfer.file?.write(contentsOf: data)
                transfer.hasher.update(data: data)
            }
            transfer.received += Int64(data.count)
            let progressAt = ProcessInfo.processInfo.systemUptime
            if !transfer.checksumPhase,
                transfer.received == transfer.plan.asset.size || progressAt - transfer.lastProgressAt >= 0.1
            {
                transfer.lastProgressAt = progressAt
                publish(.downloading(received: transfer.received, total: transfer.plan.asset.size), id: transfer.id)
            }
        } catch { fail(transfer.id, "无法保存安装包。 / Unable to save the package.") }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Public release downloads never use account credentials or client certificates.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer, generation == transfer.id, transfer.session === session, transfer.task === task else { return }
        guard error == nil, transfer.responseAccepted, transfer.received == transfer.activeAsset.size else {
            fail(transfer.id, error == nil ? "下载不完整，请重试。 / Incomplete download; try again." : "下载失败，请重试。 / Download failed; try again.")
            return
        }
        do {
            if transfer.checksumPhase {
                guard let hash = AppUpdateDownloadPolicy.checksumHash(transfer.checksumData, filename: transfer.plan.asset.name) else {
                    throw AppUpdateDownloadPolicy.Failure(message: "SHA256 文件不匹配，无法下载。 / The checksum file does not match this package.")
                }
                transfer.expectedHash = hash
                transfer.checksumPhase = false
                try requestNextAsset(transfer)
                return
            }
            publish(.verifying, id: transfer.id)
            try transfer.file?.close()
            transfer.file = nil
            guard let partial = transfer.partialURL, let directory = transfer.directory,
                let expectedHash = transfer.expectedHash, Self.hex(transfer.hasher.finalize()) == expectedHash,
                let actualSize = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                Int64(actualSize) == transfer.plan.asset.size
            else { throw AppUpdateDownloadPolicy.Failure(message: "安装包 SHA256 或大小校验失败，请重试。 / Package SHA256 or size verification failed; try again.") }
            let destination = directory.appendingPathComponent(transfer.plan.asset.name)
            guard generation == transfer.id else {
                cleanupTransfer()
                return
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            guard generation == transfer.id else {
                cleanupTransfer()
                return
            }
            completed = (
                transfer.id, AppUpdateDownloadPolicy.identity(release: transfer.plan.release, asset: transfer.plan.asset), destination, transfer.plan.asset.size, expectedHash
            )
            transfer.session.finishTasksAndInvalidate()
            self.transfer = nil
            publish(.downloaded(destination), id: transfer.id)
        } catch { fail(transfer.id, Self.failureMessage(error)) }
    }

    private func publish(_ state: AppUpdateDownloadState, id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == id else { return }
            self.state = state
        }
    }

    private func fail(_ id: UUID, _ message: String) {
        if transfer?.id == id { cleanupTransfer() }
        // Avoid surfacing URLs, signed CDN query strings or private paths from system errors.
        let safeMessage =
            message.hasPrefix("/") || message.contains("https://") || message.contains("file://")
            ? "下载失败，请重试。 / Download failed; try again." : message
        publish(.failed(safeMessage), id: id)
    }

    private static func failureMessage(_ error: Error) -> String {
        (error as? AppUpdateDownloadPolicy.Failure)?.message ?? "下载失败，请重试。 / Download failed; try again."
    }

    private func cleanupTransfer() {
        guard let old = transfer else { return }
        transfer = nil
        old.task?.cancel()
        old.session?.invalidateAndCancel()
        try? old.file?.close()
        if let directory = old.directory { try? FileManager.default.removeItem(at: directory) }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
