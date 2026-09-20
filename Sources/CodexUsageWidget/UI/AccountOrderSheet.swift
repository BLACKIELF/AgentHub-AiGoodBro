import SwiftUI
import UniformTypeIdentifiers

/// A local draft. Saving still requires the store to compare the expected full order.
struct AccountOrderSheetDraft {
    let originalAllIDs: [String]
    let originalVisibleIDs: [String]
    private(set) var orderedVisibleIDs: [String]
    private var dragToken: String?
    private var dragSource: String?
    private var dragOrder: [String]?

    init(visibleIDs: [String], originalAllIDs: [String]) {
        self.originalAllIDs = originalAllIDs
        self.originalVisibleIDs = visibleIDs
        self.orderedVisibleIDs = visibleIDs
    }

    var isValid: Bool {
        Set(originalAllIDs).count == originalAllIDs.count
            && Set(originalVisibleIDs).count == originalVisibleIDs.count
            && originalAllIDs.allSatisfy { !$0.isEmpty }
            && Set(originalVisibleIDs).isSubset(of: Set(originalAllIDs))
            && orderedVisibleIDs.count == originalVisibleIDs.count
            && Set(orderedVisibleIDs) == Set(originalVisibleIDs)
    }

    var hasChanges: Bool { isValid && orderedVisibleIDs != originalVisibleIDs }

    mutating func move(from offsets: IndexSet, to destination: Int) {
        invalidateDrag()
        guard isValid, offsets.allSatisfy({ orderedVisibleIDs.indices.contains($0) }),
            (0...orderedVisibleIDs.count).contains(destination)
        else { return }
        orderedVisibleIDs.move(fromOffsets: offsets, toOffset: destination)
    }

    var isDragging: Bool { dragToken != nil }

    mutating func beginDragging(_ id: String) -> String? {
        invalidateDrag()
        guard isValid, orderedVisibleIDs.contains(id) else { return nil }
        let token = UUID().uuidString
        dragToken = token
        dragSource = id
        dragOrder = orderedVisibleIDs
        return token
    }

    @discardableResult
    mutating func drop(token: String, targetID: String, after: Bool) -> Bool {
        guard isValid, token == dragToken, let source = dragSource,
            dragOrder == orderedVisibleIDs, orderedVisibleIDs.contains(targetID)
        else { return false }
        defer { invalidateDrag() }
        guard source != targetID else { return true }
        orderedVisibleIDs.removeAll { $0 == source }
        let target = orderedVisibleIDs.firstIndex(of: targetID)!
        orderedVisibleIDs.insert(source, at: target + (after ? 1 : 0))
        return true
    }

    mutating func move(_ id: String, by offset: Int) {
        invalidateDrag()
        guard isValid, let index = orderedVisibleIDs.firstIndex(of: id),
            orderedVisibleIDs.indices.contains(index + offset)
        else { return }
        orderedVisibleIDs.swapAt(index, index + offset)
    }

    private mutating func invalidateDrag() {
        dragToken = nil
        dragSource = nil
        dragOrder = nil
    }

    func fullOrder(currentAllIDs: [String]) -> [String]? {
        guard isValid, let first = orderedVisibleIDs.first,
            let transaction = DirectReorderTransaction(
                original: originalAllIDs, visible: orderedVisibleIDs,
                source: first, knownIDs: Set(originalAllIDs))
        else { return nil }
        return transaction.committed(current: currentAllIDs)
    }
}

@MainActor
struct AccountOrderSheet: View {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
    }

    struct Request: Identifiable {
        let id = UUID()
        let items: [Item]
        let originalAllIDs: [String]
    }

    let items: [Item]
    let language: WidgetLanguage
    let onSave: ([String], [String]) -> Bool
    let onCancel: () -> Void
    @State private var draft: AccountOrderSheetDraft
    @State private var saveFailed = false

    init(
        items: [Item], originalAllIDs: [String], language: WidgetLanguage,
        onSave: @escaping ([String], [String]) -> Bool, onCancel: @escaping () -> Void
    ) {
        self.items = items
        self.language = language
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: AccountOrderSheetDraft(visibleIDs: items.map(\.id), originalAllIDs: originalAllIDs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("调整 Codex 账号顺序", "Reorder Codex accounts"))
                .font(.title3.weight(.semibold))
            Text(language.text("点击箭头，每次移动一位；保存后生效。置顶账号仍优先显示。", "Move one position per click, then save. Pinned accounts still appear first."))
                .font(.callout)
                .foregroundStyle(.secondary)
            if !draft.isValid {
                Text(language.text("账号列表无效，请取消后重新打开。", "The account list is invalid. Cancel and reopen this sheet."))
                    .foregroundStyle(.red)
            } else if draft.orderedVisibleIDs.isEmpty {
                Text(language.text("没有可调整的 Codex 账号。", "No Codex accounts to reorder."))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(draft.orderedVisibleIDs, id: \.self) { id in
                            accountRow(id)
                        }
                    }
                }
                .frame(minHeight: 180, idealHeight: 280, maxHeight: 420)
            }
            if saveFailed {
                Text(
                    language.text(
                        "未保存。账号列表可能已变化，或当前无法写入；请取消后重新打开重试。",
                        "Not saved. The account list may have changed, or saving is unavailable. Cancel and reopen to retry."
                    )
                )
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(language.text("取消", "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(language.text("保存", "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.hasChanges)
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 560)
        .onDisappear { draft = AccountOrderSheetDraft(visibleIDs: [], originalAllIDs: []) }
    }

    private func accountRow(_ id: String) -> some View {
        HStack(spacing: 4) {
            HStack {
                Text(verbatim: items.first(where: { $0.id == id })?.title ?? language.text("账号", "Account"))
                    .lineLimit(2)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(items.first(where: { $0.id == id })?.title ?? language.text("账号", "Account"))
            .accessibilityIdentifier("account-order-" + id)
            .accessibilityHint(language.text("使用上移或下移按钮调整顺序", "Use the move up or move down buttons"))
            .accessibilityAction(named: Text(language.text("向上移动", "Move up"))) { draft.move(id, by: -1) }
            .accessibilityAction(named: Text(language.text("向下移动", "Move down"))) { draft.move(id, by: 1) }
            HStack(spacing: 6) {
                Button {
                    draft.move(id, by: -1)
                    saveFailed = false
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(draft.orderedVisibleIDs.first == id)
                .accessibilityLabel(language.text("向上移动", "Move up"))
                Button {
                    draft.move(id, by: 1)
                    saveFailed = false
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(draft.orderedVisibleIDs.last == id)
                .accessibilityLabel(language.text("向下移动", "Move down"))
            }
            .buttonStyle(.bordered)
            .padding(.trailing, 10)
        }
        .frame(height: 40)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func save() {
        guard let fullOrder = draft.fullOrder(currentAllIDs: draft.originalAllIDs),
            onSave(fullOrder, draft.originalAllIDs)
        else {
            saveFailed = true
            return
        }
        saveFailed = false
    }
}
