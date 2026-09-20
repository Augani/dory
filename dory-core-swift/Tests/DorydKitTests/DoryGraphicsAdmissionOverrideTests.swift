@testable import DorydKit
import Testing

@Suite("Graphics admission development override")
struct DoryGraphicsAdmissionOverrideTests {
    @Test("DEBUG activation requires the exact unsafe-development opt-in")
    func exactOptIn() {
        #if DEBUG
        #expect(DoryDaemonVirtualMachineProductionTrustFactory
            .allowsUnsafeDevelopmentGraphicsAdmission(environment: [
                "DORY_GRAPHICS_ADMISSION_OVERRIDE": "unsafe-development",
            ]))
        #expect(!DoryDaemonVirtualMachineProductionTrustFactory
            .allowsUnsafeDevelopmentGraphicsAdmission(environment: [:]))
        #expect(!DoryDaemonVirtualMachineProductionTrustFactory
            .allowsUnsafeDevelopmentGraphicsAdmission(environment: [
                "DORY_GRAPHICS_ADMISSION_OVERRIDE": "true",
            ]))
        #else
        #expect(!DoryDaemonVirtualMachineProductionTrustFactory
            .allowsUnsafeDevelopmentGraphicsAdmission(environment: [
                "DORY_GRAPHICS_ADMISSION_OVERRIDE": "unsafe-development",
            ]))
        #endif
    }
}
