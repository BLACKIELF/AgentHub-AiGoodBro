import AppKit
import SwiftUI

/// Local, bundled recommendations. No remote execution or private source paths.
enum BundledSkill: String, CaseIterable, Identifiable {
    case oracle, handoff, quickToggle
    case typesafeAI = "typesafe-ai"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .oracle: "Oracle"
        case .handoff: "Handoff · 任务交接"
        case .typesafeAI: "TypeSafe AI · 类型化判断"
        case .quickToggle: "轻唤 · App"
        }
    }
    var symbol: String {
        switch self {
        case .oracle: "checkmark.bubble"
        case .handoff: "arrow.triangle.branch"
        case .typesafeAI: "checkmark.seal"
        case .quickToggle: "keyboard"
        }
    }
    func summary(_ language: WidgetLanguage) -> String {
        switch self {
        case .oracle:
            language.text("调用浏览器，请网页版 GPT 最好的模型复核或出方案", "Use the browser to ask the best available GPT model on the web for a review or plan")
        case .handoff:
            language.text("保存进度、证据与下一步，换任务也能接着做", "Preserve progress, evidence and next steps")
        case .typesafeAI:
            language.text("把自然语言判断变成带概率的类型化结果", "Turn language judgments into typed probabilistic results")
        case .quickToggle:
            language.text("给常用 App 设置快捷键，一键呼出与收起", "Set hotkeys to bring up and hide your favorite apps")
        }
    }

    private var installBoundary: String {
        switch self {
        case .oracle:
            "Oracle CLI 若未安装，只说明缺失与安装命令，等我确认。安装 Skill 本身不等于授权模型调用。"
        case .handoff:
            "只安装 Skill，不创建交接文件；后续保存或读取交接仍按具体任务授权。"
        case .typesafeAI:
            "只安装 Skill，不安装 SDK、不读取或保存 TYPESAFE_API_KEY，也不调用 TypeSafe API；接入与调用另行按具体任务确认。"
        case .quickToggle:
            "不修改现有快捷键，不绕过系统安全检查；需要权限时由我确认。"
        }
    }

    func directory(in bundle: Bundle = .main) -> URL? {
        guard self != .quickToggle else { return nil }
        guard let resources = bundle.resourceURL else { return nil }
        let url = resources.appendingPathComponent("SkillLibrary/\(rawValue)", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) ? url : nil
    }

    func installPrompt(directory: URL) -> String {
        "请读取 \(directory.path) 的 SKILL.md 和安装说明.md，将 \(rawValue) Skill 安装到当前 Codex 用户级 skills 目录；先检查重复项，相同则复用、有差异先问我，不修改认证或全局配置，不读取密钥、不调用模型或执行付费请求；\(installBoundary)"
    }

    var prompt: String? {
        if self == .quickToggle {
            return "请从 https://github.com/BLACKIELF/QuickToggle 的官方 Releases 为我的系统安装最新版轻唤 App；先检查已有安装，相同则复用、有差异先问我，不修改现有快捷键或绕过系统安全检查，完成后告诉我如何使用。"
        }
        return directory().map { installPrompt(directory: $0) }
    }

    static func codexURL(prompt: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "codex"
        parts.host = "threads"
        parts.path = "/new"
        parts.queryItems = [URLQueryItem(name: "prompt", value: prompt), URLQueryItem(name: "mode", value: "codex")]
        return parts.url
    }

    static func selfTest() -> Bool {
        let prompt = "安装 # & ? % 中文\n只安装选中项"
        guard let url = codexURL(prompt: prompt), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "codex", parts.host == "threads", parts.path == "/new",
            parts.queryItems == [URLQueryItem(name: "prompt", value: prompt), URLQueryItem(name: "mode", value: "codex")]
        else { return false }
        for skill in allCases {
            if skill == .quickToggle {
                guard let prompt = skill.prompt, prompt.contains("https://github.com/BLACKIELF/QuickToggle"), !prompt.contains("/Users/") else { return false }
                continue
            }
            guard let directory = skill.directory(),
                let text = try? String(contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8),
                text.contains("name: \(skill.rawValue)"), !text.contains("/Users/"),
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("安装说明.md").path)
            else { return false }
        }
        return true
    }
}

struct HomeSkillShelf: View {
    let language: WidgetLanguage
    @State private var selected: BundledSkill?
    @AppStorage(HomeSection.recommendations.storageKey) private var isExpanded = true
    static let quickToggleURL = URL(string: "https://github.com/BLACKIELF/QuickToggle/releases")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HomeSectionToggle(
                    title: language.text("推荐 Skills 与应用", "Recommended skills and apps"),
                    systemImage: "square.stack.3d.up", language: language, isExpanded: $isExpanded
                )
                .font(.subheadline.weight(.semibold))
                Text(language.text("精选工具 · 按需安装", "Selected tools · install as needed"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if isExpanded {
                ViewThatFits(in: .horizontal) {
                    recommendationGrid(columns: 4).frame(minWidth: 996)
                    recommendationGrid(columns: 2).frame(minWidth: 492)
                    recommendationGrid(columns: 1)
                }
            }
        }
        .sheet(item: $selected) { skill in SkillInstallSheet(skill: skill, language: language) }
    }

    private func recommendationGrid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 10) {
            ForEach(BundledSkill.allCases) { skill in
                Button {
                    selected = skill
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: skill.symbol).foregroundStyle(.tint).font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.title).font(.callout.weight(.semibold))
                            Text(skill.summary(language)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("查看 \(skill.title) 安装指令", "View \(skill.title) installation instructions"))
            }
        }
    }
}

private struct SkillInstallSheet: View {
    let skill: BundledSkill
    let language: WidgetLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(skill.title).font(.title3.weight(.semibold))
                Spacer()
                Button(language.text("关闭", "Close")) { dismiss() }
            }
            Text(language.text("以下指令会交给 Codex。先检查重复项，不会静默覆盖；模型调用另行确认。", "Codex will check for existing skills first. No silent overwrite or model calls."))
                .font(.callout).foregroundStyle(.secondary)
            if let prompt = skill.prompt {
                ScrollView {
                    Text(verbatim: prompt).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120).padding(12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button(language.text("复制安装指令", "Copy instructions")) {
                        copy(prompt)
                        status = language.text("已复制，可粘贴到 Codex。", "Copied. Paste into Codex.")
                    }
                    if let directory = skill.directory() {
                        Button(language.text("查看安装包", "Show package")) {
                            NSWorkspace.shared.activateFileViewerSelecting([directory])
                        }
                    } else {
                        Link(language.text("查看项目", "View project"), destination: HomeSkillShelf.quickToggleURL)
                    }
                    Spacer()
                    Button(language.text("前往 Codex 安装", "Install with Codex")) {
                        copy(prompt)
                        guard let url = BundledSkill.codexURL(prompt: prompt),
                            NSWorkspace.shared.urlForApplication(toOpen: url) != nil,
                            NSWorkspace.shared.open(url)
                        else {
                            status = language.text("未找到可打开链接的 Codex。指令已复制，请手动打开 Codex 后粘贴。", "Codex link handler unavailable. Instructions copied; open Codex and paste them.")
                            return
                        }
                        status = language.text("已请求打开 Codex，安装指令也已复制；请在 Codex 中查看并确认。", "Requested Codex to open; instructions also copied. Review and confirm in Codex.")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text(language.text("安装包缺失，请重新安装完整的 AiGoodBro；未执行任何安装。", "Bundled package missing. Reinstall the complete AiGoodBro app; nothing was installed."))
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(22).frame(width: 610)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
