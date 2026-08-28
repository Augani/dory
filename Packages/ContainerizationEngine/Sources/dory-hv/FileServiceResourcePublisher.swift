import Darwin
import DoryFSWorkerContracts
import DoryHV
import Foundation

struct DoryFileServiceResourceSnapshot: Codable, Sendable, Equatable {
    let schema: String
    let version: Int
    let generatedAt: Date
    let running: Bool
    let cacheMode: String
    let maximumCacheValiditySeconds: Double
    let configuredShareCount: Int
    let invalidationOnlyShareCount: Int
    let watcherNudgeShareCount: Int
    let frontendCount: Int
    let requestQueueCount: Int
    let observationRequired: Bool
    let observationActive: Bool
    let requiredObservationShareCount: Int
    let observedRequiredShareCount: Int
    let observationStreamCount: Int
    let pendingEventCount: Int
    let pendingEventLimit: Int
    let receivedEventCount: UInt64
    let deliveredBatchCount: UInt64
    let failedBatchCount: UInt64
    let eventLossCount: UInt64
    let invalidationCount: UInt64
    let invalidationFailureCount: UInt64
    let invalidationFailureLatched: Bool
    let rejectedRequestCount: UInt64
    let executedRequestCount: UInt64
    let terminalQueueFaultCount: UInt64
    let completedRequestCount: UInt64
    let failedRequestCount: UInt64
    let inFlightRequestCount: UInt64
    let peakInFlightRequestCount: UInt64
    let requestPayloadBytes: UInt64
    let workerResponsePayloadBytes: UInt64
    let guestPublishedResponseBytes: UInt64
    let totalRequestLatencyNanoseconds: UInt64
    let maximumRequestLatencyNanoseconds: UInt64
    let coherenceReceivedBatchCount: UInt64
    let coherenceReplayedBatchCount: UInt64
    let coherenceInFlightBatchCount: Int
    let coherenceFailedBatchCount: UInt64
    let coherenceTotalLatencyNanoseconds: UInt64
    let coherenceMaximumLatencyNanoseconds: UInt64
    let coherenceRequestBytes: UInt64
    let coherenceAcknowledgementBytes: UInt64
    let coherenceTerminalFailureLatched: Bool
}

final class FileServiceResourcePublisher: @unchecked Sendable {
    private let outputPath: String
    private let worker: DoryFilesystemWorkerLaunch
    private let frontends: [VirtioFS]
    private let queue = DispatchQueue(label: "dev.dory.file-service.resources")
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(
        stateDirectory: String,
        worker: DoryFilesystemWorkerLaunch,
        frontends: [VirtioFS]
    ) {
        outputPath = stateDirectory + "/file-service-resources.json"
        self.worker = worker
        self.frontends = frontends
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.publish() }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    func stop() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
        try? FileManager.default.removeItem(atPath: outputPath)
    }

    private func publish() {
        let status = try? worker.client.coherenceStatus(timeout: 1)
        let sink = worker.client.coherenceStatistics
        let invalidation = frontends.map(\.statistics)
        let frontend = frontends.map(\.frontendStatistics)
        let performance = frontends.map(\.performanceStatistics)
        let configured = Int(status?.configuredShareCount ?? 0)
        let streamCount = Int(status?.observationStreamCount ?? 0)
        let required = Int(status?.requiredObservationShareCount ?? 0)
        let observed = Int(status?.observedRequiredShareCount ?? 0)
        let observationActive = configured == 0
            || (streamCount > 0 && required == observed && status?.running == true)
        let invalidationLatched = invalidation.contains(where: \.invalidationFailureLatched)
        let snapshot = DoryFileServiceResourceSnapshot(
            schema: "dev.dory.file-service.resources",
            version: 1,
            generatedAt: Date(),
            running: status?.running == true
                && !sink.terminalFailureLatched
                && !invalidationLatched
                && observationActive,
            cacheMode: "zero-validity",
            maximumCacheValiditySeconds: Double(VirtioFS.maximumCoherentCacheValiditySeconds),
            configuredShareCount: configured,
            invalidationOnlyShareCount: Int(status?.invalidationOnlyShareCount ?? 0),
            watcherNudgeShareCount: Int(status?.watcherNudgeShareCount ?? 0),
            frontendCount: frontends.count,
            requestQueueCount: frontends.reduce(0) { $0 + $1.requestQueueCount },
            observationRequired: configured > 0,
            observationActive: observationActive,
            requiredObservationShareCount: required,
            observedRequiredShareCount: observed,
            observationStreamCount: streamCount,
            pendingEventCount: Int(status?.pendingEventCount ?? 0),
            pendingEventLimit: Int(status?.pendingEventLimit ?? 0),
            receivedEventCount: status?.receivedEventCount ?? 0,
            deliveredBatchCount: status?.deliveredBatchCount ?? 0,
            failedBatchCount: status?.failedBatchCount ?? 0,
            eventLossCount: status?.eventLossCount ?? 0,
            invalidationCount: sum(invalidation.map(\.invalidations)),
            invalidationFailureCount: sum(invalidation.map(\.invalidationFailures)),
            invalidationFailureLatched: invalidationLatched,
            rejectedRequestCount: sum(frontend.map(\.rejectedRequests)),
            executedRequestCount: sum(frontend.map(\.executedRequests)),
            terminalQueueFaultCount: sum(frontend.map(\.terminalQueueFaults)),
            completedRequestCount: sum(performance.map(\.completedRequests)),
            failedRequestCount: sum(performance.map(\.failedRequests)),
            inFlightRequestCount: sum(performance.map(\.inFlightRequests)),
            peakInFlightRequestCount: sum(performance.map(\.peakInFlightRequests)),
            requestPayloadBytes: sum(performance.map(\.requestPayloadBytes)),
            workerResponsePayloadBytes: sum(performance.map(\.workerResponsePayloadBytes)),
            guestPublishedResponseBytes: sum(performance.map(\.guestPublishedResponseBytes)),
            totalRequestLatencyNanoseconds: sum(performance.map(\.totalRequestLatencyNanoseconds)),
            maximumRequestLatencyNanoseconds: performance.map(\.maximumRequestLatencyNanoseconds).max() ?? 0,
            coherenceReceivedBatchCount: sink.receivedBatchCount,
            coherenceReplayedBatchCount: sink.replayedBatchCount,
            coherenceInFlightBatchCount: sink.inFlightBatchCount,
            coherenceFailedBatchCount: sink.failedBatchCount,
            coherenceTotalLatencyNanoseconds: sink.totalLatencyNanoseconds,
            coherenceMaximumLatencyNanoseconds: sink.maximumLatencyNanoseconds,
            coherenceRequestBytes: sink.receivedBytes,
            coherenceAcknowledgementBytes: sink.acknowledgementBytes,
            coherenceTerminalFailureLatched: sink.terminalFailureLatched
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? Self.writeAtomically(data, to: outputPath)
    }

    private func sum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { left, right in
            let (value, overflow) = left.addingReportingOverflow(right)
            return overflow ? UInt64.max : value
        }
    }

    private static func writeAtomically(_ data: Data, to path: String) throws {
        let temporary = path + ".tmp.\(getpid())"
        _ = unlink(temporary)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { unlink(temporary) }
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    raw.baseAddress?.advanced(by: offset),
                    raw.count - offset
                )
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary, path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        succeeded = true
    }
}
