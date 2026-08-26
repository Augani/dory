import CryptoKit
@testable import DoryRendererWorkerWireContracts
import Foundation
import Testing

@Suite("Renderer production inventory")
struct DoryRendererProductionInventoryTests {
    @Test("canonical bundle inventory binds the final worker and ANGLE Metal pair")
    func canonicalInventory() throws {
        let bytes = try inventoryBytes()
        let decoded = try DoryRendererProductionInventory.decodeCanonical(bytes)

        #expect(decoded.candidateInventory.bytes == Data(SHA256.hash(data: bytes)))
        #expect(decoded.definition.lowercaseSHA256
            == DoryRendererSourceTuple.productionDefinitionSHA256)
        #expect(Set(decoded.components.keys)
            == Set(DoryRendererProductionInventory.expectedFiles.keys))
        #expect(try decoded.componentDigest("rendererWorker")
            == decoded.components["rendererWorker"]?.digest)
        #expect(try decoded.componentDigest("angleMetal")
            == decoded.components["angleMetal"]?.digest)
    }

    @Test("noncanonical and mismatched inventories fail closed")
    func rejectsAmbiguityAndDrift() throws {
        let canonical = try inventoryBytes()
        #expect(throws: DoryRendererProductionInventoryError.nonCanonicalJSON) {
            _ = try DoryRendererProductionInventory.decodeCanonical(
                Data(" \n".utf8) + canonical
            )
        }

        var root = try #require(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        root["definitionSha256"] = String(repeating: "a", count: 64)
        #expect(throws: DoryRendererProductionInventoryError.definitionMismatch) {
            _ = try DoryRendererProductionInventory.decodeCanonical(
                try canonicalBytes(root)
            )
        }

        root = try #require(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        var components = try #require(root["components"] as? [String: Any])
        var worker = try #require(components["rendererWorker"] as? [String: Any])
        worker["digest"] = String(repeating: "b", count: 64)
        components["rendererWorker"] = worker
        root["components"] = components
        #expect(throws: DoryRendererProductionInventoryError.componentMismatch(
            "rendererWorker"
        )) {
            _ = try DoryRendererProductionInventory.decodeCanonical(
                try canonicalBytes(root)
            )
        }

        root = try #require(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        root["schemaVersion"] = 1
        #expect(throws: DoryRendererProductionInventoryError.schemaMismatch) {
            _ = try DoryRendererProductionInventory.decodeCanonical(
                try canonicalBytes(root)
            )
        }
    }

    @Test("hex digests reject uppercase zero and malformed input")
    func exactDigestText() throws {
        let valid = String(repeating: "ab", count: 32)
        let digest = try DoryRendererArtifactDigest(lowercaseSHA256: valid)
        #expect(digest.lowercaseSHA256 == valid)
        #expect(throws: DoryRendererWorkerContractError.invalidDigest(field: "digest")) {
            _ = try DoryRendererArtifactDigest(lowercaseSHA256: valid.uppercased())
        }
        #expect(throws: DoryRendererWorkerContractError.invalidDigest(field: "digest")) {
            _ = try DoryRendererArtifactDigest(
                lowercaseSHA256: String(repeating: "0", count: 64)
            )
        }
    }

    @Test("canonical key order is bytewise across punctuation")
    func punctuationOrderingIsCrossLanguage() throws {
        let base = try inventoryBytes()
        let needle = Data("\"buildPolicy\":{}".utf8)
        let replacement = Data(
            "\"buildPolicy\":{\"meson.build\":\"dot\",\"meson_options.txt\":\"underscore\"}".utf8
        )
        let range = try #require(base.range(of: needle))
        var bytewise = base
        bytewise.replaceSubrange(range, with: replacement)
        _ = try DoryRendererProductionInventory.decodeCanonical(bytewise)

        let noncanonicalReplacement = Data(
            "\"buildPolicy\":{\"meson_options.txt\":\"underscore\",\"meson.build\":\"dot\"}".utf8
        )
        var foundationOrder = base
        foundationOrder.replaceSubrange(range, with: noncanonicalReplacement)
        #expect(throws: DoryRendererProductionInventoryError.nonCanonicalJSON) {
            _ = try DoryRendererProductionInventory.decodeCanonical(foundationOrder)
        }
    }

    private func inventoryBytes() throws -> Data {
        var components = [String: Any]()
        for name in DoryRendererProductionInventory.expectedFiles.keys.sorted() {
            let paths = DoryRendererProductionInventory.expectedFiles[name]!
            let files: [[String: Any]] = paths.enumerated().map { index, path in
                [
                    "bytes": index + 1,
                    "path": path,
                    "sha256": String(repeating: String(format: "%x", index + 1), count: 64),
                ]
            }
            let digestPayload: [String: Any] = ["files": files, "name": name]
            let digest = SHA256.hash(data: try canonicalBytes(digestPayload))
                .map { String(format: "%02x", $0) }.joined()
            components[name] = ["digest": digest, "files": files]
        }
        return try canonicalBytes([
            "architecture": "arm64",
            "buildPolicy": [:],
            "components": components,
            "dependencyBuildPolicy": [:],
            "dependencySources": [:],
            "definitionSha256": DoryRendererSourceTuple.productionDefinitionSHA256,
            "guestMesaBuildPolicy": [:],
            "kind": "dev.dory.renderer-artifact-inventory",
            "platform": "macos",
            "producerFence": [:],
            "profile": "rendererBundle",
            "schemaVersion": 3,
            "sourceTuple": "dory-dual-metal-20260826",
            "sources": [:],
            "toolchain": [:],
        ])
    }

    private func canonicalBytes(_ object: Any) throws -> Data {
        try DoryRendererProductionInventory.canonicalJSONData(object)
            + Data("\n".utf8)
    }
}
