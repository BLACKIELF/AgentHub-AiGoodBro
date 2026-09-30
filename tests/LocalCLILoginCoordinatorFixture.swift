import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw FixtureFailure.failed(message) }
}

/// Thread-safe record of which parked capability stages observed a
/// cancellation request on the awaiting driver task. The `onCancel` handler
/// runs synchronously inside the suspended task, so a recorded stage proves
/// the coordinator actually asked that task to stop.
private final class CancellationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var observedStages: Set<String> = []

    func record(_ stage: String) {
        lock.lock()
        observedStages.insert(stage)
        lock.unlock()
    }

    func observed(_ stage: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedStages.contains(stage)
    }
}

private actor CapabilityHarness {
    let receipt = LocalCLILoginLaunchReceipt(source: "synthetic official launcher")
    let cancellationLog = CancellationLog()
    var installed = true
    var identities: [LocalCLILoginIdentityEvidence]
    var quota: LocalCLILoginQuotaEvidence
    var models: [String: LocalCLILoginModelEvidence]
    var blockLaunch: Bool
    private var holdDetect = false
    private var holdIdentity = false
    private var holdQuota = false
    private var holdModel = false
    private var detectContinuation: CheckedContinuation<LocalCLILoginDetectionEvidence, Never>?
    private var identityContinuation: CheckedContinuation<LocalCLILoginIdentityEvidence, Never>?
    private var launchContinuation: CheckedContinuation<LocalCLILoginLaunchReceipt, Never>?
    private var quotaContinuation: CheckedContinuation<LocalCLILoginQuotaEvidence, Never>?
    private var modelContinuation: CheckedContinuation<LocalCLILoginModelEvidence, Never>?
    private(set) var launchCount = 0
    private(set) var cancelCount = 0
    private(set) var identityCalls = 0
    private(set) var modelCalls: [String] = []

    init(
        identities: [LocalCLILoginIdentityEvidence],
        quota: LocalCLILoginQuotaEvidence = .init(status: .unverified),
        models: [String: LocalCLILoginModelEvidence] = [:],
        blockLaunch: Bool = false
    ) {
        self.identities = identities
        self.quota = quota
        self.models = models
        self.blockLaunch = blockLaunch
    }

    enum Gate {
        case detect
        case identity
        case quota
        case model
    }

    /// Parks the next call of the gated stage on a continuation until
    /// `resume` supplies the answer. Released stages answer immediately.
    func hold(_ gate: Gate) {
        switch gate {
        case .detect: holdDetect = true
        case .identity: holdIdentity = true
        case .quota: holdQuota = true
        case .model: holdModel = true
        }
    }

    /// Stops holding future calls. A parked continuation stays resumable so a
    /// test can deliver the provider's late answer after a retry began.
    func unhold(_ gate: Gate) {
        switch gate {
        case .detect: holdDetect = false
        case .identity: holdIdentity = false
        case .quota: holdQuota = false
        case .model: holdModel = false
        }
    }

    func observed(_ stage: String) -> Bool {
        cancellationLog.observed(stage)
    }

    func detect(_: LocalCLILoginTarget) async -> LocalCLILoginDetectionEvidence {
        if holdDetect {
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { detectContinuation = $0 }
            }, onCancel: {
                cancellationLog.record("detect")
            })
        }
        return .init(installed: installed, source: "synthetic detector")
    }

    func discoverIdentity(_: LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence {
        identityCalls += 1
        if holdIdentity {
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { identityContinuation = $0 }
            }, onCancel: {
                cancellationLog.record("identity")
            })
        }
        guard !identities.isEmpty else { return .missing }
        if identities.count == 1 { return identities[0] }
        return identities.removeFirst()
    }

    func startAuthorization(_: LocalCLILoginTarget) async -> LocalCLILoginLaunchReceipt {
        launchCount += 1
        guard blockLaunch else { return receipt }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { launchContinuation = $0 }
        }, onCancel: {
            cancellationLog.record("launch")
        })
    }

    func resumeLaunch() {
        blockLaunch = false
        launchContinuation?.resume(returning: receipt)
        launchContinuation = nil
    }

    func cancelAuthorization(_: LocalCLILoginTarget, _: LocalCLILoginLaunchReceipt) {
        cancelCount += 1
    }

    func readQuota(_: LocalCLILoginTarget) async -> LocalCLILoginQuotaEvidence {
        if holdQuota {
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { quotaContinuation = $0 }
            }, onCancel: {
                cancellationLog.record("quota")
            })
        }
        return quota
    }

    func verifyModel(_: LocalCLILoginTarget, model: String) async -> LocalCLILoginModelEvidence {
        modelCalls.append(model)
        if holdModel {
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { modelContinuation = $0 }
            }, onCancel: {
                cancellationLog.record("model")
            })
        }
        return models[model] ?? .init(model: model, status: .unverified)
    }

    func resumeDetect() {
        detectContinuation?.resume(
            returning: .init(installed: installed, source: "synthetic detector"))
        detectContinuation = nil
    }

    func resumeIdentity(_ evidence: LocalCLILoginIdentityEvidence) {
        identityContinuation?.resume(returning: evidence)
        identityContinuation = nil
    }

    func resumeQuota() {
        quotaContinuation?.resume(returning: quota)
        quotaContinuation = nil
    }

    func resumeModel(_ model: String) {
        modelContinuation?.resume(
            returning: models[model] ?? .init(model: model, status: .unverified))
        modelContinuation = nil
    }

    func counts() -> (launch: Int, cancel: Int, model: Int) {
        (launchCount, cancelCount, modelCalls.count)
    }
}

private func capability(
    provider: LocalCLILoginProvider = .grok,
    harness: CapabilityHarness,
    descriptor: LocalCLILoginCapabilityDescriptor? = nil
) -> LocalCLILoginCapabilityAdapter {
    LocalCLILoginCapabilityAdapter(
        descriptor: descriptor ?? .official(for: provider),
        detect: { await harness.detect($0) },
        discoverIdentity: { await harness.discoverIdentity($0) },
        startAuthorization: { await harness.startAuthorization($0) },
        cancelAuthorization: { await harness.cancelAuthorization($0, $1) },
        readQuota: { await harness.readQuota($0) },
        verifyModel: { await harness.verifyModel($0, model: $1) })
}

private func target(_ provider: LocalCLILoginProvider = .grok) -> LocalCLILoginTarget {
    .init(id: "synthetic-\(provider.rawValue)", provider: provider, displayName: "Synthetic")
}

private func fingerprint(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func waitFor(
    _ coordinator: LocalCLILoginCoordinator,
    timeout: TimeInterval = 2,
    _ predicate: (LocalCLILoginStatus) async -> Bool
) async throws -> LocalCLILoginStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let status = await coordinator.snapshot()
        if await predicate(status) { return status }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw FixtureFailure.failed("timed out waiting for workflow state")
}

/// Observation window longer than any injected deadline: a state that survives
/// it was not changed by a timer that should already have fired.
private func observeWindow() async throws {
    try await Task.sleep(nanoseconds: 300_000_000)
}

/// Deadline injected by every timeout scenario; short, deterministic, and
/// always well below the fixture's observation windows.
private let injectedDeadline = Duration.milliseconds(100)

private func expectTimedOut(_ status: LocalCLILoginStatus) throws {
    try expect(status.state == .failed, "stage deadline did not fail the attempt")
    try expect(
        status.failure?.reason == .providerTimeout,
        "timeout produced reason \(status.failure?.reason.rawValue ?? "nil") instead of providerTimeout")
}

private func testExitZeroDoesNotMeanReady() async throws {
    let harness = CapabilityHarness(identities: [.missing, .missing])
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    let waiting = try await waitFor(coordinator) { $0.state == .waitingForReturn }
    try expect(waiting.state != .ready, "launcher receipt must not imply ready")
    let accepted = await coordinator.authorizationDidReturn(attemptID: attempt, exitCode: 0)
    try expect(accepted, "return event rejected")
    let failed = try await waitFor(coordinator) { $0.state == .failed }
    try expect(failed.failure?.reason == .identityMissing, "exit zero must still require identity")
}

private func testCancelRejectsLateLaunchAndCallback() async throws {
    let harness = CapabilityHarness(identities: [.missing], blockLaunch: true)
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    _ = try await waitFor(coordinator) { _ in
        let counts = await harness.counts()
        return counts.launch == 1
    }
    let cancelled = await coordinator.cancel(attemptID: attempt)
    try expect(cancelled, "active attempt did not cancel")
    await harness.resumeLaunch()
    _ = try await waitFor(coordinator) { _ in
        let counts = await harness.counts()
        return counts.cancel == 1
    }
    let lateAccepted = await coordinator.authorizationDidReturn(attemptID: attempt, exitCode: 0)
    try expect(!lateAccepted, "late authorization callback was accepted")
    let status = await coordinator.snapshot()
    try expect(status.state == .cancelled, "late launch changed cancelled state")
}

private func testIdentityChangeInvalidatesOldQuota() async throws {
    let accountA = LocalCLILoginIdentity(fingerprint: fingerprint("a"), maskedLabel: "a***")
    let accountB = LocalCLILoginIdentity(fingerprint: fingerprint("b"), maskedLabel: "b***")
    let harness = CapabilityHarness(
        identities: [.verified(accountA), .verified(accountA), .verified(accountB)],
        quota: .init(status: .verified, identityFingerprint: accountA.fingerprint),
        models: [
            "model-a": .init(model: "model-a", status: .verified, identityFingerprint: accountA.fingerprint)
        ])
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    _ = await coordinator.start(target: target(), expectedIdentity: accountA, models: ["model-a"])
    let failed = try await waitFor(coordinator) { $0.state == .failed }
    try expect(failed.failure?.reason == .identityMismatch, "identity change did not fail closed")
    let counts = await harness.counts()
    try expect(counts.model == 0, "model verifier ran after identity changed")
}

private func testRepeatedStartDoesNotDoubleLaunch() async throws {
    let harness = CapabilityHarness(identities: [.missing], blockLaunch: true)
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    _ = try await waitFor(coordinator) { _ in
        let counts = await harness.counts()
        return counts.launch == 1
    }
    let duplicate = await coordinator.start(target: target(), models: ["model-a"])
    try expect(duplicate == nil, "duplicate start created another attempt")
    let launchCounts = await harness.counts()
    try expect(launchCounts.launch == 1, "duplicate start launched twice")
    _ = await coordinator.cancel(attemptID: attempt)
    await harness.resumeLaunch()
    _ = try await waitFor(coordinator) { _ in (await harness.counts()).cancel == 1 }
}

private func testMissingCapabilityIsUnsupported() async throws {
    let harness = CapabilityHarness(identities: [.missing])
    let coordinator = LocalCLILoginCoordinator(
        capabilities: [.grok: capability(harness: harness)])
    let attempt = await coordinator.start(target: target(.workBuddy), models: ["model-a"])
    try expect(attempt != nil, "unsupported attempt should still have a receipt for presentation")
    let status = await coordinator.snapshot()
    try expect(status.state == .failed && status.failure?.reason == .unsupported, "missing capability was not explicit")
    let counts = await harness.counts()
    try expect(counts.launch == 0, "unsupported provider launched another capability")
}

private func testExistingIdentityRunsQuotaAndEveryModel() async throws {
    let identity = LocalCLILoginIdentity(fingerprint: fingerprint("a"), maskedLabel: "a***")
    let models = ["provider/model-a", "provider/model-b"]
    let harness = CapabilityHarness(
        identities: Array(repeating: .verified(identity), count: 4),
        quota: .init(status: .verified, identityFingerprint: identity.fingerprint),
        models: Dictionary(
            uniqueKeysWithValues: models.map {
                ($0, LocalCLILoginModelEvidence(model: $0, status: .verified, identityFingerprint: identity.fingerprint))
            }))
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    _ = await coordinator.start(target: target(), expectedIdentity: identity, models: models)
    let ready = try await waitFor(coordinator) { $0.state == .ready }
    try expect(ready.verifiedModels.count == models.count, "not every requested model was verified")
    let counts = await harness.counts()
    try expect(counts.launch == 0, "matching signed-in identity unnecessarily launched authorization")
    try expect(counts.model == models.count, "model verification was not per-model")
}

private func testNoModelsRemainPending() async throws {
    let identity = LocalCLILoginIdentity(fingerprint: fingerprint("a"))
    let harness = CapabilityHarness(
        identities: [.verified(identity), .verified(identity)],
        quota: .init(status: .verified, identityFingerprint: identity.fingerprint))
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    _ = await coordinator.start(target: target(), expectedIdentity: identity)
    let pending = try await waitFor(coordinator) { $0.state == .modelsPending }
    try expect(pending.state != .ready, "an empty model list was treated as model evidence")
}

// A detection call that never answers must fail the attempt at the injected
// deadline, release the active state, and leave the same provider retryable.
// The late detection answer arrives after a retry began and must not touch it.
private func testDetectionTimeoutFailsAndAllowsRetry() async throws {
    let harness = CapabilityHarness(identities: [.missing])
    await harness.hold(.detect)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: injectedDeadline)
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    let failed = try await waitFor(coordinator) {
        $0.state == .failed && $0.failure?.reason == .providerTimeout
    }
    try expectTimedOut(failed)
    try expect(failed.attemptID == attempt, "timeout reported a different attempt")
    let stillActive = await coordinator.isActive
    try expect(!stillActive, "timed-out attempt stayed active")

    await harness.unhold(.detect)
    let retry = await coordinator.start(target: target(), models: ["model-a"])
    try expect(retry != nil, "same-provider retry after timeout was rejected")
    try expect(retry != attempt, "retry reused the timed-out attempt id")
    _ = try await waitFor(coordinator) { $0.state == .waitingForReturn }

    await harness.resumeDetect()
    try await observeWindow()
    let status = await coordinator.snapshot()
    try expect(status.state == .waitingForReturn, "late detection result mutated the retry attempt")
    try expect(status.attemptID == retry, "late detection result changed the active attempt")
    _ = await coordinator.cancel(attemptID: retry)
}

// Identity discovery is awaited directly in every branch; parking it must
// produce the same bounded failure and accept a retry.
private func testIdentityDiscoveryTimeoutFailsAttempt() async throws {
    let harness = CapabilityHarness(identities: [.missing])
    await harness.hold(.identity)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: injectedDeadline)
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    let failed = try await waitFor(coordinator) {
        $0.state == .failed && $0.failure?.reason == .providerTimeout
    }
    try expectTimedOut(failed)
    try expect(failed.attemptID == attempt, "timeout reported a different attempt")
    let stillActive = await coordinator.isActive
    try expect(!stillActive, "timed-out attempt stayed active")

    await harness.unhold(.identity)
    let retry = await coordinator.start(target: target(), models: ["model-a"])
    try expect(retry != nil, "same-provider retry after identity timeout was rejected")
    _ = try await waitFor(coordinator) { $0.state == .waitingForReturn }

    await harness.resumeIdentity(.missing)
    try await observeWindow()
    let status = await coordinator.snapshot()
    try expect(status.state == .waitingForReturn, "late identity result mutated the retry attempt")
    try expect(status.attemptID == retry, "late identity result changed the active attempt")
    _ = await coordinator.cancel(attemptID: retry)
}

// A launch past its deadline must fail the attempt and cancel the late
// receipt exactly once; a late return callback must be rejected.
private func testAuthorizationLaunchTimeoutCancelsLateReceiptOnce() async throws {
    let harness = CapabilityHarness(identities: [.missing], blockLaunch: true)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: injectedDeadline)
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    _ = try await waitFor(coordinator) { $0.state == .needsAuthorization }
    let failed = try await waitFor(coordinator) {
        $0.state == .failed && $0.failure?.reason == .providerTimeout
    }
    try expectTimedOut(failed)
    try expect(failed.attemptID == attempt, "timeout reported a different attempt")
    let stillActive = await coordinator.isActive
    try expect(!stillActive, "timed-out attempt stayed active")
    let launchCancelObserved = await harness.observed("launch")
    try expect(launchCancelObserved, "timed-out launch driver did not receive a cancellation request")

    await harness.resumeLaunch()
    _ = try await waitFor(coordinator) { _ in
        let counts = await harness.counts()
        return counts.cancel == 1
    }
    let counts = await harness.counts()
    try expect(counts.cancel == 1, "late receipt was cancelled \(counts.cancel) times, expected exactly once")
    let lateAccepted = await coordinator.authorizationDidReturn(attemptID: attempt, exitCode: 0)
    try expect(!lateAccepted, "late authorization callback was accepted after timeout")
    let status = await coordinator.snapshot()
    try expect(status.state == .failed, "late receipt changed the failed state")
    try expectTimedOut(status)
}

// Quota read past its deadline fails the attempt; the late quota answer must
// not change a ready retry attempt.
private func testQuotaReadTimeoutFailsAndLateValueIsIsolated() async throws {
    let identity = LocalCLILoginIdentity(fingerprint: fingerprint("a"), maskedLabel: "a***")
    let harness = CapabilityHarness(
        identities: Array(repeating: .verified(identity), count: 4),
        quota: .init(status: .verified, identityFingerprint: identity.fingerprint),
        models: [
            "model-a": .init(model: "model-a", status: .verified, identityFingerprint: identity.fingerprint)
        ])
    await harness.hold(.quota)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: injectedDeadline)
    guard let attempt = await coordinator.start(
        target: target(), expectedIdentity: identity, models: ["model-a"])
    else {
        throw FixtureFailure.failed("attempt was not created")
    }
    _ = try await waitFor(coordinator) { $0.state == .quotaPending }
    let failed = try await waitFor(coordinator) {
        $0.state == .failed && $0.failure?.reason == .providerTimeout
    }
    try expectTimedOut(failed)
    try expect(failed.attemptID == attempt, "timeout reported a different attempt")
    let stillActive = await coordinator.isActive
    try expect(!stillActive, "timed-out attempt stayed active")

    await harness.unhold(.quota)
    let retry = await coordinator.start(
        target: target(), expectedIdentity: identity, models: ["model-a"])
    try expect(retry != nil, "same-provider retry after quota timeout was rejected")
    let ready = try await waitFor(coordinator) { $0.state == .ready }
    try expect(ready.attemptID == retry, "retry attempt id changed before the late answer")

    await harness.resumeQuota()
    try await observeWindow()
    let status = await coordinator.snapshot()
    try expect(status.state == .ready, "late quota result changed the ready retry attempt")
    try expect(status.attemptID == retry, "late quota result changed the active attempt")
    try expect(status.verifiedModels.count == 1, "late quota result altered verified models")
}

// Model verification past its deadline fails the attempt; the late evidence
// must not resurrect it.
private func testModelVerificationTimeoutFailsAttempt() async throws {
    let identity = LocalCLILoginIdentity(fingerprint: fingerprint("a"), maskedLabel: "a***")
    let harness = CapabilityHarness(
        identities: Array(repeating: .verified(identity), count: 3),
        quota: .init(status: .verified, identityFingerprint: identity.fingerprint),
        models: [
            "model-a": .init(model: "model-a", status: .verified, identityFingerprint: identity.fingerprint)
        ])
    await harness.hold(.model)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: injectedDeadline)
    guard let attempt = await coordinator.start(
        target: target(), expectedIdentity: identity, models: ["model-a"])
    else {
        throw FixtureFailure.failed("attempt was not created")
    }
    _ = try await waitFor(coordinator) { $0.state == .modelsPending }
    let failed = try await waitFor(coordinator) {
        $0.state == .failed && $0.failure?.reason == .providerTimeout
    }
    try expectTimedOut(failed)
    try expect(failed.attemptID == attempt, "timeout reported a different attempt")
    let stillActive = await coordinator.isActive
    try expect(!stillActive, "timed-out attempt stayed active")
    try expect(failed.verifiedModels.isEmpty, "unverified model appeared as verified evidence")

    await harness.resumeModel("model-a")
    try await observeWindow()
    let status = await coordinator.snapshot()
    try expect(status.state == .failed, "late model evidence resurrected the attempt")
    try expectTimedOut(status)
    try expect(status.verifiedModels.isEmpty, "late model evidence was recorded")
}

// Manual cancel that wins the race against the deadline must stick: the timer
// firing later must not overwrite cancelled with timeout.
private func testManualCancelBeforeDeadlineStaysCancelled() async throws {
    let harness = CapabilityHarness(identities: [.missing])
    await harness.hold(.detect)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: injectedDeadline)
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    let cancelled = await coordinator.cancel(attemptID: attempt)
    try expect(cancelled, "cancel before the deadline failed")
    let status = await coordinator.snapshot()
    try expect(status.state == .cancelled, "cancel did not reach cancelled state")

    try await observeWindow()
    let afterTimer = await coordinator.snapshot()
    try expect(afterTimer.state == .cancelled, "late deadline timer overwrote the cancelled state")
    let activeAfterTimer = await coordinator.isActive
    try expect(!activeAfterTimer, "cancelled attempt stayed active")

    await harness.resumeDetect()
    try await observeWindow()
    let afterLateAnswer = await coordinator.snapshot()
    try expect(
        afterLateAnswer.state == .cancelled,
        "the provider's late answer changed the cancelled state")
}

// When the deadline already produced the terminal state, a later manual cancel
// must be rejected and the state must stay the timeout failure.
private func testCancelAfterTimeoutIsRejected() async throws {
    let harness = CapabilityHarness(identities: [.missing])
    await harness.hold(.detect)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: injectedDeadline)
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    let failed = try await waitFor(coordinator) {
        $0.state == .failed && $0.failure?.reason == .providerTimeout
    }
    try expectTimedOut(failed)
    let cancelled = await coordinator.cancel(attemptID: attempt)
    try expect(!cancelled, "cancel after the terminal timeout was accepted")
    try await observeWindow()
    let status = await coordinator.snapshot()
    try expect(status.state == .failed, "rejected cancel changed the failed state")
    try expectTimedOut(status)

    await harness.resumeDetect()
    try await observeWindow()
    let afterLateAnswer = await coordinator.snapshot()
    try expect(afterLateAnswer.state == .failed, "the late answer changed the failed state")
    try expectTimedOut(afterLateAnswer)
}

// A login that finishes its provider work with no requested models stays in
// modelsPending by design, but must release the active attempt so the same
// provider can start again instead of blocking on cancel.
private func testEmptyModelsReleaseActiveAttempt() async throws {
    let identity = LocalCLILoginIdentity(fingerprint: fingerprint("a"), maskedLabel: "a***")
    let harness = CapabilityHarness(
        identities: Array(repeating: .verified(identity), count: 4),
        quota: .init(status: .verified, identityFingerprint: identity.fingerprint))
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    guard let attempt = await coordinator.start(target: target(), expectedIdentity: identity)
    else {
        throw FixtureFailure.failed("attempt was not created")
    }
    let pending = try await waitFor(coordinator) { $0.state == .modelsPending }
    try expect(pending.state != .ready, "an empty model list was treated as model evidence")
    try await observeWindow()
    let activeAfterFirst = await coordinator.isActive
    try expect(!activeAfterFirst, "finished attempt with no models stayed active")

    let retry = await coordinator.start(target: target(), expectedIdentity: identity)
    try expect(retry != nil, "same-provider restart after modelsPending was rejected")
    try expect(retry != attempt, "restart reused the previous attempt id")
    _ = try await waitFor(coordinator) { $0.state == .modelsPending }
    let activeAfterSecond = await coordinator.isActive
    try expect(!activeAfterSecond, "second finished attempt stayed active")
}

// The timeout must request cooperative cancellation of the suspended driver
// task. Every gated stage parks a capability continuation; after the injected
// deadline the test asserts that the provider side observed the cancellation,
// that the attempt is released and retryable, and that the late answer cannot
// touch the retry. The timeout path never awaits the old task: the retry and
// the assertions below run while the old continuation is still parked.
private func testDetectTimeoutCancelsDriverAndIsolatesLateResult() async throws {
    let harness = CapabilityHarness(identities: [.missing])
    await harness.hold(.detect)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: injectedDeadline)
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    let failed = try await waitFor(coordinator) {
        $0.state == .failed && $0.failure?.reason == .providerTimeout
    }
    try expectTimedOut(failed)
    try expect(failed.attemptID == attempt, "timeout reported a different attempt")
    let cancelObserved = await harness.observed("detect")
    try expect(cancelObserved, "timed-out detection driver did not receive a cancellation request")
    let stillActive = await coordinator.isActive
    try expect(!stillActive, "timed-out attempt stayed active")

    await harness.unhold(.detect)
    let retry = await coordinator.start(target: target(), models: ["model-a"])
    try expect(retry != nil, "same-provider retry after timeout was rejected")
    _ = try await waitFor(coordinator) { $0.state == .waitingForReturn }

    await harness.resumeDetect()
    try await observeWindow()
    let status = await coordinator.snapshot()
    try expect(status.state == .waitingForReturn, "late detection result mutated the retry attempt")
    try expect(status.attemptID == retry, "late detection result changed the active attempt")
    _ = await coordinator.cancel(attemptID: retry)
}

private func testIdentityTimeoutCancelsDriverAndIsolatesLateResult() async throws {
    let harness = CapabilityHarness(identities: [.missing])
    await harness.hold(.identity)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: injectedDeadline)
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    let failed = try await waitFor(coordinator) {
        $0.state == .failed && $0.failure?.reason == .providerTimeout
    }
    try expectTimedOut(failed)
    try expect(failed.attemptID == attempt, "timeout reported a different attempt")
    let cancelObserved = await harness.observed("identity")
    try expect(cancelObserved, "timed-out identity driver did not receive a cancellation request")
    let stillActive = await coordinator.isActive
    try expect(!stillActive, "timed-out attempt stayed active")

    await harness.unhold(.identity)
    let retry = await coordinator.start(target: target(), models: ["model-a"])
    try expect(retry != nil, "same-provider retry after timeout was rejected")
    _ = try await waitFor(coordinator) { $0.state == .waitingForReturn }

    await harness.resumeIdentity(.missing)
    try await observeWindow()
    let status = await coordinator.snapshot()
    try expect(status.state == .waitingForReturn, "late identity result mutated the retry attempt")
    try expect(status.attemptID == retry, "late identity result changed the active attempt")
    _ = await coordinator.cancel(attemptID: retry)
}

private func testQuotaTimeoutCancelsDriverAndIsolatesLateResult() async throws {
    let identity = LocalCLILoginIdentity(fingerprint: fingerprint("a"), maskedLabel: "a***")
    let harness = CapabilityHarness(
        identities: Array(repeating: .verified(identity), count: 4),
        quota: .init(status: .verified, identityFingerprint: identity.fingerprint),
        models: [
            "model-a": .init(model: "model-a", status: .verified, identityFingerprint: identity.fingerprint)
        ])
    await harness.hold(.quota)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: injectedDeadline)
    guard (await coordinator.start(
        target: target(), expectedIdentity: identity, models: ["model-a"])) != nil
    else {
        throw FixtureFailure.failed("attempt was not created")
    }
    let failed = try await waitFor(coordinator) {
        $0.state == .failed && $0.failure?.reason == .providerTimeout
    }
    try expectTimedOut(failed)
    let cancelObserved = await harness.observed("quota")
    try expect(cancelObserved, "timed-out quota driver did not receive a cancellation request")
    let stillActive = await coordinator.isActive
    try expect(!stillActive, "timed-out attempt stayed active")

    await harness.unhold(.quota)
    let retry = await coordinator.start(
        target: target(), expectedIdentity: identity, models: ["model-a"])
    try expect(retry != nil, "same-provider retry after timeout was rejected")
    let ready = try await waitFor(coordinator) { $0.state == .ready }
    try expect(ready.attemptID == retry, "retry attempt id changed before the late answer")

    await harness.resumeQuota()
    try await observeWindow()
    let status = await coordinator.snapshot()
    try expect(status.state == .ready, "late quota result changed the ready retry attempt")
    try expect(status.attemptID == retry, "late quota result changed the active attempt")
    try expect(status.verifiedModels.count == 1, "late quota result altered verified models")
}

private func testModelTimeoutCancelsDriverAndIsolatesLateResult() async throws {
    let identity = LocalCLILoginIdentity(fingerprint: fingerprint("a"), maskedLabel: "a***")
    let harness = CapabilityHarness(
        identities: Array(repeating: .verified(identity), count: 3),
        quota: .init(status: .verified, identityFingerprint: identity.fingerprint),
        models: [
            "model-a": .init(model: "model-a", status: .verified, identityFingerprint: identity.fingerprint)
        ])
    await harness.hold(.model)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: injectedDeadline)
    guard (await coordinator.start(
        target: target(), expectedIdentity: identity, models: ["model-a"])) != nil
    else {
        throw FixtureFailure.failed("attempt was not created")
    }
    let failed = try await waitFor(coordinator) {
        $0.state == .failed && $0.failure?.reason == .providerTimeout
    }
    try expectTimedOut(failed)
    let cancelObserved = await harness.observed("model")
    try expect(cancelObserved, "timed-out model driver did not receive a cancellation request")
    let stillActive = await coordinator.isActive
    try expect(!stillActive, "timed-out attempt stayed active")

    await harness.unhold(.model)
    let retry = await coordinator.start(
        target: target(), expectedIdentity: identity, models: ["model-a"])
    try expect(retry != nil, "same-provider retry after timeout was rejected")
    _ = try await waitFor(coordinator) { $0.state == .ready }

    await harness.resumeModel("model-a")
    try await observeWindow()
    let status = await coordinator.snapshot()
    try expect(status.state == .ready, "late model evidence changed the ready retry attempt")
    try expect(status.attemptID == retry, "late model evidence changed the active attempt")
}

/// A stage that finishes near its own deadline must invalidate its watchdog:
/// the next stage parks past the first stage's nominal deadline and has to
/// stay active until its own deadline expires. Only then may the attempt fail.
private func testFirstStageDeadlineCannotFailNextStage() async throws {
    let stageDeadline = Duration.milliseconds(200)
    let harness = CapabilityHarness(identities: [.missing])
    await harness.hold(.detect)
    await harness.hold(.identity)
    let coordinator = LocalCLILoginCoordinator(
        capability: capability(harness: harness),
        stageDeadline: stageDeadline)
    guard (await coordinator.start(target: target(), models: ["model-a"])) != nil else {
        throw FixtureFailure.failed("attempt was not created")
    }

    // Stage 1 completes near its own deadline (~100 ms of the 200 ms budget).
    try await Task.sleep(nanoseconds: 100_000_000)
    await harness.unhold(.detect)
    await harness.resumeDetect()
    _ = try await waitFor(coordinator) { _ in await harness.identityCalls == 1 }

    // Past stage 1's nominal deadline (~200 ms) but before stage 2's own
    // deadline (~300 ms): the attempt must still be active in detection.
    try await Task.sleep(nanoseconds: 140_000_000)
    let activeAfterOldDeadline = await coordinator.isActive
    let statusAfterOldDeadline = await coordinator.snapshot()
    try expect(
        activeAfterOldDeadline,
        "stale stage-1 watchdog failed the attempt before stage 2's own deadline")
    try expect(
        statusAfterOldDeadline.state == .detecting,
        "the next stage did not survive the old deadline")

    // Stage 2's own deadline expires and fails the attempt.
    let failed = try await waitFor(coordinator) {
        $0.state == .failed && $0.failure?.reason == .providerTimeout
    }
    try expectTimedOut(failed)
    let stillActive = await coordinator.isActive
    try expect(!stillActive, "timed-out attempt stayed active")

    await harness.unhold(.identity)
    await harness.resumeIdentity(.missing)
    try await observeWindow()
    let status = await coordinator.snapshot()
    try expect(status.state == .failed, "late identity result changed the failed state")
    try expectTimedOut(status)
}

@main enum Main {
    static func main() async throws {
        try await testExitZeroDoesNotMeanReady()
        try await testCancelRejectsLateLaunchAndCallback()
        try await testIdentityChangeInvalidatesOldQuota()
        try await testRepeatedStartDoesNotDoubleLaunch()
        try await testMissingCapabilityIsUnsupported()
        try await testExistingIdentityRunsQuotaAndEveryModel()
        try await testNoModelsRemainPending()
        try await testDetectionTimeoutFailsAndAllowsRetry()
        try await testIdentityDiscoveryTimeoutFailsAttempt()
        try await testAuthorizationLaunchTimeoutCancelsLateReceiptOnce()
        try await testQuotaReadTimeoutFailsAndLateValueIsIsolated()
        try await testModelVerificationTimeoutFailsAttempt()
        try await testManualCancelBeforeDeadlineStaysCancelled()
        try await testCancelAfterTimeoutIsRejected()
        try await testDetectTimeoutCancelsDriverAndIsolatesLateResult()
        try await testIdentityTimeoutCancelsDriverAndIsolatesLateResult()
        try await testQuotaTimeoutCancelsDriverAndIsolatesLateResult()
        try await testModelTimeoutCancelsDriverAndIsolatesLateResult()
        try await testFirstStageDeadlineCannotFailNextStage()
        try await testEmptyModelsReleaseActiveAttempt()
        print("local-cli-login-coordinator-fixture: ok")
    }
}
