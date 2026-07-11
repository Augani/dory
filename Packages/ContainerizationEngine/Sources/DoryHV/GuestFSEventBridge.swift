import Foundation

public struct GuestFSEventBatchResult: Equatable, Sendable {
    public let pathCount: UInt32
    public let failedIndices: [UInt32]

    public var touched: UInt32 { pathCount - failed }
    public var failed: UInt32 { UInt32(failedIndices.count) }

    public init(pathCount: UInt32, failedIndices: [UInt32]) {
        precondition(failedIndices.allSatisfy { $0 < pathCount }, "failed fsevent index out of range")
        precondition(
            zip(failedIndices, failedIndices.dropFirst()).allSatisfy { $0.0 < $0.1 },
            "failed fsevent indices must be strictly increasing"
        )
        self.pathCount = pathCount
        self.failedIndices = failedIndices
    }
}

public enum GuestFSEventBridgeError: Error, Equatable {
    case tooManyPaths
    case invalidOperationID
    case invalidPath(String)
    case oversizedFrame
    case invalidResponse
    case operationIDConflict
    case dedupeCapacityExhausted
    case guestExecutionFailed
    case timedOut
    case connectionClosed
}

public enum GuestFSEventBatchCodec {
    public static let protocolVersion: UInt32 = 2
    /// Body limit; the four-byte length prefix brings the complete frame to exactly 128 KiB.
    public static let maximumFrameBytes = 128 * 1024 - 4
    public static let maximumPaths = 512
    /// Linux PATH_MAX includes the terminating NUL used by open(2).
    public static let maximumPathBytes = 4095
    /// The guest retains completed IDs for 120 seconds. During one guest-agent lifetime, host
    /// retries stop earlier so expiration cannot turn an uncertain delivery into a second nudge.
    public static let maximumOperationRetryAgeSeconds: TimeInterval = 90
    private static let responseBaseBodyBytes = 24
    static let maximumResponseBodyBytes = responseBaseBodyBytes + maximumPaths * 4

    public static func encodeRequest(operationID: UInt64, paths: [String]) throws -> [UInt8] {
        guard paths.count <= maximumPaths else { throw GuestFSEventBridgeError.tooManyPaths }
        guard operationID != 0 || paths.isEmpty else {
            throw GuestFSEventBridgeError.invalidOperationID
        }
        var body = [UInt8]()
        body.reserveCapacity(min(maximumFrameBytes, 16 + paths.reduce(0) { $0 + $1.utf8.count + 4 }))
        body.appendLE(protocolVersion)
        body.appendLE(operationID)
        body.appendLE(UInt32(paths.count))
        for path in paths {
            let bytes = Array(path.utf8)
            guard path.hasPrefix("/"),
                  !path.utf8.contains(0),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
                  !bytes.isEmpty,
                  bytes.count <= maximumPathBytes else {
                throw GuestFSEventBridgeError.invalidPath(path)
            }
            guard body.count + 4 + bytes.count <= maximumFrameBytes else {
                throw GuestFSEventBridgeError.oversizedFrame
            }
            body.appendLE(UInt32(bytes.count))
            body.append(contentsOf: bytes)
        }
        var frame = [UInt8]()
        frame.reserveCapacity(4 + body.count)
        frame.appendLE(UInt32(body.count))
        frame.append(contentsOf: body)
        return frame
    }

    public static func decodeResponse(
        frame: [UInt8],
        expectedOperationID: UInt64,
        expectedPathCount: Int
    ) throws -> GuestFSEventBatchResult {
        guard expectedPathCount >= 0,
              expectedPathCount <= maximumPaths,
              frame.count >= 4 + responseBaseBodyBytes,
              frame.count <= 4 + maximumResponseBodyBytes,
              frame.leUInt32(at: 0) == UInt32(frame.count - 4),
              frame.leUInt32(at: 4) == protocolVersion,
              frame.leUInt64(at: 8) == expectedOperationID,
              frame.leUInt32(at: 16) == UInt32(expectedPathCount) else {
            throw GuestFSEventBridgeError.invalidResponse
        }

        let status = frame.leUInt32(at: 20)
        if status != 0 {
            guard frame.count == 4 + responseBaseBodyBytes,
                  frame.leUInt32(at: 24) == 0 else {
                throw GuestFSEventBridgeError.invalidResponse
            }
            switch status {
            case 1: throw GuestFSEventBridgeError.operationIDConflict
            case 2: throw GuestFSEventBridgeError.dedupeCapacityExhausted
            case 3: throw GuestFSEventBridgeError.guestExecutionFailed
            default: throw GuestFSEventBridgeError.invalidResponse
            }
        }

        let failedCount = Int(frame.leUInt32(at: 24))
        guard failedCount <= expectedPathCount,
              frame.count == 4 + responseBaseBodyBytes + failedCount * 4 else {
            throw GuestFSEventBridgeError.invalidResponse
        }
        var failedIndices = [UInt32]()
        failedIndices.reserveCapacity(failedCount)
        for index in 0..<failedCount {
            let failedIndex = frame.leUInt32(at: 28 + index * 4)
            guard failedIndex < UInt32(expectedPathCount),
                  failedIndices.last.map({ $0 < failedIndex }) ?? true else {
                throw GuestFSEventBridgeError.invalidResponse
            }
            failedIndices.append(failedIndex)
        }
        return GuestFSEventBatchResult(pathCount: UInt32(expectedPathCount), failedIndices: failedIndices)
    }
}

/// Generates a process-scoped sequence seeded from system entropy. Callers that retry an uncertain
/// delivery must retain and reuse the same value; a logically new batch must obtain a new one.
public enum GuestFSEventOperationIDs {
    private static let source = GuestFSEventOperationIDSource()

    public static func next() -> UInt64 {
        source.next()
    }
}

public protocol GuestFSEventSending: Sendable {
    func send(operationID: UInt64, paths: [String]) async throws -> GuestFSEventBatchResult
}

public extension GuestFSEventSending {
    /// Convenience for one-shot operations. Retry-capable coherence code must allocate explicitly
    /// and call `send(operationID:paths:)` so an uncertain response reuses the same identifier.
    func send(paths: [String]) async throws -> GuestFSEventBatchResult {
        try await send(operationID: GuestFSEventOperationIDs.next(), paths: paths)
    }
}

/// Sends an already-invalidated host-edit batch to the guest agent. The bridge is deliberately a
/// separate vsock service from the general agent RPC: it is local-engine-only, bounded, and cannot
/// be reached through Dory's remote-machine control surface.
public final class GuestFSEventBridge: GuestFSEventSending, @unchecked Sendable {
    private let vsock: VirtioVsock
    private let timeoutNanoseconds: UInt64

    public init(vsock: VirtioVsock, timeoutNanoseconds: UInt64 = 2_000_000_000) {
        self.vsock = vsock
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public func send(operationID: UInt64, paths: [String]) async throws -> GuestFSEventBatchResult {
        let frame = try GuestFSEventBatchCodec.encodeRequest(operationID: operationID, paths: paths)
        let cancellation = GuestFSEventCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        let result = try send(
                            frame: frame,
                            operationID: operationID,
                            pathCount: paths.count,
                            cancellation: cancellation
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func send(
        frame: [UInt8],
        operationID: UInt64,
        pathCount: Int,
        cancellation: GuestFSEventCancellation
    ) throws -> GuestFSEventBatchResult {
        let deadline = ProcessInfo.processInfo.systemUptime
            + Double(timeoutNanoseconds) / 1_000_000_000
        let connection = vsock.connect(port: VsockPorts.fsevents)
        try cancellation.install(connection)
        defer { connection.close() }
        do {
            try connection.write(frame, timeoutNanoseconds: remainingNanoseconds(until: deadline))
        } catch VsockConnectionWriteError.timedOut {
            throw GuestFSEventBridgeError.timedOut
        } catch VsockConnectionWriteError.connectionClosed {
            throw GuestFSEventBridgeError.connectionClosed
        }
        connection.shutdownSend()
        let prefix = try readExactly(4, from: connection, deadline: deadline)
        let bodyLength = Int(prefix.leUInt32(at: 0))
        guard bodyLength >= 24,
              bodyLength <= GuestFSEventBatchCodec.maximumResponseBodyBytes else {
            throw GuestFSEventBridgeError.invalidResponse
        }
        let body = try readExactly(bodyLength, from: connection, deadline: deadline)
        return try GuestFSEventBatchCodec.decodeResponse(
            frame: prefix + body,
            expectedOperationID: operationID,
            expectedPathCount: pathCount
        )
    }

    private func readExactly(
        _ count: Int,
        from connection: VsockConnection,
        deadline: TimeInterval
    ) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let now = ProcessInfo.processInfo.systemUptime
            guard now < deadline else { throw GuestFSEventBridgeError.timedOut }
            let remaining = UInt64(max(0, deadline - now) * 1_000_000_000)
            _ = connection.waitForReadable(timeoutNanoseconds: min(remaining, 50_000_000))
            let read = try bytes.withUnsafeMutableBytes { raw in
                try connection.read(into: UnsafeMutableRawBufferPointer(
                    rebasing: raw[offset..<count]
                ))
            }
            if read == 0 {
                if connection.isPeerClosed { throw GuestFSEventBridgeError.connectionClosed }
                continue
            }
            offset += read
        }
        return bytes
    }

    private func remainingNanoseconds(until deadline: TimeInterval) -> UInt64 {
        UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000_000_000)
    }
}

private final class GuestFSEventOperationIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = {
        var generator = SystemRandomNumberGenerator()
        let seed = UInt64.random(in: 1...UInt64.max, using: &generator)
        return seed
    }()

    func next() -> UInt64 {
        lock.withLock {
            let result = value
            value &+= 1
            if value == 0 { value = 1 }
            return result
        }
    }
}

private final class GuestFSEventCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: VsockConnection?
    private var cancelled = false

    func install(_ connection: VsockConnection) throws {
        let shouldClose = lock.withLock { () -> Bool in
            guard !cancelled else { return true }
            self.connection = connection
            return false
        }
        if shouldClose {
            connection.close()
            throw CancellationError()
        }
    }

    func cancel() {
        let connection = lock.withLock { () -> VsockConnection? in
            cancelled = true
            return self.connection
        }
        connection?.close()
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
