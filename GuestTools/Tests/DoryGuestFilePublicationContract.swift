import DoryMacGuestIntegrationWire
import Foundation

/// Standalone source-level contract for the Guest Tools app target. Compile together with
/// DoryGuestFilePublication.swift and the built integration-wire module.
@main
struct DoryGuestFilePublicationContract {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dory-guest-publication-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let received = root.appendingPathComponent("received", isDirectory: true)
    let completedID = UUID()
    let completed = received.appendingPathComponent("\(completedID.uuidString)-guest.txt")
    do {
      let publication = try DoryGuestFilePublication(
        directory: received, transferID: completedID, name: "guest.txt"
      )
      try publication.output.write(contentsOf: Data("complete".utf8))
      precondition(!FileManager.default.fileExists(atPath: completed.path))
      try publication.publish()
    }
    let completedBytes = try Data(contentsOf: completed)
    let completedContents = try FileManager.default.contentsOfDirectory(atPath: received.path)
    precondition(completedBytes == Data("complete".utf8))
    precondition(completedContents == [completed.lastPathComponent])

    let cancelledID = UUID()
    do {
      let publication = try DoryGuestFilePublication(
        directory: received, transferID: cancelledID, name: "guest.txt"
      )
      try publication.output.write(contentsOf: Data("partial".utf8))
    }
    let afterCancellation = try FileManager.default.contentsOfDirectory(atPath: received.path)
    precondition(afterCancellation == [completed.lastPathComponent])

    let duplicateID = UUID()
    let duplicate = received.appendingPathComponent("\(duplicateID.uuidString)-guest.txt")
    try Data("keep".utf8).write(to: duplicate)
    do {
      let publication = try DoryGuestFilePublication(
        directory: received, transferID: duplicateID, name: "guest.txt"
      )
      try publication.output.write(contentsOf: Data("replacement".utf8))
      do {
        try publication.publish()
        preconditionFailure("existing destination was overwritten")
      } catch DoryMacGuestIntegrationWire.WireError.invalidEnvelope {
        // An existing name cannot be overwritten, regardless of its file type.
      }
    }
    let duplicateBytes = try Data(contentsOf: duplicate)
    precondition(duplicateBytes == Data("keep".utf8))

    let moved = root.appendingPathComponent("moved", isDirectory: true)
    let movedID = UUID()
    do {
      let publication = try DoryGuestFilePublication(
        directory: received, transferID: movedID, name: "guest.txt"
      )
      try publication.output.write(contentsOf: Data("redirected".utf8))
      try FileManager.default.moveItem(at: received, to: moved)
      try FileManager.default.createDirectory(at: received, withIntermediateDirectories: false)
      do {
        try publication.publish()
        preconditionFailure("replaced directory accepted publication")
      } catch DoryMacGuestIntegrationWire.WireError.invalidEnvelope {
        // The open descriptor remains pinned to the moved original for safe cleanup.
      }
    }
    let replacementContents = try FileManager.default.contentsOfDirectory(atPath: received.path)
    let movedContents = try Set(FileManager.default.contentsOfDirectory(atPath: moved.path))
    precondition(replacementContents.isEmpty)
    precondition(movedContents == [completed.lastPathComponent, duplicate.lastPathComponent])
    try finalAuthorizationRetirementContracts(root: root)
    try directoryReplacementDuringAuthorization(root: root)
    print("Dory guest file publication contract passed")
  }

  private enum RetiredAuthorization: String, CaseIterable {
    case consoleRevoked, reconnected, expired, skipped
  }

  /// Execute revocation at the real publisher's post-flush callback, not on a source clone or
  /// before preparation. An independently staged successor must survive the old cleanup.
  private static func finalAuthorizationRetirementContracts(root: URL) throws {
    for scenario in RetiredAuthorization.allCases {
      let directory = root.appendingPathComponent(scenario.rawValue, isDirectory: true)
      let oldID = UUID(), successorID = UUID(), originalConnection = UUID()
      let oldDestination = directory.appendingPathComponent("\(oldID.uuidString)-guest.txt")
      let nextDestination = directory.appendingPathComponent("\(successorID.uuidString)-guest.txt")
      var session = DoryMacGuestIntegrationWire.UserSessionAuthority()
      session.transition(active: true)
      guard let originalLease = session.lease else { preconditionFailure("missing active lease") }
      let request = try DoryMacGuestIntegrationWire.Envelope(
        kind: .request, sessionID: UUID(), machineID: String(repeating: "a", count: 64),
        runtimeGeneration: 7, requestID: 3, capability: .filePush, timeoutMilliseconds: 10)
      var admission = try DoryMacGuestIntegrationWire.UserActionAdmission(
        request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
      var successor: DoryGuestFilePublication?
      var reachedFinalAuthorization = false
      do {
        let publication = try DoryGuestFilePublication(
          directory: directory, transferID: oldID, name: "guest.txt")
        try publication.output.write(contentsOf: Data("retired".utf8))
        do {
          try publication.publish { mutation in
            reachedFinalAuthorization = true
            successor = try DoryGuestFilePublication(
              directory: directory, transferID: successorID, name: "guest.txt")
            try successor?.output.write(contentsOf: Data("successor".utf8))
            if scenario == .skipped { return }
            var connection = originalConnection
            var now: UInt64 = 1_009_999_999
            switch scenario {
            case .consoleRevoked:
              session.transition(active: false)
              session.transition(active: true)
            case .reconnected:
              connection = UUID()
            case .expired:
              now = admission.deadlineUptimeNanoseconds
            case .skipped:
              preconditionFailure("skipped authorization unexpectedly continued")
            }
            guard admission.begin(connectionID: originalConnection,
              currentConnectionID: connection, userSession: session, lease: originalLease,
              nowUptimeNanoseconds: now) else {
              throw DoryMacGuestIntegrationWire.WireError.connectionClosed
            }
            try mutation()
          }
          preconditionFailure("\(scenario.rawValue) publication unexpectedly succeeded")
        } catch let error as DoryMacGuestIntegrationWire.WireError {
          precondition(error == (scenario == .skipped ? .invalidEnvelope : .connectionClosed),
            "unexpected \(scenario.rawValue) failure: \(error)")
        }
      }
      precondition(reachedFinalAuthorization)
      precondition(!FileManager.default.fileExists(atPath: oldDestination.path))
      let oldStaging = directory.appendingPathComponent(".transfer-\(oldID.uuidString).partial")
      precondition(!FileManager.default.fileExists(atPath: oldStaging.path))
      let nextStaging = ".transfer-\(successorID.uuidString).partial"
      let afterOldCleanup = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      precondition(afterOldCleanup == [nextStaging], "old cleanup altered successor staging")
      precondition(admission.state == (scenario == .skipped ? .pending
        : scenario == .expired ? .expired : .revoked))
      guard let next = successor else { preconditionFailure("successor was not staged") }
      try next.publish()
      let nextBytes = try Data(contentsOf: nextDestination)
      let finalContents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      precondition(nextBytes == Data("successor".utf8))
      precondition(finalContents == [nextDestination.lastPathComponent])
    }
  }

  private static func directoryReplacementDuringAuthorization(root: URL) throws {
    let selected = root.appendingPathComponent("selected-during-authorization", isDirectory: true)
    let moved = root.appendingPathComponent("moved-during-authorization", isDirectory: true)
    let oldID = UUID(), successorID = UUID()
    let oldDestination = selected.appendingPathComponent("\(oldID.uuidString)-guest.txt")
    let nextDestination = selected.appendingPathComponent("\(successorID.uuidString)-guest.txt")
    var successor: DoryGuestFilePublication?
    do {
      let publication = try DoryGuestFilePublication(
        directory: selected, transferID: oldID, name: "guest.txt")
      try publication.output.write(contentsOf: Data("retired".utf8))
      try Data("original directory".utf8).write(to: selected.appendingPathComponent("keep.txt"))
      do {
        try publication.publish { mutation in
          try FileManager.default.moveItem(at: selected, to: moved)
          successor = try DoryGuestFilePublication(
            directory: selected, transferID: successorID, name: "guest.txt")
          try successor?.output.write(contentsOf: Data("replacement directory".utf8))
          try mutation()
        }
        preconditionFailure("directory replaced during authorization accepted publication")
      } catch DoryMacGuestIntegrationWire.WireError.invalidEnvelope {
        // Rechecking the path inside mutation rejects even this post-preparation replacement.
      }
    }
    precondition(!FileManager.default.fileExists(atPath: oldDestination.path))
    let movedContents = try FileManager.default.contentsOfDirectory(atPath: moved.path)
    let preserved = try Data(contentsOf: moved.appendingPathComponent("keep.txt"))
    precondition(movedContents == ["keep.txt"], "old cleanup leaked or published in moved directory")
    precondition(preserved == Data("original directory".utf8))
    let nextStaging = ".transfer-\(successorID.uuidString).partial"
    let selectedContents = try FileManager.default.contentsOfDirectory(atPath: selected.path)
    precondition(selectedContents == [nextStaging], "old cleanup altered replacement directory")
    guard let next = successor else { preconditionFailure("replacement staging was lost") }
    try next.publish()
    let nextBytes = try Data(contentsOf: nextDestination)
    let finalContents = try FileManager.default.contentsOfDirectory(atPath: selected.path)
    precondition(nextBytes == Data("replacement directory".utf8))
    precondition(finalContents == [nextDestination.lastPathComponent])
  }
}
