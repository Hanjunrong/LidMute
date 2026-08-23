import SwiftUI

enum LiquidGlassButtonShape {
    case capsule
    case roundedRectangle
}

struct LiquidGlassButtonStyle: PrimitiveButtonStyle {
    let tint: Color
    var isEmphasized = false
    var shape: LiquidGlassButtonShape = .capsule
    var usesTint = false
    var horizontalPadding: CGFloat = 15
    var verticalPadding: CGFloat = 9

    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            nativeBody(configuration: configuration)
        } else {
            fallbackBody(configuration: configuration)
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func nativeBody(configuration: Configuration) -> some View {
        if isEmphasized {
            nativeButton(configuration: configuration)
                .buttonStyle(.glassProminent)
                .tint(tint)
        } else if usesTint {
            nativeButton(configuration: configuration)
                .buttonStyle(.glass(.regular.tint(tint)))
        } else {
            nativeButton(configuration: configuration)
                .buttonStyle(.glass)
        }
    }

    @available(macOS 26.0, *)
    private func nativeButton(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            label(configuration)
        }
        .buttonBorderShape(buttonBorderShape)
    }

    @ViewBuilder
    private func fallbackBody(configuration: Configuration) -> some View {
        switch shape {
        case .capsule:
            fallbackButton(configuration: configuration)
                .background(.regularMaterial, in: Capsule())
        case .roundedRectangle:
            fallbackButton(configuration: configuration)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
        }
    }

    private func fallbackButton(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            label(configuration)
                .foregroundStyle(palette.primaryText)
        }
        .buttonStyle(.plain)
    }

    private func label(_ configuration: Configuration) -> some View {
        configuration.label
            .font(ControlCenterTypography.button)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .contentShape(Rectangle())
    }

    private var buttonBorderShape: ButtonBorderShape {
        switch shape {
        case .capsule:
            return .capsule
        case .roundedRectangle:
            return .roundedRectangle(radius: 13)
        }
    }
}

struct LiquidGlassIconButtonStyle: PrimitiveButtonStyle {
    let tint: Color
    var isEmphasized = false
    var size: CGFloat = 40
    var usesTint = false

    @Environment(\.colorScheme) private var colorScheme

    private var palette: AmberThemePalette {
        AmberVisualTheme.palette(for: colorScheme)
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            nativeBody(configuration: configuration)
        } else {
            fallbackBody(configuration: configuration)
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func nativeBody(configuration: Configuration) -> some View {
        if isEmphasized {
            nativeButton(configuration: configuration)
                .buttonStyle(.glassProminent)
                .tint(tint)
        } else if usesTint {
            nativeButton(configuration: configuration)
                .buttonStyle(.glass(.regular.tint(tint)))
        } else {
            nativeButton(configuration: configuration)
                .buttonStyle(.glass)
        }
    }

    @available(macOS 26.0, *)
    private func nativeButton(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .frame(width: size, height: size)
        }
        .buttonBorderShape(.circle)
    }

    private func fallbackBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .frame(width: size, height: size)
                .foregroundStyle(palette.primaryText)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Circle())
    }
}

struct NativeGlassEffectContainerModifier: ViewModifier {
    let spacing: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}
