import AppKit
import SwiftUI

/// The normal product entry for the independent screen-edge dock. Editing an
/// automatic list converts it to an explicit list; an explicit empty list is
/// intentional and never silently replaced by a provider guessed from login.
struct TokenMonitorEdgeDockSettingsView: View {
    @ObservedObject var settings: AppSettings
    let quotaSources: [TokenMonitorFloatingBubbleAccount]
    let language: WidgetLanguage
    @State private var screenOptions: [TokenMonitorEdgeDockScreenCatalog.Option] = []

    private var selectedScreenID: String {
        TokenMonitorEdgeDockScreenTarget.migratedID(
            preferences.displayID, screens: screenOptions.map(\.identity)
        ) ?? ""
    }

    private var unavailableScreenID: String? {
        let selected = selectedScreenID
        guard !selected.isEmpty,
            !screenOptions.contains(where: { $0.id == selected })
        else { return nil }
        return selected
    }

    private var screenBinding: Binding<String> {
        Binding(
            get: { selectedScreenID },
            set: { choice in update { $0.displayID = choice.isEmpty ? nil : choice } }
        )
    }

    private var preferences: TokenMonitorEdgeDockPreferences { settings.edgeDock }

    private var availableProviders: [(id: String, title: String)] {
        var seen = Set<String>()
        return quotaSources.filter { seen.insert(TokenMonitorEdgeDockItem.canonicalProviderID($0.providerID)).inserted }
            .map { (id: TokenMonitorEdgeDockItem.canonicalProviderID($0.providerID), title: $0.providerName) }
    }

    private var defaultItems: [TokenMonitorEdgeDockItem] {
        TokenMonitorEdgeDockProjection.automaticItems(quotaSources)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(language.text("显示侧边栏", "Show Edge Dock"), isOn: binding(\.enabled))
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("edge-dock-enabled")
            Text(
                language.text(
                    "选择多个账号，额度会分别显示在屏幕边缘。悬停查看详情，拖动顶部调整位置；项目较多时可翻页。",
                    "Choose multiple accounts to show their limits separately at the screen edge. Hover for details, drag the top to move, and page through longer lists.")
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 9) {
                Text(language.text("显示方式", "Visibility"))
                    .font(.system(size: 11, weight: .semibold))
                Picker(language.text("显示方式", "Visibility"), selection: binding(\.mode)) {
                    Text(language.text("自动隐藏", "Auto-hide")).tag(TokenMonitorEdgeDockPreferences.Mode.autoHide)
                    Text(language.text("始终显示", "Always visible")).tag(TokenMonitorEdgeDockPreferences.Mode.always)
                }
                .pickerStyle(.segmented).labelsHidden()

                Text(language.text("屏幕边缘", "Screen edge"))
                    .font(.system(size: 11, weight: .semibold))
                Picker(language.text("屏幕边缘", "Screen edge"), selection: binding(\.side)) {
                    Text(language.text("右侧", "Right")).tag(TokenMonitorEdgeDockPreferences.Side.right)
                    Text(language.text("左侧", "Left")).tag(TokenMonitorEdgeDockPreferences.Side.left)
                }
                .pickerStyle(.segmented).labelsHidden()

                Text(language.text("显示屏幕", "Display"))
                    .font(.system(size: 11, weight: .semibold))
                Picker(language.text("显示屏幕", "Display"), selection: screenBinding) {
                    Text(language.text("跟随当前屏幕", "Follow current screen")).tag("")
                    Text(language.text("Mac内置屏幕", "Mac built-in screen"))
                        .tag(TokenMonitorEdgeDockScreenTarget.builtInID)
                    ForEach(screenOptions.filter { !$0.identity.isBuiltIn }) { option in
                        Text(option.title).tag(option.id)
                    }
                    if let unavailableScreenID, unavailableScreenID != TokenMonitorEdgeDockScreenTarget.builtInID {
                        Text(language.text("已选屏幕暂不可用", "Selected screen unavailable"))
                            .tag(unavailableScreenID)
                    }
                }
                .accessibilityIdentifier("edge-dock-display")
                if unavailableScreenID != nil {
                    Text(
                        language.text(
                            "目标屏幕未连接，侧边栏暂时隐藏；重新连接后会恢复，选择不会丢失。",
                            "The selected screen is disconnected. The dock is hidden until it returns; your choice is kept."
                        )
                    )
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            Divider()
            accountComposer
            itemComposer

            Toggle(language.text("触控板轻触反馈", "Trackpad haptics"), isOn: binding(\.hapticEnabled))
                .font(.system(size: 11))
            Toggle(language.text("额度较低时用颜色提示", "Highlight low limits in colour"), isOn: binding(\.warnColors))
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .accessibilityIdentifier("edge-dock-settings")
        .onAppear { screenOptions = TokenMonitorEdgeDockScreenCatalog.options() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            TokenMonitorEdgeDockScreenCatalog.screensChanged()
            screenOptions = TokenMonitorEdgeDockScreenCatalog.options()
        }
    }

    private var accountComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.text("常驻账号", "Pinned accounts"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(language.text("右侧常驻", "Keep on right")) {
                    update { prefs in
                        prefs.enabled = true
                        prefs.mode = .always
                        prefs.side = .right
                    }
                }
                .font(.system(size: 11))
                .accessibilityIdentifier("edge-dock-keep-on-right")
            }
            ForEach(availableProviders, id: \.id) { provider in
                DisclosureGroup(provider.title) {
                    ForEach(quotaSources.filter { TokenMonitorEdgeDockItem.canonicalProviderID($0.providerID) == provider.id }, id: \.accountID) { account in
                        Toggle(account.accountName, isOn: pinnedAccountBinding(account))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .disabled(!isPinned(account) && (preferences.items ?? defaultItems).count >= 24)
                            .accessibilityIdentifier("edge-dock-account-\(account.accountID)")
                    }
                    .padding(.leading, 10)
                }
                .font(.system(size: 11))
            }
            Text(language.text("勾选后独立显示；在下方调整顺序。最多 24 项。", "Selected accounts appear separately. Reorder them below. Up to 24 items."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func isPinned(_ account: TokenMonitorFloatingBubbleAccount) -> Bool {
        (preferences.items ?? defaultItems).contains { $0.id == TokenMonitorEdgeDockItem.account(account.providerID, account.accountID).id }
    }

    private func pinnedAccountBinding(_ account: TokenMonitorFloatingBubbleAccount) -> Binding<Bool> {
        Binding(
            get: { isPinned(account) },
            set: { selected in
                let item = TokenMonitorEdgeDockItem.account(account.providerID, account.accountID)
                update { prefs in
                    var items = prefs.items ?? defaultItems
                    items.removeAll { $0.id == item.id }
                    if selected { items.append(item) }
                    prefs.items = items
                }
            })
    }

    private var itemComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.text("侧边栏项目", "Dock items"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if preferences.items != nil {
                    Button(language.text("恢复自动", "Reset to automatic")) { update { $0.items = nil } }
                        .buttonStyle(.plain).font(.system(size: 10))
                }
            }
            if preferences.items == nil {
                Text(
                    language.text(
                        "自动显示反代入口、今日用量、最多三个额度平台和采样速率。自定义后可移除或调整顺序。",
                        "Automatically show proxy settings, today's usage, up to three limit providers, and sampled rate. Customize to remove or reorder items."
                    )
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(defaultItems, id: \.id) { item in
                    itemLabel(item)
                }
                Button(language.text("自定义这些项目", "Customize these items")) {
                    update { $0.items = defaultItems }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
            } else if let items = preferences.items, items.isEmpty {
                Text(language.text("侧边栏目前没有项目。", "The dock has no items."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let items = preferences.items {
                ForEach(items.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            itemLabel(items[index])
                            Spacer(minLength: 2)
                            Button {
                                moveItem(at: index, by: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .disabled(index == 0)
                            .accessibilityLabel(language.text("上移", "Move up"))
                            Button {
                                moveItem(at: index, by: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(index == items.count - 1)
                            .accessibilityLabel(language.text("下移", "Move down"))
                            Button {
                                removeItem(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .accessibilityLabel(language.text("移除项目", "Remove item"))
                        }
                        .buttonStyle(.plain)
                        if items[index].type == .limit && items[index].accountID == nil {
                            limitItemOptions(items[index])
                        }
                    }
                    .font(.system(size: 10))
                    .padding(.vertical, 2)
                }
            }
            Menu {
                Button {
                    addItem(.proxy())
                } label: {
                    Label(language.text("反代设置", "Proxy settings"), systemImage: "network")
                }
                .disabled((preferences.items ?? defaultItems).contains { $0.type == .proxy })
                Divider()
                ForEach(availableProviders.map(\.id), id: \.self) { providerID in
                    Button(availableProviders.first { $0.id == providerID }?.title ?? providerID) {
                        addItem(.limit(providerID))
                    }
                }
                Divider()
                ForEach(TokenMonitorEdgeDockItem.Metric.allCases) { metric in
                    Button(metric.title(language)) { addItem(.stat(metric)) }
                }
            } label: {
                Label(language.text("添加项目", "Add item"), systemImage: "plus.circle")
            }
            .font(.system(size: 10))
            .disabled((preferences.items ?? defaultItems).count >= 24)
            Text(language.text("网络图标打开反代设置；移除图标不会停止反代。", "The network icon opens proxy settings. Removing it does not stop the proxy."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(language.text("数据按分钟更新；采样速率没有可信记录时显示“—”。", "Data updates at minute intervals. Sampled rate shows a dash until a verified sample exists."))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func itemLabel(_ item: TokenMonitorEdgeDockItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.type == .proxy ? "network" : item.type == .stat ? "chart.bar.xaxis" : "circle.dotted.circle")
                .frame(width: 14)
            Text(
                item.type == .stat
                    ? (item.metric?.title(language) ?? "—")
                    : itemTitle(item)
            )
            .lineLimit(1)
            if item.metric == .liveRate {
                Text(language.text("可用时", "when available"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10))
    }

    private func itemTitle(_ item: TokenMonitorEdgeDockItem) -> String {
        if item.type == .proxy { return language.text("反代设置", "Proxy settings") }
        let provider = availableProviders.first { $0.id == item.providerID }?.title ?? item.providerID ?? "—"
        guard let accountID = item.accountID else { return provider }
        let account = quotaSources.first { TokenMonitorEdgeDockItem.canonicalProviderID($0.providerID) == item.providerID && $0.accountID == accountID }
        return account.map { "\(provider) · \($0.accountName)" } ?? language.text("账号不可用", "Account unavailable")
    }

    private func limitItemOptions(_ item: TokenMonitorEdgeDockItem) -> some View {
        DisclosureGroup(language.text("额度项目选项", "Limit item options")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    language.text("详情卡显示 Token 用量", "Show token usage in card"),
                    isOn: itemBinding(item, \.showUsage))
                if item.providerID == AgentNavCatalog.codexID {
                    Toggle(
                        language.text("详情卡显示最近会话", "Show recent sessions in card"),
                        isOn: itemBinding(item, \.showSessions))
                    Picker(language.text("额度栏显示", "Rail value"), selection: itemBinding(item, \.accountMode)) {
                        Text(language.text("当前账号", "Current account")).tag(TokenMonitorEdgeDockItem.AccountMode.active)
                        Text(language.text("最低额度", "Lowest visible allowance")).tag(TokenMonitorEdgeDockItem.AccountMode.lowest)
                    }
                    .pickerStyle(.menu)
                }
                ForEach(quotaSources.filter { TokenMonitorEdgeDockItem.canonicalProviderID($0.providerID) == item.providerID }, id: \.accountID) { account in
                    Toggle(account.accountName, isOn: accountVisibilityBinding(itemID: item.id, accountID: account.accountID))
                }
            }
            .padding(.leading, 12)
            .padding(.vertical, 4)
        }
        .font(.system(size: 10))
    }

    private func itemBinding<Value: Equatable>(
        _ item: TokenMonitorEdgeDockItem, _ keyPath: WritableKeyPath<TokenMonitorEdgeDockItem, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                ((settings.edgeDock.items ?? defaultItems).first { $0.id == item.id } ?? item)[keyPath: keyPath]
            },
            set: { value in
                update { prefs in
                    var items = prefs.items ?? defaultItems
                    guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
                    items[index][keyPath: keyPath] = value
                    prefs.items = items
                }
            })
    }

    private func accountVisibilityBinding(itemID: String, accountID: String) -> Binding<Bool> {
        Binding(
            get: {
                !((settings.edgeDock.items ?? defaultItems).first { $0.id == itemID }?.hiddenAccountIDs.contains(accountID) ?? false)
            },
            set: { visible in
                update { prefs in
                    var items = prefs.items ?? defaultItems
                    guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
                    var hidden = Set(items[index].hiddenAccountIDs)
                    if visible { hidden.remove(accountID) } else { hidden.insert(accountID) }
                    items[index].hiddenAccountIDs = Array(hidden).sorted()
                    prefs.items = items
                }
            })
    }

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<TokenMonitorEdgeDockPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { settings.edgeDock[keyPath: keyPath] },
            set: { value in
                var next = settings.edgeDock
                next[keyPath: keyPath] = value
                settings.edgeDock = next.normalized()
            })
    }

    private func update(_ body: (inout TokenMonitorEdgeDockPreferences) -> Void) {
        var next = settings.edgeDock
        body(&next)
        settings.edgeDock = next.normalized()
    }

    private func addItem(_ item: TokenMonitorEdgeDockItem) {
        update { prefs in
            var items = prefs.items ?? defaultItems
            guard !items.contains(where: { $0.id == item.id }) else { return }
            items.append(item)
            prefs.items = items
        }
    }

    private func removeItem(at index: Int) {
        update { prefs in
            var items = prefs.items ?? defaultItems
            guard items.indices.contains(index) else { return }
            items.remove(at: index)
            prefs.items = items
        }
    }

    private func moveItem(at index: Int, by offset: Int) {
        update { prefs in
            var items = prefs.items ?? defaultItems
            let destination = index + offset
            guard items.indices.contains(index), items.indices.contains(destination) else { return }
            items.swapAt(index, destination)
            prefs.items = items
        }
    }
}
