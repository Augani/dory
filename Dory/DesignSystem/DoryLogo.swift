import SwiftUI

struct FishMark: View {
    var fishColor: Color
    var eyeColor: Color
    var eye: CGPoint = CGPoint(x: 10.5, y: 14)

    var body: some View {
        Canvas { ctx, size in
            let scale = size.width / 32
            let t = CGAffineTransform(scaleX: scale, y: scale)
            for prim in DoryGlyph.fish.prims {
                ctx.fill(prim.makePath().applying(t), with: .color(fishColor.opacity(prim.opacity)))
            }
            let eyePath = Path(ellipseIn: CGRect(x: eye.x - 1.8, y: eye.y - 1.8, width: 3.6, height: 3.6)).applying(t)
            ctx.fill(eyePath, with: .color(eyeColor))
        }
    }
}

struct DoryLogo: View {
    @Environment(\.palette) private var palette
    var size: CGFloat = 30
    var corner: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(colors: [palette.accent, Color(hex: 0x1F6FD0)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                FishMark(fishColor: .white, eyeColor: palette.accent)
                    .frame(width: size * 0.66, height: size * 0.66)
            )
            .shadow(color: palette.accent.opacity(0.35), radius: 4, x: 0, y: 2)
    }
}
