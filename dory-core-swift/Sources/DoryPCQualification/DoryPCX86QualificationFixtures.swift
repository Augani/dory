import CryptoKit
import Darwin
import Foundation

public struct DoryPCX86QualificationFixtureManifest: Codable, Equatable, Sendable {
  public static let schemaIdentity = "dev.dory.pc-x86-qualification-fixtures@1"

  public enum Purpose: String, Codable, CaseIterable, Hashable, Sendable {
    case pvhSmoke = "pvh-smoke"
    case uefiInstaller = "uefi-installer"
    case combined

    fileprivate var requiredRoles: Set<Artifact.Role> {
      switch self {
      case .pvhSmoke: [.pvhKernel, .pvhInitrd]
      case .uefiInstaller: [.firmwareCode, .firmwareVariables, .installerISO]
      case .combined:
        [.pvhKernel, .pvhInitrd, .firmwareCode, .firmwareVariables, .installerISO]
      }
    }
  }

  public struct Producer: Codable, Equatable, Sendable {
    public enum EnvironmentKind: String, Codable, Sendable {
      case container
      case hostToolchain = "host-toolchain"
    }

    public let builderSHA256: String
    public let recipeSHA256: String
    public let toolchainIdentitySHA256: String
    public let toolchainDescription: String
    public let environmentKind: EnvironmentKind
    public let environmentIdentitySHA256: String
    public let environmentDescription: String

    public init(
      builderSHA256: String,
      recipeSHA256: String,
      toolchainIdentitySHA256: String,
      toolchainDescription: String,
      environmentKind: EnvironmentKind,
      environmentIdentitySHA256: String,
      environmentDescription: String
    ) {
      self.builderSHA256 = builderSHA256
      self.recipeSHA256 = recipeSHA256
      self.toolchainIdentitySHA256 = toolchainIdentitySHA256
      self.toolchainDescription = toolchainDescription
      self.environmentKind = environmentKind
      self.environmentIdentitySHA256 = environmentIdentitySHA256
      self.environmentDescription = environmentDescription
    }
  }

  public struct Artifact: Codable, Equatable, Sendable {
    public enum Role: String, Codable, CaseIterable, Hashable, Sendable {
      case pvhKernel = "pvh-kernel"
      case pvhInitrd = "pvh-initrd"
      case pvhSymbols = "pvh-symbols"
      case firmwareCode = "firmware-code"
      case firmwareVariables = "firmware-variables"
      case installerISO = "installer-iso"
      case rootDiskSeed = "root-disk-seed"
    }

    public let role: Role
    public let importFileName: String
    public let sha256: String
    public let byteCount: UInt64
    public let sourceURL: String
    public let sourceArtifactSHA256: String
    public let licenseSPDX: String
    public let derivation: String

    public init(
      role: Role,
      importFileName: String,
      sha256: String,
      byteCount: UInt64,
      sourceURL: String,
      sourceArtifactSHA256: String,
      licenseSPDX: String,
      derivation: String
    ) {
      self.role = role
      self.importFileName = importFileName
      self.sha256 = sha256
      self.byteCount = byteCount
      self.sourceURL = sourceURL
      self.sourceArtifactSHA256 = sourceArtifactSHA256
      self.licenseSPDX = licenseSPDX
      self.derivation = derivation
    }
  }

  public let schema: String
  public let architecture: String
  public let catalogID: String
  public let purpose: Purpose
  public let producer: Producer
  public let artifacts: [Artifact]

  public init(
    schema: String = Self.schemaIdentity,
    architecture: String = "x86_64",
    catalogID: String,
    purpose: Purpose,
    producer: Producer,
    artifacts: [Artifact]
  ) {
    self.schema = schema
    self.architecture = architecture
    self.catalogID = catalogID
    self.purpose = purpose
    self.producer = producer
    self.artifacts = artifacts
  }

  public static func decodeAndValidate(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= 1 << 20 else {
      throw DoryPCX86QualificationFixtureError.invalidManifest("manifest byte count")
    }
    let manifest: Self
    do {
      manifest = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw DoryPCX86QualificationFixtureError.invalidManifest("JSON: \(error)")
    }
    try manifest.validate()
    return manifest
  }

  public func validate() throws {
    guard schema == Self.schemaIdentity else {
      throw DoryPCX86QualificationFixtureError.invalidManifest("schema")
    }
    guard architecture == "x86_64" else {
      throw DoryPCX86QualificationFixtureError.invalidManifest("architecture")
    }
    guard Self.isSafeIdentifier(catalogID, maximumBytes: 128) else {
      throw DoryPCX86QualificationFixtureError.invalidManifest("catalogID")
    }
    let producerDigests = [
      producer.builderSHA256,
      producer.recipeSHA256,
      producer.toolchainIdentitySHA256,
      producer.environmentIdentitySHA256,
    ]
    guard producerDigests.allSatisfy(Self.isSHA256) else {
      throw DoryPCX86QualificationFixtureError.invalidManifest("producer SHA-256")
    }
    guard Self.isBoundedDescription(producer.toolchainDescription),
      Self.isBoundedDescription(producer.environmentDescription)
    else {
      throw DoryPCX86QualificationFixtureError.invalidManifest("producer description")
    }
    guard (2...32).contains(artifacts.count) else {
      throw DoryPCX86QualificationFixtureError.invalidManifest("artifact count")
    }
    let roles = Set(artifacts.map(\.role))
    guard roles.count == artifacts.count, roles.isSuperset(of: purpose.requiredRoles) else {
      throw DoryPCX86QualificationFixtureError.invalidManifest("artifact roles")
    }
    let names = Set(artifacts.map(\.importFileName))
    guard names.count == artifacts.count else {
      throw DoryPCX86QualificationFixtureError.invalidManifest("duplicate importFileName")
    }
    for artifact in artifacts {
      guard Self.isSafeIdentifier(artifact.importFileName, maximumBytes: 200) else {
        throw DoryPCX86QualificationFixtureError.invalidManifest(
          "importFileName for \(artifact.role.rawValue)")
      }
      guard Self.isSHA256(artifact.sha256), Self.isSHA256(artifact.sourceArtifactSHA256) else {
        throw DoryPCX86QualificationFixtureError.invalidManifest(
          "SHA-256 for \(artifact.role.rawValue)")
      }
      guard artifact.byteCount > 0, artifact.byteCount <= 32 * 1_024 * 1_024 * 1_024 else {
        throw DoryPCX86QualificationFixtureError.invalidManifest(
          "byteCount for \(artifact.role.rawValue)")
      }
      guard let components = URLComponents(string: artifact.sourceURL),
        components.scheme == "https", components.host != nil,
        components.user == nil, components.password == nil, components.fragment == nil
      else {
        throw DoryPCX86QualificationFixtureError.invalidManifest(
          "sourceURL for \(artifact.role.rawValue)")
      }
      guard Self.isSafeLicense(artifact.licenseSPDX),
        Self.isBoundedDescription(artifact.derivation)
      else {
        throw DoryPCX86QualificationFixtureError.invalidManifest(
          "provenance for \(artifact.role.rawValue)")
      }
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func isSafeIdentifier(_ value: String, maximumBytes: Int) -> Bool {
    guard (1...maximumBytes).contains(value.utf8.count),
      let first = value.utf8.first,
      (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first)
    else { return false }
    return value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || [45, 46, 95].contains($0)
    }
  }

  private static func isSafeLicense(_ value: String) -> Bool {
    guard (1...128).contains(value.utf8.count) else { return false }
    return value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || [32, 40, 41, 43, 45, 46].contains($0)
    }
  }

  private static func isBoundedDescription(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1_024 && !value.utf8.contains(0)
  }
}

public struct DoryPCX86QualificationFixtureImportReceipt: Codable, Equatable, Sendable {
  public static let schemaIdentity = "dev.dory.pc-x86-qualification-fixture-import@1"

  public struct Object: Codable, Equatable, Sendable {
    public let role: DoryPCX86QualificationFixtureManifest.Artifact.Role
    public let sha256: String
    public let byteCount: UInt64
    public let objectRelativePath: String
    public let publication: String
  }

  public let schema: String
  public let qualified: Bool
  public let qualification: String
  public let manifestSHA256: String
  public let catalogID: String
  public let purpose: DoryPCX86QualificationFixtureManifest.Purpose
  public let producer: DoryPCX86QualificationFixtureManifest.Producer
  public let objects: [Object]
}

public enum DoryPCX86QualificationFixtureError: Error, CustomStringConvertible, Equatable {
  case invalidManifest(String)
  case invalidPath(String)
  case filesystem(String)
  case sourceChanged(String)
  case byteCountMismatch(String)
  case digestMismatch(String)

  public var description: String {
    switch self {
    case .invalidManifest(let field): "invalid x86 qualification fixture manifest: \(field)"
    case .invalidPath(let detail): "invalid x86 qualification fixture path: \(detail)"
    case .filesystem(let operation): "x86 qualification fixture filesystem failure: \(operation)"
    case .sourceChanged(let name): "x86 qualification fixture changed while reading: \(name)"
    case .byteCountMismatch(let name): "x86 qualification fixture byte count differs: \(name)"
    case .digestMismatch(let name): "x86 qualification fixture SHA-256 differs: \(name)"
    }
  }
}

public struct DoryPCX86QualificationFixtureImporter: Sendable {
  public static let maximumManifestBytes = 1 << 20

  public let storeDirectory: URL

  public init(storeDirectory: URL) throws {
    guard storeDirectory.isFileURL, storeDirectory.path.hasPrefix("/"),
      storeDirectory.path != "/", !storeDirectory.path.utf8.contains(0)
    else { throw DoryPCX86QualificationFixtureError.invalidPath("store directory") }
    self.storeDirectory = storeDirectory.standardizedFileURL
  }

  public func importFixtures(
    manifestData: Data,
    sourceDirectory: URL
  ) throws -> DoryPCX86QualificationFixtureImportReceipt {
    guard sourceDirectory.isFileURL, sourceDirectory.path.hasPrefix("/"),
      sourceDirectory.path != "/", !sourceDirectory.path.utf8.contains(0)
    else { throw DoryPCX86QualificationFixtureError.invalidPath("source directory") }
    let manifest = try DoryPCX86QualificationFixtureManifest.decodeAndValidate(manifestData)
    let manifestDigest = Self.sha256(manifestData)
    try FileManager.default.createDirectory(
      at: storeDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])

    let root = try Self.openDirectory(storeDirectory.path, label: "store directory")
    defer { Darwin.close(root) }
    if mkdirat(root, "sha256", 0o755) != 0, errno != EEXIST {
      throw DoryPCX86QualificationFixtureError.filesystem("create sha256 object directory")
    }
    let objects = openat(root, "sha256", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard objects >= 0 else {
      throw DoryPCX86QualificationFixtureError.filesystem("open sha256 object directory")
    }
    defer { Darwin.close(objects) }
    let sources = try Self.openDirectory(
      sourceDirectory.standardizedFileURL.path, label: "source directory")
    defer { Darwin.close(sources) }

    var imported: [DoryPCX86QualificationFixtureImportReceipt.Object] = []
    for artifact in manifest.artifacts.sorted(by: { $0.role.rawValue < $1.role.rawValue }) {
      let publication = try importArtifact(artifact, sources: sources, objects: objects)
      imported.append(.init(
        role: artifact.role,
        sha256: artifact.sha256,
        byteCount: artifact.byteCount,
        objectRelativePath: "sha256/\(artifact.sha256)",
        publication: publication
      ))
    }
    return .init(
      schema: DoryPCX86QualificationFixtureImportReceipt.schemaIdentity,
      qualified: false,
      qualification: "content integrity and provenance binding only; no guest execution",
      manifestSHA256: manifestDigest,
      catalogID: manifest.catalogID,
      purpose: manifest.purpose,
      producer: manifest.producer,
      objects: imported
    )
  }

  private func importArtifact(
    _ artifact: DoryPCX86QualificationFixtureManifest.Artifact,
    sources: Int32,
    objects: Int32
  ) throws -> String {
    let source = openat(
      sources, artifact.importFileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard source >= 0 else {
      throw DoryPCX86QualificationFixtureError.filesystem(
        "open source \(artifact.importFileName)")
    }
    defer { Darwin.close(source) }
    let initial = try Self.fileStamp(source, name: artifact.importFileName)
    guard initial.isRegular, initial.byteCount == artifact.byteCount else {
      throw DoryPCX86QualificationFixtureError.byteCountMismatch(artifact.importFileName)
    }

    let temporary = ".import-\(UUID().uuidString.lowercased())"
    let output = openat(
      objects, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard output >= 0 else {
      throw DoryPCX86QualificationFixtureError.filesystem("create temporary object")
    }
    defer {
      Darwin.close(output)
      _ = unlinkat(objects, temporary, 0)
    }
    let copied = try Self.copyAndHash(
      source: source, output: output, maximumBytes: artifact.byteCount,
      name: artifact.importFileName)
    guard copied.byteCount == artifact.byteCount else {
      throw DoryPCX86QualificationFixtureError.byteCountMismatch(artifact.importFileName)
    }
    guard copied.sha256 == artifact.sha256 else {
      throw DoryPCX86QualificationFixtureError.digestMismatch(artifact.importFileName)
    }
    guard try Self.fileStamp(source, name: artifact.importFileName) == initial else {
      throw DoryPCX86QualificationFixtureError.sourceChanged(artifact.importFileName)
    }

    let existing = openat(objects, artifact.sha256, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if existing >= 0 {
      defer { Darwin.close(existing) }
      try Self.verifyObject(existing, artifact: artifact)
      return "verified-existing"
    }
    guard errno == ENOENT else {
      throw DoryPCX86QualificationFixtureError.filesystem("inspect destination object")
    }
    guard fchmod(output, 0o444) == 0, fsync(output) == 0 else {
      throw DoryPCX86QualificationFixtureError.filesystem("synchronize temporary object")
    }
    if linkat(objects, temporary, objects, artifact.sha256, 0) != 0 {
      guard errno == EEXIST else {
        throw DoryPCX86QualificationFixtureError.filesystem("publish object")
      }
      let raced = openat(
        objects, artifact.sha256, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard raced >= 0 else {
        throw DoryPCX86QualificationFixtureError.filesystem("open concurrently published object")
      }
      defer { Darwin.close(raced) }
      try Self.verifyObject(raced, artifact: artifact)
      return "verified-concurrent"
    }
    guard fsync(objects) == 0 else {
      throw DoryPCX86QualificationFixtureError.filesystem("synchronize object directory")
    }
    return "published"
  }

  private static func verifyObject(
    _ descriptor: Int32,
    artifact: DoryPCX86QualificationFixtureManifest.Artifact
  ) throws {
    let stamp = try fileStamp(descriptor, name: artifact.sha256)
    guard stamp.isRegular, stamp.byteCount == artifact.byteCount else {
      throw DoryPCX86QualificationFixtureError.byteCountMismatch(artifact.sha256)
    }
    let measured = try copyAndHash(
      source: descriptor, output: nil, maximumBytes: artifact.byteCount, name: artifact.sha256)
    guard measured.byteCount == artifact.byteCount else {
      throw DoryPCX86QualificationFixtureError.byteCountMismatch(artifact.sha256)
    }
    guard measured.sha256 == artifact.sha256 else {
      throw DoryPCX86QualificationFixtureError.digestMismatch(artifact.sha256)
    }
    guard try fileStamp(descriptor, name: artifact.sha256) == stamp else {
      throw DoryPCX86QualificationFixtureError.sourceChanged(artifact.sha256)
    }
  }

  private struct FileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let byteCount: UInt64
    let mode: mode_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    var isRegular: Bool { mode & S_IFMT == S_IFREG }
  }

  private static func fileStamp(_ descriptor: Int32, name: String) throws -> FileStamp {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size >= 0 else {
      throw DoryPCX86QualificationFixtureError.filesystem("stat \(name)")
    }
    return .init(
      device: metadata.st_dev,
      inode: metadata.st_ino,
      byteCount: UInt64(metadata.st_size),
      mode: metadata.st_mode,
      modifiedSeconds: metadata.st_mtimespec.tv_sec,
      modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
      changedSeconds: metadata.st_ctimespec.tv_sec,
      changedNanoseconds: metadata.st_ctimespec.tv_nsec
    )
  }

  private static func copyAndHash(
    source: Int32,
    output: Int32?,
    maximumBytes: UInt64,
    name: String
  ) throws -> (sha256: String, byteCount: UInt64) {
    guard lseek(source, 0, SEEK_SET) == 0 else {
      throw DoryPCX86QualificationFixtureError.filesystem("seek \(name)")
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var total: UInt64 = 0
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw DoryPCX86QualificationFixtureError.filesystem("read \(name)")
      }
      if count == 0 { break }
      let unsignedCount = UInt64(count)
      guard total <= maximumBytes, unsignedCount <= maximumBytes - total else {
        throw DoryPCX86QualificationFixtureError.byteCountMismatch(name)
      }
      total += unsignedCount
      hasher.update(data: Data(buffer[0..<count]))
      if let output {
        var offset = 0
        while offset < count {
          let written = buffer.withUnsafeBytes {
            Darwin.write(output, $0.baseAddress!.advanced(by: offset), count - offset)
          }
          if written < 0 {
            if errno == EINTR { continue }
            throw DoryPCX86QualificationFixtureError.filesystem("write temporary object")
          }
          guard written > 0 else {
            throw DoryPCX86QualificationFixtureError.filesystem("short write temporary object")
          }
          offset += written
        }
      }
    }
    return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
  }

  private static func openDirectory(_ path: String, label: String) throws -> Int32 {
    let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw DoryPCX86QualificationFixtureError.filesystem("open \(label)")
    }
    return descriptor
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
