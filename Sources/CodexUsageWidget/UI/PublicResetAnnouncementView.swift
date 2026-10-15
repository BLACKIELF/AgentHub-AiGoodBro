import SwiftUI

struct PublicResetAnnouncementView: View {
    @Environment(\.widgetLanguage) private var language
    @ObservedObject var monitor: PublicResetAnnouncementMonitor
    let paused: Bool
    var deliveryDetailsOnly = false
    @State private var isResolvingDelivery = false
    @State private var resolvingID = ""
    @State private var isEstablishingBaseline = false
    @State private var isEstablishingLocalBaseline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !deliveryDetailsOnly {
                HStack(spacing: 8) {
                    Label(PublicResetAnnouncementPresentation.title(language), systemImage: "megaphone.fill")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        monitor.check()
                    } label: {
                        Label(
                            monitor.checking ? language.text("更新中…", "Checking…") : language.text("刷新", "Refresh"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(monitor.checking)
                    .fixedSize(horizontal: true, vertical: true)
                }
                Toggle(
                    language.text("接收额度重置公告", "Receive quota reset announcements"),
                    isOn: Binding(get: { monitor.enabled }, set: { monitor.setEnabled($0) })
                )
                .toggleStyle(.switch)
                .disabled(paused)
                Text(
                    language.text(
                        "默认开启。有新消息时自动提醒，不消耗账号额度。",
                        "On by default. New updates are checked automatically and use no account quota."
                    )
                )
                .font(.caption).foregroundStyle(.secondary)
                if let announcement = monitor.latest {
                    Text(announcement.title(language))
                        .font(.caption.weight(.semibold))
                    PublicResetTranslatedText(eventID: announcement.id, original: announcement.text, language: language, compact: false)
                    Text(
                        language.text("事件时间：", "Event time: ")
                            + PublicResetAnnouncementPresentation.eventTime(announcement.announcedAt, language: language)
                            + " · "
                            + PublicResetAnnouncementPresentation.sourceLabel(announcement.source, language: language)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(announcement.meaning(language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PublicResetAnnouncementLinks(source: announcement.source, language: language)
                    Text(MessageNoticeFormat.footer).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Link(language.text("查看公开记录", "Browse public history"), destination: PublicResetClient.siteURL)
                        .font(.caption)
                }
                HStack {
                    if let checkedAt = monitor.checkedAt {
                        Text(language.text("上次检查：", "Last checked: ") + PublicResetAnnouncementPresentation.eventTime(checkedAt, language: language))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if monitor.needsLocalBaseline {
                    Button(language.text("从当前消息继续接收", "Resume from current updates")) { isEstablishingLocalBaseline = true }
                        .disabled(monitor.checking || !monitor.enabled)
                }
            } else {
                if monitor.missingDeliveryCount > 0 {
                    Text(
                        language.text(
                            "有 \(monitor.missingDeliveryCount) 条旧记录需要恢复，已保存的完整消息会继续处理。",
                            "Recovering \(monitor.missingDeliveryCount) older records. Complete saved updates continue to be processed.")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if monitor.needsNewBaseline {
                    Button(language.text("重新建立公告基线", "Establish a new baseline")) { isEstablishingBaseline = true }
                        .disabled(monitor.checking || !monitor.enabled)
                }
                ForEach(monitor.uncertainDeliveryIDs, id: \.self) { id in
                    Button(language.text("核实待确认推送：", "Verify delivery: ") + id) {
                        resolvingID = id
                        isResolvingDelivery = true
                    }
                    .disabled(monitor.checking)
                }
            }
            ForEach(PublicResetAnnouncementPresentation.visibleStatuses(local: monitor.localStatus, general: monitor.status), id: \.self) { status in
                Text(verbatim: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .alert(language.text("请先核对飞书中的重置公告", "Check the reset announcement in Feishu first"), isPresented: $isResolvingDelivery) {
            Button(language.text("已收到", "Received")) { monitor.resolveUncertainDelivery(id: resolvingID, received: true) }
            Button(language.text("未收到，允许重试", "Not received; allow retry")) { monitor.resolveUncertainDelivery(id: resolvingID, received: false) }
            Button(language.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                language.text(
                    "公告 ID：\(resolvingID)。只有确认未收到时才允许重试；重试可能造成重复消息。", "Announcement ID: \(resolvingID). Allow retry only if it did not arrive. Retrying can produce a duplicate."))
        }
        .alert(language.text("从当前公告重新开始跟踪？", "Track announcements from the current page?"), isPresented: $isEstablishingBaseline) {
            Button(language.text("建立基线", "Establish baseline")) { monitor.establishNewBaseline() }
            Button(language.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                language.text(
                    "保留已保存的待发与待核实公告；当前页其余历史消息不补发。", "Saved pending and uncertain deliveries are preserved. Other historical announcements on the current page will not be sent."))
        }
        .alert(language.text("从当前消息继续接收？", "Resume from current updates?"), isPresented: $isEstablishingLocalBaseline) {
            Button(language.text("继续接收", "Resume updates")) { monitor.establishNewBaseline(local: true) }
            Button(language.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                language.text(
                    "保留已保存的待发与待核实消息。当前历史仅作为起点，不补发；之后的新消息恢复提醒。",
                    "Saved pending and uncertain updates are preserved. Current history becomes the baseline without being resent; future updates resume notifications."))
        }
    }
}

#if canImport(Translation) && compiler(>=6.0)
    import Translation
#endif

/// Identity resets the view's request owner when either ID or exact bytes change.
@MainActor
struct PublicResetTranslatedText: View {
    let eventID: String
    let original: String
    let language: WidgetLanguage
    let compact: Bool

    var body: some View {
        PublicResetTranslationContent(
            key: .init(eventID: eventID, original: original), original: original,
            language: language, compact: compact
        )
        .id(PublicResetTranslationModel.Key(eventID: eventID, original: original))
    }
}

@MainActor
private struct PublicResetTranslationContent: View {
    let key: PublicResetTranslationModel.Key
    let original: String
    let language: WidgetLanguage
    let compact: Bool
    @ObservedObject private var store = PublicResetTranslationStore.shared
    @State private var request: PublicResetTranslationModel.Request?

    private var supported: Bool {
        #if canImport(Translation) && compiler(>=6.0)
            if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AnnouncementOriginalText(text: original, language: language, compact: compact)
            switch store.model.state(for: key, original: original) {
            case .notRequested:
                Button(language.text("翻译为简体中文", "Translate to Simplified Chinese")) { start(resources: .requiresDownload, userInitiated: true) }
            case .downloadRequired:
                Text(language.text("需下载中英文语言包；原文可直接阅读。", "English and Simplified Chinese language downloads are required; the original is available."))
                Button(language.text("下载语言包并翻译", "Download languages and translate")) { start(resources: .requiresDownload, userInitiated: true) }
            case .preparing:
                Text(language.text("正在准备系统翻译…", "Preparing system translation…"))
            case .translating:
                Text(language.text("系统翻译中…", "Translating with macOS…"))
            case .translated(let text, let vetted):
                if !compact {
                    Text(vetted ? language.text("已核对译文", "Vetted translation") : language.text("系统翻译 · 简体中文", "System translation · Simplified Chinese"))
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: PublicResetAnnouncementPresentation.readableText(text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            case .unavailable:
                Text(language.text("系统翻译暂不可用；请阅读原文。", "System translation unavailable; read the original."))
                if supported {
                    Button(language.text("重试翻译", "Retry translation")) { start(resources: .requiresDownload, userInitiated: true) }
                } else {
                    Text(language.text("需要 macOS 15 或更新版本及支持翻译的构建。", "Requires macOS 15 or later and a translation-enabled build."))
                }
            }
            #if canImport(Translation) && compiler(>=6.0)
                if #available(macOS 15.0, *), let request, store.model.owns(request) {
                    PublicResetNativeTranslation(request: request, store: store)
                        .id(request.generation)
                }
            #endif
        }
        .font(.caption)
        .task {
            await startAutomatically()
        }
        .onDisappear {
            if let request { store.model.cancel(request) }
            request = nil
        }
    }

    private var mayStartAutomatically: Bool {
        switch store.model.state(for: key, original: original) {
        case .notRequested, .downloadRequired: return true
        default: return false
        }
    }

    private func startAutomatically() async {
        guard mayStartAutomatically else { return }
        var resources: PublicResetTranslationModel.LanguageResources = .unsupported
        #if canImport(Translation) && compiler(>=6.0)
            if #available(macOS 15.0, *) {
                let status = await LanguageAvailability().status(
                    from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans")
                )
                switch status {
                case .installed: resources = .installed
                case .supported: resources = .requiresDownload
                case .unsupported: resources = .unsupported
                @unknown default: resources = .unsupported
                }
            }
        #endif
        guard !Task.isCancelled, mayStartAutomatically else { return }
        start(resources: resources)
    }

    private func start(resources: PublicResetTranslationModel.LanguageResources, userInitiated: Bool = false) {
        if let next = store.model.begin(key: key, original: original, resources: supported ? resources : .unsupported, userInitiated: userInitiated) {
            request = next
        }
    }
}

#if canImport(Translation) && compiler(>=6.0)
    @available(macOS 15.0, *)
    @MainActor
    private struct PublicResetNativeTranslation: View {
        let request: PublicResetTranslationModel.Request
        let store: PublicResetTranslationStore
        // A fresh view per generation creates a fresh configuration/task on retry.
        @State private var configuration: TranslationSession.Configuration? = .init(
            source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans")
        )

        var body: some View {
            Color.clear.frame(width: 0, height: 0)
                .translationTask(configuration) { session in
                    await run(session)
                }
                .onDisappear { store.model.cancel(request) }
        }

        private func run(_ session: TranslationSession) async {
            guard store.model.owns(request) else { return }
            defer { store.model.cancel(request) }
            do {
                let status = await LanguageAvailability().status(
                    from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans")
                )
                try Task.checkCancellation()
                guard status != .unsupported, store.model.owns(request) else { return }
                guard status == .installed || request.allowsResourcePreparation else {
                    store.model.requireDownload(request)
                    return
                }
                if request.allowsResourcePreparation {
                    try await session.prepareTranslation()
                }
                try Task.checkCancellation()
                guard store.model.owns(request) else { return }
                store.model.prepared(request)
                let response = try await session.translate(request.original)
                try Task.checkCancellation()
                store.model.finish(request, source: response.sourceText, translation: response.targetText)
            } catch {
                // No raw errors, paths or payloads are exposed to UI or logs.
                store.model.cancel(request)
            }
        }
    }
#endif
