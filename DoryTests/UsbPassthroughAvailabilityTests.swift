import Testing
@testable import Dory

struct UsbPassthroughAvailabilityTests {
    @Test func missingAuthorizedMachineFailsClosed() {
        #expect(!UsbPassthroughAvailability.attachSupported(for: nil))
        #expect(
            UsbPassthroughAvailability.unavailableReason(for: nil)
                .contains("signed removable-USB authorization")
        )
    }
}
