import CryptoKit
import Darwin
import DoryMachineARMVirt
import Foundation

public struct DoryARMVirtColdSnapshotManifest: Codable, Sendable, Equatable {
  public static let currentSchemaVersion: UInt32 = 1
  public static let snapshotABIIdentity = "dory.snapshot.armvirt.cold@1"

  public let schemaVersion: UInt32
  public let snapshotABIIdentity: String
  public let consistency: String
  public let machineABIIdentity: String
  public let firmwareABIIdentity: String
  public let variableStoreFormatIdentity: String
  public let firmwareBuildIdentifier: String
  public let firmwareCodeSHA256: String
  public let systemDiskFileName: String
  public let systemDiskByteCount: UInt64
  public let systemDiskSHA256: String
  public let variableStoreFileName: String
  public let variableStoreGeneration: UInt64
  public let variableStoreSHA256: String

  public init(
    firmware: DoryFirmwareArtifactManifest,
    systemDiskByteCount: UInt64,
    systemDiskSHA256: String,
    variableStoreGeneration: UInt64,
    variableStoreSHA256: String
  ) throws {
    try self.init(
      schemaVersion: Self.currentSchemaVersion,
      snapshotABIIdentity: Self.snapshotABIIdentity,
      consistency: "cold-stopped",
      machineABIIdentity: firmware.machineABIIdentity,
      firmwareABIIdentity: firmware.firmwareABIIdentity,
      variableStoreFormatIdentity: firmware.variableStoreFormatIdentity,
      firmwareBuildIdentifier: firmware.buildIdentifier,
      firmwareCodeSHA256: firmware.firmwareCodeSHA256,
      systemDiskFileName: DoryARMVirtColdSnapshotStore.systemDiskFileName,
      systemDiskByteCount: systemDiskByteCount,
      systemDiskSHA256: systemDiskSHA256,
      variableStoreFileName: DoryARMVirtColdSnapshotStore.variableStoreFileName,
      variableStoreGeneration: variableStoreGeneration,
      variableStoreSHA256: variableStoreSHA256
    )
  }

  private init(
    schemaVersion: UInt32,
    snapshotABIIdentity: String,
    consistency: String,
    machineABIIdentity: String,
    firmwareABIIdentity: String,
    variableStoreFormatIdentity: String,
    firmwareBuildIdentifier: String,
    firmwareCodeSHA256: String,
    systemDiskFileName: String,
    systemDiskByteCount: UInt64,
    systemDiskSHA256: String,
    variableStoreFileName: String,
    variableStoreGeneration: UInt64,
    variableStoreSHA256: String
  ) throws {
    guard schemaVersion == Self.currentSchemaVersion,
      snapshotABIIdentity == Self.snapshotABIIdentity,
      consistency == "cold-stopped",
      machineABIIdentity == DoryARMVirtV1ABI.identity,
      firmwareABIIdentity == DoryARMVirtV1ABI.firmwareABIIdentity,
      variableStoreFormatIdentity == DoryARMVirtV1ABI.variableStoreFormatIdentity,
      !firmwareBuildIdentifier.isEmpty,
      firmwareBuildIdentifier.utf8.count <= 256,
      Self.isSHA256(firmwareCodeSHA256),
      systemDiskFileName == DoryARMVirtColdSnapshotStore.systemDiskFileName,
      systemDiskByteCount > 0,
      systemDiskByteCount.isMultiple(of: 512),
      Self.isSHA256(systemDiskSHA256),
      variableStoreFileName == DoryARMVirtColdSnapshotStore.variableStoreFileName,
      variableStoreGeneration > 0,
      Self.isSHA256(variableStoreSHA256)
    else {
      throw DoryARMVirtColdSnapshotError.invalidManifest
    }
    self.schemaVersion = schemaVersion
    self.snapshotABIIdentity = snapshotABIIdentity
    self.consistency = consistency
    self.machineABIIdentity = machineABIIdentity
    self.firmwareABIIdentity = firmwareABIIdentity
    self.variableStoreFormatIdentity = variableStoreFormatIdentity
    self.firmwareBuildIdentifier = firmwareBuildIdentifier
    self.firmwareCodeSHA256 = firmwareCodeSHA256
    self.systemDiskFileName = systemDiskFileName
    self.systemDiskByteCount = systemDiskByteCount
    self.systemDiskSHA256 = systemDiskSHA256
    self.variableStoreFileName = variableStoreFileName
    self.variableStoreGeneration = variableStoreGeneration
    self.variableStoreSHA256 = variableStoreSHA256
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion, snapshotABIIdentity, consistency, machineABIIdentity
    case firmwareABIIdentity, variableStoreFormatIdentity, firmwareBuildIdentifier
    case firmwareCodeSHA256, systemDiskFileName, systemDiskByteCount, systemDiskSHA256
    case variableStoreFileName, variableStoreGeneration, variableStoreSHA256
  }

  public init(from decoder: any Decoder) throws {
    try rejectUnknownFirmwareFields(
      from: decoder,
      allowed: Set(CodingKeys.allCases.map(\.rawValue)),
      type: "DoryARMVirtColdSnapshotManifest"
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      schemaVersion: container.decode(UInt32.self, forKey: .schemaVersion),
      snapshotABIIdentity: container.decode(String.self, forKey: .snapshotABIIdentity),
      consistency: container.decode(String.self, forKey: .consistency),
      machineABIIdentity: container.decode(String.self, forKey: .machineABIIdentity),
      firmwareABIIdentity: container.decode(String.self, forKey: .firmwareABIIdentity),
      variableStoreFormatIdentity: container.decode(
        String.self,
        forKey: .variableStoreFormatIdentity
      ),
      firmwareBuildIdentifier: container.decode(String.self, forKey: .firmwareBuildIdentifier),
      firmwareCodeSHA256: container.decode(String.self, forKey: .firmwareCodeSHA256),
      systemDiskFileName: container.decode(String.self, forKey: .systemDiskFileName),
      systemDiskByteCount: container.decode(UInt64.self, forKey: .systemDiskByteCount),
      systemDiskSHA256: container.decode(String.self, forKey: .systemDiskSHA256),
      variableStoreFileName: container.decode(String.self, forKey: .variableStoreFileName),
      variableStoreGeneration: container.decode(UInt64.self, forKey: .variableStoreGeneration),
      variableStoreSHA256: container.decode(String.self, forKey: .variableStoreSHA256)
    )
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}

public struct DoryARMVirtColdSnapshotRestore: Sendable, Equatable {
  public let manifest: DoryARMVirtColdSnapshotManifest
  public let systemDiskPath: String
  public let variableStore: DoryUEFIVariableStoreFile
}

public enum DoryARMVirtColdSnapshotError: Error, Sendable, Equatable {
  case invalidManifest
  case incompatibleFirmware
  case unsafePath(String)
  case destinationExists(String)
  case unexpectedBundleFiles([String])
  case unstableSource(String)
  case digestMismatch(String)
  case filesystem(operation: String, path: String, code: Int32)
}

public enum DoryARMVirtColdSnapshotStore {
  public static let manifestFileName = "manifest.json"
  public static let systemDiskFileName = "system.raw"
  public static let variableStoreFileName = "uefi-variables.json"
  public static let restoredVariableStoreDirectoryName = "variables"

  public static func capture(
    firmware: DoryFirmwareArtifactManifest,
    systemDiskPath: String,
    variableStore: DoryUEFIVariableStoreFile,
    destinationDirectory: String
  ) throws -> DoryARMVirtColdSnapshotManifest {
    let destination = try canonicalNewDirectory(destinationDirectory)
    let sourceDisk = try canonicalPrivateFile(systemDiskPath)
    let variables = try variableStore.load()
    guard variables.source == .primary else {
      throw DoryARMVirtColdSnapshotError.unstableSource(variableStore.primaryPath)
    }
    let variableData = try variables.snapshot.canonicalData()
    let staging = destination + "." + UUID().uuidString.lowercased() + ".partial"
    try createPrivateDirectory(staging)
    var published = false
    defer {
      if !published { try? FileManager.default.removeItem(atPath: staging) }
    }

    let stagedDisk = staging + "/" + systemDiskFileName
    let sourceBefore = try stableFileIdentity(sourceDisk)
    try copyPrivateFile(sourceDisk, to: stagedDisk)
    let sourceAfter = try stableFileIdentity(sourceDisk)
    guard sourceBefore == sourceAfter else {
      throw DoryARMVirtColdSnapshotError.unstableSource(sourceDisk)
    }
    let sourceDigest = try hashPrivateFile(sourceDisk)
    let copiedDigest = try hashPrivateFile(stagedDisk)
    guard sourceDigest == copiedDigest else {
      throw DoryARMVirtColdSnapshotError.digestMismatch(systemDiskFileName)
    }
    let variableDigest = digest(variableData)
    try writePrivate(variableData, to: staging + "/" + variableStoreFileName)
    let manifest = try DoryARMVirtColdSnapshotManifest(
      firmware: firmware,
      systemDiskByteCount: sourceBefore.byteCount,
      systemDiskSHA256: sourceDigest,
      variableStoreGeneration: variables.snapshot.generation,
      variableStoreSHA256: variableDigest
    )
    try writePrivate(try canonicalData(manifest), to: staging + "/" + manifestFileName)
    try syncDirectory(staging)
    guard Darwin.rename(staging, destination) == 0 else {
      throw filesystem("publish", destination)
    }
    published = true
    try syncDirectory((destination as NSString).deletingLastPathComponent)
    return manifest
  }

  public static func loadVerified(
    directory: String,
    expectedFirmware: DoryFirmwareArtifactManifest
  ) throws -> DoryARMVirtColdSnapshotManifest {
    let canonical = try canonicalPrivateDirectory(directory)
    let entries = try FileManager.default.contentsOfDirectory(atPath: canonical).sorted()
    let expected = [manifestFileName, systemDiskFileName, variableStoreFileName].sorted()
    guard entries == expected else {
      throw DoryARMVirtColdSnapshotError.unexpectedBundleFiles(entries)
    }
    let manifestData = try readPrivateFile(canonical + "/" + manifestFileName, maximum: 1 << 20)
    let manifest: DoryARMVirtColdSnapshotManifest
    do {
      manifest = try JSONDecoder().decode(DoryARMVirtColdSnapshotManifest.self, from: manifestData)
      guard try canonicalData(manifest) == manifestData else {
        throw DoryARMVirtColdSnapshotError.invalidManifest
      }
    } catch let error as DoryARMVirtColdSnapshotError {
      throw error
    } catch {
      throw DoryARMVirtColdSnapshotError.invalidManifest
    }
    guard manifest.machineABIIdentity == expectedFirmware.machineABIIdentity,
      manifest.firmwareABIIdentity == expectedFirmware.firmwareABIIdentity,
      manifest.variableStoreFormatIdentity == expectedFirmware.variableStoreFormatIdentity,
      manifest.firmwareBuildIdentifier == expectedFirmware.buildIdentifier,
      manifest.firmwareCodeSHA256 == expectedFirmware.firmwareCodeSHA256
    else {
      throw DoryARMVirtColdSnapshotError.incompatibleFirmware
    }
    let diskPath = canonical + "/" + systemDiskFileName
    let diskIdentity = try stableFileIdentity(diskPath)
    guard diskIdentity.byteCount == manifest.systemDiskByteCount,
      try hashPrivateFile(diskPath) == manifest.systemDiskSHA256
    else {
      throw DoryARMVirtColdSnapshotError.digestMismatch(systemDiskFileName)
    }
    let variableData = try readPrivateFile(
      canonical + "/" + variableStoreFileName,
      maximum: DoryUEFIVariableStoreFile.maximumEncodedBytes
    )
    let variableSnapshot = try DoryUEFIVariableStoreSnapshot.decodeCanonicalTemplate(variableData)
    guard variableSnapshot.generation == manifest.variableStoreGeneration,
      digest(variableData) == manifest.variableStoreSHA256
    else {
      throw DoryARMVirtColdSnapshotError.digestMismatch(variableStoreFileName)
    }
    return manifest
  }

  public static func restore(
    bundleDirectory: String,
    expectedFirmware: DoryFirmwareArtifactManifest,
    destinationDirectory: String
  ) throws -> DoryARMVirtColdSnapshotRestore {
    let bundle = try canonicalPrivateDirectory(bundleDirectory)
    let manifest = try loadVerified(directory: bundle, expectedFirmware: expectedFirmware)
    let destination = try canonicalNewDirectory(destinationDirectory)
    let staging = destination + "." + UUID().uuidString.lowercased() + ".partial"
    try createPrivateDirectory(staging)
    var published = false
    defer {
      if !published { try? FileManager.default.removeItem(atPath: staging) }
    }
    try copyPrivateFile(bundle + "/" + systemDiskFileName, to: staging + "/" + systemDiskFileName)
    let variableData = try readPrivateFile(
      bundle + "/" + variableStoreFileName,
      maximum: DoryUEFIVariableStoreFile.maximumEncodedBytes
    )
    let variableSnapshot = try DoryUEFIVariableStoreSnapshot.decodeCanonicalTemplate(variableData)
    let stagedStore = try DoryUEFIVariableStoreFile(
      directory: staging + "/" + restoredVariableStoreDirectoryName
    )
    try stagedStore.initializeFromColdSnapshot(variableSnapshot)
    try writePrivate(try canonicalData(manifest), to: staging + "/" + manifestFileName)
    try syncDirectory(staging)
    guard Darwin.rename(staging, destination) == 0 else {
      throw filesystem("publish restore", destination)
    }
    published = true
    try syncDirectory((destination as NSString).deletingLastPathComponent)
    return DoryARMVirtColdSnapshotRestore(
      manifest: manifest,
      systemDiskPath: destination + "/" + systemDiskFileName,
      variableStore: try DoryUEFIVariableStoreFile(
        directory: destination + "/" + restoredVariableStoreDirectoryName
      )
    )
  }

  private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let byteCount: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
  }

  private static func canonicalNewDirectory(_ path: String) throws -> String {
    let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
    guard path == canonical, canonical.hasPrefix("/"), canonical != "/" else {
      throw DoryARMVirtColdSnapshotError.unsafePath(path)
    }
    var status = stat()
    if lstat(canonical, &status) == 0 {
      throw DoryARMVirtColdSnapshotError.destinationExists(canonical)
    }
    guard errno == ENOENT else {
      throw filesystem("inspect destination", canonical)
    }
    _ = try canonicalPrivateDirectory((canonical as NSString).deletingLastPathComponent)
    return canonical
  }

  private static func canonicalPrivateDirectory(_ path: String) throws -> String {
    let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
    var status = stat()
    guard path == canonical, canonical != "/", lstat(canonical, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0
    else {
      throw DoryARMVirtColdSnapshotError.unsafePath(path)
    }
    return canonical
  }

  private static func canonicalPrivateFile(_ path: String) throws -> String {
    let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
    guard path == canonical else { throw DoryARMVirtColdSnapshotError.unsafePath(path) }
    _ = try stableFileIdentity(canonical)
    return canonical
  }

  private static func stableFileIdentity(_ path: String) throws -> FileIdentity {
    var status = stat()
    guard lstat(path, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0,
      status.st_nlink == 1,
      status.st_size > 0
    else {
      throw DoryARMVirtColdSnapshotError.unsafePath(path)
    }
    return FileIdentity(
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino),
      byteCount: UInt64(status.st_size),
      modificationSeconds: Int64(status.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
    )
  }

  private static func createPrivateDirectory(_ path: String) throws {
    guard mkdir(path, 0o700) == 0 else { throw filesystem("create directory", path) }
  }

  private static func copyPrivateFile(_ source: String, to destination: String) throws {
    let sourceDescriptor = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard sourceDescriptor >= 0 else { throw filesystem("open copy source", source) }
    defer { close(sourceDescriptor) }
    _ = try privateFileIdentity(descriptor: sourceDescriptor, path: source)
    let destinationDescriptor = open(
      destination,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard destinationDescriptor >= 0 else {
      throw filesystem("create copy destination", destination)
    }
    var succeeded = false
    defer {
      close(destinationDescriptor)
      if !succeeded { unlink(destination) }
    }
    guard
      fcopyfile(sourceDescriptor, destinationDescriptor, nil, copyfile_flags_t(COPYFILE_DATA))
        == 0
    else {
      throw filesystem("copy", destination)
    }
    guard fchmod(destinationDescriptor, 0o600) == 0,
      fsync(destinationDescriptor) == 0
    else {
      throw filesystem("sync copy", destination)
    }
    succeeded = true
  }

  private static func hashPrivateFile(_ path: String) throws -> String {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw filesystem("open", path) }
    defer { close(descriptor) }
    _ = try privateFileIdentity(descriptor: descriptor, path: path)
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw filesystem("read", path) }
      if count == 0 { break }
      hasher.update(data: Data(buffer[0..<count]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func readPrivateFile(_ path: String, maximum: Int) throws -> Data {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw filesystem("open", path) }
    defer { close(descriptor) }
    let identity = try privateFileIdentity(descriptor: descriptor, path: path)
    guard identity.byteCount <= UInt64(maximum) else {
      throw DoryARMVirtColdSnapshotError.unsafePath(path)
    }
    var data = Data()
    data.reserveCapacity(Int(identity.byteCount))
    var buffer = [UInt8](repeating: 0, count: 64 << 10)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw filesystem("read", path) }
      if count == 0 { break }
      guard data.count <= maximum - count else {
        throw DoryARMVirtColdSnapshotError.unsafePath(path)
      }
      data.append(buffer, count: count)
    }
    guard data.count == Int(identity.byteCount),
      try privateFileIdentity(descriptor: descriptor, path: path) == identity
    else {
      throw DoryARMVirtColdSnapshotError.unstableSource(path)
    }
    return data
  }

  private static func privateFileIdentity(
    descriptor: Int32,
    path: String
  ) throws -> FileIdentity {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0,
      status.st_nlink == 1,
      status.st_size > 0
    else {
      throw DoryARMVirtColdSnapshotError.unsafePath(path)
    }
    return FileIdentity(
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino),
      byteCount: UInt64(status.st_size),
      modificationSeconds: Int64(status.st_mtimespec.tv_sec),
      modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
    )
  }

  private static func writePrivate(_ data: Data, to path: String) throws {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw filesystem("create file", path) }
    var succeeded = false
    defer {
      close(descriptor)
      if !succeeded { unlink(path) }
    }
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw filesystem("write", path) }
        offset += count
      }
    }
    guard fsync(descriptor) == 0 else { throw filesystem("sync", path) }
    succeeded = true
  }

  private static func syncDirectory(_ path: String) throws {
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw filesystem("open directory", path) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw filesystem("sync directory", path) }
  }

  private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data("\n".utf8)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func filesystem(
    _ operation: String,
    _ path: String
  ) -> DoryARMVirtColdSnapshotError {
    .filesystem(operation: operation, path: path, code: errno)
  }
}
