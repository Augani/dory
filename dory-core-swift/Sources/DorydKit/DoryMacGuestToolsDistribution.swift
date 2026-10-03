import CryptoKit
import Darwin
import Foundation

/// Checks the exact signed-app payload before making it visible to a Mac guest. Release
/// assembly verifies the Installer signature and stapled ticket; this launch check prevents
/// a partial update or a changed package/manifest pair from being silently shared.
enum DoryMacGuestToolsDistribution {
  private static let maximumManifestBytes = 1_048_576
  private static let maximumPackageBytes: Int64 = 512 * 1_024 * 1_024

  private struct Manifest: Decodable {
    struct Package: Decodable {
      let filename: String
      let sha256: String
      let byteCount: Int64
      let installLocation: String
      let installedAppPath: String
      let installerTeamIdentifier: String
    }

    struct Notarization: Decodable {
      let status: String
      let submissionID: String
    }

    struct LoginAgent: Decodable {
      let path: String
      let label: String
      let sha256: String
    }

    let schema: String
    let package: Package
    let notarization: Notarization
    let loginAgent: LoginAgent
  }

  static func validate(directoryPath: String) throws {
    guard directoryPath.hasPrefix("/"),
      URL(fileURLWithPath: directoryPath).standardizedFileURL.path == directoryPath,
      !directoryPath.contains("/../"),
      !directoryPath.contains("/./")
    else {
      throw invalid("directory path is not canonical")
    }
    let directory = Darwin.open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw invalid("directory is unavailable") }
    defer { Darwin.close(directory) }

    var directoryInfo = stat()
    guard fstat(directory, &directoryInfo) == 0,
      (directoryInfo.st_mode & S_IFMT) == S_IFDIR
    else { throw invalid("distribution root is not a direct directory") }

    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directoryPath).sorted()
    } catch {
      throw invalid("distribution inventory is unavailable")
    }
    guard names.count == 2,
      let packageName = names.first(where: { $0.hasSuffix("-arm64.pkg") }),
      packageName.hasPrefix("DoryGuestTools-"),
      packageName.utf8.count <= 128,
      packageName.utf8.allSatisfy({
        (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
          || (0x61...0x7A).contains($0) || [0x2D, 0x2E, 0x5F, 0x2B].contains($0)
      }),
      names.contains(packageName + ".json")
    else { throw invalid("distribution inventory is invalid") }

    let manifestDescriptor = openat(
      directory, packageName + ".json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard manifestDescriptor >= 0 else { throw invalid("manifest is unavailable") }
    defer { Darwin.close(manifestDescriptor) }
    var manifestInfo = stat()
    guard fstat(manifestDescriptor, &manifestInfo) == 0,
      (manifestInfo.st_mode & S_IFMT) == S_IFREG,
      manifestInfo.st_size > 0,
      manifestInfo.st_size <= maximumManifestBytes
    else { throw invalid("manifest is not a bounded regular file") }

    let manifest: Manifest
    do {
      let handle = FileHandle(fileDescriptor: manifestDescriptor, closeOnDealloc: false)
      var data = Data()
      while true {
        let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
        guard !chunk.isEmpty else { break }
        guard data.count <= maximumManifestBytes - chunk.count else {
          throw invalid("manifest exceeds the size limit")
        }
        data.append(chunk)
      }
      guard data.count == Int(manifestInfo.st_size) else { throw invalid("manifest changed while reading") }
      manifest = try JSONDecoder().decode(Manifest.self, from: data)
    } catch {
      throw invalid("manifest cannot be decoded")
    }
    guard manifest.schema == "dory.macos-guest-tools-package@3",
      manifest.package.filename == packageName,
      manifest.package.byteCount > 0,
      manifest.package.byteCount <= maximumPackageBytes,
      isSHA256(manifest.package.sha256),
      manifest.package.installLocation == "/",
      manifest.package.installedAppPath == "/Applications/DoryGuestTools.app",
      manifest.package.installerTeamIdentifier == "864H636QW4",
      manifest.notarization.status == "stapled",
      UUID(uuidString: manifest.notarization.submissionID)?.uuidString.lowercased()
        == manifest.notarization.submissionID,
      manifest.loginAgent.path
        == "/Library/LaunchAgents/com.pythonxi.Dory.GuestTools.agent.plist",
      manifest.loginAgent.label == "com.pythonxi.Dory.GuestTools.agent",
      isSHA256(manifest.loginAgent.sha256)
    else { throw invalid("manifest binding is invalid") }

    let packageDescriptor = openat(directory, packageName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard packageDescriptor >= 0 else { throw invalid("package is unavailable") }
    defer { Darwin.close(packageDescriptor) }
    var packageInfo = stat()
    guard fstat(packageDescriptor, &packageInfo) == 0,
      (packageInfo.st_mode & S_IFMT) == S_IFREG,
      packageInfo.st_size == manifest.package.byteCount
    else { throw invalid("package byte count differs from manifest") }

    let digest: String
    do {
      let handle = FileHandle(fileDescriptor: packageDescriptor, closeOnDealloc: false)
      var hasher = SHA256()
      var byteCount: Int64 = 0
      while true {
        let chunk = try autoreleasepool { try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data() }
        guard !chunk.isEmpty else { break }
        byteCount += Int64(chunk.count)
        guard byteCount <= manifest.package.byteCount else {
          throw invalid("package grew while reading")
        }
        hasher.update(data: chunk)
      }
      guard byteCount == manifest.package.byteCount else {
        throw invalid("package changed while reading")
      }
      digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    } catch {
      throw invalid("package cannot be read")
    }
    guard digest == manifest.package.sha256 else {
      throw invalid("package digest differs from manifest")
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  private static func invalid(_ reason: String) -> MachineManagerError {
    .persistence("macOS Guest Tools distribution is invalid: \(reason)")
  }
}
