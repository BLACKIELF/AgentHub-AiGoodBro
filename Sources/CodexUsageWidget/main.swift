import Cocoa
import Darwin

@main
struct CodexAccountManagerNextMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test-global-shortcut") {
            exit(GlobalShortcutSelfTest.run() ? 0 : 1)
        }

        if let helperIndex = CommandLine.arguments.firstIndex(of: "--hold-exclusive-hotkey"),
            CommandLine.arguments.indices.contains(helperIndex + 1)
        {
            GlobalShortcutSelfTest.holdExclusiveShortcut(
                readyFile: CommandLine.arguments[helperIndex + 1]
            )
        }

        if CommandLine.arguments.contains("--self-test-status-item") {
            exit(StatusItemPresentationSelfTest.run() && SettingsPresentationSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-palettes") {
            exit(PaletteCatalogSelfTest.run() ? 0 : 1)
        }

        if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-palette-previews"),
            CommandLine.arguments.indices.contains(previewIndex + 1)
        {
            _ = NSApplication.shared
            let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1], isDirectory: true)
            exit(PalettePreviewRenderer.renderBuiltIns(to: outputURL) ? 0 : 1)
        }

        if let screenshotIndex = CommandLine.arguments.firstIndex(of: "--render-documentation-settings"),
            CommandLine.arguments.indices.contains(screenshotIndex + 1)
        {
            _ = NSApplication.shared
            let outputURL = URL(fileURLWithPath: CommandLine.arguments[screenshotIndex + 1])
            exit(PalettePreviewRenderer.renderDocumentationSettings(to: outputURL) ? 0 : 1)
        }

        if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-settings-previews"),
            CommandLine.arguments.indices.contains(previewIndex + 1)
        {
            _ = NSApplication.shared
            let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1], isDirectory: true)
            exit(PalettePreviewRenderer.renderSettingsCatalog(to: outputURL) ? 0 : 1)
        }

        if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-workbench-previews"),
            CommandLine.arguments.indices.contains(previewIndex + 1)
        {
            _ = NSApplication.shared
            exit(WorkspacePreviewRenderer.renderWorkbench(to: URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1], isDirectory: true)) ? 0 : 1)
        }

        if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-workspace-previews"),
            CommandLine.arguments.indices.contains(previewIndex + 1)
        {
            _ = NSApplication.shared
            let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1], isDirectory: true)
            let language: WidgetLanguage = CommandLine.arguments.contains("--preview-english") ? .en : .zh
            exit(WorkspacePreviewRenderer.render(to: outputURL, language: language) ? 0 : 1)
        }

        if CommandLine.arguments.contains("--preview-home-interaction") {
            HomeInteractionPreview.show()
            return
        }

        if CommandLine.arguments.contains("--preview-device-login-interaction") {
            CodexDeviceLoginPreviewRenderer.showInteractive()
            return
        }

        if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-device-login-previews"),
            CommandLine.arguments.indices.contains(previewIndex + 1)
        {
            _ = NSApplication.shared
            exit(CodexDeviceLoginPreviewRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1], isDirectory: true)) ? 0 : 1)
        }

        if let previewIndex = CommandLine.arguments.firstIndex(of: "--render-setup-previews"),
            CommandLine.arguments.indices.contains(previewIndex + 1)
        {
            _ = NSApplication.shared
            let outputURL = URL(fileURLWithPath: CommandLine.arguments[previewIndex + 1], isDirectory: true)
            exit(NextSetupPreviewRenderer.render(to: outputURL) ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-webview-bridge") {
            exit(WKWebViewBridgeSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-particle-animation") {
            exit(QuotaParticleAnimationSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-rate-limits") {
            exit(CodexRateLimitNormalizerSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-updates") {
            exit(AppUpdateSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-statistics-time-zone") {
            exit(StatisticsTimeZoneSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-token-counter") {
            exit(CodexTokenCounterNormalizerSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-model-pricing") {
            exit(ModelPricingSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-model-usage-trend") {
            exit(ModelUsageTrendSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-model-inference-performance") {
            exit(ModelInferencePerformanceSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-app-server-pipe") {
            exit(
                POSIXPipeReaderSelfTest.run()
                    && CodexThreadHistoryProbeSelfTest.run()
                    && CodexAccountLoginProtocolSelfTest.run()
                    && CodexDeviceLoginSelfTest.run()
                    && UsageStore.deviceLoginTargetSelfTest()
                    && UsageStore.deviceLoginEscapeShortcutSelfTest()
                    ? 0 : 1
            )
        }

        if let probeIndex = CommandLine.arguments.firstIndex(of: "--probe-thread-history-id"),
            CommandLine.arguments.indices.contains(probeIndex + 1)
        {
            let completed = DispatchSemaphore(value: 0)
            var result: Result<CodexThreadHistorySnapshot, CodexThreadHistoryError>?
            DispatchQueue.global(qos: .utility).async {
                result = CodexThreadHistoryProbe.capture(
                    threadID: CommandLine.arguments[probeIndex + 1]
                )
                completed.signal()
            }
            guard completed.wait(timeout: .now() + 20) == .success,
                let result
            else {
                print("Codex thread history metadata probe timed out")
                exit(1)
            }
            switch result {
            case .success(let snapshot):
                print("Codex thread history metadata probe passed: \(snapshot.turnIDs.count) turns")
                exit(0)
            case .failure(let error):
                print("Codex thread history metadata probe failed: \(error.localizedDescription)")
                exit(1)
            }
        }

        if CommandLine.arguments.contains("--self-test-cc-switch") {
            exit(CCSwitchUsageReaderSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-profile-store") {
            exit(
                CodexProfileStoreSelfTest.run()
                    && NextAppInstanceLease.selfTest()
                    && TerminalAppLauncher.selfTest()
                    && AccountDisplay.selfTest()
                    ? 0 : 1
            )
        }

        if CommandLine.arguments.contains("--self-test-workspace-screenshot") {
            _ = NSApplication.shared
            exit(WorkspaceScreenshotSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-quota-provider-wiring") {
            exit(QuotaProviderWiringSelfTest.run() && AppIconStyleSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-token-monitor-ui") {
            _ = NSApplication.shared
            exit(TokenMonitorUISelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments == [CommandLine.arguments[0], "--send-authorized-public-reset-update"] {
            IntegrationPushCommand.sendAuthorizedPublicResetUpdate()
        }

        if CommandLine.arguments.contains("--submit-authorized-push") {
            exit(IntegrationPushCommand.run())
        }

        if CommandLine.arguments.contains("--self-test-main-window-layout") {
            exit(AccountCardGridLayout.selfTest() && CrossProviderQuotaSummary.selfTest() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-account-floating-panel") {
            exit(AccountFloatingPanelStateStore.selfTest() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-brand-assets") {
            exit(AHBrandAssetsSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-account-inspection") {
            // Preserve the test CLI contract after merging inspection into account cards.
            exit(AccountTaskStatusSelfTest.run() && TaskStatusCopy.selfTest() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-automatic-account-switch") {
            exit(CodexAutomaticSwitchPolicySelfTest.run() && NextLocalNotificationService.selfTest() && NextFeatureDefaults.selfTest() && NextSetupProgress.selfTest() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-warm-up-policy") {
            exit(CodexWarmUpPolicySelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-feishu-webhook") {
            exit(FeishuWebhookServiceSelfTest.run() && FeishuTaskCompletionObserverSelfTest.run() && MessageChannelsControllerSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-account-automation-audit") {
            exit(AccountAutomationAuditStoreSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-account-switch-safety") {
            exit(
                CodexAccountSwitchSafetySelfTest.run()
                    && HubWarmUpGateSelfTest.run()
                    && CodexWarmUpProtocolSelfTest.run()
                    ? 0 : 1
            )
        }

        if CommandLine.arguments.contains("--self-test-task-runtime") {
            exit(TaskRuntimeSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-leadership-model") {
            exit(LeadershipModelSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-codex-session-link") {
            exit(CodexSessionLinkSelfTest.run() && BundledSkill.selfTest() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-performance-monitor") {
            exit(PerformanceMonitorSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--self-test-phase-one-gate") {
            exit(PhaseOneGateSelfTest.run() ? 0 : 1)
        }

        if CommandLine.arguments.contains("--evaluate-phase-one-gate") {
            exit(PhaseOneGateCommand.run(arguments: CommandLine.arguments))
        }

        if CommandLine.arguments.contains("--dump-json") {
            dumpJSON(MultiRuntimeUsageReader().load())
            return
        }

        if let owner = NextAppInstanceLease.runningOwner() {
            _ = owner.activate(options: [.activateAllWindows])
            return
        }
        do {
            guard let lease = try NextAppInstanceLease.acquire(in: DispatchParticipationPaths.supportDirectory()) else {
                _ = NextAppInstanceLease.runningOwner()?.activate(options: [.activateAllWindows])
                return
            }
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(lease) { app.run() }
        } catch {
            let alert = NSAlert()
            alert.messageText = WidgetLanguage.storedOrAutomatic().text("无法安全启动 Next", "Next could not start safely")
            alert.informativeText = WidgetLanguage.storedOrAutomatic().text(
                "无法取得账号管理器的独占运行锁。请检查应用支持目录的权限后重试。",
                "The account manager could not acquire its exclusive run lock. Check the application support folder permissions and try again.")
            alert.runModal()
            exit(1)
        }
    }
}
