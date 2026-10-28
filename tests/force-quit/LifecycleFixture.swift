import Darwin
import Foundation

// The runner inserts the exact watchdog and applicationShouldTerminate from
// AppLifecycle.swift. These substitutes model only surrounding AppKit/stores.
// __PRODUCTION_WATCHDOG__

@MainActor enum FixtureState {
    static var events: [String] = []
    static var alertCount = 0
    static var alertTitle = ""
    static var alertExplanation = ""
    static var buttons: [String] = []
    static var modal: CheckedContinuation<NSApplication.ModalResponse, Never>?
    static var selected = NSApplication.ModalResponse.alertFirstButtonReturn
    static var holdModal = true
    static var blockReply = false
    static var blockLogin = false
    static func reset() {
        events = []; alertCount = 0; alertTitle = ""; alertExplanation = ""; buttons = []; modal = nil
        selected = .alertFirstButtonReturn; holdModal = true; blockReply = false; blockLogin = false
    }
}
@MainActor final class NSApplication {
    enum TerminateReply: Equatable { case terminateCancel, terminateLater }
    struct ModalResponse: Equatable {
        let raw: Int
        static let alertFirstButtonReturn = Self(raw: 1)
        static let alertSecondButtonReturn = Self(raw: 2)
    }
    func reply(toApplicationShouldTerminate value: Bool) {
        FixtureState.events.append(value ? "reply:true" : "reply:false")
        if FixtureState.blockReply {
            print("REPLY_BLOCKED_MAIN")
            Thread.sleep(forTimeInterval: 30)
        }
    }
}
@MainActor final class NSAlert {
    enum Style { case warning }
    var alertStyle: Style = .warning
    var messageText = "" { didSet { FixtureState.alertTitle = messageText } }
    var informativeText = "" { didSet { FixtureState.alertExplanation = informativeText } }
    init() { FixtureState.alertCount += 1 }
    func addButton(withTitle: String) { FixtureState.buttons.append(withTitle) }
    @discardableResult func beginSheetModal(for: FakeWindow) async -> NSApplication.ModalResponse {
        if !FixtureState.holdModal { return FixtureState.selected }
        return await withCheckedContinuation { FixtureState.modal = $0 }
    }
    @discardableResult func runModal() -> NSApplication.ModalResponse { FixtureState.selected }
}
struct FakeWindow { var isVisible = true }
struct Language { func text(_ zh: String, _ en: String) -> String { zh } }
struct Settings { var language = Language() }
@MainActor final class FakeUsageStore {
    var isLaunchingCodex = false
    var isLoggingIn = false
    func cancelLogin() {
        FixtureState.events.append("cancel:login")
        if FixtureState.blockLogin {
            if FixtureState.events == ["force:local", "force:anti", "force:token", "cancel:login"] {
                print("LOGIN_BLOCKED_AFTER_OWNED_HELPERS")
            }
            Thread.sleep(forTimeInterval: 30)
        }
    }
    func finishLoginForTermination() async { FixtureState.events.append("normal:login") }
}
@MainActor final class FakeLocalProxy {
    var requiresStopConfirmation = false
    var canFinishTermination = true
    var issue: String? = nil
    func forceStopForConfirmedTermination() { FixtureState.events.append("force:local") }
    func finishForTermination() async { FixtureState.events.append("normal:local") }
    func resumeAfterCancelledTermination() { FixtureState.events.append("resume:local") }
}
@MainActor final class AntigravityProxyStore {
    static let shared = AntigravityProxyStore()
    var canFinishTermination = true
    func forceStopForConfirmedTermination() { FixtureState.events.append("force:anti") }
    func finishForTermination() async { FixtureState.events.append("normal:anti") }
}
@MainActor final class FakeTokenDesktop {
    func forceStopForConfirmedTermination() { FixtureState.events.append("force:token") }
}
@MainActor final class FixtureDelegate {
    let store = FakeUsageStore()
    let localProxy = FakeLocalProxy()
    let tokenDesktop = FakeTokenDesktop()
    var settings = Settings()
    var window: FakeWindow? = FakeWindow()
    var terminationTask: Task<Void, Never>?
    // __PRODUCTION_TERMINATION__
}

enum FixtureFailure: Error { case failed(String) }
@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure.failed(message) }
}
@MainActor func wait(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try require(condition(), "timed out waiting for callback")
}
@MainActor func makeConfirmed() async throws -> (FixtureDelegate, NSApplication) {
    FixtureState.reset()
    let delegate = FixtureDelegate(), sender = NSApplication()
    delegate.localProxy.requiresStopConfirmation = true
    delegate.localProxy.canFinishTermination = false
    AntigravityProxyStore.shared.canFinishTermination = false
    delegate.store.isLoggingIn = true
    try require(delegate.applicationShouldTerminate(sender) == .terminateLater, "initial quit must await confirmation")
    try await wait { FixtureState.modal != nil }
    try require(FixtureState.alertTitle == "强制退出并停止反代？", "forced quit title")
    try require(FixtureState.alertExplanation.contains("强制退出会中断正在回复的任务，尚未保存的状态可能丢失"), "forced quit warning")
    try require(FixtureState.buttons == ["取消", "强制退出"], "forced quit button semantics")
    try require(delegate.applicationShouldTerminate(sender) == .terminateLater, "duplicate must join one prompt")
    try require(FixtureState.alertCount == 1, "duplicate prompt")
    let modal = FixtureState.modal; FixtureState.modal = nil
    modal?.resume(returning: .alertSecondButtonReturn)
    return (delegate, sender)
}

@main enum FixtureMain {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        switch CommandLine.arguments[1] {
        case "cancel":
            FixtureState.reset()
            let delegate = FixtureDelegate(), sender = NSApplication()
            delegate.localProxy.requiresStopConfirmation = true
            delegate.store.isLoggingIn = true
            AntigravityProxyStore.shared.canFinishTermination = false
            try require(delegate.applicationShouldTerminate(sender) == .terminateLater, "cancel prompt")
            try await wait { FixtureState.modal != nil }
            try require(delegate.applicationShouldTerminate(sender) == .terminateLater && FixtureState.alertCount == 1, "single pending prompt")
            let modal = FixtureState.modal; FixtureState.modal = nil
            modal?.resume(returning: .alertFirstButtonReturn)
            try await wait { FixtureState.events.contains("reply:false") }
            try require(FixtureState.events == ["reply:false"] && delegate.terminationTask == nil, "cancel touched running work")
            // A mistakenly armed real watchdog would terminate this isolated process
            // before the marker, without an explicit assertion failure.
            try await Task.sleep(nanoseconds: 5_300_000_000)
            print("PASS cancellation keeps helpers running and arms no watchdog")
        case "guard":
            FixtureState.reset()
            let delegate = FixtureDelegate(), sender = NSApplication()
            delegate.store.isLaunchingCodex = true
            delegate.localProxy.requiresStopConfirmation = true
            try require(delegate.applicationShouldTerminate(sender) == .terminateCancel, "launch guard changed")
            try require(FixtureState.events.isEmpty && FixtureState.alertCount == 0 && delegate.terminationTask == nil, "launch guard performed side effects")
            print("PASS existing active Codex launch guard is preserved")
        case "normal":
            FixtureState.reset()
            let delegate = FixtureDelegate(), sender = NSApplication()
            delegate.store.isLoggingIn = true
            AntigravityProxyStore.shared.canFinishTermination = true
            try require(delegate.applicationShouldTerminate(sender) == .terminateLater, "normal path")
            try await wait { FixtureState.events.contains("reply:true") }
            try require(FixtureState.alertCount == 0 && FixtureState.events == ["normal:login", "normal:local", "normal:anti", "reply:true"], "normal termination changed")
            print("PASS unconfirmed normal termination keeps original cleanup")
        case "confirm":
            let (delegate, sender) = try await makeConfirmed()
            try await wait { FixtureState.events.contains("reply:true") }
            try require(FixtureState.events == ["force:local", "force:anti", "force:token", "cancel:login", "reply:true"], "confirmation waited on normal cleanup or missed exact stops")
            try require(!delegate.localProxy.canFinishTermination && !AntigravityProxyStore.shared.canFinishTermination, "fixture lost simulated cleanup failure")
            try require(delegate.applicationShouldTerminate(sender) == .terminateLater && FixtureState.alertCount == 1, "confirmed repeat rearmed quit")
            print("PASS confirmation bypasses failed cleanup and does not wait for login")
        case "modal":
            FixtureState.reset()
            let delegate = FixtureDelegate(), sender = NSApplication()
            delegate.window = nil
            delegate.localProxy.requiresStopConfirmation = true
            FixtureState.selected = .alertSecondButtonReturn
            try require(delegate.applicationShouldTerminate(sender) == .terminateLater, "windowless quit")
            try await wait { FixtureState.events.contains("reply:true") }
            try require(FixtureState.events == ["force:local", "force:anti", "force:token", "reply:true"], "windowless confirmation")
            try require(FixtureState.buttons == ["取消", "强制退出"], "windowless confirmation buttons")
            print("PASS windowless confirmation takes the same forced exit path")
        case "blocked":
            FixtureState.blockReply = true
            FixtureState.reset()
            let delegate = FixtureDelegate(), sender = NSApplication()
            delegate.localProxy.requiresStopConfirmation = true
            FixtureState.holdModal = false
            FixtureState.selected = .alertSecondButtonReturn
            FixtureState.blockReply = true
            _ = delegate.applicationShouldTerminate(sender)
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw FixtureFailure.failed("watchdog did not exit blocked process")
        case "blocked-login":
            FixtureState.reset()
            let delegate = FixtureDelegate(), sender = NSApplication()
            delegate.localProxy.requiresStopConfirmation = true
            delegate.store.isLoggingIn = true
            FixtureState.holdModal = false
            FixtureState.selected = .alertSecondButtonReturn
            FixtureState.blockLogin = true
            _ = delegate.applicationShouldTerminate(sender)
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw FixtureFailure.failed("watchdog did not exit blocked login cancellation")
        case "repeat-deadline":
            let (delegate, sender) = try await makeConfirmed()
            try await wait { FixtureState.events.contains("reply:true") }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try require(delegate.applicationShouldTerminate(sender) == .terminateLater, "duplicate response")
            try require(FixtureState.events.filter { $0 == "force:local" }.count == 1 && FixtureState.alertCount == 1, "repeated stop")
            print("REPEAT_2S_BLOCKED_MAIN")
            Darwin.sleep(30)
            throw FixtureFailure.failed("watchdog did not exit blocked process")
        default: throw FixtureFailure.failed("unknown mode")
        }
    }
}
