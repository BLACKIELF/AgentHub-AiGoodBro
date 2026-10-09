import Foundation
import CryptoKit

final class FixtureProtocol: URLProtocol {
    static var mode = "ok"
    static var package = Data("synthetic-dmg-fixture".utf8)
    static var requests = 0
    static var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        if Self.mode == "hold" { return }
        let name = request.url!.lastPathComponent
        let payload = name.hasSuffix(".sha256") ? Data("\(digestHex(Self.package))  dist/AiGoodBro-9.6.80-mac-arm64.dmg\n".utf8) : Self.package
        let status = Self.mode == "http403" ? 403 : 200
        let length = Self.mode == "wrong-size" ? payload.count + 1 : payload.count
        let reply = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(length)])!
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stopped = true }
}
func digestHex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func require(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
func settle(_ condition: () -> Bool, timeout: TimeInterval = 5) {
    let end = Date().addingTimeInterval(timeout)
    while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    require(condition(), "fixture timed out")
}
func release(version: String = "9.6.80", digest: String? = nil, withSidecar: Bool = false) -> (GitHubReleaseInfo, GitHubReleaseAsset) {
    let name = "AiGoodBro-\(version)-mac-arm64.dmg"
    let prefix = "https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v\(version)/"
    let asset = GitHubReleaseAsset(name: name, browserDownloadURL: URL(string: prefix + name)!, size: Int64(FixtureProtocol.package.count), contentType: "application/octet-stream", digest: digest)
    let sidecarBody = Data("\(digestHex(FixtureProtocol.package))  dist/\(name)\n".utf8)
    let sidecar = GitHubReleaseAsset(name: name + ".sha256", browserDownloadURL: URL(string: prefix + name + ".sha256")!, size: Int64(sidecarBody.count), contentType: "text/plain")
    return (GitHubReleaseInfo(tagName: "v\(version)", name: "Update", htmlURL: URL(string: "https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/v\(version)")!, publishedAt: Date(), prerelease: false, draft: false, body: "Fixture release", assets: withSidecar ? [asset, sidecar] : [asset]), asset)
}
func runTransportTests() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aigoodbro-update-fixture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]
    let downloader = AppUpdateDownloader(configuration: config, downloadsDirectory: root)
    var metadata = release(digest: "sha256:" + digestHex(FixtureProtocol.package))
    let currentV23 = "2.3.0"
    let legacyOnly = GitHubReleaseUpdateChecker.evaluate(
        releases: [metadata.0], currentVersion: currentV23, includePrereleases: true,
        checkedAt: Date(), architecture: .arm64)
    require(legacyOnly.status == .upToDate && legacyOnly.latestRelease == nil, "2.3 must ignore the retired 9.6.x release line")
    let oldClient = GitHubReleaseUpdateChecker.evaluate(
        releases: [metadata.0], currentVersion: "9.6.79", includePrereleases: true,
        checkedAt: Date(), architecture: .arm64)
    require(oldClient.status == .updateAvailable, "legacy clients must retain their existing SemVer update behavior")
    let currentLineRelease = release(version: "2.3.1", digest: "sha256:" + digestHex(FixtureProtocol.package))
    let mixed = GitHubReleaseUpdateChecker.evaluate(
        releases: [metadata.0, currentLineRelease.0], currentVersion: currentV23, includePrereleases: true,
        checkedAt: Date(), architecture: .arm64)
    require(mixed.status == .updateAvailable && mixed.latestVersionLabel == "2.3.1", "2.3+ must keep normal SemVer update selection")
    let v24 = release(version: "2.4.0", digest: "sha256:" + digestHex(FixtureProtocol.package))
    let upgradeTo24 = GitHubReleaseUpdateChecker.evaluate(
        releases: [metadata.0, v24.0], currentVersion: currentV23, includePrereleases: false,
        checkedAt: Date(), architecture: .arm64)
    require(upgradeTo24.status == .updateAvailable && upgradeTo24.latestVersionLabel == "2.4.0",
            "2.3 must select 2.4 rather than the retired 9.6 release")
    let current24 = GitHubReleaseUpdateChecker.evaluate(
        releases: [metadata.0, v24.0], currentVersion: "2.4.0", includePrereleases: false,
        checkedAt: Date(), architecture: .arm64)
    require(current24.status == .upToDate, "2.4 must not offer the retired 9.6 release")
    let oldTo24 = GitHubReleaseUpdateChecker.evaluate(
        releases: [v24.0], currentVersion: "9.6.80", includePrereleases: false,
        checkedAt: Date(), architecture: .arm64)
    require(oldTo24.status == .upToDate, "9.6 clients require the documented manual version-line migration")
    require((try? AppUpdateDownloadPolicy.plan(release: v24.0, asset: v24.1, currentVersion: currentV23, architecture: .arm64)) != nil,
            "2.4 ARM64 release assets must satisfy the existing download policy")
    require((try? AppUpdateDownloadPolicy.plan(release: metadata.0, asset: metadata.1, currentVersion: currentV23, architecture: .arm64)) == nil,
            "downloader must reject legacy 9.6.x packages from 2.3")
    require((try? AppUpdateDownloadPolicy.plan(release: currentLineRelease.0, asset: currentLineRelease.1, currentVersion: currentV23, architecture: .arm64)) != nil,
            "downloader must accept a newer 2.3-line package after the existing trust checks")
    downloader.start(release: metadata.0, asset: metadata.1, currentVersion: "9.6.79")
    settle { !downloader.state.isBusy }
    guard case .downloaded(let firstFile) = downloader.state else { fatalError("successful fixture not downloaded: \(downloader.state)") }
    require((try? Data(contentsOf: firstFile)) == FixtureProtocol.package, "download bytes mismatch")
    downloader.start(release: metadata.0, asset: metadata.1, currentVersion: "9.6.79")
    settle { !downloader.state.isBusy }
    guard case .downloaded(let secondFile) = downloader.state else { fatalError("second fixture failed") }
    require(firstFile != secondFile, "download overwrote old package")
    metadata = release(digest: "sha256:" + String(repeating: "a", count: 64))
    downloader.start(release: metadata.0, asset: metadata.1, currentVersion: "9.6.79")
    settle { !downloader.state.isBusy }
    guard case .failed = downloader.state else { fatalError("wrong hash accepted") }
    let dirsAfterFailure = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("AiGoodBro Updates"), includingPropertiesForKeys: nil)) ?? []
    require(dirsAfterFailure.count == 2, "failed temporary download survived")
    FixtureProtocol.mode = "wrong-size"
    metadata = release(digest: "sha256:" + digestHex(FixtureProtocol.package))
    downloader.start(release: metadata.0, asset: metadata.1, currentVersion: "9.6.79")
    settle { !downloader.state.isBusy }
    guard case .failed = downloader.state else { fatalError("response wrong size accepted") }
    FixtureProtocol.mode = "http403"
    downloader.start(release: metadata.0, asset: metadata.1, currentVersion: "9.6.79")
    settle { !downloader.state.isBusy }
    guard case .failed = downloader.state else { fatalError("response HTTP403 accepted") }
    FixtureProtocol.mode = "ok"
    metadata = release(withSidecar: true)
    let beforeSidecar = FixtureProtocol.requests
    downloader.start(release: metadata.0, asset: metadata.1, currentVersion: "9.6.79")
    settle { !downloader.state.isBusy }
    guard case .downloaded = downloader.state else { fatalError("sidecar fixture failed: \(downloader.state)") }
    require(FixtureProtocol.requests - beforeSidecar == 2, "sidecar did not bind before package")
    metadata = release()
    let beforeNoHash = FixtureProtocol.requests
    downloader.start(release: metadata.0, asset: metadata.1, currentVersion: "9.6.79")
    settle { !downloader.state.isBusy }
    guard case .failed = downloader.state else { fatalError("no hash fixture accepted") }
    require(beforeNoHash == FixtureProtocol.requests, "package fetched without hash")
    FixtureProtocol.mode = "hold"
    FixtureProtocol.stopped = false
    metadata = release(digest: "sha256:" + digestHex(FixtureProtocol.package))
    downloader.start(release: metadata.0, asset: metadata.1, currentVersion: "9.6.79")
    settle { if case .downloading = downloader.state { return true }; return false }
    downloader.cancel()
    settle { FixtureProtocol.stopped }
    require(downloader.state == .cancelled, "cancel state overwritten")
    FixtureProtocol.mode = "ok"
    downloader.start(release: metadata.0, asset: metadata.1, currentVersion: "9.6.79")
    settle { !downloader.state.isBusy }
    guard case .downloaded = downloader.state else { fatalError("retry after cancellation failed") }
    let originalIdentity = AppUpdateDownloadPolicy.identity(release: metadata.0, asset: metadata.1)
    let changedAsset = GitHubReleaseAsset(name: metadata.1.name, browserDownloadURL: metadata.1.browserDownloadURL, size: metadata.1.size + 1, contentType: metadata.1.contentType, digest: metadata.1.digest)
    require(originalIdentity != AppUpdateDownloadPolicy.identity(release: metadata.0, asset: changedAsset), "same tag asset replacement retained downloaded identity")
    let changedDigest = GitHubReleaseAsset(name: metadata.1.name, browserDownloadURL: metadata.1.browserDownloadURL, size: metadata.1.size, contentType: metadata.1.contentType, digest: "sha256:" + String(repeating: "b", count: 64))
    require(originalIdentity != AppUpdateDownloadPolicy.identity(release: metadata.0, asset: changedDigest), "same tag digest replacement retained downloaded identity")
    let otherURL = URL(string: metadata.1.browserDownloadURL.absoluteString.replacingOccurrences(of: "AgentHub-AiGoodBro", with: "codex-account-manager-next"))!
    let otherAsset = GitHubReleaseAsset(name: metadata.1.name, browserDownloadURL: otherURL, size: metadata.1.size, contentType: metadata.1.contentType, digest: metadata.1.digest)
    let otherRelease = GitHubReleaseInfo(tagName: metadata.0.tagName, name: metadata.0.name, htmlURL: URL(string: metadata.0.htmlURL.absoluteString.replacingOccurrences(of: "AgentHub-AiGoodBro", with: "codex-account-manager-next"))!, publishedAt: metadata.0.publishedAt, prerelease: false, draft: false, body: "", assets: [otherAsset])
    require(originalIdentity != AppUpdateDownloadPolicy.identity(release: otherRelease, asset: otherAsset), "same tag cross-repository update retained downloaded identity")
    downloader.openDownloadedPackage(release: metadata.0, asset: changedAsset)
    guard case .failed = downloader.state else { fatalError("mismatched current update opened an old package") }
    // No matched openDownloadedPackage call is made: real package opening is outside fixture scope.
    print("update downloader transport fixtures passed")
}
