import SwiftUI

enum LiquidGlassButtonShape {
    case capsule
    case roundedRectangle
}

struct LiquidGlassButtonStyle: ButtonStyle {
    let tint: Color
    var isEmphasized = false
    var shape: LiquidGlassButtonShape = .capsule

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            latestBody(configuration: configuration)
        } else {
            fallbackBody(configuration: configuration)
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func latestBody(configuration: Configuration) -> some View {
        switch shape {
        case .capsule:
            label(configuration)
                .modifier(
                    AuroraControlChrome(
                        tint: tint,
                        shape: .capsule,
                        isEmphasized: isEmphasized,
                        isPressed: configuration.isPressed,
                        isEnabled: isEnabled
                    )
                )
                .glassEffect(glass.interactive(), in: .capsule)
        case .roundedRectangle:
            label(configuration)
                .modifier(
                    AuroraControlChrome(
                        tint: tint,
                        shape: .roundedRectangle,
                        isEmphasized: isEmphasized,
                        isPressed: configuration.isPressed,
                        isEnabled: isEnabled
                    )
                )
                .glassEffect(glass.interactive(), in: .rect(cornerRadius: 13))
        }
    }

    @ViewBuilder
    private func fallbackBody(configuration: Configuration) -> some View {
        switch shape {
        case .capsule:
            label(configuration)
                .modifier(
                    AuroraControlChrome(
                        tint: tint,
                        shape: .capsule,
                        isEmphasized: isEmphasized,
                        isPressed: configuration.isPressed,
                        isEnabled: isEnabled
                    )
                )
        case .roundedRectangle:
            label(configuration)
                .modifier(
                    AuroraControlChrome(
                        tint: tint,
                        shape: .roundedRectangle,
                        isEmphasized: isEmphasized,
                        isPressed: configuration.isPressed,
                        isEnabled: isEnabled
                    )
                )
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        .regular.tint(tint.opacity(isEmphasized ? 0.55 : 0.28))
    }

    private func label(_ configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? palette.primaryText : palette.secondaryText)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.76)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct LiquidGlassIconButtonStyle: ButtonStyle {
    let tint: Color
    var isEmphasized = false
    var size: CGFloat = 40

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            configuration.label
                .frame(width: size, height: size)
                .modifier(
                    AuroraControlChrome(
                        tint: tint,
                        shape: .circle,
                        isEmphasized: isEmphasized,
                        isPressed: configuration.isPressed,
                        isEnabled: isEnabled
                    )
                )
                .glassEffect(.regular.tint(tint.opacity(isEmphasized ? 0.55 : 0.28)).interactive(), in: .circle)
                .modifier(IconInteractionModifier(isPressed: configuration.isPressed, isEnabled: isEnabled, palette: palette))
        } else {
            configuration.label
                .frame(width: size, height: size)
                .modifier(
                    AuroraControlChrome(
                        tint: tint,
                        shape: .circle,
                        isEmphasized: isEmphasized,
                        isPressed: configuration.isPressed,
                        isEnabled: isEnabled
                    )
                )
                .modifier(IconInteractionModifier(isPressed: configuration.isPressed, isEnabled: isEnabled, palette: palette))
        }
    }
}

private enum AuroraControlShape {
    case capsule
    case roundedRectangle
    case circle
}

private struct AuroraControlChrome: ViewModifier {
    let tint: Color
    let shape: AuroraControlShape
    let isEmphasized: Bool
    let isPressed: Bool
    let isEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let palette = AmberVisualTheme.palette(for: colorScheme)
        let gradient = LinearGradient(
            colors: [
                palette.glassHighlight.opacity(isPressed ? 0.18 : 0.34),
                tint.opacity(isEnabled ? (isEmphasized ? 0.26 : 0.14) : 0.07),
                isEnabled ? palette.controlFill : palette.disabledFill,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let stroke = LinearGradient(
            colors: [
                palette.glassHighlight.opacity(isPressed ? 0.35 : 0.72),
                tint.opacity(isEnabled ? (isEmphasized ? 0.70 : 0.38) : 0.18),
                palette.border,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let shadow = isPressed ? palette.cardShadow.opacity(0.45) : palette.cardShadow.opacity(0.78)

        switch shape {
        case .capsule:
            content
                .background(gradient, in: Capsule())
                .overlay(Capsule().stroke(stroke, lineWidth: isEmphasized ? 1.1 : 0.85))
                .shadow(color: shadow, radius: isPressed ? 3 : 7, y: isPressed ? 1 : 4)
        case .roundedRectangle:
            let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
            content
                .background(gradient, in: shape)
                .overlay(shape.stroke(stroke, lineWidth: isEmphasized ? 1.1 : 0.85))
                .shadow(color: shadow, radius: isPressed ? 3 : 7, y: isPressed ? 1 : 4)
        case .circle:
            content
                .background(gradient, in: Circle())
                .overlay(Circle().stroke(stroke, lineWidth: isEmphasized ? 1.1 : 0.85))
                .shadow(color: shadow, radius: isPressed ? 3 : 7, y: isPressed ? 1 : 4)
        }
    }
}

private struct IconInteractionModifier: ViewModifier {
    let isPressed: Bool
    let isEnabled: Bool
    let palette: AmberThemePalette

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isEnabled ? palette.primaryText : palette.secondaryText)
            .scaleEffect(isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.76)
            .animation(.easeOut(duration: 0.16), value: isPressed)
    }
}
