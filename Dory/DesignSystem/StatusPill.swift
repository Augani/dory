import SwiftUI

extension RunState {
    var pillText: String { label }
}

struct StatusPill: View {
    @Environment(\.palette) private var p
    let text: String
    var showsDot: Bool = true

    init(_ status: RunState) {
        self.text = status.label
        self.colorKey = .status(status)
        self.showsDot = true
    }

    init(inUse: Bool) {
        self.text = inUse ? "In use" : "Unused"
        self.colorKey = .inUse(inUse)
        self.showsDot = false
    }

    private enum ColorKey { case status(RunState), inUse(Bool) }
    private let colorKey: ColorKey

    private var fg: Color {
        switch colorKey {
        case .status(let s): return s.dotColor(p)
        case .inUse(let used): return used ? p.green : p.text3
        }
    }
    private var bg: Color {
        switch colorKey {
        case .status(let s): return s.badgeBackground(p)
        case .inUse(let used): return used ? p.greenWeak : p.pill
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if showsDot { Circle().fill(fg).frame(width: 5, height: 5) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(fg)
        .fixedSize()
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(bg, in: RoundedRectangle(cornerRadius: DoryRadius.md.rawValue))
        .accessibilityLabel(text)
    }
}
