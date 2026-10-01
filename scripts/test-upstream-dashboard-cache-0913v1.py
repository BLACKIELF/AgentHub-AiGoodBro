#!/usr/bin/env python3
"""Compile the exact production Renderer with a controlled WK transport (no GUI).

The transport records actual callAsyncJavaScript arguments and delivers callbacks
in adversarial orders. Foundation still parses JSON; the spy counts large parses.
--source may point to a frozen baseline for an expected-failure comparison.
"""
import argparse
import pathlib
import platform
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--source", type=pathlib.Path, default=ROOT / "Sources/CodexUsageWidget/UI/UpstreamTrendView.swift")
args = parser.parse_args()
source = args.source.read_text()
types = source[source.index("    struct SummaryCost:"):source.index("    let points: [Point]")]
renderer = source[source.index("    @MainActor\n    final class Renderer:"):source.index("\n}\n\nprivate extension")]
fixture = r'''
import Foundation
import Combine
import CoreGraphics

enum WidgetLanguage: String { case zh, en }
enum JSONSerialization {
    static var largeParses = 0
    static func jsonObject(with data: Data) throws -> Any {
        if data.count > 1_000_000 { largeParses += 1 }
        return try Foundation.JSONSerialization.jsonObject(with: data)
    }
    static func data(withJSONObject object: Any) throws -> Data {
        try Foundation.JSONSerialization.data(withJSONObject: object)
    }
}
// This fixture exercises the standalone renderer. The home-only cost
// projection has its own integration suite and must not run here.
struct TokenMonitorDashboardSnapshot {
    enum Period { case total }
    enum Metric { case cost }
    init(response: TokenMonitorResponse) {}
    func value(for period: Period, metric: Metric) -> Double? {
        fatalError("home cost projection is outside the standalone fixture")
    }
}
enum TokenMonitorEngine {
    static let maximumOutputBytes = 16 * 1_024 * 1_024
}
final class WKNavigation: NSObject {}
enum WKContentWorld { case page }
@MainActor final class WKWebView: NSObject {
    struct Call {
        let body: String
        let arguments: [String: Any]
        let completion: (Result<Any, Error>) -> Void
    }
    var bounds = CGRect(x: 0, y: 0, width: 650, height: 260)
    var calls: [Call] = []
    var navigation: WKNavigation?
    var rendererAvailable = true
    func loadFileURL(_ url: URL, allowingReadAccessTo: URL) -> WKNavigation? {
        navigation = WKNavigation()
        return navigation
    }
    func evaluateJavaScript(_ body: String, completionHandler: @escaping (Any?, Error?) -> Void) {
        completionHandler(rendererAvailable, nil)
    }
    func callAsyncJavaScript(_ body: String, arguments: [String: Any], in frame: Any?, in world: WKContentWorld,
                            completionHandler: @escaping (Result<Any, Error>) -> Void) {
        calls.append(Call(body: body, arguments: arguments, completion: completionHandler))
    }
}
@MainActor enum UpstreamTrendView {
''' + types + renderer + r'''
}
extension UpstreamTrendView.Renderer {
    func fixtureNavigate(_ web: WKWebView) {
        attach(web)
        resourceURL = URL(fileURLWithPath: "/synthetic/standalone.html")
        startLoad(in: web, resourceURL: resourceURL!)
    }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: " + message); exit(1) }
}
@main struct Fixture {
    @MainActor static func drain() async { for _ in 0..<30 { await Task.yield() } }
    @MainActor static func main() async {
        typealias Renderer = UpstreamTrendView.Renderer
        let base = "{\"schemaVersion\":1,\"payload\":{}}"
        let large = base + String(repeating: " ", count: 10_085_083 - base.utf8.count)
        let r = Renderer(), web = WKWebView()
        r.update(dashboardJSON: large, resetAnnotations: [], height: 260)
        for i in 0..<8 {
            let annotation = UpstreamTrendView.ResetAnnotation(date: "2026-09-13", kind: .regular, text: "reset \(i)")
            r.update(dashboardJSON: large, resetAnnotations: [annotation], height: CGFloat(280+i), language: i % 2 == 0 ? .en : .zh)
        }
        require(JSONSerialization.largeParses == 1, "presentation-only updates must validate the 10MB snapshot once")
        r.fixtureNavigate(web)
        r.didFinishLoading(web, navigation: web.navigation)
        await drain()
        require(web.calls.count == 1 && web.calls[0].arguments["input"] as? String == large, "first realm must send full snapshot")
        let initialOptions = web.calls[0].arguments["options"] as! [String: Any]
        require(initialOptions["snapshotID"] is String, "full payload needs a snapshot identity")
        for i in 0..<8 {
            web.bounds.size.width = CGFloat(700+i*20)
            r.render(in: web)
            r.update(dashboardJSON: large, resetAnnotations: [], height: CGFloat(330+i), language: .en)
        }
        require(web.calls.count == 1, "only one script may run while callbacks are pending")
        web.calls[0].completion(.success("<svg></svg>"))
        await drain()
        require(web.calls.count == 2 && web.calls[1].arguments["input"] is NSNull, "coalesced options must not retransmit full JSON")
        let options = web.calls[1].arguments["options"] as! [String: Any]
        require(options["snapshotID"] as? String == initialOptions["snapshotID"] as? String, "option update must reference installed snapshot")
        require((options["height"] as? CGFloat) == 337 && (options["width"] as? CGFloat) == 840, "latest presentation parameters must win")
        web.calls[0].completion(.failure(NSError(domain: "synthetic", code: 1)))
        await drain()
        require(r.state == .loading && web.calls.count == 2, "old duplicate callback must not complete or clear current work")
        web.calls[1].completion(.success("<svg></svg>"))
        await drain()
        require(r.state == .ready, "latest option render succeeds")
        let chartURL = URL(fileURLWithPath: "/synthetic/standalone.html")
        var size: [String: Any] = ["snapshotID": options["snapshotID"]!, "width": 840.0, "height": 310.25]
        let initialHeight = r.contentHeight
        r.receiveContentSize(body: size, from: WKWebView(), isMainFrame: true, url: chartURL)
        r.receiveContentSize(body: size, from: web, isMainFrame: false, url: chartURL)
        r.receiveContentSize(body: size, from: web, isMainFrame: true, url: URL(string: "https://example.invalid"))
        size["snapshotID"] = "stale"
        r.receiveContentSize(body: size, from: web, isMainFrame: true, url: chartURL)
        size["snapshotID"] = options["snapshotID"]
        size["width"] = 600.0
        r.receiveContentSize(body: size, from: web, isMainFrame: true, url: chartURL)
        size["width"] = 840.0
        for invalid in [Double.nan, Double.infinity, -1, 0] {
            size["height"] = invalid
            r.receiveContentSize(body: size, from: web, isMainFrame: true, url: chartURL)
        }
        require(r.contentHeight == initialHeight, "foreign, stale, resized or invalid size reports must be ignored")
        size["height"] = 310.25
        r.receiveContentSize(body: size, from: web, isMainFrame: true, url: chartURL)
        require(r.contentHeight == 311, "current chart height must fit the rendered content")
        size["height"] = 1.0
        r.receiveContentSize(body: size, from: web, isMainFrame: true, url: chartURL)
        require(r.contentHeight == 96, "content height keeps a usable minimum")
        size["height"] = 9000.0
        r.receiveContentSize(body: size, from: web, isMainFrame: true, url: chartURL)
        require(r.contentHeight == 2400, "expanded details stay within the native layout bound")
        let next = large + "\n"
        r.update(dashboardJSON: next, resetAnnotations: [], height: 337, language: .en)
        require(JSONSerialization.largeParses == 2 && web.calls.count == 3, "new snapshot must validate and send exactly once")
        require(web.calls[2].arguments["input"] as? String == next, "new snapshot must not reuse older JSON")
        r.didTerminateContentProcess(web)
        web.calls[2].completion(.success("<svg></svg>"))
        await drain()
        require(r.state == .failed(.processTerminated), "late success must not clear process termination")
        r.fixtureNavigate(web)
        r.didFinishLoading(web, navigation: web.navigation)
        await drain()
        require(web.calls.count == 4 && web.calls[3].arguments["input"] as? String == next, "new realm must reinstall the validated snapshot")
        let nextOptions = web.calls[3].arguments["options"] as! [String: Any]
        require(nextOptions["snapshotID"] as? String != initialOptions["snapshotID"] as? String, "navigation must invalidate transferred identity")
        web.calls[2].completion(.failure(NSError(domain: "synthetic", code: 2)))
        await drain()
        require(r.state == .loading, "previous realm failure must not replace current state")
        web.calls[3].completion(.success("<svg></svg>"))
        await drain()
        require(r.state == .ready && JSONSerialization.largeParses == 2, "navigation reuses native validation but reinstalls JS data")
        r.render(in: web)
        require(web.calls.last!.arguments["input"] is NSNull, "size callbacks after navigation also use options only")
        web.calls.last!.completion(.success("not an svg"))
        await drain()
        require(r.state == .failed(.rendererReturnedNoOutput), "empty renderer result stays an explicit error")
        r.render(in: web)
        web.calls.last!.completion(.failure(NSError(domain: "synthetic", code: 3)))
        await drain()
        require(r.state == .failed(.scriptFailed), "script failure remains explicit")
        r.update(points: [.init(date: "2026-09-13", tokens: 0)], height: 40)
        require(web.calls.last!.arguments["input"] is [Any], "legacy points stay a separate real payload")
        web.calls.last!.completion(.success("<svg></svg>"))
        await drain()
        require(r.state == .ready, "legacy known zero stays renderable")
        r.update(dashboardJSON: next, resetAnnotations: [], height: 260)
        require(web.calls.last!.arguments["input"] as? String == next, "return from legacy must install dashboard again")
        web.calls.last!.completion(.success("<svg></svg>"))
        await drain()

        // A data replacement during an older flight cannot mark the new data installed.
        let replacement = next + "\n"
        r.update(dashboardJSON: replacement, resetAnnotations: [], height: 260)
        let older = web.calls.last!
        r.update(dashboardJSON: replacement + "\n", resetAnnotations: [], height: 260)
        older.completion(.success("<svg></svg>"))
        await drain()
        require(web.calls.last!.arguments["input"] as? String == replacement + "\n", "late old-snapshot success cannot suppress the newest full payload")
        web.calls.last!.completion(.success("<svg></svg>"))
        await drain()
        require(r.state == .ready, "newest snapshot ultimately wins")

        let bounds = Renderer(), maximum = 16 * 1024 * 1024
        let exact = base + String(repeating: " ", count: maximum - base.utf8.count)
        bounds.update(dashboardJSON: exact, resetAnnotations: [], height: 260)
        require(bounds.state == .loading, "exact 16MiB remains valid")
        let parseCount = JSONSerialization.largeParses
        bounds.update(dashboardJSON: exact + " ", resetAnnotations: [], height: 260)
        require(bounds.state == .failed(.invalidData) && JSONSerialization.largeParses == parseCount, "over-limit bytes must be rejected before parsing")
        let multibyte = "{\"schemaVersion\":1,\"payload\":{},\"probe\":\"" + String(repeating: "汉", count: 6_000_000) + "\"}"
        bounds.update(dashboardJSON: multibyte, resetAnnotations: [], height: 260)
        require(bounds.state == .failed(.invalidData) && JSONSerialization.largeParses == parseCount, "UTF-8 overflow cannot pass character-length guard")
        bounds.update(dashboardJSON: "{}", resetAnnotations: [], height: 260)
        require(bounds.state == .failed(.invalidData), "invalid schema remains visible")
        let longValidAnnotation = UpstreamTrendView.ResetAnnotation(date: "2026-09-13", kind: .regular, text: String(repeating: "x", count: 2332))
        bounds.update(dashboardJSON: large, resetAnnotations: [longValidAnnotation], height: 260)
        require(bounds.state == .loading, "a valid public announcement above 2KiB must not invalidate the usage snapshot")
        let annotationParseCount = JSONSerialization.largeParses
        let exactAnnotation = UpstreamTrendView.ResetAnnotation(date: "2026-09-13", kind: .regular, text: String(repeating: "汉", count: 5461) + "x")
        require(exactAnnotation.text.utf8.count == 16384, "annotation fixture is exactly 16KiB in UTF-8")
        bounds.update(dashboardJSON: large, resetAnnotations: [exactAnnotation], height: 260)
        require(bounds.state == .loading && JSONSerialization.largeParses == annotationParseCount, "exact public text bound reuses validated usage data")
        let shortAnnotation = UpstreamTrendView.ResetAnnotation(date: "2026-09-13", kind: .regular, text: "reset")
        bounds.update(dashboardJSON: large, resetAnnotations: Array(repeating: shortAnnotation, count: 500), height: 260)
        require(bounds.state == .loading, "500 annotations remain within the existing count bound")
        bounds.update(dashboardJSON: large, resetAnnotations: Array(repeating: shortAnnotation, count: 501), height: 260)
        require(bounds.state == .failed(.invalidData), "501 annotations still exceed the existing count bound")
        let oversizedMultibyteAnnotation = UpstreamTrendView.ResetAnnotation(date: "2026-09-13", kind: .regular, text: String(repeating: "汉", count: 5462))
        bounds.update(dashboardJSON: large, resetAnnotations: [oversizedMultibyteAnnotation], height: 260)
        require(bounds.state == .failed(.invalidData), "multibyte public text over 16KiB remains invalid")
        let oversizedAnnotation = UpstreamTrendView.ResetAnnotation(date: "2026-09-13", kind: .regular, text: String(repeating: "x", count: 16385))
        bounds.update(dashboardJSON: large, resetAnnotations: [oversizedAnnotation], height: 260)
        require(bounds.state == .failed(.invalidData), "cached data must still validate new options")
        let count = JSONSerialization.largeParses
        bounds.update(dashboardJSON: large, resetAnnotations: [], height: 260)
        require(bounds.state == .loading && JSONSerialization.largeParses == count, "correcting options must reuse validation")
        print("PASS exact production Renderer: one 10MB validation across display changes; serialized small options; new snapshot; navigation/process invalidation; stale callbacks; legacy; 16MiB UTF-8; explicit errors. Controlled WK transport, not GUI proof.")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="upstream-dashboard-cache-") as folder:
    output = pathlib.Path(folder)
    subprocess.run(["python3", str(ROOT / "scripts/check-build-target-idle.py"), str(output / "fixture")], check=True)
    swift = output / "fixture.swift"
    swift.write_text(fixture)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    arch = platform.machine()
    if arch not in ("arm64", "x86_64"):
        raise SystemExit("unsupported host architecture: " + arch)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-sdk", sdk,
                    "-target", arch + "-apple-macosx13.0", str(swift),
                    str(ROOT / "Sources/CodexUsageWidget/Domain/TokenMonitorEngineModels.swift"),
                    str(ROOT / "Sources/CodexUsageWidget/Domain/HomeDashboardPreferences.swift"),
                    "-o", str(output / "fixture")], check=True)
    subprocess.run([str(output / "fixture")], check=True, timeout=60)
