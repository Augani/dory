import CryptoKit
import Darwin
import DoryCore
import DoryOperations
import DoryRendererWorkerWireContracts
import DoryVMContracts
import Foundation
import Testing
import XCTest
@testable import DorydKit

@Suite("MachineManager resolved-plan launch integration", .serialized)
struct MachineManagerResolvedPlanIntegrationTests {
    @Test("preflight tokens cannot authorize helper spawn", arguments: [
        DoryDaemonVirtualMachineLaunchValidationPurpose.restartPreflight, .stoppedPreflight,
    ])
    func preflightTokenCannotLaunch(purpose: DoryDaemonVirtualMachineLaunchValidationPurpose) throws {
        let wrongUse = DoryDaemonVirtualMachinePreSpawnAuthorization(purpose: purpose, revalidate: {})
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.revalidationFailed) {
            try wrongUse.authorizeResolvedLaunch()
        }
        let preflight = DoryDaemonVirtualMachinePreSpawnAuthorization(purpose: purpose, revalidate: {})
        if purpose == .stoppedPreflight { try preflight.authorizeStoppedPreflight() }
        else { try preflight.authorizeRestartPreflight() }
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.alreadyConsumed) {
            try preflight.authorizeResolvedLaunch()
        }
    }

    @Test("native VZMac launch emits resolved effective device policy arguments")
    func nativeVZMacLaunchEmitsResolvedDevicePolicyArguments() throws {
        var arguments = ["vzmac", "run"]
        let devices = DoryVirtualMachineDeviceCapabilityRequest(
            networkAttachment: .disconnected,
            display: DoryVirtualMachineDisplayCapabilityRequest(
                widthPixels: 1_920,
                heightPixels: 1_080
            ),
            audioInput: false,
            audioOutput: true,
            keyboard: true,
            pointer: true,
            directorySharing: false,
            clipboard: false,
            clipboardPolicy: .disabled,
            dynamicDisplay: true,
            gracefulShutdown: true
        )

        try MachineManager.appendVZMacResolvedDevicePolicyArguments(
            from: devices,
            to: &arguments
        )

        #expect(arguments.suffix(10) == [
            "--network", "disconnected",
            "--audio-input", "false",
            "--audio-output", "true",
            "--clipboard", "false",
            "--directory-sharing", "false",
        ])
    }

    @Test("native VZMac launch rejects resolved policies it cannot construct")
    func nativeVZMacLaunchRejectsUnsupportedResolvedPolicies() {
        var isolatedArguments: [String] = []
        #expect(throws: MachineManagerError.self) {
            var devices = DoryVirtualMachineDeviceCapabilityRequest(
                networkAttachment: .isolated
            )
            devices.clipboardPolicy = .disabled
            try MachineManager.appendVZMacResolvedDevicePolicyArguments(
                from: devices,
                to: &isolatedArguments
            )
        }

        var directionalClipboardArguments: [String] = []
        #expect(throws: MachineManagerError.self) {
            let devices = DoryVirtualMachineDeviceCapabilityRequest(
                clipboard: true,
                clipboardPolicy: DoryVMClipboardPolicy(
                    text: .hostToGuest,
                    image: .hostToGuest,
                    files: .off
                )
            )
            try MachineManager.appendVZMacResolvedDevicePolicyArguments(
                from: devices,
                to: &directionalClipboardArguments
            )
        }

        var shareArguments: [String] = []
        #expect(throws: MachineManagerError.self) {
            let devices = DoryVirtualMachineDeviceCapabilityRequest(
                directorySharing: true
            )
            try MachineManager.appendVZMacResolvedDevicePolicyArguments(
                from: devices,
                to: &shareArguments
            )
        }
    }

    @Test("single-use renderer identity binds only the resolved RawHV hardware-3D launch")
    func rendererIdentityBindsExactResolvedLaunch() throws {
        let identity = try rendererReleaseIdentityFixture()
        let binding = MachineBackendLaunchBinding(
            machineID: "dev",
            operationID: UUID(),
            backend: RawHVLinuxMachineBackend.backendDescriptor,
            componentIdentifier: "dory-hv",
            executablePath: "/bin/sh",
            graphics: .hardwareAccelerated3D,
            devices: .minimumBootable
        )
        let authorization = DoryDaemonVirtualMachinePreSpawnAuthorization
            .resolvingLaunchAuthority { .rendererReleaseIdentity(identity) }
        let launchAuthority = try authorization.authorizeResolvedLaunch()
        #expect(try MachineManager.resolvedRendererReleaseIdentity(
            preSpawnLaunchAuthority: launchAuthority,
            resolvedLaunchBinding: binding
        ) == identity)
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.alreadyConsumed) {
            _ = try authorization.authorizeResolvedLaunch()
        }

        #expect(throws: MachineManagerError.self) {
            _ = try MachineManager.resolvedRendererReleaseIdentity(
                preSpawnLaunchAuthority: .noRendererReleaseIdentityRequired,
                resolvedLaunchBinding: binding
            )
        }

        var displayBinding = binding
        displayBinding.graphics = .hostAcceleratedDisplay
        #expect(try MachineManager.resolvedRendererReleaseIdentity(
            preSpawnLaunchAuthority: .noRendererReleaseIdentityRequired,
            resolvedLaunchBinding: displayBinding
        ) == nil)
        #expect(throws: MachineManagerError.self) {
            _ = try MachineManager.resolvedRendererReleaseIdentity(
                preSpawnLaunchAuthority: .rendererReleaseIdentity(identity),
                resolvedLaunchBinding: displayBinding
            )
        }
    }

    @Test("validated persisted plan dispatches once without public-start recursion")
    func exactPlanDispatchesThroughRegistry() throws {
        try withHarness("success") { manager, starter, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            #expect(throws: (any Error).self) {
                _ = try operations.start("dev")
            }
            #expect(starter.count == 0)

            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            let requestedOperationID = UUID(
                uuidString: "01234567-89ab-4cde-8f01-23456789abcd"
            )!
            let requestedOperationToken = DoryOperationIdentity.canonical(
                requestedOperationID
            )
            let status = try manager.start(
                id: "dev",
                operationID: requestedOperationID
            )
            #expect(status.state == .running)
            #expect(starter.count == 1)
            #expect(resolver.callCount == 1)
            let identity = try #require(manager.resolvedLaunchIdentity(id: "dev"))
            #expect(identity.planRevision == 1)
            #expect(identity.backend == .doryHypervisor)
            #expect(identity.planSHA256.count == 64)
            #expect(status.runtimeIdentity.mode == .resolvedPlan)
            #expect(status.runtimeIdentity.planRevision == 1)
            #expect(status.runtimeIdentity.definitionSHA256?.count == 64)
            #expect(
                status.runtimeIdentity.backendImplementationIdentifier
                    == RawHVLinuxMachineBackend.backendDescriptor.implementationIdentifier
            )
            #expect(status.runtimeIdentity.virtualHardwareABIVersion == 1)
            #expect(status.runtimeIdentity.components.count == 1)
            let startEvents = try manager.flightRecorder(id: "dev", afterSequence: 0).events
                .filter { $0.operationKind == DoryWorkspaceMutationKind.starting.rawValue }
            #expect(!startEvents.isEmpty)
            #expect(startEvents.allSatisfy { $0.operationID == requestedOperationToken })
            let journals = try DoryOperationJournalStore(home: state + "/.lifecycle-journal").list()
            #expect(journals.filter { $0.plan.kind == .workspaceStart }.map(\.plan.id) == [requestedOperationID])
            #expect(!journals.contains { $0.plan.kind == .workspaceResolve })
            let service = DorydService(
                socketPath: state + "/service.sock",
                machineManager: manager
            )
            var xpcRows: NSArray = []
            service.machineList { rows, message in
                #expect(message.isEmpty)
                xpcRows = rows
            }
            let xpcStatus = try #require(xpcRows.firstObject as? NSDictionary)
            let xpcIdentity = try #require(
                xpcStatus["runtimeIdentity"] as? NSDictionary
            )
            #expect(xpcIdentity["mode"] as? String == "resolved-plan")
            #expect(xpcIdentity["planSHA256"] as? String == identity.planSHA256)
            #expect(xpcIdentity["backend"] as? String == "dory-hypervisor")
            #expect(xpcIdentity["resolvedPlan"] == nil)
            let encodedXPC = try JSONSerialization.data(withJSONObject: xpcIdentity)
            let xpcText = String(decoding: encodedXPC, as: UTF8.self)
            #expect(!xpcText.contains("/bin/sleep"))
            #expect(!xpcText.contains(state))
            #expect(FileManager.default.fileExists(atPath: state + "/dev/machine.json"))
            let pauseOperationID = UUID(
                uuidString: "12345678-9abc-4def-8012-3456789abcde"
            )!
            #expect(try manager.pause(
                id: "dev",
                operationID: pauseOperationID
            ).state == .paused)
            let resumeOperationID = UUID(
                uuidString: "23456789-abcd-4ef0-8123-456789abcdef"
            )!
            #expect(try manager.resume(
                id: "dev",
                operationID: resumeOperationID
            ).state == .running)
            let stopOperationID = UUID(
                uuidString: "3456789a-bcde-4f01-8234-56789abcdef0"
            )!
            #expect(try manager.stop(
                id: "dev",
                operationID: stopOperationID
            ).state == .stopped)
            let lifecycleEvents = try manager.flightRecorder(
                id: "dev",
                afterSequence: 0
            ).events
            for (kind, operationID) in [
                (DoryWorkspaceMutationKind.pausing, pauseOperationID),
                (DoryWorkspaceMutationKind.resuming, resumeOperationID),
                (DoryWorkspaceMutationKind.stopping, stopOperationID),
            ] {
                #expect(lifecycleEvents.contains {
                    $0.operationKind == kind.rawValue
                        && $0.operationID == DoryOperationIdentity.canonical(operationID)
                })
            }
            let snapshot = try manager.snapshot(id: "dev", snapshotID: "evidence")
            #expect(snapshot.runtimeIdentity == status.runtimeIdentity)
            #expect(snapshot.artifactEvidence?.rootfs.sha256.count == 64)
            #expect(snapshot.artifactEvidence?.kernel.sha256.count == 64)
            let bundle = state + "/resolved.dorymachine"
            try manager.exportSnapshot(
                machineID: "dev",
                snapshotID: snapshot.id,
                toPath: bundle
            )
            let component = try #require(snapshot.runtimeIdentity.components.first)
            let exactAssessment = try manager.assessSnapshotImport(
                fromPath: bundle,
                environment: DoryMachineImportEnvironment(
                    backendRuntimeBuildIdentifiers: [.doryHypervisor: "raw-runtime-1"],
                    backendComponents: [.doryHypervisor: [component]]
                )
            )
            #expect(exactAssessment.disposition == .requiresReplanning)
            #expect(exactAssessment.portable)
            #expect(exactAssessment.components.map(\.availability) == [.available])
            #expect(exactAssessment.issues == [.resolvedPlanRequiresReplanning])
            let missingAssessment = try manager.assessSnapshotImport(fromPath: bundle)
            #expect(missingAssessment.disposition == .requiresComponents)
            #expect(missingAssessment.components.map(\.availability) == [.missing])
            #expect(missingAssessment.issues.contains(.missingComponents))
            var tamperedIdentity = snapshot.runtimeIdentity
            tamperedIdentity.resolvedPlanSHA256 = String(repeating: "0", count: 64)
            #expect(tamperedIdentity.validate().contains { $0.code == .planDigestMismatch })

            let restored = try manager.restoreSnapshot(
                machineID: "dev",
                snapshotID: "evidence"
            )
            #expect(restored.state == .stopped)
            #expect(restored.runtimeIdentity.mode == .requiresReplanning)
            #expect(restored.runtimeIdentity.invalidationReason == .restoredSnapshot)
        }
    }

    @Test("adapter cannot substitute resolved graphics devices or port forwards")
    func adapterCannotSubstituteLaunchContract() throws {
        enum Mutation: CaseIterable, Sendable { case graphics, devices, portForwards }

        for mutation in Mutation.allCases {
            try withHarness("binding-substitution-\(mutation)") { manager, starter, _ in
                let plans = MutablePlanStore()
                let managerOperations = manager.resolvedLaunchCompatibilityOperations(
                    for: .doryHypervisor
                )
                let mutatingOperations = MachineBackendCompatibilityOperations(
                    authorizedStart: { binding in
                        var changed = binding
                        switch mutation {
                        case .graphics:
                            changed.graphics = .software
                        case .devices:
                            changed.devices.keyboard.toggle()
                        case .portForwards:
                            changed.portForwards = [DoryVMPortForward(
                                id: "substituted",
                                hostPort: 8_080,
                                guestPort: 80
                            )]
                        }
                        return try managerOperations.authorizedStart(changed)
                    },
                    stop: managerOperations.stop,
                    pause: managerOperations.pause,
                    resume: managerOperations.resume
                )
                let registry = try rawRegistry(operations: mutatingOperations)
                let resolver = ClosureLaunchResolver { request in
                    let resolution = try exactResolution(request: request)
                    plans.set(resolution.resolvedPlan)
                    return resolution
                }
                try manager.installResolvedLaunchInfrastructure(
                    registry: registry,
                    resolver: resolver,
                    plans: plans,
                    expectedPlanRevision: { _ in 1 }
                )

                #expect(throws: MachineManagerError.self) {
                    _ = try manager.start(id: "dev")
                }
                #expect(starter.count == 0)
            }
        }
    }

    @Test("resolved DoryARMVirt-v1 launch uses the runtime envelope as its sole device authority")
    func resolvedLaunchUsesExactHelperArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-resolved-arguments-\(UUID().uuidString)"
        ).path
        let helper = root + "/helper.sh"
        let capture = root + "/arguments.txt"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeExecutable(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(capture)'\nsleep 30\n",
            path: helper
        )

        try withHarness(
            "exact-arguments",
            acceleratedExecutablePath: helper,
            passMachineArguments: true,
            initialEnvironment: ["DORY_LOG_HARD_MAX_BYTES": "1048576"]
        ) { manager, starter, state in
            let definition = try DoryWorkspaceRepository(root: state)
                .readPersistedRecord(id: "dev").definition
            let devices = DoryDaemonVirtualMachinePlanningCoordinator.devices(for: definition)
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations, executablePath: helper)
            let helperSHA256 = try fileSHA256(path: helper)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(
                    request: request,
                    componentSHA256: helperSHA256
                )
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            let started = try manager.start(id: "dev")
            #expect(starter.count == 1)
            let deadline = Date().addingTimeInterval(2)
            var arguments: [String] = []
            while Date() < deadline {
                if let contents = try? String(contentsOfFile: capture, encoding: .utf8) {
                    arguments = contents.split(separator: "\n").map(String.init)
                    if arguments.contains("--runtime-launch-envelope") {
                        break
                    }
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            func value(after flag: String) throws -> String {
                let index = try #require(arguments.firstIndex(of: flag))
                let valueIndex = arguments.index(after: index)
                return try #require(
                    arguments.indices.contains(valueIndex) ? arguments[valueIndex] : nil,
                    "missing value after \(flag) in captured helper arguments"
                )
            }
            #expect(try value(after: "--operation-id") == started.activeOperationID)
            let envelope = try RuntimeLaunchEnvelope.decodeResolvedARMVirtArgument(
                value(after: "--runtime-launch-envelope")
            )
            #expect(envelope.machineID == "dev")
            #expect(envelope.operationID.uuidString.lowercased() == started.activeOperationID)
            #expect(envelope.graphics == .hostAcceleratedDisplay)
            #expect(envelope.devices == devices)
            #expect(envelope.portForwards.isEmpty)
            #expect(envelope.executionResources.memoryMB == 2_048)
            #expect(envelope.executionResources.virtualCPUCount == 2)
            #expect(envelope.executionResources.systemDiskQueueCount == 2)
            #expect(envelope.executionResources.schedulingPolicyRevision == 1)
            #expect(!arguments.contains("--rootfs"))
            #expect(!arguments.contains("--memory-mb"))
            #expect(!arguments.contains("--cpus"))
            #expect(!arguments.contains("--dockerd-sock"))
            #expect(!arguments.contains("--usb-control-sock"))
            #expect(!arguments.contains("--resolved-graphics"))
            #expect(!arguments.contains("--resolved-devices"))
            #expect(!arguments.contains("--resolved-port-forwards"))
            #expect(!arguments.contains { $0.hasPrefix("DORY_DESKTOP_GRAPHICS=") })
            #expect(!arguments.contains { $0.hasPrefix("DORY_DESKTOP_VMM=") })
            #expect(arguments.contains("DORY_LOG_HARD_MAX_BYTES=1048576"))
        }
    }

    @Test("resolved DoryARMVirt-v1 rejects launch when trusted machine-state authority is absent")
    func resolvedARMVirtRequiresMachineStateBroker() throws {
        try withHarness(
            "missing-machine-state-broker",
            injectStateBroker: false
        ) { manager, starter, _ in
            try installExactRawHVInfrastructure(manager)

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
        }
    }

    @Test("machine-directory replacement after admission closes FDs and never spawns")
    func machineDirectoryReplacementAfterAdmissionFailsClosed() throws {
        try withHarness("machine-state-replacement") { manager, starter, state in
            try installExactRawHVInfrastructure(manager)
            let machineDirectory = state + "/dev"
            let displaced = state + "/displaced-dev"
            manager.installRawHVStateAuthorityPreFinalRevalidationHookForTesting { machineID in
                guard machineID == "dev" else {
                    throw MachineManagerError.persistence("unexpected machine ID")
                }
                try FileManager.default.moveItem(
                    atPath: machineDirectory,
                    toPath: displaced
                )
                try FileManager.default.createDirectory(
                    atPath: machineDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                guard chmod(machineDirectory, mode_t(0o700)) == 0 else {
                    throw POSIXError(.EACCES)
                }
            }
            defer {
                if FileManager.default.fileExists(atPath: displaced) {
                    try? FileManager.default.removeItem(atPath: machineDirectory)
                    try? FileManager.default.moveItem(
                        atPath: displaced,
                        toPath: machineDirectory
                    )
                }
            }

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
            try assertDiskLeaseReleased(path: displaced + "/rootfs.ext4")
            #expect(try FileManager.default.contentsOfDirectory(atPath: displaced)
                .contains { $0.hasPrefix(".rawhv-") } == false)
        }
    }

    @Test("root replacement after admission propagates quarantine and never spawns")
    func machineStateRootReplacementAfterAdmissionFailsClosed() throws {
        try withHarness("machine-state-root-replacement") { manager, starter, state in
            try installExactRawHVInfrastructure(manager)
            let displaced = state + ".displaced"
            manager.installRawHVStateAuthorityPreFinalRevalidationHookForTesting { machineID in
                guard machineID == "dev" else {
                    throw MachineManagerError.persistence("unexpected machine ID")
                }
                try FileManager.default.moveItem(atPath: state, toPath: displaced)
                try FileManager.default.createDirectory(
                    atPath: state,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                guard chmod(state, mode_t(0o700)) == 0 else {
                    throw POSIXError(.EACCES)
                }
            }
            defer {
                if FileManager.default.fileExists(atPath: displaced) {
                    try? FileManager.default.removeItem(atPath: state)
                    try? FileManager.default.moveItem(atPath: displaced, toPath: state)
                }
            }

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
            try assertDiskLeaseReleased(path: displaced + "/dev/rootfs.ext4")
            #expect(try FileManager.default.contentsOfDirectory(atPath: displaced + "/dev")
                .contains { $0.hasPrefix(".rawhv-") } == false)
        }
    }

    @Test("machine-directory mode drift after admission never spawns")
    func machineDirectoryModeDriftAfterAdmissionFailsClosed() throws {
        try withHarness("machine-state-mode-drift") { manager, starter, state in
            try installExactRawHVInfrastructure(manager)
            let machineDirectory = state + "/dev"
            manager.installRawHVStateAuthorityPreFinalRevalidationHookForTesting { machineID in
                guard machineID == "dev", chmod(machineDirectory, mode_t(0o755)) == 0 else {
                    throw POSIXError(.EACCES)
                }
            }
            defer { _ = chmod(machineDirectory, mode_t(0o700)) }

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
            try assertDiskLeaseReleased(path: machineDirectory + "/rootfs.ext4")
            #expect(try FileManager.default.contentsOfDirectory(atPath: machineDirectory)
                .contains { $0.hasPrefix(".rawhv-") } == false)
        }
    }

    @Test("launch authority drift after raw-HV admission closes descriptors")
    func launchAuthorityDriftAfterRawHVAdmissionClosesDescriptors() throws {
        try withHarness("launch-authority-drift") { manager, starter, state in
            try installExactRawHVInfrastructure(manager)
            let machineDirectory = state + "/dev"
            manager.installRawHVStateAuthorityPreFinalRevalidationHookForTesting { machineID in
                guard machineID == "dev" else {
                    throw MachineManagerError.persistence("unexpected machine ID")
                }
                try manager.mutateReservedLaunchAuthorityForTesting(
                    machineID: machineID,
                    mutation: .operation
                )
            }

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
            try assertDiskLeaseReleased(path: machineDirectory + "/rootfs.ext4")
            #expect(try FileManager.default.contentsOfDirectory(atPath: machineDirectory)
                .contains { $0.hasPrefix(".rawhv-") } == false)
        }
    }

    @Test("resolved USB control rejects attach without desired-state authority")
    func resolvedUSBControlRejectsMissingAuthorization() throws {
        let usb = ResolvedPlanRecordingUSBController()
        try withHarness(
            "resolved-usb-control",
            requiresReadyHandoff: true,
            useShortStatePath: true,
            authenticatedRuntime: true,
            usbController: usb
        ) { manager, starter, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            let starting = try manager.start(id: "dev")
            let selection = try graphicsSelection(
                plan: plans.read(id: "dev"),
                operationID: try #require(starting.activeOperationID)
            )
            try sendVmmHandoff(
                path: try #require(starting.handoffSocketPath),
                ready: VmmReadyMessage(
                    machineID: "dev",
                    operationID: starting.activeOperationID,
                    agentBuild: "dory-agent/resolved-usb-test",
                    agentProtocolVersion: DoryCore.protocolVersion(),
                    agentCapabilities: [DoryAgentCapability(id: "usb-vhci", version: 1)],
                    agentSocketPath: "/run/dory-agent.sock",
                    controlSocketPath: try authenticatedControlSocket(state: state),
                    graphicsSelection: selection
                ),
                fileDescriptors: []
            )
            for _ in 0..<200 {
                if manager.status(id: "dev")?.state == .running { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            let readyStatus = try #require(manager.status(id: "dev"))
            #expect(
                readyStatus.state == .running,
                "resolved USB readiness failed: \(readyStatus.lastError ?? "unknown")"
            )
            #expect(starter.count == 1)

            #expect(throws: MachineManagerError.self) {
                _ = try manager.attachResolvedUSBDevice(
                    id: "dev",
                    busID: "3-2",
                    identityToken: DoryUSBPhysicalIdentityToken(
                        rawValue: String(repeating: "a", count: 64)
                    )!
                )
            }
            #expect(usb.callCount == 0)
        }
    }

    @Test("resolved wake clock synchronization follows desired-state authority")
    func resolvedClockSyncUsesExactAuthorization() throws {
        let clock = ResolvedClockSyncRecorder()
        try withHarness(
            "resolved-clock-sync",
            requiresReadyHandoff: true,
            useShortStatePath: true,
            authenticatedRuntime: true,
            agentConnector: clock.connect(socketPath:)
        ) { manager, starter, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(
                for: .doryHypervisor
            )
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            let starting = try manager.start(id: "dev")
            let selection = try graphicsSelection(
                plan: plans.read(id: "dev"),
                operationID: try #require(starting.activeOperationID)
            )
            try sendVmmHandoff(
                path: try #require(starting.handoffSocketPath),
                ready: VmmReadyMessage(
                    machineID: "dev",
                    operationID: starting.activeOperationID,
                    agentBuild: "dory-agent/resolved-clock-test",
                    agentProtocolVersion: DoryCore.protocolVersion(),
                    agentCapabilities: [
                        DoryAgentCapability(id: "clock-sync", version: 1),
                    ],
                    agentSocketPath: "/run/dory-agent.sock",
                    controlSocketPath: try authenticatedControlSocket(state: state),
                    graphicsSelection: selection
                ),
                fileDescriptors: []
            )
            for _ in 0..<200 {
                if manager.status(id: "dev")?.state == .running { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(manager.status(id: "dev")?.state == .running)
            #expect(starter.count == 1)

            let result = manager.syncAgentClock(
                now: Date(timeIntervalSince1970: 1_234.5)
            )
            #expect(result.attempted)
            #expect(result.synced)
            #expect(clock.syncs == [1_234_500_000_000])
        }
    }

    @Test("resolved RawHV readiness rejects a missing live graphics selection")
    func resolvedARMVirtReadinessRequiresGraphicsSelection() throws {
        try withHarness(
            "resolved-graphics-receipt",
            requiresReadyHandoff: true,
            useShortStatePath: true,
            authenticatedRuntime: true
        ) { manager, starter, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(
                for: .doryHypervisor
            )
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            let starting = try manager.start(id: "dev")
            try sendVmmHandoff(
                path: try #require(starting.handoffSocketPath),
                ready: VmmReadyMessage(
                    machineID: "dev",
                    operationID: starting.activeOperationID,
                    agentBuild: "dory-agent/missing-graphics-receipt",
                    controlSocketPath: try authenticatedControlSocket(state: state)
                ),
                fileDescriptors: []
            )
            for _ in 0..<200 {
                if manager.status(id: "dev")?.state == .failed { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            let failed = try #require(manager.status(id: "dev"))
            #expect(failed.state == .failed)
            #expect(failed.runtimeGraphicsSelection == nil)
            #expect(failed.lastError?.contains("graphics selection") == true)
            #expect(starter.count == 1)
        }
    }

    @Test("replacement manager preserves authenticated paused execution without spawning")
    func replacementManagerPreservesPausedRuntime() throws {
        try withHarness(
            "paused-reconnect",
            requiresReadyHandoff: true,
            useShortStatePath: true,
            authenticatedRuntime: true
        ) { manager, starter, state in
            let plans = MutablePlanStore()
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: rawRegistry(operations: manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)),
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )
            let starting = try manager.start(id: "dev")
            let control = try authenticatedControlSocket(state: state)
            try sendVmmHandoff(
                path: try #require(starting.handoffSocketPath),
                ready: VmmReadyMessage(
                    machineID: "dev",
                    operationID: starting.activeOperationID,
                    controlSocketPath: control,
                    graphicsSelection: try graphicsSelection(
                        plan: plans.read(id: "dev"),
                        operationID: try #require(starting.activeOperationID)
                    )
                ),
                fileDescriptors: []
            )
            let deadline = Date().addingTimeInterval(5)
            while manager.status(id: "dev")?.state == .starting, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(try manager.pause(id: "dev").state == .paused)
            let launchIdentity = try DoryRuntimeReconnectRecordStore(root: state)
                .read(machineID: "dev").launchIdentity
            let before = try VmmControlClient.authenticateRuntime(
                socketPath: control, launchIdentity: launchIdentity
            )
            #expect(before.runtimeState == .paused)

            // The replacement reads only the durable workspace and the live helper challenge.
            // The first manager remains retained here to avoid its graceful deinit stop hook;
            // daemon SIGKILL qualification is a separate process-level campaign.
            let replacementStarter = CountingProcessStarter()
            let replacement = MachineManager(
                configuration: MachineManagerConfiguration(
                    vmmExecutablePath: "/bin/sh",
                    stateDirectory: state,
                    requiresReadyHandoff: true
                ),
                launchPolicy: .requireResolvedPlan,
                machineStateBroker: try DoryMachineStateBroker(canonicalStateRootPath: state),
                processStarter: { try replacementStarter.start($0) }
            )
            defer { replacement.stopAll() }
            try replacement.installResolvedLaunchInfrastructure(
                registry: rawRegistry(operations: replacement.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)),
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )
            #expect(replacement.status(id: "dev")?.state == .paused)
            #expect(replacementStarter.count == 0)
            #expect(starter.count == 1)
            #expect(try replacement.resume(id: "dev").state == .running)
            let after = try VmmControlClient.authenticateRuntime(
                socketPath: control, launchIdentity: launchIdentity
            )
            #expect(after.identity == before.identity)
            #expect(after.runtimeState == .running)
            #expect(try replacement.stop(id: "dev").state == .stopped)
            #expect(!before.identity.matchesCurrentProcess())
        }
    }

    @Test("daemon death preserves helper generation and refreshes guest readiness",
          arguments: [false, true], [false, true])
    func daemonDeathRecoversRuntime(paused: Bool, incompatibleAgent: Bool) throws {
        let state = "/private/tmp/dory-r-\(UUID().uuidString)"
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        daemon.arguments = [
            "xctest", "-XCTest", "DorydKitTests.DoryRuntimeReconnectTests/testDaemonSubprocessOwner",
            Bundle(for: DoryRuntimeReconnectTests.self).bundlePath,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DORY_RECONNECT_DAEMON_ROOT"] = state
        environment["DORY_RECONNECT_DAEMON_PAUSED"] = paused ? "1" : "0"
        daemon.environment = environment
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.nullDevice
        try daemon.run()
        defer {
            if daemon.isRunning { _ = kill(daemon.processIdentifier, SIGKILL) }
            daemon.waitUntilExit()
            if let record = try? DoryRuntimeReconnectRecordStore(root: state).read(machineID: "dev"),
               let identity = record.processIdentity, identity.matchesCurrentProcess() {
                _ = kill(identity.processIdentifier, SIGKILL)
            }
            try? FileManager.default.removeItem(atPath: state)
        }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: state + "/daemon-ready"),
              daemon.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(FileManager.default.fileExists(atPath: state + "/daemon-ready"))
        let original = try DoryRuntimeReconnectRecordStore(root: state).read(machineID: "dev")
        let process = try #require(original.processIdentity)
        _ = kill(daemon.processIdentifier, SIGKILL)
        daemon.waitUntilExit()
        #expect(daemon.terminationReason == .uncaughtSignal)
        #expect(process.matchesCurrentProcess())

        let starter = CountingProcessStarter()
        let permitAgentConnection = DispatchSemaphore(value: 0)
        defer { permitAgentConnection.signal() }
        let agent = ResolvedClockSyncRecorder(
            advertisedInfo: DoryAgentInfo(
                protocolVersion: DoryCore.protocolVersion() + (incompatibleAgent ? 1 : 0),
                kernel: "Linux reconnect fixture",
                agentBuild: "dory-agent/fresh-reconnect",
                uptimeSeconds: 10,
                capabilities: [DoryAgentCapability(id: "exec", version: 1)]
            ),
            execOutput: "2: eth0 inet 192.168.64.12/24 scope global eth0\n"
        )
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sh", stateDirectory: state, requiresReadyHandoff: true
            ),
            launchPolicy: .requireResolvedPlan,
            machineStateBroker: try DoryMachineStateBroker(canonicalStateRootPath: state),
            agentConnector: { path in
                guard permitAgentConnection.wait(timeout: .now() + 5) == .success else {
                    throw ResolvedLaunchLifecycleFixtureError.prepublicationFailure
                }
                permitAgentConnection.signal()
                return try agent.connect(socketPath: path)
            },
            processStarter: { try starter.start($0) }
        )
        defer { manager.stopAll() }
        let plans = DoryResolvedMachinePlanRepository(root: state)
        let resolver = ClosureLaunchResolver { _ in
            throw ResolvedLaunchLifecycleFixtureError.prepublicationFailure
        }
        let ledger = DoryVirtualMachineResourceAdmissionLedger(root: state + "/admission")
        try manager.installResolvedLaunchInfrastructure(
            registry: rawRegistry(operations: manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)),
            resolver: resolver,
            plans: plans,
            expectedPlanRevision: { _ in 1 },
            productionPlanningController: RejectingPlanningRecorder(),
            resourceAdmissionLedger: ledger
        )
        #expect(manager.status(id: "dev")?.state == (paused ? .paused : .running))
        #expect(manager.status(id: "dev")?.pid == process.processIdentifier)
        #expect(starter.count == 0)
        #expect(resolver.callCount == 0)
        #expect(try ledger.snapshot().leases.first?.state == .running)
        #expect(manager.status(id: "dev")?.readiness.toolsConnected == false)
        #expect(manager.status(id: "dev")?.readiness.desktopVisible == false)
        #expect(manager.status(id: "dev")?.readiness.workloadReady == false)
        #expect(manager.status(id: "dev")?.runtimeAddress == nil)
        if paused { #expect(try manager.resume(id: "dev").state == .running) }
        permitAgentConnection.signal()
        let refreshedDeadline = Date().addingTimeInterval(5)
        while Date() < refreshedDeadline {
            if incompatibleAgent, agent.infoCalls > 0 { break }
            if !incompatibleAgent, manager.status(id: "dev")?.runtimeAddress != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(agent.infoCalls == 1)
        let refreshed = try #require(manager.status(id: "dev"))
        #expect(refreshed.readiness.toolsConnected == !incompatibleAgent)
        #expect(!refreshed.readiness.workloadReady)
        #expect(!refreshed.readiness.desktopVisible)
        #expect(refreshed.runtimeAddress == (incompatibleAgent ? nil : "192.168.64.12"))
        #expect(try manager.stop(id: "dev").state == .stopped)
        #expect(try ledger.snapshot().leases.first?.state == .stopped)
        #expect(!process.matchesCurrentProcess())
        #expect(try DoryRuntimeReconnectRecordStore(root: state).liveRecords().isEmpty)
    }

    private static let restartFixtureOperationID = UUID(uuidString: "e27d789b-362b-4ba9-8b4b-e0692d2f306c")!

    @Test("restart journal survives daemon death at each process handoff boundary",
          arguments: ["before-stop", "after-stop", "after-ready"], [false, true])
    func restartDaemonDeathRecoversOneOperation(boundary: String, paused: Bool) throws {
        let state = "/private/tmp/dory-r-\(UUID().uuidString)"
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        daemon.arguments = [
            "xctest", "-XCTest", "DorydKitTests.DoryRuntimeReconnectTests/testDaemonSubprocessOwner",
            Bundle(for: DoryRuntimeReconnectTests.self).bundlePath,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DORY_RECONNECT_DAEMON_ROOT"] = state
        environment["DORY_RECONNECT_DAEMON_PAUSED"] = paused ? "1" : "0"
        environment["DORY_RECONNECT_RESTART_BOUNDARY"] = boundary
        daemon.environment = environment
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.nullDevice
        try daemon.run()
        defer {
            if daemon.isRunning { _ = kill(daemon.processIdentifier, SIGKILL) }
            daemon.waitUntilExit()
            if let record = try? DoryRuntimeReconnectRecordStore(root: state).read(machineID: "dev"),
               let identity = record.processIdentity, identity.matchesCurrentProcess() {
                _ = kill(identity.processIdentifier, SIGKILL)
            }
            try? FileManager.default.removeItem(atPath: state)
        }
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: state + "/daemon-ready"),
              daemon.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(FileManager.default.fileExists(atPath: state + "/daemon-ready"), "restart fixture did not reach \(boundary)")
        let source = try JSONDecoder().decode(DoryRuntimeReconnectRecord.self, from: Data(contentsOf: URL(fileURLWithPath: state + "/restart-source.json")))
        let sourceProcess = try #require(source.processIdentity)
        let survivor = try? DoryRuntimeReconnectRecordStore(root: state).read(machineID: "dev")
        _ = kill(daemon.processIdentifier, SIGKILL)
        daemon.waitUntilExit()
        #expect(daemon.terminationReason == .uncaughtSignal)
        #expect(sourceProcess.matchesCurrentProcess() == (boundary == "before-stop"))

        let starter = CountingProcessStarter()
        let resolver = ClosureLaunchResolver { _ in throw ResolvedLaunchLifecycleFixtureError.prepublicationFailure }
        let planning = RejectingPlanningRecorder()
        let ledger = DoryVirtualMachineResourceAdmissionLedger(root: state + "/admission")
        let before = try #require(ledger.snapshot().leases.first)
        let manager = MachineManager(
            configuration: .init(vmmExecutablePath: "/bin/sh", stateDirectory: state, requiresReadyHandoff: true),
            launchPolicy: .requireResolvedPlan,
            machineStateBroker: try DoryMachineStateBroker(canonicalStateRootPath: state),
            processStarter: { try starter.start($0) }
        )
        defer { manager.stopAll() }
        let journal = try DoryOperationJournalStore(home: state + "/.lifecycle-journal")
        #expect(try journal.read(Self.restartFixtureOperationID).state.status == .running)
        try manager.installResolvedLaunchInfrastructure(
            registry: rawRegistry(operations: manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)),
            resolver: resolver, plans: DoryResolvedMachinePlanRepository(root: state),
            expectedPlanRevision: { _ in 1 }, productionPlanningController: planning,
            resourceAdmissionLedger: ledger
        )
        let status = try #require(manager.status(id: "dev"))
        let recovered = try journal.read(Self.restartFixtureOperationID)
        let operation = try journal.acquire(Self.restartFixtureOperationID).readWorkspaceLifecycleOperation()
        #expect(operation.sourceRuntimeOperationID == DoryOperationIdentity.parseCanonical(source.launchIdentity.operationID))
        #expect(operation.source.runtime == operation.target.runtime)
        #expect(operation.admissionLeaseID == before.leaseID)
        #expect(recovered.state.status == (boundary == "after-ready" ? .completed : .failed))
        #expect(status.state == (boundary == "after-stop" ? .stopped : (boundary == "before-stop" && paused ? .paused : .running)))
        #expect(status.pid == (boundary == "after-stop" ? nil : survivor?.processIdentity?.processIdentifier))
        let after = try #require(ledger.snapshot().leases.first)
        #expect(after.leaseID == before.leaseID)
        #expect(after.resources == before.resources)
        #expect(after.state == (boundary == "after-stop" ? .stopped : .running))
        #expect(starter.count == 0)
        #expect(resolver.callCount == 0)
        #expect(planning.machineIDs.isEmpty)
        if boundary == "after-ready" {
            #expect(try manager.restart(id: "dev", operationID: Self.restartFixtureOperationID).pid == status.pid)
        } else {
            #expect(throws: (any Error).self) { _ = try manager.restart(id: "dev", operationID: Self.restartFixtureOperationID) }
        }
        if boundary != "after-stop" { #expect(try manager.stop(id: "dev").state == .stopped) }
        #expect(try ledger.snapshot().leases.count == 1)
        #expect(try ledger.snapshot().leases.first?.state == .stopped)
        #expect(starter.count == 0)
    }

    /// Invoked only in an xctest subprocess which the owning test kills without Swift teardown.
    func runDaemonReconnectFixture(state: String, paused: Bool, restartBoundary: String? = nil) throws {
        try withHarness(
            "daemon-generation",
            stateDirectoryOverride: state,
            admittedDesktopFixture: true,
            requiresReadyHandoff: true,
            useShortStatePath: true,
            authenticatedRuntime: true
        ) { manager, _, state in
            let plans = DoryResolvedMachinePlanRepository(root: state)
            let ledger = DoryVirtualMachineResourceAdmissionLedger(root: state + "/admission")
            let resolver = ClosureLaunchResolver { request in
                if let existing = try? plans.read(id: "dev") {
                    return try exactResolution(request: request, admissionEvidence: existing.resourceAdmission)
                }
                let reserved = try ledger.reserveStarting(
                    binding: .init(
                        machineID: "dev", definitionRevision: request.definition.lifecycle.revision,
                        definitionSHA256: SHA256.hash(data: request.canonicalDefinitionData).map { String(format: "%02x", $0) }.joined(),
                        plannedPlanRevision: request.expectedPlanRevision
                    ),
                    hostFacts: .init(logicalCPUCount: 12, physicalMemoryBytes: 32 * 1_073_741_824, freeStorageBytes: 512 * 1_073_741_824),
                    workload: .desktop, resources: request.definition.resources
                )
                let resolution = try exactResolution(request: request, admissionEvidence: reserved.evidence)
                _ = try ledger.bind(leaseID: reserved.leaseID, to: resolution.resolvedPlan, expectedLeaseRevision: reserved.leaseRevision)
                try plans.create(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: rawRegistry(operations: manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)),
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 },
                productionPlanningController: RejectingPlanningRecorder(),
                resourceAdmissionLedger: ledger
            )
            let starting = try manager.start(id: "dev")
            try sendVmmHandoff(
                path: try #require(starting.handoffSocketPath),
                ready: VmmReadyMessage(
                    machineID: "dev", operationID: starting.activeOperationID,
                    agentBuild: "dory-agent/previous-daemon",
                    agentProtocolVersion: DoryCore.protocolVersion(),
                    agentSocketPath: "/run/dory-agent.sock",
                    controlSocketPath: try authenticatedControlSocket(state: state),
                    graphicsSelection: try graphicsSelection(
                        plan: plans.read(id: "dev"), operationID: try #require(starting.activeOperationID)
                    ),
                    guestBooted: true, toolsConnected: true,
                    desktopVisible: true, workloadReady: true
                ), fileDescriptors: []
            )
            let deadline = Date().addingTimeInterval(5)
            while manager.status(id: "dev")?.state == .starting, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            try #require(manager.status(id: "dev")?.state == .running)
            if paused { _ = try manager.pause(id: "dev") }
            if let restartBoundary {
                let source = try DoryRuntimeReconnectRecordStore(root: state).read(machineID: "dev")
                try JSONEncoder().encode(source).write(to: URL(fileURLWithPath: state + "/restart-source.json"))
                manager.installLifecycleFaultInjectorForTesting { point in
                    let matches = (restartBoundary == "before-stop" && point == .restartBeforeStop)
                        || (restartBoundary == "after-stop" && point == .stopAfterProcessStop)
                        || (restartBoundary == "after-ready" && point == .completionBeforeJournalWrite(.restarting))
                    if matches {
                        try Data("ready".utf8).write(to: URL(fileURLWithPath: state + "/daemon-ready"))
                        while true { Darwin.pause() }
                    }
                }
                let restart = try manager.restart(id: "dev", operationID: Self.restartFixtureOperationID)
                try sendVmmHandoff(
                    path: try #require(restart.handoffSocketPath),
                    ready: .init(
                        machineID: "dev", operationID: restart.activeOperationID,
                        controlSocketPath: try authenticatedControlSocket(state: state),
                        graphicsSelection: try graphicsSelection(plan: plans.read(id: "dev"), operationID: try #require(restart.activeOperationID))
                    ), fileDescriptors: []
                )
                while true { Darwin.pause() }
            }
            try Data("ready".utf8).write(to: URL(fileURLWithPath: state + "/daemon-ready"))
            while true { Darwin.pause() }
        }
    }

    @Test("prepublication application retirement retains resolved launch authority")
    func prepublicationApplicationRetirementRetainsResolvedAuthority() throws {
        let application = ControlledApplicationTerminationController()
        let stopper = ControlledMachineProcessStopper()
        let starter = CountingProcessStarter { process in
            process.installPrepublicationTerminalRetirement(
                application: application,
                retryDelay: 0.01
            )
            throw ResolvedLaunchLifecycleFixtureError.prepublicationFailure
        }
        try withHarness(
            "prepublication-retirement",
            useShortStatePath: true,
            starter: starter,
            processStopper: stopper.stop(_:)
        ) { manager, starter, _ in
            try installExactRawHVInfrastructure(manager)

            #expect(throws: (any Error).self) {
                _ = try manager.start(id: "dev")
            }
            let retained = try #require(manager.failedRuntimeAuthoritySnapshot(id: "dev"))
            #expect(retained.hasProcess)
            #expect(retained.processIsRunning)
            #expect(retained.hasResolvedAdmissionAuthority)
            #expect(retained.backend == .doryHypervisor)
            #expect(manager.status(id: "dev")?.state == .failed)

            #expect(throws: (any Error).self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 1)

            application.confirmTermination()
            let retirementDeadline = Date().addingTimeInterval(2)
            while Date() < retirementDeadline,
                  manager.failedRuntimeAuthoritySnapshot(id: "dev")?.hasProcess == true {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let retired = try #require(manager.failedRuntimeAuthoritySnapshot(id: "dev"))
            #expect(!retired.hasProcess)
            #expect(!retired.processIsRunning)
            #expect(!retired.hasResolvedAdmissionAuthority)
            #expect(retired.backend == nil)
        }
    }

    @Test("readiness rejection cannot release a live helper's resolved authority")
    func readinessRejectionRetainsResolvedAuthorityUntilExactExit() throws {
        let stopper = ControlledMachineProcessStopper()
        try withHarness(
            "readiness-retirement",
            requiresReadyHandoff: true,
            useShortStatePath: true,
            processStopper: stopper.stop(_:)
        ) { manager, starter, _ in
            try installExactRawHVInfrastructure(manager)

            let starting = try manager.start(id: "dev")
            try sendVmmHandoff(
                path: try #require(starting.handoffSocketPath),
                ready: VmmReadyMessage(
                    machineID: "dev",
                    operationID: UUID().uuidString.lowercased(),
                    agentBuild: "dory-agent/rejected-operation",
                    controlSocketPath: "/run/dory-control.sock"
                ),
                fileDescriptors: []
            )
            let rejectionDeadline = Date().addingTimeInterval(2)
            while Date() < rejectionDeadline,
                  manager.status(id: "dev")?.state != .failed {
                Thread.sleep(forTimeInterval: 0.01)
            }

            let retained = try #require(manager.failedRuntimeAuthoritySnapshot(id: "dev"))
            #expect(retained.hasProcess)
            #expect(retained.processIsRunning)
            #expect(retained.hasResolvedAdmissionAuthority)
            #expect(retained.backend == .doryHypervisor)
            #expect(manager.status(id: "dev")?.state == .failed)

            #expect(throws: (any Error).self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 1)

            stopper.allowTermination()
            let stopped = try manager.stop(id: "dev")
            #expect(stopped.state == .stopped)
            let released = try #require(manager.failedRuntimeAuthoritySnapshot(id: "dev"))
            #expect(!released.hasProcess)
            #expect(!released.hasResolvedAdmissionAuthority)
            #expect(released.backend == nil)
        }
    }

    @Test("resolved installed-Linux launch never materializes legacy boot paths")
    func resolvedInstalledLinuxUsesOnlyDescriptorBootAuthority() throws {
        let root = try makeState("resolved-installed-linux")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sourceBundle = root + "/source.boot"
        let sourceDisk = root + "/source.raw"
        let kernel = Data(repeating: 0x41, count: 8_192)
        let initrd = Data(repeating: 0x42, count: 16_384)
        try DoryInstalledLinuxBootBundle.write(
            assets: DoryLinuxInstallerBootAssets(
                kernel: kernel,
                initrd: initrd,
                kernelISOPath: "casper/vmlinuz",
                initrdISOPath: "casper/initrd"
            ),
            rootDevice: "/dev/vda2",
            toPath: sourceBundle
        )
        try Data(repeating: 0x31, count: 4_096).write(
            to: URL(fileURLWithPath: sourceDisk)
        )
        let starter = CountingProcessStarter()
        let managedState = root + "/machines"
        try FileManager.default.createDirectory(
            atPath: managedState,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(managedState, mode_t(0o700))
        let stateBroker = try DoryMachineStateBroker(
            canonicalStateRootPath: managedState
        )
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sh",
                acceleratedDesktopExecutablePath: "/bin/sh",
                stateDirectory: managedState,
                baseArguments: ["-c", "exec /bin/sleep 30", "dory-test-runtime"],
                acceleratedDesktopBaseArguments: [
                    "-c", "exec /bin/sleep 30", "dory-test-runtime",
                ],
                passMachineArguments: true,
                requiresReadyHandoff: false
            ),
            launchPolicy: .requireResolvedPlan,
            machineStateBroker: stateBroker,
            processStarter: { process in try starter.start(process) }
        )
        defer {
            _ = try? manager.stop(id: "installed")
            _ = try? manager.delete(id: "installed")
        }
        _ = try manager.stageMachineForBootstrap(DoryMachineConfiguration(
            id: "installed",
            kernelPath: sourceBundle,
            rootfsPath: sourceDisk,
            bootMode: .efi,
            memoryMB: 4_096,
            cpuCount: 4,
            displayMode: .desktop
        ))
        let state = root + "/machines/installed"
        let directKernel = state + "/direct-kernel"
        let directInitrd = state + "/direct-initrd"
        let plans = MutablePlanStore()
        let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
        let registry = try rawRegistry(operations: operations)
        let resolver = ClosureLaunchResolver { request in
            let resolution = try exactResolution(
                request: request,
                bootArtifactSHA256: try fileSHA256(path: sourceBundle),
                preSpawnRevalidation: {
                    guard !FileManager.default.fileExists(atPath: directKernel),
                          !FileManager.default.fileExists(atPath: directInitrd) else {
                        throw MachineManagerError.persistence(
                            "resolved preparation materialized legacy boot paths"
                        )
                    }
                }
            )
            plans.set(resolution.resolvedPlan)
            return resolution
        }
        try manager.installResolvedLaunchInfrastructure(
            registry: registry,
            resolver: resolver,
            plans: plans,
            expectedPlanRevision: { _ in 1 }
        )

        _ = try manager.start(id: "installed")
        #expect(starter.count == 1)
        #expect(!FileManager.default.fileExists(atPath: directKernel))
        #expect(!FileManager.default.fileExists(atPath: directInitrd))
    }

    @Test("resolved snapshot disk capacity is bound to resource admission")
    func resolvedSnapshotRejectsSelfConsistentDifferentCapacityDisk() throws {
        try withHarness("snapshot-storage-evidence") { manager, _, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )
            _ = try manager.start(id: "dev")
            _ = try manager.stop(id: "dev")
            var snapshot = try manager.snapshot(id: "dev", snapshotID: "capacity")

            let rootfsURL = URL(fileURLWithPath: snapshot.rootfsPath)
            let handle = try FileHandle(forWritingTo: rootfsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
            let rootfsData = try Data(contentsOf: rootfsURL)
            let rootfsSHA256 = SHA256.hash(data: rootfsData)
                .map { String(format: "%02x", $0) }.joined()
            snapshot.sizeBytes = Int64(rootfsData.count)
            snapshot.artifactEvidence?.rootfs = DoryMachineSnapshotArtifact(
                byteCount: UInt64(rootfsData.count),
                sha256: rootfsSHA256
            )

            let metadataPath = state + "/dev/snapshots/capacity.json"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(
                to: URL(fileURLWithPath: metadataPath),
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: metadataPath
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.restoreSnapshot(machineID: "dev", snapshotID: "capacity")
            }
        }
    }

    @Test("daemon restart recovers exact plan identity and definition changes invalidate it")
    func restartRecoveryAndConfigurationInvalidation() throws {
        try withHarness("restart-recovery") { manager, _, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )
            _ = try manager.start(id: "dev")
            _ = try manager.stop(id: "dev")

            let restarted = MachineManager(
                configuration: MachineManagerConfiguration(
                    vmmExecutablePath: "/bin/sh",
                    acceleratedDesktopExecutablePath: "/bin/sh",
                    stateDirectory: state,
                    baseArguments: ["-c", "exec /bin/sleep 30", "dory-test-runtime"],
                    acceleratedDesktopBaseArguments: [
                        "-c", "exec /bin/sleep 30", "dory-test-runtime",
                    ],
                    passMachineArguments: true,
                    requiresReadyHandoff: false
                ),
                launchPolicy: .requireResolvedPlan
            )
            #expect(restarted.status(id: "dev")?.runtimeIdentity.mode == .requiresReplanning)
            let restartedOperations = restarted.resolvedLaunchCompatibilityOperations(
                for: .doryHypervisor
            )
            try restarted.installResolvedLaunchInfrastructure(
                registry: rawRegistry(operations: restartedOperations),
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )
            #expect(restarted.status(id: "dev")?.runtimeIdentity.mode == .resolvedPlan)
            let updated = try restarted.update(id: "dev", memoryMB: 4_096)
            #expect(updated.runtimeIdentity.mode == .requiresReplanning)
            #expect(updated.runtimeIdentity.invalidationReason == .definitionChanged)
        }
    }

    @Test("missing stale tampered and rejected plans never reach process starter")
    func rejectedPlansFailBeforeSpawn() throws {
        enum Scenario: CaseIterable {
            case missing
            case staleDefinition
            case tamperedDigest
            case rejectedEvidence
            case adapterPlanMismatch
        }

        for scenario in Scenario.allCases {
            try withHarness("reject-\(scenario)") { manager, starter, _ in
                let plans = MutablePlanStore()
                let operations = manager.resolvedLaunchCompatibilityOperations(
                    for: .doryHypervisor
                )
                let registry = try rawRegistry(operations: operations)
                let resolver = ClosureLaunchResolver { request in
                    switch scenario {
                    case .missing:
                        throw DoryDaemonVirtualMachineLaunchPlanFailure(
                            code: .planNotFound,
                            message: "fixture missing plan"
                        )
                    case .staleDefinition:
                        var resolution = try exactResolution(request: request)
                        resolution.resolvedPlan.definitionRevision += 1
                        resolution.resolvedPlanSHA256 = try planSHA256(
                            resolution.resolvedPlan
                        )
                        return resolution
                    case .tamperedDigest:
                        var resolution = try exactResolution(request: request)
                        resolution.resolvedPlanSHA256 = digest("9")
                        return resolution
                    case .rejectedEvidence:
                        var resolution = try exactResolution(request: request)
                        resolution.revalidation = DoryResolvedMachinePlanRevalidationResult(
                            state: .rejected,
                            issues: [DoryResolvedMachinePlanRevalidationIssue(
                                code: .componentEvidenceMismatch,
                                field: "components"
                            )]
                        )
                        return resolution
                    case .adapterPlanMismatch:
                        var resolution = try exactResolution(request: request)
                        resolution.backendPlan.machine.memoryMB += 1_024
                        return resolution
                    }
                }
                try manager.installResolvedLaunchInfrastructure(
                    registry: registry,
                    resolver: resolver,
                    plans: plans,
                    expectedPlanRevision: { _ in 1 }
                )

                #expect(throws: MachineManagerError.self) {
                    _ = try manager.start(id: "dev")
                }
                #expect(starter.count == 0)
                #expect(manager.status(id: "dev")?.state == .created)
                #expect(manager.resolvedLaunchIdentity(id: "dev") == nil)
            }
        }
    }

    @Test("restart preflight rejection preserves the live source and durable metadata", arguments: [
        "missing-plan", "missing-revision", "stale-definition", "tampered-digest",
        "rejected-evidence", "adapter-mismatch", "missing-authorization", "rejected-authorization",
        "changed-plan", "missing-artifact", "stale-projection", "changed-metadata",
    ], [false, true])
    func rejectedRestartPreservesSource(scenario: String, paused: Bool) throws {
        try withHarness("restart-preflight-\(scenario)") { manager, starter, state in
            let plans = MutablePlanStore()
            let baseline = MutablePlanStore()
            let resolver = ClosureLaunchResolver { request in
                var resolution = try exactResolution(request: request)
                guard (try? baseline.read(id: "dev")) != nil else {
                    baseline.set(resolution.resolvedPlan)
                    plans.set(resolution.resolvedPlan)
                    return resolution
                }
                switch scenario {
                case "missing-plan":
                    throw DoryDaemonVirtualMachineLaunchPlanFailure(code: .planNotFound, message: "missing restart plan")
                case "stale-definition":
                    resolution.resolvedPlan.definitionRevision += 1
                    resolution.resolvedPlanSHA256 = try planSHA256(resolution.resolvedPlan)
                case "tampered-digest":
                    resolution.resolvedPlanSHA256 = digest("9")
                case "rejected-evidence":
                    resolution.revalidation = .init(state: .rejected, issues: [
                        .init(code: .componentEvidenceMismatch, field: "components"),
                    ])
                case "adapter-mismatch":
                    resolution.backendPlan.machine.memoryMB += 1_024
                case "missing-authorization":
                    resolution.preSpawnAuthorization = nil
                case "rejected-authorization":
                    resolution.preSpawnAuthorization = .init(purpose: request.purpose, revalidate: {
                        throw DoryDaemonVirtualMachinePreSpawnAuthorizationError.revalidationFailed
                    })
                case "changed-plan":
                    resolution.resolvedPlan.createdAtUnixMilliseconds += 1
                    resolution.resolvedPlanSHA256 = try planSHA256(resolution.resolvedPlan)
                    plans.set(resolution.resolvedPlan)
                default:
                    break
                }
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: try rawRegistry(operations: manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)),
                resolver: resolver, plans: plans,
                expectedPlanRevision: { _ in
                    scenario == "missing-revision" && (try? baseline.read(id: "dev")) != nil ? nil : 1
                }
            )
            _ = try manager.start(id: "dev")
            if paused { _ = try manager.pause(id: "dev") }
            let before = try #require(manager.status(id: "dev"))
            let pid = try #require(before.pid)
            let workspacePath = state + "/dev/" + DoryWorkspaceRepository.recordFileName
            switch scenario {
            case "missing-artifact":
                try FileManager.default.moveItem(atPath: state + "/dev/kernel", toPath: state + "/dev/kernel-retained")
            case "stale-projection":
                try Data("invalid workspace projection".utf8).write(to: URL(fileURLWithPath: workspacePath))
            case "changed-metadata":
                let path = state + "/dev/machine.json"
                var machine = try JSONDecoder().decode(DoryMachineConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                machine.memoryMB += 1_024
                try DoryMachineConfigurationMigrationBridge.encodeLegacy(machine).write(to: URL(fileURLWithPath: path))
            default:
                break
            }
            let metadata = try restartAuthoritySnapshot(state: state)
            let operationID = UUID()
            #expect(throws: (any Error).self) { _ = try manager.restart(id: "dev", operationID: operationID) }
            let after = try #require(manager.status(id: "dev"))
            #expect(after.state == before.state)
            #expect(after.pid == pid)
            #expect(kill(pid, 0) == 0)
            #expect(after.runtimeIdentity == before.runtimeIdentity)
            #expect(after.readiness == before.readiness)
            #expect(after.activeOperationID == nil)
            #expect(starter.count == 1)
            let afterFiles = try restartAuthoritySnapshot(state: state)
            let changedFiles = Set(afterFiles.keys).union(metadata.keys).filter { afterFiles[$0] != metadata[$0] }.sorted()
            #expect(afterFiles == metadata, Comment(rawValue: "Changed files: \(changedFiles.joined(separator: ", "))"))
            let journals = try DoryOperationJournalStore(home: state + "/.lifecycle-journal").list()
            #expect(!journals.contains { $0.plan.id == operationID || $0.plan.kind == .workspaceRestart })
        }
    }

    @Test("late resolved preflight cannot recreate a removed workspace projection", arguments: [false, true])
    func latePreflightDoesNotReconcile(restarting: Bool) throws {
        try withHarness("late-preflight-projection") { manager, starter, state in
            let plans = MutablePlanStore()
            let workspacePath = state + "/dev/" + DoryWorkspaceRepository.recordFileName
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                let removeProjection = !restarting || (try? plans.read(id: "dev")) != nil
                plans.set(resolution.resolvedPlan)
                if removeProjection { try FileManager.default.removeItem(atPath: workspacePath) }
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: try rawRegistry(operations: manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)),
                resolver: resolver, plans: plans, expectedPlanRevision: { _ in 1 }
            )
            if restarting { _ = try manager.start(id: "dev") }
            let before = try #require(manager.status(id: "dev"))
            #expect(throws: MachineManagerError.self) {
                if restarting { _ = try manager.restart(id: "dev") }
                else { _ = try manager.start(id: "dev") }
            }
            #expect(!FileManager.default.fileExists(atPath: workspacePath))
            #expect(manager.status(id: "dev")?.state == before.state)
            #expect(manager.status(id: "dev")?.pid == before.pid)
            #expect(starter.count == (restarting ? 1 : 0))
        }
    }

    @Test("restart rechecks media authority after stopping the source")
    func restartRevalidatesAfterStop() throws {
        try withHarness("restart-preflight-stop-boundary") { manager, starter, state in
            let plans = MutablePlanStore()
            let media = state + "/resolved-media"
            let original = Data("qualified media".utf8)
            try original.write(to: URL(fileURLWithPath: media))
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request, preSpawnRevalidation: {
                    guard try Data(contentsOf: URL(fileURLWithPath: media)) == original else {
                        throw DoryDaemonVirtualMachinePreSpawnAuthorizationError.revalidationFailed
                    }
                })
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: try rawRegistry(operations: manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)),
                resolver: resolver, plans: plans, expectedPlanRevision: { _ in 1 }
            )
            let running = try manager.start(id: "dev")
            let pid = try #require(running.pid)
            manager.installLifecycleFaultInjectorForTesting { point in
                if point == .stopAfterProcessStop {
                    try Data("changed while stopping".utf8).write(to: URL(fileURLWithPath: media))
                }
            }
            defer { manager.installLifecycleFaultInjectorForTesting { _ in } }
            let operationID = UUID()
            #expect(throws: MachineManagerError.self) { _ = try manager.restart(id: "dev", operationID: operationID) }
            #expect(starter.count == 1)
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
            #expect(manager.status(id: "dev")?.pid == nil)
            #expect(manager.status(id: "dev")?.activeOperationID == nil)
            let journals = try DoryOperationJournalStore(home: state + "/.lifecycle-journal").list()
            let restart = try #require(journals.first { $0.plan.id == operationID })
            #expect(restart.plan.kind == .workspaceRestart)
            #expect(restart.state.status == .failed)
            #expect(journals.filter { $0.plan.kind == .workspaceStart }.count == 1)
            #expect(!journals.contains { $0.plan.kind == .workspaceStop })
        }
    }

    private func restartAuthoritySnapshot(state: String) throws -> [String: String] {
        var snapshot: [String: String] = [:]
        for relative in FileManager.default.enumerator(atPath: state)?.allObjects as? [String] ?? [] {
            guard !relative.hasSuffix(".log") else { continue }
            let path = state + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            snapshot[relative] = "\(info.st_ino):\(info.st_mode):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(try fileSHA256(path: path))"
        }
        return snapshot
    }

    @Test("machine metadata mutation during evidence collection is rejected before spawn")
    func authorityTOCTOUIsRejected() throws {
        try withHarness("authority-toctou") { manager, starter, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                var changed = request.machine
                changed.memoryMB += 1_024
                let path = state + "/dev/machine.json"
                try DoryMachineConfigurationMigrationBridge.encodeLegacy(changed).write(
                    to: URL(fileURLWithPath: path),
                    options: .atomic
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: path
                )
                return try exactResolution(request: request)
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
            #expect(manager.status(id: "dev")?.state == .created)
        }
    }

    @Test("missing pinned plan revision fails without invoking resolver or process")
    func missingPinnedRevisionFailsClosed() throws {
        try withHarness("missing-revision") { manager, starter, _ in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                try exactResolution(request: request)
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in nil }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(resolver.callCount == 0)
            #expect(starter.count == 0)
        }
    }

    @Test("resolved plan replacement during evidence collection is rejected before spawn")
    func planAuthorityTOCTOUIsRejected() throws {
        try withHarness("plan-toctou") { manager, starter, _ in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                var replacement = resolution.resolvedPlan
                replacement.planRevision += 1
                replacement.updatedAtUnixMilliseconds += 1
                plans.set(replacement)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
            #expect(manager.status(id: "dev")?.state == .created)
        }
    }

    @Test("same-path runtime replacement is rejected before process starter")
    func swappedRuntimeArtifactIsRejected() throws {
        try withHarness("runtime-swap") { manager, starter, state in
            let runtimePath = state + "/adapter-runtime"
            try writeExecutable("#!/bin/sh\nexec /bin/sleep \"$@\"\n", path: runtimePath)
            let qualifiedSHA256 = try fileSHA256(path: runtimePath)
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(
                operations: operations,
                executablePath: runtimePath
            )
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(
                    request: request,
                    componentSHA256: qualifiedSHA256
                )
                plans.set(resolution.resolvedPlan)
                try writeExecutable("#!/bin/sh\nexit 0\n", path: runtimePath)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
        }
    }

    @Test("final media mutation is rejected by single-use authorization before process starter")
    func preSpawnArtifactMutationIsRejected() throws {
        try withHarness("pre-spawn-media-mutation") { manager, starter, state in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(
                for: .doryHypervisor
            )
            let registry = try rawRegistry(operations: operations)
            let resolver = ClosureLaunchResolver { request in
                let mediaPath = state + "/resolved-media"
                try Data("qualified-media".utf8).write(
                    to: URL(fileURLWithPath: mediaPath),
                    options: .atomic
                )
                let expectedSHA256 = SHA256.hash(
                    data: try Data(contentsOf: URL(fileURLWithPath: mediaPath))
                ).map { String(format: "%02x", $0) }.joined()
                let resolution = try exactResolution(
                    request: request,
                    preSpawnRevalidation: {
                        let current = try Data(contentsOf: URL(fileURLWithPath: mediaPath))
                        let currentSHA256 = SHA256.hash(data: current)
                            .map { String(format: "%02x", $0) }.joined()
                        guard currentSHA256 == expectedSHA256 else {
                            throw DoryDaemonVirtualMachinePreSpawnAuthorizationError
                                .revalidationFailed
                        }
                    }
                )
                plans.set(resolution.resolvedPlan)
                try Data("mutated-after-evidence".utf8).write(
                    to: URL(fileURLWithPath: mediaPath),
                    options: .atomic
                )
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
            #expect(manager.status(id: "dev")?.state == .created)
        }
    }

    @Test("required resolved launch rejects a missing pre-spawn authorization")
    func missingPreSpawnAuthorizationFailsClosed() throws {
        try withHarness("missing-pre-spawn") { manager, starter, _ in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(
                for: .doryHypervisor
            )
            let resolver = ClosureLaunchResolver { request in
                var resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                resolution.preSpawnAuthorization = nil
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: try rawRegistry(operations: operations),
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
        }
    }

    @Test("resolved DoryARMVirt-v1 cannot omit the immutable helper envelope")
    func resolvedLaunchRejectsOmittedMachineArguments() throws {
        try withHarness(
            "missing-envelope",
            passMachineArguments: false
        ) { manager, starter, _ in
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(request: request)
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: try rawRegistry(operations: operations),
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
        }
    }

    @Test("adapter-issued executable is launched instead of manager backend lookup")
    func adapterExecutableBindingIsUsed() throws {
        try withHarness(
            "adapter-binding",
            acceleratedExecutablePath: nil
        ) { manager, starter, state in
            let runtimePath = state + "/adapter-runtime"
            try writeExecutable("#!/bin/sh\nexec /bin/sleep 30\n", path: runtimePath)
            let plans = MutablePlanStore()
            let operations = manager.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
            let registry = try rawRegistry(
                operations: operations,
                executablePath: runtimePath
            )
            let resolver = ClosureLaunchResolver { request in
                let resolution = try exactResolution(
                    request: request,
                    componentSHA256: try fileSHA256(path: runtimePath)
                )
                plans.set(resolution.resolvedPlan)
                return resolution
            }
            try manager.installResolvedLaunchInfrastructure(
                registry: registry,
                resolver: resolver,
                plans: plans,
                expectedPlanRevision: { _ in 1 }
            )

            let status = try manager.start(id: "dev")
            #expect(status.state == .running)
            #expect(starter.count == 1)
        }
    }

    @Test("launch policy explicitly gates compatibility and resolved starts")
    func launchPolicyIsExplicit() throws {
        try withHarness("required-no-infra") { manager, starter, _ in
            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
        }
        try withHarness("legacy", launchPolicy: .legacyCompatibility) {
            manager, starter, _ in
            let status = try manager.start(id: "dev")
            #expect(status.state == .running)
            #expect(starter.count == 1)
        }
    }

    @Test("per-workspace policy blocks new machines until planning")
    func perWorkspaceNewMachineRequiresPlanning() throws {
        try withHarness("per-workspace-new", launchPolicy: .perWorkspaceAuthority) {
            manager, starter, _ in
            let status = try #require(manager.status(id: "dev"))
            #expect(status.runtimeIdentity.mode == .requiresReplanning)
            #expect(status.runtimeIdentity.invalidationReason == .planNotInstalled)
            #expect(throws: MachineManagerError.self) {
                _ = try manager.start(id: "dev")
            }
            #expect(starter.count == 0)
        }
    }

    @Test("diagnostic native settings preserve budgets through staged replacement and reload", arguments: [
        DoryDesktopGraphicsPreference.virgl, .software,
    ])
    func nativeTypedSettingsAreWorkspaceAuthority(graphics: DoryOperations.DoryDesktopGraphicsPreference) throws {
        let state = try makeState("native-typed-settings")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let manager = makeManager(state: state, policy: .perWorkspaceAuthority)
        let created = try manager.stageMachineForBootstrap(
            DoryMachineConfiguration(
                id: "typed",
                kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath,
                memoryMB: 2_048,
                cpuCount: 2,
                displayMode: .desktop
            ),
            typedSettings: DoryMachineTypedSettingsPatch(
                guestUsername: .set("developer"),
                guestNumericUserID: .set(1_000),
                desktopDistributionIdentifier: .set("ubuntu"),
                desktopDisplayName: .set("Ubuntu"),
                clipboardPolicy: .set(DoryVMClipboardPolicy(
                    text: .bidirectional,
                    image: .bidirectional,
                    files: .bidirectional
                )),
                runtimePreference: .set(.accelerated),
                graphicsPreference: .set(graphics),
                networkMode: .set(.isolated),
                portForwards: .set([
                    DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
                ]),
                cameraEnabled: .set(true)
            )
        )
        #expect(created.environment.isEmpty)
        #expect(created.typedSettings?.guestIdentityIntent.account?.username == "developer")
        #expect(created.typedSettings?.runtimePreference == .accelerated)
        #expect(created.typedSettings?.clipboardPolicy?.files == .bidirectional)
        #expect(created.typedSettings?.portForwards == [
            DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
        ])

        let machineData = try Data(contentsOf: URL(
            fileURLWithPath: state + "/typed/machine.json"
        ))
        let persistedMachine = try JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: machineData
        )
        #expect(persistedMachine.environment.isEmpty)
        let repository = DoryWorkspaceRepository(root: state)
        let createdRecord = try repository.readPersistedRecord(id: "typed")
        #expect(createdRecord.legacyConfigurationSHA256 == nil)
        #expect(createdRecord.legacyMigrationFactsSHA256 == nil)
        #expect(createdRecord.definition.guestIdentityIntent.account?.username == "developer")
        #expect(createdRecord.definition.platform == .arm64LinuxV1)
        #expect(createdRecord.definition.boot.devices.first?.kind == .linuxKernel)
        let expectedGraphics: DoryGraphicsAccelerationLevel = graphics == .software
            ? .software : .hostAcceleratedDisplay
        #expect(created.typedSettings?.graphicsPreference == graphics)
        #expect(createdRecord.definition.graphics.acceptableLevels == [expectedGraphics])
        #expect(createdRecord.definition.networkMode == .isolated)
        #expect(createdRecord.definition.resources == DoryVMProductionResourceBudget.make(for: createdRecord.definition))
        if graphics == .software {
            #expect(createdRecord.definition.resources.rendererBytes == 1_920 * 1_080 * 4 * 3)
            #expect(createdRecord.definition.resources.workerOverheadBytes == 0)
        }
        #expect(createdRecord.definition.portForwards == [
            DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
        ])
        // This fixture stages desired graphics/device intent without runtime qualification.
        // Exercise the typed persistence boundary directly; public lifecycle tests use the
        // separately activated signed production fixture for admissible machine definitions.
        #expect(try DoryMachineTypedSettingsPatch().applying(
            to: createdRecord.definition, displayMode: .desktop) == createdRecord.definition)
        let snapshot = try DoryMachineTypedSettingsSnapshot(definition: createdRecord.definition)
        #expect(snapshot == created.typedSettings)
        var updatedDefinition = try DoryMachineTypedSettingsPatch(
            guestUsername: .set("builder"),
            desktopDisplayName: .set("Ubuntu Builder"),
            graphicsPreference: .set(.virglVenus)
        ).applying(to: createdRecord.definition, displayMode: .desktop)
        updatedDefinition.lifecycle.revision += 1
        updatedDefinition.lifecycle.updatedAtUnixMilliseconds += 1
        try repository.replace(updatedDefinition, expectedRevision: createdRecord.definition.lifecycle.revision)
        let updatedManager = makeManager(state: state, policy: .perWorkspaceAuthority)
        let updated = try #require(updatedManager.status(id: "typed"))
        #expect(updated.environment.isEmpty)
        #expect(updated.typedSettings?.guestIdentityIntent.account?.username == "builder")
        #expect(updated.typedSettings?.guestIdentityIntent.account?.numericUserID == 1_000)
        #expect(updated.typedSettings?.graphicsPreference == .virglVenus)
        let updatedRecord = try repository.readPersistedRecord(id: "typed")
        #expect(updatedRecord.definition.lifecycle.revision == 2)
        #expect(updatedRecord.definition.guestIdentityIntent.desktop?.displayName
            == "Ubuntu Builder")
        #expect(updatedRecord.definition.guestIdentityIntent.desktop?.distributionIdentifier
            == "ubuntu")
        #expect(updatedRecord.definition.graphics.acceptableLevels == [.hardwareAccelerated3D])
        #expect(updatedRecord.definition.portForwards == createdRecord.definition.portForwards)
        #expect(updatedRecord.definition.networkMode == createdRecord.definition.networkMode)
        #expect(updatedRecord.definition.camera == createdRecord.definition.camera)
        #expect(updatedRecord.definition.resources.rendererBytes == DoryVMProductionResourceBudget.isolatedRendererScanoutBytes)
        #expect(updatedRecord.definition.resources.workerOverheadBytes == DoryVMProductionResourceBudget.rendererWorkerOverheadBytes)
        #expect(try DoryMachineTypedSettingsPatch().applying(
            to: updatedRecord.definition, displayMode: .desktop) == updatedRecord.definition)
        #expect(try repository.readPersistedRecord(id: "typed").definition.lifecycle.revision == 2)

        let clone = try manager.stageMachineForBootstrap(
            DoryMachineConfiguration(id: "typed-clone", kernelPath: persistedMachine.kernelPath,
                rootfsPath: persistedMachine.rootfsPath, memoryMB: 2_048, cpuCount: 2, displayMode: .desktop),
            typedSettings: snapshot.replacementPatch
        )
        #expect(clone.environment.isEmpty)
        #expect(clone.typedSettings == created.typedSettings)
        let cloneRecord = try repository.readPersistedRecord(id: "typed-clone")
        #expect(cloneRecord.legacyConfigurationSHA256 == nil)
        #expect(cloneRecord.definition.guestIdentityIntent.account?.username == "developer")
        #expect(cloneRecord.definition.resources == createdRecord.definition.resources)
        #expect(cloneRecord.definition.portForwards == createdRecord.definition.portForwards)
        #expect(cloneRecord.definition.camera == createdRecord.definition.camera)

        var encodedSnapshot = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(snapshot)) as? [String: Any])
        encodedSnapshot["environment"] = ["SHOULD_NOT_PERSIST": "opaque-secret"]
        let decodedSnapshot = try JSONDecoder().decode(DoryMachineTypedSettingsSnapshot.self,
            from: JSONSerialization.data(withJSONObject: encodedSnapshot))
        #expect(decodedSnapshot == snapshot)
        var restoredDefinition = try decodedSnapshot.applyingAsReplacement(
            to: updatedRecord.definition, displayMode: .desktop)
        restoredDefinition.lifecycle.revision += 1
        restoredDefinition.lifecycle.updatedAtUnixMilliseconds += 1
        try repository.replace(restoredDefinition, expectedRevision: updatedRecord.definition.lifecycle.revision)
        let restoredManager = makeManager(state: state, policy: .perWorkspaceAuthority)
        let restored = try #require(restoredManager.status(id: "typed"))
        #expect(restored.environment.isEmpty)
        #expect(restored.typedSettings == created.typedSettings)
        #expect(restored.runtimeIdentity.mode == .requiresReplanning)
        let restoredRecord = try repository.readPersistedRecord(id: "typed")
        #expect(restoredRecord.definition.lifecycle.revision == 3)
        #expect(restoredRecord.definition.guestIdentityIntent.account?.username == "developer")
        #expect(restoredRecord.definition.graphics.acceptableLevels == [expectedGraphics])
        #expect(restoredRecord.definition.resources == createdRecord.definition.resources)
        #expect(restoredRecord.definition.portForwards == createdRecord.definition.portForwards)
        #expect(restoredRecord.definition.camera == createdRecord.definition.camera)

        #expect(try Data(contentsOf: URL(fileURLWithPath: state + "/typed/machine.json")) == machineData)
        let restarted = makeManager(state: state, policy: .perWorkspaceAuthority)
        let restartedStatus = try #require(restarted.status(id: "typed"))
        #expect(restartedStatus.environment.isEmpty)
        #expect(restartedStatus.typedSettings == created.typedSettings)
        #expect(restartedStatus.runtimeIdentity.mode == .requiresReplanning)
    }

    @Test("native direct-kernel records upgrade the historical bundle alias exactly once")
    func nativeDirectKernelAliasMigrates() throws {
        let state = try makeState("native-kernel-media-upgrade")
        defer { try? FileManager.default.removeItem(atPath: state) }
        do {
            let manager = makeManager(state: state, policy: .perWorkspaceAuthority)
            _ = try createMachine(id: "native", manager: manager)
        }

        let repository = DoryWorkspaceRepository(root: state)
        let current = try repository.readPersistedRecord(id: "native").definition
        #expect(current.boot.devices.first?.kind == .linuxKernel)
        var historicalAlias = current
        historicalAlias.boot.devices[0].kind = .installedLinuxBootBundle
        historicalAlias.lifecycle = DoryVMLifecycleMetadata(
            revision: current.lifecycle.revision + 1,
            createdAtUnixMilliseconds: current.lifecycle.createdAtUnixMilliseconds,
            updatedAtUnixMilliseconds: current.lifecycle.updatedAtUnixMilliseconds + 1
        )
        try repository.replace(
            historicalAlias,
            expectedRevision: current.lifecycle.revision
        )

        let machineBytes = try Data(contentsOf: URL(
            fileURLWithPath: state + "/native/machine.json"
        ))
        let restarted = makeManager(state: state, policy: .perWorkspaceAuthority)
        let status = try #require(restarted.status(id: "native"))
        #expect(status.runtimeIdentity.mode == .requiresReplanning)
        let upgraded = try repository.readPersistedRecord(id: "native").definition
        #expect(upgraded.boot.devices.first?.kind == .linuxKernel)
        #expect(upgraded.lifecycle.revision == historicalAlias.lifecycle.revision + 1)
        #expect(try Data(contentsOf: URL(
            fileURLWithPath: state + "/native/machine.json"
        )) == machineBytes)
    }

    @Test("native creation authority is durable before machine metadata becomes discoverable")
    func nativeCreationCrashOrderingNeverMintsLegacy() throws {
        let state = try makeState("native-create-order")
        defer { try? FileManager.default.removeItem(atPath: state) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: state
        )
        let directory = state + "/native"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let rootfs = directory + "/rootfs.ext4"
        let kernel = directory + "/kernel"
        try FileManager.default.copyItem(atPath: doryTestRootfsPath, toPath: rootfs)
        try FileManager.default.copyItem(atPath: doryTestKernelPath, toPath: kernel)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: rootfs
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: kernel
        )
        let machine = DoryMachineConfiguration(
            id: "native",
            kernelPath: kernel,
            rootfsPath: rootfs,
            memoryMB: 2_048,
            cpuCount: 2,
            displayMode: .desktop
        )
        let legacyData = try DoryMachineConfigurationMigrationBridge.encodeLegacy(machine)
        let expected = DoryMachineRuntimeIdentity.requiresReplanning(
            virtualHardwareABIVersion: 1,
            reason: .planNotInstalled
        )
        let markerPath = directory + "/.dory-native-create-precommit-v1"
        try Data("DORY-NATIVE-CREATE-PRECOMMIT-V1:native\n".utf8).write(
            to: URL(fileURLWithPath: markerPath),
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerPath
        )
        let rootfsBytes = try #require(
            (try FileManager.default.attributesOfItem(atPath: rootfs)[.size] as? NSNumber)?
                .uint64Value
        )
        let interruptedDefinition = try DoryMachineConfigurationMigrationBridge.migrate(
            machine,
            facts: DoryMachineConfigurationMigrationFacts(
                guestArchitecture: .arm64,
                systemDiskCapacityBytes: rootfsBytes,
                lifecycle: DoryVMLifecycleMetadata(
                    createdAtUnixMilliseconds: 1,
                    updatedAtUnixMilliseconds: 1
                )
            )
        ).definition
        try DoryWorkspaceRepository(root: state).create(interruptedDefinition)
        try DoryMachineRuntimeIdentityStore(root: state).publish(
            expected,
            machineID: "native",
            authoritativeLegacyData: legacyData
        )
        let interruptedStoreTemporary = directory
            + "/.runtime-identity-v1.tmp-interrupted"
        try Data("partial".utf8).write(
            to: URL(fileURLWithPath: interruptedStoreTemporary),
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: interruptedStoreTemporary
        )

        // Crash before machine.json publication: startup does not discover a machine at all.
        let recovered = makeManager(
            state: state,
            policy: .perWorkspaceAuthority
        )
        #expect(recovered.status(id: "native") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory))
        let retried = try createMachine(id: "native", manager: recovered)
        #expect(retried.runtimeIdentity == expected)

        let completedRootfs = state + "/native/rootfs.ext4"
        let completedKernel = state + "/native/kernel"
        let committedMarker = state
            + "/native/.dory-native-create-committed-v1"
        let preparingMarker = state
            + "/native/.dory-native-create-precommit-v1"
        #expect(FileManager.default.fileExists(atPath: committedMarker))
        // Simulate a crash after durable machine.json but before marker transition. Restart
        // completes the exact authority rather than deleting or widening it.
        try FileManager.default.moveItem(
            atPath: committedMarker,
            toPath: preparingMarker
        )
        let markerRecovered = makeManager(
            state: state,
            policy: .perWorkspaceAuthority
        )
        #expect(markerRecovered.status(id: "native")?.runtimeIdentity == expected)
        #expect(FileManager.default.fileExists(atPath: committedMarker))
        #expect(!FileManager.default.fileExists(atPath: preparingMarker))

        try FileManager.default.removeItem(atPath: state + "/native/machine.json")
        let metadataLost = makeManager(state: state, policy: .perWorkspaceAuthority)
        #expect(metadataLost.status(id: "native") == nil)
        #expect(FileManager.default.fileExists(atPath: completedRootfs))
        #expect(FileManager.default.fileExists(atPath: completedKernel))
        #expect(FileManager.default.fileExists(atPath: state + "/native"))
    }

    @Test("native creation recovers crashes before its durable marker is complete")
    func nativeCreationInitialMarkerCrashCanRetry() throws {
        for shape in ["empty-directory", "partial-marker"] {
            let state = try makeState("native-create-initial-\(shape)")
            defer { try? FileManager.default.removeItem(atPath: state) }
            let directory = state + "/native"
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            if shape == "partial-marker" {
                let marker = directory + "/.dory-native-create-precommit-v1"
                try Data("DORY-NATIVE-CREATE".utf8).write(
                    to: URL(fileURLWithPath: marker)
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: marker
                )
            }

            let recovered = makeManager(
                state: state,
                policy: .perWorkspaceAuthority
            )
            #expect(recovered.status(id: "native") == nil)
            #expect(!FileManager.default.fileExists(atPath: directory))
            let retried = try createMachine(id: "native", manager: recovered)
            #expect(retried.runtimeIdentity.mode == .requiresReplanning)
            #expect(retried.runtimeIdentity.invalidationReason == .planNotInstalled)
        }
    }

    @Test("legacy compatibility migration is exact-byte bound and cannot be widened")
    func perWorkspaceLegacyMigrationRejectsRawByteDrift() throws {
        let state = try makeState("legacy-byte-authority")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let legacy = makeManager(state: state, policy: .legacyCompatibility)
        _ = try createMachine(id: "legacy", manager: legacy)

        let migrated = makeManager(state: state, policy: .perWorkspaceAuthority)
        #expect(migrated.status(id: "legacy")?.runtimeIdentity.mode == .legacyCompatibility)
        let path = state + "/legacy/machine.json"
        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        bytes.append(0x0A)
        try bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )

        let changed = makeManager(state: state, policy: .perWorkspaceAuthority)
        #expect(changed.status(id: "legacy")?.runtimeIdentity.mode == .requiresReplanning)
        #expect(changed.status(id: "legacy")?.runtimeIdentity.invalidationReason == .planRecoveryFailed)
    }

    @Test("per-workspace launch requires production authority for legacy and persisted-plan identities")
    func perWorkspaceMixedAuthorityAndRestart() throws {
        let state = try makeState("per-workspace-mixed")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let legacyManager = makeManager(state: state, policy: .legacyCompatibility)
        _ = try createMachine(id: "legacy", manager: legacyManager)

        let firstPerWorkspace = makeManager(state: state, policy: .perWorkspaceAuthority)
        #expect(firstPerWorkspace.status(id: "legacy")?.runtimeIdentity.mode == .legacyCompatibility)
        _ = try createMachine(id: "planned", manager: firstPerWorkspace)
        #expect(firstPerWorkspace.status(id: "planned")?.runtimeIdentity.mode == .requiresReplanning)

        let plans = MutablePlanStore()
        let plannedIdentity = try persistResolvedIdentity(
            machineID: "planned",
            state: state,
            plans: plans
        )
        #expect(plannedIdentity.mode == .resolvedPlan)

        let starter = CountingProcessStarter()
        let restarted = makeManager(
            state: state,
            policy: .perWorkspaceAuthority,
            starter: starter
        )
        let operations = restarted.resolvedLaunchCompatibilityOperations(for: .doryHypervisor)
        let resolver = ClosureLaunchResolver { request in
            try exactResolution(request: request)
        }
        try restarted.installResolvedLaunchInfrastructure(
            registry: rawRegistry(operations: operations),
            resolver: resolver,
            plans: plans,
            expectedPlanRevision: { $0 == "planned" ? 1 : nil }
        )
        #expect(restarted.status(id: "legacy")?.runtimeIdentity.mode == .legacyCompatibility)
        #expect(restarted.status(id: "planned")?.runtimeIdentity == plannedIdentity)

        #expect(throws: MachineManagerError.self) {
            _ = try restarted.start(id: "legacy")
        }
        #expect(starter.count == 0)
        let identityPath = state + "/planned/" + DoryMachineRuntimeIdentityStore.recordFileName
        let originalIdentityData = try Data(contentsOf: URL(fileURLWithPath: identityPath))
        // A persisted plan and injected launch resolver cannot replace the production
        // planning controller that owns the caller's start transaction and admission.
        do {
            _ = try restarted.start(id: "planned")
            Issue.record("partial launch infrastructure authorized production start")
        } catch let error as MachineManagerError {
            #expect(String(describing: error).contains("production source authority"))
        }
        #expect(resolver.callCount == 0)
        #expect(starter.count == 0)
        #expect(restarted.status(id: "planned")?.runtimeIdentity == plannedIdentity)
        #expect(try Data(contentsOf: URL(fileURLWithPath: identityPath)) == originalIdentityData)

        let secondRestart = makeManager(state: state, policy: .perWorkspaceAuthority)
        #expect(secondRestart.status(id: "legacy")?.runtimeIdentity.mode == .legacyCompatibility)
        #expect(secondRestart.status(id: "planned")?.runtimeIdentity == plannedIdentity)
    }

    @Test("legacy workspace planning reaches the unified production transaction")
    func perWorkspaceLegacyIdentityCanBePlanned() throws {
        let state = try makeState("legacy-production-planning")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let legacyManager = makeManager(state: state, policy: .legacyCompatibility)
        _ = try createMachine(id: "legacy", manager: legacyManager)

        let migrated = makeManager(state: state, policy: .perWorkspaceAuthority)
        let controller = RejectingPlanningRecorder()
        #expect(throws: MachineManagerError.self) {
            _ = try migrated.resolveAndPublishProductionPlan(
                id: "legacy",
                controller: controller
            )
        }
        #expect(controller.machineIDs == ["legacy"])
        #expect(migrated.status(id: "legacy")?.runtimeIdentity.mode == .legacyCompatibility)
    }

    @Test("missing or changed resolved authority never falls back to legacy")
    func perWorkspaceResolvedAuthorityFailsClosed() throws {
        let state = try makeState("per-workspace-no-fallback")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let bootstrap = makeManager(state: state, policy: .perWorkspaceAuthority)
        _ = try createMachine(id: "planned", manager: bootstrap)
        let plans = MutablePlanStore()
        _ = try persistResolvedIdentity(machineID: "planned", state: state, plans: plans)

        let withoutInfrastructureStarter = CountingProcessStarter()
        let withoutInfrastructure = makeManager(
            state: state,
            policy: .perWorkspaceAuthority,
            starter: withoutInfrastructureStarter
        )
        #expect(withoutInfrastructure.status(id: "planned")?.runtimeIdentity.mode == .resolvedPlan)
        #expect(throws: MachineManagerError.self) {
            _ = try withoutInfrastructure.start(id: "planned")
        }
        #expect(withoutInfrastructureStarter.count == 0)

        plans.set(nil)
        let missingPlanStarter = CountingProcessStarter()
        let missingPlan = makeManager(
            state: state,
            policy: .perWorkspaceAuthority,
            starter: missingPlanStarter
        )
        let resolver = ClosureLaunchResolver { request in
            try exactResolution(request: request)
        }
        try missingPlan.installResolvedLaunchInfrastructure(
            registry: rawRegistry(
                operations: missingPlan.resolvedLaunchCompatibilityOperations(
                    for: .doryHypervisor
                )
            ),
            resolver: resolver,
            plans: plans,
            expectedPlanRevision: { _ in 1 }
        )
        #expect(missingPlan.status(id: "planned")?.runtimeIdentity.mode == .requiresReplanning)
        #expect(throws: MachineManagerError.self) {
            _ = try missingPlan.start(id: "planned")
        }
        #expect(resolver.callCount == 0)
        #expect(missingPlanStarter.count == 0)

        let recordPath = state + "/planned/"
            + DoryMachineRuntimeIdentityStore.recordFileName
        try FileManager.default.removeItem(atPath: recordPath)
        let missingCompanionStarter = CountingProcessStarter()
        let missingCompanion = makeManager(
            state: state,
            policy: .perWorkspaceAuthority,
            starter: missingCompanionStarter
        )
        #expect(missingCompanion.status(id: "planned")?.runtimeIdentity.mode == .requiresReplanning)
        #expect(throws: MachineManagerError.self) {
            _ = try missingCompanion.start(id: "planned")
        }
        #expect(missingCompanionStarter.count == 0)
    }

    @Test("live durable identity deletion or substitution rejects launch and snapshot")
    func perWorkspaceLiveIdentityTamperFailsClosed() throws {
        let legacyState = try makeState("live-legacy-tamper")
        defer { try? FileManager.default.removeItem(atPath: legacyState) }
        let legacyBootstrap = makeManager(
            state: legacyState,
            policy: .legacyCompatibility
        )
        _ = try createMachine(id: "legacy", manager: legacyBootstrap)
        let legacyStarter = CountingProcessStarter()
        let legacy = makeManager(
            state: legacyState,
            policy: .perWorkspaceAuthority,
            starter: legacyStarter
        )
        try FileManager.default.removeItem(
            atPath: legacyState + "/legacy/"
                + DoryMachineRuntimeIdentityStore.recordFileName
        )
        #expect(throws: MachineManagerError.self) {
            _ = try legacy.start(id: "legacy")
        }
        #expect(throws: MachineManagerError.self) {
            _ = try legacy.snapshot(id: "legacy", snapshotID: "must-not-publish")
        }
        #expect(legacyStarter.count == 0)
        #expect(!FileManager.default.fileExists(
            atPath: legacyState + "/legacy/snapshots/must-not-publish.json"
        ))

        let resolvedState = try makeState("live-resolved-tamper")
        defer { try? FileManager.default.removeItem(atPath: resolvedState) }
        let bootstrap = makeManager(
            state: resolvedState,
            policy: .perWorkspaceAuthority
        )
        _ = try createMachine(id: "planned", manager: bootstrap)
        let plans = MutablePlanStore()
        _ = try persistResolvedIdentity(
            machineID: "planned",
            state: resolvedState,
            plans: plans
        )
        let resolvedStarter = CountingProcessStarter()
        let resolved = makeManager(
            state: resolvedState,
            policy: .perWorkspaceAuthority,
            starter: resolvedStarter
        )
        let resolver = ClosureLaunchResolver { request in
            try exactResolution(request: request)
        }
        try resolved.installResolvedLaunchInfrastructure(
            registry: rawRegistry(
                operations: resolved.resolvedLaunchCompatibilityOperations(
                    for: .doryHypervisor
                )
            ),
            resolver: resolver,
            plans: plans,
            expectedPlanRevision: { _ in 1 }
        )
        let machineData = try Data(contentsOf: URL(
            fileURLWithPath: resolvedState + "/planned/machine.json"
        ))
        try DoryMachineRuntimeIdentityStore(root: resolvedState).publish(
            .legacyCompatibility(virtualHardwareABIVersion: 1),
            machineID: "planned",
            authoritativeLegacyData: machineData
        )
        #expect(throws: MachineManagerError.self) {
            _ = try resolved.start(id: "planned")
        }
        #expect(resolver.callCount == 0)
        #expect(resolvedStarter.count == 0)
    }

    @Test("historical snapshot restore without production authority preserves the resolved workspace")
    func resolvedWorkspaceRestoreOfLegacySnapshotRequiresReplanning() throws {
        let state = try makeState("resolved-restore-legacy")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let legacy = makeManager(state: state, policy: .legacyCompatibility)
        _ = try createMachine(id: "dev", manager: legacy)
        _ = try legacy.snapshot(id: "dev", snapshotID: "historical")

        let migrated = makeManager(state: state, policy: .perWorkspaceAuthority)
        #expect(migrated.status(id: "dev")?.runtimeIdentity.mode == .legacyCompatibility)
        let plans = MutablePlanStore()
        _ = try persistResolvedIdentity(machineID: "dev", state: state, plans: plans)
        let starter = CountingProcessStarter()
        let resolved = makeManager(
            state: state,
            policy: .perWorkspaceAuthority,
            starter: starter
        )
        let resolver = ClosureLaunchResolver { request in
            try exactResolution(request: request)
        }
        try resolved.installResolvedLaunchInfrastructure(
            registry: rawRegistry(
                operations: resolved.resolvedLaunchCompatibilityOperations(
                    for: .doryHypervisor
                )
            ),
            resolver: resolver,
            plans: plans,
            expectedPlanRevision: { _ in 1 }
        )
        let originalIdentity = try #require(resolved.status(id: "dev")?.runtimeIdentity)
        #expect(originalIdentity.mode == .resolvedPlan)
        let protectedPaths = [
            "machine.json", DoryWorkspaceRepository.recordFileName,
            DoryMachineRuntimeIdentityStore.recordFileName, "kernel", "rootfs.ext4",
        ].map { state + "/dev/" + $0 }
        let originalData = try protectedPaths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }

        // Historical snapshot compatibility must not bypass the production restore root.
        // This fixture installs a launch resolver, but has no production planning controller.
        do {
            _ = try resolved.restoreSnapshot(machineID: "dev", snapshotID: "historical")
            Issue.record("historical snapshot restored without production authority")
        } catch let error as MachineManagerError {
            #expect(String(describing: error).contains("production source authority"))
        }
        #expect(resolved.status(id: "dev")?.runtimeIdentity == originalIdentity)
        for (path, expected) in zip(protectedPaths, originalData) {
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == expected)
        }
        #expect(resolver.callCount == 0)
        #expect(throws: MachineManagerError.self) {
            _ = try resolved.start(id: "dev")
        }
        #expect(starter.count == 0)

        let restartedStarter = CountingProcessStarter()
        let restarted = makeManager(
            state: state,
            policy: .perWorkspaceAuthority,
            starter: restartedStarter
        )
        let restartedResolver = ClosureLaunchResolver { request in
            try exactResolution(request: request)
        }
        try restarted.installResolvedLaunchInfrastructure(
            registry: rawRegistry(
                operations: restarted.resolvedLaunchCompatibilityOperations(
                    for: .doryHypervisor
                )
            ),
            resolver: restartedResolver,
            plans: plans,
            expectedPlanRevision: { _ in 1 }
        )
        #expect(restarted.status(id: "dev")?.runtimeIdentity == originalIdentity)
        #expect(throws: MachineManagerError.self) {
            _ = try restarted.start(id: "dev")
        }
        #expect(restartedResolver.callCount == 0)
        #expect(restartedStarter.count == 0)
    }

    @Test("per-workspace clone and portable import require a fresh plan")
    func perWorkspaceCloneAndImportInvalidateAuthority() throws {
        let state = try makeState("per-workspace-copy")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let legacy = makeManager(state: state, policy: .legacyCompatibility)
        _ = try createMachine(id: "source", manager: legacy)
        let sourceSnapshot = try legacy.snapshot(id: "source", snapshotID: "base")
        let bundle = state + "/source.dorymachine"
        try legacy.exportSnapshot(
            machineID: "source",
            snapshotID: sourceSnapshot.id,
            toPath: bundle
        )

        let manager = makeManager(state: state, policy: .perWorkspaceAuthority)
        let clone = try manager.stageCloneSnapshotForBootstrap(
            machineID: "source",
            snapshotID: "base",
            newID: "clone"
        )
        #expect(clone.state == .created)
        #expect(clone.runtimeIdentity.mode == .requiresReplanning)
        #expect(clone.runtimeIdentity.invalidationReason == .planNotInstalled)

        let imported = try manager.importSnapshot(fromPath: bundle)
        #expect(imported.runtimeIdentity.mode == .requiresReplanning)
        #expect(imported.runtimeIdentity.invalidationReason == .importedSnapshot)
    }

    private func makeState(_ label: String) throws -> String {
        let state = "/private/tmp/dory-authority-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: state,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(state, mode_t(0o700))
        return state
    }

    private func makeManager(
        state: String,
        policy: DoryMachineLaunchPolicy,
        starter: CountingProcessStarter = CountingProcessStarter()
    ) -> MachineManager {
        let stateBroker = try! DoryMachineStateBroker(
            canonicalStateRootPath: state
        )
        return MachineManager(
            diagnosticConfiguration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sh",
                acceleratedDesktopExecutablePath: "/bin/sh",
                stateDirectory: state,
                baseArguments: ["-c", "exec /bin/sleep 30", "dory-test-runtime"],
                acceleratedDesktopBaseArguments: [
                    "-c", "exec /bin/sleep 30", "dory-test-runtime",
                ],
                passMachineArguments: true,
                requiresReadyHandoff: false
            ),
            launchPolicy: policy,
            machineStateBroker: stateBroker,
            processStarter: { process in try starter.start(process) }
        )
    }

    @discardableResult
    private func createMachine(id: String, manager: MachineManager) throws -> DoryMachineStatus {
        try manager.stageMachineForBootstrap(DoryMachineConfiguration(
            id: id,
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            memoryMB: 2_048,
            cpuCount: 2,
            displayMode: .desktop
        ))
    }

    private func persistResolvedIdentity(
        machineID: String,
        state: String,
        plans: MutablePlanStore
    ) throws -> DoryMachineRuntimeIdentity {
        let definition = try DoryWorkspaceRepository(root: state)
            .readPersistedRecord(id: machineID).definition
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let definitionData = try encoder.encode(definition)
        let legacyData = try Data(
            contentsOf: URL(fileURLWithPath: state + "/\(machineID)/machine.json")
        )
        let machine = try JSONDecoder().decode(
            DoryMachineConfiguration.self,
            from: legacyData
        )
        let resolution = try exactResolution(request: .init(
            definition: definition,
            canonicalDefinitionData: definitionData,
            machine: machine,
            persistence: try DoryResolvedMachinePersistence(stateDirectory: state, machineID: machineID),
            expectedPlanRevision: 1
        ))
        plans.set(resolution.resolvedPlan)
        let identity = try DoryMachineRuntimeIdentity(
            resolvedPlan: resolution.resolvedPlan,
            planSHA256: resolution.resolvedPlanSHA256
        )
        try DoryMachineRuntimeIdentityStore(root: state).publish(
            identity,
            machineID: machineID,
            authoritativeLegacyData: legacyData
        )
        return identity
    }

    private func withHarness(
        _ label: String,
        stateDirectoryOverride: String? = nil,
        admittedDesktopFixture: Bool = false,
        launchPolicy: DoryMachineLaunchPolicy = .requireResolvedPlan,
        acceleratedExecutablePath: String? = "/bin/sh",
        passMachineArguments: Bool = true,
        requiresReadyHandoff: Bool = false,
        useShortStatePath: Bool = false,
        authenticatedRuntime: Bool = false,
        injectStateBroker: Bool = true,
        initialEnvironment: [String: String] = [:],
        usbController: any DoryMachineUSBControlling = UnixDoryMachineUSBController(),
        agentConnector: @escaping MachineManager.AgentConnector = { socketPath in
            try LocalAgentControl.connect(socketPath: socketPath)
        },
        starter: CountingProcessStarter = CountingProcessStarter(),
        processStopper: @escaping MachineManager.ProcessStopper = { process in
            process.stop(timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
        },
        _ body: (MachineManager, CountingProcessStarter, String) throws -> Void
    ) throws {
        let state = stateDirectoryOverride ?? (useShortStatePath
            ? "/private/tmp/dory-r-\(UUID().uuidString)"
            : "/private/tmp/dory-resolved-start-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: state,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(state, mode_t(0o700))
        let stateBroker = injectStateBroker
            ? try DoryMachineStateBroker(canonicalStateRootPath: state)
            : nil
        let runtimeCommand: String
        if authenticatedRuntime {
            func shellQuote(_ value: String) -> String {
                "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
                .map { "DEVELOPER_DIR=" + shellQuote($0) + " " } ?? ""
            runtimeCommand = developerDirectory
                + "DORY_RECONNECT_TEST_SOCKET=" + shellQuote(state + "/control.sock")
                + " DORY_RECONNECT_TEST_FD=20 exec /usr/bin/xcrun xctest -XCTest "
                + "DorydKitTests.DoryRuntimeReconnectTests/testReconnectSubprocessServer "
                + shellQuote(Bundle(for: DoryRuntimeReconnectTests.self).bundlePath)
        } else {
            runtimeCommand = "exec /bin/sleep 30"
        }
        let manager = MachineManager(
            diagnosticConfiguration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sh",
                acceleratedDesktopExecutablePath: acceleratedExecutablePath,
                stateDirectory: state,
                baseArguments: ["-c", runtimeCommand, "dory-test-runtime"],
                acceleratedDesktopBaseArguments: [
                    "-c", runtimeCommand, "dory-test-runtime",
                ],
                passMachineArguments: passMachineArguments,
                requiresReadyHandoff: requiresReadyHandoff
            ),
            launchPolicy: launchPolicy,
            machineStateBroker: stateBroker,
            usbController: usbController,
            agentConnector: agentConnector,
            processStarter: { process in try starter.start(process) },
            processStopper: processStopper
        )
        defer {
            // The daemon-death parent owns this directory and needs failure evidence if its
            // child exits before reaching the requested crash boundary.
            if ProcessInfo.processInfo.environment["DORY_RECONNECT_DAEMON_ROOT"] != state {
                _ = try? manager.stop(id: "dev")
                _ = try? manager.delete(id: "dev")
                _ = try? FileManager.default.removeItem(atPath: state)
            }
        }
        let rootfsPath: String
        if admittedDesktopFixture {
            rootfsPath = state + "/fixture-rootfs.ext4"
            try Data(contentsOf: URL(fileURLWithPath: doryTestRootfsPath)).write(to: URL(fileURLWithPath: rootfsPath))
            let disk = try FileHandle(forWritingTo: URL(fileURLWithPath: rootfsPath))
            try disk.truncate(atOffset: 32 * 1_073_741_824)
            try disk.close()
        } else {
            rootfsPath = doryTestRootfsPath
        }
        _ = try manager.stageMachineForBootstrap(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: rootfsPath,
            memoryMB: admittedDesktopFixture ? 4_096 : 2_048,
            cpuCount: 2,
            displayMode: .desktop,
            environment: initialEnvironment
        ))
        try body(manager, starter, state)
    }

    private func authenticatedControlSocket(state: String) throws -> String {
        let socket = state + "/control.sock"
        let identity = try DoryRuntimeReconnectRecordStore(root: state).read(machineID: "dev").launchIdentity
        let deadline = Date().addingTimeInterval(3)
        while true {
            do {
                _ = try VmmControlClient.authenticateRuntime(socketPath: socket, launchIdentity: identity)
                return socket
            } catch {
                if Date() >= deadline {
                    let files = FileManager.default.enumerator(atPath: state)?.allObjects as? [String] ?? []
                    let logs = files.filter { $0.hasSuffix(".log") }.compactMap {
                        try? String(contentsOfFile: state + "/" + $0, encoding: .utf8)
                    }.joined(separator: "\n")
                    throw NSError(domain: "AuthenticatedRuntimeFixture", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "\(error); runtime output: \(logs)",
                    ])
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private func installExactRawHVInfrastructure(
        _ manager: MachineManager
    ) throws {
        let plans = MutablePlanStore()
        let operations = manager.resolvedLaunchCompatibilityOperations(
            for: .doryHypervisor
        )
        let registry = try rawRegistry(operations: operations)
        let resolver = ClosureLaunchResolver { request in
            let resolution = try exactResolution(request: request)
            plans.set(resolution.resolvedPlan)
            return resolution
        }
        try manager.installResolvedLaunchInfrastructure(
            registry: registry,
            resolver: resolver,
            plans: plans,
            expectedPlanRevision: { _ in 1 }
        )
    }

    private func assertDiskLeaseReleased(path: String) throws {
        let descriptor = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        _ = flock(descriptor, LOCK_UN)
    }

    private func rawRegistry(
        operations: MachineBackendCompatibilityOperations,
        executablePath: String = "/bin/sh"
    ) throws -> BackendRegistry {
        try BackendRegistry(backends: [RawHVLinuxMachineBackend(
            executablePath: executablePath,
            operations: operations
        )])
    }

    private func rendererReleaseIdentityFixture() throws
        -> DoryRendererReleaseIdentityV1
    {
        DoryRendererReleaseIdentityV1(
            runnerCodeDirectoryHash: try DoryCodeDirectoryHash(
                lowercaseHexadecimal: String(repeating: "11", count: 20)
            ),
            rendererWorkerCodeDirectoryHash: try DoryCodeDirectoryHash(
                lowercaseHexadecimal: String(repeating: "22", count: 20)
            ),
            tupleDefinitionSHA256: try DoryRendererArtifactDigest(
                lowercaseSHA256:
                    DoryRendererSourceTuple.productionDefinitionSHA256
            )
        )
    }

    private func exactResolution(
        request: DoryDaemonVirtualMachineLaunchPlanRequest,
        componentSHA256: String? = nil,
        bootArtifactSHA256: String? = nil,
        admissionEvidence: DoryResolvedMachineResourceAdmissionEvidence? = nil,
        preSpawnRevalidation: @escaping @Sendable () throws -> Void = {}
    ) throws -> DoryDaemonVirtualMachineLaunchPlanResolution {
        let devices = DoryDaemonVirtualMachinePlanningCoordinator.devices(
            for: request.definition
        )
        let definitionDigest = SHA256.hash(data: request.canonicalDefinitionData)
            .map { String(format: "%02x", $0) }.joined()
        let artifact = try bootArtifactSHA256
            ?? fileSHA256(path: request.machine.kernelPath)
        let media = DoryBootMedia(
            kind: request.definition.boot.devices[0].kind,
            source: .userProvided,
            artifactSHA256: artifact
        )
        let runtime = "raw-runtime-1"
        let launcherSHA256: String
        if let componentSHA256 {
            launcherSHA256 = componentSHA256
        } else {
            launcherSHA256 = try fileSHA256(path: "/bin/sh")
        }
        let plan = DoryResolvedMachinePlan(
            machineID: request.machine.id,
            definitionRevision: request.definition.lifecycle.revision,
            definitionSHA256: definitionDigest,
            planRevision: request.expectedPlanRevision,
            createdAtUnixMilliseconds: request.definition.lifecycle.createdAtUnixMilliseconds,
            updatedAtUnixMilliseconds: request.definition.lifecycle.updatedAtUnixMilliseconds,
            guest: request.definition.guest,
            backend: .doryHypervisor,
            backendImplementationIdentifier:
                RawHVLinuxMachineBackend.backendDescriptor.implementationIdentifier,
            backendRuntimeBuildIdentifier: runtime,
            virtualHardwareABIVersion: request.definition.virtualHardwareABIVersion,
            armVirtTopology: try DoryARMVirtV1TopologyPlanner.resolve(
                definition: request.definition,
                resolvedDevices: devices
            ),
            bootMedia: DoryResolvedMachineBootMedia(
                resolverReference: DoryVMResolverReference(
                    namespace: "machine",
                    identifier: "dev-kernel"
                ),
                media: media
            ),
            launchArtifacts: resolvedBootLaunchArtifacts(
                reference: DoryVMResolverReference(
                    namespace: "machine", identifier: "dev-kernel"
                ),
                media: media
            ),
            components: [DoryResolvedBackendComponentEvidence(
                componentIdentifier: "dory-hv",
                buildIdentifier: runtime,
                artifactSHA256: launcherSHA256
            )],
            devices: devices,
            graphics: .hostAcceleratedDisplay,
            portForwards: request.definition.portForwards,
            supportTier: .supported,
            selectionEvidence: DoryResolvedMachineBackendSelectionEvidence(
                disposition: .primary,
                plannerRequest: DoryVirtualMachineBackendPlanRequest(
                    guest: request.definition.guest,
                    bootMedia: media,
                    acceptableGraphics: [.hostAcceleratedDisplay],
                    devices: devices,
                    virtualHardwareABIVersion:
                        request.definition.virtualHardwareABIVersion,
                    backendPreferences: [.doryHypervisor],
                    backendPreferencePolicy: .required
                ),
                selectedEvaluationIndex: 0,
                rejectedCandidates: []
            ),
            qualificationEvidence: DoryResolvedMachineQualificationEvidence(
                graphics: DorySignedArtifactQualificationEvidence(
                    manifestIdentity: "graphics-qualification-1",
                    artifactSHA256: artifact,
                    manifestSHA256: digest("b"),
                    signingKeyID: "dory-release-1",
                    manifestFormatVersion: 1
                ),
                runtime: runtimeQualification(
                    guest: request.definition.guest,
                    media: media,
                    runtimeBuild: runtime,
                    devices: devices,
                    virtualHardwareABIVersion:
                        request.definition.virtualHardwareABIVersion
                )
            ),
            resourceAdmission: admissionEvidence ?? resourceAdmission(
                machine: request.machine,
                diskBytes: request.definition.resources.diskBytes
            ),
            hostQualification: DoryResolvedHostQualificationEvidence(
                qualificationIdentity: "host-qualification-1",
                qualificationReportSHA256: digest("6"),
                hostHardwareModelIdentifier: "Mac16.1",
                hostOperatingSystemBuild: "26A5406c",
                backend: .doryHypervisor,
                backendRuntimeBuildIdentifier: runtime,
                virtualHardwareABIVersion: request.definition.virtualHardwareABIVersion,
                qualifierIdentifier: "dory-host-qualifier",
                qualifierVersion: 1
            ),
            resources: request.definition.resources,
            persistence: request.persistence
        )
        let validationIssues = plan.validate()
        guard validationIssues.isEmpty else {
            throw MachineManagerError.persistence(
                "fixture plan is invalid: \(validationIssues)"
            )
        }
        let capability = DoryVirtualMachineCapabilityDescriptor(
            evaluatorVersion: DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
            request: DoryVirtualMachineCapabilityRequest(
                guest: plan.guest,
                bootMedia: media,
                backend: .doryHypervisor,
                graphics: plan.graphics,
                devices: devices,
                virtualHardwareABIVersion: plan.virtualHardwareABIVersion
            ),
            availability: DoryCapabilityAvailability(
                supportTier: .supported,
                state: .available
            ),
            resolvedDevices: devices,
            graphicsQualificationEvidence: plan.qualificationEvidence.graphics,
            runtimeQualificationEvidence: plan.qualificationEvidence.runtime
        )
        return DoryDaemonVirtualMachineLaunchPlanResolution(
            resolvedPlan: plan,
            resolvedPlanSHA256: try planSHA256(plan),
            revalidation: DoryResolvedMachinePlanStartValidator.revalidate(
                plan,
                against: DoryResolvedMachinePlanStartRevalidationInput(
                    machineID: plan.machineID,
                    expectedPlanRevision: plan.planRevision,
                    currentDefinitionRevision: plan.definitionRevision,
                    currentDefinitionSHA256: definitionDigest,
                    runtimeEvidence: DoryResolvedMachineRuntimeEvidence(plan: plan)
                )
            ),
            backendPlan: MachineBackendPlan(
                backend: RawHVLinuxMachineBackend.backendDescriptor,
                machine: request.machine,
                capability: capability,
                portForwards: request.definition.portForwards
            ),
            preSpawnAuthorization: DoryDaemonVirtualMachinePreSpawnAuthorization(
                purpose: request.purpose,
                revalidate: preSpawnRevalidation
            )
        )
    }

    private func runtimeQualification(
        guest: DoryGuestPlatform,
        media: DoryBootMedia,
        runtimeBuild: String,
        devices: DoryVirtualMachineDeviceCapabilityRequest,
        virtualHardwareABIVersion: UInt16
    ) -> DoryVirtualMachineRuntimeQualificationEvidence {
        DoryVirtualMachineRuntimeQualificationEvidence(
            qualificationIdentity: "runtime-qualification-1",
            qualificationReportSHA256: digest("c"),
            signingKeyID: "dory-runtime-1",
            qualificationFormatVersion: 1,
            guest: guest,
            bootMediaKind: media.kind,
            immutableArtifactSHA256: media.artifactSHA256,
            backend: .doryHypervisor,
            backendRuntimeBuildID: runtimeBuild,
            virtualHardwareABIVersion: virtualHardwareABIVersion,
            graphics: .hostAcceleratedDisplay,
            devices: devices
        )
    }

    private func resourceAdmission(
        machine: DoryMachineConfiguration,
        diskBytes: UInt64
    ) -> DoryResolvedMachineResourceAdmissionEvidence {
        DoryResolvedMachineResourceAdmissionEvidence(
            admittedVirtualCPUCount: UInt64(machine.cpuCount),
            admittedMemoryBytes: machine.memoryMB * 1_048_576,
            admittedStorageBytes: diskBytes,
            hostLogicalCPUCount: 12,
            hostPhysicalMemoryBytes: 32 * 1_073_741_824,
            hostFreeStorageBytes: 512 * 1_073_741_824,
            existingVirtualCPUCommitment: 0,
            existingMemoryCommitmentBytes: 0,
            existingStorageReservationBytes: 0,
            hostReservedLogicalCPUCount: 2,
            hostReservedMemoryBytes: 8 * 1_073_741_824,
            hostReservedStorageBytes: 32 * 1_073_741_824,
            admissionIdentity: "resource-admission-1",
            admissionReportSHA256: digest("f"),
            assessorIdentifier: "dory-resource-policy",
            assessorVersion: 1
        )
    }

    private func planSHA256(_ plan: DoryResolvedMachinePlan) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(plan))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func graphicsSelection(
        plan: DoryResolvedMachinePlan,
        operationID: String
    ) throws -> DoryRuntimeGraphicsSelection {
        switch plan.graphics {
        case .software:
            return DoryRuntimeGraphicsSelection(
                operationID: operationID,
                resolvedPlanSHA256: try planSHA256(plan),
                planRevision: plan.planRevision,
                accelerationLevel: .software,
                backend: .software
            )
        case .hostAcceleratedDisplay:
            return DoryRuntimeGraphicsSelection(
                operationID: operationID,
                resolvedPlanSHA256: try planSHA256(plan),
                planRevision: plan.planRevision,
                accelerationLevel: .hostAcceleratedDisplay,
                backend: .virgl,
                rendererGeneration: 1,
                rendererWorkerReceiptSHA256: digest("7"),
                guestProducerFenceProofSHA256: digest("8")
            )
        case .hardwareAccelerated3D:
            return DoryRuntimeGraphicsSelection(
                operationID: operationID,
                resolvedPlanSHA256: try planSHA256(plan),
                planRevision: plan.planRevision,
                accelerationLevel: .hardwareAccelerated3D,
                backend: .virglVenus,
                rendererGeneration: 1,
                rendererWorkerReceiptSHA256: digest("7"),
                guestProducerFenceProofSHA256: digest("8")
            )
        case .none:
            throw MachineManagerError.persistence(
                "RawHV desktop fixture cannot emit a headless graphics selection"
            )
        }
    }

    private func fileSHA256(path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func writeExecutable(_ contents: String, path: String) throws {
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: path
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}

private final class ClosureLaunchResolver:
    DoryDaemonVirtualMachineLaunchPlanResolving,
    @unchecked Sendable
{
    typealias Handler = @Sendable (
        DoryDaemonVirtualMachineLaunchPlanRequest
    ) throws -> DoryDaemonVirtualMachineLaunchPlanResolution

    private let lock = NSLock()
    private var calls = 0
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var callCount: Int { lock.withLock { calls } }

    func resolve(
        _ request: DoryDaemonVirtualMachineLaunchPlanRequest
    ) throws -> DoryDaemonVirtualMachineLaunchPlanResolution {
        lock.withLock { calls += 1 }
        return try handler(request)
    }
}

private final class CountingProcessStarter: @unchecked Sendable {
    typealias Start = @Sendable (HvProcess) throws -> Void

    private let lock = NSLock()
    private var starts = 0
    private let startImplementation: Start

    init(startImplementation: @escaping Start = { process in try process.start() }) {
        self.startImplementation = startImplementation
    }

    var count: Int { lock.withLock { starts } }

    func start(_ process: HvProcess) throws {
        lock.withLock { starts += 1 }
        try startImplementation(process)
    }
}

private enum ResolvedLaunchLifecycleFixtureError: Error {
    case prepublicationFailure
}

private final class ControlledApplicationTerminationController:
    DoryApplicationTerminationControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var terminated = false

    var isTerminated: Bool { lock.withLock { terminated } }

    @discardableResult
    func forceTerminate() -> Bool { true }

    func confirmTermination() {
        lock.withLock { terminated = true }
    }
}

private final class ControlledMachineProcessStopper: @unchecked Sendable {
    private let lock = NSLock()
    private var permitsTermination = false

    func stop(_ process: HvProcess) -> Bool {
        let permitted = lock.withLock { permitsTermination }
        guard permitted else { return false }
        return process.stop(timeout: 0.25)
    }

    func allowTermination() {
        lock.withLock { permitsTermination = true }
    }
}

private final class ResolvedClockSyncRecorder: AgentControlClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSyncs: [Int64] = []
    private var recordedInfoCalls = 0
    private let advertisedInfo: DoryAgentInfo
    private let execOutput: String

    init(advertisedInfo: DoryAgentInfo = DoryAgentInfo(
        protocolVersion: DoryCore.protocolVersion(), kernel: "Linux test",
        agentBuild: "dory-agent/resolved-clock-test", uptimeSeconds: 1
    ), execOutput: String = "") {
        self.advertisedInfo = advertisedInfo
        self.execOutput = execOutput
    }

    var syncs: [Int64] { lock.withLock { recordedSyncs } }
    var infoCalls: Int { lock.withLock { recordedInfoCalls } }

    func connect(socketPath: String) throws -> any AgentControlClient {
        #expect(socketPath == "/run/dory-agent.sock")
        return self
    }

    func info() throws -> DoryAgentInfo {
        lock.withLock { recordedInfoCalls += 1 }
        return advertisedInfo
    }

    func clockSync(hostEpochNs: Int64) throws -> Bool {
        lock.withLock { recordedSyncs.append(hostEpochNs) }
        return true
    }

    func portsWatch() throws -> DoryPortsSnapshot {
        DoryPortsSnapshot(ports: [], added: [], removed: [])
    }

    func telemetry() throws -> DoryTelemetry {
        DoryTelemetry(
            memTotalKB: 1,
            memAvailableKB: 1,
            psiSomeAvg10: 0,
            psiFullAvg10: 0
        )
    }

    func exec(
        argv: [String],
        cwd: String,
        env: [DoryExecEnvironment],
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult {
        DoryExecResult(
            exitCode: 0,
            stdout: Data(execOutput.utf8),
            stderr: Data(),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        )
    }

    func close() {}
}

private final class ResolvedPlanRecordingUSBController:
    DoryMachineUSBControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func attach(
        machineID: String,
        socketPath: String,
        busID: String,
        identityToken: DoryUSBPhysicalIdentityToken,
        mode: DoryMachineUSBOpenMode
    ) throws -> DoryMachineUSBAttachment {
        _ = identityToken
        lock.withLock { calls += 1 }
        return DoryMachineUSBAttachment(
            machineID: machineID,
            busID: busID,
            port: 4,
            vsockPort: 1025,
            deviceID: 0x0003_0002,
            speed: 3
        )
    }

    func detach(socketPath: String, busID: String) throws {
        lock.withLock { calls += 1 }
    }
}

private final class MutablePlanStore: DoryResolvedMachinePlanStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var plan: DoryResolvedMachinePlan?

    func set(_ plan: DoryResolvedMachinePlan?) {
        lock.withLock { self.plan = plan }
    }

    func create(_ plan: DoryResolvedMachinePlan) throws { set(plan) }

    func replace(
        _ plan: DoryResolvedMachinePlan,
        expectedPlanRevision: UInt64
    ) throws {
        lock.withLock { self.plan = plan }
    }

    func read(id: String) throws -> DoryResolvedMachinePlan {
        guard let plan = lock.withLock({ self.plan }), plan.machineID == id else {
            throw DoryResolvedMachinePlanRepositoryError.planNotFound(id)
        }
        return plan
    }
}

private final class RejectingPlanningRecorder:
    DoryDaemonVirtualMachineProductionPlanningControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedMachineIDs: [String] = []

    var machineIDs: [String] { lock.withLock { recordedMachineIDs } }

    func authorityRevision(for reference: DoryVMResolverReference) throws -> UInt64? {
        _ = reference
        return nil
    }

    func publishResolvedPlan(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        artifacts: [DoryDaemonVirtualMachinePlanningArtifactPublication]
    ) throws {
        _ = artifacts
        lock.withLock {
            recordedMachineIDs.append(request.planning.machine.id)
        }
        throw PlanningRejected()
    }

    private struct PlanningRejected: Error {}
}
