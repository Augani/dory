import DoryVMContracts
import DoryRendererWorkerWireContracts
import Foundation

/// Immutable, versioned launch data shared by the daemon and runtime helper.
///
/// This contract contains resolved identity and named object-authority slots, never host paths.
public struct RuntimeLaunchEnvelope: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 5
    public static let maximumEncodedArgumentBytes = 65_536
    public static let systemDiskSlotName = "systemDisk"
    public static let linuxKernelSlotName = "linuxKernel"
    public static let linuxInitrdSlotName = "linuxInitrd"
    public static let rendererBootstrapSlotName = "rendererBootstrap"
    public static let systemDiskDescriptor: Int32 = 3
    public static let linuxKernelDescriptor: Int32 = 4
    public static let linuxInitrdDescriptor: Int32 = 5
    public static let rendererBootstrapDescriptor: Int32 = 6
    public static let maximumLinuxKernelBytes: UInt64 = 256 * 1_024 * 1_024
    public static let maximumLinuxInitrdBytes: UInt64 = 512 * 1_024 * 1_024
    private static let zeroOperationID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    public enum Kind: String, Codable, Sendable, Equatable {
        case resolvedVirtualMachine = "resolved-virtual-machine"
    }

    public enum DescriptorAccess: String, Codable, Sendable, Equatable {
        case readOnly
        case readWrite
    }

    public struct InheritedFileDescriptorSlot: Codable, Sendable, Equatable {
        public let name: String
        public let descriptor: Int32
        public let access: DescriptorAccess
        /// Exact size of the opened object. For the mutable system disk this is its advertised
        /// capacity; for immutable boot blobs this is the complete hashed byte count.
        public let byteCount: UInt64
        /// Present only for immutable boot blobs. The mutable disk is bound by object identity,
        /// exclusive lease, capacity, and virtual-device identity instead of a launch-time digest.
        public let contentSHA256: String?
        /// Guest-visible identity for descriptor-backed virtual devices. Boot blobs are payloads,
        /// not devices, and therefore leave this field nil.
        public let logicalDeviceID: DoryVirtualDeviceID?

        public init(
            name: String,
            descriptor: Int32,
            access: DescriptorAccess,
            byteCount: UInt64,
            contentSHA256: String? = nil,
            logicalDeviceID: DoryVirtualDeviceID? = nil
        ) {
            self.name = name
            self.descriptor = descriptor
            self.access = access
            self.byteCount = byteCount
            self.contentSHA256 = contentSHA256
            self.logicalDeviceID = logicalDeviceID
        }

        /// Source-compatible spelling for callers that treat the system-disk length as capacity.
        public var capacityBytes: UInt64 { byteCount }
    }

    /// Immutable direct-boot policy. Resolved helpers derive their command line from this value;
    /// split CLI flags are accepted only by the explicitly legacy pathname launch mode.
    public enum LinuxDirectBootProfile: String, Codable, Sendable, Equatable {
        case managedKernel = "managed-kernel"
        case installedLinuxBundle = "installed-linux-bundle"
    }

    public struct LinuxDirectBoot: Codable, Sendable, Equatable {
        public let rootDevice: String
        public let profile: LinuxDirectBootProfile

        public var genericGuest: Bool { profile == .installedLinuxBundle }

        public init(rootDevice: String, genericGuest: Bool) {
            self.rootDevice = rootDevice
            self.profile = genericGuest ? .installedLinuxBundle : .managedKernel
        }

        public init(rootDevice: String, profile: LinuxDirectBootProfile) {
            self.rootDevice = rootDevice
            self.profile = profile
        }
    }

    public struct ResolvedRawHVResources: Sendable, Equatable {
        public let systemDisk: InheritedFileDescriptorSlot
        public let linuxKernel: InheritedFileDescriptorSlot
        public let linuxInitrd: InheritedFileDescriptorSlot?
        /// Exact one-shot renderer authority. It is present only for a resolved hardware-3D
        /// launch and is consumed before the VM or its vCPUs start.
        public let rendererBootstrap: InheritedFileDescriptorSlot?
    }

    /// Exact compute and storage-parallelism authority for one resolved RawHV launch.
    ///
    /// These values live in the canonical envelope rather than in ambient defaults or an
    /// independent command-line policy. The helper therefore cannot silently advertise a
    /// different block topology from the candidate-bound CPU and memory allocation.
    public struct RawHVExecutionResources: Codable, Sendable, Equatable {
        public static let minimumMemoryMB: UInt64 = 1_024
        public static let maximumMemoryMB: UInt64 = 16 * 1_024
        public static let minimumVirtualCPUCount: UInt16 = 1
        public static let maximumVirtualCPUCount: UInt16 = 8
        public static let maximumSystemDiskQueueCount: UInt16 = 16
        public static let currentSchedulingPolicyRevision: UInt16 = 1

        public let memoryMB: UInt64
        public let virtualCPUCount: UInt16
        public let systemDiskQueueCount: UInt16
        public let schedulingPolicyRevision: UInt16

        public init(
            memoryMB: UInt64,
            virtualCPUCount: UInt16,
            systemDiskQueueCount: UInt16,
            schedulingPolicyRevision: UInt16 = Self.currentSchedulingPolicyRevision
        ) {
            self.memoryMB = memoryMB
            self.virtualCPUCount = virtualCPUCount
            self.systemDiskQueueCount = systemDiskQueueCount
            self.schedulingPolicyRevision = schedulingPolicyRevision
        }

        /// Current production policy exposes one system-disk queue per admitted vCPU. The exact
        /// result is serialized into the envelope so changing this policy requires a new plan and
        /// produces a different launch identity rather than changing an existing run in place.
        public static func production(
            memoryMB: UInt64,
            virtualCPUCount: UInt16
        ) -> Self {
            Self(
                memoryMB: memoryMB,
                virtualCPUCount: virtualCPUCount,
                systemDiskQueueCount: min(
                    maximumSystemDiskQueueCount,
                    virtualCPUCount
                )
            )
        }

        fileprivate var isValid: Bool {
            (Self.minimumMemoryMB...Self.maximumMemoryMB).contains(memoryMB)
                && (Self.minimumVirtualCPUCount...Self.maximumVirtualCPUCount)
                    .contains(virtualCPUCount)
                && (1...Self.maximumSystemDiskQueueCount)
                    .contains(systemDiskQueueCount)
                && systemDiskQueueCount <= virtualCPUCount
                && schedulingPolicyRevision == Self.currentSchedulingPolicyRevision
        }
    }

    public let kind: Kind
    public let schemaVersion: UInt16
    public let machineID: String
    public let operationID: UUID
    public let resolvedPlanSHA256: String
    public let planRevision: UInt64
    public let backendIdentity: DoryVirtualizationBackendIdentity
    public let backendRuntimeBuildIdentifier: String
    public let virtualHardwareABIVersion: UInt16
    public let rawHVVirtualHardwareTopology: DoryRawHVVirtualHardwareTopology
    public let graphics: DoryGraphicsAccelerationLevel
    public let devices: DoryVirtualMachineDeviceCapabilityRequest
    public let portForwards: [DoryVMPortForward]
    public let executionResources: RawHVExecutionResources
    public let linuxDirectBoot: LinuxDirectBoot
    public let inheritedFileDescriptors: [InheritedFileDescriptorSlot]

    public init(
        kind: Kind = .resolvedVirtualMachine,
        schemaVersion: UInt16 = RuntimeLaunchEnvelope.currentSchemaVersion,
        machineID: String,
        operationID: UUID,
        resolvedPlanSHA256: String,
        planRevision: UInt64,
        backendIdentity: DoryVirtualizationBackendIdentity,
        backendRuntimeBuildIdentifier: String,
        virtualHardwareABIVersion: UInt16,
        rawHVVirtualHardwareTopology: DoryRawHVVirtualHardwareTopology,
        graphics: DoryGraphicsAccelerationLevel,
        devices: DoryVirtualMachineDeviceCapabilityRequest,
        portForwards: [DoryVMPortForward],
        executionResources: RawHVExecutionResources,
        linuxDirectBoot: LinuxDirectBoot,
        inheritedFileDescriptors: [InheritedFileDescriptorSlot]
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.machineID = machineID
        self.operationID = operationID
        self.resolvedPlanSHA256 = resolvedPlanSHA256
        self.planRevision = planRevision
        self.backendIdentity = backendIdentity
        self.backendRuntimeBuildIdentifier = backendRuntimeBuildIdentifier
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.rawHVVirtualHardwareTopology = rawHVVirtualHardwareTopology
        self.graphics = graphics
        self.devices = devices
        self.portForwards = portForwards
        self.executionResources = executionResources
        self.linuxDirectBoot = linuxDirectBoot
        self.inheritedFileDescriptors = inheritedFileDescriptors
    }

    public static func resolvedRawHV(
        machineID: String,
        operationID: UUID,
        resolvedPlanSHA256: String,
        planRevision: UInt64,
        backendRuntimeBuildIdentifier: String,
        virtualHardwareABIVersion: UInt16,
        rawHVVirtualHardwareTopology: DoryRawHVVirtualHardwareTopology,
        graphics: DoryGraphicsAccelerationLevel,
        devices: DoryVirtualMachineDeviceCapabilityRequest,
        portForwards: [DoryVMPortForward],
        executionResources: RawHVExecutionResources,
        systemDiskCapacityBytes: UInt64,
        systemDiskLogicalID: DoryVirtualDeviceID,
        linuxRootDevice: String,
        genericGuest: Bool,
        linuxKernelByteCount: UInt64,
        linuxKernelSHA256: String,
        linuxInitrdByteCount: UInt64? = nil,
        linuxInitrdSHA256: String? = nil,
        rendererBootstrapByteCount: UInt64? = nil,
        rendererBootstrapSHA256: String? = nil
    ) -> Self {
        var descriptorSlots = [
            InheritedFileDescriptorSlot(
                name: systemDiskSlotName,
                descriptor: systemDiskDescriptor,
                access: .readWrite,
                byteCount: systemDiskCapacityBytes,
                logicalDeviceID: systemDiskLogicalID
            ),
            InheritedFileDescriptorSlot(
                name: linuxKernelSlotName,
                descriptor: linuxKernelDescriptor,
                access: .readOnly,
                byteCount: linuxKernelByteCount,
                contentSHA256: linuxKernelSHA256
            ),
        ]
        if linuxInitrdByteCount != nil || linuxInitrdSHA256 != nil {
            descriptorSlots.append(InheritedFileDescriptorSlot(
                name: linuxInitrdSlotName,
                descriptor: linuxInitrdDescriptor,
                access: .readOnly,
                byteCount: linuxInitrdByteCount ?? 0,
                contentSHA256: linuxInitrdSHA256
            ))
        }
        if rendererBootstrapByteCount != nil || rendererBootstrapSHA256 != nil {
            descriptorSlots.append(InheritedFileDescriptorSlot(
                name: rendererBootstrapSlotName,
                descriptor: rendererBootstrapDescriptor,
                access: .readOnly,
                byteCount: rendererBootstrapByteCount ?? 0,
                contentSHA256: rendererBootstrapSHA256
            ))
        }
        return Self(
            machineID: machineID,
            operationID: operationID,
            resolvedPlanSHA256: resolvedPlanSHA256,
            planRevision: planRevision,
            backendIdentity: .doryHypervisor,
            backendRuntimeBuildIdentifier: backendRuntimeBuildIdentifier,
            virtualHardwareABIVersion: virtualHardwareABIVersion,
            rawHVVirtualHardwareTopology: rawHVVirtualHardwareTopology,
            graphics: graphics,
            devices: devices,
            portForwards: portForwards,
            executionResources: executionResources,
            linuxDirectBoot: LinuxDirectBoot(
                rootDevice: linuxRootDevice,
                genericGuest: genericGuest
            ),
            inheritedFileDescriptors: descriptorSlots
        )
    }

    public func validatedResolvedRawHVResources() throws -> ResolvedRawHVResources {
        guard kind == .resolvedVirtualMachine else {
            throw RuntimeLaunchEnvelopeError.invalidKind
        }
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RuntimeLaunchEnvelopeError.unsupportedSchemaVersion(schemaVersion)
        }
        guard Self.isSafeMachineIdentifier(machineID),
              operationID != Self.zeroOperationID,
              Self.isSafeEvidenceIdentifier(backendRuntimeBuildIdentifier),
              planRevision > 0,
              virtualHardwareABIVersion > 0 else {
            throw RuntimeLaunchEnvelopeError.invalidIdentity
        }
        guard backendIdentity == .doryHypervisor else {
            throw RuntimeLaunchEnvelopeError.invalidBackend(backendIdentity)
        }
        guard virtualHardwareABIVersion == 1,
              rawHVVirtualHardwareTopology.abiVersion == .rawHVARM64V1,
              rawHVVirtualHardwareTopology.backend == .rawHV,
              rawHVVirtualHardwareTopology.architecture == .arm64 else {
            throw RuntimeLaunchEnvelopeError.invalidVirtualHardwareTopology
        }
        let roleCounts = Dictionary(
            grouping: rawHVVirtualHardwareTopology.occupiedSlots,
            by: \.role
        ).mapValues(\.count)
        func count(_ role: DoryVirtualDeviceRole) -> Int {
            roleCounts[role, default: 0]
        }
        guard graphics != .none,
              devices.displays.isEmpty == false,
              devices.audioInput == devices.audioOutput,
              devices.networkInterface?.isValid == true,
              devices.networkAttachment != .bridged,
              count(.systemDisk) == 1,
              count(.graphics) == 1,
              count(.entropy) == 1,
              count(.balloon) == 1,
              count(.vsock) == 1,
              count(.keyboard) == (devices.keyboard ? 1 : 0),
              count(.pointer) == (devices.pointer ? 1 : 0),
              count(.audio) == (devices.audioInput ? 1 : 0),
              count(.network) == 1,
              devices.directorySharing == (count(.directoryShare) > 0),
              count(.auxiliaryBlock) == 0,
              count(.removableStorage) == 0,
              count(.usbController) == 0 else {
            throw RuntimeLaunchEnvelopeError.invalidVirtualHardwareTopology
        }
        let fixedRoles: [DoryVirtualDeviceRole] = [
            .graphics, .entropy, .balloon, .vsock, .keyboard, .pointer, .audio,
        ]
        guard fixedRoles.allSatisfy({ role in
            let matches = rawHVVirtualHardwareTopology.occupiedSlots.filter {
                $0.role == role
            }
            return matches.isEmpty
                || (matches.count == 1
                    && matches[0].logicalID.rawValue == "rawhv-\(role.rawValue)")
        }),
        let networkInterface = devices.networkInterface,
        let expectedNetworkID = try? DoryVirtualDeviceID.derived(
            namespace: .network,
            stableID: networkInterface.id
        ),
        rawHVVirtualHardwareTopology.occupiedSlots.contains(where: {
            $0.role == .network && $0.logicalID == expectedNetworkID
        }) else {
            throw RuntimeLaunchEnvelopeError.invalidVirtualHardwareTopology
        }
        guard resolvedPlanSHA256.count == 64,
              resolvedPlanSHA256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw RuntimeLaunchEnvelopeError.invalidPlanSHA256
        }
        guard executionResources.isValid else {
            throw RuntimeLaunchEnvelopeError.invalidExecutionResources
        }

        var names: Set<String> = []
        var descriptors: Set<Int32> = []
        for slot in inheritedFileDescriptors {
            guard !slot.name.isEmpty else {
                throw RuntimeLaunchEnvelopeError.invalidSlotName
            }
            guard slot.descriptor >= 3 else {
                throw RuntimeLaunchEnvelopeError.invalidDescriptor(slot.descriptor)
            }
            guard names.insert(slot.name).inserted else {
                throw RuntimeLaunchEnvelopeError.duplicateSlotName(slot.name)
            }
            guard descriptors.insert(slot.descriptor).inserted else {
                throw RuntimeLaunchEnvelopeError.duplicateDescriptor(slot.descriptor)
            }
            guard slot.byteCount > 0 else {
                throw RuntimeLaunchEnvelopeError.invalidCapacity(slot.name)
            }
        }
        let rendererBootstrap = inheritedFileDescriptors.first {
            $0.name == Self.rendererBootstrapSlotName
        }
        guard (graphics == .hardwareAccelerated3D) == (rendererBootstrap != nil) else {
            throw RuntimeLaunchEnvelopeError.invalidRendererBootstrapAuthority
        }
        var expectedSlotNames = [Self.systemDiskSlotName, Self.linuxKernelSlotName]
        if inheritedFileDescriptors.contains(where: {
            $0.name == Self.linuxInitrdSlotName
        }) {
            expectedSlotNames.append(Self.linuxInitrdSlotName)
        }
        if graphics == .hardwareAccelerated3D {
            expectedSlotNames.append(Self.rendererBootstrapSlotName)
        }
        guard inheritedFileDescriptors.map(\.name) == expectedSlotNames else {
            throw RuntimeLaunchEnvelopeError.invalidResolvedRawHVSlots
        }
        let systemDisk = inheritedFileDescriptors[0]
        let linuxKernel = inheritedFileDescriptors[1]
        let linuxInitrd = inheritedFileDescriptors.first {
            $0.name == Self.linuxInitrdSlotName
        }
        guard systemDisk.descriptor == Self.systemDiskDescriptor else {
            throw RuntimeLaunchEnvelopeError.invalidDescriptor(systemDisk.descriptor)
        }
        guard systemDisk.access == .readWrite,
              systemDisk.contentSHA256 == nil,
              let systemDiskLogicalID = systemDisk.logicalDeviceID,
              rawHVVirtualHardwareTopology.occupiedSlots.contains(where: {
                  $0.role == .systemDisk && $0.logicalID == systemDiskLogicalID
              }) else {
            throw RuntimeLaunchEnvelopeError.invalidSystemDiskAccess
        }
        guard linuxKernel.descriptor == Self.linuxKernelDescriptor else {
            throw RuntimeLaunchEnvelopeError.invalidDescriptor(linuxKernel.descriptor)
        }
        guard linuxKernel.access == .readOnly,
              linuxKernel.logicalDeviceID == nil,
              linuxKernel.byteCount <= Self.maximumLinuxKernelBytes,
              Self.isLowercaseSHA256(linuxKernel.contentSHA256) else {
            throw RuntimeLaunchEnvelopeError.invalidLinuxKernelAuthority
        }
        if let linuxInitrd {
            guard linuxInitrd.descriptor == Self.linuxInitrdDescriptor else {
                throw RuntimeLaunchEnvelopeError.invalidDescriptor(linuxInitrd.descriptor)
            }
            guard linuxInitrd.access == .readOnly,
                  linuxInitrd.logicalDeviceID == nil,
                  linuxInitrd.byteCount <= Self.maximumLinuxInitrdBytes,
                  Self.isLowercaseSHA256(linuxInitrd.contentSHA256) else {
                throw RuntimeLaunchEnvelopeError.invalidLinuxInitrdAuthority
            }
        }
        if let rendererBootstrap {
            guard rendererBootstrap.descriptor == Self.rendererBootstrapDescriptor else {
                throw RuntimeLaunchEnvelopeError.invalidDescriptor(
                    rendererBootstrap.descriptor
                )
            }
            guard rendererBootstrap.access == .readOnly,
                  rendererBootstrap.logicalDeviceID == nil,
                  rendererBootstrap.byteCount
                    == UInt64(DoryRendererWorkerBootstrapCodec.fixedByteCount),
                  Self.isLowercaseSHA256(rendererBootstrap.contentSHA256) else {
                throw RuntimeLaunchEnvelopeError.invalidRendererBootstrapAuthority
            }
        }
        guard Self.isValidLinuxRootDevice(linuxDirectBoot.rootDevice) else {
            throw RuntimeLaunchEnvelopeError.invalidLinuxDirectBoot
        }
        switch linuxDirectBoot.profile {
        case .managedKernel:
            guard linuxDirectBoot.rootDevice == "/dev/vda", linuxInitrd == nil else {
                throw RuntimeLaunchEnvelopeError.invalidLinuxDirectBoot
            }
        case .installedLinuxBundle:
            guard linuxDirectBoot.rootDevice != "/dev/vda", linuxInitrd != nil else {
                throw RuntimeLaunchEnvelopeError.invalidLinuxDirectBoot
            }
        }
        return ResolvedRawHVResources(
            systemDisk: systemDisk,
            linuxKernel: linuxKernel,
            linuxInitrd: linuxInitrd,
            rendererBootstrap: rendererBootstrap
        )
    }

    public func validatedResolvedRawHVSystemDisk() throws -> InheritedFileDescriptorSlot {
        try validatedResolvedRawHVResources().systemDisk
    }

    public func encodedArgument() throws -> String {
        _ = try validatedResolvedRawHVResources()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedArgumentBytes else {
            throw RuntimeLaunchEnvelopeError.argumentTooLarge(data.count)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw RuntimeLaunchEnvelopeError.invalidEncoding
        }
        return value
    }

    public static func decodeResolvedRawHVArgument(_ value: String) throws -> Self {
        guard let data = value.data(using: .utf8) else {
            throw RuntimeLaunchEnvelopeError.invalidEncoding
        }
        guard data.count <= Self.maximumEncodedArgumentBytes else {
            throw RuntimeLaunchEnvelopeError.argumentTooLarge(data.count)
        }
        let envelope = try JSONDecoder().decode(Self.self, from: data)
        _ = try envelope.validatedResolvedRawHVResources()
        // Unknown keys, duplicate-key spellings, whitespace, and alternate UUID/JSON forms are
        // not accepted at this authority boundary. Both sides consume one exact representation.
        guard try envelope.encodedArgument() == value else {
            throw RuntimeLaunchEnvelopeError.nonCanonicalEncoding
        }
        return envelope
    }

    private static func isSafeMachineIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...63).contains(bytes.count), let first = bytes.first,
              isASCIIAlphaNumeric(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isLowercaseSHA256(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isValidLinuxRootDevice(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 8,
              Array(bytes.prefix(7)) == Array("/dev/vd".utf8),
              let disk = bytes.dropFirst(7).first,
              (97...122).contains(disk) else {
            return false
        }
        let suffix = bytes.dropFirst(8)
        guard let first = suffix.first else { return true }
        guard (49...57).contains(first) else { return false }
        return suffix.dropFirst().allSatisfy { (48...57).contains($0) }
    }

    /// Matches the resolved-plan evidence identifier grammar. Production build identities are
    /// normally `sha256:<lowercase digest>`, while already-valid persisted plans may use another
    /// bounded identifier (for example a signed release/build label).
    private static func isSafeEvidenceIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...256).contains(bytes.count) else { return false }
        return bytes.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 47
                || $0 == 44 || $0 == 58 || $0 == 64 || $0 == 95
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }
}

public enum RuntimeLaunchEnvelopeError: Error, CustomStringConvertible, Equatable {
    case invalidKind
    case unsupportedSchemaVersion(UInt16)
    case invalidIdentity
    case invalidBackend(DoryVirtualizationBackendIdentity)
    case invalidVirtualHardwareTopology
    case invalidPlanSHA256
    case invalidExecutionResources
    case invalidSlotName
    case duplicateSlotName(String)
    case invalidDescriptor(Int32)
    case duplicateDescriptor(Int32)
    case invalidCapacity(String)
    case invalidResolvedRawHVSlots
    case invalidSystemDiskAccess
    case invalidLinuxKernelAuthority
    case invalidLinuxInitrdAuthority
    case invalidRendererBootstrapAuthority
    case invalidLinuxDirectBoot
    case invalidEncoding
    case argumentTooLarge(Int)
    case nonCanonicalEncoding

    public var description: String {
        switch self {
        case .invalidKind:
            return "runtime launch envelope kind is not a resolved virtual machine"
        case .unsupportedSchemaVersion(let version):
            return "unsupported runtime launch envelope schema version \(version)"
        case .invalidIdentity:
            return "runtime launch envelope identity is incomplete"
        case .invalidBackend(let backend):
            return "runtime launch envelope backend \(backend.rawValue) is not raw-HV"
        case .invalidVirtualHardwareTopology:
            return "runtime launch envelope virtual-hardware topology is not RawHV ARM64 ABI v1"
        case .invalidPlanSHA256:
            return "runtime launch envelope plan SHA-256 is invalid"
        case .invalidExecutionResources:
            return "runtime launch envelope compute or system-disk queue authority is invalid"
        case .invalidSlotName:
            return "runtime launch envelope contains an empty descriptor slot name"
        case .duplicateSlotName(let name):
            return "runtime launch envelope repeats descriptor slot \(name)"
        case .invalidDescriptor(let descriptor):
            return "runtime launch envelope contains invalid descriptor \(descriptor)"
        case .duplicateDescriptor(let descriptor):
            return "runtime launch envelope repeats descriptor \(descriptor)"
        case .invalidCapacity(let name):
            return "runtime launch envelope slot \(name) has no capacity"
        case .invalidResolvedRawHVSlots:
            return "resolved raw-HV launch requires ordered systemDisk, linuxKernel, and optional linuxInitrd descriptor slots"
        case .invalidSystemDiskAccess:
            return "resolved raw-HV systemDisk must be read-write and bound to its topology identity"
        case .invalidLinuxKernelAuthority:
            return "resolved raw-HV linuxKernel must be a bounded read-only exact-digest blob"
        case .invalidLinuxInitrdAuthority:
            return "resolved raw-HV linuxInitrd must be a bounded read-only exact-digest blob"
        case .invalidRendererBootstrapAuthority:
            return "resolved raw-HV hardware-3D launch requires one exact renderer bootstrap blob"
        case .invalidLinuxDirectBoot:
            return "resolved raw-HV direct-boot policy is invalid"
        case .invalidEncoding:
            return "runtime launch envelope is not valid UTF-8 JSON"
        case .argumentTooLarge(let byteCount):
            return "runtime launch envelope is too large (\(byteCount) bytes)"
        case .nonCanonicalEncoding:
            return "runtime launch envelope JSON is not canonical"
        }
    }
}
