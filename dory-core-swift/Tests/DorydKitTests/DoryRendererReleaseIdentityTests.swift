@testable import DorydKit
import DoryOperations
import DoryRendererWorkerWireContracts
import Foundation
import Security
import Testing

@Suite("Renderer release identity")
struct DoryRendererReleaseIdentityTests {
    private let runnerCDHash = String(repeating: "a1", count: 20)
    private let workerCDHash = String(repeating: "ab", count: 20)

    @Test("canonical entitlement binds the directed release chain")
    func canonicalEntitlement() throws {
        let dictionary = fixture()
        let identity = try DoryRendererReleaseIdentityV1.decode(
            entitlementDictionary: dictionary
        )

        #expect(identity.runnerCodeDirectoryHash.lowercaseHexadecimal == runnerCDHash)
        #expect(identity.rendererWorkerCodeDirectoryHash.lowercaseHexadecimal
            == workerCDHash)
        #expect(identity.tupleDefinitionSHA256.lowercaseSHA256
            == DoryRendererSourceTuple.productionDefinitionSHA256)

        let provider: any DoryRendererReleaseIdentityProviding = FixtureProvider(
            identity: identity
        )
        #expect(try provider.loadReleaseIdentity() == identity)
    }

    @Test("entitlement rejects missing extra and mistyped fields")
    func rejectsNonCanonicalShape() {
        var dictionary = fixture()
        dictionary.removeValue(forKey: "runner-cdhash")
        #expect(throws: DoryRendererReleaseIdentityError.nonCanonicalEntitlement) {
            _ = try DoryRendererReleaseIdentityV1.decode(
                entitlementDictionary: dictionary
            )
        }

        dictionary = fixture()
        dictionary["unreviewed"] = "value"
        #expect(throws: DoryRendererReleaseIdentityError.nonCanonicalEntitlement) {
            _ = try DoryRendererReleaseIdentityV1.decode(
                entitlementDictionary: dictionary
            )
        }

        dictionary = fixture()
        dictionary["schema-version"] = "1"
        #expect(throws: DoryRendererReleaseIdentityError.nonCanonicalEntitlement) {
            _ = try DoryRendererReleaseIdentityV1.decode(
                entitlementDictionary: dictionary
            )
        }

        for wrongNumberType: Any in [
            true,
            NSNumber(value: true),
            NSNumber(value: 1.0),
        ] {
            dictionary = fixture()
            dictionary["schema-version"] = wrongNumberType
            #expect(throws: DoryRendererReleaseIdentityError.nonCanonicalEntitlement) {
                _ = try DoryRendererReleaseIdentityV1.decode(
                    entitlementDictionary: dictionary
                )
            }
        }
    }

    @Test("entitlement rejects unsupported generations and tuple drift")
    func rejectsVersionAndTupleDrift() {
        var dictionary = fixture()
        dictionary["schema-version"] = 2
        #expect(throws: DoryRendererReleaseIdentityError.unsupportedSchemaVersion(2)) {
            _ = try DoryRendererReleaseIdentityV1.decode(
                entitlementDictionary: dictionary
            )
        }

        dictionary = fixture()
        dictionary["tuple-definition-sha256"] = String(repeating: "cd", count: 32)
        #expect(throws: DoryRendererReleaseIdentityError.tupleDefinitionMismatch) {
            _ = try DoryRendererReleaseIdentityV1.decode(
                entitlementDictionary: dictionary
            )
        }
    }

    @Test("entitlement requires canonical nonzero CDHashes")
    func rejectsInvalidCDHashes() {
        var dictionary = fixture()
        dictionary["runner-cdhash"] = runnerCDHash.uppercased()
        #expect(throws: DoryRendererReleaseIdentityError.invalidCodeDirectoryHash(
            field: "runner-cdhash"
        )) {
            _ = try DoryRendererReleaseIdentityV1.decode(
                entitlementDictionary: dictionary
            )
        }

        dictionary = fixture()
        dictionary["renderer-worker-cdhash"] = String(repeating: "0", count: 40)
        #expect(throws: DoryRendererReleaseIdentityError.invalidCodeDirectoryHash(
            field: "renderer-worker-cdhash"
        )) {
            _ = try DoryRendererReleaseIdentityV1.decode(
                entitlementDictionary: dictionary
            )
        }
    }

    @Test("exact requirements compile as Security requirements")
    func requirementsCompile() throws {
        let runner = try DoryCodeDirectoryHash(lowercaseHexadecimal: runnerCDHash)
        let worker = try DoryCodeDirectoryHash(lowercaseHexadecimal: workerCDHash)
        for requirementText in [
            DoryRendererWorkerIdentity.exactRunnerCodeSigningRequirement(
                codeDirectoryHash: runner
            ),
            DoryRendererWorkerIdentity.exactWorkerCodeSigningRequirement(
                codeDirectoryHash: worker
            ),
        ] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(
                requirementText as CFString,
                SecCSFlags(),
                &requirement
            ) == errSecSuccess)
            #expect(requirement != nil)
        }
    }

    @Test("production pre-spawn selects identity only for RawHV hardware 3D")
    func productionPreSpawnSelection() throws {
        let identity = try DoryRendererReleaseIdentityV1.decode(
            entitlementDictionary: fixture()
        )
        let selected = try DoryProductionRendererReleaseIdentityAuthority.resolve(
            backend: .doryHypervisor,
            graphics: .hardwareAccelerated3D,
            provider: FixtureProvider(identity: identity)
        )
        #expect(selected == .rendererReleaseIdentity(identity))

        for (backend, graphics) in [
            (DoryVirtualizationBackendIdentity.appleVirtualizationFramework,
             DoryGraphicsAccelerationLevel.hardwareAccelerated3D),
            (.doryHypervisor, .hostAcceleratedDisplay),
            (.doryHypervisor, .software),
            (.doryHypervisor, .none),
        ] {
            let notRequired = try DoryProductionRendererReleaseIdentityAuthority.resolve(
                backend: backend,
                graphics: graphics,
                provider: RejectingProvider()
            )
            #expect(notRequired == .noRendererReleaseIdentityRequired)
        }
    }

    @Test("production pre-spawn rejects typed tuple drift")
    func productionPreSpawnRejectsTupleDrift() throws {
        let canonical = try DoryRendererReleaseIdentityV1.decode(
            entitlementDictionary: fixture()
        )
        let drifted = DoryRendererReleaseIdentityV1(
            runnerCodeDirectoryHash: canonical.runnerCodeDirectoryHash,
            rendererWorkerCodeDirectoryHash:
                canonical.rendererWorkerCodeDirectoryHash,
            tupleDefinitionSHA256: try DoryRendererArtifactDigest(
                lowercaseSHA256: String(repeating: "cd", count: 32)
            )
        )
        #expect(throws: DoryRendererReleaseIdentityError.tupleDefinitionMismatch) {
            _ = try DoryProductionRendererReleaseIdentityAuthority.resolve(
                backend: .doryHypervisor,
                graphics: .hardwareAccelerated3D,
                provider: FixtureProvider(identity: drifted)
            )
        }
    }

    private func fixture() -> [String: Any] {
        [
            "schema-version": DoryRendererReleaseIdentityV1.schemaVersion,
            "runner-cdhash": runnerCDHash,
            "renderer-worker-cdhash": workerCDHash,
            "tuple-definition-sha256":
                DoryRendererSourceTuple.productionDefinitionSHA256,
        ]
    }

    private struct FixtureProvider: DoryRendererReleaseIdentityProviding {
        let identity: DoryRendererReleaseIdentityV1

        func loadReleaseIdentity() throws -> DoryRendererReleaseIdentityV1 {
            identity
        }
    }

    private struct RejectingProvider: DoryRendererReleaseIdentityProviding {
        func loadReleaseIdentity() throws -> DoryRendererReleaseIdentityV1 {
            throw DoryRendererReleaseIdentityError.entitlementUnavailable
        }
    }
}
