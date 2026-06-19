import SwiftUI

enum SVGPath {
    private enum Token { case cmd(Character); case num(Double) }

    static func path(_ d: String) -> Path {
        let tokens = tokenize(d)
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var i = 0
        var command: Character = " "

        func nextNum() -> Double {
            while i < tokens.count {
                if case let .num(v) = tokens[i] { i += 1; return v }
                i += 1
            }
            return 0
        }
        func peekIsNum() -> Bool {
            i < tokens.count && { if case .num = tokens[i] { return true } else { return false } }()
        }

        while i < tokens.count {
            if case let .cmd(c) = tokens[i] { command = c; i += 1 }
            let rel = command.isLowercase
            switch Character(command.uppercased()) {
            case "M":
                let x = nextNum(), y = nextNum()
                current = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: current); start = current; lastControl = nil
                while peekIsNum() {
                    let lx = nextNum(), ly = nextNum()
                    current = rel ? CGPoint(x: current.x + lx, y: current.y + ly) : CGPoint(x: lx, y: ly)
                    path.addLine(to: current)
                }
            case "L":
                repeat {
                    let x = nextNum(), y = nextNum()
                    current = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                    path.addLine(to: current); lastControl = nil
                } while peekIsNum()
            case "H":
                repeat {
                    let x = nextNum()
                    current = rel ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                    path.addLine(to: current); lastControl = nil
                } while peekIsNum()
            case "V":
                repeat {
                    let y = nextNum()
                    current = rel ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                    path.addLine(to: current); lastControl = nil
                } while peekIsNum()
            case "C":
                repeat {
                    let c1 = point(nextNum(), nextNum(), rel, current)
                    let c2 = point(nextNum(), nextNum(), rel, current)
                    let end = point(nextNum(), nextNum(), rel, current)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2; current = end
                } while peekIsNum()
            case "S":
                repeat {
                    let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let c2 = point(nextNum(), nextNum(), rel, current)
                    let end = point(nextNum(), nextNum(), rel, current)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2; current = end
                } while peekIsNum()
            case "Q":
                repeat {
                    let c = point(nextNum(), nextNum(), rel, current)
                    let end = point(nextNum(), nextNum(), rel, current)
                    path.addQuadCurve(to: end, control: c)
                    lastControl = c; current = end
                } while peekIsNum()
            case "T":
                repeat {
                    let c = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let end = point(nextNum(), nextNum(), rel, current)
                    path.addQuadCurve(to: end, control: c)
                    lastControl = c; current = end
                } while peekIsNum()
            case "Z":
                path.closeSubpath(); current = start; lastControl = nil
            default:
                i += 1
            }
        }
        return path
    }

    private static func point(_ x: Double, _ y: Double, _ rel: Bool, _ current: CGPoint) -> CGPoint {
        rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
    }

    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(d)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter {
                tokens.append(.cmd(c)); i += 1
            } else if c == "-" || c == "+" || c == "." || c.isNumber {
                var s = ""
                if c == "-" || c == "+" { s.append(c); i += 1 }
                var seenDot = false
                while i < chars.count {
                    let ch = chars[i]
                    if ch.isNumber { s.append(ch); i += 1 }
                    else if ch == "." && !seenDot { seenDot = true; s.append(ch); i += 1 }
                    else if (ch == "e" || ch == "E") {
                        s.append(ch); i += 1
                        if i < chars.count && (chars[i] == "-" || chars[i] == "+") { s.append(chars[i]); i += 1 }
                    } else { break }
                }
                tokens.append(.num(Double(s) ?? 0))
            } else {
                i += 1
            }
        }
        return tokens
    }
}
