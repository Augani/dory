import Foundation

public enum DoryARMVirtQualificationGateKind: String, Codable, CaseIterable, Sendable {
  case installerBoot = "installer-boot"
  case installReboot = "install-reboot"
  case guestUpdate = "guest-update"
  case recovery
  case coldSnapshot = "cold-snapshot"
  case baselineDevices = "baseline-devices"
  case desktopLiveBoot = "desktop-live-boot"
}

public struct DoryARMVirtDisplayExpectation: Codable, Equatable, Sendable {
  public let scanoutCount: Int
  public let widthPixels: UInt32
  public let heightPixels: UInt32
  public let minimumContentFrameCount: UInt64
}

public struct DoryARMVirtInputExpectation: Codable, Equatable, Sendable {
  public let keyboardMinimumPublishedFrameCount: UInt64
  public let keyboardMinimumPublishedEventCount: UInt64
  public let pointerMinimumPublishedFrameCount: UInt64
  public let pointerMinimumPublishedEventCount: UInt64
}

public struct DoryARMVirtAudioExpectation: Codable, Equatable, Sendable {
  public let minimumCompletedPlaybackPeriodCount: UInt64
  public let minimumCompletedCapturePeriodCount: UInt64
  public let minimumPlaybackByteCount: UInt64
  public let minimumCaptureByteCount: UInt64
}

public struct DoryARMVirtGuestToolsExpectation: Codable, Equatable, Sendable {
  public let byteCount: UInt64
  public let sha256: String
  public let agentSHA256: String
}

public struct DoryARMVirtCameraExpectation: Codable, Equatable, Sendable {
  public let busID: String
  public let busNumber: UInt16
  public let deviceNumber: UInt16
  public let vendorID: UInt16
  public let productID: UInt16
  public let widthPixels: UInt32
  public let heightPixels: UInt32
  public let minimumHostFrameRequestCount: UInt64
  public let minimumJPEGByteCount: UInt64
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
  public let gvproxySHA256: String?
  public let display: DoryARMVirtDisplayExpectation?
  public let input: DoryARMVirtInputExpectation?
  public let audio: DoryARMVirtAudioExpectation?
  public let guestTools: DoryARMVirtGuestToolsExpectation?
  public let camera: DoryARMVirtCameraExpectation?
  public let receipt: DoryARMVirtQualificationReceiptExpectation
}

public struct DoryARMVirtCompatibilityMatrix: Codable, Equatable, Sendable {
  public static let currentSchemaVersion: UInt32 = 6
  public static let identity = "dory.compatibility.armvirt@6"

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
        gate.gvproxySHA256.map(Self.isSHA256) ?? true,
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
      guard (gate.kind == .desktopLiveBoot) == (gate.display != nil) else {
        throw DoryARMVirtCompatibilityMatrixError.invalidGate(gate.gateID)
      }
      guard gate.kind != .desktopLiveBoot || gate.receipt.bootAttempts == 1 else {
        throw DoryARMVirtCompatibilityMatrixError.invalidGate(gate.gateID)
      }
      if let display = gate.display {
        guard (1...16).contains(display.scanoutCount),
          (640...7680).contains(display.widthPixels),
          (480...4320).contains(display.heightPixels),
          (1...10_000).contains(display.minimumContentFrameCount)
        else {
          throw DoryARMVirtCompatibilityMatrixError.invalidGate(gate.gateID)
        }
      }
      if let input = gate.input {
        guard gate.kind == .desktopLiveBoot,
          (1...100).contains(input.keyboardMinimumPublishedFrameCount),
          (1...1_000).contains(input.keyboardMinimumPublishedEventCount),
          (1...100).contains(input.pointerMinimumPublishedFrameCount),
          (1...1_000).contains(input.pointerMinimumPublishedEventCount)
        else {
          throw DoryARMVirtCompatibilityMatrixError.invalidGate(gate.gateID)
        }
      }
      if let audio = gate.audio {
        guard gate.kind == .desktopLiveBoot,
          (1...10_000).contains(audio.minimumCompletedPlaybackPeriodCount),
          (1...10_000).contains(audio.minimumCompletedCapturePeriodCount),
          (1...(1 << 30)).contains(audio.minimumPlaybackByteCount),
          (1...(1 << 30)).contains(audio.minimumCaptureByteCount)
        else {
          throw DoryARMVirtCompatibilityMatrixError.invalidGate(gate.gateID)
        }
      }
      if let guestTools = gate.guestTools {
        guard gate.kind == .desktopLiveBoot,
          (512...(1 << 30)).contains(guestTools.byteCount),
          guestTools.byteCount.isMultiple(of: 512),
          Self.isSHA256(guestTools.sha256),
          Self.isSHA256(guestTools.agentSHA256)
        else {
          throw DoryARMVirtCompatibilityMatrixError.invalidGate(gate.gateID)
        }
      }
      if let camera = gate.camera {
        guard gate.kind == .desktopLiveBoot,
          gate.guestTools != nil,
          !camera.busID.isEmpty,
          camera.busID.utf8.count < 32,
          camera.busID.utf8.allSatisfy({
            (48...57).contains($0) || $0 == 45 || $0 == 46
          }),
          camera.busNumber > 0,
          camera.deviceNumber > 0,
          camera.busID == "\(camera.busNumber)-\(camera.deviceNumber)",
          camera.vendorID > 0,
          camera.productID > 0,
          (160...3_840).contains(camera.widthPixels),
          (120...2_160).contains(camera.heightPixels),
          (1...10_000).contains(camera.minimumHostFrameRequestCount),
          (1...UInt64(32 << 20)).contains(camera.minimumJPEGByteCount)
        else {
          throw DoryARMVirtCompatibilityMatrixError.invalidGate(gate.gateID)
        }
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
