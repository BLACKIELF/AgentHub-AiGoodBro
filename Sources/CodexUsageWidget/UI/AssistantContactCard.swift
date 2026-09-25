import Cocoa
import SwiftUI

enum AssistantContact {
    static let wechatID = "AiGoodBro"
    static let qrImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AiGoodBro-wechat", withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

struct AssistantContactCard: View {
    let language: WidgetLanguage
    var compact = false
    @State private var showsQRCode = false
    @State private var copySucceeded = false
    @State private var copyFailed = false
    @State private var copyRevision = 0

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                contactDetails.frame(minWidth: 175, maxWidth: .infinity, alignment: .leading)
                qrThumbnail
            }
            VStack(alignment: .leading, spacing: 16) {
                contactDetails
                qrThumbnail.frame(maxWidth: .infinity)
            }
        }
        .padding(compact ? 14 : 18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .sheet(isPresented: $showsQRCode) { qrSheet }
        .task(id: copyRevision) {
            guard copyRevision > 0 else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            copySucceeded = false
        }
    }

    private var contactDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(language.text("联系小助理", "Contact our assistant"), systemImage: "bubble.left.and.bubble.right")
                .font(.headline)
            Text(language.text("使用问题与反馈，欢迎通过微信联系。", "Questions or feedback? Get in touch on WeChat."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(language.text("微信号", "WeChat ID"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(AssistantContact.wechatID)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button {
                NSPasteboard.general.clearContents()
                copySucceeded = NSPasteboard.general.setString(AssistantContact.wechatID, forType: .string)
                copyFailed = !copySucceeded
                copyRevision += 1
            } label: {
                Label(
                    copySucceeded ? language.text("已复制", "Copied") : language.text("复制微信号", "Copy WeChat ID"),
                    systemImage: copySucceeded ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("about.assistant.copy")
            .help(language.text("复制 AiGoodBro，在微信中搜索添加好友", "Copy AiGoodBro and search for it in WeChat"))
            if copyFailed {
                Text(language.text("复制失败，请选择上方微信号手动复制。", "Copy failed. Select the ID above and copy it manually."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var qrThumbnail: some View {
        if let image = AssistantContact.qrImage {
            Button {
                showsQRCode = true
            } label: {
                VStack(spacing: 7) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: 160, height: 204)
                        .background(.white)
                    Text(language.text("点击放大二维码", "Enlarge QR code"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("放大小助理微信二维码", "Enlarge assistant's WeChat QR code"))
        } else {
            Text(language.text("二维码暂不可用，可复制微信号添加。", "QR code unavailable. Copy the WeChat ID instead."))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 160)
        }
    }

    private var qrSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text(language.text("小助理的微信", "Assistant on WeChat")).font(.headline)
                Spacer()
                Button {
                    showsQRCode = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(language.text("关闭二维码", "Close QR code"))
            }
            if let image = AssistantContact.qrImage {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: 320, height: 408)
                    .background(.white)
                    .accessibilityLabel(language.text("微信扫一扫，添加小助理", "Scan with WeChat to add our assistant"))
            }
            Text(language.text("微信号：AiGoodBro", "WeChat ID: AiGoodBro"))
                .font(.callout).textSelection(.enabled)
        }
        .padding(20)
        .frame(width: 360)
    }
}
