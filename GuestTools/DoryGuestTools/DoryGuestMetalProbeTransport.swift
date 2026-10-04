import Darwin
import Foundation

/// Guest half of the one-shot qualification channel. The host endpoint is reachable only through
/// this VM's VZVirtioSocketDevice; no IP network or shared folder participates in collection.
enum DoryGuestMetalProbeTransport {
  static let port: UInt32 = 1_031
  static let challengeSchema = "dory.macos-guest-metal-probe-challenge@2"
  static let maximumJSONBytes = 64 * 1_024

  struct Challenge: Codable {
    let schema: String
    let issuedAt: String
    let candidateID: String
    let machineID: String
    let operationID: String
    let nonce: String
    let guestToolsManifestSHA256: String
    let guestToolsBundleIdentifier: String
    let guestToolsVersion: String
    let guestToolsBuild: String
  }

  static func collect() throws -> String {
    let descriptor = try connectToHost()
    defer {
      _ = shutdown(descriptor, SHUT_RDWR)
      close(descriptor)
    }
    let challengeData = try readFrame(from: descriptor)
    let challenge = try JSONDecoder().decode(Challenge.self, from: challengeData)
    try validate(challenge)
    let result = try DoryGuestMetalProbe.run(
      nonce: challenge.nonce,
      candidateID: challenge.candidateID,
      machineID: challenge.machineID,
      operationID: challenge.operationID
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let resultData = try encoder.encode(result)
    try writeFrame(resultData, to: descriptor)
    return String(decoding: resultData, as: UTF8.self)
  }

  private static func validate(_ challenge: Challenge) throws {
    let bundle = Bundle.main
    guard challenge.schema == challengeSchema,
      isISO8601Timestamp(challenge.issuedAt),
      challenge.guestToolsBundleIdentifier == bundle.bundleIdentifier,
      challenge.guestToolsVersion
        == (bundle.object(
          forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String),
      challenge.guestToolsBuild
        == (bundle.object(
          forInfoDictionaryKey: "CFBundleVersion"
        ) as? String),
      challenge.guestToolsManifestSHA256.utf8.count == 64,
      challenge.guestToolsManifestSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else {
      throw TransportError.invalidChallenge
    }
  }

  static func isISO8601Timestamp(_ value: String) -> Bool {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) != nil
      || ISO8601DateFormatter().date(from: value) != nil
  }

  private static func connectToHost() throws -> Int32 {
    let descriptor = socket(AF_VSOCK, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw TransportError.socketFailed(errno) }
    var noSignal: Int32 = 1
    _ = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSignal,
      socklen_t(MemoryLayout<Int32>.size)
    )
    var address = sockaddr_vm()
    address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
    address.svm_family = sa_family_t(AF_VSOCK)
    address.svm_port = port
    address.svm_cid = UInt32(VMADDR_CID_HOST)
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
      }
    }
    guard status == 0 else {
      let code = errno
      close(descriptor)
      throw TransportError.connectFailed(code)
    }
    var timeout = timeval(tv_sec: 120, tv_usec: 0)
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
      guard
        setsockopt(
          descriptor,
          SOL_SOCKET,
          option,
          &timeout,
          socklen_t(MemoryLayout<timeval>.size)
        ) == 0
      else {
        let code = errno
        close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
      }
    }
    return descriptor
  }

  private static func readFrame(from descriptor: Int32) throws -> Data {
    let header = try readExactly(4, from: descriptor)
    let count = header.withUnsafeBytes {
      Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
    }
    guard count > 0, count <= maximumJSONBytes else {
      throw TransportError.invalidFrameLength(count)
    }
    return try readExactly(count, from: descriptor)
  }

  private static func writeFrame(_ data: Data, to descriptor: Int32) throws {
    guard !data.isEmpty, data.count <= maximumJSONBytes else {
      throw TransportError.invalidFrameLength(data.count)
    }
    var count = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &count) { try writeAll($0, to: descriptor) }
    try data.withUnsafeBytes { try writeAll($0, to: descriptor) }
  }

  private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < count {
        let result = read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
        if result < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard result > 0 else { throw TransportError.connectionClosed }
        offset += result
      }
    }
    return data
  }

  private static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
    var offset = 0
    while offset < bytes.count {
      let result = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      if result < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard result > 0 else { throw TransportError.connectionClosed }
      offset += result
    }
  }

  enum TransportError: LocalizedError {
    case socketFailed(Int32)
    case connectFailed(Int32)
    case invalidChallenge
    case invalidFrameLength(Int)
    case connectionClosed

    var errorDescription: String? {
      switch self {
      case .socketFailed(let code):
        "Could not create the Dory host channel (errno \(code))."
      case .connectFailed(let code):
        "No matching host qualification run is waiting (errno \(code))."
      case .invalidChallenge:
        "The host qualification challenge does not match this Guest Tools build."
      case .invalidFrameLength(let count):
        "The host qualification message has an invalid length (\(count) bytes)."
      case .connectionClosed:
        "The Dory host channel closed before collection completed."
      }
    }
  }
}
