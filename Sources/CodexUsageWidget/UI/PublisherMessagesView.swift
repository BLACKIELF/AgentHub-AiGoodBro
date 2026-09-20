import SwiftUI

struct PublisherMessagesView: View {
    @ObservedObject var monitor: PublisherMessageMonitor
    let language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(language.text("AiGoodBro 消息", "AiGoodBro messages")).font(.caption.weight(.semibold))
                Spacer()
                Toggle(language.text("通知新消息", "Notify me"), isOn: $monitor.notificationsEnabled)
                    .toggleStyle(.checkbox).font(.caption)
                    .help(language.text("默认关闭；开启后仅提醒新消息，还需开启应用的系统通知并获得 macOS 权限。", "Off by default. New messages only; app and macOS notification permission are also required."))
                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).disabled(monitor.checking)
                .accessibilityLabel(language.text("刷新 AiGoodBro 消息", "Refresh AiGoodBro messages"))
                .help(monitor.checking ? language.text("检查中…", "Checking…") : monitor.status ?? language.text("刷新", "Refresh"))
            }
            if monitor.messages.isEmpty {
                Text(monitor.status ?? language.text("暂无已发布消息", "No published messages"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            ForEach(monitor.messages) { message in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(verbatim: message.title).font(.caption.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text(PublicResetAnnouncementPresentation.compactEventTime(message.publishedAt, language: language))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(verbatim: message.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let url = message.url {
                        Link(language.text("查看详情", "View details"), destination: url).font(.caption2)
                    }
                }
            }
        }
    }
}
