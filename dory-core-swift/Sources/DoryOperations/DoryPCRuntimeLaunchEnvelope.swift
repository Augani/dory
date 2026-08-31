import DoryFirmware
import DoryMachinePC
import DoryRendererWorkerWireContracts
import DoryVMContracts
import Foundation

/// Canonical descriptor-only launch authority for one DoryPC-v1 machine running through DBT.
/// Host paths never cross this boundary.
public struct DoryPCRuntimeLaunchEnvelope: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let maximumEncodedArgumentBytes = 65_536

    public enum ExecutionTier: String, Codable, Sendable, Equatable {
        case interpreter
        case baselineJIT = "baseline-jit"
        case optimizingJIT = "optimizing-jit"
    }

    public struct ExecutionResources: Codable, Sendable, Equatable {
        public static let currentSchedulingPolicyRevision: UInt16 = 1

        public let memoryMB: UInt64
        public let virtualCPUCount: UInt16
        public let tier: ExecutionTier
        public let schedulingPolicyRevision: UInt16

        public init(
            memoryMB: UInt64,
            virtualCPUCount: UInt16,
            tier: ExecutionTier,
            schedulingPolicyRevision: UInt16 = Self.currentSchedulingPolicyRevision
        ) {
            self.memoryMB = memoryMB
            self.virtualCPUCount = virtualCPUCount
            self.tier = tier
            self.schedulingPolicyRevision = schedulingPolicyRevision
        }

        fileprivate var isValid: Bool {
            let (memoryBytes, overflow) = memoryMB.multipliedReportingOverflow(by: 1_024 * 1_024)
            return !overflow
                && (try? DoryPCV1ABI.validateProductMemoryBytes(memoryBytes)) != nil
                && (try? DoryPCV1ABI.validateVCPUCount(Int(virtualCPUCount))) != nil
                && schedulingPolicyRevision == Self.currentSchedulingPolicyRevision
        }
    }

    public struct ResolvedResources: Sendable, Equatable {
        public let systemDisk: RuntimeLaunchEnvelope.InheritedFileDescriptorSlot
        public let firmwareCode: RuntimeLaunchEnvelope.InheritedFileDescriptorSlot
        public let variableStoreTemplate: RuntimeLaunchEnvelope.InheritedFileDescriptorSlot
        public let firmwareSBOM: RuntimeLaunchEnvelope.InheritedFileDescriptorSlot
        public let installerMedia: RuntimeLaunchEnvelope.InheritedFileDescriptorSlot?
        public let variableStoreDirectory: RuntimeLaunchEnvelope.InheritedDirectoryDescriptorSlot
        public let rendererBootstrap: RuntimeLaunchEnvelope.InheritedFileDescriptorSlot?
    }

    public let schemaVersion: UInt16
    public let machineID: String
    public let operationID: UUID
    public let resolvedPlanSHA256: String
    public let planRevision: UInt64
    public let platform: DoryVirtualizationPlatformComposition
    public let executionComponentBuildIdentifier: String
    public let virtualHardwareABIVersion: UInt16
    public let graphics: DoryGraphicsAccelerationLevel
    public let devices: DoryVirtualMachineDeviceCapabilityRequest
    public let portForwards: [DoryVMPortForward]
    public let executionResources: ExecutionResources
    public let launchPlan: DoryPCUEFILaunchPlan
    public let inheritedFileDescriptors: [RuntimeLaunchEnvelope.InheritedFileDescriptorSlot]
    public let inheritedDirectoryDescriptors: [RuntimeLaunchEnvelope.InheritedDirectoryDescriptorSlot]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        machineID: String,
        operationID: UUID,
        resolvedPlanSHA256: String,
        planRevision: UInt64,
        executionComponentBuildIdentifier: String,
        virtualHardwareABIVersion: UInt16,
        graphics: DoryGraphicsAccelerationLevel,
        devices: DoryVirtualMachineDeviceCapabilityRequest,
        portForwards: [DoryVMPortForward],
        executionResources: ExecutionResources,
        launchPlan: DoryPCUEFILaunchPlan,
        inheritedFileDescriptors: [RuntimeLaunchEnvelope.InheritedFileDescriptorSlot],
        inheritedDirectoryDescriptors: [RuntimeLaunchEnvelope.InheritedDirectoryDescriptorSlot]
    ) {
        self.schemaVersion = schemaVersion
        self.machineID = machineID
        self.operationID = operationID
        self.resolvedPlanSHA256 = resolvedPlanSHA256
        self.planRevision = planRevision
        platform = .x86_64LinuxV1
        self.executionComponentBuildIdentifier = executionComponentBuildIdentifier
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.graphics = graphics
        self.devices = devices
        self.portForwards = portForwards
        self.executionResources = executionResources
        self.launchPlan = launchPlan
        self.inheritedFileDescriptors = inheritedFileDescriptors
        self.inheritedDirectoryDescriptors = inheritedDirectoryDescriptors
    }

    public static func resolvedUEFI(
        machineID: String,
        operationID: UUID,
        resolvedPlanSHA256: String,
        planRevision: UInt64,
        executionComponentBuildIdentifier: String,
        virtualHardwareABIVersion: UInt16,
        graphics: DoryGraphicsAccelerationLevel,
        devices: DoryVirtualMachineDeviceCapabilityRequest,
        portForwards: [DoryVMPortForward],
        executionResources: ExecutionResources,
        systemDiskCapacityBytes: UInt64,
        systemDiskLogicalID: DoryVirtualDeviceID,
        launchPlan: DoryPCUEFILaunchPlan,
        firmwareSBOMByteCount: UInt64,
        installerMediaByteCount: UInt64? = nil,
        installerMediaSHA256: String? = nil,
        installerMediaLogicalID: DoryVirtualDeviceID? = nil,
        rendererBootstrapByteCount: UInt64? = nil,
        rendererBootstrapSHA256: String? = nil
    ) -> Self {
        var files = [
            RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
                name: RuntimeLaunchEnvelope.systemDiskSlotName,
                descriptor: RuntimeLaunchEnvelope.systemDiskDescriptor,
                access: .readWrite,
                byteCount: systemDiskCapacityBytes,
                logicalDeviceID: systemDiskLogicalID
            ),
            RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
                name: RuntimeLaunchEnvelope.firmwareCodeSlotName,
                descriptor: RuntimeLaunchEnvelope.firmwareCodeDescriptor,
                access: .readOnly,
                byteCount: launchPlan.firmware.firmwareCodeByteCount,
                contentSHA256: launchPlan.firmware.firmwareCodeSHA256
            ),
            RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
                name: RuntimeLaunchEnvelope.variableStoreTemplateSlotName,
                descriptor: RuntimeLaunchEnvelope.variableStoreTemplateDescriptor,
                access: .readOnly,
                byteCount: launchPlan.firmware.variableStoreTemplateByteCount,
                contentSHA256: launchPlan.firmware.variableStoreTemplateSHA256
            ),
            RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
                name: RuntimeLaunchEnvelope.firmwareSBOMSlotName,
                descriptor: RuntimeLaunchEnvelope.firmwareSBOMDescriptor,
                access: .readOnly,
                byteCount: firmwareSBOMByteCount,
                contentSHA256: launchPlan.firmware.sbomSHA256
            ),
        ]
        if installerMediaByteCount != nil || installerMediaSHA256 != nil
            || installerMediaLogicalID != nil {
            files.append(RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
                name: RuntimeLaunchEnvelope.installerMediaSlotName,
                descriptor: RuntimeLaunchEnvelope.installerMediaDescriptor,
                access: .readOnly,
                byteCount: installerMediaByteCount ?? 0,
                contentSHA256: installerMediaSHA256,
                logicalDeviceID: installerMediaLogicalID
            ))
        }
        if rendererBootstrapByteCount != nil || rendererBootstrapSHA256 != nil {
            files.append(RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
                name: RuntimeLaunchEnvelope.rendererBootstrapSlotName,
                descriptor: RuntimeLaunchEnvelope.uefiRendererBootstrapDescriptor,
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
            executionComponentBuildIdentifier: executionComponentBuildIdentifier,
            virtualHardwareABIVersion: virtualHardwareABIVersion,
            graphics: graphics,
            devices: devices,
            portForwards: portForwards,
            executionResources: executionResources,
            launchPlan: launchPlan,
            inheritedFileDescriptors: files,
            inheritedDirectoryDescriptors: [
                RuntimeLaunchEnvelope.InheritedDirectoryDescriptorSlot(
                    name: RuntimeLaunchEnvelope.variableStoreDirectorySlotName,
                    descriptor: RuntimeLaunchEnvelope.variableStoreDirectoryDescriptor,
                    access: .readWrite
                )
            ]
        )
    }

    public func validatedResources() throws -> ResolvedResources {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.isSafeMachineIdentifier(machineID),
              operationID != Self.zeroOperationID,
              Self.isSHA256(resolvedPlanSHA256),
              planRevision > 0,
              Self.isSafeEvidenceIdentifier(executionComponentBuildIdentifier),
              virtualHardwareABIVersion == 1,
              platform == .x86_64LinuxV1,
              launchPlan.machineABIIdentity == DoryPCV1ABI.identity,
              executionResources.isValid else {
            throw DoryPCRuntimeLaunchEnvelopeError.invalidIdentity
        }
        guard devices.networkInterface?.isValid == true,
              devices.networkAttachment != .bridged,
              devices.displays.count <= 1,
              (devices.displays.isEmpty ? graphics == .none : graphics != .none),
              !devices.intelApplicationTranslation else {
            throw DoryPCRuntimeLaunchEnvelopeError.invalidDeviceContract
        }
        guard inheritedDirectoryDescriptors == [
            RuntimeLaunchEnvelope.InheritedDirectoryDescriptorSlot(
                name: RuntimeLaunchEnvelope.variableStoreDirectorySlotName,
                descriptor: RuntimeLaunchEnvelope.variableStoreDirectoryDescriptor,
                access: .readWrite
            )
        ] else {
            throw DoryPCRuntimeLaunchEnvelopeError.invalidVariableStoreDirectoryAuthority
        }

        var expectedNames = [
            RuntimeLaunchEnvelope.systemDiskSlotName,
            RuntimeLaunchEnvelope.firmwareCodeSlotName,
            RuntimeLaunchEnvelope.variableStoreTemplateSlotName,
            RuntimeLaunchEnvelope.firmwareSBOMSlotName,
        ]
        let installer = inheritedFileDescriptors.first {
            $0.name == RuntimeLaunchEnvelope.installerMediaSlotName
        }
        let removable = launchPlan.bootDevices.first { $0.kind == .removableMedia }
        if installer != nil || removable != nil {
            expectedNames.append(RuntimeLaunchEnvelope.installerMediaSlotName)
        }
        let renderer = inheritedFileDescriptors.first {
            $0.name == RuntimeLaunchEnvelope.rendererBootstrapSlotName
        }
        if graphics == .hardwareAccelerated3D {
            expectedNames.append(RuntimeLaunchEnvelope.rendererBootstrapSlotName)
        }
        guard inheritedFileDescriptors.map(\.name) == expectedNames,
              (installer != nil) == (removable != nil),
              (renderer != nil) == (graphics == .hardwareAccelerated3D),
              Set(inheritedFileDescriptors.map(\.descriptor)).count
                == inheritedFileDescriptors.count,
              !inheritedFileDescriptors.map(\.descriptor)
                .contains(RuntimeLaunchEnvelope.variableStoreDirectoryDescriptor) else {
            throw DoryPCRuntimeLaunchEnvelopeError.invalidDescriptorLayout
        }

        let systemDisk = inheritedFileDescriptors[0]
        let firmware = inheritedFileDescriptors[1]
        let variableTemplate = inheritedFileDescriptors[2]
        let sbom = inheritedFileDescriptors[3]
        guard let plannedSystem = launchPlan.bootDevices.first(where: { $0.kind == .systemDisk }),
              systemDisk.name == RuntimeLaunchEnvelope.systemDiskSlotName,
              systemDisk.descriptor == RuntimeLaunchEnvelope.systemDiskDescriptor,
              systemDisk.access == .readWrite,
              systemDisk.byteCount > 0,
              systemDisk.contentSHA256 == nil,
              systemDisk.logicalDeviceID?.rawValue == plannedSystem.logicalID else {
            throw DoryPCRuntimeLaunchEnvelopeError.invalidSystemDiskAuthority
        }
        guard Self.matchesImmutable(
            firmware,
            name: RuntimeLaunchEnvelope.firmwareCodeSlotName,
            descriptor: RuntimeLaunchEnvelope.firmwareCodeDescriptor,
            byteCount: launchPlan.firmware.firmwareCodeByteCount,
            sha256: launchPlan.firmware.firmwareCodeSHA256
        ), Self.matchesImmutable(
            variableTemplate,
            name: RuntimeLaunchEnvelope.variableStoreTemplateSlotName,
            descriptor: RuntimeLaunchEnvelope.variableStoreTemplateDescriptor,
            byteCount: launchPlan.firmware.variableStoreTemplateByteCount,
            sha256: launchPlan.firmware.variableStoreTemplateSHA256
        ), sbom.name == RuntimeLaunchEnvelope.firmwareSBOMSlotName,
           sbom.descriptor == RuntimeLaunchEnvelope.firmwareSBOMDescriptor,
           sbom.access == .readOnly,
           sbom.logicalDeviceID == nil,
           sbom.byteCount > 0,
           sbom.byteCount <= RuntimeLaunchEnvelope.maximumFirmwareSBOMBytes,
           sbom.contentSHA256 == launchPlan.firmware.sbomSHA256 else {
            throw DoryPCRuntimeLaunchEnvelopeError.invalidFirmwareAuthority
        }
        if let installer, let removable {
            guard installer.descriptor == RuntimeLaunchEnvelope.installerMediaDescriptor,
                  installer.access == .readOnly,
                  installer.byteCount > 0,
                  installer.byteCount <= RuntimeLaunchEnvelope.maximumInstallerMediaBytes,
                  Self.isSHA256(installer.contentSHA256),
                  installer.logicalDeviceID?.rawValue == removable.logicalID,
                  removable.pciAddress == DoryPCV1ABI.removableMediaPCIAddress else {
                throw DoryPCRuntimeLaunchEnvelopeError.invalidInstallerMediaAuthority
            }
        }
        if let renderer {
            guard renderer.descriptor == RuntimeLaunchEnvelope.uefiRendererBootstrapDescriptor,
                  renderer.access == .readOnly,
                  renderer.logicalDeviceID == nil,
                  renderer.byteCount == UInt64(DoryRendererWorkerBootstrapCodec.fixedByteCount),
                  Self.isSHA256(renderer.contentSHA256) else {
                throw DoryPCRuntimeLaunchEnvelopeError.invalidRendererBootstrapAuthority
            }
        }
        return ResolvedResources(
            systemDisk: systemDisk,
            firmwareCode: firmware,
            variableStoreTemplate: variableTemplate,
            firmwareSBOM: sbom,
            installerMedia: installer,
            variableStoreDirectory: inheritedDirectoryDescriptors[0],
            rendererBootstrap: renderer
        )
    }

    public func encodedArgument() throws -> String {
        _ = try validatedResources()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedArgumentBytes,
              let value = String(data: data, encoding: .utf8) else {
            throw DoryPCRuntimeLaunchEnvelopeError.invalidEncoding
        }
        return value
    }

    public static func decodeArgument(_ value: String) throws -> Self {
        guard let data = value.data(using: .utf8),
              data.count <= Self.maximumEncodedArgumentBytes else {
            throw DoryPCRuntimeLaunchEnvelopeError.invalidEncoding
        }
        let envelope = try JSONDecoder().decode(Self.self, from: data)
        _ = try envelope.validatedResources()
        guard try envelope.encodedArgument() == value else {
            throw DoryPCRuntimeLaunchEnvelopeError.nonCanonicalEncoding
        }
        return envelope
    }

    private static let zeroOperationID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    private static func matchesImmutable(
        _ slot: RuntimeLaunchEnvelope.InheritedFileDescriptorSlot,
        name: String,
        descriptor: Int32,
        byteCount: UInt64,
        sha256: String
    ) -> Bool {
        slot.name == name && slot.descriptor == descriptor && slot.access == .readOnly
            && slot.byteCount == byteCount && slot.contentSHA256 == sha256
            && slot.logicalDeviceID == nil
    }

    private static func isSafeMachineIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...63).contains(bytes.count), let first = bytes.first,
              isASCIIAlphaNumeric(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isSafeEvidenceIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...255).contains(bytes.count) else { return false }
        return bytes.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 58 || $0 == 64
                || $0 == 95
        }
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

public enum DoryPCRuntimeLaunchEnvelopeError: Error, Sendable, Equatable {
    case invalidIdentity
    case invalidDeviceContract
    case invalidDescriptorLayout
    case invalidSystemDiskAuthority
    case invalidFirmwareAuthority
    case invalidInstallerMediaAuthority
    case invalidRendererBootstrapAuthority
    case invalidVariableStoreDirectoryAuthority
    case invalidEncoding
    case nonCanonicalEncoding
}
