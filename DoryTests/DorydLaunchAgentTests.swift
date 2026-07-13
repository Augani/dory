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
        #expect(plist.contains("<key>DORYD_HELPERS_DIR</key>"))
        #expect(plist.contains("<string>\(helpersURL.path)</string>"))
        #expect(plist.contains("<key>DORYD_RESOURCES_DIR</key>"))
        #expect(plist.contains("<string>\(contentsURL.appendingPathComponent("Resources").path)</string>"))
        #expect(plist.contains("<key>DORYD_HOST_CLI</key>"))
        #expect(plist.contains("<string>1</string>"))
        #expect(plist.contains("<key>DORYD_AMD64</key>"))
        #expect(plist.contains("<key>DORYD_GPU</key>"))
        let sizing = DorydLaunchAgent.Configuration()
        #expect(plist.contains("<key>DORYD_CPUS</key>"))
        #expect(plist.contains("<string>\(sizing.cpuCount)</string>"))
        #expect(plist.contains("<key>DORYD_MEMORY_MB</key>"))
        #expect(plist.contains("<string>\(sizing.memoryMB)</string>"))
        #expect(plist.contains("<key>DORYD_HV_RESTART_LIMIT</key>"))
        #expect(plist.contains("<string>3</string>"))
        #expect(plist.contains("<key>DORYD_HV_RESTART_DELAY</key>"))
        #expect(plist.contains("<string>0.5</string>"))
        #expect(!plist.contains("<key>DORYD_AUTOSTART_DOCKER_TIER</key>"))
        #expect(plist.contains("<key>DORYD_DOMAIN_SUFFIX</key>"))
        #expect(plist.contains("<string>dory.local</string>"))
        #expect(plist.contains("<key>StandardOutPath</key>"))
        #expect(plist.contains("<string>\(DorydLaunchAgent.logPath)</string>"))
        #expect(recorder.commands.map { $0.first ?? "" } == ["print", "bootstrap", "kickstart"])
        #expect(recorder.commands.first { $0.first == "bootstrap" }?.last == plistURL.path)
    }

    @Test func defaultEngineResourcesScaleWithHostCapacity() {
        #expect(DorydLaunchAgent.Configuration.hostScaledCPUCount(activeProcessorCount: 12) == 6)
        #expect(DorydLaunchAgent.Configuration.hostScaledCPUCount(activeProcessorCount: 8) == 6)
        #expect(DorydLaunchAgent.Configuration.hostScaledCPUCount(activeProcessorCount: 4) == 4)
        #expect(DorydLaunchAgent.Configuration.hostScaledCPUCount(activeProcessorCount: 2) == 2)
        #expect(DorydLaunchAgent.Configuration.hostScaledMemoryMB(physicalMemory: 16 * 1024 * 1024 * 1024) == 8192)
        #expect(DorydLaunchAgent.Configuration.hostScaledMemoryMB(physicalMemory: 8 * 1024 * 1024 * 1024) == 4096)
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

        let rejectingRecorder = LaunchctlRecorder(
            printOutput:
            """
            gui/501/dev.dory.doryd = {
                path = \(plistURL.path)
                state = running
                program = \(dorydURL.path)
            }
            """,
            bootoutStatus: 5,
            bootoutStderr: "Boot-out failed: operation not permitted"
        )
        let rejected = await DorydLaunchAgent.ensureCurrent(
            bundle: bundle,
            launchAgentsDirectory: launchAgentsDirectory,
            configuration: DorydLaunchAgent.Configuration(domainSuffix: "rejected.dory.local")
        ) { arguments in
            rejectingRecorder.run(arguments)
        }
        #expect(!rejected)
        #expect(rejectingRecorder.commands.map { $0.first ?? "" } == ["print", "bootout"])
    }

    @Test func ensureCurrentRetriesBootstrapAfterReplacingLaunchAgent() async throws {
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

        let recorder = LaunchctlRecorder(
            printOutput:
            """
            gui/501/dev.dory.doryd = {
                path = /Users/me/Library/LaunchAgents/dev.dory.doryd.plist
                state = running
                program = /tmp/OldDory.app/Contents/Helpers/doryd
            }
            """,
            bootstrapStatuses: [5, 0]
        )

        let ok = await DorydLaunchAgent.ensureCurrent(
            bundle: bundle,
            launchAgentsDirectory: launchAgentsDirectory,
            bootstrapRetryDelay: .milliseconds(0)
        ) { arguments in
            recorder.run(arguments)
        }

        #expect(ok)
        #expect(recorder.commands.map { $0.first ?? "" } == ["print", "bootout", "bootstrap", "print", "bootstrap", "kickstart"])
    }

    @Test func bootoutCurrentStopsLaunchAgentService() async {
        let recorder = LaunchctlRecorder(printOutput: "")

        let ok = await DorydLaunchAgent.bootoutCurrent(uid: 501) { arguments in
            recorder.run(arguments)
        }

        #expect(ok)
        #expect(recorder.commands == [["bootout", "gui/501/dev.dory.doryd"]])
    }

    @Test func bootoutCurrentTreatsMissingServiceAsStopped() async {
        let recorder = LaunchctlRecorder(
            printOutput: "",
            bootoutStatus: 36,
            bootoutStderr: "Boot-out failed: 3: No such process"
        )

        let ok = await DorydLaunchAgent.bootoutCurrent(uid: 501) { arguments in
            recorder.run(arguments)
        }

        #expect(ok)
        #expect(recorder.commands == [["bootout", "gui/501/dev.dory.doryd"]])
    }

    @Test func launchAgentCanDisableDaemonHostCLIRepair() {
        let plist = DorydLaunchAgent.launchAgentPlist(
            program: "/Applications/Dory.app/Contents/Helpers/doryd",
            helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers"),
            configuration: DorydLaunchAgent.Configuration(hostCLIEnabled: false)
        )

        #expect(plist.contains("<key>DORYD_HOST_CLI</key>"))
        #expect(plist.contains("<string>0</string>"))
    }

    @Test func launchAgentOwnsEngineResourcePolicy() {
        let plist = DorydLaunchAgent.launchAgentPlist(
            program: "/Applications/Dory.app/Contents/Helpers/doryd",
            helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers"),
            configuration: DorydLaunchAgent.Configuration(cpuCount: 6, memoryMB: 4096)
        )

        #expect(plist.contains("<key>DORYD_CPUS</key>"))
        #expect(plist.contains("<string>6</string>"))
        #expect(plist.contains("<key>DORYD_MEMORY_MB</key>"))
        #expect(plist.contains("<string>4096</string>"))
        #expect(plist.contains("<key>ExitTimeOut</key>"))
        #expect(plist.contains("<integer>\(DorydLaunchAgent.exitTimeoutSeconds)</integer>"))
        #expect(DorydLaunchAgent.exitTimeoutSeconds > 30)
    }

    @Test func launchAgentCarriesExplicitPersistedEngineChoices() throws {
        let plist = DorydLaunchAgent.launchAgentPlist(
            program: "/Applications/Dory.app/Contents/Helpers/doryd",
            helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers"),
            configuration: DorydLaunchAgent.Configuration(
                amd64EmulationEnabled: true,
                gpuVenusEnabled: true,
                sshAuthSock: "/private/tmp/com.apple.launchd.fixture/Listeners"
            )
        )
        let data = try #require(plist.data(using: .utf8))
        let root = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let environment = try #require(root["EnvironmentVariables"] as? [String: String])

        #expect(environment["DORYD_AMD64"] == "1")
        #expect(environment["DORYD_GPU"] == "venus")
        #expect(
            environment["DORYD_SSH_AUTH_SOCK"]
                == "/private/tmp/com.apple.launchd.fixture/Listeners"
        )
        #expect(root["ExitTimeOut"] as? Int == DorydLaunchAgent.exitTimeoutSeconds)
    }

    @Test func launchAgentEngineChoicesAreOptInByDefault() throws {
        let plist = DorydLaunchAgent.launchAgentPlist(
            program: "/Applications/Dory.app/Contents/Helpers/doryd",
            helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers")
        )
        let data = try #require(plist.data(using: .utf8))
        let root = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let environment = try #require(root["EnvironmentVariables"] as? [String: String])

        #expect(environment["DORYD_AMD64"] == "0")
        #expect(environment["DORYD_GPU"] == "off")
    }

    @Test func launchAgentDoesNotOwnRuntimeModePolicy() {
        let plist = DorydLaunchAgent.launchAgentPlist(
            program: "/Applications/Dory.app/Contents/Helpers/doryd",
            helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers")
        )

        #expect(!plist.contains("<key>DORYD_AUTOSTART_DOCKER_TIER</key>"))
    }
}

private final class LaunchctlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let printStatus: Int32
    private let printOutput: String
    private var bootstrapStatuses: [Int32]
    private let bootoutStatus: Int32
    private let bootoutStderr: String
    private var recorded: [[String]] = []

    init(
        printStatus: Int32 = 0,
        printOutput: String,
        bootstrapStatuses: [Int32] = [],
        bootoutStatus: Int32 = 0,
        bootoutStderr: String = ""
    ) {
        self.printStatus = printStatus
        self.printOutput = printOutput
        self.bootstrapStatuses = bootstrapStatuses
        self.bootoutStatus = bootoutStatus
        self.bootoutStderr = bootoutStderr
    }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ arguments: [String]) -> DorydLaunchAgent.CommandResult {
        lock.lock()
        recorded.append(arguments)
        let bootstrapStatus = arguments.first == "bootstrap" && !bootstrapStatuses.isEmpty
            ? bootstrapStatuses.removeFirst()
            : nil
        lock.unlock()
        if arguments.first == "print" {
            return DorydLaunchAgent.CommandResult(status: printStatus, stdout: printOutput, stderr: "")
        }
        if let bootstrapStatus {
            return DorydLaunchAgent.CommandResult(status: bootstrapStatus, stdout: "", stderr: "")
        }
        if arguments.first == "bootout" {
            return DorydLaunchAgent.CommandResult(status: bootoutStatus, stdout: "", stderr: bootoutStderr)
        }
        return DorydLaunchAgent.CommandResult(status: 0, stdout: "", stderr: "")
    }
}
