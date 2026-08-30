import Darwin
import DoryPhase0AQualification
import Foundation

private let roundCount = 5
private let fileBytes = 128 * 1_024 * 1_024
private let sequentialChunkBytes = 1 * 1_024 * 1_024
private let randomBlockBytes = 4 * 1_024
private let randomOperationCount = 2_000

private struct StoragePolicy: Codable {
    var roundCount: Int
    var fileBytes: Int
    var sequentialChunkBytes: Int
    var randomBlockBytes: Int
    var randomOperationsPerKindPerRound: Int
    var uncachedIO: Bool
    var writeDurability: String
    var temporaryFileLifecycle: String
    var clock: String
    var percentileMethod: String
}

private struct StorageTarget: Codable {
    var directoryClass: String
    var device: String
    var fileSystemType: String
    var freeBytesBefore: UInt64
    var temporaryFileUnlinkedImmediately: Bool
}

private struct StorageLatencyObservation: Codable {
    var round: Int
    var operation: String
    var sample: Int
    var blockIndex: Int
    var latencyMicroseconds: Double
}

private struct StorageRound: Codable {
    var round: Int
    var sequentialWriteMiBPerSecond: Double
    var sequentialReadMiBPerSecond: Double
    var randomReadIOPS: Double
    var randomWriteIOPSIncludingFinalSync: Double
    var randomWriteFinalSyncMicroseconds: Double
    var sequentialCorrectnessChecks: Int
    var randomReadCorrectnessChecks: Int
    var randomWriteCorrectnessChecks: Int
}

private struct StorageAggregate: Codable {
    var sequentialWriteMiBPerSecond: Phase0AMetricSummary
    var sequentialReadMiBPerSecond: Phase0AMetricSummary
    var randomReadIOPS: Phase0AMetricSummary
    var randomWriteIOPSIncludingFinalSync: Phase0AMetricSummary
    var randomReadLatencyMicroseconds: Phase0AMetricSummary
    var randomWriteSubmissionLatencyMicroseconds: Phase0AMetricSummary
    var randomWriteFinalSyncMicroseconds: Phase0AMetricSummary
}

private struct StorageReceipt: Codable {
    var schema: String
    var startedHost: Phase0AHostQualificationReceipt
    var finishedHost: Phase0AHostQualificationReceipt
    var target: StorageTarget
    var policy: StoragePolicy
    var rounds: [StorageRound]
    var latencyObservations: [StorageLatencyObservation]
    var aggregate: StorageAggregate
    var validityBlockers: [String]
    var hostStorageBaselineComplete: Bool
    var doryVirtualStorageQualified: Bool
    var referenceMatrixComplete: Bool
}

private enum StorageBaselineError: Error, CustomStringConvertible {
    case posix(operation: String, code: Int32)
    case insufficientFreeStorage(required: UInt64, available: UInt64)
    case correctness(operation: String, round: Int, sample: Int)

    var description: String {
        switch self {
        case .posix(let operation, let code):
            "\(operation) failed with errno \(code): \(String(cString: strerror(code)))"
        case .insufficientFreeStorage(let required, let available):
            "storage baseline requires \(required) free bytes but found \(available)"
        case .correctness(let operation, let round, let sample):
            "\(operation) correctness failed in round \(round), sample \(sample)"
        }
    }
}

private func monotonicNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
}

private func systemValue(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return ""
    }
}

private func benchmarkDevice() -> String {
    let output = systemValue("/bin/df", ["-P", "/private/var/tmp"])
    return output.split(separator: "\n").last?.split(separator: " ").first.map(String.init) ?? ""
}

private func benchmarkFileSystemType(device: String) -> String {
    let output = systemValue("/usr/sbin/diskutil", ["info", "-plist", device])
    guard
        let propertyList = try? PropertyListSerialization.propertyList(
            from: Data(output.utf8),
            format: nil
        ),
        let properties = propertyList as? [String: Any],
        let fileSystemType = properties["FilesystemType"] as? String
    else {
        return ""
    }
    return fileSystemType
}

private func availableBytes() throws -> UInt64 {
    var statistics = statvfs()
    guard statvfs("/private/var/tmp", &statistics) == 0 else {
        throw StorageBaselineError.posix(operation: "statvfs", code: errno)
    }
    return UInt64(statistics.f_bavail) * UInt64(statistics.f_frsize)
}

private func makeUnlinkedTemporaryFile() throws -> Int32 {
    var template = Array("/private/var/tmp/dory-phase0a-storage.XXXXXX".utf8CString)
    let descriptor = template.withUnsafeMutableBufferPointer { buffer in
        mkstemp(buffer.baseAddress!)
    }
    guard descriptor >= 0 else {
        throw StorageBaselineError.posix(operation: "mkstemp", code: errno)
    }
    let unlinkResult = template.withUnsafeBufferPointer { buffer in
        unlink(buffer.baseAddress!)
    }
    guard unlinkResult == 0 else {
        let code = errno
        close(descriptor)
        throw StorageBaselineError.posix(operation: "unlink temporary file", code: code)
    }
    guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
        let code = errno
        close(descriptor)
        throw StorageBaselineError.posix(operation: "fcntl(FD_CLOEXEC)", code: code)
    }
    guard fcntl(descriptor, F_NOCACHE, 1) == 0 else {
        let code = errno
        close(descriptor)
        throw StorageBaselineError.posix(operation: "fcntl(F_NOCACHE)", code: code)
    }
    guard ftruncate(descriptor, off_t(fileBytes)) == 0 else {
        let code = errno
        close(descriptor)
        throw StorageBaselineError.posix(operation: "ftruncate", code: code)
    }
    return descriptor
}

private func allocateAligned(byteCount: Int) throws -> UnsafeMutableRawPointer {
    var pointer: UnsafeMutableRawPointer?
    let result = posix_memalign(&pointer, randomBlockBytes, byteCount)
    guard result == 0, let pointer else {
        throw StorageBaselineError.posix(operation: "posix_memalign", code: Int32(result))
    }
    return pointer
}

private func writeFully(
    descriptor: Int32,
    buffer: UnsafeRawPointer,
    byteCount: Int,
    offset: Int
) throws {
    var written = 0
    while written < byteCount {
        let result = pwrite(
            descriptor,
            buffer.advanced(by: written),
            byteCount - written,
            off_t(offset + written)
        )
        if result < 0, errno == EINTR { continue }
        guard result > 0 else {
            throw StorageBaselineError.posix(operation: "pwrite", code: errno)
        }
        written += result
    }
}

private func readFully(
    descriptor: Int32,
    buffer: UnsafeMutableRawPointer,
    byteCount: Int,
    offset: Int
) throws {
    var readBytes = 0
    while readBytes < byteCount {
        let result = pread(
            descriptor,
            buffer.advanced(by: readBytes),
            byteCount - readBytes,
            off_t(offset + readBytes)
        )
        if result < 0, errno == EINTR { continue }
        guard result > 0 else {
            throw StorageBaselineError.posix(operation: "pread", code: errno)
        }
        readBytes += result
    }
}

private func runCampaign() throws -> StorageReceipt {
    let startedHost = try Phase0AHostCollector.collect()
    let freeBytes = try availableBytes()
    let requiredFreeBytes = UInt64(fileBytes) * 4 + 4 * 1_024 * 1_024 * 1_024
    guard freeBytes >= requiredFreeBytes else {
        throw StorageBaselineError.insufficientFreeStorage(
            required: requiredFreeBytes,
            available: freeBytes
        )
    }

    let descriptor = try makeUnlinkedTemporaryFile()
    defer { close(descriptor) }
    let sequentialBuffer = try allocateAligned(byteCount: sequentialChunkBytes)
    let randomBuffer = try allocateAligned(byteCount: randomBlockBytes)
    let randomWritePatternBuffer = try allocateAligned(byteCount: sequentialChunkBytes)
    defer {
        free(sequentialBuffer)
        free(randomBuffer)
        free(randomWritePatternBuffer)
    }
    let sequentialBytes = sequentialBuffer.assumingMemoryBound(to: UInt8.self)
    for index in 0..<sequentialChunkBytes {
        sequentialBytes[index] = UInt8(truncatingIfNeeded: (index * 31) + 17)
    }

    let blockCount = fileBytes / randomBlockBytes
    var rounds: [StorageRound] = []
    var observations: [StorageLatencyObservation] = []
    observations.reserveCapacity(roundCount * randomOperationCount * 2)

    for roundIndex in 0..<roundCount {
        let round = roundIndex + 1
        var started = monotonicNanoseconds()
        for offset in stride(from: 0, to: fileBytes, by: sequentialChunkBytes) {
            try writeFully(
                descriptor: descriptor,
                buffer: UnsafeRawPointer(sequentialBuffer),
                byteCount: sequentialChunkBytes,
                offset: offset
            )
        }
        guard fsync(descriptor) == 0 else {
            throw StorageBaselineError.posix(operation: "sequential fsync", code: errno)
        }
        let sequentialWriteNanoseconds = monotonicNanoseconds() - started

        started = monotonicNanoseconds()
        for offset in stride(from: 0, to: fileBytes, by: sequentialChunkBytes) {
            try readFully(
                descriptor: descriptor,
                buffer: sequentialBuffer,
                byteCount: sequentialChunkBytes,
                offset: offset
            )
        }
        let sequentialReadNanoseconds = monotonicNanoseconds() - started

        let correctnessBlocks = try Phase0ADeterministicBlockSchedule.indices(
            seed: 0xd0_72_c0_00 + UInt64(round),
            count: 32,
            blockCount: blockCount
        )
        for (sample, block) in correctnessBlocks.enumerated() {
            let offset = block * randomBlockBytes
            try readFully(
                descriptor: descriptor,
                buffer: randomBuffer,
                byteCount: randomBlockBytes,
                offset: offset
            )
            let expected = sequentialBuffer.advanced(by: offset % sequentialChunkBytes)
            guard memcmp(randomBuffer, expected, randomBlockBytes) == 0 else {
                throw StorageBaselineError.correctness(
                    operation: "sequential read",
                    round: round,
                    sample: sample + 1
                )
            }
        }

        let readBlocks = try Phase0ADeterministicBlockSchedule.indices(
            seed: 0xd0_72_10_00 + UInt64(round),
            count: randomOperationCount,
            blockCount: blockCount
        )
        let randomReadStarted = monotonicNanoseconds()
        for (sample, block) in readBlocks.enumerated() {
            let offset = block * randomBlockBytes
            let operationStarted = monotonicNanoseconds()
            try readFully(
                descriptor: descriptor,
                buffer: randomBuffer,
                byteCount: randomBlockBytes,
                offset: offset
            )
            let latency = Double(monotonicNanoseconds() - operationStarted) / 1_000
            let expected = sequentialBuffer.advanced(by: offset % sequentialChunkBytes)
            guard memcmp(randomBuffer, expected, randomBlockBytes) == 0 else {
                throw StorageBaselineError.correctness(
                    operation: "random read",
                    round: round,
                    sample: sample + 1
                )
            }
            observations.append(
                StorageLatencyObservation(
                    round: round,
                    operation: "random-read",
                    sample: sample + 1,
                    blockIndex: block,
                    latencyMicroseconds: latency
                )
            )
        }
        let randomReadNanoseconds = monotonicNanoseconds() - randomReadStarted

        let writeBlocks = try Phase0ADeterministicBlockSchedule.indices(
            seed: 0xd0_72_20_00 + UInt64(round),
            count: randomOperationCount,
            blockCount: blockCount
        )
        let writePatternBytes = randomWritePatternBuffer.assumingMemoryBound(to: UInt8.self)
        let writePatternMask = UInt8(0x80 | round)
        for index in 0..<sequentialChunkBytes {
            writePatternBytes[index] = sequentialBytes[index] ^ writePatternMask
        }
        let randomWriteStarted = monotonicNanoseconds()
        for (sample, block) in writeBlocks.enumerated() {
            let offset = block * randomBlockBytes
            let expected = randomWritePatternBuffer.advanced(by: offset % sequentialChunkBytes)
            let operationStarted = monotonicNanoseconds()
            try writeFully(
                descriptor: descriptor,
                buffer: UnsafeRawPointer(expected),
                byteCount: randomBlockBytes,
                offset: offset
            )
            let latency = Double(monotonicNanoseconds() - operationStarted) / 1_000
            observations.append(
                StorageLatencyObservation(
                    round: round,
                    operation: "random-write-submission",
                    sample: sample + 1,
                    blockIndex: block,
                    latencyMicroseconds: latency
                )
            )
        }
        let syncStarted = monotonicNanoseconds()
        guard fsync(descriptor) == 0 else {
            throw StorageBaselineError.posix(operation: "random write fsync", code: errno)
        }
        let syncNanoseconds = monotonicNanoseconds() - syncStarted
        let randomWriteNanoseconds = monotonicNanoseconds() - randomWriteStarted
        for (sample, block) in writeBlocks.enumerated() {
            let offset = block * randomBlockBytes
            try readFully(
                descriptor: descriptor,
                buffer: randomBuffer,
                byteCount: randomBlockBytes,
                offset: offset
            )
            let expected = randomWritePatternBuffer.advanced(by: offset % sequentialChunkBytes)
            guard memcmp(randomBuffer, expected, randomBlockBytes) == 0 else {
                throw StorageBaselineError.correctness(
                    operation: "random write readback",
                    round: round,
                    sample: sample + 1
                )
            }
        }

        rounds.append(
            StorageRound(
                round: round,
                sequentialWriteMiBPerSecond: (Double(fileBytes) / 1_048_576)
                    / (Double(sequentialWriteNanoseconds) / 1_000_000_000),
                sequentialReadMiBPerSecond: (Double(fileBytes) / 1_048_576)
                    / (Double(sequentialReadNanoseconds) / 1_000_000_000),
                randomReadIOPS: Double(randomOperationCount)
                    / (Double(randomReadNanoseconds) / 1_000_000_000),
                randomWriteIOPSIncludingFinalSync: Double(randomOperationCount)
                    / (Double(randomWriteNanoseconds) / 1_000_000_000),
                randomWriteFinalSyncMicroseconds: Double(syncNanoseconds) / 1_000,
                sequentialCorrectnessChecks: correctnessBlocks.count,
                randomReadCorrectnessChecks: readBlocks.count,
                randomWriteCorrectnessChecks: writeBlocks.count
            )
        )
    }

    let readLatencies = observations.filter { $0.operation == "random-read" }
        .map(\.latencyMicroseconds)
    let writeLatencies = observations.filter { $0.operation == "random-write-submission" }
        .map(\.latencyMicroseconds)
    let aggregate = StorageAggregate(
        sequentialWriteMiBPerSecond: try Phase0AMetricSummary(
            samples: rounds.map(\.sequentialWriteMiBPerSecond)
        ),
        sequentialReadMiBPerSecond: try Phase0AMetricSummary(
            samples: rounds.map(\.sequentialReadMiBPerSecond)
        ),
        randomReadIOPS: try Phase0AMetricSummary(samples: rounds.map(\.randomReadIOPS)),
        randomWriteIOPSIncludingFinalSync: try Phase0AMetricSummary(
            samples: rounds.map(\.randomWriteIOPSIncludingFinalSync)
        ),
        randomReadLatencyMicroseconds: try Phase0AMetricSummary(samples: readLatencies),
        randomWriteSubmissionLatencyMicroseconds: try Phase0AMetricSummary(samples: writeLatencies),
        randomWriteFinalSyncMicroseconds: try Phase0AMetricSummary(
            samples: rounds.map(\.randomWriteFinalSyncMicroseconds)
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
    let device = benchmarkDevice()
    let fileSystemType = benchmarkFileSystemType(device: device)
    if device.isEmpty {
        blockers.append("benchmark device could not be identified")
    }
    if fileSystemType.isEmpty {
        blockers.append("benchmark filesystem type could not be identified")
    }
    let target = StorageTarget(
        directoryClass: "system-data-temporary",
        device: device,
        fileSystemType: fileSystemType,
        freeBytesBefore: freeBytes,
        temporaryFileUnlinkedImmediately: true
    )
    return StorageReceipt(
        schema: "dory.phase0a.host-storage-baseline@1",
        startedHost: startedHost,
        finishedHost: finishedHost,
        target: target,
        policy: StoragePolicy(
            roundCount: roundCount,
            fileBytes: fileBytes,
            sequentialChunkBytes: sequentialChunkBytes,
            randomBlockBytes: randomBlockBytes,
            randomOperationsPerKindPerRound: randomOperationCount,
            uncachedIO: true,
            writeDurability: "sequential and random batches end in fsync",
            temporaryFileLifecycle: "0600 O_EXCL file unlinked immediately after open",
            clock: "CLOCK_MONOTONIC_RAW",
            percentileMethod: "R-7 linear interpolation"
        ),
        rounds: rounds,
        latencyObservations: observations,
        aggregate: aggregate,
        validityBlockers: blockers,
        hostStorageBaselineComplete: blockers.isEmpty,
        doryVirtualStorageQualified: false,
        referenceMatrixComplete: false
    )
}

do {
    let receipt = try runCampaign()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(receipt))
    FileHandle.standardOutput.write(Data([0x0a]))
    exit(receipt.hostStorageBaselineComplete ? EXIT_SUCCESS : 3)
} catch {
    FileHandle.standardError.write(Data("dory Phase 0A storage baseline failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
