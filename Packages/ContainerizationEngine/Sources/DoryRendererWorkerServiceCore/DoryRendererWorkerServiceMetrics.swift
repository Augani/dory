/// Monotonic worker-boundary evidence. Command-stream bytes count descriptor-backed submit3D
/// regions, while XPC control bytes count only the bounded metadata frame. Accelerated scanout is
/// inadmissible if a later backend ever records a copied byte; the current service has no API that
/// can turn a copy into a production capability.
public struct DoryRendererWorkerServiceMetrics: Equatable, Sendable {
    public let xpcBatchCount: UInt64
    public let xpcControlBytes: UInt64
    public let descriptorBackedCommandBytes: UInt64
    public let totalAdmissionLatencyNanoseconds: UInt64
    public let maximumAdmissionLatencyNanoseconds: UInt64
    public let currentQueueDepth: Int
    public let maximumQueueDepth: Int
    public let backpressureRejections: UInt64
    public let replayRejections: UInt64
    public let scanoutCopyBytes: UInt64

    public init(
        xpcBatchCount: UInt64,
        xpcControlBytes: UInt64,
        descriptorBackedCommandBytes: UInt64,
        totalAdmissionLatencyNanoseconds: UInt64,
        maximumAdmissionLatencyNanoseconds: UInt64,
        currentQueueDepth: Int,
        maximumQueueDepth: Int,
        backpressureRejections: UInt64,
        replayRejections: UInt64,
        scanoutCopyBytes: UInt64
    ) {
        self.xpcBatchCount = xpcBatchCount
        self.xpcControlBytes = xpcControlBytes
        self.descriptorBackedCommandBytes = descriptorBackedCommandBytes
        self.totalAdmissionLatencyNanoseconds = totalAdmissionLatencyNanoseconds
        self.maximumAdmissionLatencyNanoseconds = maximumAdmissionLatencyNanoseconds
        self.currentQueueDepth = currentQueueDepth
        self.maximumQueueDepth = maximumQueueDepth
        self.backpressureRejections = backpressureRejections
        self.replayRejections = replayRejections
        self.scanoutCopyBytes = scanoutCopyBytes
    }
}
