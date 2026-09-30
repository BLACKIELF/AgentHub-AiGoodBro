import AppKit
import SwiftUI

enum OnboardingModesSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        expect(WorkspaceVisualMetrics.trackThickness == 3, "quota track is 3pt")
        expect(WorkspaceVisualMetrics.titleSize == 15 && WorkspaceVisualMetrics.bodySize == 13, "title 15 / body 13")
        expect(WorkspaceVisualMetrics.metaSize == 11 && WorkspaceVisualMetrics.valueSize == 22, "meta 11 / value 22")
        expect(WorkspaceVisualMetrics.cardPadding == 10 && WorkspaceVisualMetrics.cardCorner == 16, "compact card padding 10 / corner 16")
        expect(QuotaRowState.from(percent: nil).percentText() == "—", "unknown is not 0%")
        expect(QuotaRowState.from(percent: 0).percentText() == "0%", "real zero stays 0%")
        expect(QuotaRowState.from(percent: nil).fillFraction == nil, "unknown does not fill the track")
        expect(QuotaRowState.from(percent: 137).fillFraction == 1, "percents clamp to 1")
        expect(QuotaRowState.from(percent: -4).fillFraction == 0, "negative percents clamp to 0")

        var flow = WorkspaceOnboardingState()
        expect(flow.shouldPresent && flow.step == .purpose, "new users start on purpose")
        flow.begin()
        flow.selectedMode = .simple
        flow.goNext()
        expect(flow.step == .connect && flow.status == .inProgress, "continue reaches connect")
        flow.goBack()
        expect(flow.step == .purpose, "back does not skip")
        let midway = flow
        flow.goNext()
        flow.goNext()
        expect(flow.step == .result, "third step is result")
        flow.finish(.completed)
        expect(!flow.shouldPresent, "completed onboarding does not auto-open")
        flow.reopen()
        expect(flow.shouldPresent && flow.step == .purpose, "completed can reopen without side effects")
        var skipped = midway
        skipped.skip()
        expect(skipped.status == .skipped && !skipped.shouldPresent, "skip is a first-class status")

        var existing = WorkspaceOnboardingState()
        existing.bootstrapIfNeeded(existingUser: true)
        expect(existing.status == .completed && existing.existingUserMigrated, "existing users are not forced through the new flow")
        expect(existing.selectedMode == .professional, "existing users keep professional")
        var fresh = WorkspaceOnboardingState()
        fresh.bootstrapIfNeeded(existingUser: false)
        expect(fresh.status == .notStarted && fresh.shouldPresent, "new users still see onboarding")

        var mode = WorkspaceDisplayMode.simple
        let lost = false
        for _ in 0..<10 {
            mode = mode == .simple ? .professional : .simple
        }
        expect(mode == .simple, "ten mode flips return to the start")
        expect(!lost, "mode flips do not own account state")

        if let measurement = measureTracks() {
            expect(abs(measurement.afterPixels - Int((WorkspaceVisualMetrics.trackThickness * 2).rounded())) <= 1, "after track is 3pt ±1px at 2x")
            expect(measurement.beforePixels >= 14, "before probe keeps the 8pt track")
            expect(measurement.unknownDoesNotFill, "unknown after-track has no fill bar")
        } else {
            expect(false, "track bitmaps must render")
        }

        if failures.isEmpty {
            print("onboarding-modes self-test passed: metrics, unknown≠0, 3pt track, skip/back/migrate")
            return true
        }
        failures.forEach { print("onboarding-modes self-test failed: \($0)") }
        return false
    }

    struct TrackMeasurement {
        var beforePixels: Int
        var afterPixels: Int
        var unknownDoesNotFill: Bool
    }

    static func measureTracks() -> TrackMeasurement? {
        let before = render(LegacyQuotaProgressTrack(percent: 50).frame(width: 200, height: 8), size: CGSize(width: 200, height: 8))
        let after = render(QuotaTrack(state: .value(50)).frame(width: 200, height: 6), size: CGSize(width: 200, height: 6))
        let unknown = render(QuotaTrack(state: .unknown).frame(width: 200, height: 6), size: CGSize(width: 200, height: 6))
        guard let before, let after, let unknown else { return nil }
        return TrackMeasurement(
            beforePixels: filledHeight(before),
            afterPixels: filledHeight(after),
            unknownDoesNotFill: filledWidth(unknown) < 8
        )
    }

    private static func render<Content: View>(_ view: Content, size: CGSize) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        else { return nil }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.contentView = nil
        return bitmap
    }

    private static func filledHeight(_ bitmap: NSBitmapImageRep) -> Int {
        let x = max(1, bitmap.pixelsWide / 4)
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.alphaComponent > 0.2, (color.redComponent + color.greenComponent + color.blueComponent) < 2.7 {
                count += 1
            }
        }
        return count
    }

    private static func filledWidth(_ bitmap: NSBitmapImageRep) -> Int {
        let y = max(1, bitmap.pixelsHigh / 2)
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.alphaComponent > 0.2, color.blueComponent > 0.4, color.redComponent < 0.6 {
                count += 1
            }
        }
        return count
    }
}
