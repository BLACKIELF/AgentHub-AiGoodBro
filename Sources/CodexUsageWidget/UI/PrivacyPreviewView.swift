import AppKit
import SwiftUI

struct PrivacyPreviewView: View {
    let language: WidgetLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var result: PrivacyPreview.Result?
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(language.text("脱敏预览", "Privacy preview")).font(.headline)
                Spacer()
                Button(language.text("关闭", "Close")) {
                    clear()
                    dismiss()
                }
            }
            Text(
                language.text(
                    "在本机检查粘贴的文本，遮住可识别的密钥、邮箱和个人路径。此预览不自动过滤请求，也不能识别所有敏感信息；分享前请复核。",
                    "Check pasted text locally for recognizable keys, emails and personal paths. This preview does not filter requests or detect every secret; review it before sharing."
                )
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(language.text("待检查文本 · 最多 64 KiB", "Text to check · up to 64 KiB")).font(.subheadline)
            PrivacyInputEditor(text: $input) {
                issue = language.text("文本超过 64 KiB，请分段检查。", "Text exceeds 64 KiB. Check it in smaller parts.")
            }
            .frame(height: 150)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .accessibilityLabel(language.text("待检查文本", "Text to check"))
            HStack {
                Button(language.text("预览", "Preview"), action: preview)
                    .buttonStyle(.borderedProminent).disabled(input.isEmpty)
                Button(language.text("清空", "Clear"), action: clear).disabled(input.isEmpty && result == nil)
                Spacer()
                if let result {
                    Text(language.text("已替换 \(result.replacements) 处", "Replaced \(result.replacements) occurrences"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(language.text("复制预览", "Copy preview")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.text, forType: .string)
                    }
                }
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            if let result {
                ScrollView {
                    Text(result.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(minHeight: 120, maxHeight: 200)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            Text(language.text("原文仅保留在此窗口，关闭后清空。", "Input stays in this window and is cleared when it closes."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 640)
        .onChange(of: input) { _ in
            result = nil
            issue = nil
        }
        .onDisappear(perform: clear)
    }

    private func preview() {
        issue = nil
        result = nil
        do {
            result = try PrivacyPreview.preview(input)
        } catch PrivacyPreview.Failure.tooLarge {
            issue = language.text("文本超过 64 KiB，请分段检查。", "Text exceeds 64 KiB. Check it in smaller parts.")
        } catch PrivacyPreview.Failure.tooManyMatches {
            issue = language.text("匹配项过多，请分段检查。", "Too many matches. Check the text in smaller parts.")
        } catch {
            issue = language.text("本地预览不可用，未生成结果。", "Local preview is unavailable. No result was generated.")
        }
    }

    private func clear() {
        input = ""
        result = nil
        issue = nil
    }
}

private struct PrivacyInputEditor: NSViewRepresentable {
    @Binding var text: String
    let onLimit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.delegate = context.coordinator
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? NSTextView)?.string = ""
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: PrivacyInputEditor
        init(_ owner: PrivacyInputEditor) { self.owner = owner }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            owner.text = editor.string
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            let current = textView.string as NSString
            guard affectedCharRange.location != NSNotFound, NSMaxRange(affectedCharRange) <= current.length else { return false }
            let size = textView.string.utf8.count - current.substring(with: affectedCharRange).utf8.count + replacementString.utf8.count
            guard size <= PrivacyPreview.maximumInputBytes else {
                owner.onLimit()
                return false
            }
            return true
        }
    }
}
