import DoryHV
import DoryOperations
import Testing
@testable import dory_hv

@Suite struct DesktopNetworkPlanTests {
    @Test func legacyAndSharedNATLaunchGVProxyAndVirtioNet() throws {
        for devices in [
            Optional<DoryVirtualMachineDeviceCapabilityRequest>.none,
            DoryVirtualMachineDeviceCapabilityRequest(networkAttachment: .sharedNAT),
        ] {
            let plan = try DesktopMode.NetworkPlan(resolvedDevices: devices)
            #expect(plan == .sharedNAT)
            #expect(plan.startsGVProxy)
            #expect(plan.attachesNetworkDevice)
        }
    }

    @Test func disconnectedRetainsTheNetworkDeviceWithoutLaunchingGVProxy() throws {
        let devices = DoryVirtualMachineDeviceCapabilityRequest(
            networkAttachment: .disconnected
        )
        let plan = try DesktopMode.NetworkPlan(resolvedDevices: devices)

        #expect(plan == .disconnected)
        #expect(!plan.startsGVProxy)
        #expect(plan.attachesNetworkDevice)
    }

    @Test func unimplementedNetworkModesFailClosed() {
        for mode in [
            DoryVirtualMachineNetworkAttachmentMode.bridged,
            .isolated,
        ] {
            #expect(throws: VMError.self) {
                _ = try DesktopMode.NetworkPlan(
                    resolvedDevices: .init(networkAttachment: mode)
                )
            }
        }
    }
}
