import SwiftUI

enum AmberVisualTheme {
    static let amber = Color(red: 0.91, green: 0.47, blue: 0.17)
    static let amberSoft = Color(red: 0.96, green: 0.72, blue: 0.46)
    static let seaGlass = Color(red: 0.18, green: 0.58, blue: 0.56)
    static let mistBlue = Color(red: 0.45, green: 0.68, blue: 0.75)
    static let danger = Color(red: 0.78, green: 0.30, blue: 0.24)
}

struct AmberAtmosphere: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.10, green: 0.13, blue: 0.15), Color(red: 0.08, green: 0.20, blue: 0.23), Color(red: 0.16, green: 0.13, blue: 0.12)]
                    : [Color(red: 0.94, green: 0.86, blue: 0.75), Color(red: 0.69, green: 0.84, blue: 0.82), Color(red: 0.74, green: 0.83, blue: 0.87)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Ellipse()
                .fill(AmberVisualTheme.amberSoft.opacity(colorScheme == .dark ? 0.14 : 0.34))
                .frame(width: 420, height: 300)
                .blur(radius: 80)
                .offset(x: -330, y: -260)

            Ellipse()
                .fill(AmberVisualTheme.seaGlass.opacity(colorScheme == .dark ? 0.17 : 0.24))
                .frame(width: 520, height: 360)
                .blur(radius: 95)
                .offset(x: 330, y: 260)
        }
    }
}

private struct AmberGlassCardModifier: ViewModifier {
    let padding: CGFloat
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .padding(padding)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.42), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 22, y: 10)
        }
    }
}

extension View {
    func amberGlassCard(padding: CGFloat = 18, cornerRadius: CGFloat = 24) -> some View {
        modifier(AmberGlassCardModifier(padding: padding, cornerRadius: cornerRadius))
    }
}
