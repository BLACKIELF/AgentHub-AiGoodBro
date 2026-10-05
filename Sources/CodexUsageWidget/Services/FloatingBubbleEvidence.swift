import Foundation

@MainActor
enum FloatingBubbleEvidence {
    static func make(store: UsageStore, localAccounts: LocalCLIAccountStore, language: WidgetLanguage) -> [TokenMonitorFloatingBubbleAccount] {
        let now = Date()
        let managedKeys = Set(store.profiles.filter { !$0.isSystemProfile }.map(\.recordedAccountKey))
        var sources = store.profiles.filter { !$0.isSystemProfile || !managedKeys.contains($0.recordedAccountKey) }.map { profile in
            let snapshot = profile.lastSnapshot
            let failedSinceRead = profile.lastQuotaReadFailureAt.map { $0 >= (snapshot?.fetchedAt ?? .distantPast) } ?? false
            let invalidated = failedSinceRead && profile.lastQuotaReadFailureReason == "oauth-invalidated"
            let loggedIn = snapshot?.quotaReadSucceeded == true && !invalidated
            let stale = failedSinceRead || snapshot.map { now.timeIntervalSince($0.fetchedAt) > 300 } == true
            var metrics: [TokenMonitorFloatingBubbleMetric] = []
            let windows: [(String, String, CodexQuotaWindowSnapshot?)] = [
                ("five-hour", language.text("五小时额度", "5-hour quota"), snapshot?.fiveHour),
                ("seven-day", language.text("每周额度", "Weekly quota"), snapshot?.sevenDay),
                ("monthly", language.text("每月额度", "Monthly quota"), snapshot?.monthly),
            ]
            if QuotaAvailabilityPresentation.weeklyOnlyPro(profile) {
                metrics.append(
                    TokenMonitorFloatingBubbleMetric(
                        id: "five-hour", name: language.text("五小时额度", "5-hour quota"),
                        sourceID: "codex:\(profile.id):five-hour", fetchedAt: snapshot?.fetchedAt,
                        isStale: stale, isAvailable: loggedIn, value: .text("∞"),
                        resetLabel: QuotaAvailabilityPresentation.weeklyOnlyProHelp(language)))
            }
            for (id, name, window) in windows {
                guard let window else { continue }
                let valid = window.usedPercent.isFinite && (0...100).contains(window.usedPercent)
                metrics.append(
                    TokenMonitorFloatingBubbleMetric(
                        id: id, name: name, sourceID: "codex:\(profile.id):\(id)",
                        fetchedAt: snapshot?.fetchedAt, isStale: stale, isAvailable: loggedIn,
                        value: valid ? .percentRemaining(100 - window.usedPercent) : .unknown,
                        resetLabel: window.resetsAt.map { language.dateTime($0) } ?? "—"))
            }
            return TokenMonitorFloatingBubbleAccount(
                providerID: AgentNavCatalog.codexID, providerName: "Codex",
                accountID: profile.id, accountName: AccountDisplay.numberedName(profile, allProfiles: store.profiles),
                isLoggedIn: loggedIn, metrics: metrics)
        }
        for profile in localAccounts.profiles {
            guard let provider = AgentNavCatalog.workspaceProviders.first(where: { $0.localKind == profile.kind }) else { continue }
            let quota = localAccounts.quotas[profile.id]
            let loggedIn = quota?.state == .available && quota?.identityFingerprint != nil
            let stale = localAccounts.stale.contains(profile.id) || quota.map { now.timeIntervalSince($0.fetchedAt) > 300 } == true
            var metrics = (quota?.windows ?? []).map { window in
                let valid = window.usedPercent.isFinite && (0...100).contains(window.usedPercent)
                let expired = provider.id == "grok" && window.resetsAt.map { $0 <= now } == true
                return TokenMonitorFloatingBubbleMetric(
                    id: window.id, name: window.label,
                    sourceID: "\(provider.id):\(profile.id):\(window.id)", fetchedAt: quota?.fetchedAt,
                    isStale: stale || expired, isAvailable: loggedIn && !expired,
                    value: valid ? .percentRemaining(100 - window.usedPercent) : .unknown,
                    resetLabel: window.resetsAt.map { language.dateTime($0) } ?? "—")
            }
            if let balance = quota?.balance, balance.isFinite, balance >= 0 {
                let currency = LocalCLIQuotaPresentation.boundedLabel(quota?.balanceCurrency, maximumUTF8Bytes: 16) ?? ""
                metrics.append(
                    TokenMonitorFloatingBubbleMetric(
                        id: "balance", name: language.text("余额", "Balance"),
                        sourceID: "\(provider.id):\(profile.id):balance", fetchedAt: quota?.fetchedAt,
                        isStale: stale, isAvailable: loggedIn,
                        value: .text(String(format: "%.2f", balance) + (currency.isEmpty ? "" : " " + currency))))
            }
            sources.append(
                TokenMonitorFloatingBubbleAccount(
                    providerID: provider.id, providerName: provider.displayName,
                    accountID: profile.id, accountName: AccountDisplay.masked(profile.displayName),
                    isLoggedIn: loggedIn, metrics: metrics))
        }
        return sources
    }
}
