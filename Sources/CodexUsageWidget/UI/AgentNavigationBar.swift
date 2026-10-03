import SwiftUI
import UniformTypeIdentifiers

struct AgentNavigationBar: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.visualTokens) private var visualTokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var navigation: AgentNavigationState
    let language: WidgetLanguage
    let detectedIDs: [String]
    let selectedID: String?
    let showingHome: Bool
    let existingUser: Bool
    var onSelectHome: () -> Void
    var onSelect: (String) -> Void
    var onRefresh: () -> Void
    var showsGettingStarted: Bool
    var onGettingStarted: () -> Void
    var onOpenSettings: () -> Void = {}
    var onOpenProxy: () -> Void = {}
    var onSaveScreenshot: () -> Void = {}
    var workspaceActionsEnabled = true

    @State private var isAdding = false
    @State private var isManaging = false
    @State private var management: AgentNavigationManagementSession?
    @State private var dropTargetID: String?
    @State private var undoIDs: [String]?
    @State private var undoResult: [String]?
    @State private var hoveredID: String?

    var body: some View {
        VStack(spacing: 6) {
            navButton(
                id: AgentNavCatalog.homeID,
                title: language.text("主页", "Home"),
                selected: showingHome,
                systemImage: "house",
                action: onSelectHome
            )
            Divider().padding(.horizontal, 8)
            ScrollViewReader { scroll in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(navigation.renderableIDs(), id: \.self) { id in
                            agentButton(id: id, selected: !showingHome && selectedID == id)
                                .id(id)
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: selectedID) { id in
                    if let id { scroll.scrollTo(id, anchor: .center) }
                }
            }
            Divider().padding(.horizontal, 8)
            Menu {
                Button(language.text("添加 Agent…", "Add Agent…")) { isAdding = true }
                Button(language.text("管理导航…", "Manage navigation…")) {
                    management = AgentNavigationManagementSession(navigation)
                    dropTargetID = nil
                    isManaging = true
                }
                if undoIDs != nil {
                    Button(language.text("撤销导航调整", "Undo navigation change")) {
                        if let undoIDs, navigation.orderedVisibleProviderIDs == undoResult {
                            navigation.orderedVisibleProviderIDs = undoIDs
                        }
                        self.undoIDs = nil
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 40)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).tint(.primary).menuIndicator(.hidden)
            .help(language.text("管理导航", "Manage navigation"))
            .accessibilityLabel(language.text("管理导航", "Manage navigation"))
            .accessibilityIdentifier("workspace.navigation.more")
            Button(action: onOpenProxy) {
                Image(systemName: "network")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 36)
            }
            .buttonStyle(WorkspaceQuietButtonStyle(cornerRadius: 10))
            .disabled(!workspaceActionsEnabled)
            .help(language.text("反代模式", "Reverse proxy"))
            .accessibilityLabel(language.text("反代模式", "Reverse proxy"))
            .accessibilityIdentifier("next.local-proxy.open")
            Button(action: onSaveScreenshot) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 36)
            }
            .buttonStyle(WorkspaceQuietButtonStyle(cornerRadius: 10))
            .disabled(!workspaceActionsEnabled)
            .help(language.text("保存主界面长截图（PNG）", "Save full workspace screenshot (PNG)"))
            .accessibilityLabel(language.text("保存主界面长截图", "Save full workspace screenshot"))
            .accessibilityIdentifier("workspace.navigation.screenshot")
            Button(action: onGettingStarted) {
                VStack(spacing: 3) {
                    Image(systemName: "questionmark.circle").font(.system(size: 17, weight: .medium))
                    Text(language.text("使用引导", "Guide")).font(.system(size: 9, weight: .medium))
                }
                .frame(width: 48, height: 44)
            }
            .buttonStyle(WorkspaceQuietButtonStyle(cornerRadius: 10))
            .help(language.text("使用引导", "Getting started"))
            .accessibilityLabel(language.text("使用引导", "Getting started"))
            .accessibilityIdentifier("workspace.navigation.guide")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(WorkspaceQuietButtonStyle(cornerRadius: 10))
            .help(language.text("设置", "Settings"))
            .accessibilityLabel(language.text("设置", "Settings"))
            .accessibilityIdentifier("workspace.navigation.settings")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(WorkspaceGlassSurface(cornerRadius: 0))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("页面导航", "Page navigation"))
        .onAppear {
            navigation.bootstrapIfNeeded(existingUser: existingUser, currentVisible: defaultVisible)
        }
        .sheet(isPresented: $isAdding) { addSheet }
        .sheet(isPresented: $isManaging, onDismiss: cancelManagement) { manageSheet }
    }

    private var defaultVisible: [String] {
        [AgentNavCatalog.codexID] + detectedIDs.filter { $0 != AgentNavCatalog.codexID }
    }

    private func agentButton(id: String, selected: Bool) -> some View {
        navButton(
            id: id, title: AgentNavCatalog.displayName(id), selected: selected,
            providerID: id,
            action: { onSelect(id) }
        )
        .contextMenu {
            Button(language.text("从导航移除", "Remove from navigation")) { remove(id) }
        }
    }

    private func navButton(
        id: String,
        title: String,
        selected: Bool,
        providerID: String? = nil,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: ProviderIconSlot.navigation.container, height: ProviderIconSlot.navigation.container)
                } else if let providerID {
                    ProviderMark(providerID: providerID, slot: .navigation)
                }
            }
            .frame(width: 44, height: 40)
            .background(
                selected ? visualTokens.selection.fill.color : Color.primary.opacity(hoveredID == id ? 0.07 : 0),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(visualTokens.selection.stroke.color.opacity(colorSchemeContrast == .increased ? 0.85 : 0.7), lineWidth: 1)
                }
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(visualTokens.accent.primary.color)
                        .frame(width: 3, height: 16).offset(x: -5)
                        .allowsHitTesting(false)
                }
            }
            .animation(WorkspaceMotion.feedback(reduceMotion: reduceMotion), value: hoveredID == id)
            .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceQuietButtonStyle(cornerRadius: 10))
        .onHover { hovering in
            if hovering { hoveredID = id } else if hoveredID == id { hoveredID = nil }
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("workspace.navigation." + id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func remove(_ id: String) {
        undoIDs = navigation.orderedVisibleProviderIDs
        _ = navigation.remove(id)
        undoResult = navigation.orderedVisibleProviderIDs
        if selectedID == id { onSelectHome() }
    }

    private var addSheet: some View {
        let added = Set(navigation.orderedVisibleProviderIDs)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(language.text("添加 Agent", "Add Agent")).font(.headline)
                Spacer()
                Button(language.text("关闭", "Close")) { isAdding = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(language.text("关闭添加 Agent", "Close Add Agent"))
            }
            Text(language.text("只加入导航入口，不会安装、登录或发起调用。", "This only adds a navigation tab. It does not install, sign in or call a model."))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        Text(language.text("已添加", "Added")).font(.subheadline.weight(.semibold))
                        ForEach(navigation.renderableIDs(), id: \.self) { id in
                            catalogRow(id: id, added: true)
                        }
                        if navigation.renderableIDs().isEmpty {
                            Text(language.text("导航里还没有 Agent，主页和添加入口仍可用。", "No agents are in the navigation yet. Home and Add stay available."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text(language.text("可添加", "Available")).font(.subheadline.weight(.semibold))
                    ForEach(AgentNavCatalog.workspaceProviders.filter { !added.contains($0.id) }) { provider in
                        catalogRow(id: provider.id, added: false, detected: detectedIDs.contains(provider.id) || provider.id == AgentNavCatalog.codexID)
                    }
                    Divider()
                    Text(language.text("尚未作为工作台 Agent 支持", "Not a workspace Agent yet")).font(.subheadline.weight(.semibold))
                    ForEach(AgentNavCatalog.upcomingProviders) { provider in
                        HStack {
                            ProviderMark(providerID: provider.id, slot: .navigation)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                Text(language.text("可在目录中查看，当前不能加入导航。", "Listed for reference and cannot be added yet."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                Button(language.text("完成", "Done")) { isAdding = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 560)
        .onExitCommand { isAdding = false }
    }

    private func catalogRow(id: String, added: Bool, detected: Bool = false) -> some View {
        HStack(spacing: 10) {
            ProviderMark(providerID: id, slot: .navigation)
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentNavCatalog.displayName(id))
                Text(
                    added
                        ? language.text("已在导航中", "Already in navigation")
                        : detected
                            ? language.text("已检测到 · 建议添加", "Detected · suggested")
                            : language.text("待配置", "Needs setup")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if added {
                Button(language.text("移除", "Remove")) { remove(id) }
            } else {
                Button(language.text("添加到导航", "Add to navigation")) { _ = navigation.add(id) }
            }
        }
    }

    private var manageSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(language.text("管理导航", "Manage navigation")).font(.headline)
                Spacer()
                Button(language.text("关闭", "Close"), action: cancelManagement)
                    .accessibilityLabel(language.text("关闭导航管理", "Close navigation management"))
            }
            Text(
                language.text(
                    "拖动 Agent 图标或名称调整顺序，完成后保存。移除仅隐藏入口，账号与任务保留。", "Drag an Agent icon or name to reorder, then choose Done to save. Removing a tab keeps its accounts and tasks.")
            )
            .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach((management?.draft ?? navigation).renderableIDs(), id: \.self) { id in
                        managementRow(id: id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if management?.committed(current: navigation) == nil {
                Text(language.text("导航已在其他窗口更改，请取消后重新管理。", "Navigation changed in another window. Cancel and reopen Manage."))
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(language.text("重新检测本机 Agent", "Scan local Agents"), action: onRefresh)
                Button(language.text("恢复默认", "Restore default")) {
                    management?.restoreDefault(currentVisible: defaultVisible)
                    dropTargetID = nil
                }
                Spacer()
                Button(language.text("取消", "Cancel"), action: cancelManagement)
                    .keyboardShortcut(.cancelAction)
                Button(language.text("完成", "Done"), action: finishManagement)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 480)
        .onExitCommand(perform: cancelManagement)
    }

    private func managementRow(id: String) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                ProviderMark(providerID: id, slot: .navigation)
                Text(AgentNavCatalog.displayName(id)).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .onDrag {
                guard let token = management?.beginDragging(id) else { return NSItemProvider() }
                return NSItemProvider(object: token as NSString)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AgentNavCatalog.displayName(id))
            .accessibilityHint(language.text("拖动调整顺序", "Drag to reorder"))
            .accessibilityAction(named: Text(language.text("向上移动", "Move up"))) { management?.move(id, by: -1) }
            .accessibilityAction(named: Text(language.text("向下移动", "Move down"))) { management?.move(id, by: 1) }
            Button(language.text("移除", "Remove"), role: .destructive) {
                management?.remove(id)
                dropTargetID = nil
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(dropTargetID == id ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .onDrop(
            of: [UTType.utf8PlainText],
            isTargeted: Binding(
                get: { dropTargetID == id },
                set: { targeted in
                    if targeted { dropTargetID = id } else if dropTargetID == id { dropTargetID = nil }
                })
        ) { providers, location in
            receiveManagementDrop(providers, targetID: id, after: location.y >= 22)
        }
    }

    private func receiveManagementDrop(_ providers: [NSItemProvider], targetID: String, after: Bool) -> Bool {
        guard providers.count == 1, let provider = providers.first,
            provider.canLoadObject(ofClass: NSString.self),
            management?.isDragging == true
        else { return false }
        provider.loadObject(ofClass: NSString.self) { object, error in
            guard error == nil, let token = object as? String else { return }
            DispatchQueue.main.async {
                // Re-check the active draft: a delayed drop cannot change a reopened sheet.
                _ = management?.drop(token: token, targetID: targetID, after: after)
                dropTargetID = nil
            }
        }
        return true
    }

    private func finishManagement() {
        guard let management, let result = management.committed(current: navigation) else { return }
        if result != navigation {
            undoIDs = navigation.orderedVisibleProviderIDs
            undoResult = result.orderedVisibleProviderIDs
            navigation = result
            if let selectedID, !result.renderableIDs().contains(selectedID) { onSelectHome() }
        }
        cancelManagement()
    }

    private func cancelManagement() {
        management = nil
        dropTargetID = nil
        isManaging = false
    }

}

/// All management changes stay in this value until Done. A local drag token is
/// single-use; canceled, external and delayed drops cannot modify another draft.
struct AgentNavigationManagementSession: Equatable {
    let original: AgentNavigationState
    private(set) var draft: AgentNavigationState
    private var dragToken: String?
    private var dragSource: String?
    private var dragOrder: [String]?

    init(_ state: AgentNavigationState) {
        original = state
        draft = state
    }

    var isDragging: Bool { dragToken != nil }

    mutating func beginDragging(_ id: String) -> String? {
        invalidateDrag()
        guard draft.renderableIDs().contains(id) else { return nil }
        let token = UUID().uuidString
        dragToken = token
        dragSource = id
        dragOrder = draft.orderedVisibleProviderIDs
        return token
    }

    @discardableResult
    mutating func drop(token: String, targetID: String, after: Bool) -> Bool {
        guard token == dragToken, let source = dragSource,
            dragOrder == draft.orderedVisibleProviderIDs,
            draft.renderableIDs().contains(targetID),
            var transaction = transaction(for: source)
        else { return false }
        defer { invalidateDrag() }
        if source == targetID { return true }
        transaction.move(before: targetID)
        if after { transaction.step(1) }
        return apply(transaction)
    }

    mutating func move(_ id: String, by offset: Int) {
        invalidateDrag()
        guard var transaction = transaction(for: id) else { return }
        transaction.step(offset)
        _ = apply(transaction)
    }

    mutating func remove(_ id: String) {
        invalidateDrag()
        _ = draft.remove(id)
    }

    mutating func restoreDefault(currentVisible: [String]) {
        invalidateDrag()
        draft.restoreDefault(currentVisible: currentVisible)
    }

    func committed(current: AgentNavigationState) -> AgentNavigationState? {
        guard current == original else { return nil }
        return draft
    }

    private func transaction(for id: String) -> DirectReorderTransaction? {
        DirectReorderTransaction(
            original: draft.orderedVisibleProviderIDs,
            visible: draft.renderableIDs(), source: id,
            knownIDs: Set(AgentNavCatalog.workspaceProviders.map(\.id)))
    }

    private mutating func apply(_ transaction: DirectReorderTransaction) -> Bool {
        guard let result = transaction.committed(current: draft.orderedVisibleProviderIDs) else { return false }
        if result != draft.orderedVisibleProviderIDs {
            draft.orderedVisibleProviderIDs = result
            draft.customized = true
        }
        return true
    }

    private mutating func invalidateDrag() {
        dragToken = nil
        dragSource = nil
        dragOrder = nil
    }
}
