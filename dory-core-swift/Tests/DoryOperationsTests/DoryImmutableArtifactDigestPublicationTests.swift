import CryptoKit
import Foundation
import Testing
@testable import DoryOperations

@Suite("Immutable artifact publication digest binding")
struct DoryImmutableArtifactDigestPublicationTests {
    @Test("replacement requires the pinned digest and current revision without changing prior authority",
          arguments: ["incorrect", "uppercase", "malformed", "staleRevision"])
    func rejectsUnpinnedReplacement(change: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-pinned-publication-\(UUID())").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("kernel")
        try Data("original".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let authority = DoryVirtualMachineArtifactAuthority(root: root.appendingPathComponent("authority").path)
        let reference = DoryVMResolverReference(namespace: "artifact", identifier: "kernel")
        _ = try authority.publishImmutable(reference: reference, path: file.path,
                                           kind: .linuxKernel, source: .bundledByDory)
        let original = try authority.authorityRecord(reference: reference)
        let target = Data("qualified replacement".utf8)
        try target.write(to: file)
        let digest = SHA256.hash(data: target).map { String(format: "%02x", $0) }.joined()
        let expectedDigest: String
        switch change {
        case "incorrect": expectedDigest = String(repeating: "0", count: 64)
        case "uppercase": expectedDigest = digest.uppercased()
        case "malformed": expectedDigest = "not-a-digest"
        default: expectedDigest = digest
        }
        let expectedError: DoryVirtualMachineArtifactAuthorityError = change == "staleRevision"
            ? .staleRevision(expected: 2, actual: 1) : .artifactChanged
        #expect(throws: expectedError) {
            try authority.publishImmutable(reference: reference, path: file.path,
                                           kind: .linuxKernel, source: .bundledByDory,
                                           expectedAuthorityRevision: change == "staleRevision" ? 2 : 1,
                                           expectedSHA256: expectedDigest)
        }
        #expect(try authority.authorityRecord(reference: reference) == original)
        #expect(try Data(contentsOf: file) == target)
        let published = try authority.publishImmutable(reference: reference, path: file.path,
                                                       kind: .linuxKernel, source: .bundledByDory,
                                                       expectedAuthorityRevision: 1, expectedSHA256: digest)
        #expect(published.authorityRevision == 2)
        #expect(published.media.artifactSHA256 == digest)
    }
}
