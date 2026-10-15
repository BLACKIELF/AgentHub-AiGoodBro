import AppKit
import SwiftUI

/// Local, bundled recommendations. No remote execution or private source paths.
enum BundledSkill: String, CaseIterable, Identifiable {
    case oracle, handoff
    case jev = "jev-use"
    case quickToggle = "quicktoggle"
    case rea, aihot

    var id: String { rawValue }
    private var entry: RecommendationCatalog.Entry? { RecommendationCatalog.bundled.entry(id) }
    var title: String { title(.storedOrAutomatic()) }
    func title(_ language: WidgetLanguage) -> String {
        entry.map { language.text($0.title.zh, $0.title.en) } ?? rawValue
    }
    var symbol: String { entry?.symbol ?? "square.stack" }
    var isApp: Bool { entry?.kind == "app" }
    var projectURL: URL? { entry.flatMap { URL(string: $0.sourceURL) } }
    func summary(_ language: WidgetLanguage) -> String {
        entry.map { language.text($0.summary.zh, $0.summary.en) } ?? ""
    }

    func purpose(_ language: WidgetLanguage) -> String {
        entry.map { language.text($0.purpose.zh, $0.purpose.en) } ?? ""
    }

    private var installBoundary: String {
        switch self {
        case .oracle:
            "Oracle CLI 若未安装，只说明缺失与安装命令，等我确认。安装 Skill 本身不等于授权模型调用。"
        case .handoff:
            "只安装 Skill，不创建交接文件；后续保存或读取交接仍按具体任务授权。"
        case .jev:
            "识别已有 jev-use／jev-cu 并优先复用。Skill 依赖持久保存的公开 Jev-cu runner；先复用或获取经核验的仓库，再仅在新安装副本中解析 {{REPO_DIR}}，不运行会先删除同名目录的 installer，不调用 Jev API。"
        case .rea:
            "只安装官方 Skill 与引用，不捆绑或安装引擎。复用已有 rea 6.4.0 与已连接工具；本次不写 MCP 登记、认证或全局运行配置，不获取不相关依赖，缺失能力如实说明。"
        case .quickToggle:
            "不修改现有快捷键，不绕过系统安全检查；需要权限时由我确认。"
        case .aihot:
            "只介绍官方项目，不安装、部署或接入模型 API。"
        }
    }

    func directory(in bundle: Bundle = .main) -> URL? {
        guard let name = entry?.skillDirectory else { return nil }
        guard let resources = bundle.resourceURL else { return nil }
        let url = resources.appendingPathComponent("SkillLibrary/\(name)", isDirectory: true)
        let complete = ["SKILL.md", "安装说明.md"].allSatisfy { name in
            let file = url.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                FileManager.default.isReadableFile(atPath: file.path),
                let content = try? Data(contentsOf: file), !content.isEmpty
            else { return false }
            return true
        }
        return complete ? url : nil
    }

    func installPrompt(directory: URL) -> String {
        "请读取 \(directory.path) 的 SKILL.md 和安装说明.md，按说明准备当前 Codex 用户级 Skill；先检查同名和近似项，已有可用安装优先复用，只在不同目标、身份或覆盖影响不明时询问，不静默覆盖。不修改认证或全局配置，不读取密钥、不调用模型或执行付费请求；\(installBoundary)"
    }

    var prompt: String? {
        guard self != .aihot else { return nil }
        if self == .quickToggle {
            guard let source = entry?.sourceURL else { return nil }
            return "请从 \(source) 的官方 Releases 为我的系统安装兼容的轻唤 App；先检查已有安装，有可用安装则复用，覆盖影响不明时说明，不修改现有快捷键或绕过系统安全检查，完成后告诉我如何使用。"
        }
        return directory().map { installPrompt(directory: $0) }
    }

    @MainActor static var installationProbes: [RecommendationVisibilityStore.Probe] {
        RecommendationCatalog.bundled.items.map {
            .init(id: $0.id, skillNames: $0.skillNames, appBundleIDs: $0.appBundleIDs)
        }
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
        guard RecommendationCatalog.bundled.items.map(\.id) == allCases.map(\.id),
            BundledRecommendationFilter.all.items.count == 6,
            BundledRecommendationFilter.skills.items.count == 4,
            BundledRecommendationFilter.apps.items == [.quickToggle, .aihot]
        else { return false }
        for skill in allCases {
            if skill == .aihot {
                guard skill.prompt == nil, skill.directory() == nil,
                    skill.projectURL?.absoluteString == "https://github.com/KKKKhazix/AIHOT"
                else { return false }
                continue
            }
            if skill == .quickToggle {
                guard let prompt = skill.prompt, prompt.contains("https://github.com/BLACKIELF/QuickToggle"), !prompt.contains("/Users/") else { return false }
                continue
            }
            guard let directory = skill.directory(),
                let text = try? String(contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8),
                text.contains("name: \(skill.entry?.skillDirectory ?? "")"), !text.contains("/Users/"),
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("安装说明.md").path)
            else { return false }
        }
        return true
    }
}

enum BundledRecommendationFilter: String, CaseIterable {
    case all, skills, apps

    var items: [BundledSkill] {
        RecommendationCatalog.bundled.items.compactMap { BundledSkill(rawValue: $0.id) }.filter {
            switch self {
            case .all: true
            case .skills: !$0.isApp
            case .apps: $0.isApp
            }
        }
    }

    func label(_ language: WidgetLanguage) -> String {
        switch self {
        case .all: language.text("全部", "All")
        case .skills: "Skills"
        case .apps: language.text("应用", "Apps")
        }
    }
}

struct HomeSkillShelf: View {
    let language: WidgetLanguage
    @ObservedObject private var visibility: RecommendationVisibilityStore
    @State private var selected: BundledSkill?
    @State private var filter: BundledRecommendationFilter = .all
    @AppStorage(HomeSection.recommendations.storageKey) private var isExpanded = true
    static let quickToggleURL = URL(string: "https://github.com/BLACKIELF/QuickToggle/releases")!

    @MainActor init(language: WidgetLanguage) {
        self.init(language: language, visibility: .shared)
    }

    @MainActor init(language: WidgetLanguage, visibility: RecommendationVisibilityStore) {
        self.language = language
        _visibility = ObservedObject(wrappedValue: visibility)
    }

    private var visibleItems: [BundledSkill] { filter.items.filter { visibility.visible($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HomeSectionToggle(
                title: language.text("推荐 Skills 与应用", "Recommended skills and apps"),
                systemImage: "square.stack.3d.up", language: language, isExpanded: $isExpanded
            ).font(.subheadline.weight(.semibold))
            if isExpanded {
                HStack(spacing: 8) {
                    Picker(language.text("类别", "Category"), selection: $filter) {
                        ForEach(BundledRecommendationFilter.allCases, id: \.self) { value in
                            Text(value.label(language)).tag(value)
                        }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 210)
                    Spacer(minLength: 0)
                    Text(language.text("\(visibleItems.count) 项 · 按需使用", "\(visibleItems.count) items · optional"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Menu {
                        Button(language.text("重新检查安装", "Recheck installations")) {
                            Task { await visibility.recheck(probes: BundledSkill.installationProbes) }
                        }.disabled(visibility.isInspecting)
                        Button(language.text("恢复隐藏推荐", "Restore hidden recommendations")) {
                            visibility.restoreHidden()
                        }.disabled(visibility.hiddenIDs.isEmpty)
                    } label: {
                        Image(systemName: visibility.isInspecting ? "arrow.triangle.2.circlepath" : "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(language.text("推荐管理", "Manage recommendations"))
                }
                if visibleItems.isEmpty {
                    Text(language.text("暂无可显示推荐", "No recommendations to show"))
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                } else {
                    ViewThatFits(in: .horizontal) {
                        recommendationGrid(columns: 4).frame(minWidth: 720)
                        recommendationGrid(columns: 2).frame(minWidth: 400)
                        recommendationGrid(columns: 1)
                    }
                }
            }
        }
        .sheet(item: $selected) { skill in SkillInstallSheet(skill: skill, language: language, visibility: visibility) }
    }

    private func recommendationGrid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(columns, visibleItems.count)), spacing: 6) {
            ForEach(visibleItems) { skill in
                Button {
                    selected = skill
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: skill.symbol).foregroundStyle(PaletteControlForeground()).font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.title(language)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(skill.purpose(language)).font(.system(size: 9)).foregroundStyle(PaletteControlForeground())
                            Text(skill.summary(language)).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(skill.summary(language))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(7).frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    skill == .aihot
                        ? language.text("查看 \(skill.title(language)) 项目介绍", "View \(skill.title(language)) project details")
                        : language.text("查看 \(skill.title(language)) 安装指令", "View \(skill.title(language)) installation instructions")
                )
                .contextMenu {
                    Button(language.text("不再显示", "Don't show again")) { visibility.hide(skill.id) }
                }
            }
        }
    }
}

private struct SkillInstallSheet: View {
    let skill: BundledSkill
    let language: WidgetLanguage
    let visibility: RecommendationVisibilityStore
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(skill.title(language)).font(.title3.weight(.semibold))
                Spacer()
                Button(language.text("关闭", "Close")) { dismiss() }
            }
            if skill == .aihot {
                Text(skill.summary(language)).font(.callout)
                Text(
                    language.text(
                        "这是开源行业热点网站框架。自建需 Docker、Node.js 24、数据库与模型 API；这里仅提供介绍与官方链接。MIT 适用于代码，AIHOT 品牌名和 Logo 另有限制。",
                        "An open-source framework for industry news sites. Self-hosting requires Docker, Node.js 24, a database and a model API. This recommendation provides information and an official link only. Code is MIT-licensed; the AIHOT name and logo have separate restrictions."
                    )
                ).font(.callout).foregroundStyle(.secondary)
                if let projectURL = skill.projectURL {
                    Link(language.text("查看官方项目", "View official project"), destination: projectURL)
                }
            } else {
                Text(
                    language.text(
                        "以下指令会交给 Codex。先检查已有安装，按说明复用或安装；不会静默覆盖或调用模型。", "Codex will check existing installations and follow the instructions. No silent overwrite or model calls.")
                )
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
                        } else if let projectURL = skill.projectURL {
                            Link(language.text("查看项目", "View project"), destination: projectURL)
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
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(language.text("不再显示此项", "Don't show this again")) {
                    visibility.hide(skill.id)
                    dismiss()
                }.font(.caption)
                Spacer()
            }
        }
        .padding(22).frame(width: 610)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
