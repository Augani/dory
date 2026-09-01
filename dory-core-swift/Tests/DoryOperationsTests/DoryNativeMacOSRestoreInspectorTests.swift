import Testing
@testable import DoryOperations

@Suite("Native macOS restore inspection")
struct DoryNativeMacOSRestoreInspectorTests {
    @Test("prepared VZMac receipt binds exact IPSW identity and compatibility")
    func preparedReceipt() throws {
        let digest = String(repeating: "a", count: 64)
        let result = try DoryQualifiedBootMediaInspector
            .inspectPreparedNativeMacOSRestoreImage(
                artifactSHA256: digest,
                byteCount: 14_000_000_000,
                buildIdentifier: "26A123"
            )

        #expect(result.media == DoryBootMedia(
            kind: .macOSRestoreImage,
            source: .userProvided,
            artifactSHA256: digest
        ))
        #expect(result.inspection.detectedKind == .macOSRestoreImage)
        #expect(result.inspection.detectedGuestFamily == .macOS)
        #expect(result.inspection.detectedArchitecture == .arm64)
        #expect(result.inspection.macOSBuildIdentifier == "26A123")
        #expect(result.inspection.macOSHardwareModelCompatible)
        #expect(result.inspection.macOSAuxiliaryStorageCompatible)
        #expect(result.auditEvidence.artifactSHA256 == digest)
        #expect(result.auditEvidence.inspectorID == "dory.vzmac-prepared-restore-inspector")
    }

    @Test("receipt rejects malformed provenance")
    func invalidReceipt() {
        #expect(throws: DoryVirtualMachineQualificationAuthorityError.self) {
            try DoryQualifiedBootMediaInspector.inspectPreparedNativeMacOSRestoreImage(
                artifactSHA256: "not-a-digest",
                byteCount: 0,
                buildIdentifier: ""
            )
        }
    }
}
