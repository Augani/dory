import Foundation
import Testing
@testable import DoryOperations

@Suite("Guest integration package contracts")
struct DoryGuestIntegrationPackageTests {
    private let digest = String(repeating: "a", count: 64)

    @Test("Linux tools declare a canonical independently versioned capability set")
    func linuxToolsPackage() throws {
        let manifest = package(
            family: .linux,
            roles: [.linuxToolsArchive],
            signature: .doryEd25519
        )

        #expect(manifest.isValidForPersistence)
        #expect(manifest.state == .contractOnly)
        let decoded = try JSONDecoder().decode(
            DoryGuestIntegrationPackageManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        #expect(decoded == manifest)
    }

    @Test("Windows contract requires an Authenticode service and driver without claiming support")
    func windowsServiceAndDriverContract() {
        let complete = package(
            family: .windows,
            roles: [.windowsDriver, .windowsService],
            signature: .microsoftAuthenticode
        )
        let missingDriver = package(
            family: .windows,
            roles: [.windowsService],
            signature: .microsoftAuthenticode
        )

        #expect(complete.isValidForPersistence)
        #expect(complete.state == .contractOnly)
        #expect(missingDriver.validationIssues().contains {
            $0.code == .incompleteWindowsPackage
        })
    }

    @Test("macOS contract permits only Developer ID packages on ARM64")
    func macOSPackageContract() {
        let valid = package(
            family: .macOS,
            roles: [.macOSPackage],
            signature: .appleDeveloperID
        )
        var wrongArchitecture = valid
        wrongArchitecture.guest.architecture = .x86_64
        var wrongPayload = valid
        wrongPayload.artifacts[0].role = .windowsDriver

        #expect(valid.isValidForPersistence)
        #expect(wrongArchitecture.validationIssues().contains {
            $0.code == .unsupportedPlatform
        })
        #expect(wrongPayload.validationIssues().contains {
            $0.code == .invalidArtifacts
        })
    }

    @Test("signature systems cannot be substituted across guest families")
    func signatureSubstitutionRejected() {
        let windowsWithAppleSignature = package(
            family: .windows,
            roles: [.windowsDriver, .windowsService],
            signature: .appleDeveloperID
        )
        #expect(windowsWithAppleSignature.validationIssues().contains {
            $0.code == .invalidSignature
        })
    }

    @Test("qualification binds the exact manifest and complete capability set")
    func qualificationBinding() {
        var manifest = package(
            family: .linux,
            roles: [.linuxToolsArchive],
            signature: .doryEd25519
        )
        manifest.state = .qualified
        #expect(manifest.validationIssues().contains { $0.code == .invalidQualification })

        manifest.qualification = DoryGuestIntegrationQualificationEvidence(
            manifestIdentity: manifest.manifestIdentity,
            manifestSHA256: digest,
            suiteSHA256: digest,
            sbomSHA256: digest,
            attestationSHA256: digest,
            qualifiedCapabilities: manifest.capabilities
        )
        #expect(manifest.isValidForPersistence)

        manifest.qualification?.qualifiedCapabilities.removeLast()
        #expect(manifest.validationIssues().contains { $0.code == .invalidQualification })
    }

    @Test("canonical ordering, versions, resolver keys, and digests fail closed")
    func malformedAuthorityRejected() {
        var manifest = package(
            family: .linux,
            roles: [.linuxToolsArchive],
            signature: .doryEd25519
        )
        manifest.capabilities.reverse()
        manifest.artifacts[0].artifact = .init(namespace: "path", identifier: "/tmp/payload")
        manifest.artifacts[0].sha256 = String(repeating: "A", count: 64)
        manifest.artifacts[0].signature.signatureSHA256 = "bad"

        let codes = Set(manifest.validationIssues().map(\.code))
        #expect(codes.contains(.invalidCapabilities))
        #expect(codes.contains(.invalidArtifacts))
        #expect(codes.contains(.invalidSignature))
    }

    private func package(
        family: DoryGuestFamily,
        roles: [DoryGuestIntegrationArtifactRole],
        signature: DoryGuestIntegrationSignatureKind
    ) -> DoryGuestIntegrationPackageManifest {
        let capabilities = [
            DoryGuestIntegrationCapabilityDeclaration(id: .readiness, version: 1),
            DoryGuestIntegrationCapabilityDeclaration(id: .telemetry, version: 1),
        ].sorted { $0.id.rawValue < $1.id.rawValue }
        let artifacts = roles.enumerated().map { index, role in
            DoryGuestIntegrationArtifact(
                id: "payload-\(index)-\(role.rawValue)",
                role: role,
                artifact: .init(
                    namespace: "guest-tools",
                    identifier: "\(family.rawValue)-arm64-\(index)"
                ),
                sha256: digest,
                byteCount: 1024,
                signature: .init(
                    kind: signature,
                    identity: "Dory Guest Tools Test Identity",
                    signatureSHA256: digest
                )
            )
        }.sorted { $0.id < $1.id }
        return DoryGuestIntegrationPackageManifest(
            manifestIdentity: "dory-tools-\(family.rawValue)-arm64-v1",
            packageVersion: "1.0.0",
            guest: .init(family: family, architecture: .arm64),
            protocolVersion: 1,
            state: .contractOnly,
            capabilities: capabilities,
            artifacts: artifacts
        )
    }
}
