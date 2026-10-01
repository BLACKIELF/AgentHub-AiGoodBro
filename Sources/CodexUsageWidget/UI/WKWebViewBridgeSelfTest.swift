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
              // The day details are collapsed by default. Open them as a user
              // would so the two tool counts exercise the content-size bridge.
              const disclosure = document.getElementById('day-disclosure');
              disclosure.open = true;
              const detailsVisible = getComputedStyle(document.querySelector('.day-summary-content')).display !== 'none';
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
                noPadding, selectionInRange, trendUsesWidth, detailsVisible, tall, short, expected
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
            probe["detailsVisible"] as? Bool == true,
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
        return testHomeDashboard()
    }

    /// Exercise the production native renderer and its authenticated preference
    /// callback, not only a JavaScript call with hand-assembled options.
    private static func testHomeDashboard() -> Bool {
        let renderer = UpstreamTrendView.Renderer(homeDashboard: true)
        final class Delegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            let renderer: UpstreamTrendView.Renderer
            init(_ renderer: UpstreamTrendView.Renderer) { self.renderer = renderer }
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                Task { @MainActor in
                    renderer.didFinishLoading(webView, navigation: navigation)
                }
            }
            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                Task { @MainActor in
                    guard let web = message.webView else { return }
                    if message.name == "chartPreferences" {
                        renderer.receiveHomePreferences(body: message.body, from: web, isMainFrame: message.frameInfo.isMainFrame, url: message.frameInfo.request.url)
                    } else {
                        renderer.receiveContentSize(body: message.body, from: web, isMainFrame: message.frameInfo.isMainFrame, url: message.frameInfo.request.url)
                    }
                }
            }
        }
        let delegate = Delegate(renderer)
        let configuration = WKWebViewConfiguration()
        // WebKit suspends rAF for an offscreen test window. Schedule the same
        // production callback with a timer; DOM measurement and native guards
        // remain real, without bringing a test window over the user's work.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: "window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 0);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for name in ["chartPreferences", "chartSize"] { configuration.userContentController.add(delegate, name: name) }
        defer {
            for name in ["chartPreferences", "chartSize"] { configuration.userContentController.removeScriptMessageHandler(forName: name) }
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 700), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1120, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        web.navigationDelegate = delegate
        let fixture = """
            {"schemaVersion":1,"collectedAt":"2026-09-28T10:00:00Z","timezone":"Asia/Shanghai","coverage":{"cost":"known"},
            "payload":{"aggregate":{"history":{"daily":[{"date":"2026-09-27","tokens":20,"cost":1,"perClient":{"codex":{"tokens":20}}},
            {"date":"2026-09-28","tokens":30,"cost":2,"perClient":{"kimi":{"tokens":30}}}],"summary":{"totalTokens":50,"totalCost":3}}}}}
            """
        var received: [HomeDashboardPreferences] = []
        renderer.onHomePreferences = { received.append($0) }
        renderer.update(dashboardJSON: fixture, resetAnnotations: [], height: 380, homePreferences: .init())
        renderer.loadIfNeeded(in: web)
        let deadline = Date().addingTimeInterval(10)
        while renderer.state == .loading, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard renderer.state == .ready else {
            print("Home dashboard native bridge failed: \(renderer.state)")
            return false
        }
        func evaluate(_ script: String) -> [String: Any]? {
            let done = DispatchSemaphore(value: 0)
            var result: [String: Any]?
            web.evaluateJavaScript(script) { value, error in
                if error == nil { result = value as? [String: Any] }
                done.signal()
            }
            wait(on: done, seconds: 5)
            return result
        }
        func evaluateValue(_ script: String) -> Any? {
            let done = DispatchSemaphore(value: 0)
            var result: Any?
            web.evaluateJavaScript(script) { value, _ in
                result = value
                done.signal()
            }
            wait(on: done, seconds: 5)
            return result
        }
        guard
            let initial = evaluate(
                """
                (() => {
                  const columns = getComputedStyle(document.getElementById('homeDashboard')).gridTemplateColumns.split(' ').length;
                  const start = document.getElementById('heatmapStart'); const initial = start.value;
                  start.value = '2026-08-01'; start.dispatchEvent(new Event('change'));
                  const splitter = document.getElementById('dashSplitter');
                  return {columns, initial, snapshot:window.AiGoodBroDashboard.snapshotID,
                    splitter:!!splitter, splitRatio:window.AiGoodBroDashboard.preferences.splitRatio,
                    both:!document.getElementById('trendsPane').classList.contains('hidden') && !document.getElementById('activityPane').classList.contains('hidden')};
                })()
                """), initial["columns"] as? Int == 3, initial["initial"] as? String == "2026-06-01",
            initial["splitter"] as? Bool == true, (initial["splitRatio"] as? Double ?? -1) == HomeDashboardPreferences.defaultSplitRatio,
            initial["both"] as? Bool == true
        else {
            print("Home dashboard native bridge failed: split layout/date")
            return false
        }
        let callbackDeadline = Date().addingTimeInterval(3)
        while received.isEmpty || renderer.contentHeight <= 220, Date() < callbackDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard received.count == 1, received[0].heatmapStart == "2026-08-01", renderer.contentHeight > 220 else {
            print("Home dashboard native bridge failed: preference callbacks=\(received.count), height=\(renderer.contentHeight)")
            return false
        }
        let keyboardSplit =
            (evaluateValue(
                "(() => { const s = document.getElementById('dashSplitter'); s.focus(); s.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight', bubbles:true})); return window.AiGoodBroDashboard.preferences.splitRatio; })()"
            ) as? Double) ?? 0
        guard keyboardSplit > HomeDashboardPreferences.defaultSplitRatio else {
            print("Home dashboard native bridge failed: splitter keyboard adjustment")
            return false
        }
        let splitDeadline = Date().addingTimeInterval(2)
        while received.count < 2, Date() < splitDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard received.count >= 2, received[1].splitRatio > HomeDashboardPreferences.defaultSplitRatio else {
            print("Home dashboard native bridge failed: splitter preference callback")
            return false
        }
        guard let data = try? JSONEncoder().encode(received[0]),
            let object = try? JSONSerialization.jsonObject(with: data), let snapshot = initial["snapshot"] as? String
        else { return false }
        // Stale callbacks, external frames and invalid preferences cannot write settings.
        let valid: [String: Any] = ["snapshotID": snapshot, "preferences": object]
        renderer.receiveHomePreferences(body: valid, from: web, isMainFrame: false, url: web.url)
        renderer.receiveHomePreferences(body: valid, from: web, isMainFrame: true, url: URL(string: "https://example.invalid"))
        renderer.receiveHomePreferences(body: ["snapshotID": "stale", "preferences": object], from: web, isMainFrame: true, url: web.url)
        renderer.receiveHomePreferences(body: ["snapshotID": snapshot, "preferences": ["mode": "invalid"]], from: web, isMainFrame: true, url: web.url)
        guard received.count == 2 else { return false }
        guard
            evaluate(
                """
                (() => { window.nativeRenders = 0; const render = window.__renderTrend;
                  window.__renderTrend = (...args) => { window.nativeRenders++; return render(...args); };
                  return {count:window.nativeRenders}; })()
                """)?["count"] as? Int == 0
        else { return false }
        renderer.update(dashboardJSON: fixture, resetAnnotations: [], height: 380, homePreferences: received[1])
        guard renderer.state == .ready, evaluate("({count:window.nativeRenders})")?["count"] as? Int == 0 else {
            print("Home dashboard native bridge failed: preference echo rerender")
            return false
        }
        renderer.update(dashboardJSON: fixture, resetAnnotations: [], height: 380, language: .en, homePreferences: received[1])
        guard renderer.state == .ready else {
            print("Home dashboard native bridge failed: valid rerender hid prior content")
            return false
        }
        let nextDeadline = Date().addingTimeInterval(5)
        var reused = evaluate(
            "({start:document.getElementById('heatmapStart').value,label:document.getElementById('heatmapStartLabel').textContent,snapshot:window.AiGoodBroDashboard.snapshotID,count:window.nativeRenders})"
        )
        while reused?["label"] as? String != "Start date", Date() < nextDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            reused = evaluate(
                "({start:document.getElementById('heatmapStart').value,label:document.getElementById('heatmapStartLabel').textContent,snapshot:window.AiGoodBroDashboard.snapshotID,count:window.nativeRenders})"
            )
        }
        let oldPreferences = """
            {"heatmapStart":"2026-08-01","heatmapMetric":"cost","range":"30","mode":"bars","stackBy":"client"}
            """.data(using: .utf8)
        let oversizedPreferences = "{\"height\":10000}".data(using: .utf8)
        let undersizedPreferences = "{\"height\":1}".data(using: .utf8)
        guard renderer.state == .ready, reused?["start"] as? String == "2026-08-01", reused?["label"] as? String == "Start date",
            reused?["snapshot"] as? String == snapshot, reused?["count"] as? Int == 1,
            HomeDashboardPreferences.load(data) == received[0],
            HomeDashboardPreferences.load(oldPreferences).height == HomeDashboardPreferences.defaultHeight,
            HomeDashboardPreferences.load(oversizedPreferences).height == HomeDashboardPreferences.maximumHeight,
            HomeDashboardPreferences.load(undersizedPreferences).height == HomeDashboardPreferences.minimumHeight
        else {
            print("Home dashboard native bridge failed: snapshot/preference reuse")
            return false
        }
        var resized = received[1]
        resized.height = 480
        renderer.update(dashboardJSON: fixture, resetAnnotations: [], height: 480, language: .en, homePreferences: resized)
        guard renderer.state == .ready,
            evaluate("({count:window.nativeRenders})")?["count"] as? Int == 1
        else {
            print("Home dashboard native bridge failed: height-only redraw")
            return false
        }
        guard
            let toggles = evaluate(
                """
                (() => {
                  const home = window.AiGoodBroDashboard;
                  const heat = document.querySelector('#dashHeatmap svg');
                  document.querySelector('[data-mode="kline"]').click(); home.render();
                  const heatKept = document.querySelector('#dashHeatmap svg') === heat;
                  const chart = document.querySelector('#dashChart svg');
                  document.querySelector('[data-control="heatmapMetric"] [data-val="tokens"]').click(); home.render();
                  const chartKept = document.querySelector('#dashChart svg') === chart;
                  const tokensHeat = document.querySelector('#dashHeatmap svg');
                  document.querySelector('[data-control="heatmapMetric"] [data-val="tokens"]').click(); home.render();
                  const repeatKept = document.querySelector('#dashHeatmap svg') === tokensHeat;
                  return {heatKept, chartKept, repeatKept};
                })()
                """), toggles["heatKept"] as? Bool == true,
            toggles["chartKept"] as? Bool == true, toggles["repeatKept"] as? Bool == true
        else {
            print("Home dashboard native bridge failed: repeat toggle redraw")
            return false
        }
        let resizedDeadline = Date().addingTimeInterval(3)
        while received.count == 2, Date() < resizedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard received.count > 2, received.dropFirst(2).allSatisfy({ $0.height == 480 }) else {
            print("Home dashboard native bridge failed: web toggle reset dragged height")
            return false
        }
        renderer.update(
            dashboardJSON: fixture, resetAnnotations: [], height: 480, language: .en,
            homePreferences: resized, summaryCost: .init(value: 19732.09))
        let costDeadline = Date().addingTimeInterval(3)
        while Date() < costDeadline {
            if evaluateValue("window.AiGoodBroDashboard.history.summary.totalCost") as? Double == 19732.09 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard evaluateValue("window.AiGoodBroDashboard.history.summary.totalCost") as? Double == 19732.09,
            evaluateValue("document.querySelectorAll('.dash-card-v')[1].textContent") as? String == "$19732.09",
            evaluateValue("document.querySelector('.summary-resize').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true})); true") as? Bool == true
        else {
            print("Home dashboard native bridge failed: shared tray cost/metric resize")
            return false
        }
        let widthsDeadline = Date().addingTimeInterval(3)
        while received.last?.summaryWidths.isEmpty != false, Date() < widthsDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let widths = received.last, widths.summaryWidths.count == 8, widths.isValid,
            HomeDashboardPreferences.load(try? JSONEncoder().encode(widths)).summaryWidths == widths.summaryWidths
        else {
            print("Home dashboard native bridge failed: metric widths persistence")
            return false
        }
        _ = evaluateValue("window.costOnlyHeatmap = document.querySelector('#dashHeatmap svg'); true")
        renderer.update(
            dashboardJSON: fixture, resetAnnotations: [], height: 480, language: .en,
            homePreferences: widths, summaryCost: .init(value: 19733.1))
        let visibleCostDeadline = Date().addingTimeInterval(3)
        while Date() < visibleCostDeadline {
            if evaluateValue("document.querySelectorAll('.dash-card-v')[1].textContent") as? String == "$19733.10" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard evaluateValue("document.querySelectorAll('.dash-card-v')[1].textContent") as? String == "$19733.10",
            evaluateValue("window.costOnlyHeatmap === document.querySelector('#dashHeatmap svg')") as? Bool == true
        else {
            print("Home dashboard native bridge failed: visible cost-only update")
            return false
        }
        renderer.update(
            dashboardJSON: fixture, resetAnnotations: [], height: 480, language: .en,
            homePreferences: widths, summaryCost: .init(value: nil))
        let unknownDeadline = Date().addingTimeInterval(3)
        while Date() < unknownDeadline {
            if evaluateValue("window.AiGoodBroDashboard.history.summary.totalCost == null") as? Bool == true { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard evaluateValue("window.AiGoodBroDashboard.history.summary.totalCost == null") as? Bool == true,
            evaluateValue("document.querySelectorAll('.dash-card-v')[1].textContent") as? String == "—"
        else {
            print("Home dashboard native bridge failed: unknown shared cost")
            return false
        }
        print("Home dashboard native bridge passed: shared tray cost, saved metric widths, split panes, guarded callbacks and snapshot reuse")
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
