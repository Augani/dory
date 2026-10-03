import Darwin
import Foundation
import Testing
@testable import DoryMacGuestIntegrationWire

@Suite struct DoryMacGuestIntegrationWireTests {
  private let machineID = String(repeating: "a", count: 64)

  @Test(arguments: [DoryMacGuestIntegrationWire.Capability.filePush, .filePull])
  func fileMutationAdmissionRejectsReconnectConsoleSwitchAndPreparationTimeout(
    capability: DoryMacGuestIntegrationWire.Capability
  ) throws {
    let request = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: UUID(), machineID: machineID,
      runtimeGeneration: 7, requestID: 11, capability: capability, timeoutMilliseconds: 10)
    var session = DoryMacGuestIntegrationWire.UserSessionAuthority()
    session.transition(active: true)
    let lease = try #require(session.lease)
    let connection = UUID()
    var stale = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
    // Reused descriptor numbers are irrelevant: the original connection UUID is required.
    let staleBegan = stale.begin(connectionID: connection, currentConnectionID: UUID(),
      userSession: session, lease: lease, nowUptimeNanoseconds: 1_000_000_001)
    #expect(!staleBegan)
    #expect(stale.state == .revoked)
    var switched = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
    session.transition(active: true)
    let switchedBegan = switched.begin(connectionID: connection, currentConnectionID: connection,
      userSession: session, lease: lease, nowUptimeNanoseconds: 1_000_000_001)
    #expect(!switchedBegan)
    #expect(switched.state == .revoked)
    let current = try #require(session.lease)
    var expired = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
    let expiredBegan = expired.begin(connectionID: connection, currentConnectionID: connection,
      userSession: session, lease: current, nowUptimeNanoseconds: 1_010_000_000)
    #expect(!expiredBegan)
    #expect(expired.state == .expired)
    var active = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
    let activeBegan = active.begin(connectionID: connection, currentConnectionID: connection,
      userSession: session, lease: current, nowUptimeNanoseconds: 1_009_999_999)
    #expect(activeBegan)
    let repeated = active.begin(connectionID: connection, currentConnectionID: connection,
      userSession: session, lease: current, nowUptimeNanoseconds: 1_000_000_001)
    #expect(!repeated)
  }

  @Test(arguments: [DoryMacGuestIntegrationWire.FilePullRequest.Phase.metadata, .chunk, .finish, .cancel])
  func offeredFileAuthorityRejectsOldRequestsWithoutRevokingReplacement(
    phase: DoryMacGuestIntegrationWire.FilePullRequest.Phase
  ) throws {
    let connection = UUID(), lease = UUID(), oldID = UUID(), nextID = UUID()
    let replacement = DoryMacGuestIntegrationWire.FileOfferAuthority(
      offerID: nextID, connectionID: connection, userSessionLease: lease)
    let old = try DoryMacGuestIntegrationWire.FilePullRequest(
      phase: phase, offerID: phase == .metadata ? nil : oldID,
      offset: phase == .chunk ? 0 : nil)
    #expect(!replacement.permits(old, connectionID: UUID(), userSessionLease: lease))
    #expect(!replacement.permits(old, connectionID: connection, userSessionLease: UUID()))
    #expect(replacement.permits(old, connectionID: connection, userSessionLease: lease)
      == (phase == .metadata))
    let next = try DoryMacGuestIntegrationWire.FilePullRequest(
      phase: phase, offerID: phase == .metadata ? nil : nextID,
      offset: phase == .chunk ? 0 : nil)
    #expect(replacement.permits(next, connectionID: connection, userSessionLease: lease))
  }

  @Test(arguments: [UInt64(1_009_999_999), UInt64(1_010_000_000), UInt64(1_020_000_000), UInt64(999_999_999)])
  func userActionAdmissionNeverRenewsOriginalReceiveDeadline(now: UInt64) throws {
    let request = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: UUID(), machineID: machineID,
      runtimeGeneration: 7, requestID: 11, capability: .openURL, timeoutMilliseconds: 10)
    var admission = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
    #expect(admission.deadlineUptimeNanoseconds == 1_010_000_000)
    let admitted = admission.begin(nowUptimeNanoseconds: now)
    #expect(admitted == (now == 1_009_999_999))
    let repeated = admission.begin(nowUptimeNanoseconds: 1_000_000_001)
    #expect(!repeated)
    #expect(admission.state == (admitted ? .begun : .expired))
  }

  @Test func queuedActionRevocationAndCompletionAreTerminalButDoNotUndoBegunAction() throws {
    let request = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: UUID(), machineID: machineID,
      runtimeGeneration: 7, requestID: 11, capability: .clipboardTextWrite, timeoutMilliseconds: 10)
    var queued = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
    let revoked = queued.revoke()
    #expect(revoked)
    let revokedBegin = queued.begin(nowUptimeNanoseconds: 1_000_000_001)
    #expect(!revokedBegin)
    let repeatedRevoke = queued.revoke()
    #expect(!repeatedRevoke)
    queued.complete()
    #expect(queued.state == .revoked)
    var begun = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
    let firstBegin = begun.begin(nowUptimeNanoseconds: 1_000_000_001)
    #expect(firstBegin)
    let begunRevoke = begun.revoke()
    #expect(!begunRevoke)
    begun.complete()
    let completedBegin = begun.begin(nowUptimeNanoseconds: 1_000_000_002)
    #expect(!completedBegin)
    #expect(begun.state == .completed)
  }

  @Test func invalidOrOverflowedUserActionBudgetCannotAcquireAdmission() throws {
    let challenge = try DoryMacGuestIntegrationWire.Envelope(
      kind: .challenge, sessionID: UUID(), machineID: machineID,
      runtimeGeneration: 7, challengeNonce: UUID())
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.UserActionAdmission(
        request: challenge, receivedAtUptimeNanoseconds: 1_000_000_000)
    }
    let request = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: UUID(), machineID: machineID,
      runtimeGeneration: 7, requestID: 11, capability: .openURL, timeoutMilliseconds: 10)
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.UserActionAdmission(
        request: request, receivedAtUptimeNanoseconds: UInt64.max - 1)
    }
  }

  @Test func consoleSwitchBetweenQueuedValidationAndBeginRejectsOldNonce() throws {
    let request = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: UUID(), machineID: machineID,
      runtimeGeneration: 7, requestID: 11, capability: .openURL, timeoutMilliseconds: 10)
    var session = DoryMacGuestIntegrationWire.UserSessionAuthority()
    session.transition(active: true)
    let old = try #require(session.lease)
    #expect(session.permits(old))
    var action = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
    // This is the formerly unsafe admission gap: the queued callback observed an active
    // session, but a console change replaced its nonce before the action actually began.
    session.transition(active: false)
    session.transition(active: true)
    let began = action.begin(userSession: session, lease: old,
      nowUptimeNanoseconds: 1_000_000_001)
    #expect(!began)
    #expect(action.state == .revoked)
    var successor = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
    let current = try #require(session.lease)
    let currentBegan = successor.begin(userSession: session, lease: current,
      nowUptimeNanoseconds: 1_000_000_001)
    #expect(currentBegan)
  }

  @Test func guestUserSessionIsDeniedUntilExplicitlyActivated() {
    let authority = DoryMacGuestIntegrationWire.UserSessionAuthority()
    #expect(authority.lease == nil)
    #expect(!authority.permits(UUID()))
  }

  @Test func inactiveOrUnknownConsoleUserCannotAcquireToolsAuthority() {
    for uid in [nil, UInt32(0), UInt32(502)] {
      #expect(!DoryMacGuestIntegrationWire.UserSessionAuthority.ownsConsoleSession(consoleUID: uid, effectiveUID: 501))
    }
    #expect(!DoryMacGuestIntegrationWire.UserSessionAuthority.ownsConsoleSession(consoleUID: 0, effectiveUID: 0))
    #expect(DoryMacGuestIntegrationWire.UserSessionAuthority.ownsConsoleSession(consoleUID: 501, effectiveUID: 501))
  }

  @Test func queuedUserWorkIsRevokedBeforeSessionCanReconnect() throws {
    var authority = DoryMacGuestIntegrationWire.UserSessionAuthority()
    authority.transition(active: true)
    let old = try #require(authority.lease)
    #expect(authority.permits(old))
    authority.transition(active: false)
    #expect(authority.lease == nil)
    #expect(!authority.permits(old))
    authority.transition(active: true)
    let replacement = try #require(authority.lease)
    #expect(replacement != old)
    #expect(authority.permits(replacement))
    #expect(!authority.permits(old))
  }

  @Test func repeatedActivationNeverReauthorizesAnOldQueuedCallback() throws {
    var authority = DoryMacGuestIntegrationWire.UserSessionAuthority()
    var previous: [UUID] = []
    for _ in 0..<64 {
      authority.transition(active: true)
      let lease = try #require(authority.lease)
      #expect(authority.permits(lease))
      #expect(previous.allSatisfy { !authority.permits($0) })
      previous.append(lease)
    }
    authority.transition(active: false)
    #expect(previous.allSatisfy { !authority.permits($0) })
  }

  @Test func implementedCapabilityListMatchesCurrentGuestAndHostHandlers() {
    let capabilities = DoryMacGuestIntegrationWire.implementedCapabilitiesV2
    #expect(capabilities == capabilities.sorted())
    #expect(capabilities == [
      .clipboardImageRead, .clipboardImageWrite, .clipboardTextRead,
      .clipboardTextWrite, .filePull, .filePush, .guestTime, .health, .openURL,
    ])
  }

  @Test func filePushFramesBoundNamesChunksAndDigest() throws {
    let transferID = UUID()
    let begin = try DoryMacGuestIntegrationWire.FilePushRequest(
      phase: .begin, transferID: transferID, name: "notes.txt", byteCount: 65_536
    )
    let chunk = try DoryMacGuestIntegrationWire.FilePushRequest(
      phase: .chunk, transferID: transferID, offset: 0,
      chunk: Data(repeating: 0x61, count: DoryMacGuestIntegrationWire.maximumFileChunkBytes)
    )
    let commit = try DoryMacGuestIntegrationWire.FilePushRequest(
      phase: .commit, transferID: transferID, sha256: String(repeating: "a", count: 64)
    )
    for frame in [begin, chunk, commit] {
      let body = try DoryMacGuestIntegrationWire.encodeFilePushRequest(frame)
      #expect(try DoryMacGuestIntegrationWire.decodeFilePushRequest(body) == frame)
      let envelope = try DoryMacGuestIntegrationWire.Envelope(
        kind: .request, sessionID: UUID(), machineID: machineID,
        runtimeGeneration: 1, requestID: 1, capability: .filePush,
        timeoutMilliseconds: 10_000, body: body
      )
      #expect(try DoryMacGuestIntegrationWire.decode(
        DoryMacGuestIntegrationWire.encode(envelope)
      ) == envelope)
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.FilePushRequest(
        phase: .begin, transferID: UUID(), name: "../host", byteCount: 10
      )
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.FilePushRequest(
        phase: .begin, transferID: UUID(),
        name: String(repeating: "a", count: DoryMacGuestIntegrationWire.maximumFileNameBytes + 1),
        byteCount: 10
      )
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.FilePushRequest(
        phase: .chunk, transferID: UUID(), offset: 0,
        chunk: Data(count: DoryMacGuestIntegrationWire.maximumFileChunkBytes + 1)
      )
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.FilePushRequest(
        phase: .commit, transferID: UUID(), sha256: String(repeating: "A", count: 64)
      )
    }
  }

  @Test func filePullRequiresSelectedOfferAndBoundedCanonicalChunks() throws {
    let offerID = UUID()
    let metadata = try DoryMacGuestIntegrationWire.FilePullRequest(phase: .metadata)
    let chunk = try DoryMacGuestIntegrationWire.FilePullRequest(
      phase: .chunk, offerID: offerID, offset: 0
    )
    let finish = try DoryMacGuestIntegrationWire.FilePullRequest(
      phase: .finish, offerID: offerID
    )
    for request in [metadata, chunk, finish] {
      let body = try DoryMacGuestIntegrationWire.encodeFilePullBody(request)
      let decoded = try DoryMacGuestIntegrationWire.decodeFilePullBody(
        body, as: DoryMacGuestIntegrationWire.FilePullRequest.self
      )
      #expect(decoded == request)
      try decoded.validate()
    }
    let offer = try DoryMacGuestIntegrationWire.FilePullOffer(
      offerID: offerID, name: "guest.txt", byteCount: 65_536
    )
    let offerBody = try DoryMacGuestIntegrationWire.encodeFilePullBody(offer)
    #expect(try DoryMacGuestIntegrationWire.decodeFilePullBody(
      offerBody, as: DoryMacGuestIntegrationWire.FilePullOffer.self
    ) == offer)
    let digest = try DoryMacGuestIntegrationWire.FilePullDigest(
      sha256: String(repeating: "a", count: 64)
    )
    #expect(try DoryMacGuestIntegrationWire.decodeFilePullBody(
      DoryMacGuestIntegrationWire.encodeFilePullBody(digest),
      as: DoryMacGuestIntegrationWire.FilePullDigest.self
    ) == digest)
    let payload = Data(repeating: 0x61, count: DoryMacGuestIntegrationWire.maximumFileChunkBytes)
    let envelope = try DoryMacGuestIntegrationWire.Envelope(
      kind: .response, sessionID: UUID(), machineID: machineID,
      runtimeGeneration: 1, requestID: 1, capability: .filePull,
      status: .success, body: payload
    )
    #expect(try DoryMacGuestIntegrationWire.decode(
      DoryMacGuestIntegrationWire.encode(envelope)
    ) == envelope)
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.Envelope(
        kind: .response, sessionID: UUID(), machineID: machineID,
        runtimeGeneration: 1, requestID: 1, capability: .filePull,
        status: .success, body: Data(count: DoryMacGuestIntegrationWire.maximumFileChunkBytes + 1)
      )
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.FilePullRequest(
        phase: .chunk, offerID: offerID, offset: DoryMacGuestIntegrationWire.maximumFileBytes
      )
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.FilePullOffer(
        offerID: offerID, name: "../host", byteCount: 1
      )
    }
  }

  @Test func imageClipboardCarriesOnlyBoundedValidPNGUnderAnImageCapability() throws {
    let png = try #require(Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    ))
    try DoryMacGuestIntegrationWire.validateClipboardPNG(png)
    let sessionID = UUID()
    let write = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: sessionID, machineID: machineID,
      runtimeGeneration: 2, requestID: 1, capability: .clipboardImageWrite,
      timeoutMilliseconds: 10_000, body: png
    )
    #expect(try DoryMacGuestIntegrationWire.decode(
      DoryMacGuestIntegrationWire.encode(write)
    ) == write)
    let read = try DoryMacGuestIntegrationWire.Envelope(
      kind: .response, sessionID: sessionID, machineID: machineID,
      runtimeGeneration: 2, requestID: 2, capability: .clipboardImageRead,
      status: .success, body: png
    )
    #expect(try DoryMacGuestIntegrationWire.decode(
      DoryMacGuestIntegrationWire.encode(read)
    ) == read)
    let comment = Data("Comment\0".utf8) + Data(repeating: 0x61, count: 40 * 1_024)
    var ancillary = Data([0, 0, 0xA0, 8])
    ancillary.append(contentsOf: Data("tEXt".utf8))
    ancillary.append(comment)
    var checksum: UInt32 = .max
    for byte in ancillary.dropFirst(4) {
      checksum ^= UInt32(byte)
      for _ in 0..<8 {
        checksum = (checksum >> 1) ^ (checksum & 1 == 0 ? 0 : 0xEDB8_8320)
      }
    }
    var bigEndianChecksum = (checksum ^ .max).bigEndian
    withUnsafeBytes(of: &bigEndianChecksum) { ancillary.append(contentsOf: $0) }
    var largePNG = Data(png.dropLast(12))
    largePNG.append(ancillary)
    largePNG.append(Data(png.suffix(12)))
    #expect(largePNG.count > DoryMacGuestIntegrationWire.maximumBodyBytes)
    try DoryMacGuestIntegrationWire.validateClipboardPNG(largePNG)
    let largeWrite = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: sessionID, machineID: machineID,
      runtimeGeneration: 2, requestID: 3, capability: .clipboardImageWrite,
      timeoutMilliseconds: 10_000, body: largePNG
    )
    #expect(try DoryMacGuestIntegrationWire.decode(
      DoryMacGuestIntegrationWire.encode(largeWrite)
    ) == largeWrite)
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.Envelope(
        kind: .request, sessionID: sessionID, machineID: machineID,
        runtimeGeneration: 2, requestID: 4, capability: .health,
        timeoutMilliseconds: 1_000, body: largePNG
      )
    }
    var corrupt = png
    corrupt[45] ^= 1
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      try DoryMacGuestIntegrationWire.validateClipboardPNG(corrupt)
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      try DoryMacGuestIntegrationWire.validateClipboardPNG(png + Data([0]))
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      try DoryMacGuestIntegrationWire.validateClipboardPNG(
        Data(count: DoryMacGuestIntegrationWire.maximumImageBytes + 1)
      )
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.Envelope(
        kind: .request, sessionID: sessionID, machineID: machineID,
        runtimeGeneration: 2, requestID: 3, capability: .clipboardImageWrite,
        timeoutMilliseconds: 1_000, body: Data("not PNG".utf8)
      )
    }
  }

  @Test func clipboardTextResponseIsBoundedAndCanonical() throws {
    let response = try DoryMacGuestIntegrationWire.ClipboardTextResponse(text: "Hello, guest 👋")
    let encoded = try DoryMacGuestIntegrationWire.encodeClipboardTextResponse(response)
    #expect(try DoryMacGuestIntegrationWire.decodeClipboardTextResponse(encoded) == response)
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.ClipboardTextResponse(text: "")
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.ClipboardTextResponse(text: "a\0b")
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.ClipboardTextResponse(
        text: String(repeating: "a", count: 16 * 1_024 + 1)
      )
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.nonCanonicalFrame) {
      _ = try DoryMacGuestIntegrationWire.decodeClipboardTextResponse(
        Data("{\"schema\":\"dory.mac-guest-clipboard-text@1\",\"text\":\"Hello\",\"extra\":1}".utf8)
      )
    }
  }

  @Test func clipboardTextWriteRequestIsBoundedAndCanonical() throws {
    let request = try DoryMacGuestIntegrationWire.ClipboardTextWriteRequest(
      text: "Hello, guest 👋"
    )
    let encoded = try DoryMacGuestIntegrationWire.encodeClipboardTextWriteRequest(request)
    #expect(try DoryMacGuestIntegrationWire.decodeClipboardTextWriteRequest(encoded) == request)
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.ClipboardTextWriteRequest(text: "")
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.ClipboardTextWriteRequest(text: "a\0b")
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.ClipboardTextWriteRequest(
        text: String(repeating: "a", count: 16 * 1_024 + 1)
      )
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.nonCanonicalFrame) {
      _ = try DoryMacGuestIntegrationWire.decodeClipboardTextWriteRequest(
        Data("{\"schema\":\"dory.mac-guest-clipboard-text-write@1\",\"text\":\"Hello\",\"extra\":1}".utf8)
      )
    }
  }

  @Test func challengeAndHelloRequireExactMachineGenerationAndCapabilityShape() throws {
    let sessionID = UUID()
    let nonce = UUID()
    let challenge = try DoryMacGuestIntegrationWire.Envelope(
      kind: .challenge,
      sessionID: sessionID,
      machineID: machineID,
      runtimeGeneration: 7,
      challengeNonce: nonce
    )
    let encoded = try DoryMacGuestIntegrationWire.encode(challenge)
    #expect(try DoryMacGuestIntegrationWire.decode(encoded) == challenge)

    let hello = try DoryMacGuestIntegrationWire.Hello(
      bundleIdentifier: "com.pythonxi.Dory.GuestTools",
      toolsVersion: "1.0",
      toolsBuild: "1",
      offeredCapabilities: [.guestTime, .health]
    )
    let response = try DoryMacGuestIntegrationWire.Envelope(
      kind: .hello,
      sessionID: sessionID,
      machineID: machineID,
      runtimeGeneration: 7,
      challengeNonce: nonce,
      hello: hello
    )
    #expect(try DoryMacGuestIntegrationWire.decode(
      DoryMacGuestIntegrationWire.encode(response)
    ) == response)

    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.Hello(
        bundleIdentifier: "com.pythonxi.Dory.GuestTools",
        toolsVersion: "1.0", toolsBuild: "1",
        offeredCapabilities: [.health, .guestTime]
      )
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.Envelope(
        kind: .challenge, sessionID: sessionID,
        machineID: machineID, runtimeGeneration: 0,
        challengeNonce: nonce
      )
    }
  }

  @Test func requestRequiresBoundedBodyRelativeTimeoutAndIdentity() throws {
    let request = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: UUID(), machineID: machineID,
      runtimeGeneration: 1, requestID: 1, capability: .health,
      timeoutMilliseconds: 1_000, body: Data([1, 2])
    )
    #expect(!request.isExpired(
      receivedAtUptimeNanoseconds: 1_000_000_000,
      nowUptimeNanoseconds: 1_999_999_999
    ))
    #expect(request.isExpired(
      receivedAtUptimeNanoseconds: 1_000_000_000,
      nowUptimeNanoseconds: 2_000_000_000
    ))
    #expect(request.isExpired(
      receivedAtUptimeNanoseconds: 1_000_000_000,
      nowUptimeNanoseconds: 2_000_000_001
    ))
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.Envelope(
        kind: .request, sessionID: UUID(), machineID: machineID,
        runtimeGeneration: 1, requestID: 0, capability: .health,
        timeoutMilliseconds: 1_000
      )
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.Envelope(
        kind: .request, sessionID: UUID(), machineID: machineID,
        runtimeGeneration: 1, requestID: 1, capability: .health,
        timeoutMilliseconds: 1_000,
        body: Data(count: DoryMacGuestIntegrationWire.maximumBodyBytes + 1)
      )
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
      _ = try DoryMacGuestIntegrationWire.Envelope(
        kind: .request, sessionID: UUID(), machineID: machineID,
        runtimeGeneration: 1, requestID: 1, capability: .health,
        timeoutMilliseconds: DoryMacGuestIntegrationWire.maximumRequestTimeoutMilliseconds + 1
      )
    }
  }

  @Test func openURLRequestRejectsLocalPathsCredentialsAndUnboundedInput() throws {
    let request = try DoryMacGuestIntegrationWire.OpenURLRequest(
      url: "https://example.org/docs?section=guest"
    )
    let canonical = try DoryMacGuestIntegrationWire.encodeOpenURLRequest(request)
    #expect(try DoryMacGuestIntegrationWire.decodeOpenURLRequest(canonical) == request)
    #expect(throws: DoryMacGuestIntegrationWire.WireError.nonCanonicalFrame) {
      _ = try DoryMacGuestIntegrationWire.decodeOpenURLRequest(
        canonical + Data(" ".utf8)
      )
    }
    for invalid in [
      "file:///etc/passwd", "javascript:alert(1)",
      "https://user:secret@example.org/", "https://example.org/\nnext",
      "https://example.org/" + String(repeating: "a", count: 2_048),
    ] {
      #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidEnvelope) {
        _ = try DoryMacGuestIntegrationWire.OpenURLRequest(url: invalid)
      }
    }
  }

  @Test func canonicalFrameRejectsUnknownFieldsAndWhitespace() throws {
    let challenge = try DoryMacGuestIntegrationWire.Envelope(
      kind: .challenge, sessionID: UUID(), machineID: machineID,
      runtimeGeneration: 1, challengeNonce: UUID()
    )
    let encoded = try DoryMacGuestIntegrationWire.encode(challenge)
    #expect(throws: DoryMacGuestIntegrationWire.WireError.nonCanonicalFrame) {
      _ = try DoryMacGuestIntegrationWire.decode(encoded + Data(" ".utf8))
    }
    let withUnknownField = String(decoding: encoded, as: UTF8.self)
      .replacingOccurrences(of: "{", with: "{\"unexpected\":1,", range: nil)
    #expect(throws: DoryMacGuestIntegrationWire.WireError.nonCanonicalFrame) {
      _ = try DoryMacGuestIntegrationWire.decode(Data(withUnknownField.utf8))
    }
  }

  @Test func framedSocketRoundTripUsesExactLength() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    defer { close(descriptors[0]); close(descriptors[1]) }
    let challenge = try DoryMacGuestIntegrationWire.Envelope(
      kind: .challenge, sessionID: UUID(), machineID: machineID,
      runtimeGeneration: 1, challengeNonce: UUID()
    )
    try DoryMacGuestIntegrationWire.writeFrame(challenge, to: descriptors[0])
    #expect(try DoryMacGuestIntegrationWire.readFrame(from: descriptors[1]) == challenge)
    var invalidLength = UInt32(DoryMacGuestIntegrationWire.maximumFrameBytes + 1).bigEndian
    try withUnsafeBytes(of: &invalidLength) { bytes in
      try #require(write(descriptors[0], bytes.baseAddress!, bytes.count) == bytes.count)
    }
    #expect(throws: DoryMacGuestIntegrationWire.WireError.invalidFrameLength(
      DoryMacGuestIntegrationWire.maximumFrameBytes + 1
    )) {
      _ = try DoryMacGuestIntegrationWire.readFrame(from: descriptors[1])
    }
  }

  @Test func oneDeadlineBoundsAnIncompleteFrame() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    defer { close(descriptors[0]); close(descriptors[1]) }
    var length = UInt32(32).bigEndian
    try withUnsafeBytes(of: &length) { bytes in
      try #require(write(descriptors[0], bytes.baseAddress!, bytes.count) == bytes.count)
    }
    let partialBody: [UInt8] = [0x78]
    try partialBody.withUnsafeBytes { bytes in
      try #require(write(descriptors[0], bytes.baseAddress!, bytes.count) == bytes.count)
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000
    #expect(throws: DoryMacGuestIntegrationWire.WireError.ioFailure(ETIMEDOUT)) {
      _ = try DoryMacGuestIntegrationWire.readFrame(
        from: descriptors[1], deadlineUptimeNanoseconds: deadline
      )
    }
  }
}
