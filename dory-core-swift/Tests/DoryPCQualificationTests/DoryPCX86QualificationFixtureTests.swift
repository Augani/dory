import CryptoKit
import DoryPCQualification
import Foundation
import Testing

@Suite("DoryPC x86 qualification fixtures")
struct DoryPCX86QualificationFixtureTests {
  @Test("imports verified inputs under immutable content identities")
  func importsContentAddressedFixtures() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let manifestData = try fixture.manifestData()
    let importer = try DoryPCX86QualificationFixtureImporter(storeDirectory: fixture.store)

    let first = try importer.importFixtures(
      manifestData: manifestData, sourceDirectory: fixture.sources)
    #expect(first.schema == DoryPCX86QualificationFixtureImportReceipt.schemaIdentity)
    #expect(!first.qualified)
    #expect(first.objects.map(\.publication) == ["published", "published"])
    #expect(first.objects.map(\.role) == [.pvhInitrd, .pvhKernel])
    for object in first.objects {
      let stored = fixture.store.appendingPathComponent(object.objectRelativePath)
      #expect(try Data(contentsOf: stored) == fixture.data[object.role])
      #expect(stored.lastPathComponent == object.sha256)
    }

    let second = try importer.importFixtures(
      manifestData: manifestData, sourceDirectory: fixture.sources)
    #expect(second.manifestSHA256 == first.manifestSHA256)
    #expect(second.objects.map(\.publication) == ["verified-existing", "verified-existing"])
  }

  @Test("rejects source mutation without replacing an accepted object")
  func rejectsMutatedSource() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let importer = try DoryPCX86QualificationFixtureImporter(storeDirectory: fixture.store)
    let manifestData = try fixture.manifestData()
    let accepted = try importer.importFixtures(
      manifestData: manifestData, sourceDirectory: fixture.sources)
    let kernel = try #require(accepted.objects.first(where: { $0.role == .pvhKernel }))
    let acceptedBytes = try Data(contentsOf: fixture.store.appendingPathComponent(
      kernel.objectRelativePath))

    try Data("kernem".utf8).write(
      to: fixture.sources.appendingPathComponent("kernel.elf"), options: [.atomic])
    #expect(throws: DoryPCX86QualificationFixtureError.digestMismatch("kernel.elf")) {
      try importer.importFixtures(manifestData: manifestData, sourceDirectory: fixture.sources)
    }
    #expect(
      try Data(contentsOf: fixture.store.appendingPathComponent(kernel.objectRelativePath))
        == acceptedBytes)
  }

  @Test("rejects symlink inputs and incomplete purpose manifests")
  func rejectsUnsafeInputsAndRoles() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let importer = try DoryPCX86QualificationFixtureImporter(storeDirectory: fixture.store)
    let target = fixture.sources.appendingPathComponent("actual-kernel")
    try fixture.data[.pvhKernel]!.write(to: target)
    try FileManager.default.removeItem(
      at: fixture.sources.appendingPathComponent("kernel.elf"))
    try FileManager.default.createSymbolicLink(
      at: fixture.sources.appendingPathComponent("kernel.elf"),
      withDestinationURL: target)
    #expect(throws: DoryPCX86QualificationFixtureError.filesystem("open source kernel.elf")) {
      try importer.importFixtures(
        manifestData: fixture.manifestData(), sourceDirectory: fixture.sources)
    }

    let incomplete = fixture.manifest(
      purpose: .combined,
      artifacts: fixture.manifest().artifacts)
    #expect(throws: DoryPCX86QualificationFixtureError.invalidManifest("artifact roles")) {
      try incomplete.validate()
    }
  }

  private final class Fixture {
    let root: URL
    let sources: URL
    let store: URL
    let data: [DoryPCX86QualificationFixtureManifest.Artifact.Role: Data]

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "dory-x86-fixture-tests-\(UUID().uuidString)", isDirectory: true)
      sources = root.appendingPathComponent("sources", isDirectory: true)
      store = root.appendingPathComponent("store", isDirectory: true)
      data = [.pvhKernel: Data("kernel".utf8), .pvhInitrd: Data("initrd".utf8)]
      try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
      try data[.pvhKernel]!.write(to: sources.appendingPathComponent("kernel.elf"))
      try data[.pvhInitrd]!.write(to: sources.appendingPathComponent("initrd.cpio"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func manifestData() throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(manifest())
    }

    func manifest(
      purpose: DoryPCX86QualificationFixtureManifest.Purpose = .pvhSmoke,
      artifacts: [DoryPCX86QualificationFixtureManifest.Artifact]? = nil
    ) -> DoryPCX86QualificationFixtureManifest {
      let entries = artifacts ?? [
        artifact(.pvhKernel, name: "kernel.elf"),
        artifact(.pvhInitrd, name: "initrd.cpio"),
      ]
      return .init(
        catalogID: "test-pvh-x86_64",
        purpose: purpose,
        producer: .init(
          builderSHA256: Self.digest(Data("builder".utf8)),
          recipeSHA256: Self.digest(Data("recipe".utf8)),
          toolchainIdentitySHA256: Self.digest(Data("toolchain".utf8)),
          toolchainDescription: "test toolchain lock",
          environmentKind: .container,
          environmentIdentitySHA256: Self.digest(Data("container".utf8)),
          environmentDescription: "test container manifest"
        ),
        artifacts: entries)
    }

    private func artifact(
      _ role: DoryPCX86QualificationFixtureManifest.Artifact.Role,
      name: String
    ) -> DoryPCX86QualificationFixtureManifest.Artifact {
      let bytes = data[role]!
      return .init(
        role: role,
        importFileName: name,
        sha256: Self.digest(bytes),
        byteCount: UInt64(bytes.count),
        sourceURL: "https://fixtures.example.invalid/source.iso",
        sourceArtifactSHA256: Self.digest(Data("source ISO".utf8)),
        licenseSPDX: "GPL-2.0-only",
        derivation: "test-only exact-byte extraction"
      )
    }

    private static func digest(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
  }
}
