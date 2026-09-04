import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DorydKit

@Suite("Machine artifact verification handoff")
struct DoryMachineArtifactProofTests {
    @Test("unchanged same-context checks reuse content verification and recovery verifies anew")
    func boundedVerification() throws {
        let fixture = try ArtifactProofFixture()
        defer { fixture.cleanup() }
        var hashes = 0
        let hash: (Int32) throws -> String = { descriptor in
            hashes += 1
            return try fixture.hash(descriptor)
        }
        let proof = try DoryMachineArtifactProof(configuration: fixture.machine, evidence: fixture.evidence, hash: hash)
        #expect(hashes == 2)
        for _ in 0..<8 { try proof.validate(configuration: fixture.machine, evidence: fixture.evidence) }
        #expect(hashes == 2)
        _ = try DoryMachineArtifactProof(configuration: fixture.machine, evidence: fixture.evidence, hash: hash)
        #expect(hashes == 4)
        var swappedEvidence = fixture.evidence
        swappedEvidence.rootfs.sha256 = String(repeating: "f", count: 64)
        #expect(throws: (any Error).self) { try proof.validate(configuration: fixture.machine, evidence: swappedEvidence) }
    }

    @Test("same-inode writes, timestamp resets and pathname replacements invalidate prior verification",
          arguments: ["write", "replace", "symlink"])
    func rejectsMutation(mutation: String) throws {
        let fixture = try ArtifactProofFixture()
        defer { fixture.cleanup() }
        let proof = try DoryMachineArtifactProof(configuration: fixture.machine,
            evidence: fixture.evidence, hash: fixture.hash)
        let path = fixture.machine.rootfsPath
        let originalDate = try #require(FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        if mutation == "write" {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.write(contentsOf: Data([0xff]))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: path)
        } else {
            try FileManager.default.removeItem(atPath: path)
            if mutation == "symlink" { try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: fixture.machine.kernelPath) }
            else {
                try fixture.bytes.write(to: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: originalDate], ofItemAtPath: path)
            }
        }
        #expect(throws: (any Error).self) { try proof.validate(configuration: fixture.machine, evidence: fixture.evidence) }
    }

    @Test("mutation during initial content verification cannot produce a reusable proof")
    func rejectsMutationDuringHash() throws {
        let fixture = try ArtifactProofFixture()
        defer { fixture.cleanup() }
        #expect(throws: (any Error).self) {
            try DoryMachineArtifactProof(configuration: fixture.machine, evidence: fixture.evidence) { descriptor in
                let digest = try fixture.hash(descriptor)
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.machine.rootfsPath))
                try handle.write(contentsOf: Data([0xff])); try handle.close()
                return digest
            }
        }
    }

    @Test("snapshot firmware bindings participate in verification and cannot be omitted on reuse")
    func completeSnapshotBindings() throws {
        let fixture = try ArtifactProofFixture()
        defer { fixture.cleanup() }
        let firmwarePaths = ["identifier", "nvram"].map { fixture.root.appendingPathComponent($0).path }
        for path in firmwarePaths {
            try fixture.bytes.write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        let paths = [fixture.machine.rootfsPath, fixture.machine.kernelPath] + firmwarePaths
        let bindings = paths.map { DoryMachineArtifactProof.Binding(path: $0, evidence: fixture.evidence.rootfs) }
        var hashes = 0
        let proof = try DoryMachineArtifactProof(bindings: bindings) { descriptor in
            hashes += 1
            return try fixture.hash(descriptor)
        }
        #expect(hashes == 4)
        try proof.validate(bindings: bindings)
        #expect(hashes == 4)
        #expect(throws: (any Error).self) { try proof.validate(bindings: Array(bindings.dropLast())) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: firmwarePaths[1]))
        try handle.write(contentsOf: Data([0xff]))
        try handle.close()
        #expect(throws: (any Error).self) { try proof.validate(bindings: bindings) }
        #expect(throws: (any Error).self) {
            try DoryMachineArtifactProof(bindings: bindings, hash: fixture.hash)
        }
    }

    @Test("empty and ambiguous artifact sets cannot mint a proof")
    func unboundArtifactsRejected() throws {
        let fixture = try ArtifactProofFixture()
        defer { fixture.cleanup() }
        let binding = DoryMachineArtifactProof.Binding(path: fixture.machine.rootfsPath,
            evidence: fixture.evidence.rootfs)
        for bindings in [[], [binding, binding]] {
            #expect(throws: (any Error).self) {
                try DoryMachineArtifactProof(bindings: bindings, hash: fixture.hash)
            }
        }
    }
}

private struct ArtifactProofFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("creation-proof-\(UUID())")
    let bytes = Data(repeating: 0x41, count: 1_048_583)
    var machine: DoryMachineConfiguration {
        .init(id: "clone", kernelPath: root.appendingPathComponent("kernel").path,
              rootfsPath: root.appendingPathComponent("rootfs").path)
    }
    var evidence: DoryMachineSnapshotArtifactEvidence {
        let artifact = DoryMachineSnapshotArtifact(byteCount: UInt64(bytes.count), sha256: digest(bytes))
        return .init(rootfs: artifact, kernel: artifact)
    }
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for path in [machine.rootfsPath, machine.kernelPath] {
            try bytes.write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
    func hash(_ descriptor: Int32) throws -> String {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return digest(try handle.readToEnd() ?? Data())
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
