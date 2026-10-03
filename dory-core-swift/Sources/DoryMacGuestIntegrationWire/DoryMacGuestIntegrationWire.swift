import Darwin
import Foundation

/// VM-local macOS Guest Tools protocol. The VZ socket listener binds the transport to one VM;
/// these fields additionally bind every message to the selected machine and runtime generation.
/// No capability represents arbitrary command execution or access to a host path.
public enum DoryMacGuestIntegrationWire {
  public static let schema = "dory.mac-guest-integration@2"
  public static let protocolVersion: UInt32 = 2
  public static let port: UInt32 = 1_032
  // A PNG is carried once as the envelope's Data body (JSON base64), not nested in another
  // JSON value. All non-image capabilities retain their original 32-KiB body bound.
  public static let maximumFrameBytes = 6 * 1_024 * 1_024
  public static let maximumBodyBytes = 32 * 1_024
  public static let maximumImageBytes = 4 * 1_024 * 1_024
  public static let maximumFileChunkBytes = 64 * 1_024
  public static let maximumFileBodyBytes = 128 * 1_024
  // Leave room for the receiver's UUID collision-avoidance prefix under NAME_MAX.
  public static let maximumFileNameBytes = 200
  public static let maximumFileBytes: UInt64 = 64 * 1_024 * 1_024 * 1_024
  public static let maximumCapabilities = 16
  public static let maximumRequestTimeoutMilliseconds: UInt32 = 10_000

  /// Process-local user-session lease, distinct from the VM's wire/runtime generation.
  /// Every activation notification replaces the nonce: work queued before a switch must
  /// not become authorized again when the same user later returns to the console.
  public struct UserSessionAuthority: Sendable {
    private var active = false
    private var generation = UUID()

    public init() {}
    public var lease: UUID? { active ? generation : nil }
    public mutating func transition(active: Bool) {
      generation = UUID()
      self.active = active
    }
    public func permits(_ lease: UUID) -> Bool { active && generation == lease }

    public static func ownsConsoleSession(consoleUID: UInt32?, effectiveUID: UInt32) -> Bool {
      guard let consoleUID, effectiveUID != 0 else { return false }
      return consoleUID == effectiveUID
    }
  }

  /// One action's original receive-time budget. Queuing on AppKit, decoding an image, or
  /// starting a waiter later must never renew permission to begin an irreversible action.
  /// The owner serializes mutation together with its completion state.
  public struct UserActionAdmission: Sendable {
    public enum State: Sendable, Equatable { case pending, begun, expired, revoked, completed }
    public private(set) var state: State = .pending
    public let receivedAtUptimeNanoseconds: UInt64
    public let deadlineUptimeNanoseconds: UInt64

    public init(request: Envelope, receivedAtUptimeNanoseconds: UInt64) throws {
      try request.validate()
      guard request.kind == .request, let timeout = request.timeoutMilliseconds else {
        throw WireError.invalidEnvelope
      }
      let deadline = receivedAtUptimeNanoseconds.addingReportingOverflow(UInt64(timeout) * 1_000_000)
      guard !deadline.overflow else { throw WireError.invalidEnvelope }
      self.receivedAtUptimeNanoseconds = receivedAtUptimeNanoseconds
      deadlineUptimeNanoseconds = deadline.partialValue
    }

    public mutating func begin(nowUptimeNanoseconds: UInt64) -> Bool {
      guard state == .pending else { return false }
      guard nowUptimeNanoseconds >= receivedAtUptimeNanoseconds,
        nowUptimeNanoseconds < deadlineUptimeNanoseconds else {
        state = .expired
        return false
      }
      state = .begun
      return true
    }

    /// The caller holds the user-session owner's lock while supplying its current authority.
    /// A previously observed active console cannot authorize work after a nonce transition.
    public mutating func begin(
      userSession: UserSessionAuthority, lease: UUID, nowUptimeNanoseconds: UInt64
    ) -> Bool {
      guard userSession.permits(lease) else { revoke(); return false }
      return begin(nowUptimeNanoseconds: nowUptimeNanoseconds)
    }

    /// File descriptors may be reused after reconnect. The caller holds the connection and
    /// console owner's lock through the mutation, and supplies the exact original connection.
    public mutating func begin(
      connectionID: UUID, currentConnectionID: UUID?,
      userSession: UserSessionAuthority, lease: UUID, nowUptimeNanoseconds: UInt64
    ) -> Bool {
      guard currentConnectionID == connectionID else { revoke(); return false }
      return begin(userSession: userSession, lease: lease,
        nowUptimeNanoseconds: nowUptimeNanoseconds)
    }

    @discardableResult public mutating func revoke() -> Bool {
      guard state == .pending else { return false }
      state = .revoked
      return true
    }

    public mutating func complete() {
      if state == .pending || state == .begun { state = .completed }
    }

    public mutating func expire() {
      if state == .pending || state == .begun { state = .expired }
    }
  }

  private static let pngCRCTable: [UInt32] = (0..<256).map { entry in
    var value = UInt32(entry)
    for _ in 0..<8 {
      value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xEDB8_8320)
    }
    return value
  }

  public enum Capability: String, Codable, Sendable, CaseIterable, Comparable, Hashable {
    case health
    case guestTime = "guest-time"
    case gracefulShutdown = "graceful-shutdown"
    case openURL = "open-url"
    case filePush = "file-push"
    case filePull = "file-pull"
    case clipboardTextRead = "clipboard-text-read"
    case clipboardTextWrite = "clipboard-text-write"
    case clipboardImageRead = "clipboard-image-read"
    case clipboardImageWrite = "clipboard-image-write"
    case displayNotification = "display-notification"

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// Only operations implemented by both current Guest Tools and the host service. Adding an
  /// enum case above does not advertise authority until both handlers and this list are updated.
  public static let implementedCapabilitiesV2: [Capability] = [
    .clipboardImageRead, .clipboardImageWrite, .clipboardTextRead,
    .clipboardTextWrite, .filePull, .filePush, .guestTime, .health, .openURL,
  ]

  /// One transfer occupies the VM-local request stream until committed. No host path crosses
  /// the boundary; the name is display-only and the receiver chooses its own destination.
  public struct FilePushRequest: Codable, Sendable, Equatable {
    public static let schema = "dory.mac-guest-file-push@1"
    public enum Phase: String, Codable, Sendable { case begin, chunk, commit, cancel }

    public let schema: String
    public let phase: Phase
    public let transferID: UUID
    public let name: String?
    public let byteCount: UInt64?
    public let offset: UInt64?
    public let chunk: Data?
    public let sha256: String?

    public init(
      phase: Phase, transferID: UUID, name: String? = nil, byteCount: UInt64? = nil,
      offset: UInt64? = nil, chunk: Data? = nil, sha256: String? = nil
    ) throws {
      schema = Self.schema
      self.phase = phase
      self.transferID = transferID
      self.name = name
      self.byteCount = byteCount
      self.offset = offset
      self.chunk = chunk
      self.sha256 = sha256
      try validate()
    }

    public func validate() throws {
      guard schema == Self.schema,
        transferID != UUID(uuidString: "00000000-0000-0000-0000-000000000000")
      else { throw WireError.invalidEnvelope }
      switch phase {
      case .begin:
        guard let name, let byteCount, byteCount <= maximumFileBytes,
          !name.isEmpty, name != ".", name != "..",
          name.utf8.count <= maximumFileNameBytes,
          !name.contains("/"), !name.contains("\\"),
          !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          offset == nil, chunk == nil, sha256 == nil
        else { throw WireError.invalidEnvelope }
      case .chunk:
        guard name == nil, byteCount == nil, sha256 == nil,
          let offset, offset <= maximumFileBytes,
          let chunk, !chunk.isEmpty, chunk.count <= maximumFileChunkBytes,
          UInt64(chunk.count) <= maximumFileBytes - offset
        else { throw WireError.invalidEnvelope }
      case .commit:
        guard name == nil, byteCount == nil, offset == nil, chunk == nil,
          let sha256, sha256.utf8.count == 64,
          sha256.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
          })
        else { throw WireError.invalidEnvelope }
      case .cancel:
        guard name == nil, byteCount == nil, offset == nil, chunk == nil, sha256 == nil
        else { throw WireError.invalidEnvelope }
      }
    }
  }

  public static func encodeFilePushRequest(_ request: FilePushRequest) throws -> Data {
    try request.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let body = try encoder.encode(request)
    guard body.count <= maximumFileBodyBytes else { throw WireError.invalidEnvelope }
    return body
  }

  public static func decodeFilePushRequest(_ body: Data) throws -> FilePushRequest {
    guard !body.isEmpty, body.count <= maximumFileBodyBytes else {
      throw WireError.invalidEnvelope
    }
    let request = try JSONDecoder().decode(FilePushRequest.self, from: body)
    guard try encodeFilePushRequest(request) == body else { throw WireError.nonCanonicalFrame }
    return request
  }

  /// The host can read only the single file explicitly offered in Guest Tools. Metadata and
  /// chunks are separate bounded requests so a save panel never holds an RPC open.
  public struct FilePullRequest: Codable, Sendable, Equatable {
    public static let schema = "dory.mac-guest-file-pull@1"
    public enum Phase: String, Codable, Sendable { case metadata, chunk, finish, cancel }

    public let schema: String
    public let phase: Phase
    public let offerID: UUID?
    public let offset: UInt64?

    public init(phase: Phase, offerID: UUID? = nil, offset: UInt64? = nil) throws {
      schema = Self.schema
      self.phase = phase
      self.offerID = offerID
      self.offset = offset
      try validate()
    }

    public func validate() throws {
      guard schema == Self.schema else { throw WireError.invalidEnvelope }
      switch phase {
      case .metadata:
        guard offerID == nil, offset == nil else { throw WireError.invalidEnvelope }
      case .chunk:
        guard let offerID, offerID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
          let offset, offset < maximumFileBytes
        else { throw WireError.invalidEnvelope }
      case .finish, .cancel:
        guard let offerID, offerID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
          offset == nil
        else { throw WireError.invalidEnvelope }
      }
    }
  }

  public struct FilePullOffer: Codable, Sendable, Equatable {
    public static let schema = "dory.mac-guest-file-offer@1"
    public let schema: String
    public let offerID: UUID
    public let name: String
    public let byteCount: UInt64

    public init(offerID: UUID, name: String, byteCount: UInt64) throws {
      schema = Self.schema
      self.offerID = offerID
      self.name = name
      self.byteCount = byteCount
      try validate()
    }

    public func validate() throws {
      guard schema == Self.schema,
        offerID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
        byteCount <= maximumFileBytes,
        !name.isEmpty, name != ".", name != "..",
        name.utf8.count <= maximumFileNameBytes,
        !name.contains("/"), !name.contains("\\"),
        !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else { throw WireError.invalidEnvelope }
    }
  }

  /// Process-local ownership of an explicitly selected file, not an additional wire grant.
  /// A request from a retired connection/console or for a replaced offer cannot consume it.
  public struct FileOfferAuthority: Sendable {
    public let offerID: UUID
    public let connectionID: UUID
    public let userSessionLease: UUID

    public init(offerID: UUID, connectionID: UUID, userSessionLease: UUID) {
      self.offerID = offerID
      self.connectionID = connectionID
      self.userSessionLease = userSessionLease
    }

    public func permits(
      _ request: FilePullRequest, connectionID: UUID, userSessionLease: UUID
    ) -> Bool {
      guard self.connectionID == connectionID, self.userSessionLease == userSessionLease,
        (try? request.validate()) != nil else { return false }
      return request.phase == .metadata || request.offerID == offerID
    }
  }

  public struct FilePullDigest: Codable, Sendable, Equatable {
    public static let schema = "dory.mac-guest-file-digest@1"
    public let schema: String
    public let sha256: String

    public init(sha256: String) throws {
      schema = Self.schema
      self.sha256 = sha256
      try validate()
    }

    public func validate() throws {
      guard schema == Self.schema, sha256.utf8.count == 64,
        sha256.unicodeScalars.allSatisfy({
          CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        })
      else { throw WireError.invalidEnvelope }
    }
  }

  public static func encodeFilePullBody<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard !data.isEmpty, data.count <= maximumBodyBytes else { throw WireError.invalidEnvelope }
    return data
  }

  public static func decodeFilePullBody<T: Decodable & Encodable>(
    _ body: Data, as type: T.Type
  ) throws -> T {
    guard !body.isEmpty, body.count <= maximumBodyBytes else {
      throw WireError.invalidEnvelope
    }
    let value = try JSONDecoder().decode(type, from: body)
    guard try encodeFilePullBody(value) == body else { throw WireError.nonCanonicalFrame }
    return value
  }

  public enum Kind: String, Codable, Sendable, Hashable {
    case challenge, hello, open, request, response, revoke, close
  }

  public enum ResponseStatus: String, Codable, Sendable, Hashable {
    case success, denied, unsupported, expired, revoked, invalidRequest = "invalid-request"
  }

  public enum WireError: Error, Sendable, Equatable {
    case invalidEnvelope
    case invalidFrameLength(Int)
    case nonCanonicalFrame
    case connectionClosed
    case ioFailure(Int32)
  }

  public struct Hello: Codable, Sendable, Equatable {
    public let protocolVersion: UInt32
    public let bundleIdentifier: String
    public let toolsVersion: String
    public let toolsBuild: String
    public let offeredCapabilities: [Capability]

    public init(
      bundleIdentifier: String,
      toolsVersion: String,
      toolsBuild: String,
      offeredCapabilities: [Capability]
    ) throws {
      self.protocolVersion = DoryMacGuestIntegrationWire.protocolVersion
      self.bundleIdentifier = bundleIdentifier
      self.toolsVersion = toolsVersion
      self.toolsBuild = toolsBuild
      self.offeredCapabilities = offeredCapabilities
      try validate()
    }

    public func validate() throws {
      guard protocolVersion == DoryMacGuestIntegrationWire.protocolVersion,
        bundleIdentifier == "com.pythonxi.Dory.GuestTools",
        Self.isVersion(toolsVersion), Self.isVersion(toolsBuild),
        !offeredCapabilities.isEmpty,
        offeredCapabilities.count <= DoryMacGuestIntegrationWire.maximumCapabilities,
        offeredCapabilities == offeredCapabilities.sorted(),
        Set(offeredCapabilities).count == offeredCapabilities.count,
        offeredCapabilities.contains(.health)
      else { throw WireError.invalidEnvelope }
    }

    private static func isVersion(_ value: String) -> Bool {
      !value.isEmpty && value.utf8.count <= 64 && value.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
          .contains($0)
      }
    }
  }

  public struct HealthReport: Codable, Sendable, Equatable {
    public static let schema = "dory.mac-guest-health@1"
    public let schema: String
    public let bundleIdentifier: String
    public let toolsVersion: String
    public let toolsBuild: String
    public let guestOSVersion: String
    public let observedAtUnixMilliseconds: UInt64

    public init(
      bundleIdentifier: String,
      toolsVersion: String,
      toolsBuild: String,
      guestOSVersion: String,
      observedAtUnixMilliseconds: UInt64
    ) throws {
      schema = Self.schema
      self.bundleIdentifier = bundleIdentifier
      self.toolsVersion = toolsVersion
      self.toolsBuild = toolsBuild
      self.guestOSVersion = guestOSVersion
      self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
      try validate()
    }

    public func validate() throws {
      guard schema == Self.schema,
        bundleIdentifier == "com.pythonxi.Dory.GuestTools",
        !toolsVersion.isEmpty, toolsVersion.utf8.count <= 64,
        !toolsBuild.isEmpty, toolsBuild.utf8.count <= 64,
        !guestOSVersion.isEmpty, guestOSVersion.utf8.count <= 128,
        !guestOSVersion.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        observedAtUnixMilliseconds > 0
      else { throw WireError.invalidEnvelope }
    }
  }

  /// A user-session action, never a host path or a shell command. The host must explicitly
  /// initiate it for the selected VM; merely connecting Guest Tools grants no action.
  public struct OpenURLRequest: Codable, Sendable, Equatable {
    public static let schema = "dory.mac-guest-open-url@1"
    public let schema: String
    public let url: String

    public init(url: String) throws {
      schema = Self.schema
      self.url = url
      try validate()
    }

    public func validate() throws {
      guard schema == Self.schema, !url.isEmpty, url.utf8.count <= 2_048,
        !url.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        let components = URLComponents(string: url),
        components.scheme == "https" || components.scheme == "http",
        let host = components.host, !host.isEmpty,
        components.user == nil, components.password == nil,
        components.url?.absoluteString == url
      else { throw WireError.invalidEnvelope }
    }
  }

  public static func encodeOpenURLRequest(_ request: OpenURLRequest) throws -> Data {
    try request.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(request)
    guard data.count <= maximumBodyBytes else { throw WireError.invalidEnvelope }
    return data
  }

  public static func decodeOpenURLRequest(_ data: Data) throws -> OpenURLRequest {
    guard !data.isEmpty, data.count <= maximumBodyBytes else {
      throw WireError.invalidEnvelope
    }
    let request = try JSONDecoder().decode(OpenURLRequest.self, from: data)
    guard try encodeOpenURLRequest(request) == data else { throw WireError.nonCanonicalFrame }
    return request
  }

  /// One explicit user-session pasteboard read. No host path, file promise, or image data may
  /// ride in this response; larger clipboard classes need separately granted capabilities.
  public struct ClipboardTextResponse: Codable, Sendable, Equatable {
    public static let schema = "dory.mac-guest-clipboard-text@1"
    public static let maximumTextBytes = 16 * 1_024
    public let schema: String
    public let text: String

    public init(text: String) throws {
      schema = Self.schema
      self.text = text
      try validate()
    }

    public func validate() throws {
      guard schema == Self.schema,
        !text.isEmpty, text.utf8.count <= Self.maximumTextBytes,
        !text.unicodeScalars.contains(where: { $0.value == 0 })
      else { throw WireError.invalidEnvelope }
    }
  }

  public static func encodeClipboardTextResponse(_ response: ClipboardTextResponse) throws -> Data {
    try response.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(response)
    guard data.count <= maximumBodyBytes else { throw WireError.invalidEnvelope }
    return data
  }

  public static func decodeClipboardTextResponse(_ data: Data) throws -> ClipboardTextResponse {
    guard !data.isEmpty, data.count <= maximumBodyBytes else {
      throw WireError.invalidEnvelope
    }
    let response = try JSONDecoder().decode(ClipboardTextResponse.self, from: data)
    guard try encodeClipboardTextResponse(response) == data else {
      throw WireError.nonCanonicalFrame
    }
    return response
  }

  /// An explicitly host-initiated paste into the selected guest user session. It cannot carry
  /// file promises or host paths, and is never granted by a guest hello alone.
  public struct ClipboardTextWriteRequest: Codable, Sendable, Equatable {
    public static let schema = "dory.mac-guest-clipboard-text-write@1"
    public let schema: String
    public let text: String

    public init(text: String) throws {
      schema = Self.schema
      self.text = text
      try validate()
    }

    public func validate() throws {
      guard schema == Self.schema,
        !text.isEmpty, text.utf8.count <= ClipboardTextResponse.maximumTextBytes,
        !text.unicodeScalars.contains(where: { $0.value == 0 })
      else { throw WireError.invalidEnvelope }
    }
  }

  public static func encodeClipboardTextWriteRequest(_ request: ClipboardTextWriteRequest) throws -> Data {
    try request.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(request)
    guard data.count <= maximumBodyBytes else { throw WireError.invalidEnvelope }
    return data
  }

  public static func decodeClipboardTextWriteRequest(_ data: Data) throws -> ClipboardTextWriteRequest {
    guard !data.isEmpty, data.count <= maximumBodyBytes else {
      throw WireError.invalidEnvelope
    }
    let request = try JSONDecoder().decode(ClipboardTextWriteRequest.self, from: data)
    guard try encodeClipboardTextWriteRequest(request) == data else {
      throw WireError.nonCanonicalFrame
    }
    return request
  }

  /// The image capabilities carry only one bounded PNG, never a pasteboard archive, file
  /// promise, URL, or arbitrary UTI. A decoder at the user-session boundary must additionally
  /// prove the compressed image can be rendered before placing it on a pasteboard.
  public static func validateClipboardPNG(_ data: Data) throws {
    guard !data.isEmpty, data.count <= maximumImageBytes else {
      throw WireError.invalidEnvelope
    }
    let bytes = [UInt8](data)
    guard bytes.count >= 45,
      Array(bytes[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10]
    else { throw WireError.invalidEnvelope }
    func word(at offset: Int) -> UInt32 {
      (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
    func crc(_ range: Range<Int>) -> UInt32 {
      var value: UInt32 = .max
      for index in range {
        value = (value >> 8)
          ^ pngCRCTable[Int((value ^ UInt32(bytes[index])) & 0xFF)]
      }
      return value ^ .max
    }
    var offset = 8
    var chunkCount = 0
    var sawImageData = false
    var endedImageData = false
    var sawEnd = false
    while offset <= bytes.count - 12 {
      chunkCount += 1
      guard chunkCount <= 4_096 else { throw WireError.invalidEnvelope }
      let length = UInt64(word(at: offset))
      guard length <= UInt64(bytes.count - offset - 12) else {
        throw WireError.invalidEnvelope
      }
      let bodyCount = Int(length)
      let type = Array(bytes[(offset + 4)..<(offset + 8)])
      let dataStart = offset + 8
      let next = offset + 12 + bodyCount
      guard crc((offset + 4)..<(dataStart + bodyCount)) == word(at: next - 4)
      else { throw WireError.invalidEnvelope }
      if offset == 8 {
        guard type == [73, 72, 68, 82], bodyCount == 13 else {
          throw WireError.invalidEnvelope
        }
        let width = word(at: dataStart)
        let height = word(at: dataStart + 4)
        guard (1...8_192).contains(width), (1...8_192).contains(height),
          UInt64(width) * UInt64(height) <= 16_777_216
        else { throw WireError.invalidEnvelope }
      } else if type == [73, 72, 68, 82] {
        throw WireError.invalidEnvelope
      } else if type == [73, 68, 65, 84] {
        guard bodyCount > 0, !endedImageData, !sawEnd else {
          throw WireError.invalidEnvelope
        }
        sawImageData = true
      } else if type == [73, 69, 78, 68] {
        guard bodyCount == 0, sawImageData, next == bytes.count else {
          throw WireError.invalidEnvelope
        }
        sawEnd = true
      } else {
        guard !sawEnd else { throw WireError.invalidEnvelope }
        if sawImageData { endedImageData = true }
      }
      offset = next
    }
    guard sawEnd else { throw WireError.invalidEnvelope }
  }

  public struct Envelope: Codable, Sendable, Equatable {
    public let schema: String
    public let kind: Kind
    public let sessionID: UUID
    public let machineID: String
    public let runtimeGeneration: UInt64
    public let challengeNonce: UUID?
    public let hello: Hello?
    public let grantedCapabilities: [Capability]?
    public let requestID: UInt64?
    public let capability: Capability?
    /// Relative budget; each endpoint measures it with its own monotonic clock. Guest and host
    /// wall clocks are deliberately not assumed to agree during boot or clock repair.
    public let timeoutMilliseconds: UInt32?
    public let status: ResponseStatus?
    public let body: Data?

    public init(
      kind: Kind,
      sessionID: UUID,
      machineID: String,
      runtimeGeneration: UInt64,
      challengeNonce: UUID? = nil,
      hello: Hello? = nil,
      grantedCapabilities: [Capability]? = nil,
      requestID: UInt64? = nil,
      capability: Capability? = nil,
      timeoutMilliseconds: UInt32? = nil,
      status: ResponseStatus? = nil,
      body: Data? = nil
    ) throws {
      schema = DoryMacGuestIntegrationWire.schema
      self.kind = kind
      self.sessionID = sessionID
      self.machineID = machineID
      self.runtimeGeneration = runtimeGeneration
      self.challengeNonce = challengeNonce
      self.hello = hello
      self.grantedCapabilities = grantedCapabilities
      self.requestID = requestID
      self.capability = capability
      self.timeoutMilliseconds = timeoutMilliseconds
      self.status = status
      self.body = body
      try validate()
    }

    public func validate() throws {
      guard schema == DoryMacGuestIntegrationWire.schema,
        sessionID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
        machineID.utf8.count == 64,
        machineID.unicodeScalars.allSatisfy({
          CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }),
        runtimeGeneration > 0,
        body.map({ payload in
          let imageBody = capability == .clipboardImageRead
            || capability == .clipboardImageWrite
          return payload.count <= (imageBody
            ? DoryMacGuestIntegrationWire.maximumImageBytes
            : capability == .filePush && kind == .request
              ? DoryMacGuestIntegrationWire.maximumFileBodyBytes
              : capability == .filePull && kind == .response
                ? DoryMacGuestIntegrationWire.maximumFileChunkBytes
              : DoryMacGuestIntegrationWire.maximumBodyBytes)
        }) ?? true
      else { throw WireError.invalidEnvelope }
      if let body, capability == .clipboardImageRead || capability == .clipboardImageWrite {
        try DoryMacGuestIntegrationWire.validateClipboardPNG(body)
      }
      try hello?.validate()
      switch kind {
      case .challenge:
        guard challengeNonce != nil, hello == nil, grantedCapabilities == nil,
          requestID == nil, capability == nil, timeoutMilliseconds == nil,
          status == nil, body == nil else { throw WireError.invalidEnvelope }
      case .hello:
        guard challengeNonce != nil, hello != nil, grantedCapabilities == nil,
          requestID == nil, capability == nil, timeoutMilliseconds == nil,
          status == nil, body == nil else { throw WireError.invalidEnvelope }
      case .open:
        guard challengeNonce == nil, hello == nil,
          let grantedCapabilities, !grantedCapabilities.isEmpty,
          grantedCapabilities.count <= DoryMacGuestIntegrationWire.maximumCapabilities,
          grantedCapabilities == grantedCapabilities.sorted(),
          Set(grantedCapabilities).count == grantedCapabilities.count,
          grantedCapabilities.contains(.health),
          requestID == nil, capability == nil, timeoutMilliseconds == nil,
          status == nil, body == nil else { throw WireError.invalidEnvelope }
      case .request:
        guard challengeNonce == nil, hello == nil, grantedCapabilities == nil,
          let requestID, requestID > 0, capability != nil,
          let timeoutMilliseconds, timeoutMilliseconds > 0,
          timeoutMilliseconds <= DoryMacGuestIntegrationWire.maximumRequestTimeoutMilliseconds,
          status == nil else { throw WireError.invalidEnvelope }
      case .response:
        guard challengeNonce == nil, hello == nil, grantedCapabilities == nil,
          let requestID, requestID > 0, capability != nil,
          timeoutMilliseconds == nil, status != nil else {
          throw WireError.invalidEnvelope
        }
      case .revoke, .close:
        guard challengeNonce == nil, hello == nil, grantedCapabilities == nil,
          requestID == nil, capability == nil, timeoutMilliseconds == nil,
          status == nil, body == nil else { throw WireError.invalidEnvelope }
      }
    }

    public func isExpired(
      receivedAtUptimeNanoseconds: UInt64,
      nowUptimeNanoseconds: UInt64
    ) -> Bool {
      guard let timeoutMilliseconds else { return false }
      guard nowUptimeNanoseconds >= receivedAtUptimeNanoseconds else { return true }
      return nowUptimeNanoseconds - receivedAtUptimeNanoseconds
        >= UInt64(timeoutMilliseconds) * 1_000_000
    }
  }

  public static func encode(_ envelope: Envelope) throws -> Data {
    try envelope.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(envelope)
    guard !data.isEmpty, data.count <= maximumFrameBytes else {
      throw WireError.invalidFrameLength(data.count)
    }
    return data
  }

  public static func decode(_ data: Data) throws -> Envelope {
    guard !data.isEmpty, data.count <= maximumFrameBytes else {
      throw WireError.invalidFrameLength(data.count)
    }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    try envelope.validate()
    guard try encode(envelope) == data else { throw WireError.nonCanonicalFrame }
    return envelope
  }

  /// One monotonic deadline covers the whole header and body, including a slow peer that makes
  /// byte-by-byte progress. The descriptor remains caller-owned and is never reconfigured here.
  public static func readFrame(
    from descriptor: Int32,
    deadlineUptimeNanoseconds: UInt64? = nil
  ) throws -> Envelope {
    let deadline = deadlineUptimeNanoseconds ?? defaultDeadline()
    let header = try readExactly(4, from: descriptor, deadline: deadline)
    let count = header.withUnsafeBytes {
      Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
    }
    guard count > 0, count <= maximumFrameBytes else {
      throw WireError.invalidFrameLength(count)
    }
    return try decode(readExactly(count, from: descriptor, deadline: deadline))
  }

  public static func writeFrame(
    _ envelope: Envelope,
    to descriptor: Int32,
    deadlineUptimeNanoseconds: UInt64? = nil
  ) throws {
    let deadline = deadlineUptimeNanoseconds ?? defaultDeadline()
    let data = try encode(envelope)
    var header = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &header) { try writeAll($0, to: descriptor, deadline: deadline) }
    try data.withUnsafeBytes { try writeAll($0, to: descriptor, deadline: deadline) }
  }

  private static func readExactly(
    _ count: Int, from descriptor: Int32, deadline: UInt64
  ) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < count {
        try waitReady(descriptor, events: Int16(POLLIN), deadline: deadline)
        let received = Darwin.recv(
          descriptor, bytes.baseAddress!.advanced(by: offset), count - offset,
          MSG_DONTWAIT
        )
        if received < 0 {
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK { continue }
          throw WireError.ioFailure(errno)
        }
        guard received > 0 else { throw WireError.connectionClosed }
        offset += received
      }
    }
    return data
  }

  private static func writeAll(
    _ bytes: UnsafeRawBufferPointer,
    to descriptor: Int32,
    deadline: UInt64
  ) throws {
    var offset = 0
    while offset < bytes.count {
      try waitReady(descriptor, events: Int16(POLLOUT), deadline: deadline)
      let written = Darwin.send(
        descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset,
        MSG_DONTWAIT | MSG_NOSIGNAL
      )
      if written < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { continue }
        throw WireError.ioFailure(errno)
      }
      guard written > 0 else { throw WireError.connectionClosed }
      offset += written
    }
  }

  private static func defaultDeadline() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
  }

  private static func waitReady(
    _ descriptor: Int32, events: Int16, deadline: UInt64
  ) throws {
    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { throw WireError.ioFailure(ETIMEDOUT) }
      let remainingMilliseconds = min(
        UInt64(Int32.max), (deadline - now) / 1_000_000 + 1
      )
      var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
      let result = Darwin.poll(&descriptorState, 1, Int32(remainingMilliseconds))
      if result < 0 {
        if errno == EINTR { continue }
        throw WireError.ioFailure(errno)
      }
      guard result > 0 else { throw WireError.ioFailure(ETIMEDOUT) }
      if descriptorState.revents & Int16(POLLNVAL | POLLERR) != 0 {
        throw WireError.ioFailure(EIO)
      }
      return
    }
  }
}
