import DoryCore
import Darwin
import DoryFirmware
import DoryMachinePC
import DoryRendererWorkerWireContracts
import DoryVMContracts
import Foundation
import Testing
@testable import DoryOperations
@testable import DorydKit

@Suite struct DoryRuntimeQualificationFaultLaunchTests {
    @Test func immutableFaultGrantStaysOutOfProcessSupervisionStacks() {
        #expect(MemoryLayout<DoryRuntimeQualificationFaultAuthority>.size == MemoryLayout<UnsafeRawPointer>.size)
        #expect(MemoryLayout<HvProcessConfiguration>.size < 256)
        #expect(MemoryLayout<DoryRendererCrashQualificationAdmission>.size <= 64)
    }

    @Test(arguments: ["canonical", "inline", "duplicate", "missing-fd", "missing-flag", "renamed",
                      "restart", "machine", "operation", "plan", "mixed-policy", "software"])
    func pcFaultDescriptorIsOneShotAndCannotBeShadowedBeforeSpawn(variant: String) throws {
        let envelope = try pcEnvelope(accelerated: variant != "software")
        let authority = try DoryPCRuntimeLaunchEnvelopeAuthority(envelope)
        let grant = DoryRuntimeQualificationFaultAuthority(
            machineID: variant == "machine" ? "other-pc" : envelope.machineID,
            operationID: variant == "operation" ? UUID() : envelope.operationID,
            resolvedPlanSHA256: variant == "plan" ? String(repeating: "e", count: 64) : envelope.resolvedPlanSHA256,
            campaignManifestSHA256: String(repeating: "d", count: 64), expiresAt: Date().addingTimeInterval(60),
            policy: .init(permittedFaults: variant == "mixed-policy"
                ? [.blockFullFlushNoSpace, .rendererWorkerCrash] : [.rendererWorkerCrash])
        )
        #expect(authority.matchesQualificationFaultAuthority(grant)
            == !["machine", "operation", "plan", "mixed-policy", "software"].contains(variant))
        let channel = try DoryRuntimeQualificationFaultHandoff.makeChannel(authority: grant)
        var descriptors = try envelope.inheritedFileDescriptors.map { slot in
            let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(.EBADF) }
            return HvProcessInheritedFileDescriptor(name: slot.name,
                takingOwnershipOf: descriptor, childDescriptor: slot.descriptor)
        }
        for slot in envelope.inheritedDirectoryDescriptors {
            let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(.EBADF) }
            descriptors.append(.init(name: slot.name, takingOwnershipOf: descriptor, childDescriptor: slot.descriptor))
        }
        if variant != "missing-fd" {
            descriptors.append(.init(name: variant == "renamed" ? "wrong-fault-slot" : DoryRuntimeQualificationFaultHandoff.descriptorName,
                takingOwnershipOf: try channel.takeDescriptor(), childDescriptor: DoryRuntimeQualificationFaultHandoff.childDescriptor))
        }
        let flag = DoryRuntimeQualificationFaultHandoff.descriptorArgument
        let slot = String(DoryRuntimeQualificationFaultHandoff.childDescriptor)
        var arguments = ["desktop", flag, slot]
        if variant == "missing-flag" { arguments = ["desktop"] }
        if variant == "inline" { arguments = ["desktop", flag + "=" + slot] }
        if variant == "duplicate" { arguments += [flag, slot] }
        var configuration = HvProcessConfiguration(executablePath: "/usr/bin/true", arguments: arguments,
            restartPolicy: variant == "restart" ? .init(maxRestarts: 1) : .none,
            pcRuntimeLaunchEnvelopeAuthority: authority, inheritedFileDescriptors: descriptors)
        configuration.qualificationFaultAuthority = grant
        configuration.qualificationFaultChannel = channel
        let process = HvProcess(configuration: configuration)
        if variant == "canonical" {
            // A harmless descriptor-only child, not a VM or renderer; the receiver's audit-token
            // authentication is covered separately by the handoff tests.
            try process.start()
            process.stop()
        } else {
            do { try process.start(); Issue.record("invalid PC fault descriptor shape reached spawn") }
            catch HvProcess.ProcessError.descriptorEnvelopeMismatch { }
            #expect(process.pid == nil)
        }
    }

    private func pcEnvelope(accelerated: Bool) throws -> DoryPCRuntimeLaunchEnvelope {
        let digest = String(repeating: "a", count: 64)
        let firmware = try DoryFirmwareArtifactManifest(platform: .pcV1, buildIdentifier: "pc-fault-test.1",
            source: .init(repository: "https://github.com/tianocore/edk2.git", revision: String(repeating: "a", count: 40)),
            sourceDateEpoch: 1, platformConfigurationSHA256: digest, toolchainSHA256: digest,
            firmwareCodeSHA256: digest, firmwareCodeByteCount: 4096,
            variableStoreTemplateSHA256: digest, variableStoreTemplateByteCount: 4096,
            sbomSHA256: digest, secureBootPolicy: .disabled, reproducible: true)
        let disk = try DoryVirtualDeviceID("system-disk")
        let bootDevice = try DoryPCUEFIBootDevice(logicalID: disk.rawValue, kind: .systemDisk,
            pciAddress: DoryPCV1ABI.systemDiskPCIAddress, readOnly: false)
        let plan = try DoryPCUEFILaunchPlan(firmware: firmware, variableStoreGeneration: 1,
            bootDevices: [bootDevice], bootOrder: [disk.rawValue])
        return .resolvedUEFI(machineID: "campaign-pc", operationID: UUID(),
            resolvedPlanSHA256: String(repeating: "b", count: 64), planRevision: 1,
            executionComponentBuildIdentifier: "dory-dbt-test.1", virtualHardwareABIVersion: 1,
            graphics: accelerated ? .hardwareAccelerated3D : .software,
            rendererProducerFenceContract: accelerated ? .doryPCX8664LinuxVirGL2PrepareFBV1 : nil,
            devices: .init(networkInterface: .stable(machineID: "campaign-pc"),
                displays: [.init(widthPixels: 1280, heightPixels: 800)], keyboard: true, pointer: true),
            portForwards: [], executionResources: .init(memoryMB: 4096, virtualCPUCount: 1, tier: .baselineJIT),
            systemDiskCapacityBytes: 8_589_934_592, systemDiskLogicalID: disk, launchPlan: plan,
            firmwareSBOMByteCount: 4096,
            rendererBootstrapByteCount: accelerated ? UInt64(DoryRendererWorkerBootstrapCodec.fixedByteCount) : nil,
            rendererBootstrapSHA256: accelerated ? digest : nil)
    }

    @Test func actualOperationIsForwardedOnceThroughThePreSpawnToken() throws {
        let operation = UUID()
        let token = DoryDaemonVirtualMachinePreSpawnAuthorization.resolvingRuntimeLaunchAuthority(purpose: .start) {
            supplied in
            guard supplied == operation else { throw DoryRuntimeQualificationFaultError.invalidIdentity }
            return .noRendererReleaseIdentityRequired
        }
        #expect(try token.authorizeResolvedLaunch(operationID: operation) == .noRendererReleaseIdentityRequired)
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.alreadyConsumed) {
            try token.authorizeResolvedLaunch(operationID: operation)
        }
    }

    @Test func omittedOperationFailsAndCannotBeRetriedWithANewIdentity() throws {
        let token = DoryDaemonVirtualMachinePreSpawnAuthorization.resolvingRuntimeLaunchAuthority(purpose: .start) {
            supplied in
            guard supplied != nil else { throw DoryRuntimeQualificationFaultError.invalidIdentity }
            return .noRendererReleaseIdentityRequired
        }
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.self) { try token.authorize() }
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.alreadyConsumed) {
            try token.authorizeResolvedLaunch(operationID: UUID())
        }
    }

    @Test func preflightCannotRunTheFaultGrantProvider() throws {
        let token = DoryDaemonVirtualMachinePreSpawnAuthorization.resolvingRuntimeLaunchAuthority(
            purpose: .restartPreflight
        ) { _ in
            Issue.record("wrong-purpose token reached the grant provider")
            return .noRendererReleaseIdentityRequired
        }
        #expect(throws: DoryDaemonVirtualMachinePreSpawnAuthorizationError.revalidationFailed) {
            try token.authorizeResolvedLaunch(operationID: UUID())
        }
    }

    @Test func faultGrantDoesNotSubstituteForHardwareGraphicsReleaseIdentity() throws {
        let grant = DoryRuntimeQualificationFaultAuthority(
            machineID: "campaign-arm-1", operationID: UUID(),
            resolvedPlanSHA256: String(repeating: "b", count: 64),
            campaignManifestSHA256: String(repeating: "c", count: 64),
            expiresAt: Date().addingTimeInterval(60),
            policy: .init(permittedFaults: [.blockFullFlushNoSpace])
        )
        let authority = DoryDaemonVirtualMachinePreSpawnLaunchAuthority.candidateCampaignFaults(
            rendererIdentity: nil, faultAuthority: grant
        )
        #expect(authority.qualificationFaultAuthority == grant)
        var binding = MachineBackendLaunchBinding(
            machineID: grant.machineID, operationID: grant.operationID,
            backend: RawHVLinuxMachineBackend.backendDescriptor, componentIdentifier: "dory-hv",
            executablePath: "/bin/sh", graphics: .software, devices: .minimumBootable
        )
        #expect(try MachineManager.resolvedRendererReleaseIdentity(
            preSpawnLaunchAuthority: authority, resolvedLaunchBinding: binding
        ) == nil)
        binding.graphics = .hardwareAccelerated3D
        #expect(throws: MachineManagerError.self) {
            try MachineManager.resolvedRendererReleaseIdentity(
                preSpawnLaunchAuthority: authority, resolvedLaunchBinding: binding
            )
        }
    }
}
