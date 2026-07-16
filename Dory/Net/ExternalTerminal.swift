import AppKit
import Foundation

enum ExternalTerminal: String, CaseIterable, Identifiable, Sendable {
    case systemDefault
    case terminal
    case iTerm2
    case ghostty
    case warp
    case wezTerm
    case alacritty
    case kitty
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemDefault: "System Default"
        case .terminal: "Terminal"
        case .iTerm2: "iTerm2"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        case .wezTerm: "WezTerm"
        case .alacritty: "Alacritty"
        case .kitty: "Kitty"
        case .custom: "Other Application"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .systemDefault, .custom: []
        case .terminal: ["com.apple.Terminal"]
        case .iTerm2: ["com.googlecode.iterm2"]
        case .ghostty: ["com.mitchellh.ghostty"]
        case .warp: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"]
        case .wezTerm: ["com.github.wez.wezterm"]
        case .alacritty: ["org.alacritty"]
        case .kitty: ["net.kovidgoyal.kitty"]
        }
    }

    func applicationURL(workspace: NSWorkspace = .shared, customPath: String? = nil) -> URL? {
        if self == .custom {
            guard let customPath, !customPath.isEmpty else { return nil }
            let url = URL(fileURLWithPath: customPath).standardizedFileURL
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        for identifier in bundleIdentifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        return nil
    }

    func isInstalled(workspace: NSWorkspace = .shared, customPath: String? = nil) -> Bool {
        self == .systemDefault || applicationURL(workspace: workspace, customPath: customPath) != nil
    }

    static func recognized(applicationURL: URL) -> ExternalTerminal? {
        guard let identifier = Bundle(url: applicationURL)?.bundleIdentifier else { return nil }
        return allCases.first { $0.bundleIdentifiers.contains(identifier) }
    }
}

struct ExternalTerminalPreference: Sendable, Equatable {
    var terminal: ExternalTerminal
    var customApplicationPath: String?

    var displayName: String {
        guard terminal == .custom,
              let customApplicationPath,
              !customApplicationPath.isEmpty else {
            return terminal.displayName
        }
        return URL(fileURLWithPath: customApplicationPath).deletingPathExtension().lastPathComponent
    }
}

enum ExternalTerminalPreferenceStore {
    static let terminalKey = "dory.externalTerminal"
    static let customApplicationPathKey = "dory.externalTerminal.customApplicationPath"

    static func load(defaults: UserDefaults = .standard) -> ExternalTerminalPreference {
        let terminal = defaults.string(forKey: terminalKey)
            .flatMap(ExternalTerminal.init(rawValue:)) ?? .terminal
        let path = defaults.string(forKey: customApplicationPathKey)
        return ExternalTerminalPreference(terminal: terminal, customApplicationPath: path)
    }

    static func save(_ preference: ExternalTerminalPreference, defaults: UserDefaults = .standard) {
        defaults.set(preference.terminal.rawValue, forKey: terminalKey)
        if let path = preference.customApplicationPath, !path.isEmpty {
            defaults.set(path, forKey: customApplicationPathKey)
        } else {
            defaults.removeObject(forKey: customApplicationPathKey)
        }
    }
}
