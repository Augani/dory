import SwiftUI

struct PortChip: View {
    @Environment(\.palette) private var p
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label).font(.mono(10.5))
                Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(p.accentText)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(hover ? p.accentWeak : p.bgElevated, in: RoundedRectangle(cornerRadius: DoryRadius.sm.rawValue))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Open \(label)")
    }
}
