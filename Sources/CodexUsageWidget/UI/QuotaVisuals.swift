import Cocoa
import SwiftUI

private enum QuotaRingGeometry {
    static let outerDiameter: CGFloat = 145
    static let innerDiameter: CGFloat = 107
    static let lineWidth: CGFloat = 16
    static let dualCenterDiameter: CGFloat = 72
    static let singleCenterDiameter: CGFloat = 110
    static let outerRadius = (outerDiameter - lineWidth) / 2
    static let innerRadius = (innerDiameter - lineWidth) / 2
    static let center = CGPoint(x: outerDiameter / 2, y: outerDiameter / 2)
}

private extension QuotaWindowKind {
    var compactTitle: String {
        switch self {
        case .fiveHour: "5h"
        case .sevenDay: "7d"
        case .monthly: "mo"
        }
    }
}

private extension QuotaPaletteRole {
    func tokens(in visualTokens: ResolvedVisualTokens) -> QuotaRoleTokenSet {
        switch self {
        case .primary: visualTokens.quota.primary
        case .secondary: visualTokens.quota.secondary
        }
    }

    var ringAssetSlot: PaletteAssetSlot {
        switch self {
        case .primary: .quotaRingPrimary
        case .secondary: .quotaRingSecondary
        }
    }

    var capAssetSlot: PaletteAssetSlot {
        switch self {
        case .primary: .quotaCapPrimary
        case .secondary: .quotaCapSecondary
        }
    }
}

private enum QuotaRingPosition: Equatable {
    case outer
    case inner
}

private struct QuotaRingItem: Identifiable, Equatable {
    let kind: QuotaWindowKind
    let window: RateWindow
    let paletteRole: QuotaPaletteRole
    let position: QuotaRingPosition

    var id: QuotaWindowKind { kind }

    var remainingText: String {
        "\(Int(window.remainingPercent.rounded()))%"
    }

    var particleProgress: CGFloat? {
        let progress = CGFloat(max(0, min(1, window.remainingPercent / 100)))
        return progress > 0.02 ? progress : nil
    }
}

private struct QuotaParticleLane: Equatable {
    let radius: CGFloat
    let progress: CGFloat?
    let maximumCount: Int
    let phaseOffset: Double
}

private struct QuotaRingPresentation: Equatable {
    enum Topology: Equatable {
        case none
        case single
        case dual
    }

    let items: [QuotaRingItem]

    init(fiveHourQuota: RateWindow?, sevenDayQuota: RateWindow?, monthlyQuota: RateWindow?) {
        var windows: [(QuotaWindowKind, RateWindow)] = []
        if let fiveHourQuota {
            windows.append((.fiveHour, fiveHourQuota))
        }
        if let sevenDayQuota {
            windows.append((.sevenDay, sevenDayQuota))
        }
        if let monthlyQuota {
            windows.append((.monthly, monthlyQuota))
        }
        let activeKinds = Set(windows.map(\.0))
        self.items = windows.enumerated().map { index, entry in
            QuotaRingItem(
                kind: entry.0,
                window: entry.1,
                paletteRole: QuotaPaletteRoleResolver.role(
                    for: entry.0,
                    activeKinds: activeKinds
                ),
                position: index == 0 ? .outer : .inner
            )
        }
    }

    var topology: Topology {
        switch items.count {
        case 0: return .none
        case 1: return .single
        default: return .dual
        }
    }

    var particleLanes: [QuotaParticleLane] {
        switch topology {
        case .none:
            return []
        case .single:
            return items.prefix(1).map {
                QuotaParticleLane(
                    radius: QuotaRingGeometry.outerRadius,
                    progress: $0.particleProgress,
                    maximumCount: 17,
                    phaseOffset: 0
                )
            }
        case .dual:
            return [
                QuotaParticleLane(
                    radius: QuotaRingGeometry.outerRadius,
                    progress: items[0].particleProgress,
                    maximumCount: 17,
                    phaseOffset: 0
                ),
                QuotaParticleLane(
                    radius: QuotaRingGeometry.innerRadius,
                    progress: items[1].particleProgress,
                    maximumCount: 12,
                    phaseOffset: 0.31
                ),
            ]
        }
    }

    var activeRadii: [CGFloat] {
        particleLanes.map(\.radius)
    }

    func diameter(for item: QuotaRingItem) -> CGFloat {
        guard topology == .dual, item.position == .inner else {
            return QuotaRingGeometry.outerDiameter
        }
        return QuotaRingGeometry.innerDiameter
    }
}

private enum QuotaRingHoverTarget {
    private static let bounds = CGRect(
        x: 0,
        y: 0,
        width: QuotaRingGeometry.outerDiameter,
        height: QuotaRingGeometry.outerDiameter
    )
    private static let hitSlop: CGFloat = 10

    static func contains(_ location: CGPoint, activeRadii: [CGFloat]) -> Bool {
        guard bounds.contains(location), !activeRadii.isEmpty else { return false }
        let distance = hypot(
            location.x - QuotaRingGeometry.center.x,
            location.y - QuotaRingGeometry.center.y
        )
        return activeRadii.contains { abs(distance - $0) <= hitSlop }
    }
}

/// Shared percentage display. Missing data stays empty rather than becoming 0%.
struct QuotaPercentageRing: View {
    let percent: Double?
    var diameter: CGFloat = 40
    var lineWidth: CGFloat = 3
    var tint: Color? = nil
    var showsValue = true
    var accessibilityTitle: String? = nil
    @Environment(\.widgetLanguage) private var language

    private var value: Double? {
        percent.flatMap { $0.isFinite ? max(0, min(100, $0)) : nil }
    }

    var body: some View {
        ZStack {
            Circle().strokeBorder(FixedVisualPalette.surfaceTrack, lineWidth: lineWidth)
            if let value, value > 0 {
                if let tint {
                    Circle().inset(by: lineWidth / 2)
                        .trim(from: 0, to: CGFloat(value / 100))
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    QuotaRingSegment(percent: value, lineWidth: lineWidth)
                }
            }
            if showsValue {
                Text(QuotaAvailabilityPresentation.percentText(value))
                    .font(.system(size: max(9, diameter * 0.25), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(lineWidth + 2)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle ?? language.text("剩余额度", "Remaining quota"))
        .accessibilityValue(value.map { QuotaAvailabilityPresentation.percentText($0) } ?? language.text("未知", "Unknown"))
    }
}

struct QuotaRingSegment: View {
    let percent: Double
    let lineWidth: CGFloat

    var body: some View {
        let progress = CGFloat(max(0, min(1, percent / 100)))
        let healthColors = RemainingQuotaHealth.classify(percent).colors
        let colors = [Color(nsColor: healthColors.end), Color(nsColor: healthColors.start)]
        ZStack {
            Circle()
                .strokeBorder(FixedVisualPalette.surfaceTrack, lineWidth: lineWidth)

            if progress > 0.001 {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            colors: colors,
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(max(1, Double(progress) * 360))
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

private enum QuotaParticleRenderPolicy {
    static func shouldRender(
        hasProgress: Bool,
        energyMode: VisualEnergyMode,
        animationMode: ParticleAnimationMode,
        reduceMotion: Bool,
        isPointerOverRing: Bool,
        isLowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState,
        appIsActive: Bool,
        appIsHidden: Bool,
        appIsFrontmost: Bool,
        windowIsVisible: Bool,
        windowIsMiniaturized: Bool,
        windowIsKey: Bool,
        windowIsOnActiveSpace: Bool,
        windowIsOccluded: Bool
    ) -> Bool {
        hasProgress
            && energyMode == .normal
            && !reduceMotion
            && !isLowPowerModeEnabled
            && thermalState == .nominal
            && appIsActive
            && !appIsHidden
            && appIsFrontmost
            && windowIsVisible
            && !windowIsMiniaturized
            && windowIsKey
            && windowIsOnActiveSpace
            && !windowIsOccluded
            && (animationMode == .standard || isPointerOverRing)
    }
}

private struct DualQuotaRingParticles: NSViewRepresentable {
    private struct ParticleStyle {
        let phase: Double
        let speed: Double
        let radialOffset: CGFloat
        let diameter: CGFloat
        let opacity: Double
    }

    private static let styles = [
        ParticleStyle(phase: 0.04, speed: 0.095, radialOffset: -2.8, diameter: 1.3, opacity: 0.52),
        ParticleStyle(phase: 0.24, speed: 0.122, radialOffset: 2.5, diameter: 2.2, opacity: 0.78),
        ParticleStyle(phase: 0.45, speed: 0.076, radialOffset: -0.4, diameter: 2.9, opacity: 0.90),
        ParticleStyle(phase: 0.66, speed: 0.274, radialOffset: 3.0, diameter: 1.2, opacity: 0.46),
        ParticleStyle(phase: 0.86, speed: 0.104, radialOffset: -2.0, diameter: 1.8, opacity: 0.66),
        ParticleStyle(phase: 0.14, speed: 0.083, radialOffset: 0.9, diameter: 2.5, opacity: 0.82),
        ParticleStyle(phase: 0.56, speed: 0.116, radialOffset: -3.1, diameter: 1.4, opacity: 0.50),
        ParticleStyle(phase: 0.34, speed: 0.068, radialOffset: 1.7, diameter: 0.9, opacity: 0.38),
        ParticleStyle(phase: 0.74, speed: 0.154, radialOffset: -1.2, diameter: 2.0, opacity: 0.72),
        ParticleStyle(phase: 0.94, speed: 0.111, radialOffset: 2.1, diameter: 1.1, opacity: 0.58),
        ParticleStyle(phase: 0.51, speed: 0.126, radialOffset: -2.4, diameter: 1.7, opacity: 0.64),
        ParticleStyle(phase: 0.09, speed: 0.142, radialOffset: 1.4, diameter: 1.5, opacity: 0.62),
        ParticleStyle(phase: 0.19, speed: 0.091, radialOffset: -1.8, diameter: 1.0, opacity: 0.44),
        ParticleStyle(phase: 0.29, speed: 0.182, radialOffset: 2.7, diameter: 1.8, opacity: 0.70),
        ParticleStyle(phase: 0.62, speed: 0.073, radialOffset: -0.8, diameter: 2.3, opacity: 0.76),
        ParticleStyle(phase: 0.81, speed: 0.133, radialOffset: -2.6, diameter: 1.2, opacity: 0.54),
        ParticleStyle(phase: 0.99, speed: 0.108, radialOffset: 1.9, diameter: 1.6, opacity: 0.60),
    ]

    static var maximumParticleRadialExtentForTesting: CGFloat {
        styles.map { abs($0.radialOffset) + $0.diameter / 2 }.max() ?? 0
    }

    let lanes: [QuotaParticleLane]
    let energyMode: VisualEnergyMode
    let animationMode: ParticleAnimationMode
    let reduceMotion: Bool
    let isPointerOverRing: Bool

    func makeNSView(context: Context) -> QuotaRingParticleHostView {
        let view = QuotaRingParticleHostView(frame: .zero)
        view.configure(
            lanes: lanes,
            energyMode: energyMode,
            animationMode: animationMode,
            reduceMotion: reduceMotion,
            isPointerOverRing: isPointerOverRing
        )
        return view
    }

    func updateNSView(_ nsView: QuotaRingParticleHostView, context: Context) {
        nsView.configure(
            lanes: lanes,
            energyMode: energyMode,
            animationMode: animationMode,
            reduceMotion: reduceMotion,
            isPointerOverRing: isPointerOverRing
        )
    }

    static func dismantleNSView(_ nsView: QuotaRingParticleHostView, coordinator: ()) {
        nsView.prepareForRemoval()
    }

    final class QuotaRingParticleHostView: NSView {
        private let particleContainer = CALayer()
        private var lanes: [QuotaParticleLane] = []
        private var energyMode: VisualEnergyMode = .suspended
        private var animationMode: ParticleAnimationMode = .standard
        private var reduceMotion = false
        private var isPointerOverRing = false
        private var renderedSize = CGSize.zero
        private var renderedScale: CGFloat = 0
        private var isRenderingParticles = false
        private var isPreparedForRemoval = false
        private var testingEligibilityOverride: Bool?
        private var windowObservers: [NSObjectProtocol] = []
        private var applicationObservers: [NSObjectProtocol] = []
        private var processObservers: [NSObjectProtocol] = []
        private var workspaceObservers: [NSObjectProtocol] = []

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = false
            particleContainer.masksToBounds = false
            particleContainer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(particleContainer)
            installLifecycleObservers()
        }

        required init?(coder: NSCoder) {
            nil
        }

        deinit {
            removeLifecycleObservers()
            removeWindowObservers()
        }

        func configure(
            lanes: [QuotaParticleLane],
            energyMode: VisualEnergyMode,
            animationMode: ParticleAnimationMode,
            reduceMotion: Bool,
            isPointerOverRing: Bool
        ) {
            guard !isPreparedForRemoval else { return }
            let lanes = lanes.map { lane in
                QuotaParticleLane(
                    radius: lane.radius,
                    progress: clampedProgress(lane.progress),
                    maximumCount: lane.maximumCount,
                    phaseOffset: lane.phaseOffset
                )
            }
            let lanesChanged = lanes != self.lanes

            self.lanes = lanes
            self.energyMode = energyMode
            self.animationMode = animationMode
            self.reduceMotion = reduceMotion
            self.isPointerOverRing = isPointerOverRing

            reconcileRendering(forceRebuild: lanesChanged)
        }

        func prepareForRemoval() {
            guard !isPreparedForRemoval else { return }
            isPreparedForRemoval = true
            clearParticles()
            removeWindowObservers()
            removeLifecycleObservers()
        }

        func setEligibilityOverrideForTesting(_ isEligible: Bool?) {
            testingEligibilityOverride = isEligible
            reconcileRendering()
        }

        var particleSublayerCountForTesting: Int {
            particleContainer.sublayers?.count ?? 0
        }

        var particleAnimationCountForTesting: Int {
            particleContainer.sublayers?.reduce(0) { count, layer in
                count + (layer.animationKeys()?.count ?? 0)
            } ?? 0
        }

        var particleAnimationPathsFitRingStrokeForTesting: Bool {
            guard let particles = particleContainer.sublayers, !particles.isEmpty else { return false }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let halfLineWidth = QuotaRingGeometry.lineWidth / 2

            return particles.allSatisfy { particle in
                let halfDiagonal = hypot(particle.bounds.width / 2, particle.bounds.height / 2)
                guard
                    pointFitsRingStroke(
                        particle.position,
                        center: center,
                        halfDiagonal: halfDiagonal,
                        halfLineWidth: halfLineWidth
                    ),
                    let group = particle.animation(forKey: "quota-flow") as? CAAnimationGroup,
                    let position = group.animations?.compactMap({ $0 as? CAKeyframeAnimation })
                        .first(where: { $0.keyPath == "position" }),
                    let path = position.path
                else { return false }

                var pathFits = true
                var previousPoint: CGPoint?
                path.applyWithBlock { elementPointer in
                    guard pathFits else { return }
                    let element = elementPointer.pointee
                    switch element.type {
                    case .moveToPoint:
                        pathFits = pointFitsRingStroke(
                            element.points[0],
                            center: center,
                            halfDiagonal: halfDiagonal,
                            halfLineWidth: halfLineWidth
                        )
                        previousPoint = element.points[0]
                    case .addLineToPoint:
                        guard let segmentStart = previousPoint else {
                            pathFits = false
                            return
                        }
                        let point = element.points[0]
                        let halfSegmentLength =
                            hypot(
                                point.x - segmentStart.x,
                                point.y - segmentStart.y
                            ) / 2
                        pathFits =
                            pointFitsRingStroke(
                                segmentStart,
                                center: center,
                                halfDiagonal: halfDiagonal + halfSegmentLength,
                                halfLineWidth: halfLineWidth
                            )
                            && pointFitsRingStroke(
                                point,
                                center: center,
                                halfDiagonal: halfDiagonal + halfSegmentLength,
                                halfLineWidth: halfLineWidth
                            )
                        previousPoint = point
                    case .closeSubpath:
                        break
                    case .addQuadCurveToPoint, .addCurveToPoint:
                        pathFits = false
                    @unknown default:
                        pathFits = false
                    }
                }
                return pathFits
            }
        }

        override func layout() {
            super.layout()
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let geometryChanged = renderedSize != bounds.size || abs(renderedScale - scale) > 0.01

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            particleContainer.frame = bounds
            particleContainer.contentsScale = scale
            CATransaction.commit()

            renderedSize = bounds.size
            renderedScale = scale
            reconcileRendering(forceRebuild: geometryChanged)
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            renderedScale = 0
            needsLayout = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeWindowObservers()
            guard !isPreparedForRemoval, let window else {
                clearParticles()
                return
            }

            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.willCloseNotification,
            ]
            windowObservers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] notification in
                    if notification.name == NSWindow.willCloseNotification {
                        self?.clearParticles()
                    } else {
                        self?.reconcileRendering()
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.reconcileRendering()
            }
        }

        private func reconcileRendering(forceRebuild: Bool = false) {
            guard !isPreparedForRemoval else {
                clearParticles()
                return
            }
            guard shouldRenderParticles else {
                clearParticles()
                return
            }
            guard bounds.width > 0, bounds.height > 0 else { return }
            guard forceRebuild || !isRenderingParticles else { return }
            rebuildAnimations()
        }

        private var shouldRenderParticles: Bool {
            if let testingEligibilityOverride {
                return testingEligibilityOverride
                    && lanes.contains { $0.progress != nil }
                    && (animationMode == .standard || isPointerOverRing)
            }
            guard let window else { return false }
            let processInfo = ProcessInfo.processInfo
            let currentProcessIdentifier = processInfo.processIdentifier
            let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return QuotaParticleRenderPolicy.shouldRender(
                hasProgress: lanes.contains { $0.progress != nil },
                energyMode: energyMode,
                animationMode: animationMode,
                reduceMotion: reduceMotion,
                isPointerOverRing: pointerIsActuallyOverRing(in: window),
                isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
                thermalState: processInfo.thermalState,
                appIsActive: NSApp.isActive,
                appIsHidden: NSApp.isHidden,
                appIsFrontmost: frontmostProcessIdentifier == currentProcessIdentifier,
                windowIsVisible: window.isVisible,
                windowIsMiniaturized: window.isMiniaturized,
                windowIsKey: window.isKeyWindow,
                windowIsOnActiveSpace: window.isOnActiveSpace,
                windowIsOccluded: !window.occlusionState.contains(.visible)
            )
        }

        private func pointerIsActuallyOverRing(in window: NSWindow) -> Bool {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            return QuotaRingHoverTarget.contains(
                location,
                activeRadii: lanes.map(\.radius)
            )
        }

        private func pointFitsRingStroke(
            _ point: CGPoint,
            center: CGPoint,
            halfDiagonal: CGFloat,
            halfLineWidth: CGFloat
        ) -> Bool {
            let radius = hypot(point.x - center.x, point.y - center.y)
            guard
                let centerlineDistance =
                    lanes
                    .map({ abs(radius - $0.radius) })
                    .min()
            else { return false }
            return centerlineDistance + halfDiagonal <= halfLineWidth + 0.001
        }

        private func rebuildAnimations() {
            clearParticles()
            guard shouldRenderParticles else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            lanes.forEach { lane in
                addParticles(
                    center: center,
                    radius: lane.radius,
                    progress: lane.progress,
                    maximumCount: lane.maximumCount,
                    phaseOffset: lane.phaseOffset
                )
            }
            CATransaction.commit()
            isRenderingParticles = !(particleContainer.sublayers?.isEmpty ?? true)
        }

        private func clearParticles() {
            guard isRenderingParticles || !(particleContainer.sublayers?.isEmpty ?? true) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            particleContainer.sublayers?.forEach { particle in
                particle.removeAllAnimations()
                particle.removeFromSuperlayer()
            }
            CATransaction.commit()
            isRenderingParticles = false
        }

        private func addParticles(
            center: CGPoint,
            radius: CGFloat,
            progress: CGFloat?,
            maximumCount: Int,
            phaseOffset: Double
        ) {
            guard let progress, progress > 0.02 else { return }
            let activeCount = min(
                maximumCount,
                max(1, Int(ceil(Double(maximumCount) * min(1, Double(progress) * 1.5))))
            )
            let activeStyles = Array(DualQuotaRingParticles.styles.prefix(activeCount))
            let speedFactor = quotaSpeedFactor(for: progress)
            let fastParticleCount = max(1, Int((Double(activeCount) * 0.3).rounded()))
            let fastParticleIndexes = Set(
                activeStyles.indices
                    .sorted {
                        actualSpeed(
                            for: activeStyles[$0],
                            progress: progress,
                            speedFactor: speedFactor
                        )
                            > actualSpeed(
                                for: activeStyles[$1],
                                progress: progress,
                                speedFactor: speedFactor
                            )
                    }
                    .prefix(fastParticleCount)
            )

            for (index, style) in activeStyles.enumerated() {
                let particleRadius = radius + style.radialOffset
                let path = particlePath(center: center, radius: particleRadius, progress: progress)
                let startPosition = arcPoint(center: center, radius: particleRadius, progress: progress)
                let duration = animationDuration(
                    for: style,
                    progress: progress,
                    speedFactor: speedFactor
                )
                let phase = (style.phase + phaseOffset).truncatingRemainder(dividingBy: 1)

                if fastParticleIndexes.contains(index) {
                    addAnimatedParticle(
                        style: style,
                        path: path,
                        startPosition: startPosition,
                        duration: duration,
                        phase: phase,
                        diameterScale: 0.40,
                        opacityScale: 0.12,
                        lag: 0.135
                    )
                    addAnimatedParticle(
                        style: style,
                        path: path,
                        startPosition: startPosition,
                        duration: duration,
                        phase: phase,
                        diameterScale: 0.58,
                        opacityScale: 0.24,
                        lag: 0.090
                    )
                    addAnimatedParticle(
                        style: style,
                        path: path,
                        startPosition: startPosition,
                        duration: duration,
                        phase: phase,
                        diameterScale: 0.78,
                        opacityScale: 0.42,
                        lag: 0.045
                    )
                }

                addAnimatedParticle(
                    style: style,
                    path: path,
                    startPosition: startPosition,
                    duration: duration,
                    phase: phase
                )
            }
        }

        private func addAnimatedParticle(
            style: ParticleStyle,
            path: CGPath,
            startPosition: CGPoint,
            duration: Double,
            phase: Double,
            diameterScale: CGFloat = 1,
            opacityScale: Double = 1,
            lag: Double = 0
        ) {
            let diameter = style.diameter * diameterScale
            let particle = CALayer()
            particle.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            particle.cornerRadius = diameter / 2
            particle.backgroundColor = FixedVisualPalette.dataFlowParticle.cgColor
            particle.opacity = 0
            particle.position = startPosition
            particle.contentsScale = particleContainer.contentsScale
            particleContainer.addSublayer(particle)

            let position = CAKeyframeAnimation(keyPath: "position")
            position.path = path
            position.calculationMode = .paced

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            let visibleOpacity = style.opacity * opacityScale
            opacity.values = [0, visibleOpacity, visibleOpacity, 0]
            opacity.keyTimes = [0, 0.08, 0.88, 1]

            let animation = CAAnimationGroup()
            animation.animations = [position, opacity]
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30,
                maximum: 60,
                preferred: 60
            )
            animation.beginTime = CACurrentMediaTime()
            let rawOffset = (duration * phase - lag).truncatingRemainder(dividingBy: duration)
            animation.timeOffset = rawOffset >= 0 ? rawOffset : rawOffset + duration
            animation.isRemovedOnCompletion = false
            particle.add(animation, forKey: "quota-flow")
        }

        private func quotaSpeedFactor(for progress: CGFloat) -> Double {
            0.45 + Double(progress) * 1.10
        }

        private func animationDuration(
            for style: ParticleStyle,
            progress: CGFloat,
            speedFactor: Double
        ) -> Double {
            max(1.6, Double(progress) / (style.speed * speedFactor))
        }

        private func actualSpeed(
            for style: ParticleStyle,
            progress: CGFloat,
            speedFactor: Double
        ) -> Double {
            let duration = animationDuration(
                for: style,
                progress: progress,
                speedFactor: speedFactor
            )
            return Double(progress) / duration
        }

        private func particlePath(center: CGPoint, radius: CGFloat, progress: CGFloat) -> CGPath {
            let path = CGMutablePath()
            let sampleCount = max(16, Int(ceil(progress * 120)))
            path.move(to: arcPoint(center: center, radius: radius, progress: progress))
            for index in 1...sampleCount {
                let fraction = CGFloat(index) / CGFloat(sampleCount)
                path.addLine(
                    to: arcPoint(
                        center: center,
                        radius: radius,
                        progress: progress * (1 - fraction)
                    ))
            }
            return path
        }

        private func arcPoint(center: CGPoint, radius: CGFloat, progress: CGFloat) -> CGPoint {
            let radians = (-90.0 + Double(progress) * 360) * .pi / 180
            return CGPoint(
                x: center.x + CGFloat(cos(radians)) * radius,
                y: center.y + CGFloat(sin(radians)) * radius
            )
        }

        private func clampedProgress(_ progress: CGFloat?) -> CGFloat? {
            guard let progress, progress > 0.02 else { return nil }
            return max(0, min(1, progress))
        }

        private func installLifecycleObservers() {
            let notificationCenter = NotificationCenter.default
            applicationObservers = [
                NSApplication.didBecomeActiveNotification,
                NSApplication.didResignActiveNotification,
                NSApplication.didHideNotification,
                NSApplication.didUnhideNotification,
            ].map { name in
                notificationCenter.addObserver(
                    forName: name,
                    object: NSApp,
                    queue: .main
                ) { [weak self] _ in
                    self?.reconcileRendering()
                    DispatchQueue.main.async { [weak self] in
                        self?.reconcileRendering()
                    }
                }
            }

            processObservers = [
                Notification.Name.NSProcessInfoPowerStateDidChange,
                ProcessInfo.thermalStateDidChangeNotification,
            ].map { name in
                notificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.reconcileRendering()
                }
            }

            workspaceObservers = [
                NSWorkspace.activeSpaceDidChangeNotification,
                NSWorkspace.didActivateApplicationNotification,
            ].map { name in
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.reconcileRendering()
                }
            }
        }

        private func removeWindowObservers() {
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers.removeAll()
        }

        private func removeLifecycleObservers() {
            applicationObservers.forEach(NotificationCenter.default.removeObserver)
            applicationObservers.removeAll()
            processObservers.forEach(NotificationCenter.default.removeObserver)
            processObservers.removeAll()
            workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            workspaceObservers.removeAll()
        }
    }
}

enum QuotaParticleAnimationSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
            }
        }

        func renders(
            hasProgress: Bool = true,
            energyMode: VisualEnergyMode = .normal,
            animationMode: ParticleAnimationMode = .standard,
            reduceMotion: Bool = false,
            isPointerOverRing: Bool = false,
            isLowPowerModeEnabled: Bool = false,
            thermalState: ProcessInfo.ThermalState = .nominal,
            appIsActive: Bool = true,
            appIsHidden: Bool = false,
            appIsFrontmost: Bool = true,
            windowIsVisible: Bool = true,
            windowIsMiniaturized: Bool = false,
            windowIsKey: Bool = true,
            windowIsOnActiveSpace: Bool = true,
            windowIsOccluded: Bool = false
        ) -> Bool {
            QuotaParticleRenderPolicy.shouldRender(
                hasProgress: hasProgress,
                energyMode: energyMode,
                animationMode: animationMode,
                reduceMotion: reduceMotion,
                isPointerOverRing: isPointerOverRing,
                isLowPowerModeEnabled: isLowPowerModeEnabled,
                thermalState: thermalState,
                appIsActive: appIsActive,
                appIsHidden: appIsHidden,
                appIsFrontmost: appIsFrontmost,
                windowIsVisible: windowIsVisible,
                windowIsMiniaturized: windowIsMiniaturized,
                windowIsKey: windowIsKey,
                windowIsOnActiveSpace: windowIsOnActiveSpace,
                windowIsOccluded: windowIsOccluded
            )
        }

        func quotaWindow(usedPercent: Double, durationMins: Int) -> RateWindow {
            RateWindow(
                usedPercent: usedPercent,
                windowDurationMins: durationMins,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }

        let fullFiveHour = quotaWindow(usedPercent: 0, durationMins: 300)
        let fullSevenDay = quotaWindow(usedPercent: 0, durationMins: 10_080)
        let fullMonthly = quotaWindow(usedPercent: 0, durationMins: 43_800)
        let noQuotaPresentation = QuotaRingPresentation(
            fiveHourQuota: nil,
            sevenDayQuota: nil,
            monthlyQuota: nil
        )
        let fiveHourOnlyPresentation = QuotaRingPresentation(
            fiveHourQuota: fullFiveHour,
            sevenDayQuota: nil,
            monthlyQuota: nil
        )
        let sevenDayOnlyPresentation = QuotaRingPresentation(
            fiveHourQuota: nil,
            sevenDayQuota: fullSevenDay,
            monthlyQuota: nil
        )
        let monthlyOnlyPresentation = QuotaRingPresentation(
            fiveHourQuota: nil,
            sevenDayQuota: nil,
            monthlyQuota: fullMonthly
        )
        let dualPresentation = QuotaRingPresentation(
            fiveHourQuota: fullFiveHour,
            sevenDayQuota: fullSevenDay,
            monthlyQuota: nil
        )
        let bothLongPresentation = QuotaRingPresentation(
            fiveHourQuota: nil,
            sevenDayQuota: fullSevenDay,
            monthlyQuota: fullMonthly
        )

        expect(noQuotaPresentation.topology == .none, "zero quota windows should use the empty presentation")
        expect(noQuotaPresentation.items.isEmpty, "empty presentation should not expose reset rows")
        expect(noQuotaPresentation.particleLanes.isEmpty, "empty presentation should not expose particle lanes")
        expect(fiveHourOnlyPresentation.topology == .single, "5h-only quota should use a single ring")
        expect(
            fiveHourOnlyPresentation.items.map(\.kind) == [.fiveHour],
            "5h-only presentation should preserve the 5h semantic"
        )
        expect(sevenDayOnlyPresentation.topology == .single, "7d-only quota should use a single ring")
        expect(
            sevenDayOnlyPresentation.items.map(\.kind) == [.sevenDay],
            "7d-only presentation should preserve the 7d semantic"
        )
        expect(
            sevenDayOnlyPresentation.items.map(\.paletteRole) == [.secondary],
            "7d-only presentation must preserve the quota.secondary identity"
        )
        expect(
            monthlyOnlyPresentation.items.map(\.paletteRole) == [.secondary],
            "monthly-only presentation should use the documented secondary fallback"
        )
        expect(
            sevenDayOnlyPresentation.particleLanes.count == 1
                && sevenDayOnlyPresentation.particleLanes[0].radius == QuotaRingGeometry.outerRadius
                && sevenDayOnlyPresentation.particleLanes[0].maximumCount == 17,
            "a single 7d quota should expand onto the full outer particle lane"
        )
        expect(dualPresentation.topology == .dual, "two quota windows should retain the dual-ring presentation")
        expect(
            dualPresentation.items.map(\.kind) == [.fiveHour, .sevenDay],
            "dual presentation should retain the stable 5h then 7d order"
        )
        expect(
            dualPresentation.items.map(\.paletteRole) == [.primary, .secondary],
            "5h and 7d must preserve their Palette Package semantic identities"
        )
        expect(
            bothLongPresentation.items.map(\.kind) == [.sevenDay, .monthly]
                && bothLongPresentation.items.map(\.paletteRole) == [.secondary, .primary]
                && bothLongPresentation.items.map(\.position) == [.outer, .inner],
            "7d should remain secondary while monthly uses the free primary fallback independent of ring geometry"
        )
        expect(
            dualPresentation.activeRadii == [
                QuotaRingGeometry.outerRadius,
                QuotaRingGeometry.innerRadius,
            ],
            "dual presentation should expose both active ring radii"
        )
        expect(
            fiveHourOnlyPresentation.items.count == 1
                && sevenDayOnlyPresentation.items.count == 1
                && monthlyOnlyPresentation.items.count == 1
                && dualPresentation.items.count == 2
                && bothLongPresentation.items.count == 2,
            "reset summary should receive only real quota rows"
        )
        expect(
            QuotaRingGeometry.singleCenterDiameter == 110,
            "single-ring center should preserve the dual-ring inner-edge clearance"
        )

        expect(renders(), "default mode should render in a focused frontmost window")
        expect(
            !renders(animationMode: .powerSaving),
            "power-saving mode should stay empty without ring hover"
        )
        expect(
            renders(animationMode: .powerSaving, isPointerOverRing: true),
            "power-saving mode should render while the ring is hovered"
        )
        expect(
            QuotaRingHoverTarget.contains(
                CGPoint(
                    x: QuotaRingGeometry.center.x,
                    y: QuotaRingGeometry.center.y - QuotaRingGeometry.outerRadius
                ), activeRadii: dualPresentation.activeRadii),
            "outer ring should be a power-saving hover target"
        )
        expect(
            QuotaRingHoverTarget.contains(
                CGPoint(
                    x: QuotaRingGeometry.center.x + QuotaRingGeometry.innerRadius,
                    y: QuotaRingGeometry.center.y
                ), activeRadii: dualPresentation.activeRadii),
            "inner ring should be a power-saving hover target"
        )
        expect(
            !QuotaRingHoverTarget.contains(
                CGPoint(
                    x: QuotaRingGeometry.center.x + QuotaRingGeometry.innerRadius,
                    y: QuotaRingGeometry.center.y
                ),
                activeRadii: sevenDayOnlyPresentation.activeRadii
            ),
            "single-ring mode should not react to the removed inner ring"
        )
        expect(
            !QuotaRingHoverTarget.contains(
                CGPoint(
                    x: QuotaRingGeometry.center.x,
                    y: QuotaRingGeometry.center.y - QuotaRingGeometry.outerRadius
                ),
                activeRadii: noQuotaPresentation.activeRadii
            ),
            "empty mode should not expose a hidden hover target"
        )
        expect(
            !QuotaRingHoverTarget.contains(
                QuotaRingGeometry.center,
                activeRadii: dualPresentation.activeRadii
            ),
            "center labels should not trigger power-saving particles"
        )
        expect(
            !QuotaRingHoverTarget.contains(
                CGPoint(x: 0, y: 0),
                activeRadii: dualPresentation.activeRadii
            ),
            "ring component corners should not trigger power-saving particles"
        )
        expect(
            abs(QuotaRingGeometry.outerRadius - 64.5) < 0.0001
                && abs(QuotaRingGeometry.innerRadius - 45.5) < 0.0001,
            "inset ring strokes should share the original particle centerline radii"
        )
        expect(
            DualQuotaRingParticles.maximumParticleRadialExtentForTesting
                <= QuotaRingGeometry.lineWidth / 2,
            "every particle pixel should remain inside the aligned ring stroke"
        )
        expect(!renders(hasProgress: false), "missing quota progress should not allocate particles")
        expect(!renders(energyMode: .suspended), "suspended visual energy mode should stop particles")
        expect(!renders(energyMode: .constrained), "constrained visual energy mode should stop particles")
        expect(!renders(reduceMotion: true), "Reduce Motion should stop particles")
        expect(!renders(isLowPowerModeEnabled: true), "Low Power Mode should stop particles")
        expect(!renders(thermalState: .fair), "thermal pressure should stop particles")
        expect(!renders(appIsActive: false), "inactive app should stop particles")
        expect(!renders(appIsHidden: true), "hidden app should stop particles")
        expect(!renders(appIsFrontmost: false), "non-frontmost app should stop particles")
        expect(!renders(windowIsVisible: false), "closed or ordered-out window should stop particles")
        expect(!renders(windowIsMiniaturized: true), "miniaturized window should stop particles")
        expect(!renders(windowIsKey: false), "unfocused window should stop particles")
        expect(!renders(windowIsOnActiveSpace: false), "window on another Space should stop particles")
        expect(!renders(windowIsOccluded: true), "occluded window should stop particles")

        let host = DualQuotaRingParticles.QuotaRingParticleHostView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: QuotaRingGeometry.outerDiameter,
                height: QuotaRingGeometry.outerDiameter
            )
        )
        host.setEligibilityOverrideForTesting(true)
        host.configure(
            lanes: [
                QuotaParticleLane(
                    radius: QuotaRingGeometry.outerRadius,
                    progress: 0.03,
                    maximumCount: 17,
                    phaseOffset: 0
                ),
                QuotaParticleLane(
                    radius: QuotaRingGeometry.innerRadius,
                    progress: 0.03,
                    maximumCount: 12,
                    phaseOffset: 0.31
                ),
            ],
            energyMode: .normal,
            animationMode: .standard,
            reduceMotion: false,
            isPointerOverRing: false
        )
        expect(
            host.particleSublayerCountForTesting == 8,
            "three-percent progress should create the expected sparse particle field"
        )
        expect(
            host.particleAnimationPathsFitRingStrokeForTesting,
            "sparse particle paths should remain inside both aligned ring strokes"
        )
        host.configure(
            lanes: [
                QuotaParticleLane(
                    radius: QuotaRingGeometry.outerRadius,
                    progress: 0.5,
                    maximumCount: 17,
                    phaseOffset: 0
                ),
                QuotaParticleLane(
                    radius: QuotaRingGeometry.innerRadius,
                    progress: 0.5,
                    maximumCount: 12,
                    phaseOffset: 0.31
                ),
            ],
            energyMode: .normal,
            animationMode: .standard,
            reduceMotion: false,
            isPointerOverRing: false
        )
        expect(
            host.particleSublayerCountForTesting == 43,
            "half progress should preserve the original particle density"
        )
        expect(
            host.particleAnimationPathsFitRingStrokeForTesting,
            "partial particle paths should remain inside both aligned ring strokes"
        )
        host.configure(
            lanes: dualPresentation.particleLanes,
            energyMode: .normal,
            animationMode: .standard,
            reduceMotion: false,
            isPointerOverRing: false
        )
        expect(
            host.particleSublayerCountForTesting == 56,
            "full original particle field should create 56 particle and trail layers"
        )
        expect(
            host.particleAnimationCountForTesting == 56,
            "every original particle and trail layer should run one quota-flow animation group"
        )
        expect(
            host.particleAnimationPathsFitRingStrokeForTesting,
            "full-circle particle paths should remain inside both aligned ring strokes"
        )
        host.configure(
            lanes: sevenDayOnlyPresentation.particleLanes,
            energyMode: .normal,
            animationMode: .standard,
            reduceMotion: false,
            isPointerOverRing: false
        )
        expect(
            host.particleSublayerCountForTesting == 32,
            "full single-ring particle field should use the outer-ring density only"
        )
        expect(
            host.particleAnimationCountForTesting == 32,
            "every single-ring particle and trail layer should run one animation group"
        )
        expect(
            host.particleAnimationPathsFitRingStrokeForTesting,
            "single-ring particle paths should fit the active outer stroke"
        )
        host.configure(
            lanes: noQuotaPresentation.particleLanes,
            energyMode: .normal,
            animationMode: .standard,
            reduceMotion: false,
            isPointerOverRing: false
        )
        expect(
            host.particleSublayerCountForTesting == 0,
            "empty presentation should immediately remove every particle layer"
        )
        host.configure(
            lanes: dualPresentation.particleLanes,
            energyMode: .normal,
            animationMode: .powerSaving,
            reduceMotion: false,
            isPointerOverRing: false
        )
        expect(
            host.particleSublayerCountForTesting == 0,
            "power-saving mode should remove particles before ring hover"
        )
        host.configure(
            lanes: dualPresentation.particleLanes,
            energyMode: .normal,
            animationMode: .powerSaving,
            reduceMotion: false,
            isPointerOverRing: true
        )
        expect(
            host.particleSublayerCountForTesting == 56,
            "power-saving ring hover should restore the full original particle field"
        )
        host.configure(
            lanes: dualPresentation.particleLanes,
            energyMode: .normal,
            animationMode: .powerSaving,
            reduceMotion: false,
            isPointerOverRing: false
        )
        expect(
            host.particleSublayerCountForTesting == 0,
            "leaving the ring should immediately remove power-saving particles"
        )
        host.configure(
            lanes: dualPresentation.particleLanes,
            energyMode: .normal,
            animationMode: .standard,
            reduceMotion: false,
            isPointerOverRing: false
        )
        host.setEligibilityOverrideForTesting(false)
        expect(
            host.particleSublayerCountForTesting == 0,
            "ineligible state should remove particle sublayers instead of pausing them"
        )
        expect(
            host.particleAnimationCountForTesting == 0,
            "ineligible state should remove all particle animations"
        )
        host.prepareForRemoval()

        let suiteName = "CodexManagerNext.particle-animation-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            print("particle animation self-test failed: could not create UserDefaults suite")
            return false
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        expect(
            ParticleAnimationMode.storedOrDefault(defaults: defaults) == .standard,
            "missing particle animation preference should default to standard"
        )
        let settings = AppSettings(defaults: defaults)
        settings.particleAnimationMode = .powerSaving
        expect(
            defaults.string(forKey: ParticleAnimationMode.storageKey) == ParticleAnimationMode.powerSaving.rawValue,
            "particle animation preference should persist immediately"
        )
        expect(
            AppSettings(defaults: defaults).particleAnimationMode == .powerSaving,
            "particle animation preference should survive AppSettings recreation"
        )
        defaults.set("future-mode", forKey: ParticleAnimationMode.storageKey)
        expect(
            ParticleAnimationMode.storedOrDefault(defaults: defaults) == .standard,
            "unknown particle animation preference should fall back to standard"
        )

        if failures.isEmpty {
            print("particle animation self-test passed")
            return true
        }
        failures.forEach { print("particle animation self-test failed: \($0)") }
        return false
    }
}

struct QuotaValueProgressBar: View {
    let currentValue: Double
    let maxValue: Double
    @Environment(\.visualTokens) private var visualTokens

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progressWidth = valueOffset(currentValue, width: width)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(FixedVisualPalette.surfaceTrack)
                    .frame(height: 10)
                    .frame(maxHeight: .infinity, alignment: .center)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: visualTokens.data.valueProgress.map(\.color), startPoint: .leading, endPoint: .trailing))
                    .frame(width: currentValue > 0 ? max(5, progressWidth) : 0, height: 10)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .overlay {
                        if let asset = visualTokens.assets[.progressLinear], currentValue > 0 {
                            PaletteAssetFill(descriptor: asset)
                                .frame(width: max(5, progressWidth), height: 10)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

            }
        }
    }

    private func valueOffset(_ amount: Double, width: CGFloat) -> CGFloat {
        guard maxValue > 0 else { return 0 }
        let referenceCeiling = 200.0
        let referenceBand = 0.28
        let clamped = max(0, min(amount, maxValue))

        let fraction: Double
        if clamped <= referenceCeiling {
            fraction = referenceBand * (clamped / referenceCeiling)
        } else {
            let remainingValue = max(maxValue - referenceCeiling, 0)
            if remainingValue <= 0 {
                fraction = 1
            } else {
                let tailValue = clamped - referenceCeiling
                let tailProgress =
                    log1p(tailValue / referenceCeiling)
                    / log1p(remainingValue / referenceCeiling)
                fraction = referenceBand + (1 - referenceBand) * tailProgress
            }
        }

        let raw = width * CGFloat(max(0, min(1, fraction)))
        return min(max(raw, 0), width)
    }
}
