import Testing
@testable import DoryOperations

@Suite("Desktop clipboard policy")
struct DoryDesktopClipboardPolicyTests {
    @Test("defaults existing desktops to bidirectional sharing")
    func defaultPolicy() {
        let policy = DoryDesktopClipboardPolicy(environment: [:])
        #expect(policy == .bidirectional)
        #expect(policy.allowsHostToGuest)
        #expect(policy.allowsGuestToHost)
    }

    @Test("directional and off policies enforce both boundaries")
    func directionalPolicies() {
        #expect(DoryDesktopClipboardPolicy.hostToGuest.allowsHostToGuest)
        #expect(!DoryDesktopClipboardPolicy.hostToGuest.allowsGuestToHost)
        #expect(!DoryDesktopClipboardPolicy.guestToHost.allowsHostToGuest)
        #expect(DoryDesktopClipboardPolicy.guestToHost.allowsGuestToHost)
        #expect(!DoryDesktopClipboardPolicy.off.allowsHostToGuest)
        #expect(!DoryDesktopClipboardPolicy.off.allowsGuestToHost)
        #expect(DoryDesktopClipboardPolicy(environment: [
            DoryDesktopClipboardPolicy.environmentKey: "invalid"
        ]) == .off)
        #expect(DoryDesktopClipboardPolicy.hostToGuest.virtualMachinePolicy
            == .legacyDesktop(.hostToGuest))
    }

    @Test("VZMac SPICE accepts only disabled or full bidirectional text/image")
    func macSPICEPolicy() {
        #expect(DoryVMClipboardPolicy.disabled.isSupportedByVZMacSPICE)
        #expect(DoryVMClipboardPolicy.legacyDesktop(.bidirectional).isSupportedByVZMacSPICE)
        #expect(!DoryVMClipboardPolicy.legacyDesktop(.hostToGuest).isSupportedByVZMacSPICE)
        #expect(!DoryVMClipboardPolicy.legacyDesktop(.guestToHost).isSupportedByVZMacSPICE)
        #expect(!DoryVMClipboardPolicy(
            text: .bidirectional, image: .bidirectional, files: .bidirectional
        ).isSupportedByVZMacSPICE)
    }
}
