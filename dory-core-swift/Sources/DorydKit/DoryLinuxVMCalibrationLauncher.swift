import CryptoKit
import Darwin
import DoryOperations
import DoryRendererWorkerWireContracts
import DoryVMContracts
import Foundation
import Security

/// Explicit inputs for one isolated Linux physical-calibration run.
///
/// This is deliberately not a production admission API. It never reads a support catalog and
/// every receipt it emits is permanently labelled `not-release-qualifying`.
public struct DoryLinuxVMCalibrationConfiguration: Sendable, Equatable {
    public static let requiredConfirmation =
        "I-UNDERSTAND-THIS-IS-NOT-RELEASE-QUALIFICATION"

    public var runnerAppPath: String
    public var kernelPath: String
    public var kernelSHA256: String
    public var rootfsPath: String
    public var rootfsSHA256: String
    public var gvproxyPath: String
    public var gvproxySHA256: String
    public var workrootPath: String
    public var memoryMB: UInt64
    public var virtualCPUCount: UInt16
    public var displayWidthPixels: UInt32
    public var displayHeightPixels: UInt32
    public var confirmation: String

    public init(
        runnerAppPath: String,
        kernelPath: String,
        kernelSHA256: String,
        rootfsPath: String,
        rootfsSHA256: String,
        gvproxyPath: String,
        gvproxySHA256: String,
        workrootPath: String,
        memoryMB: UInt64 = 8_192,
        virtualCPUCount: UInt16 = 8,
        displayWidthPixels: UInt32 = 1_920,
        displayHeightPixels: UInt32 = 1_080,
        confirmation: String
    ) {
        self.runnerAppPath = runnerAppPath
        self.kernelPath = kernelPath
        self.kernelSHA256 = kernelSHA256.lowercased()
        self.rootfsPath = rootfsPath
        self.rootfsSHA256 = rootfsSHA256.lowercased()
        self.gvproxyPath = gvproxyPath
        self.gvproxySHA256 = gvproxySHA256.lowercased()
        self.workrootPath = workrootPath
        self.memoryMB = memoryMB
        self.virtualCPUCount = virtualCPUCount
        self.displayWidthPixels = displayWidthPixels
        self.displayHeightPixels = displayHeightPixels
        self.confirmation = confirmation
    }
}

public enum DoryLinuxVMCalibrationError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case unsafePath(String)
    case filesystem(String)
    case artifactMismatch(String)
    case rendererAuthorityUnavailable
    case definitionRejected
    case handoffTimedOut
    case handoffRejected(String)
    case runtimeTerminated(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let detail):
            "invalid Linux calibration configuration: \(detail)"
        case .unsafePath(let detail):
            "unsafe Linux calibration path: \(detail)"
        case .filesystem(let detail):
            "Linux calibration filesystem failure: \(detail)"
        case .artifactMismatch(let detail):
            "Linux calibration artifact mismatch: \(detail)"
        case .rendererAuthorityUnavailable:
            "the signed runner does not contain an admissible static renderer graph"
        case .definitionRejected:
            "the Linux calibration workspace definition is invalid"
        case .handoffTimedOut:
            "the Linux calibration VM did not publish readiness within 180 seconds"
        case .handoffRejected(let detail):
            "the Linux calibration readiness handoff was rejected: \(detail)"
        case .runtimeTerminated(let detail):
            "the Linux calibration runtime terminated before readiness: \(detail)"
        }
    }
}

/// Calibration-only vertical slice through the exact resolved RawHV renderer launch boundary.
///
/// The launcher creates a new private workspace, clones the mutable disk, verifies every immutable
/// input, verifies the signed nested runner graph, transfers FD3/FD4/FD6, validates the suspended
/// live runner CDHash, and accepts readiness only after the synchronized producer-fence/Metal
/// presentation receipt is published. It never starts or mutates the user's daemon.
public enum DoryLinuxVMCalibrationLauncher {
    private static let machineID = "linux-calibration"
    private static let planFileName = "calibration-launch-plan.json"
    private static let resultFileName = "calibration-result.json"
    private static let logFileName = "runner.log"
    private static let handoffTimeout: TimeInterval = 180

    private struct ArtifactRecord: Codable, Sendable, Equatable {
        let byteCount: UInt64
        let sha256: String
        let codeDirectoryHash: String?

        init(
            byteCount: UInt64,
            sha256: String,
            codeDirectoryHash: String? = nil
        ) {
            self.byteCount = byteCount
            self.sha256 = sha256
            self.codeDirectoryHash = codeDirectoryHash
        }
    }

    private struct LaunchPlan: Codable, Sendable, Equatable {
        let schemaVersion: UInt16
        let qualificationMode: String
        let verdict: String
        let definition: DoryVirtualMachineDefinition
        let devices: DoryVirtualMachineDeviceCapabilityRequest
        let topology: DoryRawHVVirtualHardwareTopology
        let executionResources: RuntimeLaunchEnvelope.RawHVExecutionResources
        let runnerExecutable: ArtifactRecord
        let rendererWorkerExecutable: ArtifactRecord
        let rendererCandidateInventorySHA256: String
        let managedGuestKernel: ArtifactRecord
        let mutableSystemDiskInput: ArtifactRecord
        let gvproxyExecutable: ArtifactRecord
        let rendererTupleDefinitionSHA256: String
    }

    private struct ResultReceipt: Codable, Sendable, Equatable {
        let schemaVersion: UInt16
        let qualificationMode: String
        let verdict: String
        let launchPlanSHA256: String
        let machineID: String
        let operationID: String
        let runnerPID: Int32
        let readyAtUnixMilliseconds: Int64
        let ready: VmmReadyMessage
    }

    private final class VerifiedInput {
        let path: String
        let descriptor: Int32
        let status: stat
        let byteCount: UInt64
        let sha256: String

        init(
            path: String,
            expectedSHA256: String,
            requiresExecutableBit: Bool = false,
            maximumByteCount: UInt64? = nil
        ) throws {
            guard DoryLinuxVMCalibrationLauncher.isCanonicalAbsolutePath(path) else {
                throw DoryLinuxVMCalibrationError.unsafePath(path)
            }
            guard DoryLinuxVMCalibrationLauncher.isLowercaseSHA256(expectedSHA256) else {
                throw DoryLinuxVMCalibrationError.invalidConfiguration(
                    "expected digest for \(path) is not lowercase SHA-256"
                )
            }
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else {
                throw DoryLinuxVMCalibrationError.filesystem(
                    "could not open \(path): \(String(cString: strerror(errno)))"
                )
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1,
                  info.st_size > 0,
                  info.st_mode & (S_IWGRP | S_IWOTH) == 0,
                  !requiresExecutableBit || info.st_mode & 0o111 != 0,
                  maximumByteCount.map({ UInt64(info.st_size) <= $0 }) ?? true else {
                close(descriptor)
                throw DoryLinuxVMCalibrationError.unsafePath(
                    "\(path) is not a stable, non-shared regular input"
                )
            }
            do {
                let digest = try DoryLinuxVMCalibrationLauncher.sha256Stable(
                    descriptor: descriptor,
                    expectedStatus: info
                )
                guard digest == expectedSHA256 else {
                    throw DoryLinuxVMCalibrationError.artifactMismatch(path)
                }
                self.path = path
                self.descriptor = descriptor
                self.status = info
                self.byteCount = UInt64(info.st_size)
                self.sha256 = digest
            } catch {
                close(descriptor)
                throw error
            }
        }

        deinit {
            close(descriptor)
        }
    }

    private final class HandoffState: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var outcome: Result<VmmReadyMessage, Error>?

        func publish(_ result: Result<VmmHandoff, Error>) {
            let mapped = result.map(\.ready)
            lock.lock()
            guard outcome == nil else {
                lock.unlock()
                return
            }
            outcome = mapped
            lock.unlock()
            semaphore.signal()
        }

        func read() -> Result<VmmReadyMessage, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }
    }

    private final class TerminationState: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: HvProcessTermination?

        func publish(_ termination: HvProcessTermination) {
            lock.lock()
            if value == nil { value = termination }
            lock.unlock()
            semaphore.signal()
        }

        func read() -> HvProcessTermination? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Blocks until the ready VM exits or this calibration process receives SIGINT/SIGTERM.
    public static func run(_ configuration: DoryLinuxVMCalibrationConfiguration) throws {
        try validate(configuration)
        let workroot = try createPrivateWorkroot(configuration.workrootPath)
        let runtimeWorkrootPath = try canonicalRuntimeWorkrootPath(for: workroot)

        let runnerExecutablePath = configuration.runnerAppPath
            + "/Contents/MacOS/dory-hv"
        let workerBundlePath = configuration.runnerAppPath
            + "/Contents/XPCServices/DoryRendererWorker.xpc"
        let workerExecutablePath = configuration.runnerAppPath
            + "/Contents/"
            + DoryRendererProductionInventory.rendererWorkerRelativePath
        let runner = try VerifiedInput(
            path: runnerExecutablePath,
            expectedSHA256: try sha256Path(runnerExecutablePath),
            requiresExecutableBit: true
        )
        let runtimeBuildIdentifier = "sha256:\(runner.sha256)"
        guard let rendererAdmission = try DoryDaemonRendererProductionAuthority
            .verifyIfPresent(
                runnerExecutablePath: runnerExecutablePath,
                runtimeBuildIdentifier: runtimeBuildIdentifier
            ) else {
            throw DoryLinuxVMCalibrationError.rendererAuthorityUnavailable
        }
        let worker = try VerifiedInput(
            path: workerExecutablePath,
            expectedSHA256:
                rendererAdmission.rendererWorkerExecutable.lowercaseSHA256,
            requiresExecutableBit: true,
            maximumByteCount: DoryRendererProductionInventory.maximumArtifactBytes
        )
        let runnerCDHash = try verifiedCodeDirectoryHash(
            at: configuration.runnerAppPath,
            requirement: DoryRendererWorkerIdentity.runnerCodeSigningRequirement
        )
        let workerCDHash = try verifiedCodeDirectoryHash(
            at: workerBundlePath,
            requirement: DoryRendererWorkerIdentity.workerCodeSigningRequirement
        )
        let rendererReleaseIdentity = DoryRendererReleaseIdentityV1(
            runnerCodeDirectoryHash: runnerCDHash,
            rendererWorkerCodeDirectoryHash: workerCDHash,
            tupleDefinitionSHA256: try DoryRendererArtifactDigest(
                lowercaseSHA256: DoryRendererSourceTuple.productionDefinitionSHA256,
                field: "rendererTupleDefinition"
            )
        )

        let kernel = try VerifiedInput(
            path: configuration.kernelPath,
            expectedSHA256: configuration.kernelSHA256,
            maximumByteCount: RuntimeLaunchEnvelope.maximumLinuxKernelBytes
        )
        let rootfs = try VerifiedInput(
            path: configuration.rootfsPath,
            expectedSHA256: configuration.rootfsSHA256
        )
        let gvproxy = try VerifiedInput(
            path: configuration.gvproxyPath,
            expectedSHA256: configuration.gvproxySHA256,
            requiresExecutableBit: true
        )

        try workroot.withBorrowedDescriptor { directory in
            try cloneOrCopy(
                kernel,
                to: "kernel",
                below: directory,
                mode: 0o600
            )
            try cloneOrCopy(
                rootfs,
                to: "rootfs.ext4",
                below: directory,
                mode: 0o600
            )
            try cloneOrCopy(
                gvproxy,
                to: "gvproxy",
                below: directory,
                mode: 0o500
            )
        }

        let executionResources = RuntimeLaunchEnvelope.RawHVExecutionResources.production(
            memoryMB: configuration.memoryMB,
            virtualCPUCount: configuration.virtualCPUCount
        )
        let definition = makeDefinition(
            configuration: configuration,
            systemDiskCapacityBytes: rootfs.byteCount
        )
        guard definition.validate().isEmpty else {
            throw DoryLinuxVMCalibrationError.definitionRejected
        }
        let devices = DoryDaemonVirtualMachinePlanningCoordinator.devices(for: definition)
        let topology = try DoryRawHVVirtualHardwareTopologyPlanner.resolve(
            definition: definition,
            resolvedDevices: devices
        )
        let launchPlan = LaunchPlan(
            schemaVersion: 1,
            qualificationMode: "calibration",
            verdict: "not-release-qualifying",
            definition: definition,
            devices: devices,
            topology: topology,
            executionResources: executionResources,
            runnerExecutable: ArtifactRecord(
                byteCount: runner.byteCount,
                sha256: runner.sha256,
                codeDirectoryHash: runnerCDHash.lowercaseHexadecimal
            ),
            rendererWorkerExecutable: ArtifactRecord(
                byteCount: worker.byteCount,
                sha256: worker.sha256,
                codeDirectoryHash: workerCDHash.lowercaseHexadecimal
            ),
            rendererCandidateInventorySHA256:
                rendererAdmission.candidateInventory.lowercaseSHA256,
            managedGuestKernel: ArtifactRecord(
                byteCount: kernel.byteCount,
                sha256: kernel.sha256
            ),
            mutableSystemDiskInput: ArtifactRecord(
                byteCount: rootfs.byteCount,
                sha256: rootfs.sha256
            ),
            gvproxyExecutable: ArtifactRecord(
                byteCount: gvproxy.byteCount,
                sha256: gvproxy.sha256
            ),
            rendererTupleDefinitionSHA256:
                DoryRendererSourceTuple.productionDefinitionSHA256
        )
        let launchPlanData = try canonicalData(launchPlan)
        let launchPlanSHA256 = sha256(launchPlanData)
        try workroot.withBorrowedDescriptor { directory in
            try writeExclusivePrivateFile(
                launchPlanData,
                named: planFileName,
                below: directory
            )
        }

        var components = rendererAdmission.qualifiedComponents.map {
            DoryResolvedBackendComponentEvidence(
                componentIdentifier: $0.componentIdentifier,
                buildIdentifier: $0.buildIdentifier,
                artifactSHA256: $0.artifactSHA256
            )
        }
        components.append(DoryResolvedBackendComponentEvidence(
            componentIdentifier: "dory-hv",
            buildIdentifier: runtimeBuildIdentifier,
            artifactSHA256: runner.sha256
        ))
        components.sort { $0.componentIdentifier < $1.componentIdentifier }

        let operationID = UUID()
        // The renderer bootstrap and envelope must bind the same operation/workspace identity.
        let exactResources: RawHVAdmittedRuntimeResources = try workroot
            .withBorrowedDescriptor { directory in
                try MachineManager.admitResolvedRawHVResources(
                    machineDirectoryDescriptor: directory,
                    machineDirectoryGeneration: workroot.identity,
                    expectedDiskCapacityBytes: rootfs.byteCount,
                    mediaKind: .linuxKernel,
                    expectedArtifactSHA256: kernel.sha256,
                    machineBootMode: .linuxKernel,
                    installerISOPath: nil,
                    rendererBootstrapRequest: RawHVRendererBootstrapRequest(
                        workspaceID: operationID,
                        generation: 1,
                        runtimeBuildIdentifier: runtimeBuildIdentifier,
                        components: components,
                        rendererWorkerCodeDirectoryHash: workerCDHash
                    )
                )
            }
        var exactResourcesTransferred = false
        defer {
            if !exactResourcesTransferred { exactResources.close() }
        }

        guard let systemDiskLogicalID = topology.occupiedSlots.first(where: {
            $0.role == .systemDisk
        })?.logicalID else {
            throw DoryLinuxVMCalibrationError.definitionRejected
        }
        let envelope = RuntimeLaunchEnvelope.resolvedRawHV(
            machineID: machineID,
            operationID: operationID,
            resolvedPlanSHA256: launchPlanSHA256,
            planRevision: 1,
            backendRuntimeBuildIdentifier: runtimeBuildIdentifier,
            virtualHardwareABIVersion:
                DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion,
            rawHVVirtualHardwareTopology: topology,
            graphics: .hardwareAccelerated3D,
            devices: devices,
            portForwards: [],
            executionResources: executionResources,
            systemDiskCapacityBytes: exactResources.disk.capacityBytes,
            systemDiskLogicalID: systemDiskLogicalID,
            linuxRootDevice: exactResources.boot.rootDevice,
            genericGuest: exactResources.boot.genericGuest,
            linuxKernelByteCount: exactResources.boot.kernel.byteCount,
            linuxKernelSHA256: exactResources.boot.kernel.sha256,
            linuxInitrdByteCount: exactResources.boot.initrd?.byteCount,
            linuxInitrdSHA256: exactResources.boot.initrd?.sha256,
            rendererBootstrapByteCount: exactResources.rendererBootstrap?.byteCount,
            rendererBootstrapSHA256: exactResources.rendererBootstrap?.sha256
        )
        _ = try envelope.validatedResolvedRawHVResources()

        let handoffPath = runtimeWorkrootPath + "/h.sock"
        let agentPath = runtimeWorkrootPath + "/a.sock"
        let shellPath = runtimeWorkrootPath + "/s.sock"
        let consolePath = runtimeWorkrootPath + "/o.sock"
        let controlPath = runtimeWorkrootPath + "/c.sock"
        let gvproxyClonePath = runtimeWorkrootPath + "/gvproxy"
        let handoffState = HandoffState()
        let handoffServer = VmmHandoffServer(path: handoffPath) {
            handoffState.publish($0)
        }
        try handoffServer.start()
        defer { handoffServer.stop() }

        var processConfiguration = HvProcessConfiguration(
            executablePath: runnerExecutablePath,
            arguments: [
                "desktop",
                "--machine-id", machineID,
                "--operation-id", DoryOperationIdentity.canonical(operationID),
                "--state-dir", runtimeWorkrootPath,
                "--agent-sock", agentPath,
                "--shell-sock", shellPath,
                "--console-sock", consolePath,
                "--control-sock", controlPath,
                "--display-mode", "desktop",
                "--runtime-launch-envelope", try envelope.encodedArgument(),
                "--gvproxy", gvproxyClonePath,
                "--handoff-sock", handoffPath,
            ],
            logPath: runtimeWorkrootPath + "/" + logFileName,
            restartPolicy: .none,
            runtimeLaunchEnvelope: envelope,
            inheritedFileDescriptors: [exactResources.disk.authority]
                + exactResources.boot.authorities
                + (exactResources.rendererBootstrap.map { [$0.authority] } ?? [])
        )
        processConfiguration.rendererReleaseIdentity = rendererReleaseIdentity
        let terminationState = TerminationState()
        let process = HvProcess(
            configuration: processConfiguration,
            unexpectedTerminationHandler: { terminationState.publish($0) }
        )
        exactResourcesTransferred = true
        try process.start()

        let handoffWait = handoffState.semaphore.wait(
            timeout: .now() + handoffTimeout
        )
        guard handoffWait == .success else {
            process.stop()
            if let termination = terminationState.read() {
                throw DoryLinuxVMCalibrationError.runtimeTerminated(
                    termination.description
                )
            }
            throw DoryLinuxVMCalibrationError.handoffTimedOut
        }
        guard let handoffResult = handoffState.read() else {
            process.stop()
            throw DoryLinuxVMCalibrationError.handoffRejected("empty outcome")
        }
        let ready: VmmReadyMessage
        do {
            ready = try handoffResult.get()
        } catch {
            process.stop()
            throw DoryLinuxVMCalibrationError.handoffRejected("\(error)")
        }
        guard ready.machineID == machineID,
              ready.operationID == DoryOperationIdentity.canonical(operationID),
              let graphics = ready.graphicsSelection,
              graphics.matchesResolvedRawHVLaunch(
                  operationID: operationID,
                  planSHA256: launchPlanSHA256,
                  planRevision: 1,
                  accelerationLevel: .hardwareAccelerated3D
              ),
              graphics.backend == .virglVenus else {
            process.stop()
            throw DoryLinuxVMCalibrationError.handoffRejected(
                "the synchronized hardware-3D receipt does not match this launch"
            )
        }
        process.disableRestarts()
        handoffServer.stop()

        guard let runnerPID = process.pid else {
            process.stop()
            throw DoryLinuxVMCalibrationError.runtimeTerminated(
                "runner exited after publishing readiness"
            )
        }
        let result = ResultReceipt(
            schemaVersion: 1,
            qualificationMode: "calibration",
            verdict: "not-release-qualifying",
            launchPlanSHA256: launchPlanSHA256,
            machineID: machineID,
            operationID: DoryOperationIdentity.canonical(operationID),
            runnerPID: runnerPID,
            readyAtUnixMilliseconds: Int64(
                (Date().timeIntervalSince1970 * 1_000).rounded(.towardZero)
            ),
            ready: ready
        )
        let resultData = try canonicalData(result)
        try workroot.withBorrowedDescriptor { directory in
            try writeExclusivePrivateFile(
                resultData,
                named: resultFileName,
                below: directory
            )
        }
        FileHandle.standardOutput.write(resultData + Data([0x0a]))

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signalQueue = DispatchQueue(label: "dev.dory.linux-calibration.signals")
        let interruptSource = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: signalQueue
        )
        let terminateSource = DispatchSource.makeSignalSource(
            signal: SIGTERM,
            queue: signalQueue
        )
        let stop: @Sendable () -> Void = {
            process.stop()
            terminationState.semaphore.signal()
        }
        interruptSource.setEventHandler(handler: stop)
        terminateSource.setEventHandler(handler: stop)
        interruptSource.resume()
        terminateSource.resume()
        terminationState.semaphore.wait()
        interruptSource.cancel()
        terminateSource.cancel()
        process.stop()
    }

    private static func validate(
        _ configuration: DoryLinuxVMCalibrationConfiguration
    ) throws {
        guard configuration.confirmation
                == DoryLinuxVMCalibrationConfiguration.requiredConfirmation else {
            throw DoryLinuxVMCalibrationError.invalidConfiguration(
                "the calibration-only confirmation is missing"
            )
        }
        for path in [
            configuration.runnerAppPath,
            configuration.kernelPath,
            configuration.rootfsPath,
            configuration.gvproxyPath,
            configuration.workrootPath,
        ] where !isCanonicalAbsolutePath(path) {
            throw DoryLinuxVMCalibrationError.unsafePath(path)
        }
        for (field, digest) in [
            ("kernelSHA256", configuration.kernelSHA256),
            ("rootfsSHA256", configuration.rootfsSHA256),
            ("gvproxySHA256", configuration.gvproxySHA256),
        ] where !isLowercaseSHA256(digest) {
            throw DoryLinuxVMCalibrationError.invalidConfiguration(
                "\(field) must be a canonical lowercase SHA-256"
            )
        }
        let memoryRange = RuntimeLaunchEnvelope.RawHVExecutionResources.minimumMemoryMB ...
            RuntimeLaunchEnvelope.RawHVExecutionResources.maximumMemoryMB
        guard memoryRange.contains(configuration.memoryMB) else {
            throw DoryLinuxVMCalibrationError.invalidConfiguration(
                "memoryMB \(configuration.memoryMB) is outside \(memoryRange)"
            )
        }
        let cpuRange = RuntimeLaunchEnvelope.RawHVExecutionResources.minimumVirtualCPUCount ...
            RuntimeLaunchEnvelope.RawHVExecutionResources.maximumVirtualCPUCount
        guard cpuRange.contains(configuration.virtualCPUCount) else {
            throw DoryLinuxVMCalibrationError.invalidConfiguration(
                "virtualCPUCount \(configuration.virtualCPUCount) is outside \(cpuRange)"
            )
        }
        let widthRange: ClosedRange<UInt32> =
            640...DoryVMDisplayConfiguration.maximumDimensionPixels
        guard widthRange.contains(configuration.displayWidthPixels) else {
            throw DoryLinuxVMCalibrationError.invalidConfiguration(
                "displayWidthPixels \(configuration.displayWidthPixels) is outside \(widthRange)"
            )
        }
        let heightRange: ClosedRange<UInt32> =
            480...DoryVMDisplayConfiguration.maximumDimensionPixels
        guard heightRange.contains(configuration.displayHeightPixels) else {
            throw DoryLinuxVMCalibrationError.invalidConfiguration(
                "displayHeightPixels \(configuration.displayHeightPixels) is outside \(heightRange)"
            )
        }
    }

    private static func makeDefinition(
        configuration: DoryLinuxVMCalibrationConfiguration,
        systemDiskCapacityBytes: UInt64
    ) -> DoryVirtualMachineDefinition {
        DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(
                id: machineID,
                name: "Linux Calibration"
            ),
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            workload: .desktop,
            boot: DoryVMBootConfiguration(
                phase: .normal,
                devices: [DoryVMBootMediaReference(
                    id: "system-kernel",
                    role: .system,
                    kind: .linuxKernel,
                    source: .bundledByDory,
                    artifact: DoryVMResolverReference(
                        namespace: "calibration",
                        identifier: configuration.kernelSHA256
                    ),
                    removable: false
                )],
                order: ["system-kernel"]
            ),
            backendPreference: DoryVMBackendPreference(
                mode: .required,
                backend: .doryHypervisor
            ),
            graphics: DoryVMGraphicsPolicy(
                acceptableLevels: [.hardwareAccelerated3D]
            ),
            resources: DoryVMResourceRequest(
                virtualCPUCount: UInt64(configuration.virtualCPUCount),
                memoryBytes: configuration.memoryMB * 1_048_576,
                diskBytes: systemDiskCapacityBytes
            ),
            storage: [DoryVMStorageAttachment(
                id: "system-disk",
                role: .system,
                artifact: DoryVMResolverReference(
                    namespace: "calibration",
                    identifier: configuration.rootfsSHA256
                ),
                source: .userProvided,
                capacityBytes: systemDiskCapacityBytes,
                readOnly: false
            )],
            networkMode: .sharedNAT,
            portForwards: [],
            displays: [DoryVMDisplayConfiguration(
                widthPixels: configuration.displayWidthPixels,
                heightPixels: configuration.displayHeightPixels,
                backingScaleFactor: 2,
                guestUIScaleFactor: 2
            )],
            audio: DoryVMAudioConfiguration(
                inputEnabled: true,
                outputEnabled: true
            ),
            camera: DoryVMCameraConfiguration(enabled: true),
            input: DoryVMInputConfiguration(
                keyboardEnabled: true,
                pointerEnabled: true
            ),
            shares: [],
            integrations: [
                .clockSynchronization,
                .dynamicDisplay,
                .gracefulShutdown,
            ],
            guestIdentityIntent: .unspecified,
            clipboardPolicy: .disabled,
            sandboxPolicy: nil,
            lifecycle: DoryVMLifecycleMetadata(
                revision: 1,
                createdAtUnixMilliseconds: 1,
                updatedAtUnixMilliseconds: 1
            )
        )
    }

    private static func createPrivateWorkroot(
        _ path: String
    ) throws -> DoryTrustedDirectoryRoot {
        guard isCanonicalAbsolutePath(path), path != "/" else {
            throw DoryLinuxVMCalibrationError.unsafePath(path)
        }
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT else {
            throw DoryLinuxVMCalibrationError.unsafePath(
                "workroot must not already exist: \(path)"
            )
        }
        guard mkdir(path, 0o700) == 0 else {
            throw DoryLinuxVMCalibrationError.filesystem(
                "could not create \(path): \(String(cString: strerror(errno)))"
            )
        }
        do {
            return try DoryTrustedDirectoryRoot(canonicalAbsolutePath: path)
        } catch {
            throw DoryLinuxVMCalibrationError.unsafePath("\(path): \(error)")
        }
    }

    private static func canonicalRuntimeWorkrootPath(
        for workroot: DoryTrustedDirectoryRoot
    ) throws -> String {
        // Foundation can choose a stable system alias for an existing object (for example,
        // `/private/tmp/...` becomes `/tmp/...`). Unix-socket validation applies that same
        // standardization after gvproxy creates its endpoint, so every child path must be derived
        // from the post-creation spelling rather than mixing the two aliases.
        let runtimePath = (workroot.canonicalPath as NSString).standardizingPath
        guard runtimePath != "/",
              isCanonicalAbsolutePath(runtimePath) else {
            throw DoryLinuxVMCalibrationError.unsafePath(runtimePath)
        }
        var status = stat()
        guard lstat(runtimePath, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o700,
              UInt64(truncatingIfNeeded: status.st_dev) == workroot.identity.device,
              UInt64(truncatingIfNeeded: status.st_ino) == workroot.identity.inode else {
            throw DoryLinuxVMCalibrationError.unsafePath(
                "runtime workroot alias does not retain the trusted directory identity: \(runtimePath)"
            )
        }
        return runtimePath
    }

    private static func cloneOrCopy(
        _ source: VerifiedInput,
        to name: String,
        below directory: Int32,
        mode: mode_t
    ) throws {
        guard !name.contains("/"), name != ".", name != ".." else {
            throw DoryLinuxVMCalibrationError.unsafePath(name)
        }
        let cloned = name.withCString {
            fclonefileat(source.descriptor, directory, $0, 0)
        }
        if cloned != 0 {
            let cloneError = errno
            _ = unlinkat(directory, name, 0)
            guard [ENOTSUP, EXDEV, EINVAL, ENOSYS].contains(cloneError) else {
                throw DoryLinuxVMCalibrationError.filesystem(
                    "could not clone \(source.path): \(String(cString: strerror(cloneError)))"
                )
            }
            try copyFileDescriptor(source, to: name, below: directory)
        }
        let destination = openat(
            directory,
            name,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard destination >= 0 else {
            _ = unlinkat(directory, name, 0)
            throw DoryLinuxVMCalibrationError.filesystem(
                "could not inspect cloned \(name)"
            )
        }
        defer { close(destination) }
        var destinationStatus = stat()
        var sourceAfter = stat()
        guard fchmod(destination, mode) == 0,
              fsync(destination) == 0,
              fstat(destination, &destinationStatus) == 0,
              destinationStatus.st_mode & S_IFMT == S_IFREG,
              destinationStatus.st_uid == geteuid(),
              destinationStatus.st_nlink == 1,
              destinationStatus.st_size == source.status.st_size,
              destinationStatus.st_mode & 0o077 == 0,
              fstat(source.descriptor, &sourceAfter) == 0,
              sameStableFile(source.status, sourceAfter) else {
            _ = unlinkat(directory, name, 0)
            throw DoryLinuxVMCalibrationError.filesystem(
                "cloned input \(name) failed exact object validation"
            )
        }
    }

    private static func copyFileDescriptor(
        _ source: VerifiedInput,
        to name: String,
        below directory: Int32
    ) throws {
        let destination = openat(
            directory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard destination >= 0 else {
            throw DoryLinuxVMCalibrationError.filesystem(
                "could not create fallback copy \(name)"
            )
        }
        var succeeded = false
        defer {
            close(destination)
            if !succeeded { _ = unlinkat(directory, name, 0) }
        }
        var buffer = Data(count: 4 * 1_024 * 1_024)
        var offset: off_t = 0
        while offset < source.status.st_size {
            let readCount: Int = try buffer.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else {
                    throw DoryLinuxVMCalibrationError.filesystem(
                        "could not allocate copy buffer"
                    )
                }
                let wanted = min(
                    bytes.count,
                    Int(source.status.st_size - offset)
                )
                while true {
                    let result = pread(source.descriptor, base, wanted, offset)
                    if result >= 0 { return result }
                    if errno != EINTR {
                        throw DoryLinuxVMCalibrationError.filesystem(
                            "could not read \(source.path)"
                        )
                    }
                }
            }
            guard readCount > 0 else {
                throw DoryLinuxVMCalibrationError.filesystem(
                    "input ended during fallback copy"
                )
            }
            try buffer.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < readCount {
                    let result = pwrite(
                        destination,
                        base.advanced(by: written),
                        readCount - written,
                        offset + off_t(written)
                    )
                    if result > 0 {
                        written += result
                    } else if result < 0, errno == EINTR {
                        continue
                    } else {
                        throw DoryLinuxVMCalibrationError.filesystem(
                            "could not write fallback copy \(name)"
                        )
                    }
                }
            }
            offset += off_t(readCount)
        }
        guard fsync(destination) == 0 else {
            throw DoryLinuxVMCalibrationError.filesystem(
                "could not synchronize fallback copy \(name)"
            )
        }
        succeeded = true
    }

    private static func verifiedCodeDirectoryHash(
        at path: String,
        requirement: String
    ) throws -> DoryCodeDirectoryHash {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: path) as CFURL,
            SecCSFlags(),
            &code
        ) == errSecSuccess, let code else {
            throw DoryLinuxVMCalibrationError.artifactMismatch(
                "code object \(path) is unavailable"
            )
        }
        var requirementObject: SecRequirement?
        guard SecRequirementCreateWithString(
            requirement as CFString,
            SecCSFlags(),
            &requirementObject
        ) == errSecSuccess,
        let requirementObject,
        SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirementObject
        ) == errSecSuccess else {
            throw DoryLinuxVMCalibrationError.artifactMismatch(
                "code requirement rejected \(path)"
            )
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [CFString: Any],
        let unique = values[kSecCodeInfoUnique] as? Data else {
            throw DoryLinuxVMCalibrationError.artifactMismatch(
                "code directory identity is unavailable for \(path)"
            )
        }
        return try DoryCodeDirectoryHash(bytes: unique, field: path)
    }

    private static func writeExclusivePrivateFile(
        _ data: Data,
        named name: String,
        below directory: Int32
    ) throws {
        let descriptor = openat(
            directory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw DoryLinuxVMCalibrationError.filesystem(
                "could not create \(name): \(String(cString: strerror(errno)))"
            )
        }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { _ = unlinkat(directory, name, 0) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw DoryLinuxVMCalibrationError.filesystem(
                        "could not write \(name)"
                    )
                }
            }
        }
        guard fsync(descriptor) == 0 else {
            throw DoryLinuxVMCalibrationError.filesystem(
                "could not synchronize \(name)"
            )
        }
        succeeded = true
    }

    private static func sha256Path(_ path: String) throws -> String {
        guard isCanonicalAbsolutePath(path) else {
            throw DoryLinuxVMCalibrationError.unsafePath(path)
        }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryLinuxVMCalibrationError.filesystem("could not open \(path)")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw DoryLinuxVMCalibrationError.unsafePath(path)
        }
        return try sha256Stable(descriptor: descriptor, expectedStatus: info)
    }

    private static func sha256Stable(
        descriptor: Int32,
        expectedStatus: stat
    ) throws -> String {
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = Data(count: 4 * 1_024 * 1_024)
        while offset < expectedStatus.st_size {
            let readCount: Int = try buffer.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else {
                    throw DoryLinuxVMCalibrationError.filesystem(
                        "could not allocate hash buffer"
                    )
                }
                let wanted = min(
                    bytes.count,
                    Int(expectedStatus.st_size - offset)
                )
                while true {
                    let result = pread(descriptor, base, wanted, offset)
                    if result >= 0 { return result }
                    if errno != EINTR {
                        throw DoryLinuxVMCalibrationError.filesystem(
                            "could not read artifact while hashing"
                        )
                    }
                }
            }
            guard readCount > 0 else {
                throw DoryLinuxVMCalibrationError.filesystem(
                    "artifact ended while hashing"
                )
            }
            hasher.update(data: buffer.prefix(readCount))
            offset += off_t(readCount)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameStableFile(expectedStatus, after) else {
            throw DoryLinuxVMCalibrationError.artifactMismatch(
                "artifact changed while hashing"
            )
        }
        return Data(hasher.finalize()).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func sameStableFile(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev
            && left.st_ino == right.st_ino
            && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
