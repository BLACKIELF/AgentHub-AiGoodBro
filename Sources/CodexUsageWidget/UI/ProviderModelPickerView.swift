import AppKit
import SwiftUI

struct ProviderModelPickerView: View {
    @ObservedObject var pool: AntigravityProxyStore
    @ObservedObject var settings: AppSettings
    let provider: AntigravityProxyProvider
    let onLaunch: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var favoritesOnly = false
    @State private var selectedModel: String?
    @State private var target = ProviderLaunchPreset.Target.codex
    @State private var presetName = ""
    @State private var issue: String?
    @State private var importPreview: ProviderLaunchLibrary?
    @State private var importBaseline: ProviderLaunchLibrary?

    private var language: WidgetLanguage { settings.language }
    private var library: ProviderLaunchLibrary { settings.providerLaunchHistory.current }
    private var catalog: [String] { pool.phase == .running ? pool.models(for: provider) : [] }
    private var canLaunch: Bool { selectedModel.map { catalog.contains($0) } == true }

    private struct ModelSection: Identifiable {
        let id: String
        let title: String
        let models: [ProviderQuotaDisplayRow]
        let shared: [ProviderQuotaDisplayRow]
    }

    private func displayed(_ rows: [ProviderQuotaDisplayRow]) -> [ProviderQuotaDisplayRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.enumerated().filter {
            (query.isEmpty || $0.element.id.localizedCaseInsensitiveContains(query) || $0.element.title.localizedCaseInsensitiveContains(query))
                && (!favoritesOnly || library.isFavorite($0.element.id, provider: provider))
        }.sorted {
            let left = library.isFavorite($0.element.id, provider: provider)
            let right = library.isFavorite($1.element.id, provider: provider)
            return left == right ? $0.offset < $1.offset : left
        }.map(\.element)
    }

    var body: some View {
        ScrollView { content }
            .frame(width: 620, height: 620)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(language.text("\(provider.title) 模型与方案", "\(provider.title) models & presets")).font(.headline)
                Spacer()
                Button(language.text("关闭", "Close")) { dismiss() }
            }
            HStack {
                TextField(language.text("搜索模型名称或 ID", "Search model name or ID"), text: $search)
                    .textFieldStyle(.roundedBorder)
                Toggle(language.text("仅常用", "Favorites"), isOn: $favoritesOnly).toggleStyle(.checkbox)
            }
            modelList
            Text(language.text("额度按账号分别显示；启动时由账号池选择可用账号。", "Allowances are shown per account; the pool chooses an available account at launch."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker(language.text("启动客户端", "Client"), selection: $target) {
                Text("Codex CLI").tag(ProviderLaunchPreset.Target.codex)
                if provider != .antigravity { Text("\(provider.title) CLI").tag(ProviderLaunchPreset.Target.native) }
            }.pickerStyle(.segmented)
            if let selectedModel {
                Text(selectedModel).font(.caption.monospaced()).textSelection(.enabled)
                if !canLaunch {
                    Text(language.text("此模型当前未由账号池确认，刷新后再启动。", "The pool has not confirmed this model; refresh before launching."))
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(language.text("启动时核对实时模型目录，并使用独立客户端配置。", "Launch verifies the live model catalog and uses an isolated client configuration."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField(language.text("方案名称", "Preset name"), text: $presetName).textFieldStyle(.roundedBorder)
                Button(language.text("保存方案", "Save preset")) { savePreset() }
                    .disabled(!canLaunch || presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(language.text("选择目录并启动", "Choose folder & launch")) {
                    guard let selectedModel, canLaunch else { return }
                    dismiss()
                    onLaunch(selectedModel, target == .native)
                }.disabled(!canLaunch).buttonStyle(.borderedProminent)
            }
            let presets = library.presets.filter { $0.provider == provider }
            if !presets.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(presets) { preset in
                            HStack {
                                Button {
                                    selectedModel = preset.model
                                    target = preset.target
                                    presetName = preset.name
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.name)
                                        Text("\(preset.target == .codex ? "Codex" : provider.title) · \(preset.model)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                                Spacer()
                                if !catalog.contains(preset.model) {
                                    Text(language.text("待核实", "Unverified")).font(.caption).foregroundStyle(.secondary)
                                }
                                Button {
                                    settings.applyProviderLaunchLibrary(library.removing(preset.id))
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel(language.text("删除方案", "Delete preset"))
                            }
                        }
                    }
                }.frame(maxHeight: 140)
            }
            HStack {
                Button(language.text("导入方案…", "Import presets…")) { previewImport() }
                Button(language.text("导出方案…", "Export presets…")) { exportPresets() }
                Spacer()
                Button(language.text("撤销上次变更", "Undo last change")) { settings.undoProviderLaunchLibrary() }
                    .disabled(settings.providerLaunchHistory.previous == nil)
            }
            if let incoming = importPreview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(language.text("导入预览（所有平台）", "Import preview (all providers)")).font(.subheadline.bold())
                    Text(
                        language.text(
                            "方案 \(library.presets.count) → \(incoming.presets.count) · 常用模型 \(favoriteCount(library)) → \(favoriteCount(incoming))",
                            "Presets \(library.presets.count) → \(incoming.presets.count) · Favorites \(favoriteCount(library)) → \(favoriteCount(incoming))")
                    )
                    .font(.caption)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(incoming.presets.filter { preset in !library.presets.contains(preset) }) { preset in
                                Text("\(preset.provider.title) · \(preset.name) · \(preset.target.rawValue) · \(preset.model)")
                                    .font(.caption).textSelection(.enabled)
                                if let previous = library.presets.first(where: { $0.id == preset.id }) {
                                    Text(language.text("原方案：", "Previous: ") + "\(previous.provider.title) · \(previous.name) · \(previous.target.rawValue) · \(previous.model)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(AntigravityProxyProvider.allCases, id: \.rawValue) { source in
                                let before = library.favorites[source.rawValue] ?? []
                                let after = incoming.favorites[source.rawValue] ?? []
                                if before != after {
                                    Text("\(source.title) · \(before.joined(separator: ", ")) → \(after.joined(separator: ", "))")
                                        .font(.caption).textSelection(.enabled)
                                }
                            }
                        }
                    }.frame(maxHeight: 90)
                    HStack {
                        Button(language.text("取消", "Cancel")) {
                            importPreview = nil
                            importBaseline = nil
                        }
                        Button(language.text("合并方案", "Merge presets")) {
                            guard importBaseline == library else {
                                issue = language.text("方案已变更，请重新导入以查看最新差异。", "Presets changed. Import again to review the current differences.")
                                importPreview = nil
                                importBaseline = nil
                                return
                            }
                            settings.applyProviderLaunchLibrary(incoming)
                            importPreview = nil
                            importBaseline = nil
                        }
                    }
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            Text(language.text("方案只保存平台、模型、客户端和名称；不包含账号授权。", "Presets contain only provider, model, client and name; no account credentials."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelList: some View {
        let now = Date()
        let accounts = pool.accounts.filter { $0.provider == provider }
        let all = accounts.map { account in
            ModelSection(
                id: account.id, title: account.maskedIdentity,
                models: ProviderModelQuotaPresentation.models(account: account, isRunning: pool.phase == .running, now: now),
                shared: ProviderModelQuotaPresentation.shared(account: account, isRunning: pool.phase == .running, now: now))
        }
        let assigned = Set(all.flatMap { $0.models.map(\.id) })
        let disabled = Set(accounts.flatMap { ($0.modelDetails ?? []).filter { $0.disabled == true }.map(\.id) })
        let unassigned = displayed(
            catalog.filter {
                !assigned.contains($0) && !disabled.contains($0) && ProviderModelQuotaPresentation.visible($0, provider: provider)
            }.map { ProviderQuotaDisplayRow(id: $0, title: $0, modelID: $0) })
        let sections = all.map { ModelSection(id: $0.id, title: $0.title, models: displayed($0.models), shared: $0.shared) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(sections) { section in
                    if !section.models.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            if !section.shared.isEmpty {
                                DisclosureGroup(language.text("共享额度（\(section.shared.count)）", "Shared allowance (\(section.shared.count))")) {
                                    ForEach(section.shared) { row in
                                        ProviderQuotaRowView(row: row, language: language, compact: true).padding(.vertical, 3)
                                    }
                                }.font(.caption)
                            }
                            ForEach(section.models) { row in modelRow(row) }
                        }
                    }
                }
                ForEach(unassigned) { row in modelRow(row) }
                if sections.allSatisfy({ $0.models.isEmpty }) && unassigned.isEmpty {
                    Text(
                        search.isEmpty && !favoritesOnly
                            ? language.text("刷新账号池后显示服务商返回的模型。", "Refresh the pool to see the models reported by the provider.")
                            : language.text("没有匹配的模型。", "No matching models.")
                    )
                    .foregroundStyle(.secondary).padding(.vertical, 12)
                }
            }
        }.frame(minHeight: 120, maxHeight: 280)
    }

    private func modelRow(_ row: ProviderQuotaDisplayRow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                if let updated = library.togglingFavorite(row.id, provider: provider) {
                    settings.applyProviderLaunchLibrary(updated)
                } else {
                    issue = language.text("每个平台最多保留 32 个常用模型。", "Keep up to 32 favorites per provider.")
                }
            } label: {
                Image(systemName: library.isFavorite(row.id, provider: provider) ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(language.text("常用模型 \(row.title)", "Favorite \(row.title)"))
            Button {
                selectedModel = row.id
            } label: {
                HStack(spacing: 8) {
                    ProviderQuotaRowView(row: row, language: language, compact: true)
                    VStack(alignment: .trailing, spacing: 4) {
                        if row.id == selectedModel { Image(systemName: "checkmark") }
                        if !catalog.contains(row.id) {
                            Text(language.text("当前不可启动", "Unavailable now")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(.vertical, 4)
    }

    private func favoriteCount(_ value: ProviderLaunchLibrary) -> Int { value.favorites.values.reduce(0) { $0 + $1.count } }

    private func savePreset() {
        guard let selectedModel, canLaunch,
            let updated = library.saving(name: presetName, provider: provider, model: selectedModel, target: target)
        else {
            issue = language.text("方案名称限 1–40 字且不能含敏感信息，最多保存 32 个方案。", "Use a 1–40 character name without sensitive values, with up to 32 presets.")
            return
        }
        settings.applyProviderLaunchLibrary(updated)
        issue = nil
    }

    private func previewImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPreview = nil
        importBaseline = nil
        do {
            guard let data = try DispatchParticipationSync.readBoundedRegularFile(url, maximumBytes: ProviderLaunchLibrary.maximumBytes, allowMissing: false),
                let merged = library.merged(with: try ProviderLaunchLibrary.decodeImport(data))
            else { throw ProviderLaunchLibrary.ImportFailure.invalid }
            importBaseline = library
            importPreview = merged
            issue = nil
        } catch {
            issue = language.text("无法导入：请选择 AiGoodBro 方案 JSON，并检查格式与数量限制。", "Cannot import: choose an AiGoodBro preset JSON and check its format and size limits.")
        }
    }

    private func exportPresets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AiGoodBro-presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.exportData().write(to: url, options: .atomic)
            issue = nil
        } catch {
            issue = language.text("无法保存方案，请检查目标文件。", "Could not save presets. Check the destination file.")
        }
    }
}
