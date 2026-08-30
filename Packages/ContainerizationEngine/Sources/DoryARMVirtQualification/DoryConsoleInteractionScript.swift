import Foundation

public struct DoryConsoleInteractionStep: Codable, Equatable, Sendable {
  public let waitFor: String
  public let send: String
  public let detachInstallerAfterSend: Bool

  public init(
    waitFor: String,
    send: String,
    detachInstallerAfterSend: Bool = false
  ) {
    self.waitFor = waitFor
    self.send = send
    self.detachInstallerAfterSend = detachInstallerAfterSend
  }

  private enum CodingKeys: String, CodingKey {
    case waitFor
    case send
    case detachInstallerAfterSend
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    waitFor = try container.decode(String.self, forKey: .waitFor)
    send = try container.decode(String.self, forKey: .send)
    detachInstallerAfterSend =
      try container.decodeIfPresent(
        Bool.self,
        forKey: .detachInstallerAfterSend
      ) ?? false
  }
}

public struct DoryConsoleInteractionScript: Codable, Equatable, Sendable {
  public let schemaVersion: UInt32
  public let steps: [DoryConsoleInteractionStep]

  public init(schemaVersion: UInt32 = 1, steps: [DoryConsoleInteractionStep]) {
    self.schemaVersion = schemaVersion
    self.steps = steps
  }
}

public enum DoryConsoleInteractionScriptError: Error, Equatable, Sendable {
  case unsupportedSchemaVersion(UInt32)
  case invalidStepCount(Int)
  case invalidWaitMarker(step: Int)
  case invalidInput(step: Int)
  case inputBudgetExceeded
  case multipleInstallerDetachSteps
}

public final class DoryConsoleInteractionDriver {
  public static let maximumStepCount = 128
  public static let maximumWaitMarkerBytes = 1_024
  public static let maximumInputBytesPerStep = 16_384
  public static let maximumTotalInputBytes = 256 * 1_024

  private let steps: [DoryConsoleInteractionStep]
  private var nextStepIndex = 0
  private var searchOffset = 0

  public let containsInstallerDetachStep: Bool
  public private(set) var shouldDetachInstaller = false

  public init(script: DoryConsoleInteractionScript) throws {
    guard script.schemaVersion == 1 else {
      throw DoryConsoleInteractionScriptError.unsupportedSchemaVersion(script.schemaVersion)
    }
    guard (1...Self.maximumStepCount).contains(script.steps.count) else {
      throw DoryConsoleInteractionScriptError.invalidStepCount(script.steps.count)
    }

    var totalInputBytes = 0
    var detachStepCount = 0
    for (index, step) in script.steps.enumerated() {
      guard !step.waitFor.isEmpty,
        step.waitFor.utf8.count <= Self.maximumWaitMarkerBytes
      else {
        throw DoryConsoleInteractionScriptError.invalidWaitMarker(step: index)
      }
      guard !step.send.isEmpty,
        step.send.utf8.count <= Self.maximumInputBytesPerStep
      else {
        throw DoryConsoleInteractionScriptError.invalidInput(step: index)
      }
      totalInputBytes += step.send.utf8.count
      guard totalInputBytes <= Self.maximumTotalInputBytes else {
        throw DoryConsoleInteractionScriptError.inputBudgetExceeded
      }
      if step.detachInstallerAfterSend {
        detachStepCount += 1
      }
    }
    guard detachStepCount <= 1 else {
      throw DoryConsoleInteractionScriptError.multipleInstallerDetachSteps
    }
    steps = script.steps
    containsInstallerDetachStep = detachStepCount == 1
  }

  public var completedStepCount: Int { nextStepIndex }
  public var stepCount: Int { steps.count }
  public var isComplete: Bool { nextStepIndex == steps.count }

  public func inputContains(_ text: String) -> Bool {
    steps.contains { $0.send.contains(text) }
  }

  public func nextInput(consoleBytes: [UInt8]) -> [UInt8]? {
    guard nextStepIndex < steps.count else { return nil }
    let step = steps[nextStepIndex]
    let marker = Array(step.waitFor.utf8)
    guard consoleBytes.count >= marker.count else { return nil }

    let lastStart = consoleBytes.count - marker.count
    if searchOffset <= lastStart {
      for offset in searchOffset...lastStart
      where consoleBytes[offset..<(offset + marker.count)].elementsEqual(marker) {
        searchOffset = offset + marker.count
        nextStepIndex += 1
        if step.detachInstallerAfterSend {
          shouldDetachInstaller = true
        }
        return Array(step.send.utf8)
      }
    }
    searchOffset = max(searchOffset, lastStart + 1)
    return nil
  }
}
