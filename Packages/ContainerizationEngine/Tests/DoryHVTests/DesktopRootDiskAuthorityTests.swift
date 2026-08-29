import Darwin
import DoryOperations
import DoryVMContracts
import Foundation
import Testing
@testable import dory_hv

@Suite struct DesktopRootDiskAuthorityTests {
    @Test func resolvedEnvelopeCannotFallBackToLegacyPath() throws {
        let envelope = makeEnvelope(capacityBytes: 4096)

        #expect(throws: (any Error).self) {
            _ = try DesktopMode.RootDiskBacking.resolve(
                legacyPath: "/tmp/replacement.ext4",
                runtimeLaunchEnvelope: envelope
            )
        }
    }

    @Test func legacyPathRemainsAnExplicitSeparateMode() throws {
        let backing = try DesktopMode.RootDiskBacking.resolve(
            legacyPath: "/tmp/legacy.ext4",
            runtimeLaunchEnvelope: nil
        )

        #expect(backing == .legacyPath("/tmp/legacy.ext4"))
    }

    @Test func resolvedDescriptorRejectsCapacityDriftBeforeVirtioConstruction() throws {
        let directory = "/tmp/dory-desktop-disk-authority-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(chmod(directory, 0o700) == 0)
        let path = directory + "/rootfs.ext4"
        try Data(repeating: 0, count: 4096).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let descriptor = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        #expect(descriptor >= 0)
        defer { close(descriptor) }

        let backing = DesktopMode.RootDiskBacking.resolvedDescriptor(
            descriptor: descriptor,
            capacityBytes: 8192
        )
        #expect(throws: (any Error).self) {
            _ = try backing.makeBackend(queueCount: 1)
        }
    }

    @Test func resolvedDescriptorMaterializesExactSystemDiskQueueTopology() throws {
        let directory = "/tmp/dory-desktop-disk-queues-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(chmod(directory, 0o700) == 0)
        let path = directory + "/rootfs.ext4"
        try Data(repeating: 0, count: 4096).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let descriptor = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        #expect(descriptor >= 0)
        defer { close(descriptor) }

        let backing = DesktopMode.RootDiskBacking.resolvedDescriptor(
            descriptor: descriptor,
            capacityBytes: 4096
        )
        let backend = try backing.makeBackend(queueCount: 4)

        #expect(backend.queueCount == 4)
        #expect(backend.deviceFeatures & (UInt64(1) << 12) != 0)
    }

    private func makeEnvelope(capacityBytes: UInt64) -> RuntimeLaunchEnvelope {
        RuntimeLaunchEnvelope.resolvedRawHV(
            machineID: "desktop-authority-test",
            operationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            resolvedPlanSHA256: String(repeating: "c", count: 64),
            planRevision: 1,
            backendRuntimeBuildIdentifier: "raw-runtime-1",
            virtualHardwareABIVersion: 1,
            rawHVVirtualHardwareTopology: makeTopology(),
            graphics: .software,
            devices: makeDevices(),
            portForwards: [],
            executionResources: .production(memoryMB: 4_096, virtualCPUCount: 4),
            systemDiskCapacityBytes: capacityBytes,
            systemDiskLogicalID: try! DoryVirtualDeviceID("system-disk"),
            linuxRootDevice: "/dev/vda",
            genericGuest: false,
            linuxKernelByteCount: 4_096,
            linuxKernelSHA256: String(repeating: "d", count: 64)
        )
    }

    private func makeTopology() -> DoryRawHVVirtualHardwareTopology {
        try! DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: [
                try! .init(logicalID: "system-disk", role: .systemDisk),
                try! .init(logicalID: "rawhv-graphics", role: .graphics),
                try! .init(logicalID: "rawhv-entropy", role: .entropy),
                try! .init(logicalID: "rawhv-balloon", role: .balloon),
                try! .init(logicalID: "rawhv-vsock", role: .vsock),
                DoryRawHVVirtualDeviceRequest(
                    logicalID: try! DoryVirtualDeviceID.derived(
                        namespace: .network,
                        stableID: makeDevices().networkInterface!.id
                    ),
                    role: .network
                ),
            ]
        )
    }

    private func makeDevices() -> DoryVirtualMachineDeviceCapabilityRequest {
        DoryVirtualMachineDeviceCapabilityRequest(
            networkInterface: .stable(machineID: "desktop-authority-test"),
            displays: [
                .init(widthPixels: 1_920, heightPixels: 1_080),
            ]
        )
    }
}
