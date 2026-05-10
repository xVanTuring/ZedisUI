import SwiftUI

/// Custom button chrome used for the small icon buttons in the sidebar.
/// Critically, this style is applied to BOTH `Button` and `Menu` (via
/// `.menuStyle(.button)`), so the two render at exactly the same geometry —
/// the system's default Menu chrome would otherwise reserve chevron space
/// even with `.menuIndicator(.hidden)`, making it visibly wider.
struct ChromeIconButtonStyle: ButtonStyle {
    var iconSize: CGFloat = 16
    var paddingH: CGFloat = 6
    var paddingV: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .regular))
            .frame(width: iconSize, height: iconSize)
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(background(for: configuration))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
    }

    private func background(for configuration: Configuration) -> Color {
        if configuration.isPressed {
            return Color.primary.opacity(0.18)
        }
        return Color.primary.opacity(0.08)
    }
}
