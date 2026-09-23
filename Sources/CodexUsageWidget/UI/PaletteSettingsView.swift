import SwiftUI

struct PaletteSettingsView: View {
    @ObservedObject var settings: AppSettings
    let onOpenLibrary: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var selectedDescriptor: PaletteDescriptor {
        let descriptors = settings.paletteCatalog
            .descriptors(
                language: settings.language == .zh ? "zh-Hans" : "en",
                includingDeprecatedID: settings.paletteID
            )
        return descriptors.first { $0.id == settings.paletteID }
            ?? descriptors.first { $0.isDefault }
            ?? PaletteDescriptor(
                id: PaletteCatalog.defaultPaletteID,
                version: "safe-default",
                displayName: settings.language.text("默认", "Default"),
                shortDescription: settings.language.text("查看与选择配色", "Browse and choose palettes"),
                inspirationNote: "",
                authorName: "内置主题",
                sourceType: "original",
                lifecycle: .stable,
                isOfficial: true,
                isDefault: true
            )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            currentPaletteButton(selectedDescriptor)
            if let notice = settings.paletteFallbackNotice {
                Text(settings.language.text("配色不可用，已恢复默认", "Palette unavailable; restored to default"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(FixedVisualPalette.statusWarning)
                    .help(notice.unavailableID)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.language.text("配色", "Color palette"))
    }

    private func currentPaletteButton(_ descriptor: PaletteDescriptor) -> some View {
        let tokens = settings.paletteCatalog.resolve(id: descriptor.id, appearance: PaletteAppearance(colorScheme))
        return Button(action: onOpenLibrary) {
            HStack(spacing: 9) {
                PaletteSwatches(tokens: tokens, diameter: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.language.text("配色 · \(descriptor.displayName)", "Palette · \(descriptor.displayName)"))
                        .font(.system(size: settingsControlFontSize, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(settings.language.text("查看与选择配色", "Browse and choose palettes"))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 14)
            .frame(
                maxWidth: .infinity,
                minHeight: 52,
                alignment: .leading
            )
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tokens.accent.primary.color.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tokens.accent.primary.color.opacity(0.16), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(descriptor.shortDescription)
        .accessibilityLabel(settings.language.text("当前配色：\(descriptor.displayName)，打开配色库", "Current palette: \(descriptor.displayName). Open palette library"))
    }
}

struct PaletteLibraryView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private var descriptors: [PaletteDescriptor] {
        settings.paletteCatalog.descriptors(
            language: settings.language == .zh ? "zh-Hans" : "en",
            includingDeprecatedID: settings.paletteID
        )
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ZStack {
            LiquidGlassWindowBackdrop(colorScheme: colorScheme)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        settings.resetPalette()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.48), lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 40, height: 34)
                    .contentShape(Rectangle())
                    .disabled(settings.paletteID == PaletteCatalog.initialPaletteID)
                    .opacity(settings.paletteID == PaletteCatalog.initialPaletteID ? 0.34 : 1)
                    .help(settings.language.text("恢复默认配色", "Restore Default Palette"))
                    .accessibilityLabel(settings.language.text("恢复默认配色", "Restore Default Palette"))
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(height: 42)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(descriptors) { descriptor in
                            PaletteArtworkCard(
                                descriptor: descriptor,
                                catalog: settings.paletteCatalog,
                                language: settings.language,
                                selected: descriptor.id == settings.paletteID
                            ) {
                                settings.selectPalette(descriptor.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(minWidth: 660, minHeight: 300)
        .appVisualEnvironment(
            catalog: settings.paletteCatalog,
            paletteID: settings.paletteID,
            appearance: PaletteAppearance(colorScheme)
        )
        .readableForegroundHierarchy(colorScheme)
    }
}

struct LiquidGlassWindowBackdrop: View {
    let colorScheme: ColorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.white.opacity(0.055), Color.clear, Color.black.opacity(0.10)]
                    : [Color.white.opacity(0.40), Color.white.opacity(0.10), Color.black.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.white.opacity(colorScheme == .dark ? 0.07 : 0.34), Color.clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct PaletteArtworkCard: View {
    let descriptor: PaletteDescriptor
    let catalog: PaletteCatalog
    let language: WidgetLanguage
    let selected: Bool
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovering = false

    private var lightTokens: ResolvedVisualTokens { catalog.resolve(id: descriptor.id, appearance: .light) }
    private var darkTokens: ResolvedVisualTokens { catalog.resolve(id: descriptor.id, appearance: .dark) }

    private var sourceLabel: String {
        let source =
            descriptor.isOfficial
            ? language.text("内置主题", "Built-in")
            : language.text("社区贡献 · \(descriptor.authorName)", "Community · \(descriptor.authorName)")
        if descriptor.lifecycle == .deprecated {
            return language.text("已弃用 · \(source)", "Deprecated · \(source)")
        }
        return source
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                HStack(spacing: 0) {
                    PaletteArtworkHalf(tokens: lightTokens, appearance: .light)
                    PaletteArtworkHalf(tokens: darkTokens, appearance: .dark)
                }
                .overlay(alignment: .center) {
                    Rectangle()
                        .fill(Color.white.opacity(0.24))
                        .frame(width: 0.75)
                        .blendMode(.overlay)
                }

                VStack(spacing: 1.5) {
                    Text(descriptor.displayName)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .tracking(0.20)
                    Text(sourceLabel)
                        .font(.system(size: 7.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.84))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(Color.black.opacity(0.20), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.30), lineWidth: 0.7))
                .shadow(color: Color.black.opacity(0.24), radius: 5, y: 2)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 19, height: 19)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.48), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.22), radius: 4, y: 1)
                        .padding(7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .accessibilityHidden(true)
                }
            }
            .aspectRatio(2.15, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        selected || focused
                            ? lightTokens.selection.focusRing.color
                            : Color.white.opacity(hovering ? 0.52 : 0.24),
                        lineWidth: selected || focused ? 2.0 : 0.7
                    )
            }
            .brightness(hovering ? 0.035 : 0)
            .shadow(
                color: selected
                    ? lightTokens.selection.focusRing.color.opacity(0.30)
                    : Color.black.opacity(hovering ? 0.24 : 0.15),
                radius: selected ? 10 : (hovering ? 8 : 5),
                y: hovering ? 4 : 2
            )
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selected)
        .help(descriptor.shortDescription)
        .accessibilityLabel("\(descriptor.displayName), \(sourceLabel)")
        .accessibilityValue(selected ? language.text("已选择", "Selected") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PaletteArtworkHalf: View {
    let tokens: ResolvedVisualTokens
    let appearance: PaletteAppearance

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LinearGradient(
                    colors: backgroundColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [tokens.accent.highlight.color.opacity(0.92), tokens.accent.primary.color.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: max(size.width, size.height) * 0.44
                        )
                    )
                    .frame(width: size.width * 1.18, height: size.width * 1.18)
                    .offset(x: -size.width * 0.34, y: -size.height * 0.28)
                    .blur(radius: 8)

                PaletteFlowBand(amplitude: 0.20, verticalPosition: 0.34)
                    .fill(
                        LinearGradient(
                            colors: [tokens.accent.secondary.color.opacity(0.22), tokens.accent.secondaryStrong.color.opacity(0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blur(radius: 1.2)

                PaletteFlowBand(amplitude: 0.15, verticalPosition: 0.63)
                    .fill(
                        LinearGradient(
                            colors: [tokens.quota.primary.start.color.opacity(0.35), tokens.quota.primary.end.color.opacity(0.94)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .offset(y: size.height * 0.10)

                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [tokens.ornament.metal.color.opacity(0.76), tokens.accent.highlight.color.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: size.width * 0.76, height: size.height * 0.23)
                    .rotationEffect(.degrees(-23))
                    .offset(x: size.width * 0.30, y: -size.height * 0.26)
                    .blur(radius: 2.5)

                LinearGradient(
                    colors: [
                        Color.white.opacity(appearance == .light ? 0.48 : 0.16),
                        Color.clear,
                        Color.black.opacity(appearance == .dark ? 0.20 : 0.04),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .compositingGroup()
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private var backgroundColors: [Color] {
        if appearance == .light {
            return [
                Color.white.opacity(0.98),
                tokens.accent.primaryLight.color.opacity(0.78),
                tokens.surfaceTint.color.color.opacity(0.52),
            ]
        }
        return [
            Color(red: 0.035, green: 0.04, blue: 0.06),
            tokens.accent.primaryStrong.color.opacity(0.76),
            tokens.accent.secondaryStrong.color.opacity(0.90),
        ]
    }
}

private struct PaletteFlowBand: Shape {
    let amplitude: CGFloat
    let verticalPosition: CGFloat

    func path(in rect: CGRect) -> Path {
        let centerY = rect.height * verticalPosition
        let rise = rect.height * amplitude
        var path = Path()
        path.move(to: CGPoint(x: -rect.width * 0.08, y: centerY - rise * 0.55))
        path.addCurve(
            to: CGPoint(x: rect.width * 1.08, y: centerY + rise * 0.20),
            control1: CGPoint(x: rect.width * 0.22, y: centerY + rise * 1.35),
            control2: CGPoint(x: rect.width * 0.72, y: centerY - rise * 1.20)
        )
        path.addLine(to: CGPoint(x: rect.width * 1.08, y: centerY + rise * 1.28))
        path.addCurve(
            to: CGPoint(x: -rect.width * 0.08, y: centerY + rise * 0.54),
            control1: CGPoint(x: rect.width * 0.72, y: centerY - rise * 0.04),
            control2: CGPoint(x: rect.width * 0.22, y: centerY + rise * 2.10)
        )
        path.closeSubpath()
        return path
    }
}

private struct PaletteSwatches: View {
    let tokens: ResolvedVisualTokens
    let diameter: CGFloat

    var body: some View {
        HStack(spacing: max(2, diameter * 0.32)) {
            ForEach(Array(swatchColors.enumerated()), id: \.offset) { _, color in
                Circle().fill(color.color).frame(width: diameter, height: diameter)
            }
        }
    }

    private var swatchColors: [PaletteColor] {
        [tokens.quota.primary.start, tokens.quota.primary.end, tokens.quota.secondary.end, tokens.data.series[2]]
    }
}
