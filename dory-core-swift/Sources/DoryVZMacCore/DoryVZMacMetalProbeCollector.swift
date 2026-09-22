import Darwin
import CryptoKit
import Foundation
import Virtualization

/// Machine-local transport used only by the retained macOS Metal qualification workflow.
/// The host creates one listener on the selected VM's socket device, sends one fresh challenge,
/// and consumes at most one result. The VZ socket endpoint supplies the machine binding; the
/// challenge nonce supplies run binding and is never accepted twice by this collector instance.
public enum DoryVZMacMetalProbeTransport {
    public static let port: UInt32 = 1_031
    public static let challengeSchema = "dory.macos-guest-metal-probe-challenge@1"
    public static let resultSchema = "dory.guest-tools.metal-probe@1"
    public static let receiptSchema = "dory.macos-guest-metal-probe-transport@1"
    public static let maximumJSONBytes = 64 * 1_024
}

public struct DoryVZMacMetalProbeChallenge: Codable, Sendable, Equatable {
    public let schema: String
    public let issuedAt: String
    public let candidateID: String
    public let machineID: String
    public let nonce: String
    public let guestToolsManifestSHA256: String
    public let guestToolsBundleIdentifier: String
    public let guestToolsVersion: String
    public let guestToolsBuild: String

    public init(
        schema: String = DoryVZMacMetalProbeTransport.challengeSchema,
        issuedAt: String,
        candidateID: String,
        machineID: String,
        nonce: String,
        guestToolsManifestSHA256: String,
        guestToolsBundleIdentifier: String,
        guestToolsVersion: String,
        guestToolsBuild: String
    ) throws {
        guard schema == DoryVZMacMetalProbeTransport.challengeSchema,
              Self.isIdentifier(candidateID), Self.isIdentifier(machineID), Self.isIdentifier(nonce),
              Self.isSHA256(guestToolsManifestSHA256),
              guestToolsBundleIdentifier == "com.pythonxi.Dory.GuestTools",
              Self.isIdentifier(guestToolsVersion), Self.isIdentifier(guestToolsBuild),
              ISO8601DateFormatter().date(from: issuedAt) != nil else {
            throw DoryVZMacMetalProbeTransportError.invalidChallenge
        }
        self.schema = schema
        self.issuedAt = issuedAt
        self.candidateID = candidateID
        self.machineID = machineID
        self.nonce = nonce
        self.guestToolsManifestSHA256 = guestToolsManifestSHA256
        self.guestToolsBundleIdentifier = guestToolsBundleIdentifier
        self.guestToolsVersion = guestToolsVersion
        self.guestToolsBuild = guestToolsBuild
    }

    public func validate() throws {
        _ = try Self(
            schema: schema,
            issuedAt: issuedAt,
            candidateID: candidateID,
            machineID: machineID,
            nonce: nonce,
            guestToolsManifestSHA256: guestToolsManifestSHA256,
            guestToolsBundleIdentifier: guestToolsBundleIdentifier,
            guestToolsVersion: guestToolsVersion,
            guestToolsBuild: guestToolsBuild
        )
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
                .contains($0)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}

public struct DoryVZMacMetalProbeTransportReceipt: Codable, Sendable, Equatable {
    public let schema: String
    public let collectedAt: String
    public let collection: String
    public let candidateID: String
    public let machineID: String
    public let nonce: String
    public let resultSHA256: String
    public let resultByteCount: Int
}

public enum DoryVZMacMetalProbeTransportError: Error, Sendable, CustomStringConvertible {
    case alreadyInstalled
    case invalidChallenge
    case invalidFrameLength(Int)
    case connectionClosed
    case invalidResult(String)
    case socketDuplicationFailed(Int32)

    public var description: String {
        switch self {
        case .alreadyInstalled: "the macOS Metal probe collector is already installed"
        case .invalidChallenge: "the macOS Metal probe challenge is invalid"
        case .invalidFrameLength(let count): "the macOS Metal probe frame length is invalid: \(count)"
        case .connectionClosed: "the macOS Metal probe connection closed before its frame completed"
        case .invalidResult(let detail): "the macOS Metal probe result is invalid: \(detail)"
        case .socketDuplicationFailed(let code):
            "the macOS Metal probe connection could not be duplicated (errno \(code))"
        }
    }
}

public final class DoryVZMacMetalProbeCollector: NSObject,
    VZVirtioSocketListenerDelegate, @unchecked Sendable
{
    private let challenge: DoryVZMacMetalProbeChallenge
    private let resultURL: URL
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var socketDevice: VZVirtioSocketDevice?
    private var listener: VZVirtioSocketListener?
    private var consumed = false

    public init(
        challenge: DoryVZMacMetalProbeChallenge,
        resultURL: URL,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        try challenge.validate()
        self.challenge = challenge
        self.resultURL = resultURL
        self.log = log
    }

    public func install(on socketDevice: VZVirtioSocketDevice) throws {
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            throw DoryVZMacMetalProbeTransportError.alreadyInstalled
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        self.listener = listener
        self.socketDevice = socketDevice
        lock.unlock()
        socketDevice.setSocketListener(listener, forPort: DoryVZMacMetalProbeTransport.port)
        log("Dory VZMac Metal probe: waiting for one guest result on port \(DoryVZMacMetalProbeTransport.port)")
    }

    public func remove() {
        lock.lock()
        let device = socketDevice
        socketDevice = nil
        listener = nil
        lock.unlock()
        device?.removeSocketListener(forPort: DoryVZMacMetalProbeTransport.port)
    }

    public func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        lock.lock()
        guard self.listener === listener, self.socketDevice === socketDevice, !consumed else {
            lock.unlock()
            return false
        }
        consumed = true
        lock.unlock()

        let box = ConnectionBox(connection)
        DispatchQueue.global(qos: .userInitiated).async { [self, box] in
            defer { box.connection.close() }
            do {
                let session = try DoryVZMacMetalProbeSession(connection: box.connection)
                let receipt = try session.collect(
                    challenge: challenge,
                    resultURL: resultURL
                )
                log("Dory VZMac Metal probe: retained guest result \(receipt.resultSHA256)")
            } catch {
                log("Dory VZMac Metal probe: collection failed: \(error)")
            }
        }
        return true
    }

    deinit { remove() }

    private final class ConnectionBox: @unchecked Sendable {
        let connection: VZVirtioSocketConnection
        init(_ connection: VZVirtioSocketConnection) { self.connection = connection }
    }
}

struct DoryVZMacMetalProbeSession: Sendable {
    let descriptor: Int32

    init(connection: VZVirtioSocketConnection) throws {
        let descriptor = dup(connection.fileDescriptor)
        guard descriptor >= 0 else {
            throw DoryVZMacMetalProbeTransportError.socketDuplicationFailed(errno)
        }
        self.descriptor = descriptor
    }

    init(ownedDescriptor: Int32) { descriptor = ownedDescriptor }

    func collect(
        challenge: DoryVZMacMetalProbeChallenge,
        resultURL: URL
    ) throws -> DoryVZMacMetalProbeTransportReceipt {
        defer {
            _ = shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
        try Self.configureTimeouts(descriptor)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Self.writeFrame(try encoder.encode(challenge), to: descriptor)
        let result = try Self.readFrame(from: descriptor)
        try Self.validateResult(result, challenge: challenge)
        try Self.publishWithoutReplacing(result, to: resultURL)

        let receipt = DoryVZMacMetalProbeTransportReceipt(
            schema: DoryVZMacMetalProbeTransport.receiptSchema,
            collectedAt: ISO8601DateFormatter().string(from: Date()),
            collection: "vz-virtio-socket",
            candidateID: challenge.candidateID,
            machineID: challenge.machineID,
            nonce: challenge.nonce,
            resultSHA256: Self.sha256(result),
            resultByteCount: result.count
        )
        try Self.publishWithoutReplacing(
            encoder.encode(receipt),
            to: resultURL.appendingPathExtension("transport.json")
        )
        return receipt
    }

    private static func validateResult(
        _ data: Data,
        challenge: DoryVZMacMetalProbeChallenge
    ) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DoryVZMacMetalProbeTransportError.invalidResult("payload is not a JSON object")
        }
        func string(_ key: String) throws -> String {
            guard let value = object[key] as? String else {
                throw DoryVZMacMetalProbeTransportError.invalidResult("missing \(key)")
            }
            return value
        }
        guard try string("schema") == DoryVZMacMetalProbeTransport.resultSchema,
              try string("candidateID") == challenge.candidateID,
              try string("machineID") == challenge.machineID,
              try string("nonce") == challenge.nonce,
              try string("guestToolsBundleIdentifier") == challenge.guestToolsBundleIdentifier,
              try string("guestToolsVersion") == challenge.guestToolsVersion,
              try string("guestToolsBuild") == challenge.guestToolsBuild,
              try string("computeCommandBufferStatus") == "completed",
              try string("renderCommandBufferStatus") == "completed",
              object["computeValueCount"] as? Int == 1_024,
              object["renderedWidth"] as? Int == 64,
              object["renderedHeight"] as? Int == 64 else {
            throw DoryVZMacMetalProbeTransportError.invalidResult(
                "identity, bundle, workload, or completion status does not match the challenge"
            )
        }
    }

    static func readFrame(from descriptor: Int32) throws -> Data {
        let header = try readExactly(4, from: descriptor)
        let count = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard count > 0, count <= DoryVZMacMetalProbeTransport.maximumJSONBytes else {
            throw DoryVZMacMetalProbeTransportError.invalidFrameLength(count)
        }
        return try readExactly(count, from: descriptor)
    }

    static func writeFrame(_ data: Data, to descriptor: Int32) throws {
        guard !data.isEmpty, data.count <= DoryVZMacMetalProbeTransport.maximumJSONBytes else {
            throw DoryVZMacMetalProbeTransportError.invalidFrameLength(data.count)
        }
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll($0, to: descriptor) }
        try data.withUnsafeBytes { try writeAll($0, to: descriptor) }
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let result = read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard result > 0 else {
                    throw DoryVZMacMetalProbeTransportError.connectionClosed
                }
                offset += result
            }
        }
        return data
    }

    private static func writeAll(_ buffer: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var offset = 0
        while offset < buffer.count {
            let result = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard result > 0 else { throw DoryVZMacMetalProbeTransportError.connectionClosed }
            offset += result
        }
    }

    private static func configureTimeouts(_ descriptor: Int32) throws {
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                option,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func publishWithoutReplacing(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard link(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
