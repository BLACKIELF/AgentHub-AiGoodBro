import Combine
import Darwin
import Foundation

/// A shared one-minute projection for the full workbench and light panel.
/// Only explicit inventory actions invoke Codex; observation never invokes a model.
@MainActor
final class TaskWorkbenchStore: ObservableObject {
    @Published private(set) var presentation: TaskWorkbenchPresentation?
    @Published private(set) var inventoryInFlight = false
    @Published private(set) var status: String?
    private var annotations: [String: TaskWorkbenchAnnotation] = [:]
    private var latestRuntimes: [RuntimeUsageSnapshot] = []
    private var latestLive = CodexTaskLiveSnapshot.disconnected
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private let file: URL?
    private let ledger: WeChatBotEventLedger
    private let conversationFactory: @MainActor () -> WeChatCodexConversation
    private var inventoryTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastBuilt = Date.distantPast

    init(previewOnly: Bool = false, file: URL? = nil,
         conversationFactory: @escaping @MainActor () -> WeChatCodexConversation = { WeChatCodexConversation(timeout: 120) }) {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexAccountManagerNext/TaskWorkbench", isDirectory: true)
        self.file = previewOnly ? nil : (file ?? support.appendingPathComponent("inventory-v1.json"))
        self.ledger = WeChatBotEventLedger(directory: support.appendingPathComponent("Actions", isDirectory: true))
        self.conversationFactory = conversationFactory
        if let file = self.file, FileManager.default.fileExists(atPath: file.path) {
            do {
                try verifyFile(file)
                let data = try Data(contentsOf: file)
                guard data.count <= 1024 * 1024 else { throw TaskWorkbenchInventory.Failure.capacity }
                let saved = try JSONDecoder().decode([String: TaskWorkbenchAnnotation].self, from: data)
                guard saved.count <= 1000, saved.allSatisfy({ Self.validKey($0.key)
                    && ((try? $0.value.inventory?.validated()) != nil || $0.value.inventory == nil) })
                else { throw TaskWorkbenchInventory.Failure.invalid }
                guard saved.allSatisfy({ key, note in
                note.inventory.map { key == RuntimeScope.codex.runtimeId + ":" + $0.threadID } ?? true
            }) else { throw TaskWorkbenchInventory.Failure.invalid }
            annotations = saved
            } catch { status = "工作台记录未能读取，保留原文件；请核对本地结果。" }
        }
    }

    static func preview(_ presentation: TaskWorkbenchPresentation) -> TaskWorkbenchStore {
        let model = TaskWorkbenchStore(previewOnly: true)
        model.presentation = presentation
        return model
    }

    func bind(runtimes: Published<[RuntimeUsageSnapshot]>.Publisher,
              live: Published<CodexTaskLiveSnapshot>.Publisher) {
        guard subscriptions.isEmpty else { return }
        runtimes.combineLatest(live).receive(on: RunLoop.main).sink { [weak self] runtimes, live in
            guard let self else { return }
            self.latestRuntimes = runtimes; self.latestLive = live
            if self.presentation == nil || Date().timeIntervalSince(self.lastBuilt) >= 60 { self.rebuild() }
        }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
        timer?.tolerance = 10
    }

    func rebuild(now: Date = Date()) {
        let overview = TaskOverviewPresentationBuilder.make(runtimeSnapshots: latestRuntimes,
            codexLiveTasks: latestLive, now: now, maximumItems: 1000, includeAllExisting: true)
        var projects: [String: String] = [:]
        let knownIDs = Set(overview.items.map(\.id))
        for runtime in latestRuntimes {
            for task in runtime.snapshot.taskBoard?.columns.flatMap(\.items) ?? [] {
                let key = runtime.scope.runtimeId + ":" + (task.threadID ?? task.id)
                guard knownIDs.contains(key) else { continue }
                let label = task.projectPath.flatMap { $0.isEmpty ? nil : $0 }
                    ?? (task.detail.isEmpty ? "未归类" : task.detail)
                projects[key] = label
            }
        }
        presentation = TaskWorkbenchPresentation.make(overview: overview, projectNames: projects,
            annotations: annotations, now: now)
        lastBuilt = now
    }

    func setDecision(_ decision: TaskManualDecision, for item: TaskWorkbenchItem) {
        guard Self.validKey(item.id), annotations.count < 1000 || annotations[item.id] != nil else { return }
        var saved = annotations
        var note = saved[item.id] ?? TaskWorkbenchAnnotation()
        note.decision = decision; note.decisionAt = Date(); saved[item.id] = note
        do { try persist(saved); annotations = saved; rebuild() }
        catch { status = "后续安排未能保存；原记录未更改。" }
    }

    /// Explicit import is a minimal local result interface. The file contains
    /// bounded inventory only, not a transcript, credentials or remote approvals.
    func importInventory(data: Data, for item: TaskWorkbenchItem) {
        guard item.task.runtimeScope == .codex, let thread = item.task.threadID,
            data.count <= 24 * 1024, let text = String(data: data, encoding: .utf8) else {
            status = "结果文件不符合所选 Codex 聊天。"; return
        }
        do {
            let result = try TaskWorkbenchInventory.parse(text, threadID: thread, sourceTurnID: nil)
            try save(result, for: item.id)
            status = "盘点结果已保存；手动暂缓、取消和完成标记保持有效。"
        } catch { status = "盘点结果未通过校验，未写入。" }
    }

    func inventory(_ item: TaskWorkbenchItem) {
        guard !inventoryInFlight, item.task.runtimeScope == .codex,
            let thread = item.task.threadID, UUID(uuidString: thread) != nil else { return }
        guard (annotations[item.id]?.decision ?? .none) == .none else {
            status = "此任务已被手动暂缓、取消或确认完成；先改为继续关注，才能发起盘点。"; return
        }
        let action = UUID()
        let event: UUID
        do {
            guard let claimed = try ledger.claim(owner: "task-workbench", messageID: action.uuidString, receivedAt: Date())
            else { return }
            event = claimed
        } catch { status = "盘点去重记录不可用，未向 Codex 提交。"; return }
        inventoryInFlight = true
        let epoch = generation
        inventoryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == epoch { self.inventoryInFlight = false; self.inventoryTask = nil } }
            let relay = self.conversationFactory()
            var returnedTurn: String?
            let result = await relay.reply(threadID: thread, eventID: event,
                text: Self.prompt(threadID: thread), shouldContinue: { self.generation == epoch },
                onSubmitted: { turn in
                    do { try self.ledger.mark(event, phase: .submitted, threadID: thread, turnID: turn)
                        returnedTurn = turn; return true } catch { return false }
                })
            guard self.generation == epoch, !Task.isCancelled else { return }
            switch result {
            case .reply(let text):
                do {
                    let value = try TaskWorkbenchInventory.parse(text, threadID: thread, sourceTurnID: returnedTurn)
                    try self.ledger.mark(event, phase: .replyAttempted)
                    try self.save(value, for: item.id)
                    try self.ledger.mark(event, phase: .accepted)
                    self.status = "盘点结果已保存。最终完成仍以你的验收为准。"
                } catch { self.status = "Codex 返回的盘点结果未能校验或保存，请查看原聊天；不会自动重发。" }
            case .busy: self.status = "原聊天正在运行，未发起盘点。"
            case .awaitingHuman: self.status = "原聊天需要你在电脑上确认或补充信息。"
            case .cancelled: break
            case .uncertain, .timedOut:
                try? self.ledger.mark(event, phase: .uncertain)
                self.status = "盘点结果不确定，请查看原聊天；不会自动重发。"
            default: self.status = "暂时无法取得盘点结果，请打开原聊天核对。"
            }
        }
    }

    func stop() {
        generation = UUID(); inventoryTask?.cancel(); inventoryTask = nil
        inventoryInFlight = false; timer?.invalidate(); timer = nil; subscriptions.removeAll()
    }

    private func save(_ inventory: TaskWorkbenchInventory, for key: String) throws {
        guard Self.validKey(key), annotations.count < 1000 || annotations[key] != nil else { throw TaskWorkbenchInventory.Failure.capacity }
        let value = try inventory.validated()
        guard key == RuntimeScope.codex.runtimeId + ":" + value.threadID else { throw TaskWorkbenchInventory.Failure.invalid }
        var saved = annotations
        var note = saved[key] ?? TaskWorkbenchAnnotation()
        if value.sourceTurnID != nil && note.inventory?.sourceTurnID == value.sourceTurnID { return }
        note.inventory = value; saved[key] = note
        try persist(saved); annotations = saved; rebuild()
    }

    private func persist(_ value: [String: TaskWorkbenchAnnotation]) throws {
        guard let file else { return }
        let directory = file.deletingLastPathComponent()
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { throw TaskWorkbenchInventory.Failure.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw TaskWorkbenchInventory.Failure.invalid }
        if FileManager.default.fileExists(atPath: file.path) { try verifyFile(file) }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1024 * 1024 else { throw TaskWorkbenchInventory.Failure.capacity }
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try verifyFile(file)
    }

    private func verifyFile(_ file: URL) throws {
        guard file.resolvingSymlinksInPath().standardizedFileURL.path == file.standardizedFileURL.path else { throw TaskWorkbenchInventory.Failure.invalid }
        var attributes = stat()
        guard lstat(file.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
            attributes.st_uid == geteuid(), attributes.st_nlink == 1, attributes.st_mode & 0o077 == 0,
            attributes.st_size <= 1024 * 1024 else { throw TaskWorkbenchInventory.Failure.invalid }
    }

    private static func validKey(_ key: String) -> Bool { !key.isEmpty && TaskWorkbenchInventory.safeText(key, limit: 512) }
    static func prompt(threadID: String) -> String {
        """
        请仅盘点当前聊天已授权的任务，不继续执行任务，不修改项目文件、不请求新权限。依据本聊天的现有公开证据，区分执行轮次结束与任务成果完成。仅输出一个 JSON 对象，不加 Markdown：
        {"threadID":"\(threadID)","project":"项目名称或未归类","outcome":"unknown|incomplete|candidate|awaitingAcceptance|complete","remaining":["未完成事项，最多8条"],"nextStep":"最小下一步","artifacts":[{"title":"已有成果名称","reference":"已知绝对文件路径或https链接"}],"evidence":"简短说明已测、未测与验收证据"}
        不确定就写unknown，不编造链接、验证或用户批准。每条remaining及nextStep最多200字，evidence最多400字，artifacts最多8条。没有用户验收证据时不判complete；手动暂缓和取消不能被自动恢复。不得输出密钥、token、身份信息或聊天全文。
        """
    }
}
