@testable import DoryRendererWorkerWireContracts
import Foundation
import Testing

@Suite("Renderer code identity")
struct DoryCodeDirectoryHashTests {
    @Test("CDHash has one canonical 20-byte spelling")
    func canonicalHash() throws {
        let text = String(repeating: "ab", count: DoryCodeDirectoryHash.byteCount)
        let hash = try DoryCodeDirectoryHash(lowercaseHexadecimal: text)

        #expect(hash.bytes == Data(repeating: 0xab, count: 20))
        #expect(hash.lowercaseHexadecimal == text)
        #expect(try DoryCodeDirectoryHash(bytes: hash.bytes) == hash)
    }

    @Test("CDHash rejects ambiguous and uninitialized values")
    func rejectsMalformedHash() {
        let field = "fixture"
        let expected = DoryRendererWorkerContractError.invalidCodeDirectoryHash(
            field: field
        )
        #expect(throws: expected) {
            _ = try DoryCodeDirectoryHash(
                lowercaseHexadecimal: String(repeating: "ab", count: 19),
                field: field
            )
        }
        #expect(throws: expected) {
            _ = try DoryCodeDirectoryHash(
                lowercaseHexadecimal: String(repeating: "AB", count: 20),
                field: field
            )
        }
        #expect(throws: expected) {
            _ = try DoryCodeDirectoryHash(
                lowercaseHexadecimal: String(repeating: "0", count: 40),
                field: field
            )
        }
        #expect(throws: expected) {
            _ = try DoryCodeDirectoryHash(
                bytes: Data(repeating: 0xab, count: 19),
                field: field
            )
        }
    }

    @Test("exact requirements bind identifier team and CDHash")
    func exactRequirements() throws {
        let text = String(repeating: "12", count: 20)
        let hash = try DoryCodeDirectoryHash(lowercaseHexadecimal: text)

        #expect(DoryRendererWorkerIdentity.exactWorkerCodeSigningRequirement(
            codeDirectoryHash: hash
        ) == DoryRendererWorkerIdentity.workerCodeSigningRequirement
            + " and cdhash H\"\(text)\"")
        #expect(DoryRendererWorkerIdentity.exactRunnerCodeSigningRequirement(
            codeDirectoryHash: hash
        ) == DoryRendererWorkerIdentity.runnerCodeSigningRequirement
            + " and cdhash H\"\(text)\"")
    }
}
