import SwiftUI

/// The normal product entry for the independent screen-edge dock. Editing an
/// automatic list converts it to an explicit list; an explicit empty list is
/// intentional and never silently replaced by a provider guessed from login.
struct TokenMonitorEdgeDockSettingsView: View {
    @ObservedObject var settings: AppSettings
    let quotaSources: [TokenMonitorFloatingBubbleAccount]
    let language: WidgetLanguage

    private var preferences: TokenMonitorEdgeDockPreferences { settings.edgeDock }

    private var availableProviders: [(id: String, title: String)] {
        var seen = Set<String>()
        return quotaSources.filter { $0.isLoggedIn && seen.insert($0.providerID).inserted }
            .map { (id: $0.providerID, title: $0.providerName) }
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
                    "从屏幕右缘向内移动指针可展开额度与用量栏；悬停查看详情，点击固定栏体，拖动顶部可换边或调整高度。",
                    "Push the pointer into the screen edge to reveal limits and usage. Hover for details, click to pin the rail, or drag its top to move it.")
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
            }

            Divider()
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
                        "自动显示今日用量、最多三个已连接额度平台与可信实时速率；总计可在下方添加。", "Automatically show today's usage, up to three connected limit providers, and verified live rate. Add Total below."
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
                        if items[index].type == .limit {
                            limitItemOptions(items[index])
                        }
                    }
                    .font(.system(size: 10))
                    .padding(.vertical, 2)
                }
            }
            Menu {
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
                Label(language.text("添加额度或用量项目", "Add limit or usage item"), systemImage: "plus.circle")
            }
            .font(.system(size: 10))
            Text(language.text("实时速率尚无可信采样时显示“—”，不会推算数值。", "Live rate shows a dash until a verified sample exists."))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func itemLabel(_ item: TokenMonitorEdgeDockItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.type == .stat ? "chart.bar.xaxis" : "circle.dotted.circle")
                .frame(width: 14)
            Text(
                item.type == .stat
                    ? (item.metric?.title(language) ?? "—")
                    : (availableProviders.first { $0.id == item.providerID }?.title ?? item.providerID ?? "—")
            )
            .lineLimit(1)
            if item.metric == .liveRate {
                Text(language.text("可用时", "when available"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10))
    }

    private func limitItemOptions(_ item: TokenMonitorEdgeDockItem) -> some View {
        DisclosureGroup(language.text("额度项目选项", "Limit item options")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    language.text("详情卡显示 Token 用量", "Show token usage in card"),
                    isOn: itemBinding(item, \.showUsage))
                Toggle(
                    language.text("详情卡显示最近会话", "Show recent sessions in card"),
                    isOn: itemBinding(item, \.showSessions))
                if item.providerID == AgentNavCatalog.codexID {
                    Picker(language.text("额度栏显示", "Rail value"), selection: itemBinding(item, \.accountMode)) {
                        Text(language.text("当前账号", "Current account")).tag(TokenMonitorEdgeDockItem.AccountMode.active)
                        Text(language.text("最低额度", "Lowest visible allowance")).tag(TokenMonitorEdgeDockItem.AccountMode.lowest)
                    }
                    .pickerStyle(.menu)
                }
                ForEach(quotaSources.filter { $0.providerID == item.providerID }, id: \.accountID) { account in
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
