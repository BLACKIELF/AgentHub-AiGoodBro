import Cocoa
import WebKit

/// Minimal native-bridge smoke: load the real standalone.html in a
/// WKWebView — the kernel the app actually ships — and drive the production
/// JavaScript entry (__renderTrend) via evaluateJavaScript. Source asset
/// first, bundled copy as fallback. This checks the bridge contract only;
/// it does not validate the full production renderer chain (native parameter
/// assembly, JSON transport, snapshot reuse, callbacks).
@MainActor
enum WKWebViewBridgeSelfTest {
    private final class SizeReceiver: NSObject, WKScriptMessageHandler {
        var heights: [Double] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any], let height = body["height"] as? Double {
                heights.append(height)
            }
        }
    }

    static func run() -> Bool {
        _ = NSApplication.shared
        guard UpstreamTrendWebViewScrollSelfTest.run() else {
            print("WKWebView bridge self-test failed: chart scroll ownership")
            return false
        }
        let htmlURL = assetURL()
        guard let htmlURL, FileManager.default.fileExists(atPath: htmlURL.path) else {
            print("WKWebView bridge self-test failed: standalone.html not found")
            return false
        }
        let sizes = SizeReceiver()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(sizes, name: "chartSize")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1400), configuration: configuration)
        defer { configuration.userContentController.removeScriptMessageHandler(forName: "chartSize") }
        let navigationDone = DispatchSemaphore(value: 0)
        final class Delegate: NSObject, WKNavigationDelegate {
            let done: DispatchSemaphore
            var finished = false
            init(done: DispatchSemaphore) { self.done = done }
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                finished = true
                done.signal()
            }
            func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
                done.signal()
            }
        }
        let delegate = Delegate(done: navigationDone)
        web.navigationDelegate = delegate
        web.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        wait(on: navigationDone, seconds: 10)
        guard delegate.finished else {
            print("WKWebView bridge self-test failed: navigation did not finish")
            return false
        }

        let script = """
            (() => {
              if (typeof window.__renderTrend !== 'function') return {failure: 'api missing'};
              const tools = Object.fromEntries(Array.from({length:8},(_,i)=>['tool-'+i,{tokens:10}]));
              const fixture = {schemaVersion:1,collectedAt:'2026-09-13T00:00:00Z',timezone:'UTC',coverage:{days:[]},payload:{aggregate:{history:{daily:[
                {date:'2026-09-11',tokens:999,perClient:{outside:{tokens:999}}},
                {date:'2026-09-12',tokens:20,perClient:{one:{tokens:20}}},
                {date:'2026-09-13',tokens:80,perClient:tools}
              ]}}}};
              // Deterministically flush the production rAF callbacks after DOM
              // updates. Geometry and chartSize messages use the real kernel.
              const callbacks = []; const expected = [];
              window.requestAnimationFrame = callback => callbacks.push(callback);
              window.flushChartSizeForTest = () => {
                const height = Math.ceil(document.body.getBoundingClientRect().height) + 4;
                callbacks.splice(0).forEach(callback => { expected.push(height); callback(); });
                return height;
              };
              const svg = window.__renderTrend(JSON.stringify(fixture),{snapshotID:'test:1',from:'2026-09-12',to:'2026-09-13'});
              const tall = window.flushChartSizeForTest();
              document.querySelector('#calendar [data-d="2026-09-12"]').dispatchEvent(new MouseEvent('click'));
              const short = window.flushChartSizeForTest();
              const noPadding = !document.querySelector('#calendar [data-d="2026-09-11"]');
              document.querySelector('button[data-mode="trends"]').click();
              const trendWidth = document.getElementById('trends').getBoundingClientRect().width;
              const chartWidth = document.getElementById('charts').getBoundingClientRect().width;
              const trendUsesWidth = Math.abs(trendWidth - chartWidth) < 2;
              window.flushChartSizeForTest();
              document.querySelector('button[data-mode="overview"]').click();
              window.__renderTrend(null,{snapshotID:'test:1',from:'2026-09-13',to:'2026-09-13'});
              const selectionInRange = document.getElementById('date').value === '2026-09-13';
              window.flushChartSizeForTest();
              return {
                svg: typeof svg === 'string' && svg.startsWith('<svg'),
                cell: !!document.querySelector('#calendar [data-d="2026-09-13"]'),
                nativeOwned: document.getElementById('from').disabled === true && document.getElementById('to').disabled === true,
                noPadding, selectionInRange, trendUsesWidth, tall, short, expected
              };
            })()
            """
        let evalDone = DispatchSemaphore(value: 0)
        var probe: [String: Any]?
        var evalError: String?
        web.evaluateJavaScript(script) { result, error in
            probe = result as? [String: Any]
            evalError = error?.localizedDescription
            evalDone.signal()
        }
        wait(on: evalDone, seconds: 10)
        guard evalError == nil, let probe,
            probe["failure"] == nil,
            probe["svg"] as? Bool == true,
            probe["cell"] as? Bool == true,
            probe["nativeOwned"] as? Bool == true,
            probe["noPadding"] as? Bool == true,
            probe["selectionInRange"] as? Bool == true,
            probe["trendUsesWidth"] as? Bool == true,
            let tall = probe["tall"] as? Double, let short = probe["short"] as? Double,
            tall > short + 40, tall < 1400,
            let expected = probe["expected"] as? [Double], !expected.isEmpty,
            sizes.heights == expected
        else {
            print("WKWebView bridge self-test failed: \(evalError ?? String(describing: probe)) (asset: \(htmlURL.path))")
            return false
        }
        print(
            "WKWebView bridge self-test passed: real kernel, native date bounds, content shrinks \(tall) → \(short), chartSize matches DOM, window/clipping/overlay scroll guards")
        return true
    }

    /// Source asset first: it is the contract under test. The bundled copy is
    /// only a fallback; a make build keeps it identical to source.
    private static func assetURL() -> URL? {
        sourceAssetURL() ?? bundledAssetURL()
    }

    private static func bundledAssetURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("UpstreamCharts/standalone.html")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func sourceAssetURL() -> URL? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/UpstreamCharts/standalone.html")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func wait(on semaphore: DispatchSemaphore, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while semaphore.wait(timeout: .now()) != .success, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }
}
