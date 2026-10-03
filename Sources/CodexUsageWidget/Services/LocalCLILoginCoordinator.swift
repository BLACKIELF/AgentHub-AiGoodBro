import Foundation

/// Coordinates one provider-owned login attempt. All installation, launch,
/// identity, quota, and model operations are injected through
/// `LocalCLILoginCapability`; this type does not inspect credentials or start
/// a process itself.
actor LocalCLILoginCoordinator {
    /// Provider stages that are awaited directly and therefore need a bounded
    /// wait. Every deadline is identified by the attempt id plus a monotonic
    /// stage generation, so a stale timer can never terminate a later stage of
    /// the same attempt or a different attempt.
    private enum LoginStage: Sendable, Equatable {
        case detection
        case identityDiscovery
        case authorizationLaunch
        case quotaRead
        case modelVerification(model: String)
    }

    /// Default per-stage bound. It matches the 15-second network request
    /// timeout used by LocalCLIQuotaReader so one provider stage cannot outwait
    /// the repo's own remote reads. Fixtures inject shorter deterministic
    /// deadlines through the initializers.
    static let defaultStageDeadline: Duration = .seconds(15)

    private struct ActiveAttempt {
        let id: UUID
        let target: LocalCLILoginTarget
        let capability: any LocalCLILoginCapability
        var workflow: LocalCLILoginWorkflow
        var receipt: LocalCLILoginLaunchReceipt?
        var stageGeneration = 0
        var watchdog: Task<Void, Never>? = nil
    }

    private let capabilities: [LocalCLILoginProvider: any LocalCLILoginCapability]
    private let stageDeadline: Duration
    private var activeAttempt: ActiveAttempt?
    // Attempt ids whose launch call may still return a receipt that must be
    // cancelled exactly once. An entry is consumed when that launch call
    // returns or throws. A launch that never returns leaves its id here for
    // the process lifetime (one UUID and one suspended task each); no TTL or
    // timed sweep exists because sweeping could drop a late receipt's
    // cancellation. Manual cancels while a launch is in flight use the same
    // mechanism and inherit the same residual.
    private var pendingCancellations: Set<UUID> = []
    private var driverTask: Task<Void, Never>?
    private(set) var status: LocalCLILoginStatus = .empty

    init(
        capability: any LocalCLILoginCapability,
        stageDeadline: Duration = LocalCLILoginCoordinator.defaultStageDeadline
    ) {
        self.capabilities = [capability.descriptor.provider: capability]
        self.stageDeadline = stageDeadline
    }

    init(
        capabilities: [LocalCLILoginProvider: any LocalCLILoginCapability],
        stageDeadline: Duration = LocalCLILoginCoordinator.defaultStageDeadline
    ) {
        self.capabilities = capabilities
        self.stageDeadline = stageDeadline
    }

    func descriptor(for provider: LocalCLILoginProvider) -> LocalCLILoginCapabilityDescriptor? {
        capabilities[provider]?.descriptor
    }

    var isActive: Bool { activeAttempt != nil }

    /// Starts detection and, if needed, the provider's official authorization
    /// entry point. A repeated call while an attempt is active returns nil and
    /// never calls the injected launcher a second time.
    @discardableResult
    func start(
        target: LocalCLILoginTarget,
        expectedIdentity: LocalCLILoginIdentity? = nil,
        models: [String] = []
    ) -> UUID? {
        guard activeAttempt == nil else { return nil }

        let attemptID = UUID()
        var workflow = LocalCLILoginWorkflow(
            target: target,
            attemptID: attemptID,
            expectedIdentity: expectedIdentity,
            targetModels: models)

        guard !target.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let capability = capabilities[target.provider],
            capability.descriptor.provider == target.provider
        else {
            _ = workflow.markFailed(.unsupported)
            status = workflow.status
            return attemptID
        }

        activeAttempt = ActiveAttempt(
            id: attemptID,
            target: target,
            capability: capability,
            workflow: workflow,
            receipt: nil)
        status = workflow.status

        driverTask = Task { [weak self] in
            await self?.runDetection(attemptID: attemptID, target: target, capability: capability)
        }
        return attemptID
    }

    /// Marks the attempt cancelled before awaiting the injected cancel hook.
    /// Any callback for this UUID is ignored, including callbacks arriving
    /// after a new attempt has started.
    @discardableResult
    func cancel(attemptID: UUID? = nil) async -> Bool {
        guard let current = activeAttempt,
            attemptID == nil || attemptID == current.id
        else { return false }

        var cancelled = current.workflow
        guard cancelled.markCancelled() else { return false }
        status = cancelled.status
        activeAttempt = nil
        driverTask?.cancel()
        driverTask = nil
        current.watchdog?.cancel()

        if let receipt = current.receipt {
            await current.capability.cancelAuthorization(target: current.target, receipt: receipt)
        } else if current.workflow.status.state == .needsAuthorization {
            // The launch call may already be in flight. If it eventually
            // returns a receipt, launchAuthorization cancels that exact receipt.
            pendingCancellations.insert(current.id)
        }
        return true
    }

    /// Delivers the provider's return/exit event. A zero exit code only moves
    /// the workflow to identity verification; it can never make it ready.
    @discardableResult
    func authorizationDidReturn(
        attemptID: UUID,
        receiptID: UUID? = nil,
        exitCode: Int32 = 0
    ) -> Bool {
        guard var current = activeAttempt,
            current.id == attemptID,
            current.workflow.status.state == .waitingForReturn,
            receiptID == nil || receiptID == current.receipt?.id
        else { return false }

        guard exitCode == 0 else {
            _ = current.workflow.markFailed(.authorizationFailed)
            status = current.workflow.status
            activeAttempt = nil
            driverTask = nil
            return true
        }

        guard current.workflow.markVerifyingIdentity() else { return false }
        activeAttempt = current
        status = current.workflow.status
        let capability = current.capability
        let target = current.target
        driverTask = Task { [weak self] in
            await self?.verifyIdentityAfterAuthorization(
                attemptID: attemptID,
                target: target,
                capability: capability)
        }
        return true
    }

    /// The normal path never invokes advanced association automatically. This
    /// method exists as a parent-wiring seam for an explicit fallback action.
    func fallbackAssociation(target: LocalCLILoginTarget) async -> LocalCLILoginIdentityEvidence {
        guard let capability = capabilities[target.provider] else { return .unsupported }
        return await capability.fallbackAssociation(target: target)
    }

    func snapshot() -> LocalCLILoginStatus { status }

    private func runDetection(
        attemptID: UUID,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard activeAttempt?.id == attemptID else {
            pendingCancellations.remove(attemptID)
            return
        }

        armStageWatchdog(attemptID: attemptID, stage: .detection)
        let detection = await capability.detect(target: target)
        disarmStageWatchdog(attemptID: attemptID)
        guard activeAttempt?.id == attemptID else {
            pendingCancellations.remove(attemptID)
            return
        }
        guard detection.installed else {
            failActive(attemptID: attemptID, reason: .notInstalled)
            return
        }

        armStageWatchdog(attemptID: attemptID, stage: .identityDiscovery)
        let identity = await capability.discoverIdentity(target: target)
        disarmStageWatchdog(attemptID: attemptID)
        guard activeAttempt?.id == attemptID else {
            pendingCancellations.remove(attemptID)
            return
        }

        switch identity {
        case .verified:
            guard var current = activeAttempt,
                current.workflow.markVerifyingIdentity()
            else {
                failActive(attemptID: attemptID, reason: .identityUnverified)
                return
            }
            activeAttempt = current
            status = current.workflow.status
            await advanceIdentity(
                attemptID: attemptID,
                evidence: identity,
                target: target,
                capability: capability)

        case .missing:
            guard capability.descriptor.supportsAuthorization else {
                failActive(attemptID: attemptID, reason: .unsupported)
                return
            }
            guard var current = activeAttempt,
                current.workflow.markNeedsAuthorization()
            else { return }
            activeAttempt = current
            status = current.workflow.status
            await launchAuthorization(
                attemptID: attemptID,
                target: target,
                capability: capability)

        case .unverified:
            failActive(attemptID: attemptID, reason: .identityUnverified)
        case .unsupported:
            failActive(attemptID: attemptID, reason: .unsupported)
        }
    }

    private func launchAuthorization(
        attemptID: UUID,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard activeAttempt?.id == attemptID else {
            pendingCancellations.remove(attemptID)
            return
        }

        armStageWatchdog(attemptID: attemptID, stage: .authorizationLaunch)
        do {
            let receipt = try await capability.startAuthorization(target: target)
            disarmStageWatchdog(attemptID: attemptID)
            guard var current = activeAttempt, current.id == attemptID else {
                if pendingCancellations.remove(attemptID) != nil {
                    await capability.cancelAuthorization(target: target, receipt: receipt)
                }
                return
            }
            current.receipt = receipt
            guard current.workflow.markWaitingForReturn(receipt: receipt) else {
                activeAttempt = current
                failActive(attemptID: attemptID, reason: .authorizationFailed)
                return
            }
            activeAttempt = current
            status = current.workflow.status
        } catch let error as LocalCLILoginCapabilityError {
            disarmStageWatchdog(attemptID: attemptID)
            if activeAttempt?.id != attemptID {
                pendingCancellations.remove(attemptID)
                return
            }
            failActive(
                attemptID: attemptID,
                reason: error == .unsupported ? .unsupported : .authorizationFailed)
        } catch {
            disarmStageWatchdog(attemptID: attemptID)
            if activeAttempt?.id != attemptID {
                pendingCancellations.remove(attemptID)
                return
            }
            failActive(attemptID: attemptID, reason: .authorizationFailed)
        }
    }

    private func verifyIdentityAfterAuthorization(
        attemptID: UUID,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard activeAttempt?.id == attemptID else { return }
        armStageWatchdog(attemptID: attemptID, stage: .identityDiscovery)
        let evidence = await capability.discoverIdentity(target: target)
        disarmStageWatchdog(attemptID: attemptID)
        guard activeAttempt?.id == attemptID else { return }
        await advanceIdentity(
            attemptID: attemptID,
            evidence: evidence,
            target: target,
            capability: capability)
    }

    private func advanceIdentity(
        attemptID: UUID,
        evidence: LocalCLILoginIdentityEvidence,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard var current = activeAttempt,
            current.id == attemptID,
            current.workflow.status.state == .verifyingIdentity
        else { return }

        switch evidence {
        case .verified(let identity):
            guard current.workflow.accepts(identity) else {
                failActive(attemptID: attemptID, reason: .identityMismatch)
                return
            }
            guard current.workflow.recordIdentity(identity),
                current.workflow.markQuotaPending()
            else {
                failActive(attemptID: attemptID, reason: .identityUnverified)
                return
            }
            activeAttempt = current
            status = current.workflow.status
            await runQuota(attemptID: attemptID, target: target, capability: capability)
        case .missing:
            failActive(attemptID: attemptID, reason: .identityMissing)
        case .unverified:
            failActive(attemptID: attemptID, reason: .identityUnverified)
        case .unsupported:
            failActive(attemptID: attemptID, reason: .unsupported)
        }
    }

    private func runQuota(
        attemptID: UUID,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard activeAttempt?.id == attemptID else { return }

        // Re-read identity at the quota boundary so an account switch cannot
        // reuse a result from the identity stage.
        armStageWatchdog(attemptID: attemptID, stage: .identityDiscovery)
        let identityEvidence = await capability.discoverIdentity(target: target)
        disarmStageWatchdog(attemptID: attemptID)
        guard let current = activeAttempt, current.id == attemptID else { return }
        guard case .verified(let identity) = identityEvidence,
            current.workflow.status.identityFingerprint == identity.fingerprint,
            current.workflow.accepts(identity)
        else {
            failActive(attemptID: attemptID, reason: .identityMismatch)
            return
        }

        armStageWatchdog(attemptID: attemptID, stage: .quotaRead)
        let quota = await capability.readQuota(target: target)
        disarmStageWatchdog(attemptID: attemptID)
        guard var latest = activeAttempt, latest.id == attemptID else { return }
        guard quota.status == .verified else {
            let reason: LocalCLILoginFailureReason
            switch quota.status {
            case .unavailable: reason = .quotaUnavailable
            case .unsupported: reason = .quotaUnsupported
            case .unverified: reason = .quotaUnverified
            case .verified: reason = .quotaUnverified
            }
            failActive(attemptID: attemptID, reason: reason)
            return
        }
        guard quota.identityFingerprint == latest.workflow.status.identityFingerprint else {
            failActive(attemptID: attemptID, reason: .identityMismatch)
            return
        }
        guard latest.workflow.recordQuota(quota), latest.workflow.markModelsPending() else {
            failActive(attemptID: attemptID, reason: .quotaUnverified)
            return
        }
        activeAttempt = latest
        status = latest.workflow.status

        if latest.workflow.targetModels.isEmpty {
            // No requested model means there is no model-availability evidence.
            // Stay pending instead of treating an empty list as proof of
            // readiness, but release the active attempt so the same provider
            // can start again; no provider call is in flight here.
            activeAttempt = nil
            driverTask = nil
            return
        }
        await runModels(attemptID: attemptID, target: target, capability: capability)
    }

    private func runModels(
        attemptID: UUID,
        target: LocalCLILoginTarget,
        capability: any LocalCLILoginCapability
    ) async {
        guard let current = activeAttempt, current.id == attemptID else { return }
        for model in current.workflow.targetModels {
            guard activeAttempt?.id == attemptID else { return }

            // Each model gets a fresh identity check and its own evidence.
            armStageWatchdog(attemptID: attemptID, stage: .identityDiscovery)
            let identityEvidence = await capability.discoverIdentity(target: target)
            disarmStageWatchdog(attemptID: attemptID)
            guard let latest = activeAttempt, latest.id == attemptID else { return }
            guard case .verified(let identity) = identityEvidence,
                latest.workflow.status.identityFingerprint == identity.fingerprint,
                latest.workflow.accepts(identity)
            else {
                failActive(attemptID: attemptID, reason: .identityMismatch, model: model)
                return
            }

            armStageWatchdog(attemptID: attemptID, stage: .modelVerification(model: model))
            let evidence = await capability.verifyModel(target: target, model: model)
            disarmStageWatchdog(attemptID: attemptID)
            guard var verified = activeAttempt, verified.id == attemptID else { return }
            guard evidence.model == model else {
                failActive(attemptID: attemptID, reason: .modelMismatch, model: model)
                return
            }
            guard evidence.identityFingerprint == verified.workflow.status.identityFingerprint else {
                failActive(attemptID: attemptID, reason: .identityMismatch, model: model)
                return
            }
            guard evidence.status == .verified else {
                let reason: LocalCLILoginFailureReason
                switch evidence.status {
                case .unavailable: reason = .modelUnavailable
                case .unsupported: reason = .modelUnsupported
                case .unverified, .verified: reason = .modelUnverified
                }
                failActive(attemptID: attemptID, reason: reason, model: model)
                return
            }
            guard verified.workflow.recordModel(evidence) else {
                failActive(attemptID: attemptID, reason: .modelUnverified, model: model)
                return
            }
            activeAttempt = verified
            status = verified.workflow.status
        }

        guard var ready = activeAttempt, ready.id == attemptID else { return }
        guard ready.workflow.markReady() else {
            failActive(attemptID: attemptID, reason: .modelUnverified)
            return
        }
        status = ready.workflow.status
        activeAttempt = nil
        driverTask = nil
    }

    private func failActive(
        attemptID: UUID,
        reason: LocalCLILoginFailureReason,
        model: String? = nil
    ) {
        guard var current = activeAttempt, current.id == attemptID else { return }
        current.watchdog?.cancel()
        // Ask the suspended driver task to stop cooperatively, but never wait
        // for it: a non-cooperative capability stays parked, and its late
        // values are discarded by the attempt guards. For the authorization
        // launch the pending-cancellation tombstone (armed by the timeout)
        // still cancels a receipt that arrives after this cancellation.
        driverTask?.cancel()
        _ = current.workflow.markFailed(reason, model: model)
        status = current.workflow.status
        activeAttempt = nil
        driverTask = nil
    }

    /// Arms the deadline for one in-flight capability call. Arming bumps the
    /// attempt's monotonic stage generation, which invalidates any watchdog
    /// left over from an earlier stage or a different attempt.
    private func armStageWatchdog(attemptID: UUID, stage: LoginStage) {
        guard var current = activeAttempt, current.id == attemptID else { return }
        current.watchdog?.cancel()
        current.stageGeneration += 1
        let generation = current.stageGeneration
        let deadline = stageDeadline
        current.watchdog = Task { [weak self] in
            // A cancelled sleep surfaces through `try?` and execution would
            // otherwise continue; a disarmed watchdog must never fire.
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            await self?.stageDeadlineFired(
                attemptID: attemptID,
                stage: stage,
                generation: generation)
        }
        activeAttempt = current
    }

    /// Cancels the watchdog as soon as the awaited call returns so no timer
    /// stays armed while no provider call is in flight — for example while the
    /// workflow waits for the user to return from authorization. Bumping the
    /// stage generation also invalidates a watchdog that already woke up from
    /// its cancelled sleep.
    private func disarmStageWatchdog(attemptID: UUID) {
        guard var current = activeAttempt, current.id == attemptID else { return }
        current.watchdog?.cancel()
        current.stageGeneration += 1
        current.watchdog = nil
        activeAttempt = current
    }

    /// Fired by a watchdog after its injected deadline. Valid only while the
    /// same attempt is still active in the exact stage that armed it; anything
    /// else (new stage, new attempt, cancelled or finished attempt) makes this
    /// a stale timer that must not change state.
    private func stageDeadlineFired(
        attemptID: UUID,
        stage: LoginStage,
        generation: Int
    ) {
        guard let current = activeAttempt,
            current.id == attemptID,
            current.stageGeneration == generation
        else { return }

        if stage == .authorizationLaunch, current.receipt == nil {
            // The launch call is still in flight past its deadline. If it
            // eventually returns a receipt, the existing pending-cancellation
            // path cancels that receipt exactly once.
            pendingCancellations.insert(attemptID)
        }
        failActive(attemptID: attemptID, reason: .providerTimeout)
    }
}
