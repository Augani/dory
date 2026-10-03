import Foundation
import Testing
@testable import DoryVZMacCore
import DoryMacGuestIntegrationWire

@Suite struct DoryVZMacGuestIntegrationServiceTests {
  @Test func removedConnectionRetainsCleanupOwnershipUntilItFinishes() throws {
    var authority = DoryVZMacGuestIntegrationConnectionAuthority()
    let uninstalled = authority.accept()
    #expect(uninstalled == nil)
    try authority.install()
    let admitted = authority.accept()
    let connection = try #require(admitted)
    #expect(authority.permits(connection))
    let overlapping = authority.accept()
    #expect(overlapping == nil)
    authority.removeRegistration()
    #expect(!authority.permits(connection))
    #expect(authority.owns(connection))
    let revoked = authority.accept()
    #expect(revoked == nil)
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      try authority.install()
    }
    let finished = authority.finish(connection)
    #expect(finished)
    try authority.install()
    let replacement = authority.accept()
    let next = try #require(replacement)
    #expect(next != connection)
    #expect(authority.currentIdentity == next)
    let staleFinish = authority.finish(connection)
    #expect(!staleFinish)
    #expect(authority.permits(next))
    #expect(authority.hasConnection)
  }

  @Test func staleDisconnectCannotPublishAdmissionOrRetireSuccessorRequests() throws {
    var authority = DoryVZMacGuestIntegrationConnectionAuthority()
    try authority.install()
    let admitted = authority.accept()
    let old = try #require(admitted)
    let unrelatedFinish = authority.finish(UUID())
    #expect(!unrelatedFinish)
    let overlapping = authority.accept()
    #expect(overlapping == nil)
    // The service takes old pending continuations under the same lock before this finish.
    let oldFinished = authority.finish(old)
    #expect(oldFinished)
    let replacement = authority.accept()
    let next = try #require(replacement)
    #expect(!authority.owns(old))
    #expect(!authority.permits(old))
    #expect(authority.currentIdentity == next)
    let staleFinish = authority.finish(old)
    #expect(!staleFinish)
    #expect(authority.permits(next))
    let nextFinished = authority.finish(next)
    #expect(nextFinished)
  }

  @Test func interruptedGuestActionDoesNotPretendItWasSafeToRetry() {
    #expect(DoryVZMacGuestIntegrationService.interruptedActionError(
      dispatched: false) == .unavailable)
    #expect(DoryVZMacGuestIntegrationService.interruptedActionError(
      dispatched: true) == .outcomeUnknown)
    #expect(DoryVZMacGuestIntegrationError.outcomeUnknown.description.contains(
      "may already have completed"))
  }

  @Test func openURLRequiresAConnectedGrantedGuestSession() async throws {
    let service = try DoryVZMacGuestIntegrationService(
      machineID: String(repeating: "a", count: 64), runtimeGeneration: 7
    )
    await #expect(throws: DoryVZMacGuestIntegrationError.unavailable) {
      try await service.openURL(URL(string: "https://example.org/")!)
    }
    await #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      try await service.openURL(URL(fileURLWithPath: "/etc/passwd"))
    }
  }

  @Test func cancelledOpenURLDoesNotEnterTheGuestRequestQueue() async throws {
    let service = try DoryVZMacGuestIntegrationService(
      machineID: String(repeating: "a", count: 64), runtimeGeneration: 7
    )
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await service.openURL(URL(string: "https://example.org/")!)
    }
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test func clipboardReadRequiresAnExplicitGrantAndConnectedSession() async throws {
    let service = try DoryVZMacGuestIntegrationService(
      machineID: String(repeating: "a", count: 64), runtimeGeneration: 7,
      allowClipboardTextRead: true
    )
    await #expect(throws: DoryVZMacGuestIntegrationError.unavailable) {
      try await service.readClipboardText()
    }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      _ = try await service.readClipboardText()
    }
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test func clipboardWriteRequiresAnExplicitGrantAndConnectedSession() async throws {
    let service = try DoryVZMacGuestIntegrationService(
      machineID: String(repeating: "a", count: 64), runtimeGeneration: 7,
      allowClipboardTextWrite: true
    )
    await #expect(throws: DoryVZMacGuestIntegrationError.unavailable) {
      try await service.writeClipboardText("Hello")
    }
    await #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      try await service.writeClipboardText("")
    }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await service.writeClipboardText("Hello")
    }
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test func imageClipboardRequiresPNGAndAConnectedGrantedSession() async throws {
    let service = try DoryVZMacGuestIntegrationService(
      machineID: String(repeating: "a", count: 64), runtimeGeneration: 7,
      allowClipboardImageRead: true, allowClipboardImageWrite: true
    )
    let png = try #require(Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    ))
    await #expect(throws: DoryVZMacGuestIntegrationError.unavailable) {
      _ = try await service.readClipboardPNG()
    }
    await #expect(throws: DoryVZMacGuestIntegrationError.unavailable) {
      try await service.writeClipboardPNG(png)
    }
    await #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      try await service.writeClipboardPNG(Data("file:///etc/passwd".utf8))
    }
  }

  @Test func fileTransfersRequireConnectedSessionAndSelectedOffer() async throws {
    let service = try DoryVZMacGuestIntegrationService(
      machineID: String(repeating: "a", count: 64), runtimeGeneration: 7
    )
    await #expect(throws: DoryVZMacGuestIntegrationError.unavailable) {
      try await service.sendFileToGuest(at: URL(fileURLWithPath: "/tmp/example.txt"))
    }
    await #expect(throws: DoryVZMacGuestIntegrationError.unavailable) {
      _ = try await service.fileOfferedByGuest()
    }
    let offer = try DoryMacGuestIntegrationWire.FilePullOffer(
      offerID: UUID(), name: "guest.txt", byteCount: 0
    )
    await #expect(throws: DoryVZMacGuestIntegrationError.unavailable) {
      try await service.receiveFileFromGuest(
        offer, to: URL(fileURLWithPath: "/tmp/guest.txt")
      )
    }
    await #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      try await service.receiveFileFromGuest(
        offer, to: URL(string: "https://example.org/guest.txt")!
      )
    }
  }
}
