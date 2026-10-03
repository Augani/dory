import Darwin
import DoryMacGuestIntegrationWire
import Foundation
import Testing
@testable import DoryVZMacCore

@Suite struct DoryVZMacGuestFilePublicationTests {
  @Test func quietLivePeerPermitsActualFinalPublication() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sockets = try PublicationSocketPair()
    let destination = root.appendingPathComponent("guest.txt")
    try Data("keep".utf8).write(to: destination)
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("verified".utf8))
      try publication.publish { mutation in
        guard DoryVZMacGuestIntegrationService.peerPermitsPublication(sockets.local) else {
          throw DoryMacGuestIntegrationWire.WireError.connectionClosed
        }
        try mutation()
      }
    }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "verified")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["guest.txt"])
  }

  @Test(arguments: [false, true])
  func peerShutdownAfterStagingCannotPublishOrRetireSuccessor(closePeer: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sockets = try PublicationSocketPair()
    let destination = root.appendingPathComponent("guest.txt")
    try Data("keep".utf8).write(to: destination)
    var successor: DoryVZMacGuestFilePublication?
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("retired".utf8))
      #expect(throws: DoryMacGuestIntegrationWire.WireError.connectionClosed) {
        try publication.publish { mutation in
          // The final callback is after actual staging sync/close, matching a guest that
          // revokes its console session while the host is preparing publication.
          if closePeer {
            sockets.closeRemote()
          } else {
            let remoteValue = sockets.remote
            let remote = try #require(remoteValue)
            guard shutdown(remote, SHUT_WR) == 0 else {
              throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
            }
          }
          successor = try DoryVZMacGuestFilePublication(destination: destination)
          try successor?.output.write(contentsOf: Data("successor".utf8))
          guard DoryVZMacGuestIntegrationService.peerPermitsPublication(sockets.local) else {
            throw DoryMacGuestIntegrationWire.WireError.connectionClosed
          }
          try mutation()
        }
      }
    }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
    let successorValue = successor
    let next = try #require(successorValue)
    try next.publish()
    #expect(try String(contentsOf: destination, encoding: .utf8) == "successor")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["guest.txt"])
  }

  @Test func unexpectedReadableProtocolDataDeniesPublicationWithoutConsumingBytes() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sockets = try PublicationSocketPair()
    let remoteValue = sockets.remote
    let remote = try #require(remoteValue)
    let unexpected: [UInt8] = [0x51, 0x72, 0x93]
    let destination = root.appendingPathComponent("guest.txt")
    try Data("keep".utf8).write(to: destination)
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("retired".utf8))
      #expect(throws: DoryMacGuestIntegrationWire.WireError.connectionClosed) {
        try publication.publish { mutation in
          let sent = unexpected.withUnsafeBytes {
            send(remote, $0.baseAddress, $0.count, MSG_DONTWAIT)
          }
          guard sent == unexpected.count else {
            throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
          }
          guard DoryVZMacGuestIntegrationService.peerPermitsPublication(sockets.local) else {
            throw DoryMacGuestIntegrationWire.WireError.connectionClosed
          }
          try mutation()
        }
      }
    }
    var retained = [UInt8](repeating: 0, count: unexpected.count)
    let received = retained.withUnsafeMutableBytes {
      recv(sockets.local, $0.baseAddress, $0.count, MSG_DONTWAIT)
    }
    #expect(received == unexpected.count)
    #expect(retained == unexpected)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["guest.txt"])
  }

  @Test(arguments: [false, true])
  func invalidPeerDescriptorDeniesActualFinalPublication(closedOwnedDescriptor: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sockets = try PublicationSocketPair()
    let destination = root.appendingPathComponent("guest.txt")
    try Data("keep".utf8).write(to: destination)
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("retired".utf8))
      #expect(throws: DoryMacGuestIntegrationWire.WireError.connectionClosed) {
        try publication.publish { mutation in
          let permitted: Bool
          if closedOwnedDescriptor {
            let retired = dup(sockets.local)
            guard retired >= 0 else { throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno) }
            close(retired)
            // A parallel fixture could reuse this number after close. Model the kernel's
            // POLLNVAL receipt without touching whoever may subsequently own that number.
            permitted = DoryVZMacGuestIntegrationService.peerPermitsPublication(retired) { peer in
              let exactDescriptor = peer.fd == retired
              #expect(exactDescriptor)
              peer.revents = Int16(POLLNVAL)
              return 1
            }
          } else {
            // poll ignores negative descriptors; the helper must reject before calling it.
            permitted = DoryVZMacGuestIntegrationService.peerPermitsPublication(-1)
          }
          guard permitted else {
            throw DoryMacGuestIntegrationWire.WireError.connectionClosed
          }
          try mutation()
        }
      }
    }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["guest.txt"])
  }

  @Test(arguments: [EINTR, EBADF, EIO])
  func pollErrorCannotRenewOrRetryPublicationAdmission(code: Int32) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sockets = try PublicationSocketPair()
    let destination = root.appendingPathComponent("guest.txt")
    try Data("keep".utf8).write(to: destination)
    var pollCount = 0
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("retired".utf8))
      #expect(throws: DoryMacGuestIntegrationWire.WireError.connectionClosed) {
        try publication.publish { mutation in
          let permitted = DoryVZMacGuestIntegrationService.peerPermitsPublication(sockets.local) { _ in
            pollCount += 1
            errno = code
            return -1
          }
          guard permitted else { throw DoryMacGuestIntegrationWire.WireError.connectionClosed }
          try mutation()
        }
      }
    }
    #expect(pollCount == 1)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["guest.txt"])
  }

  @Test(arguments: [UInt64(1_009_999_999), UInt64(1_010_000_000), UInt64(1_020_000_000)])
  func finalPublicationUsesOriginalFinishRequestBudgetAfterPreparation(now: UInt64) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("guest.txt")
    try Data("keep".utf8).write(to: destination)
    let request = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: UUID(), machineID: String(repeating: "a", count: 64),
      runtimeGeneration: 7, requestID: 3, capability: .filePull, timeoutMilliseconds: 10)
    var admission = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("verified".utf8))
      var reachedFinalAdmission = false
      let publish = {
        try publication.publish { mutation in
          reachedFinalAdmission = true
          guard admission.begin(nowUptimeNanoseconds: now) else {
            throw DoryVZMacGuestIntegrationError.expired
          }
          try mutation()
        }
      }
      if now < admission.deadlineUptimeNanoseconds {
        try publish()
      } else {
        #expect(throws: DoryVZMacGuestIntegrationError.expired) { try publish() }
      }
      #expect(reachedFinalAdmission)
    }
    #expect(try String(contentsOf: destination, encoding: .utf8)
      == (now < admission.deadlineUptimeNanoseconds ? "verified" : "keep"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["guest.txt"])
  }

  @Test func revokedConnectionPublicationCannotTouchSuccessorStaging() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("guest.txt")
    try Data("keep".utf8).write(to: destination)
    var connection = DoryVZMacGuestIntegrationConnectionAuthority()
    try connection.install()
    let admitted = connection.accept()
    let old = try #require(admitted)
    var successor: DoryVZMacGuestFilePublication?
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("old".utf8))
      #expect(throws: CancellationError.self) {
        try publication.publish { mutation in
          // Deterministic preparation/admission gap: revoke the original registration and
          // admit a successor before the old publication's final mutation can begin.
          connection.removeRegistration()
          connection.finish(old)
          try connection.install()
          let next = connection.accept()
          let current = try #require(next)
          #expect(connection.permits(current))
          successor = try DoryVZMacGuestFilePublication(destination: destination)
          try successor?.output.write(contentsOf: Data("successor".utf8))
          guard connection.permits(old) else { throw CancellationError() }
          try mutation()
        }
      }
    }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
    try successor?.publish()
    successor = nil
    #expect(try String(contentsOf: destination, encoding: .utf8) == "successor")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["guest.txt"])
  }

  @Test func skippedPublicationAdmissionDoesNotReportSuccess() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("guest.txt")
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("unpublished".utf8))
      #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
        try publication.publish { _ in }
      }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test func directoryReplacedInsideFinalAdmissionCannotPublishIntoEitherDirectory() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let selected = root.appendingPathComponent("selected", isDirectory: true)
    let moved = root.appendingPathComponent("moved", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
    let destination = selected.appendingPathComponent("guest.txt")
    try Data("original".utf8).write(to: destination)
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("stale".utf8))
      #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
        try publication.publish { mutation in
          try FileManager.default.moveItem(at: selected, to: moved)
          try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
          try Data("replacement".utf8).write(to: destination)
          try mutation()
        }
      }
    }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "replacement")
    #expect(try String(contentsOf: moved.appendingPathComponent("guest.txt"), encoding: .utf8) == "original")
    #expect(try FileManager.default.contentsOfDirectory(atPath: selected.path) == ["guest.txt"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path) == ["guest.txt"])
  }

  @Test func symlinkInsertedInsideFinalAdmissionCannotReplaceItsTarget() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("guest.txt")
    let victim = root.appendingPathComponent("victim.txt")
    try Data("keep".utf8).write(to: victim)
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("stale".utf8))
      #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
        try publication.publish { mutation in
          try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim)
          try mutation()
        }
      }
    }
    #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == victim.path)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == ["guest.txt", "victim.txt"])
  }

  @Test func publishesANewFileOnlyAfterTheCompleteWrite() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("new.txt")
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("complete".utf8))
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      try publication.publish()
    }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "complete")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["new.txt"])
  }

  @Test func publishesIntoTheSelectedDirectoryAndReplacesOnlyARegularFile() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("guest.txt")
    try Data("old".utf8).write(to: destination)
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("verified guest bytes".utf8))
      try publication.publish()
    }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "verified guest bytes")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["guest.txt"])
  }

  @Test func refusesASymlinkDestinationWithoutChangingItsTarget() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let victim = root.appendingPathComponent("victim.txt")
    let destination = root.appendingPathComponent("guest.txt")
    try Data("keep".utf8).write(to: victim)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim)
    do {
      let publication = try DoryVZMacGuestFilePublication(destination: destination)
      try publication.output.write(contentsOf: Data("guest bytes".utf8))
      #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
        try publication.publish()
      }
    }
    #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == victim.path)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == ["guest.txt", "victim.txt"])
  }

  @Test func refusesADirectoryReplacedDuringTransfer() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let selected = root.appendingPathComponent("selected", isDirectory: true)
    let moved = root.appendingPathComponent("moved", isDirectory: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
    do {
      let publication = try DoryVZMacGuestFilePublication(
        destination: selected.appendingPathComponent("guest.txt")
      )
      try publication.output.write(contentsOf: Data("guest bytes".utf8))
      try FileManager.default.moveItem(at: selected, to: moved)
      try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
      #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
        try publication.publish()
      }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: selected.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dory-mac-file-publication-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
  }

  /// Each fixture owns exact live descriptors; a retired remote descriptor is cleared before
  /// closure so successor staging/parallel tests cannot be accidentally closed by cleanup.
  private final class PublicationSocketPair {
    let local: Int32
    private(set) var remote: Int32?

    init() throws {
      var descriptors: [Int32] = [-1, -1]
      guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
      }
      local = descriptors[0]
      remote = descriptors[1]
    }

    func closeRemote() {
      guard let descriptor = remote else { return }
      remote = nil
      _ = shutdown(descriptor, SHUT_RDWR)
      close(descriptor)
    }

    deinit {
      if let remote { close(remote) }
      close(local)
    }
  }
}
