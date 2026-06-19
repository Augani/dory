import SwiftUI

struct GlyphPrim: Sendable {
    enum Kind: Sendable {
        case path(String)
        case circle(CGFloat, CGFloat, CGFloat)
        case ellipse(CGFloat, CGFloat, CGFloat, CGFloat)
        case rect(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case line(CGFloat, CGFloat, CGFloat, CGFloat)
    }
    var kind: Kind
    var fill: Bool = false
    var opacity: Double = 1

    func makePath() -> Path {
        switch kind {
        case let .path(d): return SVGPath.path(d)
        case let .circle(cx, cy, r): return Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        case let .ellipse(cx, cy, rx, ry): return Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
        case let .rect(x, y, w, h, r): return Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
        case let .line(x1, y1, x2, y2):
            var p = Path(); p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2)); return p
        }
    }
}

enum DoryGlyph: Sendable {
    case containers, images, volumes, networks, kubernetes, machines, settings
    case search, plus, play, pause, listView, gridView, moon
    case eye, shield
    case fish

    var viewBox: CGFloat { self == .fish ? 32 : 16 }

    var prims: [GlyphPrim] {
        switch self {
        case .containers:
            return [.init(kind: .path("M8 1.7 14 5.1v5.8L8 14.3 2 10.9V5.1z")),
                    .init(kind: .path("M2 5.1 8 8.5 14 5.1")),
                    .init(kind: .path("M8 8.5v5.8"))]
        case .images:
            return [.init(kind: .path("M8 1.8 14.5 5 8 8.2 1.5 5z")),
                    .init(kind: .path("M1.6 8 8 11.2 14.4 8")),
                    .init(kind: .path("M1.6 11 8 14.2 14.4 11"))]
        case .volumes:
            return [.init(kind: .ellipse(8, 4, 5.2, 2.1)),
                    .init(kind: .path("M2.8 4v8c0 1.16 2.33 2.1 5.2 2.1s5.2-.94 5.2-2.1V4")),
                    .init(kind: .path("M2.8 8c0 1.16 2.33 2.1 5.2 2.1s5.2-.94 5.2-2.1"))]
        case .networks:
            return [.init(kind: .circle(8, 3.4, 2)), .init(kind: .circle(3.4, 12, 2)), .init(kind: .circle(12.6, 12, 2)),
                    .init(kind: .path("M8 5.4 4.4 10.3M8 5.4l3.6 4.9M5.4 12h5.2"))]
        case .kubernetes:
            return [.init(kind: .path("M8 1.6 13.5 4.4 12.2 10.6 8 14 3.8 10.6 2.5 4.4z")),
                    .init(kind: .circle(8, 7.6, 2)),
                    .init(kind: .path("M8 3.2v2.4M11.5 6 9.7 7M9 9.4l1.2 1.9M7 9.4 5.8 11.3M4.5 6 6.3 7"))]
        case .machines:
            return [.init(kind: .rect(2, 2.6, 12, 7.4, 1.2)), .init(kind: .path("M5.4 13h5.2M8 10v3"))]
        case .settings:
            return [.init(kind: .line(2, 5, 14, 5)), .init(kind: .circle(6, 5, 1.7), fill: true),
                    .init(kind: .line(2, 11, 14, 11)), .init(kind: .circle(10.5, 11, 1.7), fill: true)]
        case .search:
            return [.init(kind: .circle(7, 7, 4.3)), .init(kind: .line(10.4, 10.4, 14, 14))]
        case .plus:
            return [.init(kind: .line(8, 3, 8, 13)), .init(kind: .line(3, 8, 13, 8))]
        case .play:
            return [.init(kind: .path("M5 3.6 12 8l-7 4.4z"), fill: true)]
        case .pause:
            return [.init(kind: .rect(4, 3.5, 3, 9, 1), fill: true), .init(kind: .rect(9, 3.5, 3, 9, 1), fill: true)]
        case .listView:
            return [.init(kind: .line(2.5, 4, 13.5, 4)), .init(kind: .line(2.5, 8, 13.5, 8)), .init(kind: .line(2.5, 12, 13.5, 12))]
        case .gridView:
            return [.init(kind: .rect(2.5, 2.5, 4.4, 4.4, 1)), .init(kind: .rect(9.1, 2.5, 4.4, 4.4, 1)),
                    .init(kind: .rect(2.5, 9.1, 4.4, 4.4, 1)), .init(kind: .rect(9.1, 9.1, 4.4, 4.4, 1))]
        case .eye:
            return [.init(kind: .path("M2 8s2-4 6-4 6 4 6 4-2 4-6 4-6-4-6-4z")), .init(kind: .circle(8, 8, 1.6))]
        case .shield:
            return [.init(kind: .path("M8 1.5 3 4v4c0 3 2.2 5.5 5 6.5 2.8-1 5-3.5 5-6.5V4z"))]
        case .moon:
            return []
        case .fish:
            return [.init(kind: .path("M3 16c4-7 12-10 18-10 4 0 7 2 8 5l-4 5 4 5c-1 3-4 5-8 5-6 0-14-3-18-10z"), fill: true),
                    .init(kind: .path("M30 6l-6 10 6 10c-3 0-6-3-7-10 1-7 4-10 7-10z"), fill: true, opacity: 0.55)]
        }
    }
}

struct Glyph: View {
    let glyph: DoryGlyph
    var size: CGFloat = 16
    var color: Color = .primary
    var strokeWidth: CGFloat = 1.4

    var body: some View {
        Canvas { ctx, canvasSize in
            let scale = canvasSize.width / glyph.viewBox
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            let stroke = StrokeStyle(lineWidth: strokeWidth * scale, lineCap: .round, lineJoin: .round)
            if case .moon = glyph {
                ctx.drawLayer { layer in
                    let outer = Path(ellipseIn: CGRect(x: 2.7, y: 2.6, width: 10.6, height: 10.6)).applying(transform)
                    layer.fill(outer, with: .color(color))
                    layer.blendMode = .destinationOut
                    let bite = Path(ellipseIn: CGRect(x: 6.0, y: 0.4, width: 10.6, height: 10.6)).applying(transform)
                    layer.fill(bite, with: .color(.black))
                }
                return
            }
            for prim in glyph.prims {
                let path = prim.makePath().applying(transform)
                if prim.fill {
                    ctx.fill(path, with: .color(color.opacity(prim.opacity)))
                } else {
                    ctx.stroke(path, with: .color(color.opacity(prim.opacity)), style: stroke)
                }
            }
        }
        .frame(width: size, height: size)
    }
}
