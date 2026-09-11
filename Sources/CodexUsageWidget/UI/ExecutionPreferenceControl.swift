import AppKit
import SwiftUI

/// Shared by the workspace, account rows and menu bar. Preferences are persisted by the caller.
struct ExecutionPreferenceControl: View {
    @Environment(\.widgetLanguage) private var language
    let preference: CodexExecutionPreference
    var allowsApplyToAll = true
    var expanded = false
    var compact = false
    var inlineEditor = false
    let onSave: (CodexExecutionPreference, Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.visualTokens) private var visualTokens
    @State private var isPresented = false
    @State private var isModeInfoPresented = false
    @State private var draft: CodexExecutionPreference
    @State private var editingMode: CodexExecutionPreference.SubagentMode?
    @State private var presetDraft: CodexExecutionPreference.CustomPreset?
    @State private var editorError: String?
    @State private var editorContentHeight: CGFloat = 360

    init(
        preference: CodexExecutionPreference,
        allowsApplyToAll: Bool = true,
        expanded: Bool = false,
        compact: Bool = false,
        inlineEditor: Bool = false,
        initialEditingMode: CodexExecutionPreference.SubagentMode? = nil,
        onSave: @escaping (CodexExecutionPreference, Bool) -> Void
    ) {
        self.preference = preference
        self.allowsApplyToAll = allowsApplyToAll
        self.expanded = expanded
        self.compact = compact
        self.inlineEditor = inlineEditor
        self.onSave = onSave
        _draft = State(initialValue: preference)
        _editingMode = State(initialValue: initialEditingMode)
        _presetDraft = State(initialValue: initialEditingMode.flatMap { preference.preset(for: $0) })
    }

    var body: some View {
        Group {
            if inlineEditor { editor } else { selector }
        }
    }

    private var selector: some View {
        Button {
            draft = preference
            editingMode = nil
            editorError = nil
            isPresented = true
        } label: {
            HStack(spacing: compact ? 6 : 10) {
                Image(systemName: preference.serviceTier == .fast ? "bolt.fill" : "bolt")
                    .font(.system(size: expanded ? 22 : 16, weight: .medium))
                    .foregroundStyle(visualTokens.accent.primaryStrong.color)
                    .accessibilityHidden(true)
                if compact {
                    Text(preference.effectiveStrategy.mainModel.displayName)
                        .font(.caption.weight(.semibold))
                    Text(preferenceSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeModeTitle(preference))
                            .font(.system(size: expanded ? 19 : 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(preferenceSummary)
                            .font(.system(size: expanded ? 12 : 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 8 : expanded ? 18 : 12)
            .padding(.vertical, compact ? 4 : expanded ? 16 : 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                FixedVisualPalette.cardFill(
                    colorScheme,
                    elevated: true,
                    reduceTransparency: reduceTransparency
                ),
                in: RoundedRectangle(cornerRadius: expanded ? 18 : 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: expanded ? 18 : 12)
                    .strokeBorder(
                        FixedVisualPalette.cardStroke(
                            colorScheme,
                            elevated: true,
                            increasedContrast: colorSchemeContrast == .increased
                        ),
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.7
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ExecutionPreferenceButtonStyle())
        .help(
            language.text("设置后续 CLI 与任务派单的模型、强度、速度和执行档位", "Set models, reasoning, speed and presets for new CLI sessions and tasks.")
                + "\n" + preferenceSummary
        )
        .accessibilityLabel(language.text("任务模型", "Task model"))
        .accessibilityValue(activeAccessibilityValue(preference))
        .popover(isPresented: $isPresented, arrowEdge: .trailing) { editor }
        .onChange(of: preference) {
            draft = $0
            editingMode = nil
            editorError = nil
        }
    }

    private var editor: some View {
        ScrollView(.vertical) {
            editorContent.background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ExecutionEditorHeightKey.self, value: geometry.size.height)
                }
            }
        }
        .frame(width: 430, height: min(editorContentHeight, max(240, (NSScreen.main?.visibleFrame.height ?? 900) - 120)))
        .background(Color(nsColor: .windowBackgroundColor))
        .onPreferenceChange(ExecutionEditorHeightKey.self) { height in
            if height > 0, abs(editorContentHeight - height) > 1 { editorContentHeight = height }
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            savedDefaultsSection
            fastSection
            presetSelectionSection

            if let editingMode, let presetDraft {
                Divider()
                presetEditor(mode: editingMode, preset: presetDraft)
            }

            if let editorError {
                Label(editorError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if allowsApplyToAll, editingMode == nil {
                Divider()
                Button {
                    onSave(draft, true)
                    isPresented = false
                } label: {
                    Label(language.text("应用到所有账号", "Apply to all profiles"), systemImage: "person.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Text(language.text("设置用于后续 CLI 会话和派单。", "Settings apply to new CLI sessions and dispatched tasks."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 430)
    }

    private var savedDefaultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(language.text("已保存默认模型", "Saved default model"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    saveValidated(.defaultValue)
                    editingMode = nil
                    presetDraft = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(defaultSettingsHelp)
                .accessibilityLabel(language.text("恢复全部默认设置", "Restore all defaults"))
            }
            adaptiveMenuRow {
                modelMenu(selection: modelBinding, label: language.text("主模型", "Main model"))
                effortMenu(selection: effortBinding, model: draft.model, label: language.text("强度", "Effort"))
            }
        }
        .padding(14)
        .background(
            FixedVisualPalette.sectionFill(colorScheme, reduceTransparency: reduceTransparency),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    FixedVisualPalette.sectionStroke(
                        colorScheme,
                        increasedContrast: colorSchemeContrast == .increased
                    ),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.7
                )
        }
    }

    private var fastSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("Fast 速度", "Fast mode")).font(.subheadline.weight(.medium))
                Text(
                    effectiveModelsSupportFast
                        ? language.text("更快响应，会消耗更多额度", "Faster responses; higher usage")
                        : language.text("当前档位的有效模型不支持 Fast", "An effective model in this preset does not support Fast.")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(language.text("Fast 速度", "Fast mode"), isOn: fastBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!effectiveModelsSupportFast && draft.serviceTier != .fast)
        }
        .padding(.horizontal, 4)
    }

    private var presetSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.text("执行档位", "Execution preset"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    isModeInfoPresented.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(language.text("了解默认组合与额度含义", "About defaults and usage"))
                .accessibilityLabel(language.text("执行档位说明", "Execution preset information"))
                .popover(isPresented: $isModeInfoPresented, arrowEdge: .trailing) { modeInformation }
            }

            HStack(alignment: .top, spacing: 7) {
                ForEach(CodexExecutionPreference.SubagentMode.allCases, id: \.rawValue) { mode in
                    presetButton(mode)
                }
            }

            if !CodexExecutionPreference.SubagentMode.allCases.contains(draft.subagentMode) {
                Text(language.text("保存的档位无法识别。请选择一个可用档位后再启动。", "The saved preset is unsupported. Choose an available preset before starting."))
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack {
                Text(activeStrategySummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(language.text("自定义", "Customize")) { beginEditing(draft.subagentMode) }
                    .buttonStyle(.borderless)
                    .disabled(!CodexExecutionPreference.SubagentMode.allCases.contains(draft.subagentMode))
            }
        }
    }

    private func presetButton(_ mode: CodexExecutionPreference.SubagentMode) -> some View {
        let selected = draft.subagentMode == mode
        let title = modeTitle(mode, preference: draft)
        let strategy = draft.effectiveStrategy(for: mode)
        return Button {
            var updated = draft
            updated.subagentMode = mode
            saveValidated(updated)
            editingMode = nil
            presetDraft = nil
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(modeBehaviorSummary(mode))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(strategy.map { "\($0.mainModel.displayName) · \($0.mainReasoningEffort.displayName)" } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(childSummary(strategy))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(8)
            .background(selected ? Color.accentColor.opacity(0.10) : FixedVisualPalette.primarySurface(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.48) : FixedVisualPalette.surfaceStrokeSoft, lineWidth: selected ? 1 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(slotAccessibilityValue(mode, preference: draft))
    }

    @ViewBuilder
    private func presetEditor(
        mode: CodexExecutionPreference.SubagentMode,
        preset: CodexExecutionPreference.CustomPreset
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(language.text("自定义档位", "Customize preset"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if presetNameBytes > 64 {
                    Text(language.text("名称过长", "Name is too long"))
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            TextField(language.text("名称（留空使用默认名称）", "Name (blank uses default)"), text: presetNameBinding)
                .textFieldStyle(.roundedBorder)

            Toggle(language.text("跟随已保存默认模型", "Use saved default model"), isOn: presetUseSavedModelBinding)
            adaptiveMenuRow {
                modelMenu(selection: presetModelBinding, label: language.text("主模型", "Main model"))
                effortMenu(selection: presetEffortBinding, model: preset.model, label: language.text("主强度", "Main effort"))
            }
            .disabled(preset.useSavedModel)
            .opacity(preset.useSavedModel ? 0.55 : 1)

            Toggle(language.text("启用子代理（每次 1 个）", "Enable subagent (one active child)"), isOn: presetSubagentsBinding)
            adaptiveMenuRow {
                modelMenu(selection: presetSubagentModelBinding, label: language.text("子模型", "Subagent model"))
                effortMenu(selection: presetSubagentEffortBinding, model: preset.subagentModel, label: language.text("子强度", "Subagent effort"))
            }
            .disabled(!preset.subagentsEnabled)
            .opacity(preset.subagentsEnabled ? 1 : 0.55)

            HStack {
                Button(language.text("恢复此档默认", "Restore preset default")) {
                    saveValidated(draft.restoringDefault(for: mode))
                    editingMode = nil
                    presetDraft = nil
                }
                .buttonStyle(.borderless)
                Spacer()
                Button(language.text("取消", "Cancel")) {
                    editingMode = nil
                    presetDraft = nil
                    editorError = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(language.text("保存", "Save")) { commitPreset(mode) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Menus sit side by side when there is room and stack when a narrow context would
    /// squeeze long model names or larger accessibility text sizes.
    @ViewBuilder
    private func adaptiveMenuRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12, content: content)
            VStack(alignment: .leading, spacing: 10, content: content)
        }
    }

    private func modelMenu(
        selection: Binding<CodexExecutionPreference.Model>,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Picker(label, selection: selection) {
                ForEach(CodexExecutionPreference.Model.allCases, id: \.rawValue) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(label)
            .accessibilityValue(selection.wrappedValue.displayName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func effortMenu(
        selection: Binding<CodexExecutionPreference.ReasoningEffort>,
        model: CodexExecutionPreference.Model,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Picker(label, selection: selection) {
                ForEach(model.supportedReasoningEfforts, id: \.rawValue) { effort in
                    Text(language.isChinese ? "\(effort.localizedTitle) · \(effort.displayName)" : effort.displayName).tag(effort)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(label)
            .accessibilityValue(selection.wrappedValue.displayName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelBinding: Binding<CodexExecutionPreference.Model> {
        Binding(
            get: { draft.model },
            set: { model in
                var updated = draft
                updated.model = model
                if !model.supportedReasoningEfforts.contains(updated.reasoningEffort) {
                    updated.reasoningEffort = model.supportedReasoningEfforts.last ?? .low
                }
                saveValidated(updated)
            })
    }

    private var effortBinding: Binding<CodexExecutionPreference.ReasoningEffort> {
        Binding(
            get: { draft.reasoningEffort },
            set: { effort in
                var updated = draft
                updated.reasoningEffort = effort
                saveValidated(updated)
            })
    }

    private var fastBinding: Binding<Bool> {
        Binding(
            get: { draft.serviceTier == .fast },
            set: { enabled in
                var updated = draft
                updated.serviceTier = enabled ? .fast : .standard
                saveValidated(updated)
            })
    }

    private var presetNameBinding: Binding<String> {
        Binding(get: { presetDraft?.name ?? "" }, set: { presetDraft?.name = $0.isEmpty ? nil : $0 })
    }

    private var presetUseSavedModelBinding: Binding<Bool> {
        Binding(get: { presetDraft?.useSavedModel ?? false }, set: { presetDraft?.useSavedModel = $0 })
    }

    private var presetModelBinding: Binding<CodexExecutionPreference.Model> {
        Binding(
            get: { presetDraft?.model ?? .astra },
            set: { model in
                presetDraft?.model = model
                if let effort = presetDraft?.reasoningEffort, !model.supportedReasoningEfforts.contains(effort) {
                    presetDraft?.reasoningEffort = model.supportedReasoningEfforts.last ?? .low
                }
            })
    }

    private var presetEffortBinding: Binding<CodexExecutionPreference.ReasoningEffort> {
        Binding(get: { presetDraft?.reasoningEffort ?? .low }, set: { presetDraft?.reasoningEffort = $0 })
    }

    private var presetSubagentsBinding: Binding<Bool> {
        Binding(get: { presetDraft?.subagentsEnabled ?? false }, set: { presetDraft?.subagentsEnabled = $0 })
    }

    private var presetSubagentModelBinding: Binding<CodexExecutionPreference.Model> {
        Binding(
            get: { presetDraft?.subagentModel ?? .luna },
            set: { model in
                presetDraft?.subagentModel = model
                if let effort = presetDraft?.subagentReasoningEffort, !model.supportedReasoningEfforts.contains(effort) {
                    presetDraft?.subagentReasoningEffort = model.supportedReasoningEfforts.last ?? .low
                }
            })
    }

    private var presetSubagentEffortBinding: Binding<CodexExecutionPreference.ReasoningEffort> {
        Binding(get: { presetDraft?.subagentReasoningEffort ?? .max }, set: { presetDraft?.subagentReasoningEffort = $0 })
    }

    private func beginEditing(_ mode: CodexExecutionPreference.SubagentMode) {
        guard let preset = draft.preset(for: mode) else { return }
        editingMode = mode
        presetDraft = preset
        editorError = nil
    }

    private func commitPreset(_ mode: CodexExecutionPreference.SubagentMode) {
        guard var preset = presetDraft else { return }
        if let name = preset.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            preset.name = trimmed.isEmpty ? nil : trimmed
        }
        var updated = draft
        updated.customPresets[mode.rawValue] = preset
        do {
            draft = try updated.validated()
            onSave(draft, false)
            editingMode = nil
            presetDraft = nil
            editorError = nil
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func saveValidated(_ updated: CodexExecutionPreference) {
        guard updated != draft else { return }
        do {
            draft = try updated.validated()
            onSave(draft, false)
            editorError = nil
        } catch {
            editorError = error.localizedDescription
        }
    }

    private var effectiveModelsSupportFast: Bool {
        let strategy = draft.effectiveStrategy
        return strategy.mainModel.supportsFast && (strategy.subagentModel?.supportsFast ?? true)
    }

    private var presetNameBytes: Int { (presetDraft?.name ?? "").utf8.count }

    private var speedTitle: String {
        preference.serviceTier == .fast ? "Fast" : language.text("标准速度", "Standard")
    }

    private var preferenceSummary: String {
        let strategy = preference.effectiveStrategy
        return "\(strategy.mainModel.displayName) · \(strategy.mainReasoningEffort.displayName) · \(childSummary(strategy)) · \(speedTitle)"
    }

    private func modeBehaviorSummary(_ mode: CodexExecutionPreference.SubagentMode) -> String {
        switch mode {
        case .standard:
            return language.text("跟随已保存的主模型和强度；无子代理", "Follows the saved main model and effort; no subagent")
        case .solLuna:
            return language.text("默认 planner + worker 组合", "Default planner + worker combination")
        case .lunaDirect:
            return language.text("默认不额外调用规划模型", "Default: no extra planner call")
        default:
            return language.text("需重新选择档位", "Choose a preset")
        }
    }

    private func builtInModeTitle(_ mode: CodexExecutionPreference.SubagentMode) -> String {
        switch mode {
        case .standard: return language.text("狂蹬模式", "Saved-model mode")
        case .solLuna: return language.text("中蹬模式", "Planner + worker")
        case .lunaDirect: return language.text("慢蹬模式", "Direct mode")
        default: return language.text("需重新选择档位", "Choose a preset")
        }
    }

    private func modeTitle(
        _ mode: CodexExecutionPreference.SubagentMode,
        preference: CodexExecutionPreference
    ) -> String {
        preference.customName(for: mode) ?? builtInModeTitle(mode)
    }

    private func activeModeTitle(_ preference: CodexExecutionPreference) -> String {
        modeTitle(preference.subagentMode, preference: preference)
    }

    private func childSummary(_ strategy: CodexExecutionPreference.EffectiveStrategy?) -> String {
        guard let strategy, let child = strategy.subagentModel,
            let effort = strategy.subagentReasoningEffort
        else { return language.text("无子代理", "No subagent") }
        return language.text("子：\(child.displayName) · \(effort.displayName)", "Child: \(child.displayName) · \(effort.displayName)")
    }

    private var activeStrategySummary: String {
        guard CodexExecutionPreference.SubagentMode.allCases.contains(draft.subagentMode) else { return "" }
        let strategy = draft.effectiveStrategy
        return language.text(
            "有效主模型：\(strategy.mainModel.displayName) · \(strategy.mainReasoningEffort.displayName)；\(childSummary(strategy))",
            "Effective main: \(strategy.mainModel.displayName) · \(strategy.mainReasoningEffort.displayName); \(childSummary(strategy))"
        )
    }

    private func slotAccessibilityValue(
        _ mode: CodexExecutionPreference.SubagentMode,
        preference: CodexExecutionPreference
    ) -> String {
        guard let strategy = preference.effectiveStrategy(for: mode) else { return "" }
        return "\(strategy.mainModel.displayName), \(strategy.mainReasoningEffort.displayName), \(childSummary(strategy))"
    }

    private func activeAccessibilityValue(_ preference: CodexExecutionPreference) -> String {
        "\(activeModeTitle(preference)), \(slotAccessibilityValue(preference.subagentMode, preference: preference)), \(speedTitle)"
    }

    private var modeInformation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("执行档位与额度", "Execution presets and usage"))
                .font(.headline)
            ForEach(CodexExecutionPreference.SubagentMode.allCases, id: \.rawValue) { mode in
                let defaults = CodexExecutionPreference.defaultValue.effectiveStrategy(for: mode)
                VStack(alignment: .leading, spacing: 3) {
                    Text(builtInModeTitle(mode)).font(.subheadline.weight(.semibold))
                    Text(
                        mode == .standard
                            ? language.text("默认：跟随已保存的主模型和强度；无子代理", "Default: saved main model and effort; no subagent")
                            : defaults.map {
                                language.text(
                                    "默认：\($0.mainModel.displayName) · \($0.mainReasoningEffort.displayName)；\(childSummary($0))",
                                    "Default: \($0.mainModel.displayName) · \($0.mainReasoningEffort.displayName); \(childSummary($0))"
                                )
                            } ?? ""
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Divider()
            Text(
                language.text(
                    "三个档位的名称和模型组合都可修改。档位表示调用方式，不是固定的费用排序；实际消耗取决于模型、上下文和调用次数。Max 是模型自身的思考强度；慢蹬默认不额外调用规划模型。子代理按每次一个的协作约定执行。Fast 需要主模型及启用的子模型都支持。",
                    "Names and model combinations are customizable. Usage depends on models, context and call count. Max is the model's own reasoning effort; Direct mode adds no separate planner. The workflow uses one child at a time. Fast requires support from the main model and any enabled subagent."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 350)
    }

    private var defaultSettingsHelp: String {
        let value = CodexExecutionPreference.defaultValue
        return language.text("恢复全部默认：", "Restore all defaults: ")
            + "\(value.model.displayName) · \(value.reasoningEffort.displayName) · \(value.serviceTier.displayName) · \(builtInModeTitle(value.subagentMode))"
    }

}

private struct ExecutionEditorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Immediate feedback remains visible for keyboard and Reduce Motion users.
private struct ExecutionPreferenceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}
