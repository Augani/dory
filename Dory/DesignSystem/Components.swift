import SwiftUI

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct CountPill: View {
    @Environment(\.palette) private var p
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(p.text3)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(p.pill, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct StatusBadge: View {
    let label: String
    let color: Color
    let background: Color
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ThinBar: View {
    @Environment(\.palette) private var p
    var fraction: Double
    var tint: Color
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(p.bgInput)
                Capsule().fill(tint).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

struct MiniMeter: View {
    @Environment(\.palette) private var p
    let label: String
    let value: String
    let fraction: Double
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.text3)
                Spacer()
                Text(value).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(p.text2)
            }
            ThinBar(fraction: fraction, tint: tint, height: 4)
        }
    }
}

struct SparkBars: View {
    let heights: [Double]
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.opacity(0.85))
                        .frame(height: max(2, geo.size.height * (h / 100)))
                }
            }
        }
    }
}

struct DoryToggle: View {
    @Environment(\.palette) private var p
    @Binding var isOn: Bool
    var body: some View {
        Capsule()
            .fill(isOn ? p.accent : p.bgInput)
            .frame(width: 38, height: 22)
            .overlay(
                Capsule().strokeBorder(p.border, lineWidth: isOn ? 0 : 1)
            )
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Color.white : p.text3)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.snappy(duration: 0.18)) { isOn.toggle() } }
    }
}

private struct HoverHighlight: ViewModifier {
    @State private var hover = false
    let color: Color
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(hover ? color : Color.clear, in: RoundedRectangle(cornerRadius: radius))
            .onHover { hover = $0 }
    }
}

extension View {
    func hoverHighlight(_ color: Color, radius: CGFloat = 7) -> some View {
        modifier(HoverHighlight(color: color, radius: radius))
    }
}
