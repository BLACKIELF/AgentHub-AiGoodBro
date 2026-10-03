import AppKit
import CoreImage
import SwiftUI

/// Login and test are explicit actions. The QR stays in memory only and is
/// generated with Core Image; no remote QR renderer or additional runtime.
struct PersonalWeChatSettingsView: View {
    @Binding var enabled: Bool
    @Binding var pairingCode: String
    let connected: Bool
    let hasContext: Bool
    let connecting: Bool
    let qrContent: String?
    let needsCode: Bool
    let disabled: Bool
    let onConnect: () -> Void
    let onCancel: () -> Void
    let onSubmitCode: (String) -> Void
    let onTest: () -> Void
    var needsAuthorization = false
    var bindingMissing = false
    var restoring = false
    var connectionStatus: String? = nil
    var onRestore: (() -> Void)? = nil
    @Environment(\.widgetLanguage) private var language

    var body: some View {
        Toggle(language.text("启用个人微信推送", "Enable personal WeChat notifications"), isOn: $enabled)
            .disabled(disabled)
        Label(statusLabel, systemImage: connected ? "checkmark.circle.fill" : "qrcode")
            .foregroundStyle(connected ? Color.green : Color.secondary)
        if enabled && connected && !hasContext {
            Text(
                language.text(
                    "在微信里给刚绑定的机器人发一句话，随后即可测试推送。",
                    "Send a message in WeChat to the bot you just paired, then test a notification.")
            )
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        if enabled, let connectionStatus {
            Text(connectionStatus).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 12) {
            if !connected, !bindingMissing, let onRestore {
                Button(language.text("恢复连接", "Restore connection"), action: onRestore)
                    .disabled(disabled || !enabled || connecting || restoring)
                    .accessibilityIdentifier("wechat-restore-connection")
            }
            Button(language.text(connected ? "重新扫码" : "扫码连接微信", connected ? "Scan again" : "Connect with QR"), action: onConnect)
                .disabled(disabled || !enabled || connecting)
            Button(language.text("发送测试消息", "Send test message"), action: onTest)
                .disabled(disabled || !enabled || !hasContext || connecting)
            if restoring { ProgressView().controlSize(.small) }
            if connecting {
                Button(language.text("取消扫码", "Cancel"), action: onCancel).disabled(disabled)
            }
        }
        if connecting {
            VStack(spacing: 10) {
                if let qrContent, let qr = Self.qrImage(qrContent) {
                    Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 210, height: 210).padding(12).background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel(language.text("微信连接二维码", "WeChat connection QR"))
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(language.text("用手机微信扫一扫，并在手机上确认。", "Scan with WeChat on your phone and confirm."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        if needsCode {
            HStack {
                SecureField(language.text("手机显示的配对码", "Pairing code shown on your phone"), text: $pairingCode)
                    .frame(maxWidth: 220)
                Button(language.text("确认配对码", "Confirm pairing code")) {
                    onSubmitCode(pairingCode)
                    pairingCode = ""
                }.disabled(disabled || pairingCode.range(of: "^[0-9]{4,10}$", options: .regularExpression) == nil)
            }
        }
        Text(
            language.text(
                "通知只发给扫码绑定的微信。成功表示微信接口已接受消息，请在手机上核对收到的内容。",
                "Notifications go only to the WeChat user who scanned. Success means the API accepted the message; check receipt on your phone.")
        )
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var statusLabel: String {
        if restoring { return language.text("正在恢复已保存的微信连接", "Restoring saved WeChat connection") }
        if connecting { return language.text("正在等待扫码确认", "Waiting for QR confirmation") }
        if connected { return language.text(hasContext ? "微信已连接，可以测试推送" : "微信已连接，等待会话", hasContext ? "Connected · ready to test" : "Connected · waiting for conversation") }
        if !enabled { return language.text("推送已关闭", "Notifications disabled") }
        if needsAuthorization { return language.text("微信连接需要授权", "WeChat needs authorization") }
        if bindingMissing { return language.text("尚未保存微信连接，请扫码", "No saved WeChat connection; scan to connect") }
        return language.text("微信连接未恢复", "WeChat connection needs restoring")
    }

    static func qrImage(_ content: String) -> NSImage? {
        guard !content.isEmpty, content.utf8.count <= 4096,
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
            let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
