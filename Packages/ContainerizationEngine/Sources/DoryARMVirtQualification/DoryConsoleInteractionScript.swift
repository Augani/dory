import Foundation

public enum DoryInstallerMediaState: String, Codable, Equatable, Sendable {
  case attached
  case detached
}

public enum DoryConsoleAfterGuestStopAction: String, Codable, Equatable, Sendable {
  case captureColdSnapshot = "capture-cold-snapshot"
  case restoreColdSnapshot = "restore-cold-snapshot"
}

public struct DoryConsoleQualificationTarget: Codable, Equatable, Sendable {
  public let guestFamily: String
  public let guestVersion: String
  public let guestBuild: String
  public let guestArchitecture: String

  public init(
    guestFamily: String,
    guestVersion: String,
    guestBuild: String,
    guestArchitecture: String
  ) {
    self.guestFamily = guestFamily
    self.guestVersion = guestVersion
    self.guestBuild = guestBuild
    self.guestArchitecture = guestArchitecture
  }
}

public struct DoryConsoleInteractionStep: Codable, Equatable, Sendable {
  public let waitFor: String
  public let send: String
  public let installerMediaAfterSend: DoryInstallerMediaState?
  public let afterGuestStop: DoryConsoleAfterGuestStopAction?

  public init(
    waitFor: String,
    send: String,
    installerMediaAfterSend: DoryInstallerMediaState? = nil,
    afterGuestStop: DoryConsoleAfterGuestStopAction? = nil
  ) {
    self.waitFor = waitFor
    self.send = send
    self.installerMediaAfterSend = installerMediaAfterSend
    self.afterGuestStop = afterGuestStop
  }

  private enum CodingKeys: String, CodingKey {
    case waitFor
    case send
    case installerMediaAfterSend
    case afterGuestStop
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    waitFor = try container.decode(String.self, forKey: .waitFor)
    send = try container.decode(String.self, forKey: .send)
    installerMediaAfterSend = try container.decodeIfPresent(
      DoryInstallerMediaState.self,
      forKey: .installerMediaAfterSend
    )
    afterGuestStop = try container.decodeIfPresent(
      DoryConsoleAfterGuestStopAction.self,
      forKey: .afterGuestStop
    )
  }
}

public struct DoryConsoleInteractionScript: Codable, Equatable, Sendable {
  public let schemaVersion: UInt32
  public let qualificationTarget: DoryConsoleQualificationTarget?
  public let steps: [DoryConsoleInteractionStep]

  public init(
    schemaVersion: UInt32 = 1,
    qualificationTarget: DoryConsoleQualificationTarget? = nil,
    steps: [DoryConsoleInteractionStep]
  ) {
    self.schemaVersion = schemaVersion
    self.qualificationTarget = qualificationTarget
    self.steps = steps
  }
}

public enum DoryConsoleInteractionScriptError: Error, Equatable, Sendable {
  case unsupportedSchemaVersion(UInt32)
  case invalidStepCount(Int)
  case invalidQualificationTarget
  case invalidWaitMarker(step: Int)
  case invalidInput(step: Int)
  case inputBudgetExceeded
  case redundantInstallerMediaTransition(step: Int, state: DoryInstallerMediaState)
  case invalidColdSnapshotActionSequence(step: Int, action: DoryConsoleAfterGuestStopAction)
  case hostActionNotPending
  case hostActionMismatch
}

public final class DoryConsoleInteractionDriver {
  public static let maximumStepCount = 128
  public static let maximumWaitMarkerBytes = 1_024
  public static let maximumInputBytesPerStep = 16_384
  public static let maximumTotalInputBytes = 256 * 1_024

  private let steps: [DoryConsoleInteractionStep]
  private var nextStepIndex = 0
  private var searchOffset = 0

  public let containsInstallerMediaTransition: Bool
  public private(set) var installerMediaState = DoryInstallerMediaState.attached
  public private(set) var installerMediaTransitionCount = 0
  public let hostActionCount: Int
  public let qualificationTarget: DoryConsoleQualificationTarget?
  public private(set) var completedHostActionCount = 0
  public private(set) var pendingHostAction: DoryConsoleAfterGuestStopAction?

  public init(script: DoryConsoleInteractionScript) throws {
    guard script.schemaVersion == 1 else {
      throw DoryConsoleInteractionScriptError.unsupportedSchemaVersion(script.schemaVersion)
    }
    guard (1...Self.maximumStepCount).contains(script.steps.count) else {
      throw DoryConsoleInteractionScriptError.invalidStepCount(script.steps.count)
    }
    if let target = script.qualificationTarget {
      let fields = [
        target.guestFamily, target.guestVersion, target.guestBuild, target.guestArchitecture,
      ]
      guard fields.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
        target.guestArchitecture == "arm64"
      else {
        throw DoryConsoleInteractionScriptError.invalidQualificationTarget
      }
    }

    var totalInputBytes = 0
    var configuredInstallerMediaState = DoryInstallerMediaState.attached
    var containsInstallerMediaTransition = false
    var configuredHostActions: [DoryConsoleAfterGuestStopAction] = []
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
      if let requestedState = step.installerMediaAfterSend {
        guard requestedState != configuredInstallerMediaState else {
          throw DoryConsoleInteractionScriptError.redundantInstallerMediaTransition(
            step: index,
            state: requestedState
          )
        }
        configuredInstallerMediaState = requestedState
        containsInstallerMediaTransition = true
      }
      if let action = step.afterGuestStop {
        configuredHostActions.append(action)
        let expected: [DoryConsoleAfterGuestStopAction] =
          configuredHostActions.count == 1
          ? [.captureColdSnapshot] : [.captureColdSnapshot, .restoreColdSnapshot]
        guard configuredHostActions == expected else {
          throw DoryConsoleInteractionScriptError.invalidColdSnapshotActionSequence(
            step: index,
            action: action
          )
        }
      }
    }
    steps = script.steps
    qualificationTarget = script.qualificationTarget
    self.containsInstallerMediaTransition = containsInstallerMediaTransition
    hostActionCount = configuredHostActions.count
  }

  public var completedStepCount: Int { nextStepIndex }
  public var stepCount: Int { steps.count }
  public var isComplete: Bool { nextStepIndex == steps.count }

  public func inputContains(_ text: String) -> Bool {
    steps.contains { $0.send.contains(text) }
  }

  public func nextInput(consoleBytes: [UInt8]) -> [UInt8]? {
    guard pendingHostAction == nil, nextStepIndex < steps.count else { return nil }
    let step = steps[nextStepIndex]
    let marker = Array(step.waitFor.utf8)
    guard consoleBytes.count >= marker.count else { return nil }

    let lastStart = consoleBytes.count - marker.count
    if searchOffset <= lastStart {
      for offset in searchOffset...lastStart
      where consoleBytes[offset..<(offset + marker.count)].elementsEqual(marker) {
        searchOffset = offset + marker.count
        nextStepIndex += 1
        if let installerMediaAfterSend = step.installerMediaAfterSend {
          installerMediaState = installerMediaAfterSend
          installerMediaTransitionCount += 1
        }
        pendingHostAction = step.afterGuestStop
        return Array(step.send.utf8)
      }
    }
    searchOffset = max(searchOffset, lastStart + 1)
    return nil
  }

  public func completeHostAction(_ action: DoryConsoleAfterGuestStopAction) throws {
    guard let pendingHostAction else {
      throw DoryConsoleInteractionScriptError.hostActionNotPending
    }
    guard pendingHostAction == action else {
      throw DoryConsoleInteractionScriptError.hostActionMismatch
    }
    self.pendingHostAction = nil
    completedHostActionCount += 1
  }
}
