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

/// Shared sizing for page-level card collections.
///
/// Page grids deliberately use wider cards than compact grids embedded in sheets or
/// cards. Resource cards carry metrics, runtime evidence, and several labeled actions;
/// allowing them to collapse to the old 340-point minimum made those controls wrap
/// while the surrounding page remained mostly empty.
enum DoryPageGrid {
    static let spacing: CGFloat = 16
    static let horizontalInset: CGFloat = 20
    static let verticalInset: CGFloat = 18

    static let resourceCardMinimumWidth: CGFloat = 520
    static let resourceCardMaximumWidth: CGFloat = 680

    static let componentCardMinimumWidth: CGFloat = 420
    static let componentCardMaximumWidth: CGFloat = 560
    static let componentContentMaximumWidth: CGFloat = 1_180

    static func columns(minimum: CGFloat, maximum: CGFloat) -> [GridItem] {
        [
            GridItem(
                .adaptive(minimum: minimum, maximum: maximum),
                spacing: spacing,
                alignment: .topLeading
            )
        ]
    }
}
