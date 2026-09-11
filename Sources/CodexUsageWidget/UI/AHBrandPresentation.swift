import SwiftUI

enum AHBrandIdentity {
    static let displayName = "AiGoodBro"
    static let shortName = "AH"
    static let workspaceName = "AgentHub"

    static func headerDetail(page: SettingsPage?, language: WidgetLanguage) -> String {
        if let page {
            return language.text(
                "\(shortName) · 设置 · \(page.title(language))",
                "\(shortName) · Settings · \(page.title(language))"
            )
        }
        return language.text("\(shortName) · 设置", "\(shortName) · Settings")
    }

    static func aboutAttribution(_ language: WidgetLanguage) -> String {
        language.text(
            "独立开源项目，非 OpenAI 官方产品。\n基于 codexU，遵循 MIT 许可。",
            "An independent open-source project, not an official OpenAI product.\nBased on codexU, under the MIT license."
        )
    }

    static func statusItemTooltip(description: String, action: String) -> String {
        "\(displayName) · \(description) · \(action)"
    }

    static func menuBarPreviewAccessibility(_ language: WidgetLanguage) -> String {
        language.text("AiGoodBro 菜单栏预览", "AiGoodBro menu bar preview")
    }

    static func syntheticCaption(_ title: String) -> String {
        "合成数据 · \(title)"
    }
}

final class AHSettingsHeaderContext: ObservableObject {
    static let shared = AHSettingsHeaderContext()

    @Published var currentPage: SettingsPage?

    fileprivate init() {}
}

/// AiGoodBro brand mark: AH ligature plus a reset-cycle hub.
/// Geometry stays in lockstep with `scripts/generate-ah-brand-icons.py`.
struct AHBrandSymbol: View {
    enum Variant {
        /// 彩色底板 + 白色字形（设置页、关于页、主界面品牌位）。
        case tile
        /// 单色字形，无底板（模板渲染体系）。
        case template(Color)
    }

    @Environment(\.visualTokens) private var visualTokens
    var size: CGFloat = 18
    var variant: Variant = .tile

    var body: some View {
        Canvas { context, canvasSize in
            switch variant {
            case .tile:
                drawTile(context: context, canvasSize: canvasSize)
            case .template(let color):
                drawGlyph(context: context, rect: glyphRect(in: canvasSize), heavy: canvasSize.width <= 32, color: color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func drawTile(context: GraphicsContext, canvasSize: CGSize) {
        let fill = visualTokens.accent.primary.color
        let tile = CGRect(origin: .zero, size: canvasSize)
        let cornerRadius = max(4, canvasSize.width * 0.2237)
        let tilePath = Path(roundedRect: tile, cornerRadius: cornerRadius, style: .continuous)
        context.fill(
            tilePath,
            with: .linearGradient(
                Gradient(colors: [fill, fill.opacity(0.78)]),
                startPoint: CGPoint(x: tile.midX, y: tile.minY),
                endPoint: CGPoint(x: tile.midX, y: tile.maxY)
            )
        )
        var clipped = context
        clipped.clip(to: tilePath)
        let inset = canvasSize.width * 0.11
        let inner = tile.insetBy(dx: inset, dy: inset)
        clipped.stroke(
            Path(roundedRect: inner, cornerRadius: max(3, canvasSize.width * 0.16), style: .continuous),
            with: .color(Color.white.opacity(canvasSize.width >= 64 ? 0.25 : 0.35)),
            lineWidth: max(1, canvasSize.width * (canvasSize.width >= 64 ? 0.018 : 0.028))
        )
        drawGlyph(context: clipped, rect: glyphRect(in: canvasSize), heavy: canvasSize.width <= 32, color: .white)
    }

    private func glyphRect(in canvasSize: CGSize) -> CGRect {
        // 光学尺寸：≤32px 放大字形框并加粗笔画（与生成脚本一致）。
        let ratio: CGFloat = canvasSize.width <= 32 ? 0.74 : 0.66
        let side = canvasSize.width * ratio
        return CGRect(
            x: (canvasSize.width - side) / 2,
            y: (canvasSize.height - side) / 2,
            width: side,
            height: side
        )
    }

    private func drawGlyph(context: GraphicsContext, rect: CGRect, heavy: Bool, color: Color) {
        let u = rect.width / 100
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * u, y: rect.minY + y * u)
        }
        var path = Path()
        path.move(to: point(17, 85))
        path.addLine(to: point(35, 15))
        path.addLine(to: point(53, 85))
        path.move(to: point(24.7, 55))
        path.addLine(to: point(83, 55))
        path.move(to: point(83, 15))
        path.addLine(to: point(83, 85))
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: (heavy ? 11.5 : 10.5) * u, lineCap: .round, lineJoin: .round)
        )
        let hubRadius = 11 * u
        context.stroke(
            Path(
                ellipseIn: CGRect(
                    x: rect.minX + 64.5 * u - hubRadius,
                    y: rect.minY + 55 * u - hubRadius,
                    width: hubRadius * 2,
                    height: hubRadius * 2
                )
            ),
            with: .color(color),
            style: StrokeStyle(lineWidth: 3.4 * u, lineCap: .round)
        )
    }
}
