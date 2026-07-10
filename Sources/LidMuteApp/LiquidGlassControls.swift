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
                .glassEffect(glass.interactive(), in: .capsule)
        case .roundedRectangle:
            label(configuration)
                .glassEffect(glass.interactive(), in: .rect(cornerRadius: 13))
        }
    }

    @ViewBuilder
    private func fallbackBody(configuration: Configuration) -> some View {
        switch shape {
        case .capsule:
            label(configuration)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(tint.opacity(isEmphasized ? 0.62 : 0.26), lineWidth: 1))
        case .roundedRectangle:
            label(configuration)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(tint.opacity(isEmphasized ? 0.62 : 0.26), lineWidth: 1))
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        .regular.tint(tint.opacity(isEmphasized ? 0.34 : 0.12))
    }

    private func label(_ configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.58)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct LiquidGlassIconButtonStyle: ButtonStyle {
    let tint: Color
    var isEmphasized = false
    var size: CGFloat = 40

    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            configuration.label
                .frame(width: size, height: size)
                .glassEffect(.regular.tint(tint.opacity(isEmphasized ? 0.34 : 0.12)).interactive(), in: .circle)
                .modifier(IconInteractionModifier(isPressed: configuration.isPressed, isEnabled: isEnabled))
        } else {
            configuration.label
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(tint.opacity(isEmphasized ? 0.62 : 0.26), lineWidth: 1))
                .modifier(IconInteractionModifier(isPressed: configuration.isPressed, isEnabled: isEnabled))
        }
    }
}

private struct IconInteractionModifier: ViewModifier {
    let isPressed: Bool
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .scaleEffect(isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.58)
            .animation(.easeOut(duration: 0.16), value: isPressed)
    }
}
