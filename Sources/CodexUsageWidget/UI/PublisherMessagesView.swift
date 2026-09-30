import SwiftUI

struct PublisherMessagesView: View {
    @ObservedObject var monitor: PublisherMessageMonitor
    let language: WidgetLanguage
    @AppStorage(HomeSection.messages.storageKey) private var isExpanded = true
    @StateObject private var composer: PublisherMessageComposer
    @State private var showsComposer = false
    @State private var selectedMessage: PublisherMessage?

    init(monitor: PublisherMessageMonitor, language: WidgetLanguage) {
        self.monitor = monitor
        self.language = language
        _composer = StateObject(wrappedValue: PublisherMessageComposer(preview: monitor.isPreview))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HomeSectionToggle(title: language.text("AiGoodBro 官方消息", "AiGoodBro official updates"), language: language, isExpanded: $isExpanded)
                    .font(.caption.weight(.semibold))
                if !monitor.isPreview && composer.configured {
                    Button {
                        showsComposer = true
                        Task { await composer.checkAccess() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("发布消息", "Publish message"))
                    .help(language.text("维护者发布入口", "Maintainer publishing"))
                }
                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).disabled(monitor.checking)
                .accessibilityLabel(language.text("刷新 AiGoodBro 消息", "Refresh AiGoodBro messages"))
                .help(monitor.checking ? language.text("检查中…", "Checking…") : monitor.status ?? language.text("刷新", "Refresh"))
            }
            if isExpanded {
                if monitor.messages.isEmpty {
                    Text(monitor.status ?? language.text("暂无已发布消息", "No published messages"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(monitor.messages) { message in
                    Button {
                        selectedMessage = message
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(verbatim: message.title).font(.caption.weight(.semibold)).lineLimit(2)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(verbatim: message.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(PublicResetAnnouncementPresentation.compactEventTime(message.publishedAt, language: language))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(FixedVisualPalette.surfaceMutedFill, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(language.text("打开完整消息", "Open the full update"))
                }
            }
        }
        .sheet(isPresented: $showsComposer) { publisherSheet }
        .sheet(item: $selectedMessage) { message in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(language.text("AiGoodBro 官方消息", "AiGoodBro official update"), systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button(language.text("关闭", "Close")) { selectedMessage = nil }.keyboardShortcut(.cancelAction)
                }
                Text(verbatim: message.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(PublicResetAnnouncementPresentation.compactEventTime(message.publishedAt, language: language))
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(verbatim: message.body).font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let url = message.url {
                    Link(destination: url) {
                        Label(language.text("打开详情链接", "Open details link"), systemImage: "arrow.up.right")
                    }
                }
            }
            .padding(20).frame(width: 540, height: 360)
            .background(WorkspaceGlassBackdrop())
        }
    }

    private var publisherSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(language.text("发布 AiGoodBro 消息", "Publish AiGoodBro message")).font(.headline)
                Spacer()
                Text("BLACKIELF").font(.caption).foregroundStyle(.secondary)
                Button(language.text("关闭", "Close")) { showsComposer = false }.disabled(composer.busy)
            }
            Text(language.text("消息公开发布，在线新版客户端会在下次检查时自动接收。", "Messages are public. Online updated clients receive them at their next check."))
                .font(.caption).foregroundStyle(.secondary)
            TextField(language.text("标题", "Title"), text: $composer.title).textFieldStyle(.roundedBorder)
                .disabled(composer.busy || composer.pending != nil)
            TextEditor(text: $composer.body).font(.body).frame(height: 150)
                .disabled(composer.busy || composer.pending != nil)
                .accessibilityLabel(language.text("消息正文", "Message"))
            TextField(language.text("详情网址（选填）", "Details URL (optional)"), text: $composer.link).textFieldStyle(.roundedBorder)
                .disabled(composer.busy || composer.pending != nil)
            Text(
                language.text(
                    "保留 30 天 · 标题 \(composer.title.utf8.count)/240 · 正文 \(composer.body.utf8.count)/2000 字节",
                    "Kept 30 days · Title \(composer.title.utf8.count)/240 · Message \(composer.body.utf8.count)/2000 bytes")
            )
            .font(.caption2).foregroundStyle(.secondary)
            if let status = composer.status { Text(status).font(.caption).textSelection(.enabled) }
            HStack {
                if composer.busy { ProgressView().controlSize(.small) }
                if !composer.authorized && !composer.busy {
                    Button(language.text("重新核验身份", "Verify identity")) { Task { await composer.checkAccess() } }
                }
                Spacer()
                if composer.published { Link(language.text("查看已发布消息", "View published messages"), destination: PublisherMessagePublishing.pageURL) }
                Button(language.text(composer.pending == nil ? "发布给所有用户" : "核对并完成发布", composer.pending == nil ? "Publish to all users" : "Verify and finish publishing")) {
                    Task {
                        await composer.publish()
                        if composer.published { monitor.refresh() }
                    }
                }
                .buttonStyle(.borderedProminent).disabled(!composer.canPublish)
            }
        }
        .padding(20).frame(width: 570)
        .background(WorkspaceGlassBackdrop())
        .interactiveDismissDisabled(composer.busy)
    }
}
