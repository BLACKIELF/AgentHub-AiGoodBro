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

    func position(of id: String) -> Int? {
        orderedVisibleIDs.firstIndex(of: id).map { $0 + 1 }
    }

    @discardableResult
    mutating func move(_ id: String, toPosition position: Int) -> Bool {
        guard isValid, let index = orderedVisibleIDs.firstIndex(of: id),
            (1...orderedVisibleIDs.count).contains(position)
        else { return false }
        invalidateDrag()
        orderedVisibleIDs.remove(at: index)
        orderedVisibleIDs.insert(id, at: position - 1)
        return true
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
    @State private var editingPositionID: String?
    @State private var targetPositionText = ""
    @State private var positionError = false
    @FocusState private var isPositionFieldFocused: Bool

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
            Text(language.text(
                "序号是当前展示顺序。点击序号输入目标位置，也可用箭头；保存后按新顺序展示，额度刷新不会改变顺序。",
                "Numbers show the current display order. Click one to enter a new position, or use the arrows. The saved order remains stable when usage refreshes."
            ))
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
            if positionError {
                Text(language.text(
                    "请输入 1 到 \(draft.orderedVisibleIDs.count) 之间的序号。",
                    "Enter a position from 1 to \(draft.orderedVisibleIDs.count)."
                ))
                .font(.callout)
                .foregroundStyle(.red)
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
                    .disabled(!draft.hasChanges && !hasPendingPositionChange)
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 560)
        .onDisappear { draft = AccountOrderSheetDraft(visibleIDs: [], originalAllIDs: []) }
    }

    private func accountRow(_ id: String) -> some View {
        HStack(spacing: 4) {
            if editingPositionID == id {
                TextField(language.text("序号", "Position"), text: $targetPositionText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .focused($isPositionFieldFocused)
                    .onSubmit { applyPosition(id) }
                    .onAppear { isPositionFieldFocused = true }
                    .accessibilityLabel(language.text("目标序号", "Target position"))
                    .accessibilityIdentifier("account-order-position-entry-" + id)
                Button(language.text("移动", "Move")) { applyPosition(id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("account-order-position-apply-" + id)
            } else {
                Button(positionLabel(for: id)) { beginPositionEdit(id) }
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .buttonStyle(.bordered)
                    .accessibilityLabel(language.text(
                        "\(items.first(where: { $0.id == id })?.title ?? "账号")：第 \(draft.position(of: id) ?? 0) 位，点击输入目标序号",
                        "\(items.first(where: { $0.id == id })?.title ?? "Account"): position \(draft.position(of: id) ?? 0), click to enter a target position"
                    ))
                    .accessibilityIdentifier("account-order-position-" + id)
            }
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
            .accessibilityHint(language.text("点击序号输入目标位置，或使用上移和下移按钮", "Enter a target position or use the move up and move down buttons"))
            .accessibilityAction(named: Text(language.text("向上移动", "Move up"))) { moveByOne(id, offset: -1) }
            .accessibilityAction(named: Text(language.text("向下移动", "Move down"))) { moveByOne(id, offset: 1) }
            HStack(spacing: 6) {
                Button {
                    moveByOne(id, offset: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(draft.orderedVisibleIDs.first == id)
                .accessibilityLabel(language.text("向上移动", "Move up"))
                Button {
                    moveByOne(id, offset: 1)
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

    private func positionLabel(for id: String) -> String {
        let position = draft.position(of: id) ?? 0
        return position < 10 ? "0\(position)" : String(position)
    }

    private var hasPendingPositionChange: Bool {
        guard let id = editingPositionID,
            let position = Int(targetPositionText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return draft.position(of: id) != position
    }

    private func beginPositionEdit(_ id: String) {
        guard let position = draft.position(of: id) else { return }
        editingPositionID = id
        targetPositionText = String(position)
        positionError = false
    }

    private func applyPosition(_ id: String) {
        let entered = targetPositionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let position = Int(entered), draft.move(id, toPosition: position) else {
            positionError = true
            return
        }
        editingPositionID = nil
        targetPositionText = ""
        isPositionFieldFocused = false
        positionError = false
        saveFailed = false
    }

    private func moveByOne(_ id: String, offset: Int) {
        editingPositionID = nil
        isPositionFieldFocused = false
        targetPositionText = ""
        positionError = false
        draft.move(id, by: offset)
        saveFailed = false
    }

    private func save() {
        if let editingPositionID {
            applyPosition(editingPositionID)
            guard !positionError else { return }
        }
        guard let fullOrder = draft.fullOrder(currentAllIDs: draft.originalAllIDs),
            onSave(fullOrder, draft.originalAllIDs)
        else {
            saveFailed = true
            return
        }
        saveFailed = false
    }
}
