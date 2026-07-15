import SwiftUI

struct AmberThemePalette {
    let canvas: Color
    let atmosphereStart: Color
    let atmosphereMiddle: Color
    let atmosphereEnd: Color
    let amberGlow: Color
    let seaGlassGlow: Color
    let surfacePrimary: Color
    let surfaceSecondary: Color
    let surfaceTertiary: Color
    let border: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let controlFill: Color
    let disabledFill: Color
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
                amberGlow: amberSoft.opacity(0.10),
                seaGlassGlow: seaGlass.opacity(0.12),
                surfacePrimary: Color(red: 0.13, green: 0.17, blue: 0.18).opacity(0.94),
                surfaceSecondary: Color(red: 0.105, green: 0.14, blue: 0.15).opacity(0.91),
                surfaceTertiary: Color(red: 0.085, green: 0.115, blue: 0.125).opacity(0.90),
                border: Color.white.opacity(0.22),
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
                amberGlow: amberSoft.opacity(0.16),
                seaGlassGlow: seaGlass.opacity(0.11),
                surfacePrimary: Color.white.opacity(0.86),
                surfaceSecondary: Color.white.opacity(0.72),
                surfaceTertiary: Color.white.opacity(0.64),
                border: Color.black.opacity(0.16),
                primaryText: Color.black.opacity(0.86),
                secondaryText: Color.black.opacity(0.63),
                tertiaryText: Color.black.opacity(0.48),
                controlFill: Color.white.opacity(0.58),
                disabledFill: Color.black.opacity(0.055)
            )
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

    init(cornerRadius: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .background {
                if #available(macOS 26.0, *) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                        .glassEffect(.regular.tint(.white.opacity(0.30)), in: .rect(cornerRadius: cornerRadius))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
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
    let padding: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let palette = AmberVisualTheme.palette(for: colorScheme)

        if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .background(palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .glassEffect(.regular.tint(palette.surfacePrimary), in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(palette.border, lineWidth: 1.0)
                )
        } else {
            content
                .padding(padding)
                .background(palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(palette.border, lineWidth: 1.0)
                )
        }
    }
}

extension View {
    func amberGlassCard(padding: CGFloat = 18, cornerRadius: CGFloat = 24) -> some View {
        modifier(AmberGlassCardModifier(padding: padding, cornerRadius: cornerRadius))
    }

    func amberGlassSurface(tint: Color = .white, shape: AmberGlassSurfaceShape = .capsule) -> some View {
        modifier(AmberGlassSurfaceModifier(tint: tint, shape: shape))
    }
}
