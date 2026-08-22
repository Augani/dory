import DoryHV
import DoryOperations
import Testing
@testable import dory_hv

@Suite struct DesktopClipboardPlanTests {
    @Test func resolvedPolicyOverridesConflictingLegacyEnvironment() throws {
        let exact = DoryVMClipboardPolicy(
            text: .hostToGuest,
            image: .guestToHost,
            files: .off
        )
        let plan = try DesktopMode.ClipboardPlan(
            resolvedDevices: .init(clipboard: true, clipboardPolicy: exact),
            environment: [DoryDesktopClipboardPolicy.environmentKey: "bidirectional"],
            genericGuest: false
        )

        #expect(plan.policy == exact)
    }

    @Test func disabledResolvedClipboardCannotCarryEnabledPolicy() {
        #expect(throws: VMError.self) {
            _ = try DesktopMode.ClipboardPlan(
                resolvedDevices: .init(
                    clipboard: false,
                    clipboardPolicy: .legacyDesktop(.hostToGuest)
                ),
                environment: [:],
                genericGuest: false
            )
        }
    }

    @Test func unsupportedFileTransferFailsClosed() {
        #expect(throws: VMError.self) {
            _ = try DesktopMode.ClipboardPlan(
                resolvedDevices: .init(
                    clipboard: true,
                    clipboardPolicy: .init(
                        text: .bidirectional,
                        image: .bidirectional,
                        files: .hostToGuest
                    )
                ),
                environment: [:],
                genericGuest: false
            )
        }
    }

    @Test func historicalLaunchRetainsLegacyPolicy() throws {
        let plan = try DesktopMode.ClipboardPlan(
            resolvedDevices: nil,
            environment: [DoryDesktopClipboardPolicy.environmentKey: "guest-to-host"],
            genericGuest: false
        )

        #expect(plan.policy == .legacyDesktop(.guestToHost))
    }
}
