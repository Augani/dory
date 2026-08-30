import Foundation

public enum DoryARMVirtQualificationGateKind: String, Codable, CaseIterable, Sendable {
  case installerBoot = "installer-boot"
  case installReboot = "install-reboot"
  case guestUpdate = "guest-update"
  case recovery
  case coldSnapshot = "cold-snapshot"
  case baselineDevices = "baseline-devices"
}

public struct DoryARMVirtCompatibilityMedia: Codable, Equatable, Sendable {
  public let guestFamily: String
  public let guestVersion: String
  public let guestBuild: String
  public let guestArchitecture: String
  public let sourceURL: String
  public let checksumURL: String
  public let byteCount: UInt64
  public let sha256: String
}

public struct DoryARMVirtQualificationReceiptExpectation: Codable, Equatable, Sendable {
  public let bootAttempts: Int
  public let consoleScriptStepCount: Int
  public let installerMediaTransitionCount: Int
  public let installerMediaAttachedForFinalBoot: Bool
  public let coldSnapshotActionCount: Int
}

public struct DoryARMVirtCompatibilityGate: Codable, Equatable, Sendable {
  public let gateID: String
  public let kind: DoryARMVirtQualificationGateKind
  public let mediaID: String
  public let consoleScriptPath: String
  public let consoleScriptSHA256: String
  public let expectedConsoleText: String
  public let memoryByteCount: UInt64
  public let systemDiskByteCount: UInt64
  public let timeoutSeconds: UInt64
  public let receipt: DoryARMVirtQualificationReceiptExpectation
}

public struct DoryARMVirtCompatibilityMatrix: Codable, Equatable, Sendable {
  public static let currentSchemaVersion: UInt32 = 1
  public static let identity = "dory.compatibility.armvirt@1"

  public let schemaVersion: UInt32
  public let matrixIdentity: String
  public let machineABIIdentity: String
  public let firmwareABIIdentity: String
  public let deviceABIIdentity: String
  public let media: [String: DoryARMVirtCompatibilityMedia]
  public let gates: [DoryARMVirtCompatibilityGate]

  public func validated() throws -> Self {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw DoryARMVirtCompatibilityMatrixError.unsupportedSchemaVersion(schemaVersion)
    }
    guard matrixIdentity == Self.identity,
      machineABIIdentity == "dory.armvirt@1",
      firmwareABIIdentity == "dory.edk2.armvirt@1",
      deviceABIIdentity == "dory.virtio@1"
    else {
      throw DoryARMVirtCompatibilityMatrixError.invalidPlatformIdentity
    }
    guard !media.isEmpty, !gates.isEmpty else {
      throw DoryARMVirtCompatibilityMatrixError.emptyMatrix
    }
    for (mediaID, item) in media {
      guard Self.isIdentifier(mediaID), Self.isBounded(item.guestFamily),
        Self.isBounded(item.guestVersion), Self.isBounded(item.guestBuild),
        item.guestArchitecture == "arm64", item.sourceURL.hasPrefix("https://"),
        item.checksumURL.hasPrefix("https://"), item.byteCount > 0,
        item.byteCount <= 32 << 30, item.byteCount.isMultiple(of: 512),
        Self.isSHA256(item.sha256)
      else {
        throw DoryARMVirtCompatibilityMatrixError.invalidMedia(mediaID)
      }
    }
    var gateIDs = Set<String>()
    for gate in gates {
      guard Self.isIdentifier(gate.gateID), gateIDs.insert(gate.gateID).inserted else {
        throw DoryARMVirtCompatibilityMatrixError.duplicateOrInvalidGateID(gate.gateID)
      }
      guard media[gate.mediaID] != nil else {
        throw DoryARMVirtCompatibilityMatrixError.unknownMedia(
          gateID: gate.gateID,
          mediaID: gate.mediaID
        )
      }
      guard Self.isSafeRelativeFixturePath(gate.consoleScriptPath),
        Self.isSHA256(gate.consoleScriptSHA256), Self.isBounded(gate.expectedConsoleText),
        gate.memoryByteCount >= 1 << 30, gate.memoryByteCount <= 16 << 30,
        gate.memoryByteCount.isMultiple(of: 16 << 10),
        gate.systemDiskByteCount >= 64 << 20, gate.systemDiskByteCount <= 64 << 30,
        gate.systemDiskByteCount.isMultiple(of: 512), (1...900).contains(gate.timeoutSeconds),
        (1...4).contains(gate.receipt.bootAttempts),
        (1...128).contains(gate.receipt.consoleScriptStepCount),
        (0...2).contains(gate.receipt.installerMediaTransitionCount),
        (0...2).contains(gate.receipt.coldSnapshotActionCount)
      else {
        throw DoryARMVirtCompatibilityMatrixError.invalidGate(gate.gateID)
      }
      guard (gate.kind == .coldSnapshot) == (gate.receipt.coldSnapshotActionCount == 2) else {
        throw DoryARMVirtCompatibilityMatrixError.invalidGate(gate.gateID)
      }
    }
    return self
  }

  public func gate(id: String) throws -> DoryARMVirtCompatibilityGate {
    let matches = gates.filter { $0.gateID == id }
    guard matches.count == 1, let gate = matches.first else {
      throw DoryARMVirtCompatibilityMatrixError.gateUnavailable(id)
    }
    return gate
  }

  private static func isBounded(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
  }

  private static func isIdentifier(_ value: String) -> Bool {
    isBounded(value)
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46
      }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func isSafeRelativeFixturePath(_ value: String) -> Bool {
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    return value.hasPrefix("qualification/") && value.hasSuffix(".json")
      && !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
      && value.utf8.count <= 256
  }
}

public enum DoryARMVirtCompatibilityMatrixError: Error, Equatable, Sendable {
  case unsupportedSchemaVersion(UInt32)
  case invalidPlatformIdentity
  case emptyMatrix
  case invalidMedia(String)
  case duplicateOrInvalidGateID(String)
  case unknownMedia(gateID: String, mediaID: String)
  case invalidGate(String)
  case gateUnavailable(String)
}
