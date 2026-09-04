import Darwin
import Foundation
import Testing
@testable import DoryOperations

@Suite("Runtime artifact backing ownership")
struct DoryArtifactBackingOwnershipTests {
    @Test("guest writes retain ownership without refreshing strict launch authority")
    func writesDoNotMintFreshEvidence() throws {
        let fixture = try BackingFixture()
        defer { fixture.cleanup() }
        let publication = try fixture.publishMutable()
        let before = try fixture.authorityBytes()
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.seek(toOffset: 10)
        try handle.write(contentsOf: Data("workload writes".utf8))
        try handle.synchronize()
        try handle.close()
        try fixture.validate(publication)
        #expect(throws: DoryVirtualMachineArtifactAuthorityError.artifactChanged) {
            try fixture.authority.resolve(reference: fixture.reference,
                                          kind: .virtualDisk, source: .userProvided)
        }
        #expect(try fixture.authorityBytes() == before)
    }

    @Test("mutable ownership rejects replaced, redirected, truncated and unsafe backing",
          arguments: ["inode", "symlink", "truncate", "extend", "hardlink", "permissions", "fifo"])
    func unsafeMutableBacking(change: String) throws {
        let fixture = try BackingFixture()
        defer { fixture.cleanup() }
        let publication = try fixture.publishMutable()
        let before = try fixture.authorityBytes()
        switch change {
        case "inode":
            let replacement = fixture.root.appendingPathComponent("replacement")
            try fixture.makeFile(replacement)
            #expect(rename(replacement.path, fixture.file.path) == 0)
        case "symlink":
            let replacement = fixture.root.appendingPathComponent("replacement")
            try fixture.makeFile(replacement)
            try FileManager.default.removeItem(at: fixture.file)
            try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: replacement)
        case "truncate", "extend":
            let handle = try FileHandle(forWritingTo: fixture.file)
            try handle.truncate(atOffset: change == "truncate" ? 2_048 : 8_192)
            try handle.close()
        case "hardlink":
            #expect(link(fixture.file.path, fixture.root.appendingPathComponent("alias").path) == 0)
        case "permissions":
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.file.path)
        case "fifo":
            try FileManager.default.removeItem(at: fixture.file)
            #expect(mkfifo(fixture.file.path, 0o600) == 0)
        default: Issue.record("Unknown mutation")
        }
        #expect(throws: DoryVirtualMachineArtifactAuthorityError.self) { try fixture.validate(publication) }
        #expect(try fixture.authorityBytes() == before)
    }

    @Test("immutable kernel bytes remain exact during ownership validation",
          arguments: ["write", "truncate", "symlink", "fifo"])
    func immutableMediaRemainsStrict(change: String) throws {
        let fixture = try BackingFixture()
        defer { fixture.cleanup() }
        let publication = try fixture.authority.publishImmutable(
            reference: fixture.reference, path: fixture.file.path,
            kind: .linuxKernel, source: .bundledByDory
        )
        try fixture.validate(publication)
        let before = try fixture.authorityBytes()
        if change == "fifo" || change == "symlink" {
            try FileManager.default.removeItem(at: fixture.file)
            if change == "fifo" { #expect(mkfifo(fixture.file.path, 0o600) == 0) }
            else {
                let other = fixture.root.appendingPathComponent("other")
                try fixture.makeFile(other)
                try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: other)
            }
        } else {
            let handle = try FileHandle(forWritingTo: fixture.file)
            if change == "truncate" { try handle.truncate(atOffset: 2_048) }
            else { try handle.write(contentsOf: Data([0x42])) }
            try handle.close()
        }
        #expect(throws: DoryVirtualMachineArtifactAuthorityError.self) { try fixture.validate(publication) }
        #expect(try fixture.authorityBytes() == before)
    }

    @Test("current authority must match the exact planned publication",
          arguments: ["revision", "path", "media", "evidence", "missingEvidence", "republished"])
    func publicationMustBeExact(change: String) throws {
        let fixture = try BackingFixture()
        defer { fixture.cleanup() }
        let publication = try fixture.publishMutable()
        var evidence = publication.mutableProvenance?.persistedAuditEvidence
        if change == "evidence" { evidence?.receiptSHA256 = String(repeating: "a", count: 64) }
        if change == "missingEvidence" { evidence = nil }
        if change == "republished" {
            _ = try fixture.authority.publishMutable(
                reference: fixture.reference, path: fixture.file.path,
                source: .userProvided, expectedAuthorityRevision: 1
            )
        }
        let before = try fixture.authorityBytes()
        #expect(throws: DoryVirtualMachineArtifactAuthorityError.self) {
            try fixture.authority.validateBackingOwnership(
                reference: fixture.reference,
                path: change == "path" ? fixture.root.appendingPathComponent("other").path : fixture.file.path,
                media: change == "media" ? DoryBootMedia(kind: .virtualDisk, source: .bundledByDory,
                                                         mutableProvenance: publication.media.mutableProvenance)
                                         : publication.media,
                authorityRevision: change == "revision" ? 2 : publication.authorityRevision,
                mutableProvenanceEvidence: evidence
            )
        }
        #expect(try fixture.authorityBytes() == before)
    }

    @Test("ownership reads do not initialize a missing authority repository")
    func missingAuthorityRemainsAbsent() throws {
        let fixture = try BackingFixture()
        defer { fixture.cleanup() }
        #expect(throws: DoryVirtualMachineArtifactAuthorityError.self) {
            try fixture.authority.validateBackingOwnership(
                reference: fixture.reference, path: fixture.file.path,
                media: DoryBootMedia(kind: .linuxKernel, source: .bundledByDory,
                                    artifactSHA256: String(repeating: "a", count: 64)),
                authorityRevision: 1, mutableProvenanceEvidence: nil
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.authority.root))
    }
}

private struct BackingFixture {
    let root: URL
    let file: URL
    let authority: DoryVirtualMachineArtifactAuthority
    let reference = DoryVMResolverReference(namespace: "backing", identifier: "system")

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-backing-\(UUID())").standardizedFileURL
        file = root.appendingPathComponent("artifact")
        authority = DoryVirtualMachineArtifactAuthority(root: root.appendingPathComponent("authority").path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try makeFile(file)
    }

    func makeFile(_ url: URL) throws {
        try Data(repeating: 0x41, count: 4_096).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func publishMutable() throws -> DoryVerifiedVirtualMachineArtifact {
        try authority.publishMutable(reference: reference, path: file.path, source: .userProvided)
    }

    func validate(_ publication: DoryVerifiedVirtualMachineArtifact) throws {
        try authority.validateBackingOwnership(
            reference: reference, path: file.path, media: publication.media,
            authorityRevision: publication.authorityRevision,
            mutableProvenanceEvidence: publication.mutableProvenance?.persistedAuditEvidence
        )
    }

    func authorityBytes() throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: authority.root)
        return try Dictionary(uniqueKeysWithValues: names.map { name in
            (name, try Data(contentsOf: URL(fileURLWithPath: authority.root).appendingPathComponent(name)))
        })
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
