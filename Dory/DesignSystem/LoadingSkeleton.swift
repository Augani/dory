import SwiftUI

struct SkeletonRows: View {
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var count: Int = 6
    @State private var shimmer = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 11) {
                    Circle().fill(p.bgElevated).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 5) {
                        bar(width: 160)
                        bar(width: 96)
                    }
                    Spacer()
                    bar(width: 54)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            }
        }
        .opacity(reduceMotion ? 1 : (shimmer ? 0.55 : 1))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { shimmer = true }
        }
        .accessibilityLabel("Loading containers")
    }

    private func bar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(p.bgElevated).frame(width: width, height: 9)
    }
}
