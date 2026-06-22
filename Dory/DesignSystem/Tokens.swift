import SwiftUI

enum DoryType: CGFloat {
    case label = 11
    case caption = 12
    case body = 13
    case title = 15
    case heading = 18
    case display = 22

    func font(_ weight: Font.Weight = .regular) -> Font {
        .system(size: rawValue, weight: weight)
    }
}

enum DorySpace: CGFloat {
    case xs = 4
    case sm = 8
    case md = 12
    case lg = 16
    case xl = 24
}

enum DoryRadius: CGFloat {
    case sm = 6
    case md = 8
    case lg = 12
}
