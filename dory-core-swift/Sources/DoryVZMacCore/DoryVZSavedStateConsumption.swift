import Darwin
import Foundation

/// A deny-only fence in the existing saved-state directory. It never authorizes a restore:
/// receipt/configuration/host validation remains with the existing artifact owner. Any entry
/// at this name, including an invalid or linked entry, forbids replay of the on-disk RAM image.
public enum DoryVZSavedStateConsumption {
  public static let markerName = "consumed-before-resume.json"

  public static func isConsumed(stateURL: URL) throws -> Bool {
    try DoryVZMacMetadataFile.entryExists(at: markerURL(stateURL))
  }

  public static func requireUnconsumed(stateURL: URL) throws {
    guard try !isConsumed(stateURL: stateURL) else {
      throw DoryVZMacSavedStateError.alreadyConsumed
    }
  }

  /// Cleanup owners may retire a killed writer's exclusive temporary inode, including a
  /// zero-byte partial. Names outside the exact reserved UUID namespace are not owned here.
  public static func isAbandonedMetadataFile(at url: URL) throws -> Bool {
    try DoryVZMacMetadataFile.isAbandonedTemporaryFile(at: url)
  }

  public static func consume(stateURL: URL) throws {
    try consume(stateURL: stateURL, io: DoryVZMacMetadataFile.WriteIO())
  }

  static func consume(stateURL: URL, io: DoryVZMacMetadataFile.WriteIO) throws {
    guard stateURL.isFileURL, !stateURL.hasDirectoryPath, !stateURL.path.contains("\0") else {
      throw DoryVZMacSavedStateError.invalidArtifact("saved state is not a local file")
    }
    try requireUnconsumed(stateURL: stateURL)
    let descriptor = open(stateURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw DoryVZMacSavedStateError.filesystem("open state for consumption", errno)
    }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw DoryVZMacSavedStateError.filesystem("inspect state for consumption", errno)
    }
    guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(),
      status.st_nlink == 1, status.st_mode & 0o077 == 0, status.st_size > 0
    else { throw DoryVZMacSavedStateError.invalidArtifact("state for consumption is not private") }
    let receipt = ConsumptionReceipt(
      schema: "dory.vz-saved-state-consumption@1",
      consumedAt: ISO8601DateFormatter().string(from: Date()),
      stateFileName: stateURL.lastPathComponent,
      stateBytes: UInt64(status.st_size)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try DoryVZMacMetadataFile.write(
      encoder.encode(receipt), to: markerURL(stateURL), replacingExisting: false, io: io
    )
    // Never remove this fence on error. In particular, a post-publication sync failure must
    // leave the RAM image non-replayable, even though this caller is forbidden to resume.
  }

  private static func markerURL(_ stateURL: URL) -> URL {
    stateURL.deletingLastPathComponent().appendingPathComponent(markerName)
  }

  private struct ConsumptionReceipt: Codable {
    let schema: String
    let consumedAt: String
    let stateFileName: String
    let stateBytes: UInt64
  }
}
