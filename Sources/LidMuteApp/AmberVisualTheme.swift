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
    static let amber = Color(red: 0.25, green: 0.43, blue: 0.32)
    static let amberSoft = Color(red: 0.46, green: 0.58, blue: 0.50)
    static let seaGlass = Color(red: 0.25, green: 0.43, blue: 0.32)
    static let mistBlue = Color(red: 0.47, green: 0.47, blue: 0.45)
    static let danger = Color(red: 0.72, green: 0.30, blue: 0.26)

    static func palette(for colorScheme: ColorScheme) -> AmberThemePalette {
        switch colorScheme {
        case .dark:
            return AmberThemePalette(
                canvas: .clear,
                atmosphereStart: .clear,
                atmosphereMiddle: .clear,
                atmosphereEnd: .clear,
                amberGlow: .clear,
                seaGlassGlow: .clear,
                mistGlow: .clear,
                surfacePrimary: Color.white.opacity(0.13),
                surfaceSecondary: Color.white.opacity(0.09),
                surfaceTertiary: Color.white.opacity(0.07),
                border: Color.white.opacity(0.16),
                glassHighlight: Color.white.opacity(0.32),
                cardShadow: Color(red: 0.05, green: 0.05, blue: 0.045).opacity(0.22),
                primaryText: Color(red: 0.950, green: 0.950, blue: 0.940),
                secondaryText: Color(red: 0.680, green: 0.680, blue: 0.660),
                tertiaryText: Color(red: 0.500, green: 0.500, blue: 0.480),
                controlFill: Color.white.opacity(0.08),
                disabledFill: Color.white.opacity(0.035)
            )
        default:
            return AmberThemePalette(
                canvas: .clear,
                atmosphereStart: .clear,
                atmosphereMiddle: .clear,
                atmosphereEnd: .clear,
                amberGlow: .clear,
                seaGlassGlow: .clear,
                mistGlow: .clear,
                surfacePrimary: Color.white.opacity(0.30),
                surfaceSecondary: Color.white.opacity(0.22),
                surfaceTertiary: Color.white.opacity(0.18),
                border: Color.white.opacity(0.54),
                glassHighlight: Color.white.opacity(0.76),
                cardShadow: Color(red: 0.18, green: 0.18, blue: 0.17).opacity(0.09),
                primaryText: Color(red: 0.150, green: 0.150, blue: 0.140),
                secondaryText: Color(red: 0.420, green: 0.420, blue: 0.400),
                tertiaryText: Color(red: 0.550, green: 0.550, blue: 0.530),
                controlFill: Color.white.opacity(0.26),
                disabledFill: Color.white.opacity(0.16)
            )
        }
    }
}

enum AuroraCardRole {
    case hero
    case standard
    case media
    case timeline

    func glassTint(palette: AmberThemePalette) -> Color {
        switch self {
        case .hero:
            return palette.glassHighlight.opacity(0.12)
        case .standard:
            return palette.glassHighlight.opacity(0.08)
        case .media:
            return palette.glassHighlight.opacity(0.18)
        case .timeline:
            return palette.glassHighlight.opacity(0.05)
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
    var body: some View {
        ZStack {
            Color.clear
            Color.clear

            Ellipse()
                .fill(.clear)
                .frame(width: 420, height: 300)
                .offset(x: -330, y: -260)

            Ellipse()
                .fill(.clear)
                .frame(width: 520, height: 360)
                .offset(x: 330, y: 260)

            Ellipse()
                .fill(.clear)
                .frame(width: 560, height: 240)
                .offset(x: 50, y: -30)
        }
    }
}

struct AmberGlassBackdrop: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 34))
        } else {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.regularMaterial)
        }
    }
}

struct TightCardDeck<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder var content: Content

    init(cornerRadius: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .background {
                if #available(macOS 26.0, *) {
                    Color.clear
                        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
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

    @ViewBuilder
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            tile
                .glassEffect(.regular.tint(tint.opacity(0.18)), in: .rect(cornerRadius: cornerRadius))
        } else {
            tile
                .background(.regularMaterial, in: shape)
        }
    }

    private var tile: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
    }
}

enum AmberGlassSurfaceShape {
    case capsule
    case roundedRectangle(cornerRadius: CGFloat)
    case circle
}

struct AmberGlassSurfaceModifier: ViewModifier {
    let tint: Color?
    let shape: AmberGlassSurfaceShape

    @ViewBuilder
    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(glass, in: .capsule)
            } else {
                content
                    .background(.regularMaterial, in: Capsule())
            }
        case let .roundedRectangle(cornerRadius):
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
            } else {
                content
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            }
        case .circle:
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(glass, in: .circle)
            } else {
                content
                    .background(.regularMaterial, in: Circle())
            }
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        if let tint {
            return .regular.tint(tint.opacity(0.18))
        }
        return .regular
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
        } else if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .glassEffect(.regular.tint(role.glassTint(palette: palette)), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .padding(padding)
                .background(.regularMaterial, in: shape)
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

    func amberGlassSurface(tint: Color? = nil, shape: AmberGlassSurfaceShape = .capsule) -> some View {
        modifier(AmberGlassSurfaceModifier(tint: tint, shape: shape))
    }
}
