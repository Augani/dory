import CryptoKit
import Darwin
import DoryCore
import DoryOperations
import Foundation

public enum DockerTierState: String, Sendable {
    case stopped
    case starting
    case running
    case sleeping
    case failed
}

/// Exact identity of a committed tier lifecycle transition. Epoch correlation prevents delayed
/// observer work from satisfying a request that belongs to a newer engine generation.
struct DockerTierLifecycleEvent: Sendable, Equatable {
    let epoch: UInt64
    let state: DockerTierState
}

public struct DockerTierStatus: Sendable {
    public var state: DockerTierState
    public var socketPath: String
    public var hvPID: Int32?
    public var lastError: String?
    /// True while endpoint and helper retirement is executing outside the tier lock. The existing
    /// state enum remains source-compatible with service/UI consumers; callers that need exact
    /// lifecycle truth can distinguish an in-progress stop from a terminal failure here.
    public var isStopping: Bool
}

public struct DoryGuestResourceSnapshot: Sendable, Equatable {
    /// The verified selected Dory drive whose ext4 image supplied this guest filesystem.
    public var selectedDataDriveID: UUID
    public var dataDiskFilesystemUUID: UUID
    public var dataDiskMountSource: String
    public var dataDiskFilesystemType: String
    public var dataDiskDeviceMajorMinor: String
    public var memoryCeilingBytes: UInt64
    public var memoryUsedBytes: UInt64
    public var memoryCacheBytes: UInt64
    /// Linux's `MemAvailable`: the kernel's estimate of memory usable for new work without swap.
    public var memoryAvailableBytes: UInt64
    public var memoryFreeBytes: UInt64
    public var dataDiskTotalBytes: UInt64
    public var dataDiskUsedBytes: UInt64
    public var dataDiskAvailableBytes: UInt64

    /// Compatibility view of the memory the guest can reclaim beyond pages Linux reports as
    /// immediately free. New callers should consume `memoryAvailableBytes` directly because it is
    /// the kernel's `MemAvailable` estimate used by Dory's pressure policy.
    @available(*, deprecated, message: "Use memoryAvailableBytes (Linux MemAvailable) instead")
    public var memoryReclaimableBytes: UInt64 {
        get {
            memoryAvailableBytes.saturatingSubtracting(memoryFreeBytes)
        }
        set {
            memoryAvailableBytes = min(
                memoryCeilingBytes,
                memoryFreeBytes.saturatingAdding(newValue)
            )
            memoryUsedBytes = memoryCeilingBytes.saturatingSubtracting(memoryAvailableBytes)
        }
    }
}

/// Legacy host-share telemetry contract retained for source and decoding compatibility. The
/// file-service telemetry record supersedes it and exposes the bounded worker/coherence metrics
/// used by current health policy.
@available(*, deprecated, message: "Use DoryFileServiceResourceSnapshot instead")
public struct DoryHostShareResourceSnapshot: Codable, Sendable, Equatable {
    public struct Batcher: Codable, Sendable, Equatable {
        public var pendingCount: Int
        public var pendingLimit: Int
        public var pendingRequiresRescan: Bool
        public var receivedEventCount: UInt64
        public var deliveredBatchCount: UInt64
        public var failedBatchCount: UInt64
        public var rescanCollapseCount: UInt64
    }

    public var schema: String
    public var version: Int
    public var generatedAt: Date
    public var configuredRoots: [String]
    public var observationRoots: [String]
    public var running: Bool
    public var flushScheduled: Bool
    public var consecutiveFailures: Int
    public var batcher: Batcher
}

/// Host-side identity of the exact selected ext4 image expected at `/dev/vdb` in the managed guest.
public struct DockerGuestDataDiskAuthority: Sendable, Equatable {
    public let dataDriveID: UUID
    public let filesystemUUID: UUID
    /// Canonical host path and stable descriptor identity of the selected ext4 image. These are
    /// optional only for source compatibility with non-managed/test callers; managed launches
    /// that perform guest disk attestation require the complete identity and fail closed otherwise.
    public let diskImagePath: String?
    public let diskImageDevice: UInt64?
    public let diskImageInode: UInt64?

    public init(dataDriveID: UUID, filesystemUUID: UUID) {
        self.dataDriveID = dataDriveID
        self.filesystemUUID = filesystemUUID
        self.diskImagePath = nil
        self.diskImageDevice = nil
        self.diskImageInode = nil
    }

    public init(
        dataDriveID: UUID,
        filesystemUUID: UUID,
        diskImagePath: String,
        diskImageDevice: UInt64,
        diskImageInode: UInt64
    ) {
        self.dataDriveID = dataDriveID
        self.filesystemUUID = filesystemUUID
        self.diskImagePath = diskImagePath
        self.diskImageDevice = diskImageDevice
        self.diskImageInode = diskImageInode
    }

    fileprivate var hasStableDiskImageIdentity: Bool {
        diskImagePath?.hasPrefix("/") == true
            && diskImageDevice != nil
            && diskImageInode != nil
    }
}

private struct DockerGuestDataDiskBinding: Sendable, Equatable {
    let authority: DockerGuestDataDiskAuthority
    let mountSource: String
    let filesystemType: String
    let deviceMajorMinor: String
}

/// Host identity captured before a managed helper may open the selected Docker image. A brand-new
/// sparse image legitimately has no filesystem UUID until the guest formats it, but its selected
/// drive, canonical path, device, and inode are already stable authority and must not change across
/// that first boot.
private struct DockerGuestDataDiskHostIdentity: Sendable, Equatable {
    let dataDriveID: UUID
    let filesystemUUID: UUID?
    let diskImagePath: String
    let diskImageDevice: UInt64
    let diskImageInode: UInt64

    func permits(
        _ authority: DockerGuestDataDiskAuthority,
        expectedFilesystemUUID: UUID
    ) -> Bool {
        dataDriveID == authority.dataDriveID
            && diskImagePath == authority.diskImagePath
            && diskImageDevice == authority.diskImageDevice
            && diskImageInode == authority.diskImageInode
            && authority.filesystemUUID == expectedFilesystemUUID
            && (filesystemUUID == nil || filesystemUUID == expectedFilesystemUUID)
    }
}

private final class DockerGuestDataDiskLaunchAuthority: @unchecked Sendable {
    let helperGeneration: UUID
    let hostIdentity: DockerGuestDataDiskHostIdentity
    let expectedFilesystemUUID: UUID
    let diskFile: DockerDataDiskFileAuthority?
    let trustedDataDriveRoot: DoryTrustedDirectoryRoot?
    let engineDirectory: DoryTrustedDirectoryHandle?
    let dataDriveLock: EngineStateDirectoryLock?
    let dataDriveSelectionAuthority: DoryDataDriveSelectionAuthority?

    init(
        helperGeneration: UUID,
        hostIdentity: DockerGuestDataDiskHostIdentity,
        expectedFilesystemUUID: UUID,
        diskFile: DockerDataDiskFileAuthority?,
        trustedDataDriveRoot: DoryTrustedDirectoryRoot?,
        engineDirectory: DoryTrustedDirectoryHandle?,
        dataDriveLock: EngineStateDirectoryLock?,
        dataDriveSelectionAuthority: DoryDataDriveSelectionAuthority?
    ) {
        self.helperGeneration = helperGeneration
        self.hostIdentity = hostIdentity
        self.expectedFilesystemUUID = expectedFilesystemUUID
        self.diskFile = diskFile
        self.trustedDataDriveRoot = trustedDataDriveRoot
        self.engineDirectory = engineDirectory
        self.dataDriveLock = dataDriveLock
        self.dataDriveSelectionAuthority = dataDriveSelectionAuthority
    }
}

private struct DockerGuestDataDiskVerifiedBinding: Sendable, Equatable {
    let lifecycleEpoch: UInt64
    let helperGeneration: UUID?
    let binding: DockerGuestDataDiskBinding
}

/// One exact engine generation around a guest resource exec. The helper reference prevents a
/// stopped generation's late reply from being accepted after a replacement helper is published.
private struct DockerGuestResourceProbeLifecycle {
    let epoch: UInt64
    let state: DockerTierState
    let helper: (any DockerManagedProcess)?
    let helperGeneration: UUID?
    let dataDiskLaunchAuthority: DockerGuestDataDiskLaunchAuthority?
}

public struct DoryFileServiceResourceSnapshot: Codable, Sendable, Equatable {
    public var schema: String
    public var version: Int
    public var generatedAt: Date
    public var running: Bool
    public var cacheMode: String
    public var maximumCacheValiditySeconds: Double
    public var configuredShareCount: Int
    public var invalidationOnlyShareCount: Int
    public var watcherNudgeShareCount: Int
    public var frontendCount: Int
    public var requestQueueCount: Int
    public var observationRequired: Bool
    public var observationActive: Bool
    public var requiredObservationShareCount: Int
    public var observedRequiredShareCount: Int
    public var observationStreamCount: Int
    public var pendingEventCount: Int
    public var pendingEventLimit: Int
    public var receivedEventCount: UInt64
    public var deliveredBatchCount: UInt64
    public var failedBatchCount: UInt64
    public var eventLossCount: UInt64
    public var invalidationCount: UInt64
    public var invalidationFailureCount: UInt64
    public var invalidationFailureLatched: Bool
    public var rejectedRequestCount: UInt64
    public var executedRequestCount: UInt64
    public var terminalQueueFaultCount: UInt64
    public var completedRequestCount: UInt64
    public var failedRequestCount: UInt64
    public var inFlightRequestCount: UInt64
    public var peakInFlightRequestCount: UInt64
    public var requestPayloadBytes: UInt64
    public var workerResponsePayloadBytes: UInt64
    public var guestPublishedResponseBytes: UInt64
    public var totalRequestLatencyNanoseconds: UInt64
    public var maximumRequestLatencyNanoseconds: UInt64
    public var coherenceReceivedBatchCount: UInt64
    public var coherenceReplayedBatchCount: UInt64
    public var coherenceInFlightBatchCount: Int
    public var coherenceFailedBatchCount: UInt64
    public var coherenceTotalLatencyNanoseconds: UInt64
    public var coherenceMaximumLatencyNanoseconds: UInt64
    public var coherenceRequestBytes: UInt64
    public var coherenceAcknowledgementBytes: UInt64
    public var coherenceTerminalFailureLatched: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, version, generatedAt, running, cacheMode, maximumCacheValiditySeconds
        case configuredShareCount, invalidationOnlyShareCount, watcherNudgeShareCount
        case frontendCount, requestQueueCount, observationRequired, observationActive
        case requiredObservationShareCount, observedRequiredShareCount, observationStreamCount
        case pendingEventCount, pendingEventLimit, receivedEventCount, deliveredBatchCount
        case failedBatchCount, eventLossCount, invalidationCount, invalidationFailureCount
        case invalidationFailureLatched, rejectedRequestCount, executedRequestCount
        case terminalQueueFaultCount, completedRequestCount, failedRequestCount
        case inFlightRequestCount, peakInFlightRequestCount, requestPayloadBytes
        case workerResponsePayloadBytes, guestPublishedResponseBytes
        case totalRequestLatencyNanoseconds, maximumRequestLatencyNanoseconds
        case coherenceReceivedBatchCount, coherenceReplayedBatchCount
        case coherenceInFlightBatchCount, coherenceFailedBatchCount
        case coherenceTotalLatencyNanoseconds, coherenceMaximumLatencyNanoseconds
        case coherenceRequestBytes, coherenceAcknowledgementBytes
        case coherenceTerminalFailureLatched
    }

    static let exactJSONKeys = Set(CodingKeys.allCases.map(\.rawValue))
}

public struct DockerTierConfiguration: Sendable {
    public var home: String
    public var forwardSocketPath: String
    public var dockerdSocketPath: String?
    public var cid: UInt32
    public var dockerPort: UInt32
    public var gpuSupported: Bool
    public var activitySocketPath: String?
    public var hvProcess: HvProcessConfiguration?
    public var vmmProcess: VmmDockerProcessConfiguration?
    public var agentControl: AgentControlConfiguration?

    public init(
        home: String = NSHomeDirectory(),
        forwardSocketPath: String,
        dockerdSocketPath: String? = nil,
        cid: UInt32 = 3,
        dockerPort: UInt32 = 1026,
        gpuSupported: Bool = false,
        activitySocketPath: String? = nil,
        hvProcess: HvProcessConfiguration? = nil,
        vmmProcess: VmmDockerProcessConfiguration? = nil,
        agentControl: AgentControlConfiguration? = nil
    ) {
        self.home = home
        self.forwardSocketPath = forwardSocketPath
        self.dockerdSocketPath = dockerdSocketPath
        self.cid = cid
        self.dockerPort = dockerPort
        self.gpuSupported = gpuSupported
        self.activitySocketPath = activitySocketPath
        self.hvProcess = hvProcess
        self.vmmProcess = vmmProcess
        self.agentControl = agentControl
    }

    public var hasManagedHelper: Bool {
        hvProcess != nil || vmmProcess != nil
    }
}

public typealias DockerContainerActivityProbe = @Sendable (DockerTierConfiguration) -> DockerContainerActivity
public typealias DockerReadyWaiter = @Sendable (
    DockerTierConfiguration,
    TimeInterval,
    @escaping @Sendable () -> Bool
) -> Bool

struct DockerManagedProcessObservation: Sendable, Equatable {
    let pid: Int32?
    /// `true` means the supervisor still owns a live generation or exact terminal-retirement
    /// authority. `false` is published only after the supervisor can prove neither remains.
    let isRunning: Bool
}

protocol DockerManagedProcess: AnyObject, Sendable {
    func start() throws
    func suspend() -> Bool
    func resume() -> Bool
    @discardableResult func stop() -> Bool
    func waitForTermination(timeout: TimeInterval) -> Bool
    /// One mutex-coherent process snapshot, bounded by the caller's absolute monotonic deadline.
    /// `nil` is unknown/contended and must be treated as retained authority, never as stopped.
    func lifecycleObservation(until deadline: DispatchTime) -> DockerManagedProcessObservation?
}

extension HvProcess: DockerManagedProcess {
    @discardableResult
    public func stop() -> Bool {
        stop(signal: SIGTERM, timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
    }
}

extension VmmDockerProcess: DockerManagedProcess {
    @discardableResult
    public func stop() -> Bool {
        stop(signal: SIGTERM, timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
    }
}

/// Couples one exact helper object to the daemon-side resources admitted for that generation.
/// Every existing active/teardown/retiring lifecycle collection already retains the helper, so
/// this wrapper also keeps the selected-drive lock and original disk descriptor alive until exact
/// terminal observation—without a second, independently drifting authority collection.
private final class DockerManagedProcessGeneration: DockerManagedProcess, @unchecked Sendable {
    private let process: any DockerManagedProcess
    private let dataDiskLaunchAuthority: DockerGuestDataDiskLaunchAuthority

    init(
        process: any DockerManagedProcess,
        dataDiskLaunchAuthority: DockerGuestDataDiskLaunchAuthority
    ) {
        self.process = process
        self.dataDiskLaunchAuthority = dataDiskLaunchAuthority
    }

    func start() throws { try process.start() }
    func suspend() -> Bool { process.suspend() }
    func resume() -> Bool { process.resume() }
    func stop() -> Bool { process.stop() }
    func waitForTermination(timeout: TimeInterval) -> Bool {
        process.waitForTermination(timeout: timeout)
    }
    func lifecycleObservation(
        until deadline: DispatchTime
    ) -> DockerManagedProcessObservation? {
        process.lifecycleObservation(until: deadline)
    }
}

public final class DockerTier: @unchecked Sendable {
    public enum TierError: Error, CustomStringConvertible {
        case alreadyRunning
        case sleepingDataplaneRequiresWakeSupport
        case suspendFailed(pid: Int32?)
        case resumeFailed(pid: Int32?)
        case readyTimeout
        case helperExited(String)
        case helperTerminationPending
        case promotionTimeout
        case startCancelled
        case daemonShuttingDown
        case notRunning
        case wakeFailed(String)
        case repairUnavailable(String)
        case readinessStageFailed(stage: DoryReadinessStageID, detail: String)

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "docker tier is already running"
            case .sleepingDataplaneRequiresWakeSupport:
                return "sleeping docker dataplane requires an idle controller, activity socket, and managed dory-hv process"
            case .suspendFailed(let pid):
                return "failed to suspend dory-hv\(pid.map { " pid \($0)" } ?? "")"
            case .resumeFailed(let pid):
                return "failed to resume dory-hv\(pid.map { " pid \($0)" } ?? "")"
            case .readyTimeout:
                return "docker tier did not become ready after wake"
            case .helperExited(let detail):
                return "docker tier helper \(detail)"
            case .helperTerminationPending:
                return "docker tier helper termination is still being verified"
            case .promotionTimeout:
                return "docker tier did not reach running state before the promotion deadline"
            case .startCancelled:
                return "docker tier start was cancelled"
            case .daemonShuttingDown:
                return "docker tier cannot start while doryd is shutting down"
            case .notRunning:
                return "docker tier is not running"
            case .wakeFailed(let message):
                return message.isEmpty ? "docker tier did not wake" : message
            case .repairUnavailable(let message):
                return message
            case let .readinessStageFailed(stage, detail):
                return "\(stage.title) readiness failed: \(detail)"
            }
        }
    }

    // A cold fresh-start boots the kernel, mounts the rootfs, initializes the docker data disk on
    // first use, and starts dockerd/containerd — legitimately tens of seconds. Too short a ready
    // window tears the engine down mid-boot; the next request restarts the cold boot, so an empty
    // engine never comes up (boot loop). Resume from a suspended helper is near-instant, so it keeps
    // a short window.
    private static let freshStartReadyTimeout: TimeInterval = 180
    private static let resumeReadyTimeout: TimeInterval = 10
    /// Status and lifecycle reconciliation must never inherit a helper launch's 30-45 second
    /// mutex hold. A contended observation fails closed after this small monotonic window.
    private static let managedProcessObservationSeconds: TimeInterval = 0.025

    /// One exact teardown generation. Claiming moves all endpoint/helper authority into this
    /// object under `lock`; cleanup then runs without that lock, while concurrent stops join this
    /// completion and lifecycle promotion remains excluded.
    private final class TeardownOperation: @unchecked Sendable {
        let epoch: UInt64
        let dataplane: DoryDataplaneHandle?
        let activityServer: DataplaneActivityServer?
        let wakeTask: Task<Void, Never>?
        let restartWorkItem: DispatchWorkItem?
        let helpers: [any DockerManagedProcess]
        let readinessCycle: EngineReadinessCycleToken
        let markStopped: Bool
        let publishStoppedIntent: Bool

        private let completion = DispatchGroup()
        private let resultLock = NSLock()
        private var storedResult: Bool?

        init(
            epoch: UInt64,
            dataplane: DoryDataplaneHandle?,
            activityServer: DataplaneActivityServer?,
            wakeTask: Task<Void, Never>?,
            restartWorkItem: DispatchWorkItem?,
            helpers: [any DockerManagedProcess],
            readinessCycle: EngineReadinessCycleToken,
            markStopped: Bool,
            publishStoppedIntent: Bool
        ) {
            self.epoch = epoch
            self.dataplane = dataplane
            self.activityServer = activityServer
            self.wakeTask = wakeTask
            self.restartWorkItem = restartWorkItem
            self.helpers = helpers
            self.readinessCycle = readinessCycle
            self.markStopped = markStopped
            self.publishStoppedIntent = publishStoppedIntent
            completion.enter()
        }

        func contains(_ helper: any DockerManagedProcess) -> Bool {
            helpers.contains { $0 === helper }
        }

        func finish(result: Bool) {
            resultLock.lock()
            precondition(storedResult == nil, "teardown operation completed more than once")
            storedResult = result
            resultLock.unlock()
            completion.leave()
        }

        func wait(until deadline: DispatchTime = .distantFuture) -> Bool? {
            guard completion.wait(timeout: deadline) == .success else { return nil }
            resultLock.lock()
            let result = storedResult
            resultLock.unlock()
            return result
        }
    }

    private final class RetainedHelperRecoveryPlan: @unchecked Sendable {
        let token: UUID
        let epoch: UInt64
        let helpers: [any DockerManagedProcess]
        let restart: DispatchWorkItem?
        let restartDelay: TimeInterval
        let terminalFailureDetail: String

        init(
            token: UUID,
            epoch: UInt64,
            helpers: [any DockerManagedProcess],
            restart: DispatchWorkItem?,
            restartDelay: TimeInterval,
            terminalFailureDetail: String
        ) {
            self.token = token
            self.epoch = epoch
            self.helpers = helpers
            self.restart = restart
            self.restartDelay = restartDelay
            self.terminalFailureDetail = terminalFailureDetail
        }
    }

    /// Exact authority for one host-only dataplane replacement. The guest helper remains owned by
    /// the tier, while the old and candidate host endpoints stay private to this operation until a
    /// lifecycle-coherent commit. Stop/terminal shutdown supersede it by advancing the epoch; the
    /// latch is released only after this operation has retired every socket it could have bound.
    private final class HostDataplaneRepairOperation: @unchecked Sendable {
        let epoch: UInt64
        let helper: (any DockerManagedProcess)?
        let helperGeneration: UUID?
        let previousDataplane: DoryDataplaneHandle?
        let previousActivityServer: DataplaneActivityServer?
        let readinessCycle: EngineReadinessCycleToken

        private let completion = DispatchGroup()
        private let completionLock = NSLock()
        private var didFinish = false

        init(
            epoch: UInt64,
            helper: (any DockerManagedProcess)?,
            helperGeneration: UUID?,
            previousDataplane: DoryDataplaneHandle?,
            previousActivityServer: DataplaneActivityServer?,
            readinessCycle: EngineReadinessCycleToken
        ) {
            self.epoch = epoch
            self.helper = helper
            self.helperGeneration = helperGeneration
            self.previousDataplane = previousDataplane
            self.previousActivityServer = previousActivityServer
            self.readinessCycle = readinessCycle
            completion.enter()
        }

        func finish() {
            completionLock.lock()
            precondition(!didFinish, "host dataplane repair completed more than once")
            didFinish = true
            completionLock.unlock()
            completion.leave()
        }

        func notify(on queue: DispatchQueue, execute work: @escaping @Sendable () -> Void) {
            completion.notify(queue: queue, execute: work)
        }
    }

    private let configuration: DockerTierConfiguration
    private let containerActivityProbe: DockerContainerActivityProbe
    private let dockerReadyWaiter: DockerReadyWaiter
    private let beforeDataplaneStart: @Sendable () -> Void
    private let guestDataDiskAuthorityProvider:
        @Sendable (String) throws -> DockerGuestDataDiskAuthority
    private let guestDataDiskLaunchAuthorityProvider:
        @Sendable (String, String, UUID) throws -> DockerGuestDataDiskLaunchAuthority
    private let socket: DorySocket
    private let idleController: IdleController?
    private let agentControl: AgentControl?
    private let portPublisher: PortPublisher?
    private let publishedPortRepairClient: PublishedPortRepairClient
    private let readinessTracker = EngineReadinessTracker()
    private let supervisorQueue = DispatchQueue(label: "dev.dory.doryd.docker-tier-supervisor")
    private let lifecycleObserverQueue = DispatchQueue(
        label: "dev.dory.doryd.docker-tier-lifecycle-observer"
    )
    private let lock = DoryProcessLifecycleMutex()
    private var dataplane: DoryDataplaneHandle?
    private var activityServer: DataplaneActivityServer?
    private var helperProcess: (any DockerManagedProcess)?
    private var managedProcessFactory:
        (@Sendable (UUID, HvProcessUnexpectedTerminationHandler?) -> (any DockerManagedProcess)?)?
    /// Exact helpers whose bounded SIGKILL window expired. Retaining these objects prevents a new
    /// engine generation from reusing its disk/socket authority until terminal observation.
    private var retiringHelpers: [any DockerManagedProcess] = []
    private var state: DockerTierState = .stopped
    private var lastError: String?
    private var wakeTask: Task<Void, Never>?
    private var activeHelperGeneration: UUID?
    private var activeGuestDataDiskLaunchAuthority: DockerGuestDataDiskLaunchAuthority?
    private var helperStartedAt: Date?
    private var unexpectedRestartCount = 0
    private var lifecycleEpoch: UInt64 = 0
    private var restartWorkItem: DispatchWorkItem?
    private var terminalShutdown = false
    private var lifecycleStateObserver: @Sendable (DockerTierLifecycleEvent) -> Void = { _ in }
    private var promotionWaiters: [UUID: DispatchSemaphore] = [:]
    private var activeTeardown: TeardownOperation?
    /// Serializes endpoint ownership without holding `lock` across handle shutdown, socket probes,
    /// or replacement startup. A newer lifecycle cannot publish endpoints until cleanup finishes.
    private var activeHostDataplaneRepair: HostDataplaneRepairOperation?
    /// Exact unexpected-loss retirement being observed asynchronously. Explicit stop/shutdown
    /// clears the token before claiming the retained helpers, so a late terminal callback cannot
    /// resurrect recovery after a newer control decision.
    private var retainedHelperRecoveryToken: UUID?
    /// Exact lightweight-dataplane launch whose socket cleanup has not retired yet. Ordinary stop
    /// may invalidate its lifecycle while `startDataplane()` is outside the tier lock; keeping this
    /// authority latched until cleanup completes prevents a replacement bind from being unlinked.
    private var activeSleepingDataplaneLaunchEpoch: UInt64?
    /// Exact within-generation guest mount binding. A fresh helper boot may legitimately receive a
    /// different Linux `dev_t`; the host image launch authority remains independently exact.
    private var verifiedGuestDataDiskBinding: DockerGuestDataDiskVerifiedBinding?

    public init(
        configuration: DockerTierConfiguration,
        idleController: IdleController? = nil,
        agentControl injectedAgentControl: AgentControl? = nil,
        portPublisher injectedPortPublisher: PortPublisher? = nil,
        containerActivityProbe: @escaping DockerContainerActivityProbe = { configuration in
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                return DockerEngineProbe.containerActivity(socketPath: dockerdSocketPath)
            }
            return DockerEngineProbe.containerActivity(
                    forwardSocketPath: configuration.forwardSocketPath,
                    cid: configuration.cid,
                    dockerPort: configuration.dockerPort
                )
        },
        dockerReadyWaiter: @escaping DockerReadyWaiter = { configuration, timeout, shouldContinue in
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                return DockerEngineProbe.waitUntilReady(
                    socketPath: dockerdSocketPath,
                    timeout: timeout,
                    shouldContinue: shouldContinue
                )
            }
            return DockerEngineProbe.waitUntilReady(
                forwardSocketPath: configuration.forwardSocketPath,
                cid: configuration.cid,
                dockerPort: configuration.dockerPort,
                timeout: timeout,
                shouldContinue: shouldContinue
            )
        },
        beforeDataplaneStart: @escaping @Sendable () -> Void = {},
        publishedPortRepairClient: PublishedPortRepairClient = PublishedPortRepairClient(),
        dataDriveSelectionAuthority: DoryDataDriveSelectionAuthority? = nil,
        dataDriveTrustedRoot: DoryTrustedDirectoryRoot? = nil,
        newGuestDataDiskFilesystemUUID: @escaping @Sendable () -> UUID = { UUID() },
        guestDataDiskAuthorityProvider:
            (@Sendable (String) throws -> DockerGuestDataDiskAuthority)? = nil
    ) {
        self.configuration = configuration
        self.containerActivityProbe = containerActivityProbe
        self.dockerReadyWaiter = dockerReadyWaiter
        self.beforeDataplaneStart = beforeDataplaneStart
        self.publishedPortRepairClient = publishedPortRepairClient
        if let guestDataDiskAuthorityProvider {
            self.guestDataDiskAuthorityProvider = guestDataDiskAuthorityProvider
            self.guestDataDiskLaunchAuthorityProvider = { home, _, helperGeneration in
                let authority = try guestDataDiskAuthorityProvider(home)
                return DockerGuestDataDiskLaunchAuthority(
                    helperGeneration: helperGeneration,
                    hostIdentity: try Self.hostIdentity(
                        from: authority
                    ),
                    expectedFilesystemUUID: authority.filesystemUUID,
                    diskFile: nil,
                    trustedDataDriveRoot: nil,
                    engineDirectory: nil,
                    dataDriveLock: nil,
                    dataDriveSelectionAuthority: nil
                )
            }
        } else {
            self.guestDataDiskAuthorityProvider = { home in
                try Self.selectedGuestDataDiskAuthority(
                    home: home,
                    dataDriveTrustedRoot: dataDriveTrustedRoot
                )
            }
            self.guestDataDiskLaunchAuthorityProvider = { home, configuredPath, helperGeneration in
                try Self.prepareSelectedGuestDataDiskLaunchAuthority(
                    home: home,
                    configuredPath: configuredPath,
                    helperGeneration: helperGeneration,
                    dataDriveSelectionAuthority: dataDriveSelectionAuthority,
                    dataDriveTrustedRoot: dataDriveTrustedRoot,
                    newFilesystemUUID: newGuestDataDiskFilesystemUUID
                )
            }
        }
        self.idleController = idleController
        self.socket = DorySocket(home: configuration.home)
        if let injectedAgentControl {
            self.agentControl = injectedAgentControl
            self.portPublisher = injectedPortPublisher ?? PortPublisher()
        } else if let agentConfiguration = configuration.agentControl {
            self.agentControl = AgentControl(configuration: agentConfiguration)
            self.portPublisher = PortPublisher()
        } else {
            self.agentControl = nil
            self.portPublisher = nil
        }
        cleanupStaleHelpers()
    }

    private static func selectedGuestDataDiskAuthority(
        home: String,
        dataDriveTrustedRoot: DoryTrustedDirectoryRoot?
    ) throws -> DockerGuestDataDiskAuthority {
        let selectionStore: DoryDataDriveSelectionStore
        do {
            selectionStore = try DoryDataDriveSelectionStore(home: home)
        } catch {
            throw TierError.repairUnavailable(
                "selected Docker data-drive authority is unavailable: \(error)"
            )
        }
        let pinned: (
            selection: DoryDataDriveSelection,
            drive: DoryDataDrive,
            root: DoryTrustedDirectoryRoot,
            manifest: DoryDataDriveManifest
        )
        do {
            pinned = try pinnedSelectedDataDrive(
                selectionStore: selectionStore,
                dataDriveTrustedRoot: dataDriveTrustedRoot
            )
        } catch let error as TierError {
            throw error
        } catch {
            throw TierError.repairUnavailable(
                "selected Docker data drive is unavailable: \(error)"
            )
        }
        do {
            let engineDirectory = try pinned.root.openPrivateChildDirectory(
                try DoryTrustedPathComponent(validating: "engine")
            )
            let diskFile = try DockerDataDisk.openAdmittedFile(
                in: engineDirectory,
                fileName: "docker-data.ext4",
                minimumBytes: DockerDataDisk.blankDiskBytes
            )
            let identity = try diskFile.withBorrowedDescriptor { descriptor in
                try inspectGuestDataDiskHostIdentity(
                    dataDriveID: pinned.manifest.id,
                    descriptor: descriptor,
                    path: pinned.drive.engineDataDiskPath,
                    allowUninitializedSparseBlank: false
                )
            }
            guard let filesystemUUID = identity.filesystemUUID else {
                throw TierError.repairUnavailable(
                    "selected Docker data disk does not contain a complete ext4 superblock"
                )
            }
            return DockerGuestDataDiskAuthority(
                dataDriveID: identity.dataDriveID,
                filesystemUUID: filesystemUUID,
                diskImagePath: identity.diskImagePath,
                diskImageDevice: identity.diskImageDevice,
                diskImageInode: identity.diskImageInode
            )
        } catch let error as TierError {
            throw error
        } catch {
            throw TierError.repairUnavailable(
                "selected Docker data-disk identity is unavailable: \(error)"
            )
        }
    }

    /// Materializes only the private sparse host file before a managed helper starts. Formatting
    /// remains guest-owned, but the exact selected path/device/inode is pinned before the helper
    /// can touch it and is reconciled with the resulting ext4 UUID before readiness is published.
    private static func prepareSelectedGuestDataDiskLaunchAuthority(
        home: String,
        configuredPath: String,
        helperGeneration: UUID,
        dataDriveSelectionAuthority injectedSelectionAuthority:
            DoryDataDriveSelectionAuthority?,
        dataDriveTrustedRoot: DoryTrustedDirectoryRoot?,
        newFilesystemUUID: @Sendable () -> UUID
    ) throws -> DockerGuestDataDiskLaunchAuthority {
        let selectionStore: DoryDataDriveSelectionStore
        do {
            selectionStore = try DoryDataDriveSelectionStore(home: home)
        } catch {
            throw TierError.repairUnavailable(
                "selected Docker data-drive authority is unavailable: \(error)"
            )
        }
        let drive: DoryDataDrive
        let trustedRoot: DoryTrustedDirectoryRoot
        let manifest: DoryDataDriveManifest
        let selectionAuthority: DoryDataDriveSelectionAuthority
        do {
            if let injectedSelectionAuthority {
                try selectionStore.validateAuthority(injectedSelectionAuthority)
                selectionAuthority = injectedSelectionAuthority
            } else {
                selectionAuthority = try selectionStore.acquireAuthority()
            }
            let pinned = try pinnedSelectedDataDrive(
                selectionStore: selectionStore,
                dataDriveTrustedRoot: dataDriveTrustedRoot
            )
            drive = pinned.drive
            trustedRoot = pinned.root
            manifest = pinned.manifest
        } catch let error as TierError {
            throw error
        } catch {
            throw TierError.repairUnavailable(
                "selected Docker data drive is unavailable: \(error)"
            )
        }
        guard drive.engineDataDiskPath == configuredPath else {
            throw TierError.repairUnavailable(
                "selected Docker data disk differs from the managed helper launch path"
            )
        }
        do {
            let driveLock = try EngineStateDirectoryLock(
                trustedDirectoryRoot: trustedRoot,
                lockFileName: "drive.lock"
            )
            let engineDirectory = try trustedRoot.openPrivateChildDirectory(
                try DoryTrustedPathComponent(validating: "engine")
            )
            let diskFile = try DockerDataDisk.prepareAdmittedFile(
                in: engineDirectory,
                fileName: "docker-data.ext4"
            )
            let identity = try diskFile.withBorrowedDescriptor { descriptor in
                try inspectGuestDataDiskHostIdentity(
                    dataDriveID: manifest.id,
                    descriptor: descriptor,
                    path: configuredPath,
                    allowUninitializedSparseBlank: true
                )
            }
            let expectedFilesystemUUID = identity.filesystemUUID ?? newFilesystemUUID()
            return DockerGuestDataDiskLaunchAuthority(
                helperGeneration: helperGeneration,
                hostIdentity: identity,
                expectedFilesystemUUID: expectedFilesystemUUID,
                diskFile: diskFile,
                trustedDataDriveRoot: trustedRoot,
                engineDirectory: engineDirectory,
                dataDriveLock: driveLock,
                dataDriveSelectionAuthority: selectionAuthority
            )
        } catch {
            throw TierError.repairUnavailable(
                "could not prepare the selected Docker data disk before launch: \(error)"
            )
        }
    }

    /// Resolves the selected namespace once, pins it with a no-follow directory walk, then validates
    /// both the APFS placement and manifest identity while that exact root remains current. All
    /// later descendants are opened from the retained descriptor rather than reopening the path.
    private static func pinnedSelectedDataDrive(
        selectionStore: DoryDataDriveSelectionStore,
        dataDriveTrustedRoot: DoryTrustedDirectoryRoot?
    ) throws -> (
        selection: DoryDataDriveSelection,
        drive: DoryDataDrive,
        root: DoryTrustedDirectoryRoot,
        manifest: DoryDataDriveManifest
    ) {
        guard let selection = try selectionStore.read(),
              selection.phase == .ready,
              let selectedPath = try selectionStore.selectedPath() else {
            throw TierError.repairUnavailable("Dory has no verified selected data drive")
        }
        let drive = try DoryDataDrive(home: selectionStore.home, overrideRoot: selectedPath)
        let root: DoryTrustedDirectoryRoot
        if let dataDriveTrustedRoot {
            guard dataDriveTrustedRoot.canonicalPath == drive.root else {
                throw TierError.repairUnavailable(
                    "selected Docker data drive differs from the daemon's pinned drive root"
                )
            }
            _ = try dataDriveTrustedRoot.revalidateRootPathname()
            root = dataDriveTrustedRoot
        } else {
            root = try DoryTrustedDirectoryRoot(canonicalAbsolutePath: drive.root)
        }
        guard try drive.inspect() == .ready else {
            throw TierError.repairUnavailable("selected Docker data drive is unavailable")
        }
        _ = try root.revalidateRootPathname()
        let manifest = try drive.readManifest(in: root)
        guard manifest.id == selection.driveID,
              manifest.volume?.uuid == selection.volumeUUID else {
            throw TierError.repairUnavailable(
                "selected Docker data-drive manifest changed during descriptor admission"
            )
        }
        return (selection, drive, root, manifest)
    }

    private static func hostIdentity(
        from authority: DockerGuestDataDiskAuthority
    ) throws -> DockerGuestDataDiskHostIdentity {
        guard authority.hasStableDiskImageIdentity,
              let diskImagePath = authority.diskImagePath,
              let diskImageDevice = authority.diskImageDevice,
              let diskImageInode = authority.diskImageInode else {
            throw TierError.repairUnavailable(
                "selected Docker data disk has no stable host-file identity"
            )
        }
        return DockerGuestDataDiskHostIdentity(
            dataDriveID: authority.dataDriveID,
            filesystemUUID: authority.filesystemUUID,
            diskImagePath: diskImagePath,
            diskImageDevice: diskImageDevice,
            diskImageInode: diskImageInode
        )
    }

    /// Reads the ext4 identity from one no-follow descriptor. Geometry and ownership are checked
    /// on that same descriptor so a replaced, truncated, linked, or foreign image cannot become
    /// the authority for a guest capacity record.
    static func inspectGuestDataDiskAuthority(
        dataDriveID: UUID,
        at path: String
    ) throws -> DockerGuestDataDiskAuthority {
        let identity = try inspectGuestDataDiskHostIdentity(
            dataDriveID: dataDriveID,
            at: path,
            allowUninitializedSparseBlank: false
        )
        guard let filesystemUUID = identity.filesystemUUID else {
            throw TierError.repairUnavailable(
                "selected Docker data disk does not contain a complete ext4 superblock"
            )
        }
        return DockerGuestDataDiskAuthority(
            dataDriveID: identity.dataDriveID,
            filesystemUUID: filesystemUUID,
            diskImagePath: identity.diskImagePath,
            diskImageDevice: identity.diskImageDevice,
            diskImageInode: identity.diskImageInode
        )
    }

    private static func inspectGuestDataDiskHostIdentity(
        dataDriveID: UUID,
        at path: String,
        allowUninitializedSparseBlank: Bool
    ) throws -> DockerGuestDataDiskHostIdentity {
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw TierError.repairUnavailable(
                "could not open the selected Docker data disk: errno \(errno)"
            )
        }
        defer { close(descriptor) }

        return try inspectGuestDataDiskHostIdentity(
            dataDriveID: dataDriveID,
            descriptor: descriptor,
            path: path,
            allowUninitializedSparseBlank: allowUninitializedSparseBlank
        )
    }

    private static func inspectGuestDataDiskHostIdentity(
        dataDriveID: UUID,
        descriptor: Int32,
        path: String,
        allowUninitializedSparseBlank: Bool
    ) throws -> DockerGuestDataDiskHostIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0,
              status.st_nlink == 1 else {
            throw TierError.repairUnavailable(
                "selected Docker data disk is not a private owned regular file"
            )
        }

        var superblock = [UInt8](repeating: 0, count: 1_024)
        let readCount = superblock.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, $0.count, off_t(1_024))
        }
        guard readCount == superblock.count else {
            throw TierError.repairUnavailable(
                "selected Docker data disk does not contain a complete ext4 superblock"
            )
        }
        if superblock[0x38] != 0x53 || superblock[0x39] != 0xEF {
            guard allowUninitializedSparseBlank,
                  status.st_blocks == 0,
                  status.st_size >= DockerDataDisk.blankDiskBytes else {
                throw TierError.repairUnavailable(
                    "selected Docker data disk does not contain a complete ext4 superblock"
                )
            }
            return DockerGuestDataDiskHostIdentity(
                dataDriveID: dataDriveID,
                filesystemUUID: nil,
                diskImagePath: path,
                diskImageDevice: UInt64(status.st_dev),
                diskImageInode: UInt64(status.st_ino)
            )
        }

        func littleEndianUInt32(at offset: Int) -> UInt32 {
            UInt32(superblock[offset])
                | (UInt32(superblock[offset + 1]) << 8)
                | (UInt32(superblock[offset + 2]) << 16)
                | (UInt32(superblock[offset + 3]) << 24)
        }
        let logBlockSize = littleEndianUInt32(at: 0x18)
        guard logBlockSize <= 6 else {
            throw TierError.repairUnavailable("selected Docker ext4 block size is invalid")
        }
        let blockSize = UInt64(1_024) << UInt64(logBlockSize)
        let featureIncompat = littleEndianUInt32(at: 0x60)
        let blocksLow = UInt64(littleEndianUInt32(at: 0x04))
        let blocksHigh = featureIncompat & 0x80 != 0
            ? UInt64(littleEndianUInt32(at: 0x150))
            : 0
        let blocks = blocksLow | (blocksHigh << 32)
        let requiredBytes = blocks.multipliedReportingOverflow(by: blockSize)
        guard blocks > 0,
              !requiredBytes.overflow,
              requiredBytes.partialValue <= UInt64(Int64.max),
              status.st_size >= 0,
              UInt64(status.st_size) >= requiredBytes.partialValue else {
            throw TierError.repairUnavailable("selected Docker ext4 image is truncated")
        }

        let uuidBytes = Array(superblock[0x68..<(0x68 + 16)])
        guard uuidBytes.contains(where: { $0 != 0 }) else {
            throw TierError.repairUnavailable("selected Docker ext4 UUID is missing")
        }
        let ranges = [0..<4, 4..<6, 6..<8, 8..<10, 10..<16]
        let encoded = ranges.map { range in
            uuidBytes[range].map { String(format: "%02x", Int($0)) }.joined()
        }.joined(separator: "-")
        guard let uuid = UUID(uuidString: encoded),
              encoded == uuid.uuidString.lowercased() else {
            throw TierError.repairUnavailable("selected Docker ext4 UUID is invalid")
        }
        return DockerGuestDataDiskHostIdentity(
            dataDriveID: dataDriveID,
            filesystemUUID: uuid,
            diskImagePath: path,
            diskImageDevice: UInt64(status.st_dev),
            diskImageInode: UInt64(status.st_ino)
        )
    }

    private func configuredGuestDataDiskImagePath() throws -> String {
        let arguments = configuration.vmmProcess?.arguments
            ?? configuration.hvProcess?.arguments
            ?? []
        var roots: [String] = []
        for index in arguments.indices where arguments[index] == "--data-drive" {
            guard arguments.indices.contains(index + 1) else {
                throw TierError.repairUnavailable(
                    "managed helper data-drive launch argument has no value"
                )
            }
            roots.append(arguments[index + 1])
        }
        guard roots.count == 1,
              let root = roots.first,
              root.hasPrefix("/"),
              root != "/",
              !root.hasSuffix("/"),
              !root.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              URL(fileURLWithPath: root).standardizedFileURL.path == root else {
            throw TierError.repairUnavailable(
                "managed helper does not have one canonical data-drive launch authority"
            )
        }
        return root + "/engine/docker-data.ext4"
    }

    private func guestDataDiskLaunchAuthority(
        helperGeneration: UUID
    ) throws -> DockerGuestDataDiskLaunchAuthority? {
        guard configuration.hasManagedHelper else { return nil }
        let arguments = configuration.vmmProcess?.arguments
            ?? configuration.hvProcess?.arguments
            ?? []
        guard arguments.contains("--data-drive") else {
            // Generic injected/development helpers without the Docker disk contract remain valid.
            // A guest-agent-backed Docker helper, however, cannot publish resource readiness
            // without one exact selected disk.
            guard agentControl == nil else {
                throw TierError.repairUnavailable(
                    "managed Docker helper has no data-drive launch authority"
                )
            }
            return nil
        }
        let configuredPath = try configuredGuestDataDiskImagePath()
        let authority = try guestDataDiskLaunchAuthorityProvider(
            configuration.home,
            configuredPath,
            helperGeneration
        )
        guard authority.helperGeneration == helperGeneration,
              authority.hostIdentity.diskImagePath == configuredPath else {
            throw TierError.repairUnavailable(
                "selected Docker data disk is not the exact image configured for this helper generation"
            )
        }
        return authority
    }

    /// Called in strict lifecycle commit order on a private serial queue after the committing code
    /// releases the tier lock. Observers may safely call back into DockerTier.
    public func setLifecycleStateObserver(
        _ observer: @escaping @Sendable (DockerTierState) -> Void
    ) {
        setLifecycleEventObserver { event in observer(event.state) }
    }

    /// Package-internal event observer used by doryd to bind durable desired-state writes to the
    /// exact lifecycle generation that committed them.
    func setLifecycleEventObserver(
        _ observer: @escaping @Sendable (DockerTierLifecycleEvent) -> Void
    ) {
        lock.lock()
        lifecycleStateObserver = observer
        lock.unlock()
    }

    func currentLifecycleEvent() -> DockerTierLifecycleEvent {
        lock.lock()
        defer { lock.unlock() }
        return DockerTierLifecycleEvent(epoch: lifecycleEpoch, state: state)
    }

    /// Internal dependency seam for deterministic supervisor lifecycle tests. Production always
    /// leaves this unset and constructs the configured VMM/HV process below.
    func installManagedProcessFactory(
        _ factory: @escaping @Sendable (
            UUID,
            HvProcessUnexpectedTerminationHandler?
        ) -> (any DockerManagedProcess)?
    ) {
        lock.lock()
        precondition(
            state == .stopped && helperProcess == nil && retiringHelpers.isEmpty,
            "managed process factory must be installed before the tier starts"
        )
        managedProcessFactory = factory
        lock.unlock()
    }

    public var socketPath: String {
        socket.path
    }

    private static func managedProcessObservationDeadline() -> DispatchTime {
        .now() + managedProcessObservationSeconds
    }

    private static func observeManagedProcess(
        _ helper: (any DockerManagedProcess)?,
        until deadline: DispatchTime
    ) -> DockerManagedProcessObservation? {
        helper?.lifecycleObservation(until: deadline)
    }

    private static func observeManagedProcess(
        _ helper: (any DockerManagedProcess)?
    ) -> DockerManagedProcessObservation? {
        observeManagedProcess(helper, until: managedProcessObservationDeadline())
    }

    public func status() -> DockerTierStatus {
        let statusDeadline = Self.managedProcessObservationDeadline()
        reconcileManagedHelperLiveness(until: statusDeadline)
        guard lock.lock(until: statusDeadline) else {
            return DockerTierStatus(
                state: .failed,
                socketPath: socket.path,
                hvPID: nil,
                lastError: "docker tier lifecycle snapshot exceeded its bounded observation window",
                isStopping: false
            )
        }
        let teardown = activeTeardown
        let currentHelper = helperProcess
        let retainedHelpers = retiringHelpers
        let currentState = state
        let currentError = lastError
        lock.unlock()

        // Process accessors are deliberately outside the tier lock. A helper implementation may
        // need to synchronize with its termination handler; status must remain responsive while
        // teardown cleanup is blocked in another subsystem.
        let observationDeadline = statusDeadline
        let currentObservation = Self.observeManagedProcess(
            currentHelper,
            until: observationDeadline
        )
        let teardownObservations = teardown?.helpers.compactMap {
            Self.observeManagedProcess($0, until: observationDeadline)
        } ?? []
        let retainedObservations = retainedHelpers.compactMap {
            Self.observeManagedProcess($0, until: observationDeadline)
        }
        let helperPID = currentObservation?.pid
            ?? teardownObservations.lazy.compactMap(\.pid).first
            ?? retainedObservations.lazy.compactMap(\.pid).first
        let reportedState: DockerTierState
        let reportedError: String?
        if teardown != nil {
            reportedState = .failed
            reportedError = "docker tier teardown is in progress"
        } else if !retainedHelpers.isEmpty {
            // A bounded stop exhausted its grace window. The exact helper remains authoritative
            // until terminal observation; never collapse that state to stopped/sleeping merely
            // because its PID became temporarily unavailable to the status snapshot.
            reportedState = .failed
            reportedError = currentError ?? TierError.helperTerminationPending.description
        } else if currentState == .running,
                  configuration.hasManagedHelper,
                  currentObservation?.isRunning != true {
            // A child can cross the exit boundary between the liveness reconciliation above and
            // this snapshot. Never publish a logically impossible `running` + no-child status.
            reportedState = .failed
            reportedError = currentError ?? "managed helper is no longer running"
        } else {
            reportedState = currentState
            reportedError = currentError
        }
        return DockerTierStatus(
            state: reportedState,
            socketPath: socket.path,
            hvPID: helperPID,
            lastError: reportedError,
            isStopping: teardown != nil
        )
    }

    public func readinessSnapshot(now: Date = Date()) -> DoryReadinessSnapshot {
        readinessTracker.snapshot(now: now)
    }

    /// Publish the Docker socket and activity listener without starting the heavy VM.
    ///
    /// This is doryd's lightweight launch shape: Docker clients can connect to `dory.sock`
    /// immediately, and the app or the first meaningful Docker request promotes it to a live helper.
    public func armSleeping() throws {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        reconcileRetiringHelpers()
        lock.lock()
        guard !terminalShutdown else {
            lock.unlock()
            throw TierError.daemonShuttingDown
        }
        guard activeTeardown == nil,
              activeHostDataplaneRepair == nil,
              activeSleepingDataplaneLaunchEpoch == nil,
              retiringHelpers.isEmpty,
              helperProcess == nil else {
            lock.unlock()
            throw TierError.helperTerminationPending
        }
        if dataplane != nil {
            if state == .stopped {
                setStateLocked(.sleeping)
                idleController?.setSleeping(true)
            }
            lock.unlock()
            return
        }
        guard idleController != nil,
              configuration.activitySocketPath != nil,
              configuration.hasManagedHelper else {
            lock.unlock()
            throw TierError.sleepingDataplaneRequiresWakeSupport
        }
        restartWorkItem?.cancel()
        restartWorkItem = nil
        lifecycleEpoch &+= 1
        let armEpoch = lifecycleEpoch
        let readinessCycle = readinessTracker.currentCycleToken()
        unexpectedRestartCount = 0
        activeHelperGeneration = nil
        activeGuestDataDiskLaunchAuthority = nil
        helperStartedAt = nil
        activeSleepingDataplaneLaunchEpoch = armEpoch
        setStateLocked(.starting)
        lastError = nil
        lock.unlock()

        try completeSleepingDataplaneArm(
            epoch: armEpoch,
            readinessCycle: readinessCycle
        )
    }

    /// Completes an already-reserved sleeping dataplane launch. The caller owns
    /// `activeSleepingDataplaneLaunchEpoch == epoch` before entering and that reservation remains
    /// live across every cleanup/start operation, so a replacement lifecycle cannot bind a socket
    /// that this operation may subsequently unlink.
    private func completeSleepingDataplaneArm(
        epoch armEpoch: UInt64,
        readinessCycle: EngineReadinessCycleToken
    ) throws {
        do {
            let resources = try startDataplane()
            lock.lock()
            guard !terminalShutdown,
                  lifecycleEpoch == armEpoch,
                  activeSleepingDataplaneLaunchEpoch == armEpoch,
                  state == .starting else {
                lock.unlock()
                resources.handle.shutdown()
                resources.activityServer?.stop()
                throw TierError.startCancelled
            }
            dataplane = resources.handle
            activityServer = resources.activityServer
            activeSleepingDataplaneLaunchEpoch = nil
            helperProcess = nil
            setStateLocked(.sleeping)
            wakeTask = nil
            activeHelperGeneration = nil
            activeGuestDataDiskLaunchAuthority = nil
            helperStartedAt = nil
            lastError = nil
            idleController?.setSleeping(true)
            lock.unlock()
            readinessTracker.markStopped(
                cycle: readinessCycle,
                detail: "engine is idle-sleeping; host socket remains armed"
            )
        } catch {
            lock.lock()
            let terminallyCancelled = terminalShutdown
            let ownsSocketCleanupAuthority = activeSleepingDataplaneLaunchEpoch == armEpoch
            let ownsLifecycle = !terminallyCancelled
                && lifecycleEpoch == armEpoch
                && state == .starting
            if ownsLifecycle {
                setStateLocked(.failed)
                lastError = "\(error)"
            }
            lock.unlock()
            if ownsSocketCleanupAuthority {
                removeRuntimeSockets()
                lock.lock()
                if activeSleepingDataplaneLaunchEpoch == armEpoch {
                    activeSleepingDataplaneLaunchEpoch = nil
                }
                lock.unlock()
            }
            if ownsLifecycle {
                idleController?.setSleeping(false)
            }
            throw error
        }
    }

    public func start() throws {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        reconcileRetiringHelpers()
        lock.lock()
        guard !terminalShutdown else {
            lock.unlock()
            throw TierError.daemonShuttingDown
        }
        guard activeTeardown == nil,
              activeHostDataplaneRepair == nil,
              activeSleepingDataplaneLaunchEpoch == nil,
              retiringHelpers.isEmpty else {
            lock.unlock()
            throw TierError.helperTerminationPending
        }
        if state == .starting {
            // A manual start during supervised backoff promotes the queued recovery to an
            // immediate foreground start. A helper that is already launching remains exclusive.
            guard helperProcess == nil, let queuedRestart = restartWorkItem else {
                lock.unlock()
                throw TierError.alreadyRunning
            }
            queuedRestart.cancel()
            restartWorkItem = nil
        }
        if dataplane != nil {
            if state == .sleeping {
                unexpectedRestartCount = 0
                lock.unlock()
                wakeSynchronously()
                try requireRunningAfterWake()
                return
            }
            lock.unlock()
            throw TierError.alreadyRunning
        }
        if let existingHelper = helperProcess {
            guard Self.observeManagedProcess(existingHelper)?.isRunning == false else {
                lock.unlock()
                throw TierError.helperTerminationPending
            }
            helperProcess = nil
            activeHelperGeneration = nil
            activeGuestDataDiskLaunchAuthority = nil
            helperStartedAt = nil
        }
        restartWorkItem?.cancel()
        restartWorkItem = nil
        lifecycleEpoch &+= 1
        let startEpoch = lifecycleEpoch
        unexpectedRestartCount = 0
        activeHelperGeneration = nil
        activeGuestDataDiskLaunchAuthority = nil
        helperStartedAt = nil
        let readinessCycle = readinessTracker.beginCycle(trigger: "cold-start")
        setStateLocked(.starting)
        lastError = nil
        lock.unlock()

        try launchFreshTier(epoch: startEpoch, readinessCycle: readinessCycle)
    }

    /// Promote every recoverable lifecycle shape to one confirmed running state.
    ///
    /// App opens, explicit XPC start/wake calls, and runtime-mode changes all use this operation.
    /// It waits behind an in-flight cold wake instead of racing a second helper launch, and it can
    /// restart a tier that an explicit engine stop left fully stopped.
    public func promoteToRunning(timeout: TimeInterval = 240) throws {
        let deadline = Date().addingTimeInterval(max(1, timeout))
        var attemptedPromotion = false

        while true {
            let snapshot = status()
            switch snapshot.state {
            case .running:
                return
            case .starting:
                guard waitForPromotionStateChange(until: deadline) else {
                    throw TierError.promotionTimeout
                }
                continue
            case .sleeping, .stopped, .failed:
                guard !attemptedPromotion else {
                    throw TierError.wakeFailed(
                        snapshot.lastError ?? "docker tier stopped before promotion completed"
                    )
                }
                attemptedPromotion = true
                do {
                    try start()
                } catch {
                    let afterStart = status()
                    guard afterStart.state == .starting else { throw error }
                }
            }
            guard Date() < deadline else { throw TierError.promotionTimeout }
        }
    }

    /// Must be called with `lock` held. Promotion waiters are one-shot: every terminal transition
    /// wakes all callers, which then inspect the authoritative state and either return or register
    /// for the next lifecycle. This removes the old 50 ms state-promotion poll without coupling
    /// clients to the helper implementation.
    private func setStateLocked(_ newState: DockerTierState) {
        state = newState
        guard newState != .starting, !promotionWaiters.isEmpty else { return }
        let waiters = promotionWaiters.values
        promotionWaiters.removeAll()
        for waiter in waiters { waiter.signal() }
    }

    /// Enqueue while holding `lock`; the serial queue preserves the same total order as lifecycle
    /// commits, while the callback itself cannot execute under the tier lock.
    private func enqueueLifecycleStateObserverLocked(_ committedState: DockerTierState) {
        let observer = lifecycleStateObserver
        let event = DockerTierLifecycleEvent(epoch: lifecycleEpoch, state: committedState)
        lifecycleObserverQueue.async {
            observer(event)
        }
    }

    /// Revalidate retained process authority without calling an external process implementation
    /// under the tier lock. Identity and lifecycle epoch are checked again before removal.
    private func reconcileRetiringHelpers() {
        lock.lock()
        guard activeTeardown == nil, !retiringHelpers.isEmpty else {
            lock.unlock()
            return
        }
        let epoch = lifecycleEpoch
        let snapshot = retiringHelpers
        lock.unlock()

        let observationDeadline = Self.managedProcessObservationDeadline()
        let terminalIdentities = Set(snapshot.compactMap { helper -> ObjectIdentifier? in
            guard Self.observeManagedProcess(helper, until: observationDeadline)?.isRunning == false
            else { return nil }
            return ObjectIdentifier(helper)
        })
        guard !terminalIdentities.isEmpty else { return }

        lock.lock()
        guard activeTeardown == nil, lifecycleEpoch == epoch else {
            lock.unlock()
            return
        }
        retiringHelpers.removeAll { terminalIdentities.contains(ObjectIdentifier($0)) }
        if retiringHelpers.isEmpty {
            retainedHelperRecoveryToken = nil
        }
        lock.unlock()
    }

    /// Must be called with `lock` held. Preserve the exact supervisor when a bounded stop cannot
    /// confirm exit, and make that uncertainty visible instead of publishing a stopped lifecycle.
    private func retainUnconfirmedHelperLocked(
        _ helper: any DockerManagedProcess,
        context: String
    ) {
        if !retiringHelpers.contains(where: { $0 === helper }) {
            retiringHelpers.append(helper)
        }
        restartWorkItem?.cancel()
        restartWorkItem = nil
        retainedHelperRecoveryToken = nil
        activeHelperGeneration = nil
        activeGuestDataDiskLaunchAuthority = nil
        helperStartedAt = nil
        setStateLocked(.failed)
        lastError = "\(context): \(TierError.helperTerminationPending.description)"
        idleController?.setSleeping(false)
    }

    /// Stop outside the tier lock, then atomically preserve an exact helper whose exit could not
    /// be confirmed. Lifecycle guards keep replacement launches excluded during the stop window;
    /// the retained authority closes the remaining window before a caller can observe success.
    @discardableResult
    private func stopManagedHelperAndRetainIfNeeded(
        _ helper: (any DockerManagedProcess)?,
        context: String
    ) -> Bool {
        guard let helper else { return true }

        lock.lock()
        if let teardown = activeTeardown, teardown.contains(helper) {
            lock.unlock()
            return teardown.wait() ?? false
        }
        let expectedEpoch = lifecycleEpoch
        let expectedGeneration = helperProcess === helper ? activeHelperGeneration : nil
        let wasCurrent = helperProcess === helper
        let wasRetiring = retiringHelpers.contains { $0 === helper }
        lock.unlock()

        let reportedTerminated = helper.stop()
        guard !reportedTerminated else { return true }
        // The bounded stop result and terminal transition can cross. A separately bounded,
        // mutex-coherent observation keeps stale false results from manufacturing retained
        // authority without waiting behind the same long launch mutex a second time. Unknown is
        // retained fail-closed and the deferred supervisor stop will resolve it asynchronously.
        guard Self.observeManagedProcess(helper)?.isRunning != false else { return true }

        lock.lock()
        if let teardown = activeTeardown, teardown.contains(helper) {
            lock.unlock()
            return teardown.wait() ?? false
        }
        let isStillCurrent = wasCurrent
            && lifecycleEpoch == expectedEpoch
            && helperProcess === helper
            && activeHelperGeneration == expectedGeneration
        let isStillRetiring = wasRetiring && retiringHelpers.contains { $0 === helper }
        guard isStillCurrent || isStillRetiring else {
            lock.unlock()
            return false
        }
        if isStillCurrent {
            helperProcess = nil
        }
        retainUnconfirmedHelperLocked(helper, context: context)
        wakeTask = nil
        lock.unlock()
        return false
    }

    private func waitForPromotionStateChange(until deadline: Date) -> Bool {
        lock.lock()
        guard state == .starting else {
            lock.unlock()
            return true
        }
        let id = UUID()
        let waiter = DispatchSemaphore(value: 0)
        promotionWaiters[id] = waiter
        lock.unlock()

        let remaining = max(0, deadline.timeIntervalSinceNow)
        let result = waiter.wait(timeout: .now() + remaining)
        if result == .timedOut {
            lock.lock()
            promotionWaiters.removeValue(forKey: id)
            let changed = state != .starting
            lock.unlock()
            return changed
        }
        return true
    }

    private func validateGuestPrerequisites(
        helper: (any DockerManagedProcess)?,
        readinessCycle: EngineReadinessCycleToken
    ) throws {
        guard configuration.hasManagedHelper else {
            for stage in [DoryReadinessStageID.guestAgent, .mountsDataDisk, .network] {
                readinessTracker.inactive(
                    stage,
                    cycle: readinessCycle,
                    code: "\(stage.rawValue).external_backend",
                    detail: "No managed guest is configured"
                )
            }
            return
        }
        guard let agentControl else {
            // Development/test configurations can deliberately omit the agent endpoint. Shipping
            // configurations always provide one; keep the test backend explicit instead of
            // fabricating active probe evidence.
            for stage in [DoryReadinessStageID.guestAgent, .mountsDataDisk, .network] {
                readinessTracker.inactive(
                    stage,
                    cycle: readinessCycle,
                    code: "\(stage.rawValue).probe_unconfigured",
                    detail: "Guest readiness probe endpoint is not configured"
                )
            }
            return
        }

        readinessTracker.begin(
            .guestAgent,
            cycle: readinessCycle,
            deadlineSeconds: 30
        )
        let agentDeadline = Date().addingTimeInterval(30)
        var lastAgentError = "guest agent did not answer"
        while Date() < agentDeadline {
            guard Self.observeManagedProcess(helper)?.isRunning == true else {
                throw TierError.helperExited("exited before the guest agent became ready")
            }
            do {
                let info = try agentControl.info()
                readinessTracker.ready(
                    .guestAgent,
                    cycle: readinessCycle,
                    code: "guestAgent.rpc_ready",
                    detail: "agent protocol \(info.protocolVersion), build \(info.agentBuild)"
                )
                lastAgentError = ""
                break
            } catch {
                lastAgentError = "\(error)"
                agentControl.disconnect()
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        guard lastAgentError.isEmpty else {
            throw TierError.readinessStageFailed(stage: .guestAgent, detail: lastAgentError)
        }

        readinessTracker.begin(
            .mountsDataDisk,
            cycle: readinessCycle,
            deadlineSeconds: 10
        )
        let resourceSnapshot: DoryGuestResourceSnapshot
        do {
            resourceSnapshot = try verifiedGuestResourceSnapshot(
                agentControl: agentControl,
                timeoutMs: 10_000,
                requiredState: .starting
            )
        } catch {
            throw TierError.readinessStageFailed(
                stage: .mountsDataDisk,
                detail: "\(error)"
            )
        }
        readinessTracker.ready(
            .mountsDataDisk,
            cycle: readinessCycle,
            code: "mounts.data_disk_ready",
            detail: "verified /dev/vdb ext4 \(resourceSnapshot.dataDiskFilesystemUUID.uuidString.lowercased()) "
                + "at /var/lib/docker (\(resourceSnapshot.dataDiskDeviceMajorMinor))"
        )

        readinessTracker.begin(
            .network,
            cycle: readinessCycle,
            deadlineSeconds: 10
        )
        let network = try agentControl.exec(
            argv: [
                "/bin/sh", "-eu", "-c",
                "ip route show default | grep -q . && test -s /etc/resolv.conf",
            ],
            timeoutMs: 10_000,
            outputLimitBytes: 64 * 1024
        )
        guard network.exitCode == 0 else {
            throw TierError.readinessStageFailed(
                stage: .network,
                detail: Self.execFailureDetail(network)
            )
        }
        readinessTracker.ready(
            .network,
            cycle: readinessCycle,
            code: "network.route_resolver_ready",
            detail: "guest default route and resolver configuration are present"
        )
    }

    private static func execFailureDetail(_ result: DoryExecResult) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = stderr.isEmpty ? stdout : stderr
        return output.isEmpty ? "guest probe exited \(result.exitCode)" : String(output.prefix(500))
    }

    private func readinessReasonCode(for error: Error) -> String {
        if case let TierError.readinessStageFailed(stage, _) = error {
            return "\(stage.rawValue).probe_failed"
        }
        switch error {
        case TierError.readyTimeout:
            return "dockerd.deadline_exceeded"
        case TierError.startCancelled:
            return "engine.start_cancelled"
        case TierError.helperExited:
            return "vmProcess.exited"
        default:
            return "engine.start_failed"
        }
    }

    private func validateDockerBackend(
        helper: (any DockerManagedProcess)?,
        epoch: UInt64,
        readinessCycle: EngineReadinessCycleToken,
        timeout: TimeInterval
    ) throws {
        readinessTracker.begin(
            .dockerd,
            cycle: readinessCycle,
            deadlineSeconds: timeout
        )
        let ready = dockerReadyWaiter(configuration, timeout) {
            self.freshLaunchIsActive(epoch: epoch, helper: helper)
                && Self.observeManagedProcess(helper)?.isRunning == true
        }
        guard freshLaunchIsActive(epoch: epoch, helper: helper) else {
            throw TierError.startCancelled
        }
        guard Self.observeManagedProcess(helper)?.isRunning == true else {
            throw TierError.helperExited("exited during Docker readiness")
        }
        guard ready else { throw TierError.readyTimeout }
        readinessTracker.ready(
            .dockerd,
            cycle: readinessCycle,
            code: "dockerd.version_ready",
            detail: "Docker /version returned a Linux server response"
        )
    }

    private func launchFreshTier(
        epoch: UInt64,
        readinessCycle: EngineReadinessCycleToken,
        publishFailure: Bool = true
    ) throws {
        var startedHelper: (any DockerManagedProcess)?
        var startedResources: DataplaneResources?
        do {
            let helperGeneration = UUID()
            let dataDiskLaunchAuthority = try guestDataDiskLaunchAuthority(
                helperGeneration: helperGeneration
            )
            let helper = try makeManagedProcess(
                generation: helperGeneration,
                dataDiskLaunchAuthority: dataDiskLaunchAuthority
            )
            startedHelper = helper

            // Publish the in-flight helper before start(), because VMM startup can block waiting
            // for its handoff and raw-HV startup immediately enters the Docker readiness wait.
            // A concurrent daemon shutdown must be able to find and stop either shape instead of
            // leaving a child behind until the startup call eventually returns.
            lock.lock()
            guard !terminalShutdown, lifecycleEpoch == epoch, state == .starting else {
                lock.unlock()
                throw TierError.startCancelled
            }
            helperProcess = helper
            activeHelperGeneration = helper == nil ? nil : helperGeneration
            activeGuestDataDiskLaunchAuthority = helper == nil ? nil : dataDiskLaunchAuthority
            lock.unlock()

            try helper?.start()

            guard freshLaunchIsActive(epoch: epoch, helper: helper) else {
                throw TierError.startCancelled
            }

            readinessTracker.ready(
                .vmProcess,
                cycle: readinessCycle,
                code: "vm.process_ready",
                detail: Self.observeManagedProcess(helper)?.pid
                    .map { "managed helper pid \($0) is running" }
                    ?? "in-process backend is running"
            )
            try validateGuestPrerequisites(
                helper: helper,
                readinessCycle: readinessCycle
            )

            if configuration.hasManagedHelper {
                try validateDockerBackend(
                    helper: helper,
                    epoch: epoch,
                    readinessCycle: readinessCycle,
                    timeout: Self.freshStartReadyTimeout
                )
            } else {
                readinessTracker.inactive(
                    .dockerd,
                    cycle: readinessCycle,
                    code: "dockerd.external_backend",
                    detail: "No managed Docker helper is configured"
                )
            }

            readinessTracker.begin(
                .hostSocketContext,
                cycle: readinessCycle,
                deadlineSeconds: 10
            )
            let resources = try startDataplane()
            startedResources = resources

            lock.lock()
            let ownsHelper = helper.map { helperProcess === $0 } ?? (helperProcess == nil)
            guard !terminalShutdown,
                  lifecycleEpoch == epoch,
                  state == .starting,
                  ownsHelper else {
                lock.unlock()
                throw TierError.startCancelled
            }
            if configuration.hasManagedHelper,
               Self.observeManagedProcess(helper)?.isRunning != true {
                lock.unlock()
                throw TierError.helperExited("exited while publishing the Docker socket")
            }
            activityServer = resources.activityServer
            dataplane = resources.handle
            helperStartedAt = helper == nil ? nil : Date()
            setStateLocked(.running)
            lastError = nil
            idleController?.setSleeping(false)
            enqueueLifecycleStateObserverLocked(.running)
            lock.unlock()
            readinessTracker.ready(
                .hostSocketContext,
                cycle: readinessCycle,
                code: "socket.forwarder_ready",
                detail: "Dory's same-user Docker socket is bound; host context is verified separately"
            )
            startedResources = nil
        } catch {
            readinessTracker.blockCurrent(
                cycle: readinessCycle,
                code: readinessReasonCode(for: error),
                detail: "\(error)"
            )
            startedResources?.handle.shutdown()
            startedResources?.activityServer?.stop()
            let helperTerminated = stopManagedHelperAndRetainIfNeeded(
                startedHelper,
                context: "failed Docker tier launch could not confirm helper exit"
            )

            let ownsLifecycle: Bool
            let terminallyCancelled: Bool
            lock.lock()
            terminallyCancelled = terminalShutdown
            if lifecycleEpoch == epoch {
                ownsLifecycle = true
                if let startedHelper, helperProcess === startedHelper {
                    helperProcess = nil
                }
                activeHelperGeneration = nil
                activeGuestDataDiskLaunchAuthority = nil
                helperStartedAt = nil
                if helperTerminated {
                    setStateLocked(publishFailure ? .failed : .starting)
                    lastError = "\(error)"
                }
            } else {
                ownsLifecycle = false
            }
            lock.unlock()
            if ownsLifecycle || terminallyCancelled {
                // A terminally-cancelled launch may have bound its dataplane after shutdown's
                // tearDown already unlinked the old paths. No newer lifecycle can exist once the
                // latch is set, so removing those late paths cannot unlink a replacement server.
                removeRuntimeSockets()
            }
            throw error
        }
    }

    private func freshLaunchIsActive(
        epoch: UInt64,
        helper: (any DockerManagedProcess)?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let ownsHelper = helper.map { helperProcess === $0 } ?? (helperProcess == nil)
        return !terminalShutdown
            && lifecycleEpoch == epoch
            && state == .starting
            && ownsHelper
    }

    private func requireRunningAfterWake() throws {
        lock.lock()
        let currentState = state
        let currentError = lastError
        let isTerminalShutdown = terminalShutdown
        lock.unlock()

        guard currentState == .running else {
            if isTerminalShutdown {
                throw TierError.daemonShuttingDown
            }
            if currentError == TierError.readyTimeout.description {
                throw TierError.readyTimeout
            }
            throw TierError.wakeFailed(currentError ?? "docker tier is \(currentState.rawValue)")
        }
    }

    @discardableResult
    public func stop() -> Bool {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }
        return tearDown(markStopped: true, publishStoppedIntent: true)
    }

    /// Close the one-way launch gate without waiting for endpoint or process teardown. Daemon
    /// shutdown uses this before moving the potentially blocking TERM/KILL phase to a bounded worker.
    func latchTerminalShutdown() {
        lock.lock()
        terminalShutdown = true
        lock.unlock()
    }

    /// Permanently close this tier for daemon process shutdown.
    ///
    /// Unlike ordinary engineStop/stop(), this is a one-way latch. Any XPC request that was
    /// accepted before listener invalidation, or races cleanup afterward, is prevented from
    /// spawning/resuming a helper once terminal shutdown begins.
    @discardableResult
    public func shutdown() -> Bool {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }
        return tearDown(markStopped: true, terminal: true)
    }

    /// Wait for exact helper retirement after a bounded stop could not prove terminal exit.
    ///
    /// This joins an in-flight teardown and performs bounded, lock-free liveness observations of
    /// the exact retained helper objects. It never launches or substitutes a helper. `false`
    /// preserves those objects as authoritative so daemon shutdown can retain ownership and retry.
    @discardableResult
    public func waitForTerminalRetirement(timeout: TimeInterval) -> Bool {
        let boundedTimeout = timeout.isFinite ? max(0, timeout) : 0
        let deadline = DispatchTime.now() + boundedTimeout

        while true {
            guard lock.lock(until: deadline) else { return false }
            if let teardown = activeTeardown {
                lock.unlock()
                guard teardown.wait(until: deadline) != nil else { return false }
                continue
            }
            let epoch = lifecycleEpoch
            let readinessCycle = readinessTracker.currentCycleToken()
            let currentHelperSnapshot = helperProcess
            let currentGeneration = activeHelperGeneration
            let retainedSnapshot = retiringHelpers
            var helperSnapshot: [any DockerManagedProcess] = []
            var seenHelpers: Set<ObjectIdentifier> = []
            func appendExactHelper(_ helper: (any DockerManagedProcess)?) {
                guard let helper else { return }
                let identity = ObjectIdentifier(helper)
                guard seenHelpers.insert(identity).inserted else { return }
                helperSnapshot.append(helper)
            }
            appendExactHelper(currentHelperSnapshot)
            for helper in retainedSnapshot { appendExactHelper(helper) }
            guard !helperSnapshot.isEmpty else {
                lock.unlock()
                return true
            }
            lock.unlock()

            var terminalIdentities: Set<ObjectIdentifier> = []
            for helper in helperSnapshot {
                let now = DispatchTime.now().uptimeNanoseconds
                let remainingNanoseconds = deadline.uptimeNanoseconds > now
                    ? deadline.uptimeNanoseconds - now
                    : 0
                let remaining = Double(remainingNanoseconds) / 1_000_000_000
                guard helper.waitForTermination(timeout: remaining),
                      helper.lifecycleObservation(until: deadline)?.isRunning == false else {
                    return false
                }
                terminalIdentities.insert(ObjectIdentifier(helper))
            }

            guard lock.lock(until: deadline) else { return false }
            let currentHelperStillExact: Bool
            switch (currentHelperSnapshot, helperProcess) {
            case (nil, nil):
                currentHelperStillExact = true
            case let (expected?, actual?):
                currentHelperStillExact = expected === actual
            default:
                currentHelperStillExact = false
            }
            let stillExact = activeTeardown == nil
                && lifecycleEpoch == epoch
                && currentHelperStillExact
                && activeHelperGeneration == currentGeneration
                && Set(retiringHelpers.map(ObjectIdentifier.init))
                    == Set(retainedSnapshot.map(ObjectIdentifier.init))
            if stillExact,
               let currentHelperSnapshot,
               terminalIdentities.contains(ObjectIdentifier(currentHelperSnapshot)) {
                helperProcess = nil
                activeHelperGeneration = nil
                activeGuestDataDiskLaunchAuthority = nil
                helperStartedAt = nil
            }
            if stillExact, !terminalIdentities.isEmpty {
                retiringHelpers.removeAll { terminalIdentities.contains(ObjectIdentifier($0)) }
            }
            let retired = stillExact && helperProcess == nil && retiringHelpers.isEmpty
            if retired {
                setStateLocked(.stopped)
                lastError = nil
                retainedHelperRecoveryToken = nil
            }
            lock.unlock()

            if retired {
                idleController?.setSleeping(false)
                readinessTracker.markStopped(
                    cycle: readinessCycle,
                    detail: "engine helper retirement was confirmed"
                )
                return true
            }
            guard DispatchTime.now() < deadline else { return false }
        }
    }

    @discardableResult
    public func cleanupStaleHelpers() -> [Int32] {
        var killed: [Int32] = []
        if let hvConfiguration = configuration.hvProcess,
           let stateDirectory = HelperProcessJanitor.stateDirectoryArgument(
            in: ([hvConfiguration.executablePath] + hvConfiguration.arguments).joined(separator: " ")
           ) {
            killed.append(contentsOf: HelperProcessJanitor.terminateStaleHelpers(
                executablePath: hvConfiguration.executablePath,
                stateDirectory: stateDirectory,
                timeout: DoryEngineShutdownTiming.hostTerminationSeconds
            ))
        }
        if let vmmConfiguration = configuration.vmmProcess {
            killed.append(contentsOf: HelperProcessJanitor.terminateStaleHelpers(
                executablePath: vmmConfiguration.executablePath,
                stateDirectory: vmmConfiguration.stateDirectory
            ))
        }
        return killed
    }

    public func sleepForIdle(idleAfter seconds: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock()
        let isTerminalShutdown = terminalShutdown
        lock.unlock()
        guard !isTerminalShutdown else { return false }

        if let sleptQueuedRecovery = sleepQueuedRecoveryIfPresent() {
            return sleptQueuedRecovery
        }
        return sleepForIdle(idleAfter: seconds, now: now, activity: containerActivityProbe(configuration))
    }

    /// Returns a read-only inventory through the daemon-owned private forward. It never traverses
    /// the activity-reporting public dataplane and therefore cannot extend the idle deadline.
    public func dashboardSnapshot() throws -> [String: Data] {
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else {
            throw TierError.notRunning
        }
        return try DockerEngineProbe.dashboardSnapshot(
            forwardSocketPath: configuration.forwardSocketPath,
            cid: configuration.cid,
            dockerPort: configuration.dockerPort
        )
    }

    /// An explicit sleep can race an unexpected-exit backoff. Convert the queued recovery into the
    /// ordinary lightweight sleeping dataplane; otherwise the delayed work item would violate the
    /// user's sleep decision by relaunching the VM moments later.
    private func sleepQueuedRecoveryIfPresent() -> Bool? {
        let queuedRestart: DispatchWorkItem
        let armEpoch: UInt64
        let readinessCycle: EngineReadinessCycleToken
        lock.lock()
        guard !terminalShutdown,
              activeTeardown == nil,
              activeHostDataplaneRepair == nil,
              activeSleepingDataplaneLaunchEpoch == nil,
              retiringHelpers.isEmpty,
              idleController != nil,
              configuration.activitySocketPath != nil,
              configuration.hasManagedHelper,
              state == .starting,
              helperProcess == nil,
              dataplane == nil,
              let queued = restartWorkItem else {
            lock.unlock()
            return nil
        }
        queuedRestart = queued
        restartWorkItem = nil
        lifecycleEpoch &+= 1
        armEpoch = lifecycleEpoch
        readinessCycle = readinessTracker.currentCycleToken()
        unexpectedRestartCount = 0
        activeHelperGeneration = nil
        activeGuestDataDiskLaunchAuthority = nil
        helperStartedAt = nil
        activeSleepingDataplaneLaunchEpoch = armEpoch
        setStateLocked(.starting)
        lastError = nil
        lock.unlock()

        queuedRestart.cancel()
        removeRuntimeSockets()
        do {
            try completeSleepingDataplaneArm(
                epoch: armEpoch,
                readinessCycle: readinessCycle
            )
            return true
        } catch {
            lock.lock()
            if !terminalShutdown,
               lifecycleEpoch == armEpoch,
               state == .failed {
                lastError = "could not arm sleeping tier after cancelling recovery: \(error)"
            }
            lock.unlock()
            return false
        }
    }

    private func sleepForIdle(
        idleAfter seconds: TimeInterval,
        now: Date,
        activity: DockerContainerActivity
    ) -> Bool {
        guard let idleController, configuration.hasManagedHelper else {
            return false
        }

        let claimedSleep: Bool
        switch activity {
        case .empty:
            claimedSleep = idleController.claimSleepForEmptyEngine(idleAfter: seconds, now: now)
        case .active, .unknown:
            claimedSleep = idleController.claimSleepIfIdle(idleAfter: seconds, now: now)
        }
        guard claimedSleep else {
            return false
        }

        lock.lock()
        guard activeHostDataplaneRepair == nil,
              state == .running,
              let currentHelper = helperProcess else {
            lock.unlock()
            idleController.setSleeping(false)
            return false
        }
        let idleSnapshot = idleController.snapshot
        let staleRequestAllowed = activity == .empty
        guard (idleSnapshot.activeRequests == 0 || staleRequestAllowed),
              idleSnapshot.controlOperations == 0 else {
            lock.unlock()
            idleController.setSleeping(false)
            return false
        }
        wakeTask = nil

        switch activity {
        case .empty:
            lifecycleEpoch &+= 1
            let sleepEpoch = lifecycleEpoch
            let readinessCycle = readinessTracker.currentCycleToken()
            let operation = TeardownOperation(
                epoch: sleepEpoch,
                dataplane: nil,
                activityServer: nil,
                wakeTask: nil,
                restartWorkItem: nil,
                helpers: [currentHelper],
                readinessCycle: readinessCycle,
                markStopped: false,
                publishStoppedIntent: false
            )
            activeTeardown = operation
            helperProcess = nil
            activeHelperGeneration = nil
            activeGuestDataDiskLaunchAuthority = nil
            helperStartedAt = nil
            lock.unlock()

            agentControl?.disconnect()
            let reportedTerminated = currentHelper.stop()
            let helperTerminated = reportedTerminated
                || Self.observeManagedProcess(currentHelper)?.isRunning == false

            var failedDataplane: DoryDataplaneHandle?
            var failedActivityServer: DataplaneActivityServer?
            lock.lock()
            guard activeTeardown === operation, lifecycleEpoch == sleepEpoch else {
                lock.unlock()
                operation.finish(result: false)
                return false
            }
            activeTeardown = nil
            if !helperTerminated {
                failedDataplane = dataplane
                failedActivityServer = activityServer
                dataplane = nil
                activityServer = nil
                retainUnconfirmedHelperLocked(
                    currentHelper,
                    context: "idle sleep could not confirm helper exit"
                )
            } else {
                setStateLocked(.sleeping)
                lastError = nil
                if !terminalShutdown {
                    enqueueLifecycleStateObserverLocked(.sleeping)
                }
            }
            lock.unlock()
            operation.finish(result: helperTerminated)

            if !helperTerminated {
                removeRuntimeSockets()
                failedDataplane?.shutdown()
                failedActivityServer?.stop()
                return false
            }
            return true
        case .active, .unknown:
            agentControl?.disconnect()
            guard currentHelper.suspend() else {
                setStateLocked(.running)
                lastError = TierError.suspendFailed(
                    pid: Self.observeManagedProcess(currentHelper)?.pid
                ).description
                lock.unlock()
                idleController.setSleeping(false)
                return false
            }
            setStateLocked(.sleeping)
            lastError = nil
            enqueueLifecycleStateObserverLocked(.sleeping)
            lock.unlock()
            return true
        }
    }

    public func prepareForHostSleep(now: Date = Date()) -> HostSleepActionResult {
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else {
            return HostSleepActionResult(
                name: "docker",
                attempted: false,
                slept: false,
                detail: "docker state=\(currentState.rawValue)"
            )
        }

        let activity = containerActivityProbe(configuration)
        switch activity {
        case .empty:
            let slept = sleepForIdle(idleAfter: 0, now: now, activity: activity)
            return HostSleepActionResult(
                name: "docker",
                attempted: true,
                slept: slept,
                detail: slept ? "docker engine empty; helper stopped for host sleep" : "docker engine empty; sleep claim rejected"
            )
        case .active(let count):
            return HostSleepActionResult(
                name: "docker",
                attempted: false,
                slept: false,
                detail: "docker has \(count) active container(s)"
            )
        case .unknown(let reason):
            return HostSleepActionResult(
                name: "docker",
                attempted: false,
                slept: false,
                detail: "docker activity unknown: \(reason)"
            )
        }
    }

    public func refreshPublishedPorts() throws -> PortPublishDiff? {
        guard let agentControl, let portPublisher else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }
        return try portPublisher.refresh(from: agentControl)
    }

    /// Forces dory-hv's gvproxy publisher to reconcile immediately and waits for a correlated
    /// receipt written only after dory-hv re-reads the live gvproxy registry. The VMM helper path
    /// has no signal-backed publisher and fails closed instead of signaling an unrelated process.
    public func repairPublishedPorts() throws -> PublishedPortReconcileReceipt {
        lock.lock()
        let currentState = state
        let currentHelper = helperProcess
        let helperGeneration = activeHelperGeneration
        let supportsSignal = configuration.hvProcess != nil && configuration.vmmProcess == nil
        lock.unlock()
        let helperPID = Self.observeManagedProcess(currentHelper)?.pid
        guard currentState == .running else {
            throw TierError.repairUnavailable("docker tier is \(currentState.rawValue)")
        }
        guard supportsSignal, let helperPID, let helperGeneration,
              let stateDirectory = managedHelperStateDirectory() else {
            throw TierError.repairUnavailable("dory-hv port reconciliation is unavailable")
        }
        do {
            let receipt = try publishedPortRepairClient.reconcile(
                stateDirectory: stateDirectory,
                enginePID: helperPID
            ) { [weak self] in
                guard let self else { return false }
                self.lock.lock()
                let current = self.state == .running
                    && self.activeHelperGeneration == helperGeneration
                    && self.helperProcess === currentHelper
                self.lock.unlock()
                return current
                    && Self.observeManagedProcess(currentHelper)?.pid == helperPID
            }
            // Keep guest-agent-backed diagnostic surfaces fresh, but never describe that unrelated
            // cache diff as proof of gvproxy repair.
            _ = try? refreshPublishedPorts()
            return receipt
        } catch {
            throw TierError.repairUnavailable("\(error)")
        }
    }

    public func currentPublishedPorts() -> [DoryListenPort]? {
        guard let portPublisher else { return nil }
        return portPublisher.current
    }

    public func currentDockerPublishedPorts() -> [DoryListenPort]? {
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return [] }

        let summaries: DockerContainerList
        if let dockerdSocketPath = configuration.dockerdSocketPath {
            summaries = DockerEngineProbe.containerSummaries(socketPath: dockerdSocketPath)
        } else {
            summaries = DockerEngineProbe.containerSummaries(
                forwardSocketPath: configuration.forwardSocketPath,
                cid: configuration.cid,
                dockerPort: configuration.dockerPort
            )
        }
        switch summaries {
        case let .ok(containers):
            var ports = Set<DoryListenPort>()
            for container in containers where container.isRunning {
                for port in container.ports {
                    guard let listenPort = Self.dockerPublishedPort(port) else { continue }
                    ports.insert(listenPort)
                }
            }
            return ports.sorted {
                if $0.port == $1.port { return $0.protocol < $1.protocol }
                return $0.port < $1.port
            }
        case .unavailable:
            return nil
        }
    }

    public func containerSummariesForIdle() -> DockerContainerList {
        lock.lock()
        let currentState = state
        let currentError = lastError
        lock.unlock()
        switch currentState {
        case .running:
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                return DockerEngineProbe.containerSummaries(socketPath: dockerdSocketPath)
            }
            return DockerEngineProbe.containerSummaries(
                    forwardSocketPath: configuration.forwardSocketPath,
                    cid: configuration.cid,
                    dockerPort: configuration.dockerPort
                )
        case .failed:
            return .unavailable(currentError ?? "docker tier failed")
        case .stopped, .starting, .sleeping:
            return .ok([])
        }
    }

    public func agentInfo() throws -> DoryAgentInfo? {
        guard let agentControl else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }
        return try agentControl.info()
    }

    /// Drops only the cached RPC transport and proves a fresh guest-agent request. The VM,
    /// containers, mounts, and Docker daemon remain untouched.
    public func reconnectAgent() throws -> DoryAgentInfo {
        guard let agentControl else {
            throw TierError.repairUnavailable("guest agent control is not configured")
        }
        lock.lock()
        let currentState = state
        let readinessCycle = readinessTracker.currentCycleToken()
        lock.unlock()
        guard currentState == .running else {
            throw TierError.repairUnavailable("docker tier is \(currentState.rawValue)")
        }
        return try reconnectAgent(agentControl, readinessCycle: readinessCycle)
    }

    private func reconnectAgent(
        _ agentControl: AgentControl,
        readinessCycle: EngineReadinessCycleToken
    ) throws -> DoryAgentInfo {
        agentControl.disconnect()
        do {
            let info = try agentControl.info()
            readinessTracker.ready(
                .guestAgent,
                cycle: readinessCycle,
                code: "guestAgent.reconnected",
                detail: "fresh RPC reached agent build \(info.agentBuild)"
            )
            return info
        } catch {
            readinessTracker.blocked(
                .guestAgent,
                cycle: readinessCycle,
                code: "guestAgent.reconnect_failed",
                detail: "\(error)"
            )
            throw error
        }
    }

    /// Replaces only the host forwarding socket. This is safe for running workloads because the
    /// guest VM and dockerd socket are retained; clients with an already-open broken connection may
    /// retry against the newly-bound same-user socket.
    public func repairSocketForwarder() throws -> String {
        if DockerEngineProbe.waitUntilReady(socketPath: socket.path, timeout: 1, pollInterval: 0.25) {
            return "Docker host socket is already healthy; no mutation applied"
        }

        let operation: HostDataplaneRepairOperation
        lock.lock()
        guard state == .running else {
            let current = state
            lock.unlock()
            throw TierError.repairUnavailable("docker tier is \(current.rawValue)")
        }
        guard activeTeardown == nil,
              activeHostDataplaneRepair == nil,
              activeSleepingDataplaneLaunchEpoch == nil,
              retiringHelpers.isEmpty else {
            lock.unlock()
            throw TierError.repairUnavailable("docker tier lifecycle transition is already in progress")
        }
        let currentHelper = helperProcess
        guard !configuration.hasManagedHelper || currentHelper != nil else {
            lock.unlock()
            throw TierError.repairUnavailable("managed Docker helper authority is unavailable")
        }
        let readinessCycle = readinessTracker.currentCycleToken()
        operation = HostDataplaneRepairOperation(
            epoch: lifecycleEpoch,
            helper: currentHelper,
            helperGeneration: activeHelperGeneration,
            previousDataplane: dataplane,
            previousActivityServer: activityServer,
            readinessCycle: readinessCycle
        )
        activeHostDataplaneRepair = operation
        dataplane = nil
        activityServer = nil
        lock.unlock()

        readinessTracker.begin(
            .hostSocketContext,
            cycle: operation.readinessCycle,
            deadlineSeconds: 10
        )
        var replacement: DataplaneResources?
        var failureCode = "socket.forwarder_rebind_failed"
        var failureDetail: String?
        do {
            // Handle shutdown, listener stop, socket mutation, endpoint startup, and probes are all
            // external operations and must remain outside the tier lifecycle lock.
            removeHostDataplaneSockets()
            operation.previousDataplane?.shutdown()
            operation.previousActivityServer?.stop()
            guard hostDataplaneRepairIsCurrent(operation) else {
                throw TierError.startCancelled
            }
            guard !configuration.hasManagedHelper
                    || Self.observeManagedProcess(operation.helper)?.isRunning == true else {
                throw TierError.repairUnavailable("managed Docker helper exited during socket repair")
            }

            let candidate = try startDataplane()
            replacement = candidate
            guard hostDataplaneRepairIsCurrent(operation) else {
                throw TierError.startCancelled
            }
            guard DockerEngineProbe.waitUntilReady(
                socketPath: socket.path,
                timeout: 5,
                pollInterval: 0.25
            ) else {
                failureCode = "socket.forwarder_probe_failed"
                failureDetail = "replacement socket bound, but Docker /version did not pass"
                throw TierError.repairUnavailable(
                    "replacement Docker socket did not pass /version"
                )
            }
            guard !configuration.hasManagedHelper
                    || Self.observeManagedProcess(operation.helper)?.isRunning == true else {
                throw TierError.repairUnavailable("managed Docker helper exited during socket repair")
            }

            lock.lock()
            let helperStillExact = operation.helper.map { helperProcess === $0 }
                ?? (helperProcess == nil)
            let canCommit = activeHostDataplaneRepair === operation
                && !terminalShutdown
                && lifecycleEpoch == operation.epoch
                && state == .running
                && helperStillExact
                && activeHelperGeneration == operation.helperGeneration
                && dataplane == nil
                && activityServer == nil
            if canCommit {
                dataplane = candidate.handle
                activityServer = candidate.activityServer
                activeHostDataplaneRepair = nil
                lastError = nil
            }
            lock.unlock()
            guard canCommit else { throw TierError.startCancelled }

            replacement = nil
            operation.finish()
            readinessTracker.ready(
                .hostSocketContext,
                cycle: operation.readinessCycle,
                code: "socket.forwarder_replaced",
                detail: "replaced only the host dataplane socket; VM and workloads were retained"
            )
            return "replaced the host Docker socket/forwarder without restarting the VM or dockerd"
        } catch {
            // Keep the exact repair latch while retiring every endpoint this operation could have
            // published. Only after unlinking may a stop-followed-by-start bind a replacement.
            replacement?.handle.shutdown()
            replacement?.activityServer?.stop()
            removeHostDataplaneSockets()

            lock.lock()
            let ownsRepair = activeHostDataplaneRepair === operation
            let helperStillExact = operation.helper.map { helperProcess === $0 }
                ?? (helperProcess == nil)
            let ownsLifecycle = ownsRepair
                && !terminalShutdown
                && lifecycleEpoch == operation.epoch
                && state == .running
                && helperStillExact
                && activeHelperGeneration == operation.helperGeneration
            if ownsRepair {
                activeHostDataplaneRepair = nil
            }
            if ownsLifecycle {
                lastError = "host socket forwarder repair failed: \(error)"
            }
            lock.unlock()
            operation.finish()
            readinessTracker.blocked(
                .hostSocketContext,
                cycle: operation.readinessCycle,
                code: failureCode,
                detail: failureDetail ?? "\(error)"
            )
            if let tierError = error as? TierError,
               case .startCancelled = tierError {
                throw TierError.repairUnavailable(
                    "host socket repair was superseded by a newer engine lifecycle"
                )
            }
            throw error
        }
    }

    private func hostDataplaneRepairIsCurrent(
        _ operation: HostDataplaneRepairOperation
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let helperStillExact = operation.helper.map { helperProcess === $0 }
            ?? (helperProcess == nil)
        return activeHostDataplaneRepair === operation
            && !terminalShutdown
            && lifecycleEpoch == operation.epoch
            && state == .running
            && helperStillExact
            && activeHelperGeneration == operation.helperGeneration
            && dataplane == nil
            && activityServer == nil
    }

    /// Restarts only a confirmed-dead dockerd using the root-only command captured during guest
    /// boot. A healthy API is never restarted, and the persistent data mount/VM stay in place.
    public func repairDockerDaemon(timeout: TimeInterval = 45) throws -> String {
        switch containerSummariesForIdle() {
        case .ok(let containers):
            return "Docker API is already healthy; \(containers.count) container(s) visible and no mutation applied"
        case .unavailable:
            break
        }
        guard let agentControl else {
            throw TierError.repairUnavailable("guest agent control is not configured")
        }
        lock.lock()
        let currentState = state
        let currentHelper = helperProcess
        let readinessCycle = readinessTracker.currentCycleToken()
        lock.unlock()
        guard currentState == .running,
              Self.observeManagedProcess(currentHelper)?.isRunning == true else {
            throw TierError.repairUnavailable("VM helper is not running; dockerd-only repair is unavailable")
        }

        readinessTracker.begin(.dockerd, cycle: readinessCycle, deadlineSeconds: timeout)
        _ = try reconnectAgent(agentControl, readinessCycle: readinessCycle)
        let restart = try agentControl.exec(
            argv: [
                "/bin/sh", "-eu", "-c",
                "test -x /run/dory-restart-dockerd; pids=$(pidof dockerd 2>/dev/null || true); [ -z \"$pids\" ] || kill -TERM $pids 2>/dev/null || true; n=0; while [ -n \"$(pidof dockerd 2>/dev/null || true)\" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done; [ -z \"$(pidof dockerd 2>/dev/null || true)\" ] || exit 70; nohup /run/dory-restart-dockerd </dev/null >/var/log/dockerd.log 2>&1 &",
            ],
            timeoutMs: 15_000,
            outputLimitBytes: 64 * 1024
        )
        guard restart.exitCode == 0 else {
            let detail = Self.execFailureDetail(restart)
            readinessTracker.blocked(
                .dockerd,
                cycle: readinessCycle,
                code: "dockerd.restart_failed",
                detail: detail
            )
            throw TierError.repairUnavailable(detail)
        }
        let ready = dockerReadyWaiter(configuration, timeout) { [weak self] in
            guard let self, let currentHelper else { return false }
            self.lock.lock()
            let active = self.state == .running && self.helperProcess === currentHelper
            self.lock.unlock()
            return active && Self.observeManagedProcess(currentHelper)?.isRunning == true
        }
        guard ready else {
            readinessTracker.blocked(
                .dockerd,
                cycle: readinessCycle,
                code: "dockerd.restart_deadline_exceeded",
                detail: "dockerd-only restart did not restore /version before \(Int(timeout)) seconds"
            )
            throw TierError.repairUnavailable("dockerd-only restart did not restore the Docker API")
        }
        readinessTracker.ready(
            .dockerd,
            cycle: readinessCycle,
            code: "dockerd.restarted_in_place",
            detail: "dockerd restarted in the existing VM with the existing data mount"
        )
        return "restarted only dockerd in the existing VM; data disk and VM were retained"
    }

    /// Reconciles the validated corporate pull/registry/CA contract inside the managed guest.
    /// Material lives only on guest tmpfs and is re-sent after every boot, so durable Docker data
    /// can never become a root-sourced configuration channel. A changed effective digest restarts
    /// dockerd with live-restore; an identical digest performs no mutation.
    public func applyCorporateConnectivity(
        profile: CorporateConnectivityProfile,
        validation: CorporateConnectivityValidation,
        profileDigest: String,
        timeout: TimeInterval = 45
    ) throws -> CorporateGuestApplyResult {
        guard validation.valid else {
            throw TierError.repairUnavailable("corporate connectivity profile is invalid")
        }
        guard let agentControl else {
            return CorporateGuestApplyResult(
                state: "guest agent is not configured; no guest mutation applied",
                changed: false,
                dockerdRestarted: false
            )
        }
        lock.lock()
        let currentState = state
        let currentHelper = helperProcess
        let readinessCycle = readinessTracker.currentCycleToken()
        lock.unlock()
        guard currentState == .running,
              Self.observeManagedProcess(currentHelper)?.isRunning == true else {
            return CorporateGuestApplyResult(
                state: "managed guest is \(currentState.rawValue); profile will reconcile on wake/start",
                changed: false,
                dockerdRestarted: false
            )
        }

        let rendered = try Self.renderCorporateGuestFiles(profile: profile, validation: validation)
        let script = Self.corporateGuestApplyScript(
            enabled: profile.enabled,
            profileDigest: profileDigest,
            effectiveDigest: rendered.digest,
            environmentBase64: rendered.environment.base64EncodedString(),
            argumentsBase64: rendered.arguments.base64EncodedString(),
            certificates: rendered.certificates
        )
        let result = try agentControl.exec(
            argv: ["/bin/sh", "-eu", "-c", script],
            timeoutMs: 20_000,
            outputLimitBytes: 128 * 1024
        )
        guard result.exitCode == 0 else {
            throw TierError.repairUnavailable(
                "guest corporate connectivity reconcile failed: \(Self.execFailureDetail(result))"
            )
        }
        let output = String(decoding: result.stdout, as: UTF8.self)
        guard output.contains("DORY_CORPORATE_CHANGED=1") else {
            return CorporateGuestApplyResult(
                state: "guest dockerd proxy, registry and CA digest already matched",
                changed: false,
                dockerdRestarted: false
            )
        }

        readinessTracker.begin(.dockerd, cycle: readinessCycle, deadlineSeconds: timeout)
        let ready = dockerReadyWaiter(configuration, timeout) { [weak self] in
            guard let self, let currentHelper else { return false }
            self.lock.lock()
            let active = self.state == .running && self.helperProcess === currentHelper
            self.lock.unlock()
            return active && Self.observeManagedProcess(currentHelper)?.isRunning == true
        }
        guard ready else {
            readinessTracker.blocked(
                .dockerd,
                cycle: readinessCycle,
                code: "dockerd.corporate_reconfigure_failed",
                detail: "dockerd did not restore /version after corporate settings changed"
            )
            throw TierError.repairUnavailable("dockerd did not become ready after corporate connectivity reconcile")
        }
        readinessTracker.ready(
            .dockerd,
            cycle: readinessCycle,
            code: "dockerd.corporate_reconfigured",
            detail: "applied a changed corporate proxy/registry/CA digest with live-restore"
        )
        return CorporateGuestApplyResult(
            state: profile.enabled
                ? "guest proxy, registry and CA contract applied"
                : "Dory-owned guest corporate settings removed",
            changed: true,
            dockerdRestarted: true
        )
    }

    private struct RenderedCorporateGuestFiles {
        var environment: Data
        var arguments: Data
        var certificates: [(id: String, base64: String)]
        var digest: String
    }

    private static func renderCorporateGuestFiles(
        profile: CorporateConnectivityProfile,
        validation: CorporateConnectivityValidation
    ) throws -> RenderedCorporateGuestFiles {
        guard profile.enabled else {
            return RenderedCorporateGuestFiles(
                environment: Data(), arguments: Data(), certificates: [], digest: "disabled"
            )
        }
        let proxy = validation.effectiveDockerd
        var environmentLines: [String] = []
        if let value = proxy.httpProxy {
            environmentLines.append("export HTTP_PROXY=\(shellQuote(value))")
            environmentLines.append("export http_proxy=\(shellQuote(value))")
        }
        if let value = proxy.httpsProxy {
            environmentLines.append("export HTTPS_PROXY=\(shellQuote(value))")
            environmentLines.append("export https_proxy=\(shellQuote(value))")
        }
        let safeBypass = CorporateConnectivityValidator.normalizedNoProxy(
            proxy.noProxy + [
                "localhost", "127.0.0.1", "::1", ".dory.local", "host.dory.internal",
                "169.254.0.0/16", profile.bridgeSubnet,
            ]
        ).joined(separator: ",")
        if !safeBypass.isEmpty {
            environmentLines.append("export NO_PROXY=\(shellQuote(safeBypass))")
            environmentLines.append("export no_proxy=\(shellQuote(safeBypass))")
        }
        let environment = Data((environmentLines.joined(separator: "\n") + "\n").utf8)

        let arguments = profile.registries.mirrors.map { "--registry-mirror=\($0)" }
            + profile.registries.insecureRegistries.map { "--insecure-registry=\($0)" }
        let argumentData = Data((arguments.joined(separator: "\n") + (arguments.isEmpty ? "" : "\n")).utf8)

        var certificates: [(id: String, base64: String)] = []
        for ca in profile.certificateAuthorities
        where ca.scopes.contains(.dockerdRegistry) || ca.scopes.contains(.buildKit) {
            let data = try CorporateConnectivityValidator.safeCAData(path: ca.path)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == ca.sha256.lowercased() else {
                throw TierError.repairUnavailable("CA \(ca.id) changed after profile validation")
            }
            certificates.append((ca.id, data.base64EncodedString()))
        }
        certificates.sort { $0.id < $1.id }
        var digestInput = environment + argumentData
        for certificate in certificates {
            digestInput.append(Data(certificate.id.utf8))
            digestInput.append(Data(certificate.base64.utf8))
        }
        let digest = SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
        return RenderedCorporateGuestFiles(
            environment: environment,
            arguments: argumentData,
            certificates: certificates,
            digest: digest
        )
    }

    private static func corporateGuestApplyScript(
        enabled: Bool,
        profileDigest: String,
        effectiveDigest: String,
        environmentBase64: String,
        argumentsBase64: String,
        certificates: [(id: String, base64: String)]
    ) -> String {
        var lines = [
            "umask 077",
            "test -x /run/dory-restart-dockerd",
            "mkdir -p /run/dory-corporate /run/dory-corporate/ca",
            "chmod 0700 /run/dory-corporate /run/dory-corporate/ca",
            "DORY_OLD_DIGEST=$(cat /run/dory-corporate/effective.sha256 2>/dev/null || true)",
            "if [ \"$DORY_OLD_DIGEST\" = \(shellQuote(effectiveDigest)) ]; then echo DORY_CORPORATE_CHANGED=0; exit 0; fi",
        ]
        if !enabled {
            lines.append("if [ -z \"$DORY_OLD_DIGEST\" ]; then echo DORY_CORPORATE_CHANGED=0; exit 0; fi")
        }
        if enabled {
            lines += [
                "printf %s \(shellQuote(environmentBase64)) | base64 -d >/run/dory-corporate/dockerd.env.tmp",
                "printf %s \(shellQuote(argumentsBase64)) | base64 -d >/run/dory-corporate/dockerd.args.tmp",
                "chmod 0600 /run/dory-corporate/dockerd.env.tmp /run/dory-corporate/dockerd.args.tmp",
                "mv /run/dory-corporate/dockerd.env.tmp /run/dory-corporate/dockerd.env",
                "mv /run/dory-corporate/dockerd.args.tmp /run/dory-corporate/dockerd.args",
                "rm -f /run/dory-corporate/ca/*.crt /usr/local/share/ca-certificates/dory-corporate-*.crt",
            ]
            for certificate in certificates {
                let safeID = certificate.id
                lines.append("printf %s \(shellQuote(certificate.base64)) | base64 -d >/run/dory-corporate/ca/\(safeID).crt")
                lines.append("chmod 0600 /run/dory-corporate/ca/\(safeID).crt")
                lines.append("cp /run/dory-corporate/ca/\(safeID).crt /usr/local/share/ca-certificates/dory-corporate-\(safeID).crt")
            }
        } else {
            lines += [
                "rm -f /run/dory-corporate/dockerd.env /run/dory-corporate/dockerd.args /run/dory-corporate/ca/*.crt",
                "rm -f /usr/local/share/ca-certificates/dory-corporate-*.crt",
            ]
        }
        lines += [
            "if command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates >/var/log/dory-corporate-ca.log 2>&1; elif ls /usr/local/share/ca-certificates/dory-corporate-*.crt >/dev/null 2>&1; then echo update-ca-certificates-missing >&2; exit 72; fi",
            "printf '%s\\n' \(shellQuote(profileDigest)) >/run/dory-corporate/profile.sha256",
            "printf '%s\\n' \(shellQuote(effectiveDigest)) >/run/dory-corporate/effective.sha256",
            "pids=$(pidof dockerd 2>/dev/null || true)",
            "[ -z \"$pids\" ] || kill -TERM $pids 2>/dev/null || true",
            "n=0; while [ -n \"$(pidof dockerd 2>/dev/null || true)\" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done",
            "[ -z \"$(pidof dockerd 2>/dev/null || true)\" ] || exit 70",
            "nohup /run/dory-restart-dockerd </dev/null >/var/log/dockerd.log 2>&1 &",
            "echo DORY_CORPORATE_CHANGED=1",
        ]
        return lines.joined(separator: "\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    public func telemetry() throws -> DoryTelemetry? {
        guard let agentControl else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }
        return try agentControl.telemetry()
    }

    /// Returns guest memory diagnostics and authoritative Docker data-filesystem capacity from one
    /// bounded command. Disk values are published only after `/var/lib/docker` is proven to be the
    /// selected ext4 image at `/dev/vdb`; balloon policy still uses the telemetry RPC.
    public func guestResourceSnapshot() throws -> DoryGuestResourceSnapshot? {
        guard let agentControl else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }

        return try verifiedGuestResourceSnapshot(
            agentControl: agentControl,
            timeoutMs: 3_000,
            requiredState: .running
        )
    }

    /// Kept as one production fragment so tests execute the exact awk accepted by the guest,
    /// including its syntax and duplicate-mount rejection, instead of fabricating probe stdout.
    static let guestResourceMountInfoAWK = #"""
          $5 == "/var/lib/docker" {
            matches++
            if ($4 != "/" || ("," $6 ",") !~ /,rw,/) {
              invalid=1
              next
            }
            separator=0
            for (field_index=7; field_index<=NF; field_index++) {
              if ($field_index == "-") { separator=field_index; break }
            }
            if (separator == 0 || $(separator + 1) != "ext4" || $(separator + 2) != "/dev/vdb" || ("," $(separator + 3) ",") !~ /,rw,/) {
              invalid=1
              next
            }
            mount_id=$1
            major_minor=$3
          }
          END {
            if (invalid) exit 74
            if (matches != 1) exit 75
            if (mount_id !~ /^[1-9][0-9]*$/ || major_minor !~ /^[0-9]+:[0-9]+$/) exit 79
            print mount_id, major_minor
          }
        """#

    /// Internal only so the test target can syntax-check the exact command sent to the guest.
    static let guestResourceProbeScript = #"""
        set -eu
        export LC_ALL=C
        \#(DockerDataDiskLaunchContract.guestFilesystemUUIDShellFunction)
        awk '
          /^MemTotal:/ { total=$2; have_total=1 }
          /^MemAvailable:/ { available=$2; have_available=1 }
          /^MemFree:/ { free=$2; have_free=1 }
          /^Buffers:/ { buffers=$2; have_buffers=1 }
          /^Cached:/ { cached=$2; have_cached=1 }
          /^SReclaimable:/ { sreclaimable=$2; have_sreclaimable=1 }
          /^Shmem:/ { shmem=$2; have_shmem=1 }
          END {
            if (!(have_total && have_available && have_free && have_buffers && have_cached && have_sreclaimable && have_shmem)) exit 73
            printf "schema=dev.dory.guest-resources\nversion=2\nmem_total_kb=%.0f\nmem_available_kb=%.0f\nmem_free_kb=%.0f\nbuffers_kb=%.0f\ncached_kb=%.0f\nsreclaimable_kb=%.0f\nshmem_kb=%.0f\n", total, available, free, buffers, cached, sreclaimable, shmem
          }
        ' /proc/meminfo

        dory_block_device_major_minor() {
          DORY_DEVICE_HEX_MAJOR_MINOR=$(stat -c '%t:%T' /dev/vdb)
          DORY_DEVICE_HEX_MAJOR=${DORY_DEVICE_HEX_MAJOR_MINOR%%:*}
          DORY_DEVICE_HEX_MINOR=${DORY_DEVICE_HEX_MAJOR_MINOR#*:}
          case "$DORY_DEVICE_HEX_MAJOR" in ''|*[!0-9a-fA-F]*) exit 80 ;; esac
          case "$DORY_DEVICE_HEX_MINOR" in ''|*[!0-9a-fA-F]*) exit 80 ;; esac
          printf '%u:%u\n' "$((0x$DORY_DEVICE_HEX_MAJOR))" "$((0x$DORY_DEVICE_HEX_MINOR))"
        }

        DORY_MOUNT_IDENTITY=$(awk '
        \#(guestResourceMountInfoAWK)
        ' /proc/self/mountinfo)
        set -- $DORY_MOUNT_IDENTITY
        test "$#" -eq 2 || exit 79
        DORY_MOUNT_ID=$1
        DORY_MOUNT_MAJOR_MINOR=$2
        test -b /dev/vdb
        DORY_BLOCK_NODE_MAJOR_MINOR=$(dory_block_device_major_minor)
        DORY_DEVICE_MAJOR_MINOR=$(cat /sys/class/block/vdb/dev)
        test "$DORY_MOUNT_MAJOR_MINOR" = "$DORY_BLOCK_NODE_MAJOR_MINOR" || exit 76
        test "$DORY_MOUNT_MAJOR_MINOR" = "$DORY_DEVICE_MAJOR_MINOR" || exit 76
        DORY_FILESYSTEM_UUID=$(\#(DockerDataDiskLaunchContract.guestFilesystemUUIDShellCommand)) || exit 77
        test -n "$DORY_FILESYSTEM_UUID" || exit 77
        printf "disk_mount_source=/dev/vdb\ndisk_filesystem_type=ext4\ndisk_device_major_minor=%s\ndisk_filesystem_uuid=%s\n" "$DORY_DEVICE_MAJOR_MINOR" "$DORY_FILESYSTEM_UUID"
        df -P -k /var/lib/docker | awk '
          NR == 2 {
            rows++
            if ($1 != "/dev/vdb") exit 78
            if ($2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/) exit 78
            printf "disk_total_bytes=%.0f\ndisk_used_bytes=%.0f\ndisk_available_bytes=%.0f\n", $2 * 1024, $3 * 1024, $4 * 1024
          }
          END { if (rows != 1) exit 78 }
        '

        DORY_FINAL_MOUNT_IDENTITY=$(awk '
        \#(guestResourceMountInfoAWK)
        ' /proc/self/mountinfo)
        test "$DORY_FINAL_MOUNT_IDENTITY" = "$DORY_MOUNT_ID $DORY_MOUNT_MAJOR_MINOR" || exit 81
        test -b /dev/vdb
        DORY_FINAL_BLOCK_NODE_MAJOR_MINOR=$(dory_block_device_major_minor)
        DORY_FINAL_DEVICE_MAJOR_MINOR=$(cat /sys/class/block/vdb/dev)
        test "$DORY_FINAL_BLOCK_NODE_MAJOR_MINOR" = "$DORY_DEVICE_MAJOR_MINOR" || exit 81
        test "$DORY_FINAL_DEVICE_MAJOR_MINOR" = "$DORY_DEVICE_MAJOR_MINOR" || exit 81
        DORY_FINAL_FILESYSTEM_UUID=$(\#(DockerDataDiskLaunchContract.guestFilesystemUUIDShellCommand)) || exit 81
        test "$DORY_FINAL_FILESYSTEM_UUID" = "$DORY_FILESYSTEM_UUID" || exit 81
        """#

    private func verifiedGuestResourceSnapshot(
        agentControl: AgentControl,
        timeoutMs: UInt64,
        requiredState: DockerTierState
    ) throws -> DoryGuestResourceSnapshot {
        let lifecycle = try captureGuestResourceProbeLifecycle(requiredState: requiredState)
        let authority = try finalizedGuestDataDiskAuthority(
            launchAuthority: lifecycle.dataDiskLaunchAuthority,
            helperGeneration: lifecycle.helperGeneration
        )
        let result = try agentControl.exec(
            argv: ["/bin/sh", "-c", Self.guestResourceProbeScript],
            timeoutMs: timeoutMs,
            outputLimitBytes: 16 * 1024
        )
        guard result.exitCode == 0,
              !result.timedOut,
              !result.stdoutTruncated,
              !result.stderrTruncated else {
            throw TierError.repairUnavailable("guest resource probe failed: \(Self.execFailureDetail(result))")
        }
        if lifecycle.dataDiskLaunchAuthority != nil {
            let authorityAfterProbe = try finalizedGuestDataDiskAuthority(
                launchAuthority: lifecycle.dataDiskLaunchAuthority,
                helperGeneration: lifecycle.helperGeneration
            )
            guard authorityAfterProbe == authority else {
                throw TierError.repairUnavailable(
                    "selected Docker data disk changed during the guest resource probe"
                )
            }
        }
        let snapshot = try Self.decodeGuestResourceSnapshot(
            result.stdout,
            authority: authority
        )
        let binding = DockerGuestDataDiskBinding(
            authority: authority,
            mountSource: snapshot.dataDiskMountSource,
            filesystemType: snapshot.dataDiskFilesystemType,
            deviceMajorMinor: snapshot.dataDiskDeviceMajorMinor
        )
        if let helper = lifecycle.helper,
           Self.observeManagedProcess(helper)?.isRunning != true {
            throw TierError.repairUnavailable(
                "guest resource probe crossed the managed helper termination boundary"
            )
        }
        lock.lock()
        defer { lock.unlock() }
        let ownsHelper = lifecycle.helper.map { helperProcess === $0 } ?? (helperProcess == nil)
        let ownsLaunchAuthority: Bool
        switch (activeGuestDataDiskLaunchAuthority, lifecycle.dataDiskLaunchAuthority) {
        case (nil, nil):
            ownsLaunchAuthority = true
        case (let active?, let captured?):
            ownsLaunchAuthority = active === captured
        default:
            ownsLaunchAuthority = false
        }
        guard !terminalShutdown,
              activeTeardown == nil,
              lifecycleEpoch == lifecycle.epoch,
              state == lifecycle.state,
              state == requiredState,
              ownsHelper,
              activeHelperGeneration == lifecycle.helperGeneration,
              ownsLaunchAuthority else {
            throw TierError.repairUnavailable(
                "guest resource probe crossed the Docker tier lifecycle boundary"
            )
        }
        let verifiedBinding = DockerGuestDataDiskVerifiedBinding(
            lifecycleEpoch: lifecycle.epoch,
            helperGeneration: lifecycle.helperGeneration,
            binding: binding
        )
        let sameBindingScope = verifiedGuestDataDiskBinding.map { existing in
            if let helperGeneration = lifecycle.helperGeneration {
                return existing.helperGeneration == helperGeneration
            }
            return existing.helperGeneration == nil
                && existing.lifecycleEpoch == lifecycle.epoch
        } ?? false
        if let existing = verifiedGuestDataDiskBinding,
           sameBindingScope,
           existing.binding != binding {
            throw TierError.repairUnavailable(
                "guest Docker data-filesystem identity changed within one helper generation"
            )
        }
        verifiedGuestDataDiskBinding = verifiedBinding
        return snapshot
    }

    /// Completes a managed launch's two-phase disk authority after the helper has formatted or
    /// reopened the image. The retained descriptor proves the same pre-launch inode became ext4;
    /// reopening the configured path proves that inode is still the selected drive's live entry.
    private func finalizedGuestDataDiskAuthority(
        launchAuthority: DockerGuestDataDiskLaunchAuthority?,
        helperGeneration: UUID?
    ) throws -> DockerGuestDataDiskAuthority {
        guard let launchAuthority else {
            return try currentGuestDataDiskAuthority()
        }
        guard launchAuthority.helperGeneration == helperGeneration else {
            throw TierError.repairUnavailable(
                "selected Docker data disk no longer matches this helper generation's launch authority"
            )
        }
        if let trustedRoot = launchAuthority.trustedDataDriveRoot {
            _ = try trustedRoot.revalidateRootPathname()
        }
        guard let diskFile = launchAuthority.diskFile else {
            // Injected test/development authorities already represent a complete ext4 identity.
            let pathAuthority: DockerGuestDataDiskAuthority
            do {
                pathAuthority = try currentGuestDataDiskAuthority()
            } catch {
                throw TierError.repairUnavailable(
                    "selected Docker data disk no longer matches this helper generation's launch authority: \(error)"
                )
            }
            guard launchAuthority.hostIdentity.permits(
                pathAuthority,
                expectedFilesystemUUID: launchAuthority.expectedFilesystemUUID
            ) else {
                throw TierError.repairUnavailable(
                    "selected Docker data disk no longer matches this helper generation's launch authority"
                )
            }
            return pathAuthority
        }
        let retainedIdentity = try diskFile.withBorrowedDescriptor { descriptor in
            try Self.inspectGuestDataDiskHostIdentity(
                dataDriveID: launchAuthority.hostIdentity.dataDriveID,
                descriptor: descriptor,
                path: launchAuthority.hostIdentity.diskImagePath,
                allowUninitializedSparseBlank: false
            )
        }
        guard let filesystemUUID = retainedIdentity.filesystemUUID else {
            throw TierError.repairUnavailable(
                "selected Docker data disk did not finish ext4 initialization"
            )
        }
        let retainedAuthority = DockerGuestDataDiskAuthority(
            dataDriveID: retainedIdentity.dataDriveID,
            filesystemUUID: filesystemUUID,
            diskImagePath: retainedIdentity.diskImagePath,
            diskImageDevice: retainedIdentity.diskImageDevice,
            diskImageInode: retainedIdentity.diskImageInode
        )
        guard launchAuthority.hostIdentity.permits(
                retainedAuthority,
                expectedFilesystemUUID: launchAuthority.expectedFilesystemUUID
              ) else {
            throw TierError.repairUnavailable(
                "selected Docker data disk changed from this helper generation's launch authority while it initialized"
            )
        }
        let pathAuthority: DockerGuestDataDiskAuthority
        do {
            pathAuthority = try currentGuestDataDiskAuthority()
        } catch {
            throw TierError.repairUnavailable(
                "selected Docker data disk no longer matches this helper generation's launch authority: \(error)"
            )
        }
        guard launchAuthority.hostIdentity.permits(
                pathAuthority,
                expectedFilesystemUUID: launchAuthority.expectedFilesystemUUID
              ),
              retainedAuthority == pathAuthority else {
            throw TierError.repairUnavailable(
                "selected Docker data disk changed from this helper generation's launch authority while it initialized"
            )
        }
        return retainedAuthority
    }

    private func currentGuestDataDiskAuthority() throws -> DockerGuestDataDiskAuthority {
        do {
            return try guestDataDiskAuthorityProvider(configuration.home)
        } catch let error as TierError {
            throw error
        } catch {
            throw TierError.repairUnavailable(
                "selected Docker data-disk authority is unavailable: \(error)"
            )
        }
    }

    private func captureGuestResourceProbeLifecycle(
        requiredState: DockerTierState
    ) throws -> DockerGuestResourceProbeLifecycle {
        lock.lock()
        guard !terminalShutdown,
              activeTeardown == nil,
              state == requiredState else {
            lock.unlock()
            throw TierError.repairUnavailable(
                "guest resource probe requires a stable \(requiredState.rawValue) Docker tier"
            )
        }
        let lifecycle = DockerGuestResourceProbeLifecycle(
            epoch: lifecycleEpoch,
            state: state,
            helper: helperProcess,
            helperGeneration: activeHelperGeneration,
            dataDiskLaunchAuthority: activeGuestDataDiskLaunchAuthority
        )
        if configuration.hasManagedHelper,
           lifecycle.helper == nil || lifecycle.helperGeneration == nil {
            lock.unlock()
            throw TierError.repairUnavailable(
                "guest resource probe has no exact managed helper generation"
            )
        }
        if configuration.hasManagedHelper,
           lifecycle.dataDiskLaunchAuthority == nil {
            lock.unlock()
            throw TierError.repairUnavailable(
                "guest resource probe has no exact host data-disk launch authority"
            )
        }
        lock.unlock()

        if let helper = lifecycle.helper,
           Self.observeManagedProcess(helper)?.isRunning != true {
            throw TierError.repairUnavailable(
                "guest resource probe helper is not running"
            )
        }
        return lifecycle
    }

    static func decodeGuestResourceSnapshot(
        _ data: Data,
        authority: DockerGuestDataDiskAuthority
    ) throws -> DoryGuestResourceSnapshot {
        let invalid = TierError.repairUnavailable(
            "guest resource probe returned an invalid versioned record"
        )
        let expectedKeys: Set<String> = [
            "schema", "version", "mem_total_kb", "mem_available_kb", "mem_free_kb",
            "buffers_kb", "cached_kb", "sreclaimable_kb", "shmem_kb",
            "disk_mount_source", "disk_filesystem_type", "disk_device_major_minor",
            "disk_filesystem_uuid",
            "disk_total_bytes", "disk_used_bytes", "disk_available_bytes",
        ]
        guard !data.isEmpty,
              data.count <= 16 * 1_024,
              data.last == 0x0A,
              !data.contains(0x0D),
              let output = String(data: data, encoding: .utf8) else {
            throw invalid
        }
        let body = output.dropLast()
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == expectedKeys.count else { throw invalid }
        var record = [String: String](minimumCapacity: expectedKeys.count)
        for line in lines {
            let fields = line.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard fields.count == 2 else { throw invalid }
            let key = String(fields[0])
            let value = String(fields[1])
            guard expectedKeys.contains(key), record.updateValue(value, forKey: key) == nil else {
                throw invalid
            }
        }
        guard Set(record.keys) == expectedKeys,
              record["schema"] == "dev.dory.guest-resources",
              record["version"] == "2" else {
            throw invalid
        }
        func unsigned(_ key: String) -> UInt64? {
            guard let value = record[key], !value.isEmpty,
                  value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
                return nil
            }
            return UInt64(value)
        }
        func canonicalMajorMinor(_ key: String) -> String? {
            guard let value = record[key] else { return nil }
            let fields = value.split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard fields.count == 2,
                  fields.allSatisfy({
                      !$0.isEmpty && $0.utf8.allSatisfy({ (0x30...0x39).contains($0) })
                  }),
                  let major = UInt32(fields[0]),
                  let minor = UInt32(fields[1]),
                  value == "\(major):\(minor)" else {
                return nil
            }
            return value
        }
        guard record["disk_mount_source"] == "/dev/vdb",
              record["disk_filesystem_type"] == "ext4",
              let deviceMajorMinor = canonicalMajorMinor("disk_device_major_minor"),
              let encodedFilesystemUUID = record["disk_filesystem_uuid"],
              let filesystemUUID = UUID(uuidString: encodedFilesystemUUID),
              encodedFilesystemUUID == filesystemUUID.uuidString.lowercased(),
              filesystemUUID == authority.filesystemUUID,
              let totalKB = unsigned("mem_total_kb"),
              let availableKB = unsigned("mem_available_kb"),
              let freeKB = unsigned("mem_free_kb"),
              let buffersKB = unsigned("buffers_kb"),
              let cachedKB = unsigned("cached_kb"),
              let slabReclaimableKB = unsigned("sreclaimable_kb"),
              let sharedKB = unsigned("shmem_kb"),
              let diskTotal = unsigned("disk_total_bytes"),
              let diskUsed = unsigned("disk_used_bytes"),
              let diskAvailable = unsigned("disk_available_bytes"),
              totalKB > 0,
              totalKB <= UInt64.max / 1_024,
              availableKB <= totalKB,
              freeKB <= totalKB,
              buffersKB <= totalKB,
              cachedKB <= totalKB,
              slabReclaimableKB <= totalKB,
              sharedKB <= totalKB,
              diskTotal > 0,
              diskUsed <= diskTotal,
              diskAvailable <= diskTotal else {
            throw invalid
        }
        let (bufferedAndCachedKB, firstOverflow) = buffersKB.addingReportingOverflow(cachedKB)
        let (accountedCacheKB, secondOverflow) = bufferedAndCachedKB.addingReportingOverflow(
            slabReclaimableKB
        )
        let (accountedDiskBytes, diskOverflow) = diskUsed.addingReportingOverflow(diskAvailable)
        guard !firstOverflow,
              !secondOverflow,
              !diskOverflow,
              accountedDiskBytes > 0,
              accountedDiskBytes <= diskTotal else {
            throw invalid
        }
        let cacheKB = accountedCacheKB >= sharedKB ? accountedCacheKB - sharedKB : 0
        guard cacheKB <= totalKB else { throw invalid }
        let usedKB = totalKB - availableKB
        return DoryGuestResourceSnapshot(
            selectedDataDriveID: authority.dataDriveID,
            dataDiskFilesystemUUID: filesystemUUID,
            dataDiskMountSource: "/dev/vdb",
            dataDiskFilesystemType: "ext4",
            dataDiskDeviceMajorMinor: deviceMajorMinor,
            memoryCeilingBytes: totalKB * 1_024,
            memoryUsedBytes: usedKB * 1_024,
            memoryCacheBytes: cacheKB * 1_024,
            memoryAvailableBytes: availableKB * 1_024,
            memoryFreeBytes: freeKB * 1_024,
            dataDiskTotalBytes: diskTotal,
            dataDiskUsedBytes: diskUsed,
            dataDiskAvailableBytes: diskAvailable
        )
    }

    public func fileServiceResourceSnapshot(now: Date = Date()) -> DoryFileServiceResourceSnapshot? {
        guard let directory = managedHelperStateDirectory() else { return nil }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("file-service-resources.json")
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize > 0,
              fileSize <= 64 * 1_024,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count == fileSize,
              let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any],
              Set(record.keys) == DoryFileServiceResourceSnapshot.exactJSONKeys else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(DoryFileServiceResourceSnapshot.self, from: data),
              snapshot.schema == "dev.dory.file-service.resources",
              snapshot.version == 1,
              abs(now.timeIntervalSince(snapshot.generatedAt)) <= 15,
              snapshot.cacheMode == "zero-validity",
              snapshot.maximumCacheValiditySeconds == 0,
              (0...64).contains(snapshot.configuredShareCount),
              (0...64).contains(snapshot.invalidationOnlyShareCount),
              (0...64).contains(snapshot.watcherNudgeShareCount),
              snapshot.invalidationOnlyShareCount + snapshot.watcherNudgeShareCount
                == snapshot.configuredShareCount,
              snapshot.observationRequired == (snapshot.configuredShareCount > 0),
              snapshot.requiredObservationShareCount >= 0,
              snapshot.requiredObservationShareCount <= snapshot.configuredShareCount,
              snapshot.observedRequiredShareCount >= 0,
              snapshot.observedRequiredShareCount <= snapshot.requiredObservationShareCount,
              snapshot.observationStreamCount >= snapshot.observedRequiredShareCount,
              snapshot.observationStreamCount <= snapshot.configuredShareCount,
              snapshot.frontendCount >= snapshot.configuredShareCount,
              snapshot.frontendCount <= 66,
              snapshot.requestQueueCount >= snapshot.frontendCount,
              snapshot.requestQueueCount <= 4_224,
              snapshot.pendingEventCount >= 0,
              snapshot.pendingEventLimit == 65_536,
              snapshot.pendingEventCount <= snapshot.pendingEventLimit,
              snapshot.coherenceInFlightBatchCount >= 0,
              snapshot.coherenceInFlightBatchCount <= 8,
              snapshot.inFlightRequestCount <= snapshot.peakInFlightRequestCount,
              snapshot.maximumRequestLatencyNanoseconds
                <= snapshot.totalRequestLatencyNanoseconds,
              !snapshot.running || (
                  snapshot.observationActive
                      && snapshot.requiredObservationShareCount
                        == snapshot.configuredShareCount
                      && snapshot.observedRequiredShareCount
                        == snapshot.configuredShareCount
                      && snapshot.observationStreamCount
                        == snapshot.configuredShareCount
                      && !snapshot.invalidationFailureLatched
                      && !snapshot.coherenceTerminalFailureLatched
              ) else {
            return nil
        }
        return snapshot
    }

    /// Reads the legacy host-share telemetry file for callers that still consume the version-one
    /// observer record. Current helpers publish `file-service-resources.json`; this method does not
    /// translate or fabricate that richer record into the retired schema.
    @available(*, deprecated, message: "Use fileServiceResourceSnapshot(now:) instead")
    public func hostShareResourceSnapshot(now: Date = Date()) -> DoryHostShareResourceSnapshot? {
        guard let directory = managedHelperStateDirectory() else { return nil }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("host-share-resources.json")
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize > 0,
              fileSize <= 64 * 1_024,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count == fileSize else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(DoryHostShareResourceSnapshot.self, from: data),
              snapshot.schema == "dev.dory.host-share.resources",
              snapshot.version == 1,
              abs(now.timeIntervalSince(snapshot.generatedAt)) <= 30 else {
            return nil
        }
        return snapshot
    }

    private func managedHelperStateDirectory() -> String? {
        if let directory = configuration.vmmProcess?.stateDirectory { return directory }
        guard let arguments = configuration.hvProcess?.arguments,
              let index = arguments.firstIndex(of: "--state-dir"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    public func memorySnapshot(
        id: String = "docker",
        minimumTargetMB: UInt64 = 512,
        maximumTargetMB: UInt64? = nil
    ) throws -> GuestMemorySnapshot? {
        guard let telemetry = try telemetry() else { return nil }
        return GuestMemorySnapshot(
            id: id,
            kind: .docker,
            telemetry: telemetry,
            minimumTargetMB: minimumTargetMB,
            maximumTargetMB: maximumTargetMB,
            canBalloon: false
        )
    }

    private static func dockerPublishedPort(_ port: DockerContainerPort) -> DoryListenPort? {
        guard let publicPort = port.publicPort,
              (1...65_535).contains(publicPort),
              let portNumber = UInt32(exactly: publicPort) else {
            return nil
        }
        switch (port.type ?? "tcp").lowercased() {
        case "tcp", "tcp6":
            return DoryListenPort(protocol: "tcp", port: portNumber)
        case "udp", "udp6":
            return DoryListenPort(protocol: "udp", port: portNumber)
        default:
            return nil
        }
    }

    public func syncAgentClock(now: Date = Date()) -> AgentClockSyncResult {
        // Reached on host wake via the wake coordinator's clock syncers. Reset the idle
        // clock the way the engine-wake path does: a long host sleep otherwise leaves
        // lastActivity far in the past, so the idle scheduler would sleep a just-woken
        // engine almost immediately.
        idleController?.touch(now: now)
        guard let agentControl else {
            return AgentClockSyncResult(name: "docker", attempted: false, synced: false)
        }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else {
            return AgentClockSyncResult(name: "docker", attempted: false, synced: false)
        }
        do {
            let synced = try agentControl.clockSync(now: now)
            if synced {
                lock.lock()
                lastError = nil
                lock.unlock()
            }
            return AgentClockSyncResult(name: "docker", attempted: true, synced: synced)
        } catch {
            lock.lock()
            lastError = "agent clock sync failed: \(error)"
            lock.unlock()
            return AgentClockSyncResult(
                name: "docker",
                attempted: true,
                synced: false,
                error: "\(error)"
            )
        }
    }

    public func ensureAwake() async {
        if let task = wakeTaskForEnsureAwake() {
            await task.value
            return
        }

        // An explicit start can promote an armed dataplane synchronously, without installing a
        // wakeTask. Hold a request that arrives in that window until the same promotion finishes;
        // otherwise the activity acknowledgement lets it dial a guest whose dockerd is still booting.
        guard promotionIsStarting(), !Task.isCancelled else { return }
        _ = await Task.detached { [weak self] in
            self?.waitForPromotionStateChange(until: Date().addingTimeInterval(240)) ?? false
        }.value
    }

    private func promotionIsStarting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !terminalShutdown && state == .starting
    }

    private func wakeTaskForEnsureAwake() -> Task<Void, Never>? {
        lock.lock()
        if terminalShutdown {
            lock.unlock()
            return nil
        }
        // A request that arrives after the first wake has changed the tier to `starting` must
        // still await that exact promotion. Acknowledging it early makes the dataplane connect to
        // a backend that is not ready yet and turns a healthy cold boot into a client-visible EOF.
        if let wakeTask {
            lock.unlock()
            return wakeTask
        }
        if state != .sleeping {
            lock.unlock()
            return nil
        }
        let task = Task.detached { [weak self] in
            if let self {
                self.wakeSynchronously()
            }
        }
        wakeTask = task
        lock.unlock()
        return task
    }

    private func wakeSynchronously() {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        var shouldSyncClock = false
        lock.lock()
        guard !terminalShutdown else {
            wakeTask = nil
            lock.unlock()
            return
        }
        if state == .sleeping,
           let currentHelper = helperProcess,
           Self.observeManagedProcess(currentHelper)?.isRunning == true {
            guard currentHelper.resume() else {
                lastError = TierError.resumeFailed(
                    pid: Self.observeManagedProcess(currentHelper)?.pid
                ).description
                wakeTask = nil
                lock.unlock()
                idleController?.setSleeping(true)
                return
            }
            lifecycleEpoch &+= 1
            let resumeEpoch = lifecycleEpoch
            let readinessCycle = readinessTracker.beginCycle(trigger: "resume")
            setStateLocked(.starting)
            lastError = nil
            lock.unlock()

            var readinessFailure: Error?
            do {
                readinessTracker.ready(
                    .vmProcess,
                    cycle: readinessCycle,
                    code: "vm.process_resumed",
                    detail: "resumed managed helper pid \(Self.observeManagedProcess(currentHelper)?.pid ?? 0)"
                )
                try validateGuestPrerequisites(
                    helper: currentHelper,
                    readinessCycle: readinessCycle
                )
                try validateDockerBackend(
                    helper: currentHelper,
                    epoch: resumeEpoch,
                    readinessCycle: readinessCycle,
                    timeout: Self.resumeReadyTimeout
                )
                readinessTracker.begin(
                    .hostSocketContext,
                    cycle: readinessCycle,
                    deadlineSeconds: 2
                )
                readinessTracker.ready(
                    .hostSocketContext,
                    cycle: readinessCycle,
                    code: "socket.forwarder_retained",
                    detail: "existing wake-on-demand Docker socket remained bound"
                )
            } catch {
                readinessFailure = error
                readinessTracker.blockCurrent(
                    cycle: readinessCycle,
                    code: readinessReasonCode(for: error),
                    detail: "\(error)"
                )
            }

            lock.lock()
            let ownsCurrentHelper = helperProcess === currentHelper
            guard !terminalShutdown,
                  lifecycleEpoch == resumeEpoch,
                  state == .starting,
                  ownsCurrentHelper else {
                wakeTask = nil
                lock.unlock()
                return
            }
            let resumedObservation = Self.observeManagedProcess(currentHelper)
            if readinessFailure == nil, resumedObservation?.isRunning == true {
                setStateLocked(.running)
                helperStartedAt = Date()
                lastError = nil
                wakeTask = nil
                enqueueLifecycleStateObserverLocked(.running)
                lock.unlock()
                idleController?.setSleeping(false)
                idleController?.touch()
                shouldSyncClock = true
                if shouldSyncClock {
                    _ = syncAgentClockAfterWake()
                }
                return
            }
            lastError = readinessFailure.map(String.init(describing:))
                ?? TierError.helperExited("exited while resuming").description
            setStateLocked(.sleeping)
            if resumedObservation?.isRunning == false {
                helperProcess = nil
                activeHelperGeneration = nil
                activeGuestDataDiskLaunchAuthority = nil
                helperStartedAt = nil
            }
            wakeTask = nil
            lock.unlock()
            idleController?.setSleeping(true)
            return
        }
        guard state == .sleeping else {
            wakeTask = nil
            lock.unlock()
            return
        }
        lifecycleEpoch &+= 1
        let wakeEpoch = lifecycleEpoch
        let readinessCycle = readinessTracker.beginCycle(trigger: "cold-wake")
        setStateLocked(.starting)
        lastError = nil
        lock.unlock()

        var helper: (any DockerManagedProcess)?
        do {
            let helperGeneration = UUID()
            let dataDiskLaunchAuthority = try guestDataDiskLaunchAuthority(
                helperGeneration: helperGeneration
            )
            helper = try makeManagedProcess(
                generation: helperGeneration,
                dataDiskLaunchAuthority: dataDiskLaunchAuthority
            )
            lock.lock()
            guard !terminalShutdown,
                  lifecycleEpoch == wakeEpoch,
                  state == .starting else {
                wakeTask = nil
                lock.unlock()
                stopManagedHelperAndRetainIfNeeded(
                    helper,
                    context: "cancelled cold wake could not confirm helper exit"
                )
                return
            }
            // Publish before start(): daemon shutdown must be able to cancel the exact window
            // between an accepted engineWake and the helper's blocking handoff/readiness wait.
            helperProcess = helper
            activeHelperGeneration = helper == nil ? nil : helperGeneration
            activeGuestDataDiskLaunchAuthority = helper == nil ? nil : dataDiskLaunchAuthority
            lock.unlock()

            try helper?.start()
            guard freshLaunchIsActive(epoch: wakeEpoch, helper: helper) else {
                stopManagedHelperAndRetainIfNeeded(
                    helper,
                    context: "superseded cold wake could not confirm helper exit"
                )
                return
            }

            readinessTracker.ready(
                .vmProcess,
                cycle: readinessCycle,
                code: "vm.process_ready",
                detail: Self.observeManagedProcess(helper)?.pid
                    .map { "managed helper pid \($0) is running" }
                    ?? "in-process backend is running"
            )
            try validateGuestPrerequisites(
                helper: helper,
                readinessCycle: readinessCycle
            )
            try validateDockerBackend(
                helper: helper,
                epoch: wakeEpoch,
                readinessCycle: readinessCycle,
                timeout: Self.freshStartReadyTimeout
            )
            readinessTracker.begin(
                .hostSocketContext,
                cycle: readinessCycle,
                deadlineSeconds: 2
            )
            readinessTracker.ready(
                .hostSocketContext,
                cycle: readinessCycle,
                code: "socket.forwarder_retained",
                detail: "existing wake-on-demand Docker socket remained bound"
            )

            lock.lock()
            let ownsHelper = helper.map { helperProcess === $0 } ?? (helperProcess == nil)
            guard !terminalShutdown,
                  lifecycleEpoch == wakeEpoch,
                  state == .starting,
                  ownsHelper else {
                wakeTask = nil
                lock.unlock()
                stopManagedHelperAndRetainIfNeeded(
                    helper,
                    context: "cold wake publication could not confirm helper exit"
                )
                return
            }
            if Self.observeManagedProcess(helper)?.isRunning == true {
                helperProcess = helper
                setStateLocked(.running)
                helperStartedAt = Date()
                lastError = nil
                wakeTask = nil
                enqueueLifecycleStateObserverLocked(.running)
                lock.unlock()
                idleController?.setSleeping(false)
                idleController?.touch()
                shouldSyncClock = true
                if shouldSyncClock {
                    _ = syncAgentClockAfterWake()
                }
            } else {
                lock.unlock()
                throw TierError.helperExited("exited while waking")
            }
        } catch {
            readinessTracker.blockCurrent(
                cycle: readinessCycle,
                code: readinessReasonCode(for: error),
                detail: "\(error)"
            )
            let helperTerminated = stopManagedHelperAndRetainIfNeeded(
                helper,
                context: "failed cold wake could not confirm helper exit"
            )
            lock.lock()
            let ownsHelper = helper.map { helperProcess === $0 } ?? (helperProcess == nil)
            let ownsLifecycle = !terminalShutdown
                && lifecycleEpoch == wakeEpoch
                && state == .starting
                && ownsHelper
            if ownsLifecycle, helperTerminated {
                helperProcess = nil
                activeHelperGeneration = nil
                activeGuestDataDiskLaunchAuthority = nil
                helperStartedAt = nil
                setStateLocked(.sleeping)
                lastError = "\(error)"
                wakeTask = nil
            }
            lock.unlock()
            if ownsLifecycle {
                idleController?.setSleeping(true)
            }
        }
    }

    private func syncAgentClockAfterWake(timeout: TimeInterval = 5) -> AgentClockSyncResult {
        let deadline = Date().addingTimeInterval(timeout)
        var result = syncAgentClock()
        while result.attempted, !result.synced, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            result = syncAgentClock()
        }
        return result
    }

    private func makeManagedProcess(
        generation: UUID,
        dataDiskLaunchAuthority: DockerGuestDataDiskLaunchAuthority?
    ) throws -> (any DockerManagedProcess)? {
        let onUnexpectedTermination: HvProcessUnexpectedTerminationHandler = { [weak self] termination in
            self?.managedHelperExited(generation: generation, termination: termination)
        }
        let process: (any DockerManagedProcess)?
        if let managedProcessFactory {
            process = managedProcessFactory(generation, onUnexpectedTermination)
        } else if var vmmConfiguration = configuration.vmmProcess {
            try configureInheritedDockerDataDisk(
                launchAuthority: dataDiskLaunchAuthority,
                vmmConfiguration: &vmmConfiguration
            )
            process = VmmDockerProcess(
                configuration: vmmConfiguration,
                unexpectedTerminationHandler: onUnexpectedTermination
            )
        } else if var hvConfiguration = configuration.hvProcess {
            // The tier must rebuild the full helper + dataplane graph after a VM exit. Disable
            // HvProcess's local child-only retry so it cannot resurrect behind stale proxies.
            hvConfiguration.restartPolicy = .none
            try configureInheritedDockerDataDisk(
                launchAuthority: dataDiskLaunchAuthority,
                hvConfiguration: &hvConfiguration
            )
            process = HvProcess(
                configuration: hvConfiguration,
                unexpectedTerminationHandler: onUnexpectedTermination
            )
        } else {
            process = nil
        }
        guard let process, let dataDiskLaunchAuthority else { return process }
        return DockerManagedProcessGeneration(
            process: process,
            dataDiskLaunchAuthority: dataDiskLaunchAuthority
        )
    }

    private func configureInheritedDockerDataDisk(
        launchAuthority: DockerGuestDataDiskLaunchAuthority?,
        vmmConfiguration: inout VmmDockerProcessConfiguration
    ) throws {
        guard let launchAuthority else { return }
        guard let diskFile = launchAuthority.diskFile else {
            throw TierError.repairUnavailable(
                "managed VMM Docker data-disk authority has no admitted file descriptor"
            )
        }
        guard vmmConfiguration.inheritedDockerDataDisk == nil,
              vmmConfiguration.dockerDataDiskFilesystemUUID == nil else {
            throw TierError.repairUnavailable(
                "managed VMM already contains Docker data-disk launch authority"
            )
        }
        let duplicate = try diskFile.duplicate()
        vmmConfiguration.inheritedDockerDataDisk = HvProcessInheritedFileDescriptor(
            name: DockerDataDiskLaunchContract.authorityName,
            takingOwnershipOf: duplicate,
            childDescriptor: DockerDataDiskLaunchContract.childFileDescriptor
        )
        vmmConfiguration.dockerDataDiskFilesystemUUID = launchAuthority.expectedFilesystemUUID
    }

    private func configureInheritedDockerDataDisk(
        launchAuthority: DockerGuestDataDiskLaunchAuthority?,
        hvConfiguration: inout HvProcessConfiguration
    ) throws {
        guard let launchAuthority else { return }
        guard let diskFile = launchAuthority.diskFile else {
            throw TierError.repairUnavailable(
                "managed RawHV Docker data-disk authority has no admitted file descriptor"
            )
        }
        let descriptorFlag = DockerDataDiskLaunchContract.fileDescriptorArgument
        let uuidFlag = DockerDataDiskLaunchContract.filesystemUUIDArgument
        guard !hvConfiguration.arguments.contains(where: {
                  $0 == descriptorFlag || $0.hasPrefix(descriptorFlag + "=")
              }),
              !hvConfiguration.arguments.contains(where: {
                  $0 == uuidFlag || $0.hasPrefix(uuidFlag + "=")
              }),
              !hvConfiguration.inheritedFileDescriptors.contains(where: {
                  $0.name == DockerDataDiskLaunchContract.authorityName
                      || $0.childDescriptor
                          == DockerDataDiskLaunchContract.childFileDescriptor
              }) else {
            throw TierError.repairUnavailable(
                "managed RawHV helper already contains Docker data-disk launch authority"
            )
        }
        let duplicate = try diskFile.duplicate()
        hvConfiguration.inheritedFileDescriptors.append(
            HvProcessInheritedFileDescriptor(
                name: DockerDataDiskLaunchContract.authorityName,
                takingOwnershipOf: duplicate,
                childDescriptor: DockerDataDiskLaunchContract.childFileDescriptor
            )
        )
        hvConfiguration.arguments += [
            descriptorFlag,
            String(DockerDataDiskLaunchContract.childFileDescriptor),
            uuidFlag,
            launchAuthority.expectedFilesystemUUID.uuidString.lowercased(),
        ]
    }

    private var managedRestartPolicy: HvRestartPolicy {
        configuration.hvProcess?.restartPolicy
            ?? configuration.vmmProcess?.restartPolicy
            ?? .none
    }

    private func reconcileManagedHelperLiveness(until deadline: DispatchTime) {
        guard configuration.hasManagedHelper else { return }
        let generation: UUID?
        let helper: (any DockerManagedProcess)?
        guard lock.lock(until: deadline) else { return }
        if state == .running {
            generation = activeHelperGeneration
            helper = helperProcess
        } else {
            generation = nil
            helper = nil
        }
        lock.unlock()

        guard let generation,
              let observation = Self.observeManagedProcess(helper, until: deadline),
              !observation.isRunning else { return }
        // Status is an observation API, not a cleanup request. Queue the exact generation's
        // teardown so endpoint/process retirement cannot extend the status budget.
        supervisorQueue.async { [weak self] in
            self?.handleManagedHelperLoss(
                generation: generation,
                detail: "is no longer running"
            )
        }
    }

    private func managedHelperExited(generation: UUID, termination: HvProcessTermination) {
        handleManagedHelperLoss(
            generation: generation,
            detail: termination.description
        )
    }

    private func handleManagedHelperLoss(generation: UUID, detail: String) {
        let operation: TeardownOperation
        let restart: DispatchWorkItem?
        let restartDelay: TimeInterval
        let terminalFailureDetail: String
        var shouldScheduleRestart = false
        var retainedRecovery: RetainedHelperRecoveryPlan?

        lock.lock()
        guard !terminalShutdown,
              state == .running,
              activeTeardown == nil,
              activeHelperGeneration == generation else {
            lock.unlock()
            return
        }

        let policy = managedRestartPolicy
        if policy.stableRunSeconds > 0,
           let helperStartedAt,
           Date().timeIntervalSince(helperStartedAt) >= policy.stableRunSeconds {
            unexpectedRestartCount = 0
        }
        unexpectedRestartCount += 1
        let attempt = unexpectedRestartCount
        let canRestart = attempt <= policy.maxRestarts

        lifecycleEpoch &+= 1
        let restartEpoch = lifecycleEpoch
        let readinessCycle = readinessTracker.currentCycleToken()
        let previousRestart = restartWorkItem
        var helpers: [any DockerManagedProcess] = []
        if let helperProcess { helpers.append(helperProcess) }
        operation = TeardownOperation(
            epoch: restartEpoch,
            dataplane: dataplane,
            activityServer: activityServer,
            wakeTask: wakeTask,
            restartWorkItem: previousRestart,
            helpers: helpers,
            readinessCycle: readinessCycle,
            markStopped: false,
            publishStoppedIntent: false
        )
        activeTeardown = operation
        dataplane = nil
        helperProcess = nil
        activityServer = nil
        wakeTask = nil
        activeHelperGeneration = nil
        activeGuestDataDiskLaunchAuthority = nil
        helperStartedAt = nil
        idleController?.setSleeping(false)

        if canRestart {
            let item = DispatchWorkItem { [weak self] in
                self?.performScheduledRestart(epoch: restartEpoch)
            }
            restart = item
            restartDelay = policy.delay(forAttempt: attempt)
            setStateLocked(.starting)
            lastError = "managed helper \(detail); restart attempt \(attempt)/\(policy.maxRestarts) queued"
            terminalFailureDetail = lastError ?? "managed helper restart cleanup failed"
        } else {
            restart = nil
            restartDelay = 0
            setStateLocked(.failed)
            lastError = "managed helper \(detail); automatic restart limit (\(policy.maxRestarts)) exhausted"
            terminalFailureDetail = lastError ?? "managed helper restart limit exhausted"
        }
        restartWorkItem = nil
        lock.unlock()

        // The operation token excludes replacement launches while every potentially blocking
        // endpoint/process call executes without the tier lock. Status and shutdown remain bounded
        // and can join the exact cleanup generation.
        operation.wakeTask?.cancel()
        operation.restartWorkItem?.cancel()
        removeRuntimeSockets()
        operation.dataplane?.shutdown()
        operation.activityServer?.stop()
        agentControl?.disconnect()
        var unconfirmedHelpers: [any DockerManagedProcess] = []
        for helper in operation.helpers {
            let reportedTerminated = helper.stop()
            if !reportedTerminated,
               Self.observeManagedProcess(helper)?.isRunning != false {
                unconfirmedHelpers.append(helper)
            }
        }

        lock.lock()
        guard activeTeardown === operation, lifecycleEpoch == operation.epoch else {
            lock.unlock()
            operation.finish(result: false)
            return
        }
        activeTeardown = nil
        let helperTerminated = unconfirmedHelpers.isEmpty
        if helperTerminated, let restart, !terminalShutdown {
            restartWorkItem = restart
            shouldScheduleRestart = true
        } else if !helperTerminated, let helper = unconfirmedHelpers.first {
            for retained in unconfirmedHelpers.dropFirst() {
                if !retiringHelpers.contains(where: { $0 === retained }) {
                    retiringHelpers.append(retained)
                }
            }
            retainUnconfirmedHelperLocked(
                helper,
                context: "unexpected helper loss could not confirm terminal exit"
            )
            let token = UUID()
            retainedHelperRecoveryToken = token
            retainedRecovery = RetainedHelperRecoveryPlan(
                token: token,
                epoch: operation.epoch,
                helpers: unconfirmedHelpers,
                restart: restart,
                restartDelay: restartDelay,
                terminalFailureDetail: terminalFailureDetail
            )
        } else if terminalShutdown {
            restartWorkItem = nil
            setStateLocked(.failed)
            lastError = "daemon shutdown superseded managed helper recovery"
        } else {
            restartWorkItem = nil
            setStateLocked(.failed)
            lastError = terminalFailureDetail
        }
        lock.unlock()
        operation.finish(result: helperTerminated)

        if helperTerminated, let restart, shouldScheduleRestart {
            supervisorQueue.asyncAfter(deadline: .now() + restartDelay, execute: restart)
        } else if let retainedRecovery {
            observeRetainedHelpersForRecovery(retainedRecovery)
        }
    }

    /// A bounded wait is repeated only while the exact retained recovery token remains current.
    /// `waitForTermination` is the process object's terminal event primitive; no status/control
    /// request is needed to notice the eventual exit or to continue the budgeted recovery.
    private func observeRetainedHelpersForRecovery(_ plan: RetainedHelperRecoveryPlan) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for helper in plan.helpers {
                while self.retainedRecoveryIsActive(token: plan.token, epoch: plan.epoch) {
                    _ = helper.waitForTermination(
                        timeout: DoryEngineShutdownTiming.hostTerminationSeconds
                    )
                    if Self.observeManagedProcess(helper)?.isRunning == false {
                        break
                    }
                }
                guard self.retainedRecoveryIsActive(token: plan.token, epoch: plan.epoch) else {
                    return
                }
            }
            self.supervisorQueue.async { [weak self] in
                self?.completeRetainedHelperRecovery(plan)
            }
        }
    }

    private func retainedRecoveryIsActive(token: UUID, epoch: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !terminalShutdown
            && lifecycleEpoch == epoch
            && retainedHelperRecoveryToken == token
    }

    private func completeRetainedHelperRecovery(_ plan: RetainedHelperRecoveryPlan) {
        let expectedIdentities = Set(plan.helpers.map(ObjectIdentifier.init))
        var shouldScheduleRestart = false

        lock.lock()
        guard !terminalShutdown,
              lifecycleEpoch == plan.epoch,
              activeTeardown == nil,
              helperProcess == nil,
              retainedHelperRecoveryToken == plan.token,
              Set(retiringHelpers.map(ObjectIdentifier.init)) == expectedIdentities else {
            lock.unlock()
            return
        }
        retiringHelpers = []
        retainedHelperRecoveryToken = nil
        if let restart = plan.restart {
            restartWorkItem = restart
            setStateLocked(.starting)
            lastError = "unexpected helper retirement was confirmed; automatic recovery queued"
            shouldScheduleRestart = true
        } else {
            restartWorkItem = nil
            setStateLocked(.failed)
            lastError = plan.terminalFailureDetail
        }
        lock.unlock()

        if let restart = plan.restart, shouldScheduleRestart {
            supervisorQueue.asyncAfter(deadline: .now() + plan.restartDelay, execute: restart)
        }
    }

    private func performScheduledRestart(epoch: UInt64) {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        reconcileRetiringHelpers()
        lock.lock()
        guard lifecycleEpoch == epoch,
              !terminalShutdown,
              activeTeardown == nil,
              activeSleepingDataplaneLaunchEpoch == nil,
              state == .starting,
              helperProcess == nil,
              retiringHelpers.isEmpty,
              restartWorkItem != nil else {
            lock.unlock()
            return
        }
        if let repair = activeHostDataplaneRepair {
            lock.unlock()
            // The scheduled item may reach its deadline while an older socket repair is still
            // retiring endpoints. Register an exact completion continuation instead of polling or
            // blocking the serial supervisor queue; lifecycle/epoch guards are rechecked there.
            repair.notify(on: supervisorQueue) { [weak self] in
                self?.performScheduledRestart(epoch: epoch)
            }
            return
        }
        restartWorkItem = nil
        lock.unlock()

        do {
            cleanupStaleHelpers()
            lock.lock()
            guard lifecycleEpoch == epoch,
                  !terminalShutdown,
                  activeTeardown == nil,
                  activeHostDataplaneRepair == nil,
                  activeSleepingDataplaneLaunchEpoch == nil,
                  state == .starting,
                  helperProcess == nil,
                  retiringHelpers.isEmpty else {
                lock.unlock()
                return
            }
            let readinessCycle = readinessTracker.beginCycle(trigger: "automatic-recovery")
            lock.unlock()
            try launchFreshTier(
                epoch: epoch,
                readinessCycle: readinessCycle,
                publishFailure: false
            )
        } catch TierError.startCancelled {
            return
        } catch {
            scheduleRecoveryAfterLaunchFailure(epoch: epoch, error: error)
        }
    }

    private func scheduleRecoveryAfterLaunchFailure(epoch: UInt64, error: Error) {
        let restart: DispatchWorkItem?
        let delay: TimeInterval

        lock.lock()
        guard !terminalShutdown,
              lifecycleEpoch == epoch,
              state == .starting else {
            lock.unlock()
            return
        }
        let policy = managedRestartPolicy
        if unexpectedRestartCount < policy.maxRestarts {
            unexpectedRestartCount += 1
            lifecycleEpoch &+= 1
            let nextEpoch = lifecycleEpoch
            let attempt = unexpectedRestartCount
            let item = DispatchWorkItem { [weak self] in
                self?.performScheduledRestart(epoch: nextEpoch)
            }
            restart = item
            restartWorkItem = item
            delay = policy.delay(forAttempt: attempt)
            setStateLocked(.starting)
            lastError = "restart attempt \(attempt - 1) failed: \(error); attempt \(attempt)/\(policy.maxRestarts) queued"
        } else {
            restart = nil
            restartWorkItem = nil
            delay = 0
            setStateLocked(.failed)
            lastError = "automatic restart limit (\(policy.maxRestarts)) exhausted after launch failure: \(error)"
        }
        lock.unlock()

        if let restart {
            supervisorQueue.asyncAfter(deadline: .now() + delay, execute: restart)
        }
    }

    private func removeRuntimeSockets() {
        unlink(socket.path)
        guard configuration.hasManagedHelper else { return }
        unlink(configuration.forwardSocketPath)
        if let dockerdSocketPath = configuration.dockerdSocketPath {
            unlink(dockerdSocketPath)
        }
        if let activitySocketPath = configuration.activitySocketPath {
            unlink(activitySocketPath)
        }
        if let handoffSocketPath = configuration.vmmProcess?.handoffSocketPath {
            unlink(handoffSocketPath)
        }
    }

    private func removeHostDataplaneSockets() {
        unlink(socket.path)
        if let activitySocketPath = configuration.activitySocketPath {
            unlink(activitySocketPath)
        }
    }

    private func startActivityServerIfNeeded() throws -> DataplaneActivityServer? {
        guard let idleController, let path = configuration.activitySocketPath else { return nil }
        let server = DataplaneActivityServer(path: path, idle: idleController) { [weak self] in
            await self?.ensureAwake()
        }
        try server.start()
        return server
    }

    private struct DataplaneResources {
        var handle: DoryDataplaneHandle
        var activityServer: DataplaneActivityServer?
    }

    private func startDataplane() throws -> DataplaneResources {
        beforeDataplaneStart()
        let server = try startActivityServerIfNeeded()
        do {
            let fd = try socket.bind()
            let handle: DoryDataplaneHandle
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                if let activitySocketPath = configuration.activitySocketPath, idleController != nil {
                    handle = DoryCore.startDockerDataplane(
                        listenFD: fd,
                        dockerdSocketPath: dockerdSocketPath,
                        gpuSupported: configuration.gpuSupported,
                        activitySocketPath: activitySocketPath
                    )
                } else {
                    handle = DoryCore.startDockerDataplane(
                        listenFD: fd,
                        dockerdSocketPath: dockerdSocketPath,
                        gpuSupported: configuration.gpuSupported
                    )
                }
            } else {
                if let activitySocketPath = configuration.activitySocketPath, idleController != nil {
                    handle = DoryCore.startDockerForwardDataplane(
                        listenFD: fd,
                        forwardSocketPath: configuration.forwardSocketPath,
                        cid: configuration.cid,
                        port: configuration.dockerPort,
                        gpuSupported: configuration.gpuSupported,
                        activitySocketPath: activitySocketPath
                    )
                } else {
                    handle = DoryCore.startDockerForwardDataplane(
                        listenFD: fd,
                        forwardSocketPath: configuration.forwardSocketPath,
                        cid: configuration.cid,
                        port: configuration.dockerPort,
                        gpuSupported: configuration.gpuSupported
                    )
                }
            }
            return DataplaneResources(handle: handle, activityServer: server)
        } catch {
            server?.stop()
            throw error
        }
    }

    @discardableResult
    private func tearDown(
        markStopped: Bool,
        publishStoppedIntent: Bool = false,
        terminal: Bool = false
    ) -> Bool {
        let operation: TeardownOperation

        lock.lock()
        if terminal {
            terminalShutdown = true
        }
        if let existing = activeTeardown {
            operation = existing
            lock.unlock()
            guard let joinedResult = operation.wait() else { return false }
            // Unexpected-loss cleanup does not itself satisfy an explicit/terminal stop request.
            // Join that exact cleanup, then claim a new stop generation so a queued restart cannot
            // escape merely because the caller arrived while endpoint retirement was in flight.
            if !operation.markStopped {
                return tearDown(
                    markStopped: markStopped,
                    publishStoppedIntent: publishStoppedIntent,
                    terminal: terminal
                )
            }
            return joinedResult
        }

        var helpersToStop: [any DockerManagedProcess] = []
        var seenHelpers: Set<ObjectIdentifier> = []
        func appendHelper(_ helper: (any DockerManagedProcess)?) {
            guard let helper else { return }
            let identity = ObjectIdentifier(helper)
            guard seenHelpers.insert(identity).inserted else { return }
            helpersToStop.append(helper)
        }

        lifecycleEpoch &+= 1
        let teardownEpoch = lifecycleEpoch
        retainedHelperRecoveryToken = nil
        let readinessCycle = readinessTracker.currentCycleToken()
        appendHelper(helperProcess)
        for helper in retiringHelpers { appendHelper(helper) }
        operation = TeardownOperation(
            epoch: teardownEpoch,
            dataplane: dataplane,
            activityServer: activityServer,
            wakeTask: wakeTask,
            restartWorkItem: restartWorkItem,
            helpers: helpersToStop,
            readinessCycle: readinessCycle,
            markStopped: markStopped,
            publishStoppedIntent: publishStoppedIntent
        )
        activeTeardown = operation
        dataplane = nil
        helperProcess = nil
        retiringHelpers = []
        activityServer = nil
        wakeTask = nil
        restartWorkItem = nil
        activeHelperGeneration = nil
        activeGuestDataDiskLaunchAuthority = nil
        helperStartedAt = nil
        if markStopped {
            setStateLocked(.failed)
            lastError = "docker tier teardown is in progress"
        }
        lock.unlock()

        // Cancellation, endpoint shutdown, guest-agent disconnect, and process termination can
        // all block or call back into DockerTier. The operation token excludes replacement
        // lifecycles while every one of these calls runs without the tier lock.
        operation.wakeTask?.cancel()
        operation.restartWorkItem?.cancel()
        removeRuntimeSockets()
        operation.dataplane?.shutdown()
        operation.activityServer?.stop()
        agentControl?.disconnect()
        var unconfirmedHelpers: [any DockerManagedProcess] = []
        for helper in operation.helpers {
            let reportedTerminated = helper.stop()
            // A false result can become stale at the return boundary. Preserve authority only
            // after a separate exact liveness observation confirms the same object is still live.
            if !reportedTerminated,
               Self.observeManagedProcess(helper)?.isRunning != false {
                unconfirmedHelpers.append(helper)
            }
        }

        lock.lock()
        guard activeTeardown === operation, lifecycleEpoch == operation.epoch else {
            lock.unlock()
            operation.finish(result: false)
            return false
        }
        retiringHelpers = unconfirmedHelpers
        let allHelpersTerminated = unconfirmedHelpers.isEmpty
        if operation.markStopped {
            unexpectedRestartCount = 0
            if allHelpersTerminated {
                setStateLocked(.stopped)
                lastError = nil
                if operation.publishStoppedIntent, !terminalShutdown {
                    enqueueLifecycleStateObserverLocked(.stopped)
                }
            } else {
                setStateLocked(.failed)
                lastError = "engine stop could not confirm helper exit: \(TierError.helperTerminationPending.description)"
            }
        }
        activeTeardown = nil
        lock.unlock()
        operation.finish(result: allHelpersTerminated)
        idleController?.setSleeping(false)
        if operation.markStopped, allHelpersTerminated {
            readinessTracker.markStopped(
                cycle: operation.readinessCycle,
                detail: "engine was explicitly stopped"
            )
        }
        return allHelpersTerminated
    }

    deinit {
        stop()
    }
}

extension DockerTier: HostSleepHandling, WakeClockSyncing {}

private extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }

    func saturatingSubtracting(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }

    func saturatingMultiplying(by other: UInt64) -> UInt64 {
        let result = multipliedReportingOverflow(by: other)
        return result.overflow ? .max : result.partialValue
    }
}
