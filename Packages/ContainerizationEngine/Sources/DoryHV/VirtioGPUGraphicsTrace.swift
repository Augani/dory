import Foundation

/// Immutable ownership identity supplied by the runtime when it enables graphics tracing.
/// Machine and operation IDs deliberately stay opaque: the device records correlations without
/// learning daemon-owned identity formats.
public struct VirtioGPUGraphicsTraceContext: Codable, Equatable, Sendable {
    public let machineID: String
    public let operationID: String
    public let workerGeneration: UInt64

    public init(machineID: String, operationID: String, workerGeneration: UInt64) {
        self.machineID = machineID
        self.operationID = operationID
        self.workerGeneration = workerGeneration
    }
}

/// A bounded, machine-readable graphics boundary. A trace event is an observation, not a claim
/// that a shader executed or a drawable became visible; campaign evidence must establish those
/// later boundaries separately.
public struct VirtioGPUGraphicsTraceEvent: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case scanoutProgress
        case scanoutFailure
        case scanoutPublished
        case hostSubmissionAccepted
        case hostSubmissionRejected
    }

    public let sequence: UInt64
    public let monotonicNanoseconds: UInt64
    public let context: VirtioGPUGraphicsTraceContext
    public let stage: Stage
    public let resourceID: UInt32?
    public let displayResourceGeneration: UInt64?
    public let rendererResourceGeneration: UInt64?
    public let deviceGeneration: UInt64?
    public let contextID: UInt32?
    public let frameSequence: UInt64?
    public let fenceID: UInt64?
    public let scanoutID: UInt32?
    public let width: UInt32?
    public let height: UInt32?
    public let stride: UInt32?
    public let format: UInt32?
    public let detail: String

    public init(
        sequence: UInt64,
        monotonicNanoseconds: UInt64,
        context: VirtioGPUGraphicsTraceContext,
        stage: Stage,
        resourceID: UInt32? = nil,
        displayResourceGeneration: UInt64? = nil,
        rendererResourceGeneration: UInt64? = nil,
        deviceGeneration: UInt64? = nil,
        contextID: UInt32? = nil,
        frameSequence: UInt64? = nil,
        fenceID: UInt64? = nil,
        scanoutID: UInt32? = nil,
        width: UInt32? = nil,
        height: UInt32? = nil,
        stride: UInt32? = nil,
        format: UInt32? = nil,
        detail: String = ""
    ) {
        self.sequence = sequence
        self.monotonicNanoseconds = monotonicNanoseconds
        self.context = context
        self.stage = stage
        self.resourceID = resourceID
        self.displayResourceGeneration = displayResourceGeneration
        self.rendererResourceGeneration = rendererResourceGeneration
        self.deviceGeneration = deviceGeneration
        self.contextID = contextID
        self.frameSequence = frameSequence
        self.fenceID = fenceID
        self.scanoutID = scanoutID
        self.width = width
        self.height = height
        self.stride = stride
        self.format = format
        self.detail = detail
    }
}
