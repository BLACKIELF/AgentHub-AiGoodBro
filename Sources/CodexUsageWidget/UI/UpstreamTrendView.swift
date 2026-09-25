import Combine
import SwiftUI
import WebKit

/// 用 WKWebView 加载 token-monitor（Javis603，MIT）的图表资源渲染用量趋势。
/// Standalone adapter uses the unchanged upstream heatmap and stacked-bar algorithms.
@MainActor
struct UpstreamTrendView: View {
    struct Point: Codable, Equatable {
        let date: String
        let tokens: Double
    }

    struct ResetAnnotation: Codable, Equatable {
        enum Kind: String, Codable { case regular, banked }
        let date: String
        let kind: Kind
        let text: String
    }

    enum RenderFailure: Equatable {
        case invalidData
        case resourceUnavailable
        case navigationFailed
        case rendererUnavailable
        case rendererReturnedNoOutput
        case scriptFailed
        case processTerminated
    }

    enum RenderState: Equatable {
        case loading
        case ready
        case empty
        case failed(RenderFailure)
    }

    let points: [Point]
    let dashboardJSON: String?
    let resetAnnotations: [ResetAnnotation]
    let chartFrom: String?
    let chartTo: String?
    var height: CGFloat = 40
    @StateObject private var renderer: Renderer
    @Environment(\.widgetLanguage) private var language
    @Environment(\.workspaceTrendScreenshots) private var screenshots

    struct Screenshot {
        let image: NSImage
        let dashboardJSON: String?
        let points: [Point]
    }

    /// Export uses pixels from the live WebKit view, including its current JS
    /// range, filters, tab and selection. It must never create another renderer.
    final class ScreenshotContext {
        let captures: [Screenshot]
        private(set) var missingSource = false

        init(captures: [Screenshot]) { self.captures = captures }

        func image(dashboardJSON: String?, points: [Point]) -> NSImage? {
            let matches = captures.filter { $0.dashboardJSON == dashboardJSON && $0.points == points }
            guard matches.count == 1 else {
                missingSource = true
                return nil
            }
            return matches[0].image
        }
    }

    static func captureScreenshots(in root: NSView) async throws -> ScreenshotContext {
        func charts(in view: NSView) -> [ResizeAwareTrendWebView] {
            if let chart = view as? ResizeAwareTrendWebView { return [chart] }
            return view.subviews.flatMap { charts(in: $0) }
        }
        var captures: [Screenshot] = []
        for chart in charts(in: root) {
            guard let renderer = chart.renderer else { throw WorkspaceScreenshotExporter.unavailable("renderer_detached") }
            captures.append(try await renderer.captureScreenshot())
        }
        return ScreenshotContext(captures: captures)
    }

    init(points: [Point], height: CGFloat = 40) {
        self.points = points
        self.dashboardJSON = nil
        self.resetAnnotations = []
        self.chartFrom = nil
        self.chartTo = nil
        self.height = height
        _renderer = StateObject(wrappedValue: Renderer())
    }

    init(
        dashboardJSON: String, resetAnnotations: [ResetAnnotation] = [], height: CGFloat = 260,
        chartFrom: String? = nil, chartTo: String? = nil
    ) {
        self.points = []
        self.dashboardJSON = dashboardJSON
        self.resetAnnotations = resetAnnotations
        self.chartFrom = chartFrom
        self.chartTo = chartTo
        self.height = height
        _renderer = StateObject(wrappedValue: Renderer())
    }

    private func updateRenderer() {
        if let dashboardJSON {
            renderer.update(
                dashboardJSON: dashboardJSON, resetAnnotations: resetAnnotations, height: height, language: language,
                from: chartFrom, to: chartTo)
        } else {
            renderer.update(points: points, height: height)
        }
    }

    var body: some View {
        if let screenshots {
            if let image = screenshots.image(dashboardJSON: dashboardJSON, points: points) {
                Image(nsImage: image)
                    .resizable()
                    .frame(maxWidth: .infinity)
                    .frame(height: image.size.height)
            } else {
                // The exporter rejects this capture after layout, before saving.
                Color.clear.frame(height: safeHeight)
            }
        } else {
            liveContent
        }
    }

    private var liveContent: some View {
        ZStack {
            TrendWebView(
                renderer: renderer
            )
            .opacity(renderer.state == .ready ? 1 : 0)
            .allowsHitTesting(renderer.state == .ready)

            stateView
        }
        .frame(maxWidth: .infinity)
        .frame(height: safeHeight)
        .onAppear {
            updateRenderer()
        }
        .onChange(of: points) { updated in
            updateRenderer()
        }
        .onChange(of: language) { _ in updateRenderer() }
        .onChange(of: dashboardJSON) { _ in updateRenderer() }
        .onChange(of: resetAnnotations) { _ in updateRenderer() }
        .onChange(of: chartFrom) { _ in updateRenderer() }
        .onChange(of: chartTo) { _ in updateRenderer() }
        .onChange(of: height) { updated in
            updateRenderer()
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch renderer.state {
        case .loading:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(language.text("图表加载中…", "Loading chart…"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: safeHeight)
            .background(FixedVisualPalette.surfaceMutedFill, in: RoundedRectangle(cornerRadius: 8))
        case .empty:
            Text(language.text("暂无每日记录", "No daily records"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: safeHeight)
                .background(FixedVisualPalette.surfaceMutedFill, in: RoundedRectangle(cornerRadius: 8))
        case .ready:
            Color.clear
                .frame(maxWidth: .infinity, minHeight: safeHeight)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        case .failed(let failure):
            HStack(spacing: 8) {
                Label(failure.title(language), systemImage: "exclamationmark.triangle")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
                Button(language.text("重试", "Retry")) {
                    renderer.retry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: safeHeight)
            .background(FixedVisualPalette.surfaceMutedFill, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(failure.title(language))
        }
    }

    private var safeHeight: CGFloat {
        if dashboardJSON != nil { return renderer.state == .ready ? renderer.contentHeight : 120 }
        guard height.isFinite else { return 40 }
        return min(600, max(24, height))
    }

    @MainActor
    final class Renderer: NSObject, ObservableObject {
        /// Production state machine shared with the offline lifecycle checks.
        /// Load IDs reject callbacks from replaced navigations; render IDs
        /// reject stale JavaScript completions after data or size changes.
        struct Lifecycle {
            enum InputStatus: Equatable {
                case unknown
                case empty
                case invalid
                case valid
            }

            enum LoadStatus: Equatable {
                case idle
                case loading(UInt64)
                case navigationFinished(UInt64)
                case rendererReady(UInt64)
                case failed(RenderFailure)
            }

            struct RenderID: Equatable {
                let load: UInt64
                let render: UInt64
            }

            private(set) var state: RenderState = .loading
            private(set) var inputStatus: InputStatus = .unknown
            private(set) var loadStatus: LoadStatus = .idle
            private(set) var currentLoadID: UInt64 = 0
            private(set) var currentRenderID: UInt64 = 0
            private var probingLoadID: UInt64?

            mutating func updateInput(_ status: InputStatus) {
                inputStatus = status
                invalidateRender()
                state = stateForCurrentInput()
            }

            mutating func beginLoad() -> UInt64 {
                currentLoadID &+= 1
                invalidateRender()
                probingLoadID = nil
                loadStatus = .loading(currentLoadID)
                state = stateForCurrentInput()
                return currentLoadID
            }

            mutating func failWithoutNavigation(_ failure: RenderFailure) {
                invalidateRender()
                probingLoadID = nil
                loadStatus = .failed(failure)
                state = .failed(failure)
            }

            mutating func finishNavigation(loadID: UInt64) -> Bool {
                guard loadID == currentLoadID, loadStatus == .loading(loadID) else { return false }
                loadStatus = .navigationFinished(loadID)
                state = stateForCurrentInput()
                return inputStatus == .valid
            }

            mutating func failNavigation(loadID: UInt64) -> Bool {
                guard loadID == currentLoadID,
                    loadStatus == .loading(loadID) || loadStatus == .navigationFinished(loadID)
                else { return false }
                failWithoutNavigation(.navigationFailed)
                return true
            }

            mutating func beginRendererProbe() -> UInt64? {
                guard case .navigationFinished(let loadID) = loadStatus,
                    probingLoadID != loadID
                else { return nil }
                probingLoadID = loadID
                return loadID
            }

            mutating func completeRendererProbe(loadID: UInt64, available: Bool) -> Bool {
                guard loadID == currentLoadID,
                    loadStatus == .navigationFinished(loadID),
                    probingLoadID == loadID
                else { return false }
                probingLoadID = nil
                guard available else {
                    loadStatus = .failed(.rendererUnavailable)
                    state = stateForCurrentInput()
                    return false
                }
                loadStatus = .rendererReady(loadID)
                state = stateForCurrentInput()
                return inputStatus == .valid
            }

            mutating func beginRender() -> RenderID? {
                guard inputStatus == .valid,
                    case .rendererReady(let loadID) = loadStatus,
                    loadID == currentLoadID
                else { return nil }
                currentRenderID &+= 1
                state = .loading
                return RenderID(load: loadID, render: currentRenderID)
            }

            mutating func completeRender(_ id: RenderID, failure: RenderFailure?) -> Bool {
                guard id.load == currentLoadID,
                    id.render == currentRenderID,
                    loadStatus == .rendererReady(id.load),
                    inputStatus == .valid
                else { return false }
                state = failure.map(RenderState.failed) ?? .ready
                return true
            }

            mutating func contentProcessTerminated() {
                currentLoadID &+= 1
                invalidateRender()
                probingLoadID = nil
                loadStatus = .failed(.processTerminated)
                state = .failed(.processTerminated)
            }

            var canProbeRenderer: Bool {
                if case .navigationFinished(let loadID) = loadStatus {
                    return inputStatus == .valid && probingLoadID != loadID
                }
                return false
            }

            var canRender: Bool {
                if case .rendererReady(let loadID) = loadStatus {
                    return inputStatus == .valid && loadID == currentLoadID
                }
                return false
            }

            private mutating func invalidateRender() {
                currentRenderID &+= 1
            }

            private func stateForCurrentInput() -> RenderState {
                switch inputStatus {
                case .unknown, .valid:
                    if case .failed(let failure) = loadStatus { return .failed(failure) }
                    return .loading
                case .empty:
                    return .empty
                case .invalid:
                    return .failed(.invalidData)
                }
            }
        }

        @Published private(set) var state: RenderState = .loading
        @Published private(set) var points: [Point] = []
        @Published private(set) var height: CGFloat = 40
        @Published private(set) var contentHeight: CGFloat = 220

        private weak var webView: WKWebView?
        private var lifecycle = Lifecycle()
        private var inputStatus: Lifecycle.InputStatus = .unknown
        private var activeNavigation: WKNavigation?
        private var activeLoadID: UInt64?
        private var resourceURL: URL?
        private var dashboardJSON: String?
        private var dashboardSnapshotRevision: UInt64 = 0
        private var dashboardSnapshotIsValid = false
        private var transferredDashboardID: String?
        private var inFlightRenderID: Lifecycle.RenderID?
        private var renderPending = false
        private var resetAnnotations: [ResetAnnotation] = []
        private var language: WidgetLanguage = .zh
        private var chartFrom: String?
        private var chartTo: String?

        func permitsNavigation(_ url: URL?) -> Bool {
            guard let url, let resourceURL else { return false }
            return url.isFileURL && url.standardizedFileURL == resourceURL.standardizedFileURL
        }

        func update(
            dashboardJSON incoming: String, resetAnnotations: [ResetAnnotation], height incomingHeight: CGFloat,
            language: WidgetLanguage = .zh, from: String? = nil, to: String? = nil
        ) {
            let nextHeight = incomingHeight.isFinite ? min(600, max(24, incomingHeight)) : 260
            guard
                self.language != language || dashboardJSON != incoming || self.resetAnnotations != resetAnnotations
                    || height != nextHeight || chartFrom != from || chartTo != to
            else {
                return
            }
            if dashboardJSON != incoming {
                let data = incoming.data(using: .utf8)
                let object = data.flatMap { $0.count <= 16 * 1_024 * 1_024 ? (try? JSONSerialization.jsonObject(with: $0)) : nil } as? [String: Any]
                dashboardSnapshotIsValid = (object?["schemaVersion"] as? Int) == 1 && object?["payload"] is [String: Any]
                dashboardSnapshotRevision &+= 1
                transferredDashboardID = nil
            }
            // Match the validated public-announcement text bound; long lawful
            // announcements must not invalidate the independent usage snapshot.
            let valid =
                dashboardSnapshotIsValid
                && resetAnnotations.count <= 500 && resetAnnotations.allSatisfy { $0.text.utf8.count <= 16_384 }
            let nextStatus: Lifecycle.InputStatus = valid ? .valid : .invalid
            self.language = language
            dashboardJSON = incoming
            self.resetAnnotations = resetAnnotations
            chartFrom = from
            chartTo = to
            height = nextHeight
            inputStatus = nextStatus
            lifecycle.updateInput(nextStatus)
            publishLifecycleState()
            attemptRenderIfPossible()
        }

        nonisolated static let maximumRenderableToken = Double(Int64.max - 1_024)

        nonisolated static func sanitizedPoints(_ points: [Point]) -> [Point] {
            points.filter {
                !$0.date.isEmpty
                    && $0.tokens.isFinite
                    && $0.tokens >= 0
                    && $0.tokens <= maximumRenderableToken
            }
        }

        func attach(_ web: WKWebView) {
            if web !== webView { resetTransferredSnapshot() }
            webView = web
        }

        func receiveContentSize(body: Any, from web: WKWebView, isMainFrame: Bool, url: URL?) {
            guard dashboardJSON != nil, web === webView,
                isMainFrame, permitsNavigation(url),
                let body = body as? [String: Any],
                body["snapshotID"] as? String == "\(lifecycle.currentLoadID):\(dashboardSnapshotRevision)",
                let width = body["width"] as? Double, width.isFinite, abs(width - web.bounds.width) < 2,
                let value = body["height"] as? Double, value.isFinite, value > 0
            else { return }
            let measured = min(2_400, max(96, ceil(value)))
            if abs(contentHeight - measured) >= 1 { contentHeight = measured }
        }

        func isAttached(to web: WKWebView) -> Bool {
            web === webView
        }

        func update(points incoming: [Point], height incomingHeight: CGFloat) {
            let wasDashboard = dashboardJSON != nil
            dashboardJSON = nil
            dashboardSnapshotIsValid = false
            transferredDashboardID = nil
            resetAnnotations = []
            let filtered = Self.sanitizedPoints(incoming)
            let newInputStatus: Lifecycle.InputStatus = {
                if incoming.isEmpty { return .empty }
                return filtered.isEmpty ? .invalid : .valid
            }()
            let safeHeight: CGFloat = {
                guard incomingHeight.isFinite else { return 40 }
                return min(600, max(24, incomingHeight))
            }()
            let changed = wasDashboard || inputStatus != newInputStatus || points != filtered || height != safeHeight
            guard changed else { return }
            points = filtered
            height = safeHeight
            inputStatus = newInputStatus
            lifecycle.updateInput(newInputStatus)
            publishLifecycleState()
            attemptRenderIfPossible()
        }

        func loadIfNeeded(in web: WKWebView) {
            attach(web)
            guard
                let resourceURL = Bundle.main.url(
                    forResource: "standalone", withExtension: "html", subdirectory: "UpstreamCharts"
                )
            else {
                self.resourceURL = nil
                lifecycle.failWithoutNavigation(.resourceUnavailable)
                publishLifecycleState()
                return
            }
            self.resourceURL = resourceURL
            startLoad(in: web, resourceURL: resourceURL)
        }

        func retry() {
            guard inputStatus == .valid else {
                lifecycle.updateInput(inputStatus)
                publishLifecycleState()
                return
            }
            guard let webView else {
                lifecycle.failWithoutNavigation(.resourceUnavailable)
                publishLifecycleState()
                return
            }
            let resolvedResourceURL =
                resourceURL
                ?? Bundle.main.url(
                    forResource: "standalone", withExtension: "html", subdirectory: "UpstreamCharts"
                )
            guard let resolvedResourceURL else {
                lifecycle.failWithoutNavigation(.resourceUnavailable)
                publishLifecycleState()
                return
            }
            resourceURL = resolvedResourceURL
            startLoad(in: webView, resourceURL: resolvedResourceURL)
        }

        func didFinishLoading(_ web: WKWebView, navigation: WKNavigation?) {
            guard isAttached(to: web), isActive(navigation: navigation), let loadID = activeLoadID,
                lifecycle.finishNavigation(loadID: loadID)
            else { return }
            publishLifecycleState()
            probeRendererIfPossible(in: web)
        }

        func didFailNavigation(_ web: WKWebView, navigation: WKNavigation?) {
            guard isAttached(to: web), isActive(navigation: navigation), let loadID = activeLoadID,
                lifecycle.failNavigation(loadID: loadID)
            else { return }
            activeNavigation = nil
            activeLoadID = nil
            publishLifecycleState()
        }

        func didTerminateContentProcess(_ web: WKWebView) {
            guard web === webView else { return }
            attach(web)
            activeNavigation = nil
            activeLoadID = nil
            resetTransferredSnapshot()
            lifecycle.contentProcessTerminated()
            publishLifecycleState()
        }

        func render(in web: WKWebView) {
            guard web === webView, let renderID = lifecycle.beginRender() else { return }
            publishLifecycleState()
            // Keep only one script in flight. A later option/data update invalidates
            // its completion and renders the latest state after it finishes.
            guard inFlightRenderID == nil else {
                renderPending = true
                return
            }
            inFlightRenderID = renderID
            renderPending = false
            guard let annotationData = try? JSONEncoder().encode(resetAnnotations),
                let annotationObject = try? JSONSerialization.jsonObject(with: annotationData)
            else {
                inFlightRenderID = nil
                _ = lifecycle.completeRender(renderID, failure: .invalidData)
                publishLifecycleState()
                return
            }
            let width = web.bounds.width.isFinite && web.bounds.width > 0 ? min(4_096, web.bounds.width) : 650
            var options: [String: Any] = ["width": width, "height": height, "resetAnnotations": annotationObject, "language": language.rawValue]
            if let chartFrom { options["from"] = chartFrom }
            if let chartTo { options["to"] = chartTo }
            let snapshotID: String?
            let input: Any
            if let dashboardJSON {
                let id = "\(renderID.load):\(dashboardSnapshotRevision)"
                snapshotID = id
                options["snapshotID"] = id
                input = transferredDashboardID == id ? NSNull() : dashboardJSON
            } else if let pointData = try? JSONEncoder().encode(points),
                let pointObject = try? JSONSerialization.jsonObject(with: pointData)
            {
                snapshotID = nil
                input = pointObject
            } else {
                inFlightRenderID = nil
                _ = lifecycle.completeRender(renderID, failure: .invalidData)
                publishLifecycleState()
                return
            }
            web.callAsyncJavaScript(
                "return window.__renderTrend(input, options);",
                arguments: ["input": input, "options": options],
                in: nil, in: .page
            ) { [weak self, weak web] completion in
                let result: Any?
                let error: Error?
                switch completion {
                case .success(let value):
                    result = value
                    error = nil
                case .failure(let failure):
                    result = nil
                    error = failure
                }
                Task { @MainActor [weak self, weak web] in
                    guard let self, let web, web === self.webView, self.inFlightRenderID == renderID else { return }
                    self.inFlightRenderID = nil
                    let failure: RenderFailure? = {
                        if error != nil { return .scriptFailed }
                        return Self.renderResultIsValid(result) ? nil : .rendererReturnedNoOutput
                    }()
                    if failure == nil, let snapshotID, self.dashboardJSON != nil,
                        snapshotID == "\(self.lifecycle.currentLoadID):\(self.dashboardSnapshotRevision)"
                    {
                        self.transferredDashboardID = snapshotID
                    }
                    if self.lifecycle.completeRender(renderID, failure: failure) {
                        self.publishLifecycleState()
                    }
                    if self.renderPending {
                        self.renderPending = false
                        self.render(in: web)
                    }
                }
            }
        }

        private func resetTransferredSnapshot() {
            transferredDashboardID = nil
            inFlightRenderID = nil
            renderPending = false
        }

        private func startLoad(in web: WKWebView, resourceURL: URL) {
            resetTransferredSnapshot()
            let loadID = lifecycle.beginLoad()
            activeLoadID = loadID
            activeNavigation = web.loadFileURL(
                resourceURL,
                allowingReadAccessTo: resourceURL.deletingLastPathComponent()
            )
            if activeNavigation == nil {
                _ = lifecycle.failNavigation(loadID: loadID)
                activeLoadID = nil
            }
            publishLifecycleState()
        }

        private func isActive(navigation: WKNavigation?) -> Bool {
            guard let navigation, let activeNavigation else { return false }
            return navigation === activeNavigation
        }

        private func attemptRenderIfPossible() {
            guard let webView else { return }
            if lifecycle.canRender {
                render(in: webView)
            } else if lifecycle.canProbeRenderer {
                probeRendererIfPossible(in: webView)
            }
        }

        private func probeRendererIfPossible(in web: WKWebView) {
            guard web === webView, let loadID = lifecycle.beginRendererProbe() else { return }
            web.evaluateJavaScript("typeof window.__renderTrend === 'function'") { [weak self, weak web] result, error in
                Task { @MainActor [weak self, weak web] in
                    guard let self, let web, web === self.webView else { return }
                    let available = error == nil && Self.rendererFunctionIsAvailable(result)
                    let shouldRender = self.lifecycle.completeRendererProbe(
                        loadID: loadID,
                        available: available
                    )
                    self.publishLifecycleState()
                    if shouldRender { self.render(in: web) }
                }
            }
        }

        private func publishLifecycleState() {
            if state != lifecycle.state { state = lifecycle.state }
        }

        nonisolated static func renderResultIsValid(_ result: Any?) -> Bool {
            guard let string = result as? String else { return false }
            return string.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<svg")
        }

        nonisolated static func rendererFunctionIsAvailable(_ result: Any?) -> Bool {
            if let available = result as? Bool { return available }
            if let available = result as? NSNumber { return available.boolValue }
            if let available = result as? String { return available == "true" }
            return false
        }
    }
}

private extension UpstreamTrendView.Renderer {
    func captureScreenshot() async throws -> UpstreamTrendView.Screenshot {
        guard state == .ready, let web = webView, web.bounds.width > 0, web.bounds.height > 0 else {
            throw WorkspaceScreenshotExporter.unavailable("chart_not_ready")
        }
        let input = dashboardJSON
        let capturedPoints = points
        let revision = lifecycle
        let rect = web.bounds
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: configuration)
        guard web === webView, state == .ready, dashboardJSON == input, points == capturedPoints,
            lifecycle.currentLoadID == revision.currentLoadID, web.bounds == rect
        else { throw WorkspaceScreenshotExporter.unavailable("chart_changed_during_capture") }
        return UpstreamTrendView.Screenshot(image: image, dashboardJSON: input, points: capturedPoints)
    }
}

private extension UpstreamTrendView.RenderFailure {
    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .invalidData:
            return language.text("每日数据无效", "Daily usage data is invalid")
        case .resourceUnavailable:
            return language.text("图表资源不可用", "Chart resource unavailable")
        case .navigationFailed:
            return language.text("图表加载失败", "Chart load failed")
        case .rendererUnavailable:
            return language.text("图表渲染器不可用", "Chart renderer unavailable")
        case .rendererReturnedNoOutput:
            return language.text("图表没有返回结果", "Chart returned no output")
        case .scriptFailed:
            return language.text("图表脚本执行失败", "Chart script failed")
        case .processTerminated:
            return language.text("图表进程已结束", "Chart process ended")
        }
    }
}

@MainActor
private struct TrendWebView: NSViewRepresentable {
    let renderer: UpstreamTrendView.Renderer

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let renderer: UpstreamTrendView.Renderer

        init(renderer: UpstreamTrendView.Renderer) {
            self.renderer = renderer
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            Task { @MainActor in
                guard let web = message.webView else { return }
                renderer.receiveContentSize(body: message.body, from: web, isMainFrame: message.frameInfo.isMainFrame, url: message.frameInfo.request.url)
            }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            Task { @MainActor in
                decisionHandler(renderer.permitsNavigation(navigationAction.request.url) && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                renderer.didFinishLoading(webView, navigation: navigation)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                renderer.didFailNavigation(webView, navigation: navigation)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                renderer.didFailNavigation(webView, navigation: navigation)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor in
                renderer.didTerminateContentProcess(webView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    func makeNSView(context: Context) -> ResizeAwareTrendWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "chartSize")
        let web = ResizeAwareTrendWebView(frame: .zero, configuration: configuration)
        web.renderer = renderer
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.startScrollWheelForwarding()
        web.onSizeChange = { [weak renderer, weak web] in
            guard let renderer, let web else { return }
            Task { @MainActor in
                renderer.render(in: web)
            }
        }
        renderer.loadIfNeeded(in: web)
        return web
    }

    static func dismantleNSView(_ web: ResizeAwareTrendWebView, coordinator: Coordinator) {
        web.stopScrollWheelForwarding()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "chartSize")
        web.onSizeChange = nil
        web.navigationDelegate = nil
    }

    func updateNSView(_ web: ResizeAwareTrendWebView, context: Context) {
        web.renderer = renderer
        renderer.attach(web)
    }
}

@MainActor
final class ResizeAwareTrendWebView: WKWebView {
    weak var renderer: UpstreamTrendView.Renderer?
    var onSizeChange: (() -> Void)?
    var onScrollWheelForwardedForTest: (() -> Void)?
    private var previousSize: CGSize = .zero
    private var scrollWheelMonitor: Any?

    func startScrollWheelForwarding() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.contains(event: event), self.forwardScrollWheel(event) else { return event }
            return nil
        }
    }

    func stopScrollWheelForwarding() {
        if let scrollWheelMonitor {
            NSEvent.removeMonitor(scrollWheelMonitor)
            self.scrollWheelMonitor = nil
        }
    }

    func outerScrollViewForRegression() -> NSScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        // A direct responder callback is the fallback for events that bypass
        // the local monitor (for example, an AppKit responder-chain dispatch).
        // Do not call super: that would restore WKWebView's inner ownership.
        _ = forwardScrollWheel(event)
    }

    private func contains(event: NSEvent) -> Bool {
        containsScrollLocation(event.locationInWindow, in: event.window)
    }

    fileprivate func containsScrollLocation(_ location: NSPoint, in eventWindow: NSWindow?) -> Bool {
        guard let window, eventWindow === window, !isHiddenOrHasHiddenAncestor,
            visibleRect.contains(convert(location, from: nil)),
            let content = window.contentView,
            let target = content.hitTest(content.convert(location, from: nil))
        else { return false }
        // The monitor observes every window. Only intercept a hit on this
        // chart, not a covered/clipped chart or a different window's content.
        return target === self || target.isDescendant(of: self)
    }

    @discardableResult
    private func forwardScrollWheel(_ event: NSEvent) -> Bool {
        guard let outer = outerScrollViewForRegression() else { return false }
        onScrollWheelForwardedForTest?()
        outer.scrollWheel(with: event)
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = previousSize.width != newSize.width
        previousSize = newSize
        super.setFrameSize(newSize)
        if changed {
            onSizeChange?()
        }
    }
}

/// Executable geometry/ownership regression for the embedded chart. A real
/// synthetic wheel exercises the responder route; hosted AppKit geometry tests
/// the monitor's hit test without injecting any user input into the desktop.
@MainActor
enum UpstreamTrendWebViewScrollSelfTest {
    private final class RecordingScrollView: NSScrollView {
        private(set) var forwardedEvents = 0

        override func scrollWheel(with event: NSEvent) {
            forwardedEvents += 1
        }
    }

    static func run() -> Bool {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: .borderless, backing: .buffered, defer: false)
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer {
            window.close()
            other.close()
        }
        let outer = RecordingScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        window.contentView = outer
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 720))
        outer.documentView = host
        let web = ResizeAwareTrendWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 420), configuration: WKWebViewConfiguration())
        host.addSubview(web)
        outer.contentView.scroll(to: .zero)
        let visible = web.visibleRect
        guard !visible.isEmpty else { return false }
        let point = web.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        guard web.containsScrollLocation(point, in: window),
            !web.containsScrollLocation(point, in: other),
            !web.containsScrollLocation(point, in: nil)
        else { return false }
        let clipped = web.convert(NSPoint(x: 20, y: visible.maxY + 20), to: nil)
        guard !web.containsScrollLocation(clipped, in: window) else { return false }
        web.isHidden = true
        guard !web.containsScrollLocation(point, in: window) else { return false }
        web.isHidden = false
        let cover = NSView(frame: web.frame)
        host.addSubview(cover, positioned: .above, relativeTo: web)
        guard !web.containsScrollLocation(point, in: window) else { return false }
        cover.removeFromSuperview()
        let target = web.outerScrollViewForRegression()
        guard
            let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: 12, wheel2: 0, wheel3: 0),
            let event = NSEvent(cgEvent: cgEvent)
        else { return false }
        web.scrollWheel(with: event)
        let passed = target === outer && outer.forwardedEvents == 1
        web.removeFromSuperview()
        return passed
    }
}

private struct WorkspaceTrendScreenshotsKey: EnvironmentKey {
    static let defaultValue: UpstreamTrendView.ScreenshotContext? = nil
}

extension EnvironmentValues {
    var workspaceTrendScreenshots: UpstreamTrendView.ScreenshotContext? {
        get { self[WorkspaceTrendScreenshotsKey.self] }
        set { self[WorkspaceTrendScreenshotsKey.self] = newValue }
    }
}
