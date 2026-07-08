import Foundation
import Testing
@testable import Dory

struct DorydLaunchAgentTests {
    @Test func parseStatusExtractsProgramAndPlistPaths() {
        let status = DorydLaunchAgent.parseStatus(
            """
            gui/501/dev.dory.doryd = {
                path = /Users/me/Library/LaunchAgents/dev.dory.doryd.plist
                state = running
                program = /Applications/Dory.app/Contents/Helpers/doryd
            }
            """
        )

        #expect(status.loaded)
        #expect(status.plistPath == "/Users/me/Library/LaunchAgents/dev.dory.doryd.plist")
        #expect(status.programPath == "/Applications/Dory.app/Contents/Helpers/doryd")
    }

    @Test func decisionBootstrapsWhenJobIsMissing() {
        let decision = DorydLaunchAgent.decision(
            status: nil,
            currentPlist: "/Users/me/Library/LaunchAgents/dev.dory.doryd.plist",
            currentProgram: "/Applications/Dory.app/Contents/Helpers/doryd"
        )

        #expect(decision == .bootstrap)
    }

    @Test func decisionReplacesWhenLaunchdPointsAtOldAppBundle() {
        let status = DorydLaunchAgent.Status(
            loaded: true,
            plistPath: "/Users/me/Library/LaunchAgents/dev.dory.doryd.plist",
            programPath: "/Users/me/Library/Developer/Xcode/DerivedData/Dory/Build/Products/Debug/Dory.app/Contents/Helpers/doryd"
        )

        let decision = DorydLaunchAgent.decision(
            status: status,
            currentPlist: "/Users/me/Library/LaunchAgents/dev.dory.doryd.plist",
            currentProgram: "/Applications/Dory.app/Contents/Helpers/doryd"
        )

        #expect(decision == .replace)
    }

    @Test func decisionLeavesCurrentLaunchdJobAlone() {
        let status = DorydLaunchAgent.Status(
            loaded: true,
            plistPath: "/Users/me/Library/LaunchAgents/dev.dory.doryd.plist",
            programPath: "/Applications/Dory.app/Contents/Helpers/doryd"
        )

        let decision = DorydLaunchAgent.decision(
            status: status,
            currentPlist: "/Users/me/Library/LaunchAgents/dev.dory.doryd.plist",
            currentProgram: "/Applications/Dory.app/Contents/Helpers/doryd"
        )

        #expect(decision == .upToDate)
    }

    @Test func decisionReplacesWhenPlistEnvironmentChanged() {
        let status = DorydLaunchAgent.Status(
            loaded: true,
            plistPath: "/Users/me/Library/LaunchAgents/dev.dory.doryd.plist",
            programPath: "/Applications/Dory.app/Contents/Helpers/doryd"
        )

        let decision = DorydLaunchAgent.decision(
            status: status,
            currentPlist: "/Users/me/Library/LaunchAgents/dev.dory.doryd.plist",
            currentProgram: "/Applications/Dory.app/Contents/Helpers/doryd",
            currentPlistChanged: true
        )

        #expect(decision == .replace)
    }

    @Test func ensureCurrentReplacesStaleLaunchdJob() async {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DorydLaunchAgentTests-\(UUID().uuidString)", isDirectory: true)
        let launchAgentsDirectory = temporaryDirectory.appendingPathComponent("LaunchAgents", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let currentPlist = launchAgentsDirectory.appendingPathComponent("\(DorydLaunchAgent.label).plist").path
        let currentProgram = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/doryd").path
        guard FileManager.default.isExecutableFile(atPath: currentProgram) else {
            return
        }

        let recorder = LaunchctlRecorder(printOutput:
            """
            gui/501/dev.dory.doryd = {
                path = /Users/me/Library/LaunchAgents/dev.dory.doryd.plist
                state = running
                program = /tmp/OldDory.app/Contents/Helpers/doryd
            }
            """
        )

        let ok = await DorydLaunchAgent.ensureCurrent(bundle: .main, launchAgentsDirectory: launchAgentsDirectory) { arguments in
            recorder.run(arguments)
        }

        #expect(ok)
        #expect(recorder.commands.map { $0.first ?? "" } == ["print", "bootout", "bootstrap", "kickstart"])
        #expect(recorder.commands.first { $0.first == "bootstrap" }?.last == currentPlist)
    }

    @Test func ensureCurrentWritesLaunchAgentForInstalledBundlePath() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DorydLaunchAgentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let bundleURL = temporaryDirectory.appendingPathComponent("Dory.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        let launchAgentsDirectory = temporaryDirectory.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.dory.test</string></dict></plist>
        """.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        let dorydURL = helpersURL.appendingPathComponent("doryd")
        try "#!/bin/sh\n".write(to: dorydURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dorydURL.path)
        let bundle = try #require(Bundle(url: bundleURL))

        let recorder = LaunchctlRecorder(printStatus: 1, printOutput: "")
        let ok = await DorydLaunchAgent.ensureCurrent(bundle: bundle, launchAgentsDirectory: launchAgentsDirectory) { arguments in
            recorder.run(arguments)
        }

        let plistURL = launchAgentsDirectory.appendingPathComponent("\(DorydLaunchAgent.label).plist")
        let plist = try String(contentsOf: plistURL, encoding: .utf8)
        #expect(ok)
        #expect(plist.contains("<string>\(dorydURL.path)</string>"))
        #expect(plist.contains("<string>\(helpersURL.appendingPathComponent("dory-vmm").path)</string>"))
        #expect(plist.contains("<key>DORYD_DOMAIN_SUFFIX</key>"))
        #expect(plist.contains("<string>dory.local</string>"))
        #expect(recorder.commands.map { $0.first ?? "" } == ["print", "bootstrap", "kickstart"])
        #expect(recorder.commands.first { $0.first == "bootstrap" }?.last == plistURL.path)
    }

    @Test func ensureCurrentRestartsWhenLaunchAgentEnvironmentChanges() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DorydLaunchAgentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let bundleURL = temporaryDirectory.appendingPathComponent("Dory.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        let launchAgentsDirectory = temporaryDirectory.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.dory.test</string></dict></plist>
        """.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        let dorydURL = helpersURL.appendingPathComponent("doryd")
        try "#!/bin/sh\n".write(to: dorydURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dorydURL.path)
        let bundle = try #require(Bundle(url: bundleURL))

        let plistURL = launchAgentsDirectory.appendingPathComponent("\(DorydLaunchAgent.label).plist")
        try DorydLaunchAgent.launchAgentPlist(
            program: dorydURL.path,
            helpersDirectory: helpersURL,
            configuration: DorydLaunchAgent.Configuration(domainSuffix: "dory.local")
        ).write(to: plistURL, atomically: true, encoding: .utf8)

        let recorder = LaunchctlRecorder(printOutput:
            """
            gui/501/dev.dory.doryd = {
                path = \(plistURL.path)
                state = running
                program = \(dorydURL.path)
            }
            """
        )

        let ok = await DorydLaunchAgent.ensureCurrent(
            bundle: bundle,
            launchAgentsDirectory: launchAgentsDirectory,
            configuration: DorydLaunchAgent.Configuration(domainSuffix: "team.dory.local")
        ) { arguments in
            recorder.run(arguments)
        }

        let plist = try String(contentsOf: plistURL, encoding: .utf8)
        #expect(ok)
        #expect(plist.contains("<string>team.dory.local</string>"))
        #expect(recorder.commands.map { $0.first ?? "" } == ["print", "bootout", "bootstrap", "kickstart"])
    }
}

private final class LaunchctlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let printStatus: Int32
    private let printOutput: String
    private var recorded: [[String]] = []

    init(printStatus: Int32 = 0, printOutput: String) {
        self.printStatus = printStatus
        self.printOutput = printOutput
    }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ arguments: [String]) -> DorydLaunchAgent.CommandResult {
        lock.lock()
        recorded.append(arguments)
        lock.unlock()
        if arguments.first == "print" {
            return DorydLaunchAgent.CommandResult(status: printStatus, stdout: printOutput, stderr: "")
        }
        return DorydLaunchAgent.CommandResult(status: 0, stdout: "", stderr: "")
    }
}
