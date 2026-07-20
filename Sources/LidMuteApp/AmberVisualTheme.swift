import SwiftUI

struct AmberThemePalette {
    let canvas: Color
    let atmosphereStart: Color
    let atmosphereMiddle: Color
    let atmosphereEnd: Color
    let amberGlow: Color
    let seaGlassGlow: Color
    let mistGlow: Color
    let surfacePrimary: Color
    let surfaceSecondary: Color
    let surfaceTertiary: Color
    let border: Color
    let glassHighlight: Color
    let cardShadow: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let controlFill: Color
    let disabledFill: Color
}

enum ControlCenterTypography {
    static let brand = Font.system(size: 24, weight: .semibold, design: .default)
    static let heroEyebrow = Font.system(size: 12, weight: .semibold, design: .default)
    static let heroTitle = Font.system(size: 30, weight: .bold, design: .default)
    static let cardTitle = Font.system(size: 15, weight: .semibold, design: .default)
    static let body = Font.system(size: 13, weight: .regular, design: .default)
    static let caption = Font.system(size: 12, weight: .medium, design: .default)
    static let compactCaption = Font.system(size: 11, weight: .medium, design: .default)
    static let button = Font.system(size: 13, weight: .semibold, design: .default)
    static let numeric = Font.system(size: 13, weight: .semibold, design: .monospaced)
    static let numericCaption = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let codeCaption = Font.system(size: 12, weight: .medium, design: .monospaced)
}

enum AmberVisualTheme {
    static let amber = Color(red: 0.91, green: 0.47, blue: 0.17)
    static let amberSoft = Color(red: 0.96, green: 0.72, blue: 0.46)
    static let seaGlass = Color(red: 0.18, green: 0.58, blue: 0.56)
    static let mistBlue = Color(red: 0.45, green: 0.68, blue: 0.75)
    static let danger = Color(red: 0.78, green: 0.30, blue: 0.24)

    static func palette(for colorScheme: ColorScheme) -> AmberThemePalette {
        switch colorScheme {
        case .dark:
            return AmberThemePalette(
                canvas: Color(red: 0.055, green: 0.075, blue: 0.085),
                atmosphereStart: Color(red: 0.075, green: 0.105, blue: 0.115),
                atmosphereMiddle: Color(red: 0.075, green: 0.145, blue: 0.155),
                atmosphereEnd: Color(red: 0.125, green: 0.095, blue: 0.075),
                amberGlow: amberSoft.opacity(0.18),
                seaGlassGlow: seaGlass.opacity(0.18),
                mistGlow: mistBlue.opacity(0.13),
                surfacePrimary: Color(red: 0.16, green: 0.20, blue: 0.21).opacity(0.68),
                surfaceSecondary: Color(red: 0.12, green: 0.17, blue: 0.18).opacity(0.58),
                surfaceTertiary: Color(red: 0.09, green: 0.13, blue: 0.15).opacity(0.52),
                border: Color.white.opacity(0.22),
                glassHighlight: Color.white.opacity(0.46),
                cardShadow: Color.black.opacity(0.34),
                primaryText: .white,
                secondaryText: Color.white.opacity(0.76),
                tertiaryText: Color.white.opacity(0.58),
                controlFill: Color.white.opacity(0.10),
                disabledFill: Color.white.opacity(0.055)
            )
        default:
            return AmberThemePalette(
                canvas: Color(red: 0.93, green: 0.92, blue: 0.89),
                atmosphereStart: Color(red: 0.94, green: 0.89, blue: 0.81),
                atmosphereMiddle: Color(red: 0.82, green: 0.89, blue: 0.88),
                atmosphereEnd: Color(red: 0.84, green: 0.88, blue: 0.91),
                amberGlow: amberSoft.opacity(0.28),
                seaGlassGlow: seaGlass.opacity(0.21),
                mistGlow: mistBlue.opacity(0.20),
                surfacePrimary: Color.white.opacity(0.70),
                surfaceSecondary: Color.white.opacity(0.58),
                surfaceTertiary: Color.white.opacity(0.50),
                border: Color.black.opacity(0.16),
                glassHighlight: Color.white.opacity(0.94),
                cardShadow: Color(red: 0.16, green: 0.24, blue: 0.27).opacity(0.16),
                primaryText: Color.black.opacity(0.86),
                secondaryText: Color.black.opacity(0.63),
                tertiaryText: Color.black.opacity(0.48),
                controlFill: Color.white.opacity(0.58),
                disabledFill: Color.black.opacity(0.055)
            )
        }
    }
}

enum AuroraCardRole {
    case hero
    case standard
    case media
    case timeline

    func gradient(palette: AmberThemePalette) -> LinearGradient {
        let colors: [Color]
        switch self {
        case .hero:
            colors = [
                palette.surfacePrimary,
                AmberVisualTheme.amberSoft.opacity(0.24),
                AmberVisualTheme.seaGlass.opacity(0.15),
            ]
        case .standard:
            colors = [
                palette.surfaceSecondary,
                AmberVisualTheme.mistBlue.opacity(0.10),
                AmberVisualTheme.amberSoft.opacity(0.06),
            ]
        case .media:
            colors = [
                palette.surfacePrimary.opacity(0.88),
                AmberVisualTheme.seaGlass.opacity(0.24),
                AmberVisualTheme.mistBlue.opacity(0.14),
            ]
        case .timeline:
            colors = [
                palette.surfaceTertiary,
                palette.surfaceSecondary.opacity(0.82),
                AmberVisualTheme.mistBlue.opacity(0.04),
            ]
        }

        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func glassTint(palette: AmberThemePalette) -> Color {
        switch self {
        case .hero:
            return AmberVisualTheme.amberSoft.opacity(0.34)
        case .standard:
            return palette.surfacePrimary.opacity(0.24)
        case .media:
            return AmberVisualTheme.seaGlass.opacity(0.30)
        case .timeline:
            return AmberVisualTheme.mistBlue.opacity(0.07)
        }
    }

    var edgeTint: Color {
        switch self {
        case .hero:
            return AmberVisualTheme.amberSoft
        case .standard:
            return AmberVisualTheme.mistBlue
        case .media:
            return AmberVisualTheme.seaGlass
        case .timeline:
            return AmberVisualTheme.mistBlue.opacity(0.75)
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .hero: 24
        case .media: 19
        case .standard: 12
        case .timeline: 6
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .hero: 12
        case .media: 9
        case .standard: 6
        case .timeline: 2
        }
    }

    func opaqueSurface(palette: AmberThemePalette) -> Color {
        switch self {
        case .hero, .media:
            return palette.surfacePrimary.opacity(0.96)
        case .standard:
            return palette.surfaceSecondary.opacity(0.96)
        case .timeline:
            return palette.surfaceTertiary.opacity(0.98)
        }
    }
}

struct AmberAtmosphere: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = AmberVisualTheme.palette(for: colorScheme)

        ZStack {
            palette.canvas
            LinearGradient(
                colors: [palette.atmosphereStart, palette.atmosphereMiddle, palette.atmosphereEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Ellipse()
                .fill(palette.amberGlow)
                .frame(width: 420, height: 300)
                .blur(radius: 80)
                .offset(x: -330, y: -260)

            Ellipse()
                .fill(palette.seaGlassGlow)
                .frame(width: 520, height: 360)
                .blur(radius: 95)
                .offset(x: 330, y: 260)

            Ellipse()
                .fill(palette.mistGlow)
                .frame(width: 560, height: 240)
                .blur(radius: 100)
                .offset(x: 50, y: -30)
        }
    }
}

struct AmberGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = AmberVisualTheme.palette(for: colorScheme)

        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(palette.surfaceSecondary)
                .glassEffect(.regular.tint(palette.surfacePrimary), in: .rect(cornerRadius: 34))
        } else {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(palette.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                )
        }
    }
}

struct TightCardDeck<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(cornerRadius: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        let palette = AmberVisualTheme.palette(for: colorScheme)

        content
            .background {
                if #available(macOS 26.0, *) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [palette.surfaceTertiary, AmberVisualTheme.seaGlass.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .glassEffect(.regular.tint(palette.surfacePrimary.opacity(0.30)), in: .rect(cornerRadius: cornerRadius))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(palette.surfaceTertiary)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
    }
}

struct AuroraSymbolTile: View {
    let systemImage: String
    let tint: Color
    var secondaryTint: Color = AmberVisualTheme.mistBlue
    var size: CGFloat = 38
    var cornerRadius: CGFloat = 11

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        let palette = AmberVisualTheme.palette(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            tile(palette: palette, shape: shape)
                .glassEffect(.regular.tint(tint.opacity(0.18)), in: .rect(cornerRadius: cornerRadius))
        } else {
            tile(palette: palette, shape: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }

    private func tile(
        palette: AmberThemePalette,
        shape: RoundedRectangle
    ) -> some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [
                        tint.opacity(0.34),
                        secondaryTint.opacity(0.20),
                        palette.surfacePrimary.opacity(0.42),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [palette.primaryText, tint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .frame(width: size, height: size)
        .overlay(
            shape.stroke(
                LinearGradient(
                    colors: [palette.glassHighlight, tint.opacity(0.32), palette.border],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.9
            )
        )
        .shadow(color: tint.opacity(0.16), radius: 8, y: 4)
    }
}

enum AmberGlassSurfaceShape {
    case capsule
    case roundedRectangle(cornerRadius: CGFloat)
}

struct AmberGlassSurfaceModifier: ViewModifier {
    let tint: Color
    let shape: AmberGlassSurfaceShape
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let palette = AmberVisualTheme.palette(for: colorScheme)

        switch shape {
        case .capsule:
            if #available(macOS 26.0, *) {
                content
                    .background(palette.controlFill, in: Capsule())
                    .glassEffect(.regular.tint(tint.opacity(0.30)), in: .capsule)
            } else {
                content
                    .background(palette.controlFill, in: Capsule())
                    .overlay(Capsule().stroke(palette.border, lineWidth: 0.8))
            }
        case let .roundedRectangle(cornerRadius):
            if #available(macOS 26.0, *) {
                content
                    .background(palette.controlFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .glassEffect(.regular.tint(tint.opacity(0.28)), in: .rect(cornerRadius: cornerRadius))
            } else {
                content
                    .background(palette.controlFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(palette.border, lineWidth: 0.8)
                    )
            }
        }
    }
}

private struct AmberGlassCardModifier: ViewModifier {
    let role: AuroraCardRole
    let padding: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let palette = AmberVisualTheme.palette(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if reduceTransparency {
            content
                .padding(padding)
                .background(role.opaqueSurface(palette: palette), in: shape)
                .overlay(shape.stroke(palette.border, lineWidth: 1.15))
                .shadow(color: palette.cardShadow, radius: role.shadowRadius * 0.55, y: role.shadowY * 0.5)
        } else if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .background(role.gradient(palette: palette), in: shape)
                .glassEffect(.regular.tint(role.glassTint(palette: palette)), in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [palette.glassHighlight, role.edgeTint.opacity(0.34), palette.border],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.05
                    )
                )
                .shadow(color: palette.cardShadow, radius: role.shadowRadius, y: role.shadowY)
        } else {
            content
                .padding(padding)
                .background(role.gradient(palette: palette), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [palette.glassHighlight, role.edgeTint.opacity(0.28), palette.border],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.05
                    )
                )
                .shadow(color: palette.cardShadow, radius: role.shadowRadius, y: role.shadowY)
        }
    }
}

extension View {
    func amberGlassCard(
        role: AuroraCardRole = .standard,
        padding: CGFloat = 18,
        cornerRadius: CGFloat = 24
    ) -> some View {
        modifier(AmberGlassCardModifier(role: role, padding: padding, cornerRadius: cornerRadius))
    }

    func amberGlassSurface(tint: Color = .white, shape: AmberGlassSurfaceShape = .capsule) -> some View {
        modifier(AmberGlassSurfaceModifier(tint: tint, shape: shape))
    }
}
