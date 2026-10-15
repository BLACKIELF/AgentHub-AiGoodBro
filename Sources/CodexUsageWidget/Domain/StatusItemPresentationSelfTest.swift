import Cocoa

enum StatusItemPresentationSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
            }
        }

        func imageContains(_ image: NSImage, colorMatching predicate: (NSColor) -> Bool) -> Bool {
            guard let bitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { return false }
            return (0..<bitmap.pixelsHigh).contains { y in
                (0..<bitmap.pixelsWide).contains { x in
                    bitmap.colorAt(x: x, y: y).map(predicate) ?? false
                }
            }
        }

        func writeLabeledStatusItem(
            _ image: NSImage,
            caption: String,
            appearance: NSAppearance,
            to url: URL
        ) -> Bool {
            let canvas = NSSize(width: max(280, image.size.width + 24), height: image.size.height + 32)
            let output = NSImage(size: canvas)
            var wrote = false
            appearance.performAsCurrentDrawingAppearance {
                output.lockFocus()
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
                let captionAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                (caption as NSString).draw(at: NSPoint(x: 8, y: canvas.height - 16), withAttributes: captionAttributes)
                image.draw(
                    at: NSPoint(x: 8, y: 8),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                output.unlockFocus()
                wrote = true
            }
            guard wrote,
                let tiff = output.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else { return false }
            do {
                try png.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }

        expect(TokenFormatter.format(nil) == "--", "missing tokens should remain unavailable")
        expect(TokenFormatter.format(999) == "999", "sub-thousand tokens should remain unabridged")
        expect(TokenFormatter.format(1_000) == "1.0K", "thousands should use K")
        expect(TokenFormatter.format(999_949) == "999.9K", "values below the rounded boundary should stay in K")
        expect(TokenFormatter.format(999_950) == "1.0M", "rounded K boundary should promote to M")
        expect(TokenFormatter.format(999_999_999) == "1.0B", "rounded M boundary should promote to B")
        expect(TokenFormatter.format(1_234_567_890) == "1.2B", "billions should use B")
        expect(TokenFormatter.format(-1_234_567) == "-1.2M", "negative values should preserve their sign")
        expect(TokenFormatter.formatChineseTotal(nil) == "--", "missing Chinese total should remain unavailable")
        expect(TokenFormatter.formatChineseTotal(3_916_737_420) == "39.2 亿", "Chinese total should use 亿")
        expect(WidgetLanguage.en.tokens(3_916_737_420) == "3.9B", "English totals must not use Chinese units")
        expect(WidgetLanguage.zh.tokens(3_916_737_420) == "39.2 亿", "Chinese totals must retain their units")
        expect(
            WidgetLanguage.en.dateTime(Date(timeIntervalSince1970: 1_800_000_000)).range(of: "\\p{Han}", options: .regularExpression) == nil,
            "English dates must not inherit the system language")
        expect(AccountDisplay.masked("longname0917@example.test") == "lon•••917", "email should hide its domain and middle")
        expect(AccountDisplay.masked("abc@example.test") == "abc", "short email names should remain readable")
        expect(AccountDisplay.masked("账号 2") == "账号 2", "non-email profile names should remain unchanged")
        expect(AccountDisplay.masked("@handle") == "@handle", "handle-like names should not be mistaken for email addresses")
        expect(AccountDisplay.masked("name@") == "name@", "incomplete email-like names should remain unchanged")
        expect(RemainingQuotaHealth.classify(nil) == .unavailable, "missing quota should remain neutral")
        expect(RemainingQuotaHealth.classify(24.99) == .critical, "quota below 25% should be red")
        expect(RemainingQuotaHealth.classify(25) == .warning, "quota from 25% should be yellow")
        expect(RemainingQuotaHealth.classify(55) == .healthy, "quota from 55% should be blue")

        let suiteName = "CodexManagerNext.status-item-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            print("status item self-test failed: could not create UserDefaults suite")
            return false
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let defaultPreferences = StatusItemPreferencesStore.load(defaults: defaults)
        expect(defaultPreferences == .accountRing, "missing keys should load the single account ring")
        expect(QuotaDisplayMode.used.drawsClockwise, "used quota should draw clockwise")
        expect(!QuotaDisplayMode.remaining.drawsClockwise, "remaining quota should draw counterclockwise")
        expect(QuotaDisplayMode.used.startsAtLeadingEdge, "used linear bar should start at the leading edge")
        expect(!QuotaDisplayMode.remaining.startsAtLeadingEdge, "remaining linear bar should start at the trailing edge")

        defaults.set(
            [StatusItemMetric.fiveHourQuota.rawValue, StatusItemMetric.sevenDayQuota.rawValue],
            forKey: StatusItemPreferencesStore.visibleMetricsKey
        )
        defaults.removeObject(forKey: StatusItemPreferencesStore.metricsSchemaVersionKey)
        let migratedPreferences = StatusItemPreferencesStore.load(defaults: defaults)
        expect(
            migratedPreferences.visibleMetrics == [.fiveHourQuota, .sevenDayQuota]
                && defaults.integer(forKey: StatusItemPreferencesStore.metricsSchemaVersionKey) == StatusItemPreferencesStore.currentMetricsSchemaVersion,
            "legacy menu migration preserves explicit metrics and upgrades the schema"
        )

        defaults.set(
            [StatusItemMetric.fiveHourQuota.rawValue, StatusItemMetric.sevenDayQuota.rawValue],
            forKey: StatusItemPreferencesStore.visibleMetricsKey
        )
        defaults.set(StatusItemPreferencesStore.currentMetricsSchemaVersion, forKey: StatusItemPreferencesStore.metricsSchemaVersionKey)
        let explicitCurrentPreferences = StatusItemPreferencesStore.load(defaults: defaults)
        expect(
            explicitCurrentPreferences.visibleMetrics == [.fiveHourQuota, .sevenDayQuota],
            "current preferences should preserve an explicit monthly deselection"
        )

        defaults.set("unknown-mode", forKey: StatusItemPreferencesStore.displayModeKey)
        defaults.set("unknown-direction", forKey: StatusItemPreferencesStore.quotaModeKey)
        defaults.set([], forKey: StatusItemPreferencesStore.visibleMetricsKey)
        let repairedPreferences = StatusItemPreferencesStore.load(defaults: defaults)
        expect(repairedPreferences.displayMode == .classic, "unknown display mode should fall back to the numeric ring")
        expect(repairedPreferences.quotaMode == .remaining, "unknown quota mode should fall back to remaining")
        expect(
            repairedPreferences.visibleMetrics == [.sevenDayQuota],
            "empty visible metrics should be repaired to the 7-day quota"
        )

        var noMetrics = StatusItemPreferences.default
        noMetrics.visibleMetrics = []
        expect(noMetrics.validationError() == .requiresVisibleMetric, "empty metrics should be rejected")

        var minimalTokensOnly = StatusItemPreferences.default
        minimalTokensOnly.displayMode = .minimal
        minimalTokensOnly.visibleMetrics = [.todayTokens]
        expect(
            minimalTokensOnly.validationError() == .minimalRequiresQuotaMetric,
            "minimal mode should require a quota metric"
        )
        expect(
            minimalTokensOnly.normalized().hasVisibleQuota,
            "stored minimal token-only state should repair itself"
        )

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = StatusItemSourceSnapshot(
            runtime: .codex,
            fiveHourRemainingPercent: 89,
            fiveHourResetsAt: now.addingTimeInterval(90 * 60),
            sevenDayRemainingPercent: 76,
            sevenDayResetsAt: now.addingTimeInterval(26 * 60 * 60),
            monthlyRemainingPercent: nil,
            monthlyResetsAt: nil,
            todayTokens: 1_234_567
        )
        let builder = StatusItemPresentationBuilder()

        var usedPreferences = StatusItemPreferences.default
        usedPreferences.visibleMetrics.insert(.todayTokens)
        let used = builder.build(
            source: source,
            preferences: usedPreferences,
            language: .en,
            now: now
        )
        let usedFiveHour = used.metrics.first { $0.metric == .fiveHourQuota }
        let usedSevenDay = used.metrics.first { $0.metric == .sevenDayQuota }
        expect(usedFiveHour?.value == "11%", "used mode should invert remaining percentage")
        expect(usedFiveHour?.fraction == 0.11, "used mode ring fraction should match its number")
        expect(usedFiveHour?.paletteRole == .primary, "5h should use the main blue ring palette")
        expect(usedSevenDay?.paletteRole == .secondary, "7d should use the main purple ring palette")
        expect(usedFiveHour?.resetText == "1h", "reset countdown should use injected time")
        expect(usedSevenDay?.resetText == "1d", "long reset countdown should prefer days")
        expect(used.todayMetric?.value == "1.2M", "today tokens should use compact formatting")
        expect(used.tooltip.contains("used"), "English tooltip should name the quota direction")
        expect(used.tooltip.contains("resets in 1 hour"), "English tooltip should explain the reset countdown")
        expect(used.accessibilityValue.contains("resets in 1 day"), "VoiceOver should explain day-based resets")

        var remainingPreferences = usedPreferences
        remainingPreferences.quotaMode = .remaining
        let remaining = builder.build(
            source: source,
            preferences: remainingPreferences,
            language: .zh,
            now: now
        )
        let remainingFiveHour = remaining.metrics.first { $0.metric == .fiveHourQuota }
        expect(remainingFiveHour?.value == "89%", "remaining mode should preserve remaining percentage")
        expect(remainingFiveHour?.fraction == 0.89, "remaining ring fraction should match its number")
        expect(remainingFiveHour?.paletteRole == .primary, "quota direction must not change palette identity")
        expect(remaining.tooltip.contains("剩余"), "Chinese tooltip should name the quota direction")
        expect(remaining.accessibilityValue.contains("1 小时后重置"), "Chinese VoiceOver should explain reset timing")

        for rawFiveHour: Double? in [82, nil] {
            let exhausted = StatusItemSourceSnapshot(
                runtime: .codex, fiveHourRemainingPercent: rawFiveHour,
                fiveHourResetsAt: source.fiveHourResetsAt,
                sevenDayRemainingPercent: 0, sevenDayResetsAt: source.sevenDayResetsAt,
                todayTokens: nil
            )
            let zero = builder.build(source: exhausted, preferences: remainingPreferences, language: .en, now: now)
            expect(zero.metrics.first { $0.metric == .fiveHourQuota }?.value == "0%", "weekly exhaustion must show zero 5h availability, including a missing 5h window")
            expect(zero.metrics.first { $0.metric == .fiveHourQuota }?.fraction == 0, "weekly exhaustion must empty the 5h ring")
            expect(zero.metrics.first { $0.metric == .sevenDayQuota }?.value == "0%", "weekly exhaustion must keep the 7d value at zero")
            expect(exhausted.fiveHourRemainingPercent == rawFiveHour, "displaying effective availability must not mutate the source")
        }
        let recovered = builder.build(source: source, preferences: remainingPreferences, language: .en, now: now)
        expect(recovered.metrics.first { $0.metric == .fiveHourQuota }?.value == "89%", "a recovered weekly window must reveal the official 5h value again")
        let claudeIndependent = StatusItemSourceSnapshot(
            runtime: .claudeCode, fiveHourRemainingPercent: 82, fiveHourResetsAt: nil,
            sevenDayRemainingPercent: 0, sevenDayResetsAt: nil, todayTokens: nil
        )
        expect(
            builder.build(source: claudeIndependent, preferences: remainingPreferences, language: .en, now: now).metrics.first { $0.metric == .fiveHourQuota }?.value == "82%",
            "Codex availability policy must not change Claude presentation")

        var withoutResetPreferences = remainingPreferences
        withoutResetPreferences.showsResetCountdown = false
        let withoutReset = builder.build(
            source: source,
            preferences: withoutResetPreferences,
            language: .zh,
            now: now
        )
        expect(
            withoutReset.quotaMetrics.allSatisfy { $0.resetText == nil },
            "disabling reset countdown should remove compact reset values"
        )
        expect(
            !withoutReset.accessibilityValue.contains("后重置"),
            "disabling reset countdown should remove reset wording from VoiceOver"
        )

        let clampedSource = StatusItemSourceSnapshot(
            runtime: .claudeCode,
            fiveHourRemainingPercent: -10,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: 110,
            sevenDayResetsAt: nil,
            monthlyRemainingPercent: nil,
            monthlyResetsAt: nil,
            todayTokens: nil
        )
        let clamped = builder.build(
            source: clampedSource,
            preferences: remainingPreferences,
            language: .en,
            now: now
        )
        expect(clamped.metrics.first { $0.metric == .fiveHourQuota }?.value == "0%", "negative quota should clamp to zero")
        expect(clamped.metrics.first { $0.metric == .sevenDayQuota }?.value == "100%", "quota above 100 should clamp")
        expect(clamped.todayMetric?.isAvailable == false, "missing token data should remain unavailable")

        let sevenDayOnlySource = StatusItemSourceSnapshot(
            runtime: .codex,
            status: .available,
            fiveHourRemainingPercent: nil,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: 76,
            sevenDayResetsAt: now.addingTimeInterval(26 * 60 * 60),
            monthlyRemainingPercent: nil,
            monthlyResetsAt: nil,
            todayTokens: 1_234_567
        )
        let sevenDayOnly = builder.build(
            source: sevenDayOnlySource,
            preferences: .default,
            language: .en,
            now: now
        )
        expect(sevenDayOnly.quotaMetrics.count == 1, "7d-only data should collapse to one quota")
        expect(
            sevenDayOnly.quotaMetrics.first?.metric == .sevenDayQuota,
            "the surviving single quota should be 7d"
        )
        expect(
            sevenDayOnly.quotaMetrics.first?.paletteRole == .secondary,
            "a single 7d quota must preserve its secondary Palette identity"
        )
        expect(!sevenDayOnly.tooltip.contains("5h"), "tooltip should omit a collapsed 5h quota")
        expect(
            !sevenDayOnly.accessibilityValue.contains("5h"),
            "accessibility text should omit a collapsed 5h quota"
        )

        let monthlyOnlySource = StatusItemSourceSnapshot(
            runtime: .codex,
            fiveHourRemainingPercent: nil,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: nil,
            sevenDayResetsAt: nil,
            monthlyRemainingPercent: 62,
            monthlyResetsAt: now.addingTimeInterval(12 * 24 * 60 * 60),
            todayTokens: nil
        )
        let monthlyOnly = builder.build(
            source: monthlyOnlySource,
            preferences: StatusItemPreferences.default,
            language: .zh,
            now: now
        )
        expect(monthlyOnly.quotaMetrics.count == 1, "monthly-only data should collapse to one quota")
        expect(
            monthlyOnly.quotaMetrics.first?.label == "mo",
            "monthly long-period quota should use the mo status-item label"
        )
        expect(
            monthlyOnly.quotaMetrics.first?.paletteRole == .secondary,
            "monthly-only status should use the documented secondary fallback"
        )
        expect(
            monthlyOnly.tooltip.contains("月额度"),
            "Chinese tooltip should name monthly quota"
        )
        let monthlyEnglish = builder.build(
            source: monthlyOnlySource,
            preferences: StatusItemPreferences.default,
            language: .en,
            now: now
        )
        expect(
            monthlyEnglish.tooltip.contains("monthly quota"),
            "English tooltip should name monthly quota"
        )

        let bothLongSource = StatusItemSourceSnapshot(
            runtime: .codex,
            fiveHourRemainingPercent: nil,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: 76,
            sevenDayResetsAt: now.addingTimeInterval(6 * 24 * 60 * 60),
            monthlyRemainingPercent: 62,
            monthlyResetsAt: now.addingTimeInterval(12 * 24 * 60 * 60),
            todayTokens: nil
        )
        let bothLong = builder.build(
            source: bothLongSource,
            preferences: .default,
            language: .en,
            now: now
        )
        expect(
            bothLong.quotaMetrics.map(\.metric) == [.sevenDayQuota, .monthlyQuota],
            "7d and monthly quotas should both remain visible when returned together"
        )
        expect(
            bothLong.quotaMetrics.map(\.paletteRole) == [.secondary, .primary],
            "7d should remain secondary while monthly uses the free primary fallback"
        )

        var disappearedSelection = StatusItemPreferences.default
        disappearedSelection.visibleMetrics = [.fiveHourQuota]
        let fallbackSelection = builder.build(
            source: sevenDayOnlySource,
            preferences: disappearedSelection,
            language: .en,
            now: now
        )
        expect(
            fallbackSelection.quotaMetrics.map(\.metric) == [.sevenDayQuota],
            "when every selected quota disappears, the current real quota should be shown temporarily"
        )

        var todayOnlyPreferences = StatusItemPreferences.default
        todayOnlyPreferences.visibleMetrics = [.todayTokens]
        let todayOnly = builder.build(
            source: sevenDayOnlySource,
            preferences: todayOnlyPreferences,
            language: .en,
            now: now
        )
        expect(todayOnly.quotaMetrics.isEmpty, "token-only preferences must not inject an unselected quota")
        expect(todayOnly.todayMetric?.isAvailable == true, "token-only preferences should keep the token metric")

        let restoredDual = builder.build(
            source: source,
            preferences: .default,
            language: .en,
            now: now
        )
        expect(
            restoredDual.quotaMetrics.map(\.metric) == [.fiveHourQuota, .sevenDayQuota],
            "5h should return automatically in its original order when data resumes"
        )

        var minimalPreferences = StatusItemPreferences.default
        minimalPreferences.displayMode = .minimal
        let minimal = builder.build(source: source, preferences: minimalPreferences, language: .en, now: now)
        expect(minimal.itemLength <= 36, "minimal double-ring item should stay within 36pt")
        let minimalOuterRingRect = StatusItemLayoutMetrics.minimalOuterRingRect
        let minimalInnerRingRect = StatusItemLayoutMetrics.minimalInnerRingRect
        expect(
            minimalOuterRingRect.midX == minimalInnerRingRect.midX
                && minimalOuterRingRect.midY == minimalInnerRingRect.midY,
            "minimal quota rings should share one center"
        )
        let minimalInnerRingOuterRadius = StatusItemLayoutMetrics.minimalInnerRingDiameter / 2
        let minimalOuterRingInnerRadius =
            StatusItemLayoutMetrics.minimalOuterRingDiameter / 2
            - StatusItemLayoutMetrics.minimalOuterRingLineWidth
        expect(
            minimalInnerRingOuterRadius + StatusItemLayoutMetrics.minimalRingClearance
                <= minimalOuterRingInnerRadius,
            "minimal quota rings should remain visibly separated"
        )
        let renderer = StatusItemRenderer()
        let lightTokens = ResolvedVisualTokens.safeDefault(.light)
        let darkTokens = ResolvedVisualTokens.safeDefault(.dark)
        let minimalImage = renderer.render(minimal, tokens: lightTokens, appearance: NSAppearance(named: .aqua))
        if let bitmap = minimalImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
            let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        {
            expect(center.alphaComponent < 0.01, "minimal mode center should remain transparent without a runtime logo")
        } else {
            failures.append("minimal status item render should produce a readable bitmap")
        }

        let singleMinimal = builder.build(
            source: sevenDayOnlySource,
            preferences: minimalPreferences,
            language: .en,
            now: now
        )
        expect(singleMinimal.quotaMetrics.count == 1, "minimal mode should draw one ring for 7d-only data")
        expect(
            singleMinimal.imageSize.width == minimal.imageSize.width,
            "minimal mode should keep its compact width when switching to one outer ring"
        )
        let todayTokenFont = NSFont.monospacedDigitSystemFont(
            ofSize: StatusItemLayoutMetrics.todayTokenFontSize,
            weight: .semibold
        )
        let maximumTokenWidth = ("999.9M" as NSString).size(withAttributes: [.font: todayTokenFont]).width
        expect(
            maximumTokenWidth <= StatusItemLayoutMetrics.classicTokenUnitWidth - 4,
            "menu bar body-sized token text should fit its fixed classic slot"
        )
        expect(
            maximumTokenWidth <= StatusItemLayoutMetrics.richTokenExtensionWidth - 4,
            "menu bar body-sized token text should fit its fixed rich slot"
        )

        var classicPreferences = StatusItemPreferences.default
        classicPreferences.displayMode = .classic
        let classic = builder.build(source: source, preferences: classicPreferences, language: .en, now: now)
        expect(classic.itemLength <= 88, "classic double-ring item should stay within 88pt")
        expect(classic.mode == .classic, "classic presentation should select the number-ring renderer")
        let aquaImage = renderer.render(classic, tokens: lightTokens, appearance: NSAppearance(named: .aqua))
        let darkImage = renderer.render(classic, tokens: darkTokens, appearance: NSAppearance(named: .darkAqua))
        expect(aquaImage.size == classic.imageSize, "Aqua render should preserve presentation size")
        expect(darkImage.size == classic.imageSize, "Dark Aqua render should preserve presentation size")
        let paletteCatalog = PaletteCatalog.loadFromMainBundle()
        for paletteID in paletteCatalog.paletteIDs {
            for paletteAppearance in PaletteAppearance.allCases {
                let tokens = paletteCatalog.resolve(id: paletteID, appearance: paletteAppearance)
                let appearance = NSAppearance(named: paletteAppearance == .dark ? .darkAqua : .aqua)
                let image = renderer.render(classic, tokens: tokens, appearance: appearance)
                expect(image.size == classic.imageSize, "\(paletteID) \(paletteAppearance.rawValue) should preserve menu bar geometry")
                expect(image.tiffRepresentation != nil, "\(paletteID) \(paletteAppearance.rawValue) should render a bitmap")
            }
        }
        if let bitmap = aquaImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
            let corner = bitmap.colorAt(x: 0, y: 0)
        {
            expect(corner.alphaComponent < 0.01, "status item image background should remain transparent")
        } else {
            failures.append("status item render should produce a readable bitmap")
        }

        let singleClassic = builder.build(
            source: sevenDayOnlySource,
            preferences: classicPreferences,
            language: .en,
            now: now
        )
        expect(singleClassic.quotaMetrics.count == 1, "classic mode should draw one numeric ring")
        expect(
            singleClassic.itemLength + StatusItemLayoutMetrics.classicQuotaUnitWidth == classic.itemLength,
            "classic mode should release exactly one quota slot for 7d-only data"
        )
        expect(singleClassic.itemLength == 33, "classic single-quota item should use the icon-free 33pt width")

        let accountRing = builder.build(
            source: sevenDayOnlySource,
            preferences: .accountRing,
            language: .zh,
            now: now
        )
        let accountRingImage = renderer.render(accountRing, tokens: lightTokens, appearance: NSAppearance(named: .aqua))
        expect(accountRing.itemLength == 33, "account ring should contain no leading runtime logo")
        expect(
            imageContains(accountRingImage) { $0.blueComponent > $0.redComponent + 0.2 && $0.blueComponent > 0.5 },
            "healthy remaining quota should render a blue ring"
        )
        let lowQuotaSource = StatusItemSourceSnapshot(
            runtime: .codex,
            fiveHourRemainingPercent: nil,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: 13,
            sevenDayResetsAt: nil,
            todayTokens: nil
        )
        let lowAccountRing = builder.build(
            source: lowQuotaSource,
            preferences: .accountRing,
            language: .zh,
            now: now
        )
        let lowAccountRingImage = renderer.render(lowAccountRing, tokens: lightTokens, appearance: NSAppearance(named: .aqua))
        expect(
            imageContains(lowAccountRingImage) { $0.redComponent > $0.blueComponent + 0.2 && $0.redComponent > 0.6 },
            "low remaining quota should render a red ring"
        )

        let rich = builder.build(source: source, preferences: .default, language: .en, now: now)
        expect(rich.itemLength <= 134, "default rich item should stay compact after adding reset semantics")
        expect(rich.quotaMetrics.count == 2, "rich mode should keep two rows when both quotas exist")

        let singleRich = builder.build(
            source: sevenDayOnlySource,
            preferences: .default,
            language: .en,
            now: now
        )
        expect(singleRich.quotaMetrics.count == 1, "rich mode should use its single-quota layout")
        expect(singleRich.itemLength == rich.itemLength, "rich single-quota layout should keep a stable menu width")
        expect(
            StatusItemLayoutMetrics.richSingleQuotaBarRect.width == 49
                && StatusItemLayoutMetrics.richSingleQuotaBarRect.height == 13
                && StatusItemLayoutMetrics.richSingleQuotaBarRect.midY
                    == StatusItemLayoutMetrics.imageHeight / 2,
            "rich single-quota percentage bar should be a centered 49x13 capsule"
        )
        expect(
            StatusItemLayoutMetrics.richSingleQuotaResetRect.midY
                == StatusItemLayoutMetrics.imageHeight / 2,
            "the rich reset countdown group should share the status item's vertical center"
        )
        expect(
            StatusItemLayoutMetrics.richSingleQuotaResetRect.minX
                - StatusItemLayoutMetrics.richSingleQuotaBarRect.maxX >= 2
                && StatusItemLayoutMetrics.richSingleQuotaResetRect.maxX
                    < StatusItemLayoutMetrics.richQuotaWidthWithReset,
            "the rich reset group should have a stable centered slot without touching adjacent content"
        )
        for resetText in ["7d", "23h", "9m", "59m"] {
            expect(
                StatusItemLayoutMetrics.richResetContentWidth(for: resetText)
                    <= StatusItemLayoutMetrics.richSingleQuotaResetRect.width,
                "the rich reset slot should fit the normal countdown boundary \(resetText)"
            )
        }
        let singleRichAqua = renderer.render(singleRich, tokens: lightTokens, appearance: NSAppearance(named: .aqua))
        let singleRichDark = renderer.render(singleRich, tokens: darkTokens, appearance: NSAppearance(named: .darkAqua))
        expect(singleRichAqua.size == singleRich.imageSize, "single rich Aqua render should preserve its size")
        expect(singleRichDark.size == singleRich.imageSize, "single rich Dark Aqua render should preserve its size")
        if let bitmap = singleRichAqua.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) {
            let scaleX = CGFloat(bitmap.pixelsWide) / singleRichAqua.size.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / singleRichAqua.size.height
            let barCenter = StatusItemLayoutMetrics.richSingleQuotaBarRect
            let color = bitmap.colorAt(
                x: Int((barCenter.midX * scaleX).rounded(.down)),
                y: Int((barCenter.midY * scaleY).rounded(.down))
            )
            expect(
                (color?.alphaComponent ?? 0) > 0.05,
                "rich single-quota capsule should render progress and its centered percentage"
            )

            let resetRect = StatusItemLayoutMetrics.richSingleQuotaResetRect
            let minPixelX = Int((resetRect.minX * scaleX).rounded(.down))
            let maxPixelX = Int((resetRect.maxX * scaleX).rounded(.up)) - 1
            let minPixelY = Int((resetRect.minY * scaleY).rounded(.down))
            let maxPixelY = Int((resetRect.maxY * scaleY).rounded(.up)) - 1
            var inkX: [Int] = []
            var inkY: [Int] = []
            for y in minPixelY...maxPixelY {
                for x in minPixelX...maxPixelX
                where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    inkX.append(x)
                    inkY.append(y)
                }
            }
            if let minInkX = inkX.min(), let maxInkX = inkX.max(),
                let minInkY = inkY.min(), let maxInkY = inkY.max()
            {
                let inkMidX = CGFloat(minInkX + maxInkX + 1) / 2 / scaleX
                let inkMidY = CGFloat(minInkY + maxInkY + 1) / 2 / scaleY
                expect(
                    abs(inkMidX - resetRect.midX) <= 1.25,
                    "the reset icon and countdown should be optically centered in their slot"
                )
                expect(
                    abs(inkMidY - resetRect.midY) <= 1.25,
                    "the reset icon and countdown should be vertically centered with the progress capsule"
                )
            } else {
                failures.append("rich single-quota reset group should render visible icon and text")
            }
        } else {
            failures.append("single rich status item render should produce a readable bitmap")
        }

        func resetInkBounds(in image: NSImage) -> NSRect? {
            guard let bitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
                return nil
            }
            let scaleX = CGFloat(bitmap.pixelsWide) / image.size.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / image.size.height
            let startX = max(
                0,
                Int(((StatusItemLayoutMetrics.richSingleQuotaBarRect.maxX + 1) * scaleX).rounded(.down))
            )
            var minX = bitmap.pixelsWide
            var maxX = -1
            var minY = bitmap.pixelsHigh
            var maxY = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in startX..<bitmap.pixelsWide
                where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return NSRect(
                x: CGFloat(minX) / scaleX,
                y: CGFloat(minY) / scaleY,
                width: CGFloat(maxX - minX + 1) / scaleX,
                height: CGFloat(maxY - minY + 1) / scaleY
            )
        }

        let minuteResetSource = StatusItemSourceSnapshot(
            runtime: .codex,
            status: .available,
            fiveHourRemainingPercent: nil,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: 76,
            sevenDayResetsAt: now.addingTimeInterval(59 * 60),
            monthlyRemainingPercent: nil,
            monthlyResetsAt: nil,
            todayTokens: nil
        )
        let minuteResetSingle = builder.build(
            source: minuteResetSource,
            preferences: .default,
            language: .en,
            now: now
        )
        expect(
            minuteResetSingle.quotaMetrics.first?.resetText == "59m",
            "the minute-boundary fixture should render the longest normal reset label"
        )
        let minuteResetSingleImage = renderer.render(
            minuteResetSingle,
            tokens: lightTokens,
            appearance: NSAppearance(named: .aqua)
        )
        if let bounds = resetInkBounds(in: minuteResetSingleImage) {
            expect(
                bounds.minX >= StatusItemLayoutMetrics.richSingleQuotaResetRect.minX - 0.5
                    && bounds.maxX <= StatusItemLayoutMetrics.richSingleQuotaResetRect.maxX + 0.5,
                "59m single-quota reset ink must stay inside its centered slot"
            )
        } else {
            failures.append("59m single-quota reset group should render visible ink")
        }

        let minuteResetDualSource = StatusItemSourceSnapshot(
            runtime: .codex,
            status: .available,
            fiveHourRemainingPercent: 80,
            fiveHourResetsAt: now.addingTimeInterval(59 * 60),
            sevenDayRemainingPercent: 76,
            sevenDayResetsAt: now.addingTimeInterval(23 * 60 * 60),
            monthlyRemainingPercent: nil,
            monthlyResetsAt: nil,
            todayTokens: nil
        )
        let minuteResetDual = builder.build(
            source: minuteResetDualSource,
            preferences: .default,
            language: .en,
            now: now
        )
        expect(
            minuteResetDual.quotaMetrics.map(\.resetText) == ["59m", "23h"],
            "dual-quota reset fixtures should preserve their compact countdowns"
        )
        let minuteResetDualImage = renderer.render(
            minuteResetDual,
            tokens: lightTokens,
            appearance: NSAppearance(named: .aqua)
        )
        if let bounds = resetInkBounds(in: minuteResetDualImage) {
            expect(
                bounds.minX >= StatusItemLayoutMetrics.richSingleQuotaResetRect.minX - 0.5
                    && bounds.maxX <= StatusItemLayoutMetrics.richSingleQuotaResetRect.maxX + 0.5,
                "minute/hour dual-quota reset ink must stay inside the shared centered slot"
            )
        } else {
            failures.append("minute/hour dual-quota reset groups should render visible ink")
        }

        let unavailable = builder.build(
            source: .unavailable(runtime: .codex),
            preferences: classicPreferences,
            language: .en,
            now: now
        )
        expect(
            unavailable.itemLength == classic.itemLength,
            "initial loading should preserve configured quota placeholders instead of collapsing to zero"
        )
        expect(unavailable.quotaMetrics.count == 2, "loading should retain two topology-neutral quota placeholders")
        expect(unavailable.quotaMetrics.allSatisfy { !$0.isAvailable }, "missing quotas should stay unavailable")

        let emptyAvailableSource = StatusItemSourceSnapshot(
            runtime: .codex,
            status: .available,
            fiveHourRemainingPercent: nil,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: nil,
            sevenDayResetsAt: nil,
            monthlyRemainingPercent: nil,
            monthlyResetsAt: nil,
            todayTokens: nil
        )
        let emptyAvailable = builder.build(
            source: emptyAvailableSource,
            preferences: classicPreferences,
            language: .en,
            now: now
        )
        expect(emptyAvailable.quotaMetrics.isEmpty, "an authoritative zero-limit response must hide quota slots")
        expect(emptyAvailable.showsNoActiveQuota, "an authoritative zero-limit response should expose its neutral state")
        expect(emptyAvailable.tooltip.contains("no active quota limits"), "zero-limit tooltip should explain the state")
        expect(
            emptyAvailable.accessibilityValue.contains("no active quota limits"),
            "zero-limit accessibility text should explain the state"
        )
        let emptyAvailableImage = renderer.render(
            emptyAvailable,
            tokens: lightTokens,
            appearance: NSAppearance(named: .aqua)
        )
        if let bitmap = emptyAvailableImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) {
            let hasVisiblePixel = (0..<bitmap.pixelsHigh).contains { y in
                (0..<bitmap.pixelsWide).contains { x in
                    (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
                }
            }
            expect(hasVisiblePixel, "zero-limit classic state should render a visible neutral indicator")
        } else {
            failures.append("zero-limit status item render should produce a readable bitmap")
        }

        let emptyMinimal = builder.build(
            source: emptyAvailableSource,
            preferences: minimalPreferences,
            language: .en,
            now: now
        )
        expect(emptyMinimal.quotaMetrics.isEmpty, "zero-limit minimal state should not draw empty rings")
        expect(emptyMinimal.showsNoActiveQuota, "zero-limit minimal state should draw the neutral infinity marker")

        let staleEmptySource = StatusItemSourceSnapshot(
            runtime: .codex,
            status: .stale,
            fiveHourRemainingPercent: nil,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: nil,
            sevenDayResetsAt: nil,
            monthlyRemainingPercent: nil,
            monthlyResetsAt: nil,
            todayTokens: nil
        )
        let staleEmpty = builder.build(
            source: staleEmptySource,
            preferences: classicPreferences,
            language: .en,
            now: now
        )
        expect(staleEmpty.quotaMetrics.count == 2, "an empty stale snapshot must retain its previous placeholders")
        expect(!staleEmpty.showsNoActiveQuota, "stale data must not claim that no limits exist")

        let localOnlyWithPartialQuota = StatusItemSourceSnapshot(
            runtime: .codex,
            status: .localOnly,
            fiveHourRemainingPercent: nil,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: 76,
            sevenDayResetsAt: nil,
            monthlyRemainingPercent: nil,
            monthlyResetsAt: nil,
            todayTokens: nil
        )
        let uncertainTopology = builder.build(
            source: localOnlyWithPartialQuota,
            preferences: classicPreferences,
            language: .en,
            now: now
        )
        expect(
            uncertainTopology.quotaMetrics.count == 2,
            "non-authoritative local-only data must not redefine the quota topology"
        )

        expect(used.tooltip.hasPrefix("\(AHBrandIdentity.displayName) · "), "menu bar tooltip must use the AiGoodBro display name")
        expect(!used.tooltip.contains("Codex Control"), "menu bar tooltip must not keep the old Codex Control name")
        expect(used.tooltip.contains("Codex"), "quota tooltip must keep the Codex provider identity")
        expect(used.accessibilityValue.contains("Codex"), "VoiceOver must keep the Codex provider identity")
        expect(
            unavailable.quotaMetrics.allSatisfy { $0.value == "--" && !$0.isAvailable },
            "unknown quota values must stay -- and must not be filled with 0"
        )
        expect(clamped.todayMetric?.value == "--", "missing token totals must stay --")

        let claudeRichSource = StatusItemSourceSnapshot(
            runtime: .claudeCode,
            fiveHourRemainingPercent: 64,
            fiveHourResetsAt: now.addingTimeInterval(90 * 60),
            sevenDayRemainingPercent: 41,
            sevenDayResetsAt: now.addingTimeInterval(26 * 60 * 60),
            todayTokens: 999_949
        )
        var claudeRichPreferences = StatusItemPreferences.default
        claudeRichPreferences.visibleMetrics.insert(.todayTokens)
        let claudeRich = builder.build(source: claudeRichSource, preferences: claudeRichPreferences, language: .en, now: now)
        expect(claudeRich.tooltip.contains("Claude Code"), "Claude quota must keep its provider identity")
        expect(claudeRich.todayMetric?.value == "999.9K", "long token values must stay compact without promoting early")
        let claudeRichImage = renderer.render(claudeRich, tokens: lightTokens, appearance: NSAppearance(named: .aqua))
        expect(claudeRichImage.size == claudeRich.imageSize, "Claude rich render must keep its layout size")
        if let bitmap = claudeRichImage.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) {
            let scaleX = CGFloat(bitmap.pixelsWide) / claudeRichImage.size.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / claudeRichImage.size.height
            let logoSample = bitmap.colorAt(
                x: Int((11 * scaleX).rounded(.down)),
                y: Int((11 * scaleY).rounded(.down))
            )
            expect((logoSample?.alphaComponent ?? 0) > 0.05, "rich mode must keep the provider icon and must not replace it with an AH mark")
            expect(
                CGFloat(bitmap.pixelsWide) >= claudeRich.imageSize.width,
                "long rich values must not clip the rendered menu bar bitmap"
            )
        } else {
            failures.append("Claude rich status item render should produce a readable bitmap")
        }

        let outputRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("review-outputs/0911v11", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            var remainingCapture = remainingPreferences
            remainingCapture.displayMode = .classic
            var usedCapture = usedPreferences
            usedCapture.displayMode = .classic
            let captures: [(String, StatusItemPresentation, NSAppearance.Name)] = [
                ("synthetic-menubar-minimal-remaining-light", builder.build(source: source, preferences: minimalPreferences, language: .zh, now: now), .aqua),
                ("synthetic-menubar-classic-remaining-light", builder.build(source: source, preferences: remainingCapture, language: .zh, now: now), .aqua),
                ("synthetic-menubar-classic-used-dark", builder.build(source: source, preferences: usedCapture, language: .en, now: now), .darkAqua),
                ("synthetic-menubar-rich-remaining-light", remaining, .aqua),
                ("synthetic-menubar-rich-claude-light", claudeRich, .aqua),
                ("synthetic-menubar-unknown-classic-light", unavailable, .aqua),
            ]
            for (name, presentation, appearanceName) in captures {
                guard let appearance = NSAppearance(named: appearanceName) else {
                    failures.append("missing appearance \(appearanceName.rawValue) for \(name)")
                    continue
                }
                let image = renderer.render(presentation, tokens: appearanceName == .darkAqua ? darkTokens : lightTokens, appearance: appearance)
                let caption = AHBrandIdentity.syntheticCaption("\(presentation.mode.rawValue) \(presentation.quotaMode.rawValue) \(presentation.runtime.displayName)")
                if !writeLabeledStatusItem(image, caption: caption, appearance: appearance, to: outputRoot.appendingPathComponent("\(name)@2x.png")) {
                    failures.append("could not write synthetic capture \(name)")
                }
            }
        } catch {
            failures.append("could not create synthetic capture directory")
        }

        if failures.isEmpty {
            print("status item self-test passed")
            return true
        }

        for failure in failures {
            print("status item self-test failed: \(failure)")
        }
        return false
    }
}
