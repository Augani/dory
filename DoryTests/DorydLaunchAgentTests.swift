import Foundation
import Darwin
import DoryOperations
import Testing
@testable import Dory

@MainActor
struct DorydLaunchAgentTests {
    @Test func launchdPlistBudgetsCoverTheActualHostShutdownDeadline() throws {
        let repository = ProcessInfo.processInfo.environment["DORY_TEST_REPO_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let timing = try String(
            contentsOf: repository.appendingPathComponent("dory-core-swift/Sources/DoryCore/DoryEngineShutdownTiming.swift"),
            encoding: .utf8
        )
        func seconds(_ name: String) throws -> Int {
            let line = try #require(timing.split(separator: "\n").first { $0.contains("let \(name):") })
            let value = try #require(line.split(separator: "=").last)
            return try #require(Int(value.trimmingCharacters(in: .whitespaces)))
        }
        let hostSeconds = try seconds("hostTerminationSeconds")
        #expect(hostSeconds > (try seconds("helperWatchdogSeconds")))
        var plists = [
            DorydLaunchAgent.launchAgentPlist(
                program: "/Applications/Dory.app/Contents/Helpers/doryd",
                helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers")
            ),
            try String(contentsOf: repository.appendingPathComponent("dory-core-swift/launchd/dev.dory.doryd.plist"), encoding: .utf8),
        ]
        for path in ["scripts/build.sh", "scripts/bundle-engine.sh"] {
            let source = try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
            let templates = source.components(separatedBy: "<?xml").dropFirst().compactMap { section -> String? in
                guard let end = section.range(of: "</plist>") else { return nil }
                let xml = "<?xml" + section[..<end.upperBound]
                return xml.contains("<key>ExitTimeOut</key>") ? xml : nil
            }
            #expect(templates.count == 1)
            plists.append(contentsOf: templates)
        }
        for plist in plists {
            let root = try #require(
                PropertyListSerialization.propertyList(from: Data(plist.utf8), options: [], format: nil) as? [String: Any]
            )
            let timeout = try #require(root["ExitTimeOut"] as? Int)
            #expect(timeout == DorydLaunchAgent.exitTimeoutSeconds)
            #expect(timeout >= hostSeconds + 10)
        }
    }

    @Test func launchAgentPrefersRetinaCapableVMMApplication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoryVMMBundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root
            .appendingPathComponent("DoryVMM.app/Contents/MacOS", isDirectory: true)
            .appendingPathComponent("dory-vmm")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        #expect(
            DorydLaunchAgent.vmmExecutablePath(helpersDirectory: root) == executable.path
        )
    }

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

    @Test func parseStatusTreatsWaitingJobAsLoadedButNotRunning() {
        let status = DorydLaunchAgent.parseStatus(
            """
            gui/501/dev.dory.doryd = {
                path = /Users/me/Library/LaunchAgents/dev.dory.doryd.plist
                state = waiting
                program = /Applications/Dory.app/Contents/Helpers/doryd
            }
            """
        )

        #expect(status.loaded)
        #expect(!status.running)
    }

    @Test func ensureCurrentKickstartsLoadedWaitingJob() async throws {
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
        let configuration = DorydLaunchAgent.Configuration()
        let plistURL = launchAgentsDirectory.appendingPathComponent("\(DorydLaunchAgent.label).plist")
        try DorydLaunchAgent.launchAgentPlist(
            program: dorydURL.path,
            helpersDirectory: helpersURL,
            configuration: configuration
        ).write(to: plistURL, atomically: true, encoding: .utf8)
        let recorder = LaunchctlRecorder(printOutput:
            """
            gui/501/dev.dory.doryd = {
                path = \(plistURL.path)
                state = waiting
                program = \(dorydURL.path)
                \(LifecycleFixture.environmentBlock(program: dorydURL, helpers: helpersURL))
            }
            """
        )

        let ok = await DorydLaunchAgent.ensureCurrent(
            bundle: bundle,
            launchAgentsDirectory: launchAgentsDirectory,
            configuration: configuration
        ) { arguments in
            recorder.run(arguments)
        }

        #expect(ok)
        #expect(recorder.commands == [
            ["print", DorydLaunchAgent.serviceTarget()],
            ["kickstart", DorydLaunchAgent.serviceTarget()],
        ])
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
            running: true,
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
            running: true,
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
            running: true,
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

    @Test func ensureCurrentReplacesStaleLaunchdJob() async throws {
        let fixture = try LifecycleFixture()
        let launchAgentsDirectory = fixture.agents
        defer { fixture.remove() }
        let currentPlist = launchAgentsDirectory.appendingPathComponent("\(DorydLaunchAgent.label).plist").path

        let recorder = LaunchctlRecorder(printOutput:
            """
            gui/501/dev.dory.doryd = {
                path = /Users/me/Library/LaunchAgents/dev.dory.doryd.plist
                state = running
                program = /tmp/OldDory.app/Contents/Helpers/doryd
            }
            """
        )

        let ok = await DorydLaunchAgent.ensureCurrent(bundle: fixture.bundle, launchAgentsDirectory: launchAgentsDirectory) { arguments in
            recorder.run(arguments)
        }

        #expect(ok)
        #expect(recorder.commands.map { $0.first ?? "" } == ["print", "bootout", "print", "bootstrap"])
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
        #expect(plist.contains("<key>DORYD_STATE_DIR</key>"))
        #expect(plist.contains("<string>\(DorydLaunchAgent.runtimeDirectory.appendingPathComponent("docker").path)</string>"))
        #expect(plist.contains("<key>DORYD_MACHINE_RUNTIME_DIR</key>"))
        #expect(plist.contains("<string>\(DorydLaunchAgent.runtimeDirectory.appendingPathComponent("m").path)</string>"))
        #expect(plist.contains("<key>DORYD_SHARE_HOME</key>"))
        #expect(plist.contains("<string>1</string>"))
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
        #expect(recorder.commands.map { $0.first ?? "" } == ["print", "bootstrap"])
        #expect(recorder.commands.first { $0.first == "bootstrap" }?.last == plistURL.path)
    }

    @Test func defaultEngineResourcesScaleWithHostCapacity() {
        #expect(DorydLaunchAgent.Configuration.hostScaledCPUCount(activeProcessorCount: 12) == 6)
        #expect(DorydLaunchAgent.Configuration.hostScaledCPUCount(activeProcessorCount: 8) == 6)
        #expect(DorydLaunchAgent.Configuration.hostScaledCPUCount(activeProcessorCount: 4) == 4)
        #expect(DorydLaunchAgent.Configuration.hostScaledCPUCount(activeProcessorCount: 2) == 2)
        #expect(DorydLaunchAgent.Configuration.hostScaledMemoryMB(physicalMemory: 16 * 1024 * 1024 * 1024) == 8192)
        #expect(DorydLaunchAgent.Configuration.hostScaledMemoryMB(physicalMemory: 8 * 1024 * 1024 * 1024) == 4096)
        #expect(DorydLaunchAgent.Configuration.hostScaledMemoryMB(physicalMemory: 128 * 1024 * 1024 * 1024) == 62 * 1024)
        #expect(DorydLaunchAgent.Configuration(memoryMB: 64 * 1024).memoryMB == 62 * 1024)
    }

    @Test func userEngineResourceLimitsReserveCapacityForMacOS() {
        #expect(AppStore.engineResourceLimits(activeProcessorCount: 12, physicalMemory: 16 * 1024 * 1024 * 1024)
            == AppStore.EngineResourceLimits(maximumCPUCount: 12, maximumMemoryMB: 12 * 1024))
        #expect(AppStore.engineResourceLimits(activeProcessorCount: 8, physicalMemory: 8 * 1024 * 1024 * 1024)
            == AppStore.EngineResourceLimits(maximumCPUCount: 8, maximumMemoryMB: 4 * 1024))
        #expect(AppStore.engineResourceLimits(activeProcessorCount: 2, physicalMemory: 4 * 1024 * 1024 * 1024)
            == AppStore.EngineResourceLimits(maximumCPUCount: 2, maximumMemoryMB: 2 * 1024))
        #expect(AppStore.engineResourceLimits(activeProcessorCount: 16, physicalMemory: 128 * 1024 * 1024 * 1024)
            == AppStore.EngineResourceLimits(maximumCPUCount: 16, maximumMemoryMB: 62 * 1024))
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
                \(LifecycleFixture.environmentBlock(program: dorydURL, helpers: helpersURL))
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
        #expect(recorder.commands.map { $0.first ?? "" } == ["print", "bootout", "print", "bootstrap"])

        let rejectingRecorder = LaunchctlRecorder(
            printOutput:
            """
            gui/501/dev.dory.doryd = {
                path = \(plistURL.path)
                state = running
                program = \(dorydURL.path)
                \(LifecycleFixture.environmentBlock(program: dorydURL, helpers: helpersURL))
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
        #expect(recorder.commands.map { $0.first ?? "" } == ["print", "bootout", "print", "bootstrap", "print", "bootstrap"])
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

    @Test func optOutRemovalPreventsLaunchAgentReloadAtNextLogin() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DorydLaunchAgentOptOut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = directory.appendingPathComponent("\(DorydLaunchAgent.label).plist")
        try "fixture".write(to: plist, atomically: true, encoding: .utf8)

        #expect(DorydLaunchAgent.removeCurrentPlist(launchAgentsDirectory: directory))
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        #expect(DorydLaunchAgent.removeCurrentPlist(launchAgentsDirectory: directory))
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

    @Test func qualificationBootstrapIsExplicitAndOffByDefault() throws {
        func environment(_ configuration: DorydLaunchAgent.Configuration) throws -> [String: String] {
            let plist = DorydLaunchAgent.launchAgentPlist(
                program: "/Applications/Dory.app/Contents/Helpers/doryd",
                helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers"),
                configuration: configuration
            )
            let data = try #require(plist.data(using: .utf8))
            let root = try #require(
                try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any]
            )
            return try #require(root["EnvironmentVariables"] as? [String: String])
        }

        #expect(
            try environment(DorydLaunchAgent.Configuration())[
                "DORYD_VM_QUALIFICATION_BOOTSTRAP"
            ] == "0"
        )
        #expect(
            try environment(DorydLaunchAgent.Configuration(
                vmQualificationBootstrapEnabled: true
            ))["DORYD_VM_QUALIFICATION_BOOTSTRAP"] == "1"
        )
    }

    @Test func launchAgentBindsRawHVToNestedRunnerApplication() throws {
        let plist = DorydLaunchAgent.launchAgentPlist(
            program: "/Applications/Dory.app/Contents/Helpers/doryd",
            helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers")
        )
        let data = try #require(plist.data(using: .utf8))
        let root = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
        let environment = try #require(root["EnvironmentVariables"] as? [String: String])

        #expect(
            environment["DORYD_HV_HELPER"]
                == "/Applications/Dory.app/Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv"
        )
        #expect(environment["DORYD_HV_HELPER"] != "/Applications/Dory.app/Contents/Helpers/dory-hv")
    }

    @Test func launchAgentCanDisableDaemonOwnedDomains() throws {
        let plist = DorydLaunchAgent.launchAgentPlist(
            program: "/Applications/Dory.app/Contents/Helpers/doryd",
            helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers"),
            configuration: DorydLaunchAgent.Configuration(domainsEnabled: false)
        )
        let data = try #require(plist.data(using: .utf8))
        let root = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
        let environment = try #require(root["EnvironmentVariables"] as? [String: String])

        #expect(environment["DORYD_NETWORKING"] == "0")
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
        #expect(DorydLaunchAgent.exitTimeoutSeconds >= 70)
    }

    @Test func launchAgentCarriesExplicitPersistedEngineChoices() throws {
        let plist = DorydLaunchAgent.launchAgentPlist(
            program: "/Applications/Dory.app/Contents/Helpers/doryd",
            helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers"),
            configuration: DorydLaunchAgent.Configuration(
                amd64EmulationEnabled: true,
                gpuVenusEnabled: true,
                bridgeSubnetCIDR: "10.44.16.0/20",
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
        #expect(environment["DORYD_BRIDGE_SUBNET"] == "10.44.16.0/20")
        #expect(
            environment["DORYD_SSH_AUTH_SOCK"]
                == "/private/tmp/com.apple.launchd.fixture/Listeners"
        )
        #expect(root["ExitTimeOut"] as? Int == DorydLaunchAgent.exitTimeoutSeconds)
    }

    @Test func launchAgentEngineChoicesAreOptInByDefault() throws {
        let runtimeDirectory = URL(fileURLWithPath: "/private/var/folders/test/T/dev.dory.doryd")
        let plist = DorydLaunchAgent.launchAgentPlist(
            program: "/Applications/Dory.app/Contents/Helpers/doryd",
            helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers"),
            runtimeDirectory: runtimeDirectory
        )
        let data = try #require(plist.data(using: .utf8))
        let root = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let environment = try #require(root["EnvironmentVariables"] as? [String: String])

        #expect(environment["DORYD_AMD64"] == "0")
        #expect(environment["DORYD_GPU"] == "off")
        #expect(environment["DORYD_STATE_DIR"] == runtimeDirectory.appendingPathComponent("docker").path)
        #expect(environment["DORYD_MACHINE_RUNTIME_DIR"] == runtimeDirectory.appendingPathComponent("m").path)
        #expect(environment["DORYD_SHARE_HOME"] == "1")
        #expect(
            environment["DORYD_BRIDGE_SUBNET"] == DoryIPv4BridgeNetwork.defaultCIDR
        )
    }

    @Test func runtimeDirectoryIsScopedBeneathThePrivateDarwinDirectoryAndFitsMachineSockets() {
        let darwinTemporaryDirectory = URL(
            fileURLWithPath: "/private/var/folders/8f/l7zyp8_15jl68g9stnzw7lvw0000gn/T",
            isDirectory: true
        )
        let runtimeDirectory = DorydLaunchAgent.runtimeDirectory(
            temporaryDirectory: darwinTemporaryDirectory
        )

        #expect(
            runtimeDirectory.path
                == darwinTemporaryDirectory.appendingPathComponent("d").standardizedFileURL.path
        )

        // MachineManager uses a 96-bit (24-hex-character) namespace token. console.sock is the
        // longest current per-machine endpoint, so proving it fits also covers handoff, agent,
        // shell, control, Docker, and USB sockets. sockaddr_un reserves one byte for the NUL.
        let longestMachineSocket = runtimeDirectory
            .appendingPathComponent("m", isDirectory: true)
            .appendingPathComponent(String(repeating: "a", count: 24), isDirectory: true)
            .appendingPathComponent("console.sock")
            .path
        #expect(longestMachineSocket.utf8.count <= 103)
    }


    @Test func missingPlistRecreationLeavesMatchingRunningJobAlone() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let recorder = LaunchctlRecorder(printOutput: fixture.status("running"))
        let ok = await DorydLaunchAgent.ensureCurrent(
            bundle: fixture.bundle, launchAgentsDirectory: fixture.agents
        ) { recorder.run($0) }
        #expect(ok)
        #expect(FileManager.default.fileExists(atPath: fixture.plist.path))
        #expect(recorder.commands.map { $0[0] } == ["print"])
    }


    @Test func missingPlistWithChangedLoadedSettingsStillReplaces() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let recorder = LaunchctlRecorder(printOutput: fixture.status("running"))
        let ok = await DorydLaunchAgent.ensureCurrent(
            bundle: fixture.bundle, launchAgentsDirectory: fixture.agents,
            configuration: .init(domainSuffix: "changed.dory.local"),
            bootstrapRetryDelay: .zero
        ) { recorder.run($0) }
        #expect(ok)
        #expect(recorder.commands.map { $0[0] } == ["print", "bootout", "print", "bootstrap"])
        #expect(try String(contentsOf: fixture.plist, encoding: .utf8).contains("changed.dory.local"))
    }

    @Test func missingPlistWithUnknownLoadedSettingsNeverClaimsSuccess() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let recorder = LaunchctlRecorder(printOutput: """
        gui/501/dev.dory.doryd = {
            path = \(fixture.plist.path)
            state = running
            program = \(fixture.program.path)
        }
        """)
        for _ in 0..<2 {
            let ok = await DorydLaunchAgent.ensureCurrent(
                bundle: fixture.bundle, launchAgentsDirectory: fixture.agents
            ) { recorder.run($0) }
            #expect(!ok)
        }
        #expect(recorder.commands.map { $0[0] } == ["print", "print"])
    }

    @Test func loadedSettingsIgnoreInheritedAndLaunchdInjectedEnvironment() {
        let status = DorydLaunchAgent.parseStatus("""
        inherited environment = {
            DORYD_MEMORY_MB => 256
        }
        environment = {
            OSLogRateLimit => 64
            DORYD_MEMORY_MB => 8192
            XPC_SERVICE_NAME => dev.dory.doryd
        }
        """)
        #expect(status.environment == ["DORYD_MEMORY_MB": "8192"])
    }

    @Test func changedExitTimeoutWithSameLoadedEnvironmentStillReplaces() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let xml = DorydLaunchAgent.launchAgentPlist(
            program: fixture.program.path, helpersDirectory: fixture.helpers
        )
        var old = try PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil) as! [String: Any]
        old["ExitTimeOut"] = 45
        try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0).write(to: fixture.plist)
        let recorder = LaunchctlRecorder(printOutput: fixture.status("running"))
        let ok = await DorydLaunchAgent.ensureCurrent(
            bundle: fixture.bundle, launchAgentsDirectory: fixture.agents,
            bootstrapRetryDelay: .zero
        ) { recorder.run($0) }
        #expect(ok)
        #expect(recorder.commands.map { $0[0] } == ["print", "bootout", "print", "bootstrap"])
        let updated = try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.plist), options: [], format: nil) as! [String: Any]
        #expect(updated["ExitTimeOut"] as? Int == DorydLaunchAgent.exitTimeoutSeconds)
    }

    @Test func equivalentBinaryPlistDoesNotRestartMatchingJob() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let xml = DorydLaunchAgent.launchAgentPlist(
            program: fixture.program.path, helpersDirectory: fixture.helpers
        )
        let object = try PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil)
        let binary = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        try binary.write(to: fixture.plist)
        let recorder = LaunchctlRecorder(printOutput: fixture.status("running"))
        let ok = await DorydLaunchAgent.ensureCurrent(
            bundle: fixture.bundle, launchAgentsDirectory: fixture.agents
        ) { recorder.run($0) }
        #expect(ok)
        #expect(recorder.commands.map { $0[0] } == ["print"])
        #expect(try Data(contentsOf: fixture.plist) == binary)
    }

    @Test func reopenedGUIWaitsForStoppingJobWithoutAnotherBootout() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let stopping = fixture.status("SIGTERMed")
        let recorder = LaunchctlRecorder(printOutput: "", queuedPrints: [stopping, stopping, nil])
        let ok = await DorydLaunchAgent.ensureCurrent(
            bundle: fixture.bundle, launchAgentsDirectory: fixture.agents,
            bootstrapRetryDelay: .zero
        ) { recorder.run($0) }
        #expect(ok)
        #expect(recorder.commands.map { $0[0] } == ["print", "print", "print", "bootstrap"])
        #expect(!recorder.commands.contains { $0.contains("-k") || $0.first == "bootout" })
    }

    @Test func stoppingJobWaitIsBoundedAndDoesNotBootstrapOnTimeout() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let recorder = LaunchctlRecorder(printOutput: fixture.status("SIGTERMed"))
        let ok = await DorydLaunchAgent.ensureCurrent(
            bundle: fixture.bundle, launchAgentsDirectory: fixture.agents,
            bootstrapRetryDelay: .zero, shutdownWaitTimeout: .zero
        ) { recorder.run($0) }
        #expect(!ok)
        #expect(recorder.commands.map { $0[0] } == ["print", "print"])
    }

    @Test func bootstrapInProgressWaitsForStoppingJobBeforeRetry() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.remove() }
        let stopping = fixture.status("SIGTERMed")
        let recorder = LaunchctlRecorder(
            printOutput: "", bootstrapStatuses: [37, 0],
            queuedPrints: [nil, stopping, stopping, nil]
        )
        let ok = await DorydLaunchAgent.ensureCurrent(
            bundle: fixture.bundle, launchAgentsDirectory: fixture.agents,
            bootstrapRetryDelay: .zero
        ) { recorder.run($0) }
        #expect(ok)
        #expect(recorder.commands.map { $0[0] } == ["print", "bootstrap", "print", "print", "print", "bootstrap"])
        #expect(!recorder.commands.contains { $0.contains("-k") || $0.first == "bootout" })
    }

    @Test func executedBootstrapCommandsKeepRunAtLoadChildAlive() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.stopOwnedChild(); fixture.remove() }
        let script = fixture.root.appendingPathComponent("launchctl-fixture.sh")
        // Execute the real command sequence against an owned stand-in, never /bin/launchctl.
        try """
        #!/bin/sh
        set -eu
        state=\(fixture.root.path)
        printf '%s\\n' "$*" >>"$state/commands"
        case "$1" in
          print) echo 'Could not find service' >&2; exit 1 ;;
          bootstrap)
            /bin/sleep 30 </dev/null >/dev/null 2>&1 &
            echo $! >"$state/child.pid"
            ;;
          kickstart)
            if [ "${2:-}" = -k ]; then
              /bin/sleep 0.018
              kill -TERM "$(cat "$state/child.pid")"
              : >"$state/newborn-killed"
            fi
            ;;
          *) exit 2 ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let ok = await DorydLaunchAgent.ensureCurrent(
            bundle: fixture.bundle, launchAgentsDirectory: fixture.agents
        ) { arguments in
            LifecycleFixture.execute(script, arguments: arguments)
        }
        let child = try #require(fixture.childPID)
        #expect(ok)
        #expect(kill(child, 0) == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("newborn-killed").path))
        let commands = try String(contentsOf: fixture.root.appendingPathComponent("commands"), encoding: .utf8)
        #expect(!commands.contains("kickstart"))
    }

    @Test func launchAgentDoesNotOwnRuntimeModePolicy() {
        let plist = DorydLaunchAgent.launchAgentPlist(
            program: "/Applications/Dory.app/Contents/Helpers/doryd",
            helpersDirectory: URL(fileURLWithPath: "/Applications/Dory.app/Contents/Helpers")
        )

        #expect(!plist.contains("<key>DORYD_AUTOSTART_DOCKER_TIER</key>"))
    }
}


@MainActor
private struct LifecycleFixture {
    let root: URL
    let bundle: Bundle
    let helpers: URL
    let agents: URL
    var program: URL { helpers.appendingPathComponent("doryd") }
    var plist: URL { agents.appendingPathComponent("\(DorydLaunchAgent.label).plist") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DoryLifecycle-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Dory.app")
        helpers = app.appendingPathComponent("Contents/Helpers")
        agents = root.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?><plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>dev.dory.lifecycle-fixture</string>
        </dict></plist>
        """.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let executable = helpers.appendingPathComponent("doryd")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        guard let found = Bundle(url: app) else { throw CocoaError(.fileReadCorruptFile) }
        bundle = found
    }

    func status(_ state: String, configuration: DorydLaunchAgent.Configuration = .init()) -> String {
        """
        gui/501/dev.dory.doryd = {
            path = \(plist.path)
            state = \(state)
            program = \(program.path)
            \(Self.environmentBlock(program: program, helpers: helpers, configuration: configuration))
        }
        """
    }

    static func environmentBlock(program: URL, helpers: URL, configuration: DorydLaunchAgent.Configuration = .init()) -> String {
        let plist = DorydLaunchAgent.launchAgentPlist(program: program.path, helpersDirectory: helpers, configuration: configuration)
        let root = try! PropertyListSerialization.propertyList(from: Data(plist.utf8), options: [], format: nil) as! [String: Any]
        let environment = root["EnvironmentVariables"] as! [String: String]
        return "environment = {\n" + environment.keys.sorted().map { "\($0) => \(environment[$0]!)" }.joined(separator: "\n") + "\n}"
    }

    var childPID: pid_t? {
        guard let text = try? String(contentsOf: root.appendingPathComponent("child.pid"), encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func stopOwnedChild() {
        guard let pid = childPID, pid > 1 else { return }
        _ = kill(pid, SIGTERM)
        for _ in 0..<100 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            usleep(10_000)
        }
        #expect(kill(pid, 0) == -1, "owned fixture sleep process must be cleaned up")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    nonisolated static func execute(_ executable: URL, arguments: [String]) -> DorydLaunchAgent.CommandResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do { try process.run() }
        catch { return .init(status: 127, stdout: "", stderr: "\(error)") }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return .init(status: process.terminationStatus,
                     stdout: String(decoding: stdout, as: UTF8.self),
                     stderr: String(decoding: stderr, as: UTF8.self))
    }
}

private final class LaunchctlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let printStatus: Int32
    private let printOutput: String
    private var bootstrapStatuses: [Int32]
    private var queuedPrints: [String?]
    private var removed = false
    private let bootoutStatus: Int32
    private let bootoutStderr: String
    private var recorded: [[String]] = []

    init(
        printStatus: Int32 = 0,
        printOutput: String,
        bootstrapStatuses: [Int32] = [],
        queuedPrints: [String?] = [],
        bootoutStatus: Int32 = 0,
        bootoutStderr: String = ""
    ) {
        self.printStatus = printStatus
        self.printOutput = printOutput
        self.bootstrapStatuses = bootstrapStatuses
        self.queuedPrints = queuedPrints
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
        defer { lock.unlock() }
        recorded.append(arguments)
        let bootstrapStatus = arguments.first == "bootstrap" && !bootstrapStatuses.isEmpty
            ? bootstrapStatuses.removeFirst()
            : nil
        if arguments.first == "print" {
            if !queuedPrints.isEmpty {
                if let output = queuedPrints.removeFirst() {
                    return DorydLaunchAgent.CommandResult(status: 0, stdout: output, stderr: "")
                }
                return DorydLaunchAgent.CommandResult(status: 1, stdout: "", stderr: "Could not find service")
            }
            if removed {
                return DorydLaunchAgent.CommandResult(status: 1, stdout: "", stderr: "Could not find service")
            }
            return DorydLaunchAgent.CommandResult(status: printStatus, stdout: printOutput, stderr: "")
        }
        if let bootstrapStatus {
            return DorydLaunchAgent.CommandResult(status: bootstrapStatus, stdout: "", stderr: "")
        }
        if arguments.first == "bootout" {
            if bootoutStatus == 0 { removed = true }
            return DorydLaunchAgent.CommandResult(status: bootoutStatus, stdout: "", stderr: bootoutStderr)
        }
        return DorydLaunchAgent.CommandResult(status: 0, stdout: "", stderr: "")
    }
}
