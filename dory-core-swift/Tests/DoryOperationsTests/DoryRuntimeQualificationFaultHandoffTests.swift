import Darwin
import DoryVMContracts
import Foundation
import Testing
@testable import DoryOperations

@Suite(.serialized) struct DoryRuntimeQualificationFaultHandoffTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func envelope(machineID: String = "campaign-arm-1", operationID: UUID = UUID()) throws -> RuntimeLaunchEnvelope {
        let disk = try DoryVirtualDeviceID("campaign-root")
        let network = DoryVirtualMachineNetworkInterfaceCapabilityRequest.stable(machineID: machineID)
        let requests = try [DoryVirtualDeviceRole.systemDisk, .graphics, .entropy, .balloon, .vsock, .network].map { role in
            DoryARMVirtV1DeviceRequest(
                logicalID: role == .systemDisk ? disk : role == .network
                    ? try DoryVirtualDeviceID.derived(namespace: .network, stableID: network.id)
                    : try DoryVirtualDeviceID("armvirt-" + role.rawValue),
                role: role
            )
        }
        return RuntimeLaunchEnvelope.resolvedARMVirt(
            machineID: machineID, operationID: operationID,
            resolvedPlanSHA256: String(repeating: "b", count: 64), planRevision: 1,
            executionComponentBuildIdentifier: "raw-runtime-1", virtualHardwareABIVersion: 1,
            armVirtTopology: try DoryARMVirtV1TopologyReconciler.reconcile(requestedDevices: requests),
            graphics: .software,
            devices: DoryVirtualMachineDeviceCapabilityRequest(
                networkInterface: network,
                displays: [.init(widthPixels: 1_920, heightPixels: 1_080)]
            ),
            portForwards: [],
            executionResources: .production(memoryMB: 1_024, virtualCPUCount: 1, bootProtocol: .linuxDirect),
            systemDiskCapacityBytes: 8_589_934_592, systemDiskLogicalID: disk,
            linuxRootDevice: "/dev/vda", genericGuest: false,
            linuxKernelByteCount: 16_777_216, linuxKernelSHA256: String(repeating: "c", count: 64)
        )
    }

    func authority(_ envelope: RuntimeLaunchEnvelope, expiry: Date? = nil) -> DoryRuntimeQualificationFaultAuthority {
        DoryRuntimeQualificationFaultAuthority(
            machineID: envelope.machineID, operationID: envelope.operationID,
            resolvedPlanSHA256: envelope.resolvedPlanSHA256,
            campaignManifestSHA256: String(repeating: "d", count: 64),
            expiresAt: expiry ?? now.addingTimeInterval(60),
            policy: .init(permittedFaults: [.blockFullFlushNoSpace])
        )
    }

    @Test func boundedTransferClosesTheDescriptorAndRetainsKernelPeerCredentials() throws {
        let launch = try envelope()
        let grant = authority(launch)
        let channel = try DoryRuntimeQualificationFaultHandoff.makeChannel(authority: grant)
        defer { withExtendedLifetime(channel) {} }
        let fd = try channel.takeDescriptor()
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) { try channel.takeDescriptor() }
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        var uid: uid_t = 0
        var gid: gid_t = 0
        #expect(getpeereid(fd, &uid, &gid) == 0)
        #expect(uid == geteuid())
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        #expect(getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0)
        #expect(length == MemoryLayout<audit_token_t>.size)
        let received = try DoryRuntimeQualificationFaultHandoff.receive(
            descriptor: fd, envelope: launch, now: now, authenticate: { _ in }
        )
        #expect(received == grant)
    }

    @Test func unsignedCreatorIsNotAnAuthenticatedDaemon() throws {
        let launch = try envelope()
        let channel = try DoryRuntimeQualificationFaultHandoff.makeChannel(authority: authority(launch))
        defer { withExtendedLifetime(channel) {} }
        let fd = try channel.takeDescriptor()
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
            _ = try DoryRuntimeQualificationFaultHandoff.receive(
                descriptor: fd, envelope: launch, now: now,
                authenticate: DoryRuntimeQualificationFaultHandoff.authenticateDaemon
            )
        }
    }

    @Test func retiredSenderCannotLeaveReplayableAuthorityBehind() throws {
        let launch = try envelope()
        let fd: Int32
        do {
            let channel = try DoryRuntimeQualificationFaultHandoff.makeChannel(authority: authority(launch))
            fd = try channel.takeDescriptor()
        }
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
            _ = try DoryRuntimeQualificationFaultHandoff.receive(
                descriptor: fd, envelope: launch, now: now,
                authenticate: DoryRuntimeQualificationFaultHandoff.authenticateDaemon
            )
        }
    }

    @Test func otherMachineAndOperationCannotReuseTheGrant() throws {
        let launch = try envelope()
        for changed in [try envelope(machineID: "campaign-arm-2", operationID: launch.operationID),
                        try envelope(operationID: UUID())] {
            let channel = try DoryRuntimeQualificationFaultHandoff.makeChannel(authority: authority(launch))
            defer { withExtendedLifetime(channel) {} }
            let fd = try channel.takeDescriptor()
            #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
                _ = try DoryRuntimeQualificationFaultHandoff.receive(
                    descriptor: fd, envelope: changed, now: now, authenticate: { _ in }
                )
            }
        }
    }

    @Test func expiredOrUnboundedLifetimeDoesNotCrossTheBoundary() throws {
        let launch = try envelope()
        for expiry in [now, now.addingTimeInterval(8 * 24 * 60 * 60)] {
            let channel = try DoryRuntimeQualificationFaultHandoff.makeChannel(authority: authority(launch, expiry: expiry))
            defer { withExtendedLifetime(channel) {} }
            let fd = try channel.takeDescriptor()
            #expect(throws: DoryRuntimeQualificationFaultError.expired) {
                _ = try DoryRuntimeQualificationFaultHandoff.receive(
                    descriptor: fd, envelope: launch, now: now, authenticate: { _ in }
                )
            }
        }
    }

    @Test func fileCannotSubstituteForTheInheritedSocket() throws {
        let launch = try envelope()
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
        #expect(fd >= 0)
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
            _ = try DoryRuntimeQualificationFaultHandoff.receive(
                descriptor: fd, envelope: launch, now: now,
                authenticate: DoryRuntimeQualificationFaultHandoff.authenticateDaemon
            )
        }
    }
}
