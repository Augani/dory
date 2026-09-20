import DoryOperations
import DoryRendererWorkerWireContracts
@testable import DorydKit
import Testing

@Suite("Stock graphics admission")
struct DoryGraphicsAdmissionTests {
    private let linuxARM = DoryGuestPlatform(family: .linux, architecture: .arm64)
    private let host = DoryGraphicsAdmissionHostFacts(
        metalAvailable: true,
        generationArenaAvailable: true
    )

    private func request(
        graphics: DoryGraphicsAccelerationLevel = .hardwareAccelerated3D,
        guest: DoryGuestPlatform? = nil,
        profile: DoryGraphicsGuestProfile = .supportedStock
    ) -> DoryGraphicsAdmissionRequest {
        DoryGraphicsAdmissionRequest(
            requestedGraphics: graphics,
            guest: guest ?? linuxARM,
            profile: profile
        )
    }

    private func evidence(
        worker: Bool = true,
        runtime: Bool = true,
        kernel: DoryGraphicsVersion? = nil,
        mesa: DoryGraphicsVersion? = nil,
        capset: DoryGraphicsCompatibilityObservation = .unobserved,
        fence: DoryGraphicsFenceObservation = .unobserved
    ) -> DoryGraphicsAdmissionEvidence {
        DoryGraphicsAdmissionEvidence(
            signedWorkerIdentityVerified: worker,
            signedRuntimeIdentityVerified: runtime,
            observedKernel: kernel,
            observedMesa: mesa,
            venusCapset: capset,
            fenceOrdering: fence
        )
    }

    @Test func parsesDistroVersionSuffixesNumerically() {
        #expect(DoryGraphicsVersion(reportedValue: "6.14.0-29-generic")
            == DoryGraphicsVersion(major: 6, minor: 14))
        #expect(DoryGraphicsVersion(reportedValue: "24.2.8-1ubuntu1")
            == DoryGraphicsVersion(major: 24, minor: 2, patch: 8))
        #expect(DoryGraphicsVersion(reportedValue: "6.13")
            == DoryGraphicsVersion(major: 6, minor: 13))
        #expect(DoryGraphicsVersion(reportedValue: "rolling") == nil)
    }

    @Test func nonHardwareRequestsPassThroughWithoutVerification() {
        let decision = DoryGraphicsAdmission.admit(
            request(graphics: .software),
            evidence: evidence(worker: false, runtime: false),
            hostFacts: DoryGraphicsAdmissionHostFacts(
                metalAvailable: false,
                generationArenaAvailable: false
            )
        )
        #expect(decision.admittedGraphics == .software)
        #expect(decision.verificationState == .notRequired)
    }

    @Test func managedProfileHasNoAdmissionPathInThisRelease() {
        let decision = DoryGraphicsAdmission.admit(
            request(profile: .managed(
                kernelSHA256: String(repeating: "a", count: 64),
                mesaSHA256: String(repeating: "b", count: 64),
                fence: .managedLinux612106PrepareFBV1
            )),
            evidence: evidence(),
            hostFacts: host
        )
        #expect(decision.verificationState == .downgraded(.managedProfileUnavailable))
    }

    @Test func stockAdmissionIsProvisionalUntilRuntimeObservationsComplete() {
        let decision = DoryGraphicsAdmission.admit(
            request(),
            evidence: evidence(),
            hostFacts: host
        )
        #expect(decision.admittedGraphics == .hardwareAccelerated3D)
        #expect(decision.verificationState == .provisional)
    }

    @Test func compatibleCapsetAndFenceOrderingPromoteStockAdmission() {
        let decision = DoryGraphicsAdmission.admit(
            request(),
            evidence: evidence(
                kernel: DoryGraphicsVersion(major: 6, minor: 14),
                mesa: DoryGraphicsVersion(major: 24, minor: 2),
                capset: .compatible,
                fence: .verified
            ),
            hostFacts: host
        )
        #expect(decision.admittedGraphics == .hardwareAccelerated3D)
        #expect(decision.verificationState == .verified)
    }

    @Test(arguments: [
        (
            DoryGraphicsAdmissionEvidence(
                signedWorkerIdentityVerified: false,
                signedRuntimeIdentityVerified: true
            ),
            DoryGraphicsAdmissionDowngradeReason.rendererWorkerIdentityUnverified
        ),
        (
            DoryGraphicsAdmissionEvidence(
                signedWorkerIdentityVerified: true,
                signedRuntimeIdentityVerified: false
            ),
            DoryGraphicsAdmissionDowngradeReason.runtimeIdentityUnverified
        ),
        (
            DoryGraphicsAdmissionEvidence(
                signedWorkerIdentityVerified: true,
                signedRuntimeIdentityVerified: true,
                observedKernel: DoryGraphicsVersion(major: 6, minor: 12)
            ),
            DoryGraphicsAdmissionDowngradeReason.guestKernelTooOld
        ),
        (
            DoryGraphicsAdmissionEvidence(
                signedWorkerIdentityVerified: true,
                signedRuntimeIdentityVerified: true,
                observedMesa: DoryGraphicsVersion(major: 23, minor: 3)
            ),
            DoryGraphicsAdmissionDowngradeReason.guestMesaTooOld
        ),
        (
            DoryGraphicsAdmissionEvidence(
                signedWorkerIdentityVerified: true,
                signedRuntimeIdentityVerified: true,
                venusCapset: .incompatible
            ),
            DoryGraphicsAdmissionDowngradeReason.venusCapsetIncompatible
        ),
        (
            DoryGraphicsAdmissionEvidence(
                signedWorkerIdentityVerified: true,
                signedRuntimeIdentityVerified: true,
                fenceOrdering: .violated
            ),
            DoryGraphicsAdmissionDowngradeReason.guestKernelLacksPrepareFB
        ),
    ])
    func incompatibleEvidenceDowngradesTruthfully(
        evidence: DoryGraphicsAdmissionEvidence,
        reason: DoryGraphicsAdmissionDowngradeReason
    ) {
        let decision = DoryGraphicsAdmission.admit(
            request(),
            evidence: evidence,
            hostFacts: host
        )
        #expect(decision.admittedGraphics == .software)
        #expect(decision.verificationState == .downgraded(reason))
        #expect(!reason.userMessage.isEmpty)
    }

    @Test func unsupportedGuestsAndMissingHostCapabilitiesDowngrade() {
        let x86 = DoryGuestPlatform(family: .linux, architecture: .x86_64)
        #expect(DoryGraphicsAdmission.admit(
            request(guest: x86),
            evidence: evidence(),
            hostFacts: host
        ).verificationState == .downgraded(.unsupportedGuest))
        #expect(DoryGraphicsAdmission.admit(
            request(),
            evidence: evidence(),
            hostFacts: DoryGraphicsAdmissionHostFacts(
                metalAvailable: false,
                generationArenaAvailable: true
            )
        ).verificationState == .downgraded(.hostMetalUnavailable))
        #expect(DoryGraphicsAdmission.admit(
            request(),
            evidence: evidence(),
            hostFacts: DoryGraphicsAdmissionHostFacts(
                metalAvailable: true,
                generationArenaAvailable: false
            )
        ).verificationState == .downgraded(.guestVRAMArenaUnavailable))
    }
}
