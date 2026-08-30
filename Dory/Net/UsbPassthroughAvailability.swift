import Foundation

enum UsbPassthroughAvailability: Sendable {
    static func attachSupported(for status: DorydMachineStatus?) -> Bool {
        guard let status else { return false }
        return status.state == "running"
            && status.runtimeIdentity.backend == "dory-hypervisor"
            && status.runtimeIdentity.authorizesRemovableUSBHotplug
    }

    static func unavailableReason(for status: DorydMachineStatus?) -> String {
        guard let status else {
            return "Select a running machine with signed removable-USB authorization."
        }
        guard status.state == "running" else {
            return "Start this machine before attaching a host USB device."
        }
        guard status.runtimeIdentity.mode == "resolved-plan" else {
            return "This machine has no launch-authorizing resolved plan. USB attachment fails closed."
        }
        guard status.runtimeIdentity.backend == "dory-hypervisor" else {
            return "USB attachment requires the resolved raw-hypervisor backend."
        }
        guard status.runtimeIdentity.authorizesRemovableUSBHotplug else {
            return "This machine's signed plan does not authorize removable USB hotplug."
        }
        return "USB attachment is available for this machine."
    }
}
