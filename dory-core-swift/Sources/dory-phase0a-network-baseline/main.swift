import Darwin
import Dispatch
import DoryPhase0AQualification
import Foundation

private let roundCount = 5
private let warmupTransferBytes = 32 * 1_024 * 1_024
private let transferBytes = 256 * 1_024 * 1_024
private let streamChunkBytes = 1 * 1_024 * 1_024
private let warmupPingCount = 200
private let pingCount = 2_000
private let pingBytes = 64

private struct NetworkPolicy: Codable {
    var workload: String
    var roundCount: Int
    var warmupTransferBytesPerDirection: Int
    var measuredTransferBytesPerDirectionPerRound: Int
    var streamChunkBytes: Int
    var warmupPingCount: Int
    var measuredPingCountPerRound: Int
    var pingBytes: Int
    var clock: String
    var percentileMethod: String
}

private struct NetworkTarget: Codable {
    var addressFamily: String
    var transport: String
    var address: String
    var interface: String
    var listenerPortPolicy: String
    var externalNetworkTraffic: Bool
}

private struct NetworkLatencyObservation: Codable {
    var round: Int
    var sample: Int
    var roundTripMicroseconds: Double
}

private struct NetworkRound: Codable {
    var round: Int
    var firstDirection: String
    var uploadMiBPerSecond: Double
    var downloadMiBPerSecond: Double
    var pingRoundTripMicroseconds: Phase0AMetricSummary
    var uploadCorrectnessBytes: Int
    var downloadCorrectnessBytes: Int
    var pingCorrectnessExchanges: Int
}

private struct NetworkAggregate: Codable {
    var uploadMiBPerSecond: Phase0AMetricSummary
    var downloadMiBPerSecond: Phase0AMetricSummary
    var pingRoundTripMicroseconds: Phase0AMetricSummary
}

private struct NetworkReceipt: Codable {
    var schema: String
    var startedHost: Phase0AHostQualificationReceipt
    var finishedHost: Phase0AHostQualificationReceipt
    var target: NetworkTarget
    var policy: NetworkPolicy
    var rounds: [NetworkRound]
    var latencyObservations: [NetworkLatencyObservation]
    var aggregate: NetworkAggregate
    var validityBlockers: [String]
    var hostNetworkBaselineComplete: Bool
    var doryVirtualNetworkQualified: Bool
    var referenceMatrixComplete: Bool
}

private enum NetworkBaselineError: Error, CustomStringConvertible {
    case posix(operation: String, code: Int32)
    case correctness(operation: String, sample: Int)
    case server(String)
    case serverTimeout

    var description: String {
        switch self {
        case .posix(let operation, let code):
            "\(operation) failed with errno \(code): \(String(cString: strerror(code)))"
        case .correctness(let operation, let sample):
            "\(operation) correctness failed at sample \(sample)"
        case .server(let message):
            "server failed: \(message)"
        case .serverTimeout:
            "server did not finish within 120 seconds"
        }
    }
}

private final class ServerResult: @unchecked Sendable {
    private let lock = NSLock()
    private var errorDescription: String?

    func record(_ error: Error) {
        lock.lock()
        errorDescription = String(describing: error)
        lock.unlock()
    }

    func throwIfFailed() throws {
        lock.lock()
        let errorDescription = errorDescription
        lock.unlock()
        if let errorDescription {
            throw NetworkBaselineError.server(errorDescription)
        }
    }
}

private func monotonicNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
}

private func allocatePattern(byteCount: Int) -> UnsafeMutableRawPointer {
    let pointer = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: MemoryLayout<UInt64>.alignment
    )
    let bytes = pointer.assumingMemoryBound(to: UInt8.self)
    for index in 0..<byteCount {
        bytes[index] = Phase0ADeterministicBytePattern.byte(at: index)
    }
    return pointer
}

private func configureStreamSocket(_ descriptor: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout.size(ofValue: enabled))
    ) == 0 else {
        throw NetworkBaselineError.posix(operation: "setsockopt(SO_NOSIGPIPE)", code: errno)
    }
    guard setsockopt(
        descriptor,
        IPPROTO_TCP,
        TCP_NODELAY,
        &enabled,
        socklen_t(MemoryLayout.size(ofValue: enabled))
    ) == 0 else {
        throw NetworkBaselineError.posix(operation: "setsockopt(TCP_NODELAY)", code: errno)
    }
}

private func makeListener() throws -> (descriptor: Int32, port: UInt16) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NetworkBaselineError.posix(operation: "socket(listener)", code: errno)
    }
    do {
        try configureStreamSocket(descriptor)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw NetworkBaselineError.posix(operation: "bind(loopback)", code: errno)
        }
        guard listen(descriptor, 1) == 0 else {
            throw NetworkBaselineError.posix(operation: "listen", code: errno)
        }
        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            throw NetworkBaselineError.posix(operation: "getsockname", code: errno)
        }
        guard boundAddress.sin_addr.s_addr == inet_addr("127.0.0.1") else {
            throw NetworkBaselineError.correctness(operation: "listener address", sample: 0)
        }
        return (descriptor, UInt16(bigEndian: boundAddress.sin_port))
    } catch {
        close(descriptor)
        throw error
    }
}

private func connectToLoopback(port: UInt16) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NetworkBaselineError.posix(operation: "socket(client)", code: errno)
    }
    do {
        try configureStreamSocket(descriptor)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            throw NetworkBaselineError.posix(operation: "connect(loopback)", code: errno)
        }
        return descriptor
    } catch {
        close(descriptor)
        throw error
    }
}

private func acceptConnection(listener: Int32) throws -> Int32 {
    while true {
        let descriptor = accept(listener, nil, nil)
        if descriptor < 0, errno == EINTR { continue }
        guard descriptor >= 0 else {
            throw NetworkBaselineError.posix(operation: "accept", code: errno)
        }
        do {
            try configureStreamSocket(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }
}

private func writeFully(
    descriptor: Int32,
    buffer: UnsafeRawPointer,
    byteCount: Int
) throws {
    var written = 0
    while written < byteCount {
        let result = Darwin.write(
            descriptor,
            buffer.advanced(by: written),
            byteCount - written
        )
        if result < 0, errno == EINTR { continue }
        guard result > 0 else {
            throw NetworkBaselineError.posix(operation: "write", code: errno)
        }
        written += result
    }
}

private func readFully(
    descriptor: Int32,
    buffer: UnsafeMutableRawPointer,
    byteCount: Int
) throws {
    var readBytes = 0
    while readBytes < byteCount {
        let result = Darwin.read(
            descriptor,
            buffer.advanced(by: readBytes),
            byteCount - readBytes
        )
        if result < 0, errno == EINTR { continue }
        guard result > 0 else {
            throw NetworkBaselineError.posix(operation: "read", code: errno)
        }
        readBytes += result
    }
}

private func waitForServer(_ group: DispatchGroup, result: ServerResult) throws {
    guard group.wait(timeout: .now() + 120) == .success else {
        throw NetworkBaselineError.serverTimeout
    }
    try result.throwIfFailed()
}

private func runUpload(byteCount: Int) throws -> UInt64 {
    let listener = try makeListener()
    let group = DispatchGroup()
    let serverResult = ServerResult()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        defer {
            close(listener.descriptor)
            group.leave()
        }
        do {
            let connection = try acceptConnection(listener: listener.descriptor)
            defer { close(connection) }
            let received = allocatePattern(byteCount: streamChunkBytes)
            let expected = allocatePattern(byteCount: streamChunkBytes)
            defer {
                received.deallocate()
                expected.deallocate()
            }
            for sample in 0..<(byteCount / streamChunkBytes) {
                try readFully(
                    descriptor: connection,
                    buffer: received,
                    byteCount: streamChunkBytes
                )
                guard memcmp(received, expected, streamChunkBytes) == 0 else {
                    throw NetworkBaselineError.correctness(operation: "upload", sample: sample + 1)
                }
            }
            var acknowledgement: UInt8 = 0xa5
            try writeFully(
                descriptor: connection,
                buffer: &acknowledgement,
                byteCount: 1
            )
        } catch {
            serverResult.record(error)
        }
    }

    let client = try connectToLoopback(port: listener.port)
    defer { close(client) }
    let payload = allocatePattern(byteCount: streamChunkBytes)
    defer { payload.deallocate() }
    let started = monotonicNanoseconds()
    for _ in 0..<(byteCount / streamChunkBytes) {
        try writeFully(descriptor: client, buffer: payload, byteCount: streamChunkBytes)
    }
    var acknowledgement: UInt8 = 0
    try readFully(descriptor: client, buffer: &acknowledgement, byteCount: 1)
    let elapsed = monotonicNanoseconds() - started
    guard acknowledgement == 0xa5 else {
        throw NetworkBaselineError.correctness(operation: "upload acknowledgement", sample: 1)
    }
    try waitForServer(group, result: serverResult)
    return elapsed
}

private func runDownload(byteCount: Int) throws -> UInt64 {
    let listener = try makeListener()
    let group = DispatchGroup()
    let serverResult = ServerResult()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        defer {
            close(listener.descriptor)
            group.leave()
        }
        do {
            let connection = try acceptConnection(listener: listener.descriptor)
            defer { close(connection) }
            var start: UInt8 = 0
            try readFully(descriptor: connection, buffer: &start, byteCount: 1)
            guard start == 0x5a else {
                throw NetworkBaselineError.correctness(operation: "download start", sample: 1)
            }
            let payload = allocatePattern(byteCount: streamChunkBytes)
            defer { payload.deallocate() }
            for _ in 0..<(byteCount / streamChunkBytes) {
                try writeFully(
                    descriptor: connection,
                    buffer: payload,
                    byteCount: streamChunkBytes
                )
            }
            var acknowledgement: UInt8 = 0
            try readFully(descriptor: connection, buffer: &acknowledgement, byteCount: 1)
            guard acknowledgement == 0xa5 else {
                throw NetworkBaselineError.correctness(
                    operation: "download acknowledgement",
                    sample: 1
                )
            }
        } catch {
            serverResult.record(error)
        }
    }

    let client = try connectToLoopback(port: listener.port)
    defer { close(client) }
    var start: UInt8 = 0x5a
    try writeFully(descriptor: client, buffer: &start, byteCount: 1)
    let received = allocatePattern(byteCount: streamChunkBytes)
    let expected = allocatePattern(byteCount: streamChunkBytes)
    defer {
        received.deallocate()
        expected.deallocate()
    }
    let started = monotonicNanoseconds()
    for sample in 0..<(byteCount / streamChunkBytes) {
        try readFully(descriptor: client, buffer: received, byteCount: streamChunkBytes)
        guard memcmp(received, expected, streamChunkBytes) == 0 else {
            throw NetworkBaselineError.correctness(operation: "download", sample: sample + 1)
        }
    }
    let elapsed = monotonicNanoseconds() - started
    var acknowledgement: UInt8 = 0xa5
    try writeFully(descriptor: client, buffer: &acknowledgement, byteCount: 1)
    try waitForServer(group, result: serverResult)
    return elapsed
}

private func runPingPong(count: Int) throws -> [Double] {
    let listener = try makeListener()
    let group = DispatchGroup()
    let serverResult = ServerResult()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        defer {
            close(listener.descriptor)
            group.leave()
        }
        do {
            let connection = try acceptConnection(listener: listener.descriptor)
            defer { close(connection) }
            let received = allocatePattern(byteCount: pingBytes)
            let expected = allocatePattern(byteCount: pingBytes)
            defer {
                received.deallocate()
                expected.deallocate()
            }
            for sample in 0..<count {
                try readFully(descriptor: connection, buffer: received, byteCount: pingBytes)
                guard memcmp(received, expected, pingBytes) == 0 else {
                    throw NetworkBaselineError.correctness(
                        operation: "ping server receive",
                        sample: sample + 1
                    )
                }
                try writeFully(descriptor: connection, buffer: expected, byteCount: pingBytes)
            }
        } catch {
            serverResult.record(error)
        }
    }

    let client = try connectToLoopback(port: listener.port)
    defer { close(client) }
    let payload = allocatePattern(byteCount: pingBytes)
    let response = allocatePattern(byteCount: pingBytes)
    defer {
        payload.deallocate()
        response.deallocate()
    }
    var latencies: [Double] = []
    latencies.reserveCapacity(count)
    for sample in 0..<count {
        let started = monotonicNanoseconds()
        try writeFully(descriptor: client, buffer: payload, byteCount: pingBytes)
        try readFully(descriptor: client, buffer: response, byteCount: pingBytes)
        let elapsed = monotonicNanoseconds() - started
        guard memcmp(response, payload, pingBytes) == 0 else {
            throw NetworkBaselineError.correctness(
                operation: "ping client receive",
                sample: sample + 1
            )
        }
        latencies.append(Double(elapsed) / 1_000)
    }
    try waitForServer(group, result: serverResult)
    return latencies
}

private func runCampaign() throws -> NetworkReceipt {
    let startedHost = try Phase0AHostCollector.collect()
    _ = try runUpload(byteCount: warmupTransferBytes)
    _ = try runDownload(byteCount: warmupTransferBytes)
    _ = try runPingPong(count: warmupPingCount)

    var rounds: [NetworkRound] = []
    var observations: [NetworkLatencyObservation] = []
    observations.reserveCapacity(roundCount * pingCount)
    for roundIndex in 0..<roundCount {
        let round = roundIndex + 1
        let uploadFirst = round % 2 == 1
        let uploadNanoseconds: UInt64
        let downloadNanoseconds: UInt64
        if uploadFirst {
            uploadNanoseconds = try runUpload(byteCount: transferBytes)
            downloadNanoseconds = try runDownload(byteCount: transferBytes)
        } else {
            downloadNanoseconds = try runDownload(byteCount: transferBytes)
            uploadNanoseconds = try runUpload(byteCount: transferBytes)
        }
        let pingLatencies = try runPingPong(count: pingCount)
        for (sample, latency) in pingLatencies.enumerated() {
            observations.append(
                NetworkLatencyObservation(
                    round: round,
                    sample: sample + 1,
                    roundTripMicroseconds: latency
                )
            )
        }
        rounds.append(
            NetworkRound(
                round: round,
                firstDirection: uploadFirst ? "upload" : "download",
                uploadMiBPerSecond: (Double(transferBytes) / 1_048_576)
                    / (Double(uploadNanoseconds) / 1_000_000_000),
                downloadMiBPerSecond: (Double(transferBytes) / 1_048_576)
                    / (Double(downloadNanoseconds) / 1_000_000_000),
                pingRoundTripMicroseconds: try Phase0AMetricSummary(samples: pingLatencies),
                uploadCorrectnessBytes: transferBytes,
                downloadCorrectnessBytes: transferBytes,
                pingCorrectnessExchanges: pingCount
            )
        )
    }

    let aggregate = NetworkAggregate(
        uploadMiBPerSecond: try Phase0AMetricSummary(samples: rounds.map(\.uploadMiBPerSecond)),
        downloadMiBPerSecond: try Phase0AMetricSummary(samples: rounds.map(\.downloadMiBPerSecond)),
        pingRoundTripMicroseconds: try Phase0AMetricSummary(
            samples: observations.map(\.roundTripMicroseconds)
        )
    )
    let finishedHost = try Phase0AHostCollector.collect()
    var blockers: [String] = []
    if startedHost.host.bootSessionIdentifier != finishedHost.host.bootSessionIdentifier {
        blockers.append("boot session changed during campaign")
    }
    if startedHost.host.powerSource != finishedHost.host.powerSource {
        blockers.append("power source changed during campaign")
    }
    if startedHost.host.lowPowerModeEnabled || finishedHost.host.lowPowerModeEnabled {
        blockers.append("low-power mode was enabled")
    }
    if startedHost.host.thermalState != "nominal" || finishedHost.host.thermalState != "nominal" {
        blockers.append("thermal state was not nominal")
    }
    return NetworkReceipt(
        schema: "dory.phase0a.host-network-baseline@1",
        startedHost: startedHost,
        finishedHost: finishedHost,
        target: NetworkTarget(
            addressFamily: "IPv4",
            transport: "TCP",
            address: "127.0.0.1",
            interface: "lo0",
            listenerPortPolicy: "kernel-assigned ephemeral port per connection",
            externalNetworkTraffic: false
        ),
        policy: NetworkPolicy(
            workload: "correctness-checked bidirectional TCP stream and ping-pong",
            roundCount: roundCount,
            warmupTransferBytesPerDirection: warmupTransferBytes,
            measuredTransferBytesPerDirectionPerRound: transferBytes,
            streamChunkBytes: streamChunkBytes,
            warmupPingCount: warmupPingCount,
            measuredPingCountPerRound: pingCount,
            pingBytes: pingBytes,
            clock: "CLOCK_MONOTONIC_RAW",
            percentileMethod: "R-7 linear interpolation"
        ),
        rounds: rounds,
        latencyObservations: observations,
        aggregate: aggregate,
        validityBlockers: blockers,
        hostNetworkBaselineComplete: blockers.isEmpty,
        doryVirtualNetworkQualified: false,
        referenceMatrixComplete: false
    )
}

do {
    let receipt = try runCampaign()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(receipt))
    FileHandle.standardOutput.write(Data([0x0a]))
    exit(receipt.hostNetworkBaselineComplete ? EXIT_SUCCESS : 3)
} catch {
    FileHandle.standardError.write(Data("dory Phase 0A network baseline failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
