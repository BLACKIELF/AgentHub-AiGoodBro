import AppKit
import Foundation
import WebKit

/// Regression for two overflowing grid rows sharing a short, narrow viewport.
@main
@MainActor
enum HomeDashboardLayoutFixture {
    final class Navigation: NSObject, WKNavigationDelegate {
        var ready = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true }
    }

    static func main() {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the home-dashboard.html path") }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.requestAnimationFrame = cb => setTimeout(() => cb(performance.now()), 0);",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 340), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1120, height: 340),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let delegate = Navigation()
        web.navigationDelegate = delegate
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        let deadline = Date().addingTimeInterval(10)
        while !delegate.ready && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(delegate.ready, "Dashboard navigation timed out")

        func evaluate(_ script: String) -> [String: Any] {
            var finished = false
            var result: [String: Any]?
            web.evaluateJavaScript(script) { value, error in
                if error == nil { result = value as? [String: Any] }
                finished = true
            }
            let deadline = Date().addingTimeInterval(5)
            while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard let result else { fatalError("Dashboard evaluation failed") }
            return result
        }

        _ = evaluate("""
            (() => {
              const daily = Array.from({length:95}, (_,i) => ({
                date:new Date(Date.UTC(2026,5,26+i)).toISOString().slice(0,10),
                tokens:(i+1)*1000000, cost:i+1,
                perClient:{codex:{tokens:(i+1)*700000},kimi:{tokens:(i+1)*300000}},
                perModel:{'gpt-6-sol':{tokens:(i+1)*700000},'gpt-6-luna':{tokens:(i+1)*300000}}
              }));
              window.__renderTrend({schemaVersion:1,collectedAt:'2026-09-28T10:00:00Z',
                timezone:'Asia/Shanghai',coverage:{cost:'known'},
                payload:{aggregate:{history:{daily,summary:{totalTokens:4560000000,totalCost:4560}}}}},
                {snapshotID:'layout-fixture',language:'zh',homePreferences:{mode:'kline',heatmapMetric:'cost',height:292}});
              return {ready:true};
            })()
            """)

        let sizes: [(Int, Int)] = [(1120,340),(761,260),(760,260),(700,292),(420,340),(360,260),(700,900),(1120,260)]
        for (width, height) in sizes {
            window.setContentSize(NSSize(width: width, height: height))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            for expanded in [false, true] {
                _ = evaluate("(() => { document.getElementById('breakdownDetails').open = \(expanded); return {ready:true}; })()")
                let result = evaluate("""
                    (() => {
                      const root = document.getElementById('homeDashboard');
                      const overview = document.getElementById('activityPane');
                      const trends = document.getElementById('trendsPane');
                      const a = overview.getBoundingClientRect(), b = trends.getBoundingClientRect();
                      const summary = document.getElementById('dashCards').getBoundingClientRect();
                      const details = document.getElementById('breakdownDetails').getBoundingClientRect();
                      const contentBottom = Math.max(a.bottom,
                        ...Array.from(overview.children, child => child.getBoundingClientRect().bottom));
                      const narrow = innerWidth <= 760;
                      return {width:innerWidth,height:innerHeight,
                        separated:narrow ? b.top >= contentBottom : b.left >= a.right,
                        summaryAbove:summary.bottom <= Math.min(a.top, b.top),
                        numbersFit:Array.from(document.querySelectorAll('.dash-card-v')).every(
                          el => el.scrollWidth <= el.clientWidth + 1 && el.scrollHeight <= el.clientHeight + 1),
                        horizontalFit:root.scrollWidth <= root.clientWidth + 1,
                        verticalAccess:root.scrollHeight <= root.clientHeight || getComputedStyle(root).overflowY === 'auto',
                        compactCalendar:Array.from(document.querySelectorAll('#dashHeatmap rect[data-d]')).every(
                          el => el.getBoundingClientRect().width <= 18.1),
                        compactTrend:document.getElementById('dashChart').clientHeight === 170,
                        detailsBelow:details.top >= Math.max(a.bottom,b.bottom),
                        compactColumns:narrow || (a.width <= 420 && b.width > a.width),
                        contentBottom,trendsTop:b.top};
                    })()
                    """)
                guard result["separated"] as? Bool == true,
                      result["summaryAbove"] as? Bool == true,
                      result["numbersFit"] as? Bool == true,
                      result["horizontalFit"] as? Bool == true,
                      result["verticalAccess"] as? Bool == true,
                      result["compactCalendar"] as? Bool == true,
                      result["compactTrend"] as? Bool == true,
                      result["detailsBelow"] as? Bool == true,
                      result["compactColumns"] as? Bool == true else {
                    print("FAIL WebKit dashboard layout: \(result)")
                    exit(1)
                }
                print("PASS WebKit dashboard \(width)x\(height), breakdown expanded=\(expanded)")
            }
        }
        print("Home dashboard WebKit resize regression passed")
    }
}
