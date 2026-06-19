import SwiftUI

enum DoryAppearance: String, CaseIterable, Sendable {
    case light, dark

    var palette: DoryPalette { self == .dark ? .dark : .light }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

struct DoryPalette: Sendable, Equatable {
    var menubar: Color = .clear
    var bgWindow: Color = .clear
    var bgSidebar: Color = .clear
    var bgContent: Color = .clear
    var bgElevated: Color = .clear
    var bgInput: Color = .clear
    var bgHover: Color = .clear
    var bgRowHover: Color = .clear
    var border: Color = .clear
    var borderStrong: Color = .clear
    var text: Color = .clear
    var text2: Color = .clear
    var text3: Color = .clear
    var accent: Color = .clear
    var accentWeak: Color = .clear
    var accentText: Color = .clear
    var accentSoft: Color = .clear
    var green: Color = .clear
    var greenWeak: Color = .clear
    var amber: Color = .clear
    var amberWeak: Color = .clear
    var red: Color = .clear
    var redWeak: Color = .clear
    var monoBg: Color = .clear
    var monoText: Color = .clear
    var pill: Color = .clear

    static let dark: DoryPalette = {
        var p = DoryPalette()
        p.menubar = Color(hex: 0x12161E, opacity: 0.62)
        p.bgWindow = Color(hex: 0x1B1D21)
        p.bgSidebar = Color(hex: 0x202227)
        p.bgContent = Color(hex: 0x191A1E)
        p.bgElevated = Color(hex: 0x24262C)
        p.bgInput = Color(hex: 0x2A2C33)
        p.bgHover = Color.white.opacity(0.045)
        p.bgRowHover = Color.white.opacity(0.04)
        p.border = Color.white.opacity(0.07)
        p.borderStrong = Color.white.opacity(0.12)
        p.text = Color(hex: 0xECEEF1)
        p.text2 = Color(hex: 0x9B9EA6)
        p.text3 = Color(hex: 0x64676F)
        p.accent = Color(hex: 0x2E9BF5)
        p.accentWeak = Color(hex: 0x2E9BF5, opacity: 0.15)
        p.accentText = Color(hex: 0x6CB8FF)
        p.accentSoft = Color(hex: 0x2E9BF5, opacity: 0.10)
        p.green = Color(hex: 0x34D058)
        p.greenWeak = Color(hex: 0x34D058, opacity: 0.15)
        p.amber = Color(hex: 0xFFAA2C)
        p.amberWeak = Color(hex: 0xFFAA2C, opacity: 0.15)
        p.red = Color(hex: 0xFF5A52)
        p.redWeak = Color(hex: 0xFF5A52, opacity: 0.13)
        p.monoBg = Color(hex: 0x121319)
        p.monoText = Color(hex: 0xD6D9E0)
        p.pill = Color.white.opacity(0.06)
        return p
    }()

    static let light: DoryPalette = {
        var p = DoryPalette()
        p.menubar = Color.white.opacity(0.55)
        p.bgWindow = Color(hex: 0xFFFFFF)
        p.bgSidebar = Color(hex: 0xF1F2F5)
        p.bgContent = Color(hex: 0xFFFFFF)
        p.bgElevated = Color(hex: 0xFFFFFF)
        p.bgInput = Color(hex: 0xFFFFFF)
        p.bgHover = Color.black.opacity(0.04)
        p.bgRowHover = Color.black.opacity(0.035)
        p.border = Color.black.opacity(0.08)
        p.borderStrong = Color.black.opacity(0.12)
        p.text = Color(hex: 0x1C1D21)
        p.text2 = Color(hex: 0x6B6E76)
        p.text3 = Color(hex: 0x9A9DA5)
        p.accent = Color(hex: 0x0A84FF)
        p.accentWeak = Color(hex: 0x0A84FF, opacity: 0.10)
        p.accentText = Color(hex: 0x0A6FD8)
        p.accentSoft = Color(hex: 0x0A84FF, opacity: 0.07)
        p.green = Color(hex: 0x1FAB47)
        p.greenWeak = Color(hex: 0x1FAB47, opacity: 0.12)
        p.amber = Color(hex: 0xD98300)
        p.amberWeak = Color(hex: 0xD98300, opacity: 0.12)
        p.red = Color(hex: 0xE5453A)
        p.redWeak = Color(hex: 0xE5453A, opacity: 0.12)
        p.monoBg = Color(hex: 0x14161C)
        p.monoText = Color(hex: 0xD6D9E0)
        p.pill = Color.black.opacity(0.045)
        return p
    }()
}

extension EnvironmentValues {
    @Entry var palette: DoryPalette = .dark
}
