import SwiftUI

struct IconButton: View {
    @Environment(\.palette) private var p
    let systemImage: String
    let label: String
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(p.text2)
                .frame(width: size, height: size)
                .background(hover ? p.bgHover : Color.clear, in: RoundedRectangle(cornerRadius: DoryRadius.sm.rawValue))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(label)
    }
}

struct DoryButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    @Environment(\.palette) private var p
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: DoryRadius.md.rawValue))
            .overlay(RoundedRectangle(cornerRadius: DoryRadius.md.rawValue).strokeBorder(border))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return p.text
        case .destructive: return p.red
        }
    }
    private var background: Color {
        switch kind {
        case .primary: return p.accent
        case .secondary: return p.bgElevated
        case .destructive: return p.redWeak
        }
    }
    private var border: Color {
        kind == .secondary ? p.border : .clear
    }
}
