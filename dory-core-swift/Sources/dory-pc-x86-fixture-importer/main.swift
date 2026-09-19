import Darwin
import DoryPCQualification
import Foundation

private enum CLIError: Error, CustomStringConvertible {
  case usage(String)

  var description: String {
    switch self {
    case .usage(let detail): detail
    }
  }
}

private struct Arguments {
  let manifest: URL
  let sourceDirectory: URL
  let storeDirectory: URL
  let receipt: URL?

  init(_ values: [String]) throws {
    let known = Set(["--manifest", "--source-directory", "--store-directory", "--receipt"])
    var parsed: [String: URL] = [:]
    var index = 0
    while index < values.count {
      let option = values[index]
      guard known.contains(option), index + 1 < values.count else {
        throw CLIError.usage("unknown option or missing value: \(option)")
      }
      let value = values[index + 1]
      guard value.hasPrefix("/"), value != "/", !value.utf8.contains(0) else {
        throw CLIError.usage("\(option) requires a narrowly scoped absolute path")
      }
      guard parsed.updateValue(URL(fileURLWithPath: value).standardizedFileURL, forKey: option) == nil
      else { throw CLIError.usage("duplicate option: \(option)") }
      index += 2
    }
    guard let manifest = parsed["--manifest"],
      let sourceDirectory = parsed["--source-directory"],
      let storeDirectory = parsed["--store-directory"]
    else {
      throw CLIError.usage(
        "usage: dory-pc-x86-fixture-importer --manifest /path/manifest.json "
          + "--source-directory /path/staging --store-directory /path/store "
          + "[--receipt /path/new-receipt.json]")
    }
    self.manifest = manifest
    self.sourceDirectory = sourceDirectory
    self.storeDirectory = storeDirectory
    receipt = parsed["--receipt"]
  }
}

private func readManifest(_ url: URL) throws -> Data {
  let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
  guard descriptor >= 0 else { throw CLIError.usage("cannot open manifest") }
  defer { Darwin.close(descriptor) }
  var metadata = stat()
  guard fstat(descriptor, &metadata) == 0,
    metadata.st_mode & S_IFMT == S_IFREG,
    metadata.st_size > 0,
    metadata.st_size <= DoryPCX86QualificationFixtureImporter.maximumManifestBytes
  else { throw CLIError.usage("manifest must be a bounded nonempty regular file") }
  let initialSize = metadata.st_size
  let initialModified = metadata.st_mtimespec
  let initialChanged = metadata.st_ctimespec
  var data = Data()
  while true {
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
    if count < 0 {
      if errno == EINTR { continue }
      throw CLIError.usage("cannot read manifest")
    }
    if count == 0 { break }
    guard data.count <= DoryPCX86QualificationFixtureImporter.maximumManifestBytes - count else {
      throw CLIError.usage("manifest exceeds its byte limit")
    }
    data.append(contentsOf: buffer[0..<count])
  }
  guard fstat(descriptor, &metadata) == 0,
    metadata.st_size == initialSize,
    metadata.st_mtimespec.tv_sec == initialModified.tv_sec,
    metadata.st_mtimespec.tv_nsec == initialModified.tv_nsec,
    metadata.st_ctimespec.tv_sec == initialChanged.tv_sec,
    metadata.st_ctimespec.tv_nsec == initialChanged.tv_nsec,
    data.count == initialSize
  else { throw CLIError.usage("manifest changed while reading") }
  return data
}

private func publishReceipt(_ data: Data, to url: URL) throws {
  let parent = url.deletingLastPathComponent()
  let name = url.lastPathComponent
  guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0) else {
    throw CLIError.usage("invalid receipt file name")
  }
  let directory = Darwin.open(
    parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
  guard directory >= 0 else { throw CLIError.usage("cannot open receipt directory") }
  defer { Darwin.close(directory) }
  let temporary = ".dory-x86-receipt-\(UUID().uuidString.lowercased())"
  let descriptor = openat(
    directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
  guard descriptor >= 0 else { throw CLIError.usage("cannot create temporary receipt") }
  defer {
    Darwin.close(descriptor)
    _ = unlinkat(directory, temporary, 0)
  }
  try data.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let written = Darwin.write(
        descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      if written < 0 {
        if errno == EINTR { continue }
        throw CLIError.usage("cannot write receipt")
      }
      guard written > 0 else { throw CLIError.usage("short receipt write") }
      offset += written
    }
  }
  guard fsync(descriptor) == 0 else { throw CLIError.usage("cannot synchronize receipt") }
  guard linkat(directory, temporary, directory, name, 0) == 0 else {
    if errno == EEXIST { throw CLIError.usage("receipt already exists") }
    throw CLIError.usage("cannot publish receipt")
  }
  guard fsync(directory) == 0 else { throw CLIError.usage("cannot synchronize receipt directory") }
}

do {
  let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
  let manifest = try readManifest(arguments.manifest)
  let importer = try DoryPCX86QualificationFixtureImporter(
    storeDirectory: arguments.storeDirectory)
  let receipt = try importer.importFixtures(
    manifestData: manifest, sourceDirectory: arguments.sourceDirectory)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let output = try encoder.encode(receipt) + Data("\n".utf8)
  if let receiptURL = arguments.receipt {
    try publishReceipt(output, to: receiptURL)
  } else {
    FileHandle.standardOutput.write(output)
  }
} catch {
  FileHandle.standardError.write(Data("dory-pc-x86-fixture-importer: \(error)\n".utf8))
  exit(2)
}
