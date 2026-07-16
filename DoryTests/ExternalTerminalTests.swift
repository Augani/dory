import Foundation
import Testing
@testable import Dory

@MainActor
struct ExternalTerminalTests {
    @Test func preferenceDefaultsToTerminalAndRoundTripsCustomApplication() throws {
        let suiteName = "DoryTests.external-terminal.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ExternalTerminalPreferenceStore.load(defaults: defaults) == ExternalTerminalPreference(
            terminal: .terminal,
            customApplicationPath: nil
        ))

        let preference = ExternalTerminalPreference(
            terminal: .custom,
            customApplicationPath: "/Applications/ExampleTerm.app"
        )
        ExternalTerminalPreferenceStore.save(preference, defaults: defaults)
        #expect(ExternalTerminalPreferenceStore.load(defaults: defaults) == preference)
        #expect(preference.displayName == "ExampleTerm")
    }

    @Test func knownTerminalMetadataIncludesPopularMacApplications() {
        #expect(ExternalTerminal.terminal.bundleIdentifiers == ["com.apple.Terminal"])
        #expect(ExternalTerminal.iTerm2.bundleIdentifiers == ["com.googlecode.iterm2"])
        #expect(ExternalTerminal.ghostty.bundleIdentifiers == ["com.mitchellh.ghostty"])
        #expect(ExternalTerminal.warp.bundleIdentifiers.contains("dev.warp.Warp-Stable"))
        #expect(ExternalTerminal.wezTerm.bundleIdentifiers == ["com.github.wez.wezterm"])
        #expect(ExternalTerminal.alacritty.bundleIdentifiers == ["org.alacritty"])
        #expect(ExternalTerminal.kitty.bundleIdentifiers == ["net.kovidgoyal.kitty"])
    }

    @Test func terminalAndITermPlansUseTheirNativeAppleScriptContracts() throws {
        let terminal = try TerminalLauncher.launchPlan(
            command: "printf '\"hello\"'",
            terminal: .terminal,
            applicationURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        )
        #expect(terminal.executable == "/usr/bin/osascript")
        #expect(terminal.arguments.joined(separator: " ").contains("com.apple.Terminal"))
        #expect(terminal.arguments.joined(separator: " ").contains("\\\"hello\\\""))

        let iTerm = try TerminalLauncher.launchPlan(
            command: "dory machine shell dev",
            terminal: .iTerm2,
            applicationURL: URL(fileURLWithPath: "/Applications/iTerm.app")
        )
        #expect(iTerm.executable == "/usr/bin/osascript")
        #expect(iTerm.arguments.joined(separator: " ").contains("create window with default profile command"))
    }

    @Test func nativeCLIPlansKeepCommandAndArgumentsSeparate() throws {
        let app = URL(fileURLWithPath: "/Applications/Ghostty.app")
        let command = "docker exec -it example sh"
        let ghostty = try TerminalLauncher.launchPlan(
            command: command,
            terminal: .ghostty,
            applicationURL: app
        )
        #expect(ghostty.executable == "/usr/bin/open")
        #expect(ghostty.arguments == ["-na", app.path, "--args", "-e", "/bin/zsh", "-lc", command])

        let wezTerm = try TerminalLauncher.launchPlan(
            command: command,
            terminal: .wezTerm,
            applicationURL: URL(fileURLWithPath: "/Applications/WezTerm.app")
        )
        #expect(wezTerm.arguments.contains("--always-new-process"))
        #expect(wezTerm.arguments.last == command)
    }

    @Test func genericApplicationPlanUsesPrivateSelfDeletingCommandFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoryExternalTerminalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = URL(fileURLWithPath: "/Applications/Warp.app")
        let command = "dory machine shell 'machine one'"

        let plan = try TerminalLauncher.launchPlan(
            command: command,
            terminal: .warp,
            applicationURL: app,
            commandFileDirectory: directory
        )
        let file = try #require(plan.temporaryCommandFile)
        let script = try String(contentsOf: file, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)

        #expect(plan.executable == "/usr/bin/open")
        #expect(plan.arguments == ["-n", "-a", app.path, file.path])
        #expect(script.contains("/bin/rm -f -- \"$self\""))
        #expect(script.contains("dory machine shell"))
        #expect(permissions.intValue & 0o777 == 0o700)
    }
}
