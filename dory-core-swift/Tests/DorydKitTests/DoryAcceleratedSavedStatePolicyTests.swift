import DoryOperations
import Testing
@testable import DorydKit

@Suite("Accelerated saved-state policy")
struct DoryAcceleratedSavedStatePolicyTests {
    @Test("3D acceleration is rejected before saved-state quiescing")
    func rejectsHardwareAccelerated3D() {
        #expect(throws: MachineManagerError.persistence(
            DoryAcceleratedSavedStatePolicy.rejectionMessage
        )) {
            try DoryAcceleratedSavedStatePolicy.validate(graphics: .hardwareAccelerated3D)
        }
        for preference in [
            DoryDesktopGraphicsPreference.automatic,
            DoryDesktopGraphicsPreference.virglVenus,
        ] {
            #expect(throws: MachineManagerError.persistence(
                DoryAcceleratedSavedStatePolicy.rejectionMessage
            )) {
                try DoryAcceleratedSavedStatePolicy.validate(
                    graphics: nil,
                    unresolvedDesktopPreference: preference
                )
            }
        }
        #expect(DoryAcceleratedSavedStatePolicy.rejectionMessage.contains("cold snapshot"))
        #expect(DoryAcceleratedSavedStatePolicy.rejectionMessage.contains("guest to RAM"))
    }

    @Test("restorable and unknown graphics plans retain the saved-state path")
    func acceptsNonRendererPlans() throws {
        try DoryAcceleratedSavedStatePolicy.validate(graphics: .software)
        try DoryAcceleratedSavedStatePolicy.validate(graphics: .hostAcceleratedDisplay)
        try DoryAcceleratedSavedStatePolicy.validate(graphics: nil)
        try DoryAcceleratedSavedStatePolicy.validate(
            graphics: nil,
            unresolvedDesktopPreference: .software
        )
        try DoryAcceleratedSavedStatePolicy.validate(
            graphics: nil,
            unresolvedDesktopPreference: .virgl
        )
    }
}
