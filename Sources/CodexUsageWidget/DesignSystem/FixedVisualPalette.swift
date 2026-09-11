import Cocoa
import SwiftUI

enum FixedVisualPalette {
    static let dataFlowParticle = NSColor.white

    // Status accents are intentionally calmer than the system neon variants. They are
    // reserved for compact marks and text, never used as a card-wide background.
    static let statusSuccess = Color(red: 0.204, green: 0.667, blue: 0.384)  // #34AA62
    static let statusInfo = Color(red: 0.039, green: 0.518, blue: 1.000)  // #0A84FF
    static let statusWarning = Color(red: 1.000, green: 0.624, blue: 0.039)  // #FF9F0A
    static let statusDanger = Color(red: 1.000, green: 0.271, blue: 0.227)  // #FF453A
    static let statusNeutral = Color(red: 0.596, green: 0.596, blue: 0.616)  // #98989D
    static let statusScheduled = Color(red: 0.545, green: 0.427, blue: 1.000)  // #8B6DFF

    // Strong semantic foregrounds keep 9 pt labels readable on light glass.
    static let statusDangerLightText = Color(red: 0.706, green: 0.137, blue: 0.094)  // #B42318
    static let statusWarningLightText = Color(red: 0.502, green: 0.294, blue: 0.000)  // #804B00
    static let statusSuccessLightText = Color(red: 0.078, green: 0.439, blue: 0.224)  // #147039
    static let statusNeutralLightText = Color(red: 0.329, green: 0.333, blue: 0.369)  // #54555E
    static let statusScheduledLightText = Color(red: 0.384, green: 0.251, blue: 0.773)  // #6240C5

    static let surfaceTrack = Color.primary.opacity(0.10)
    static let surfaceSubtleFill = Color.primary.opacity(0.025)
    static let surfaceFaintFill = Color.primary.opacity(0.035)
    static let surfaceMutedFill = Color.primary.opacity(0.045)
    static let surfaceSoftFill = Color.primary.opacity(0.06)
    static let surfaceHairline = Color.primary.opacity(0.08)
    static let surfaceStrokeSubtle = Color.primary.opacity(0.07)
    static let surfaceStrokeSoft = Color.primary.opacity(0.09)
    static let surfaceStrokeStrong = Color.primary.opacity(0.12)
    static let surfaceRing = Color.primary.opacity(0.16)

    static func primarySurface(_ opacity: Double) -> Color {
        Color.primary.opacity(opacity)
    }

    static func windowScrim(_ colorScheme: ColorScheme, reduceTransparency: Bool = false) -> Color {
        if reduceTransparency {
            return Color(nsColor: .windowBackgroundColor)
        }
        return colorScheme == .dark
            ? Color(red: 0.075, green: 0.080, blue: 0.100).opacity(0.96)
            : Color(red: 0.955, green: 0.960, blue: 0.975).opacity(0.98)
    }

    static func sectionFill(_ colorScheme: ColorScheme, reduceTransparency: Bool = false) -> Color {
        if reduceTransparency {
            return Color(nsColor: .controlBackgroundColor)
        }
        return colorScheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.024)
    }

    static func sectionStroke(_ colorScheme: ColorScheme, increasedContrast: Bool = false) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(increasedContrast ? 0.240 : 0.120)
        }
        return Color.black.opacity(increasedContrast ? 0.180 : 0.080)
    }

    static func cardFill(
        _ colorScheme: ColorScheme,
        elevated: Bool = false,
        reduceTransparency: Bool = false
    ) -> Color {
        if reduceTransparency {
            return Color(nsColor: .controlBackgroundColor)
        }
        if colorScheme == .dark {
            return Color.white.opacity(elevated ? 0.065 : 0.035)
        }
        return Color.white.opacity(elevated ? 1.0 : 0.86)
    }

    static func leadershipPlaqueFill(_ colorScheme: ColorScheme) -> Color {
        Color.black.opacity(colorScheme == .dark ? 0.58 : 0.52)
    }

    static func cardStroke(
        _ colorScheme: ColorScheme,
        elevated: Bool = false,
        increasedContrast: Bool = false
    ) -> Color {
        if colorScheme == .dark {
            let base = elevated ? 0.140 : 0.100
            return Color.white.opacity(increasedContrast ? base + 0.100 : base)
        }
        let base = elevated ? 0.100 : 0.070
        return Color.black.opacity(increasedContrast ? base + 0.100 : base)
    }

    static func secondaryText(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.720) : Color.black.opacity(0.660)
    }

    static func tertiaryText(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.560) : Color.black.opacity(0.560)
    }

    static func controlFill(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.085) : Color.white.opacity(0.520)
    }

    static func controlSelectedFill(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.180) : Color.black.opacity(0.105)
    }

    static func controlStroke(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.070) : Color.black.opacity(0.050)
    }

    static func statusDangerFill(_ colorScheme: ColorScheme) -> Color {
        statusDanger.opacity(colorScheme == .dark ? 0.14 : 0.08)
    }

    static func statusDangerStroke(_ colorScheme: ColorScheme) -> Color {
        statusDanger.opacity(colorScheme == .dark ? 0.34 : 0.24)
    }

    static func statusSuccessForeground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? statusSuccess : statusSuccessLightText
    }

    static func statusWarningForeground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? statusWarning : statusWarningLightText
    }

    static func statusDangerForeground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? statusDanger : statusDangerLightText
    }

    static func statusScheduledForeground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? statusScheduled : statusScheduledLightText
    }

    static func statusFill(_ foreground: Color, colorScheme: ColorScheme) -> Color {
        foreground.opacity(colorScheme == .dark ? 0.10 : 0.065)
    }
}
