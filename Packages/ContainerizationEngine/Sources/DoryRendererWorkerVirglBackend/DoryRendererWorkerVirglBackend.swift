import Darwin
import DoryRendererWorkerContracts
import DoryRendererWorkerServiceCore
import DoryVirglRendererShim
import Foundation
import Metal
import OSLog

public protocol DoryRendererScanoutAlignmentProviding: Sendable {
    func minimumLinearTextureAlignment(
        pixelFormat: DoryRendererScanoutPixelFormat
    ) -> UInt32?
}

public struct DoryRendererSystemMetalAlignmentProvider:
    DoryRendererScanoutAlignmentProviding,
    Sendable
{
    public init() {}

    public func minimumLinearTextureAlignment(
        pixelFormat: DoryRendererScanoutPixelFormat
    ) -> UInt32? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let format: MTLPixelFormat = switch pixelFormat {
        case .bgra8Unorm: .bgra8Unorm
        case .rgba8Unorm: .rgba8Unorm
        }
        let alignment = device.minimumLinearTextureAlignment(for: format)
        guard alignment >= 4, alignment <= 65_536,
              alignment.nonzeroBitCount == 1 else { return nil }
        return UInt32(alignment)
    }
}

public struct DoryRendererWorkerVirglBackendSnapshot: Equatable, Sendable {
    public let isActive: Bool
    public let contextCount: Int
    public let resourceCount: Int
    public let liveScanoutLeaseCount: Int
}

/// Closed worker-side failure vocabulary. Raw foreign error text is never logged or returned.
enum DoryRendererForeignExecutionFailureStage: String, Equatable, Sendable {
    case foreignSessionOpen = "foreign-session-open"
    case foreignCall = "foreign-call"
    case foreignResultValidation = "foreign-result-validation"
    case backendInternal = "backend-internal"
}

enum DoryRendererForeignSessionErrorCase: String, Equatable, Sendable {
    case openFailed = "open-failed"
    case callFailed = "call-failed"
    case submitFailed = "submit-failed"
    case invalidResult = "invalid-result"
    case unexpected = "unexpected"
}

/// Exact allowlist of operation labels constructed by the production foreign-session adapter.
/// Unknown strings collapse to `unclassified` and never cross the diagnostic boundary.
enum DoryRendererForeignOperationLabel: String, Equatable, Sendable {
    case sessionOpen = "session-open"
    case getCapset = "virgl_renderer_get_cap_set"
    case fillCaps = "virgl_renderer_fill_caps"
    case capsetSize = "capset-size"
    case createContext = "virgl_renderer_context_create_with_flags"
    case submit3D = "virgl_renderer_submit_cmd2"
    case createBlob = "virgl_renderer_resource_create_blob"
    case createResource3D = "virgl_renderer_resource_create"
    case attachBacking = "virgl_renderer_resource_attach_iov"
    case mapInfo = "virgl_renderer_resource_get_map_info"
    case exportBlob = "virgl_renderer_resource_export_blob"
    case exportBlobDescriptor = "export-blob-fd"
    case resourceInfo = "virgl_renderer_resource_get_info"
    case acquireScanoutTexture = "virgl_renderer_create_handle_for_scanout"
    case scanoutTextureResult = "metal-scanout-texture"
    case scanoutTextureType = "metal-scanout-texture-type"
    case transferToHost = "virgl_renderer_transfer_write_iov"
    case transferFromHost = "virgl_renderer_transfer_read_iov"
    case createContextFence = "virgl_renderer_context_create_fence"
    case createGlobalFence = "virgl_renderer_create_fence"
    case exportFenceDescriptor = "export-fence-fd"
    case rendererPollDescriptor = "renderer-poll-fd"
    case closedSession = "closed-session"
    case nonSHMExport = "non-shm-export"
    case shmExportStat = "shm-export-stat"
    case shmExportBounds = "shm-export-bounds"
    case shmExportMapping = "shm-export-mapping"
    case shmExportUnmapping = "shm-export-unmapping"
    case shmExportCloseOnExec = "shm-export-cloexec"
    case resourceGeneration = "resource-generation"
    case typedOperationPayload = "typed-operation-payload"
    case unclassified
}

struct DoryRendererForeignExecutionFailureDiagnostic: Equatable, Sendable {
    let operation: DoryRendererWorkerOperation
    let requestID: UInt64
    let stage: DoryRendererForeignExecutionFailureStage
    let errorCase: DoryRendererForeignSessionErrorCase
    let foreignOperation: DoryRendererForeignOperationLabel
    let statusIsAvailable: Bool
    let status: Int32
    let submitDiagnosticIsAvailable: Bool
    let virglDecoderDiagnosticIsAvailable: Bool
    let submitContextID: UInt32
    let virglCommandID: UInt32
    let virglCommandStatus: Int32
    let createObjectSubtypeDisposition: DoryRendererCreateObjectSubtypeDisposition
    let createObjectSubtype: DoryRendererVirglObjectType?
    let createObjectCandidateCount: UInt32
    let createObjectSubtypeMask: UInt32
    let surfaceFailureReason: DoryRendererVirglSurfaceFailureReason
    let virglPrecursorCategory: DoryRendererVirglSubmitPrecursorCategory
    let elapsedNanoseconds: UInt64
}

/// virglrenderer keeps its current EGL/GL context in pthread-local state. A serial DispatchQueue
/// preserves ordering but may execute successive blocks on different pthreads, so it cannot own
/// that context. This lane gives the complete foreign-renderer lifetime one persistent native
/// thread: initialization, every command, explicit polling, inspection, and teardown.
private final class DoryRendererForeignExecutionLane: @unchecked Sendable {
    private enum LaneError: Error {
        case stopped
    }

    private final class Submission<Output>: @unchecked Sendable {
        private let condition = NSCondition()
        private let operation: () throws -> Output
        private var result: Result<Output, any Error>?

        init(operation: @escaping () throws -> Output) {
            self.operation = operation
        }

        func run() {
            let completed = Result { try operation() }
            condition.lock()
            result = completed
            condition.broadcast()
            condition.unlock()
        }

        func wait() throws -> Output {
            condition.lock()
            while result == nil { condition.wait() }
            let completed = result!
            condition.unlock()
            return try completed.get()
        }
    }

    private final class State: @unchecked Sendable {
        private let condition = NSCondition()
        private var pending = [() -> Void]()
        private var owner: pthread_t?
        private var started = false
        private var stopping = false
        private var exited = false

        func run() {
            condition.lock()
            owner = pthread_self()
            started = true
            condition.broadcast()
            condition.unlock()

            while let operation = next() {
                autoreleasepool(invoking: operation)
            }
        }

        func waitUntilStarted() {
            condition.lock()
            while !started { condition.wait() }
            condition.unlock()
        }

        func isOwnerThread() -> Bool {
            condition.lock()
            let matches = owner.map { pthread_equal(pthread_self(), $0) != 0 } ?? false
            condition.unlock()
            return matches
        }

        func enqueue(_ operation: @escaping () -> Void) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard !stopping else { return false }
            pending.append(operation)
            condition.signal()
            return true
        }

        func stopAndWait() {
            condition.lock()
            stopping = true
            condition.broadcast()
            if owner.map({ pthread_equal(pthread_self(), $0) != 0 }) != true {
                while !exited { condition.wait() }
            }
            condition.unlock()
        }

        private func next() -> (() -> Void)? {
            condition.lock()
            while pending.isEmpty, !stopping { condition.wait() }
            guard !pending.isEmpty else {
                exited = true
                condition.broadcast()
                condition.unlock()
                return nil
            }
            let operation = pending.removeFirst()
            condition.unlock()
            return operation
        }
    }

    private let state: State
    private let thread: Thread

    init() {
        let state = State()
        self.state = state
        let thread = Thread { state.run() }
        thread.name = "dory-renderer.foreign-owner"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        state.waitUntilStarted()
    }

    deinit { state.stopAndWait() }

    func sync<Output>(_ operation: @escaping () throws -> Output) throws -> Output {
        if state.isOwnerThread() { return try operation() }
        let submission = Submission(operation: operation)
        guard state.enqueue({ submission.run() }) else { throw LaneError.stopped }
        return try submission.wait()
    }
}

/// Production renderer backend. Activation is one atomic transition: exact bundle bytes are
/// verified, the static dual renderer is opened, real VirGL2 and Venus contexts are exercised,
/// VirGL's shareable Metal texture and Venus SHM paths are imported, and callback-backed fences are
/// observed before a complete receipt can exist. Any uncertain result tears down the entire process
/// generation; there is no software, frame-copy, or synchronous runtime-completion fallback.
public final class DoryRendererWorkerVirglBackend:
    DoryRendererWorkerBackend,
    @unchecked Sendable
{
    private static let maximumContexts = 4_096
    private static let maximumResources = 65_536
    private static let preflightVirgl2ContextID: UInt32 = 0xffff_fff0
    private static let preflightVenusContextID: UInt32 = 0xffff_fff1
    private static let preflightResourceID: UInt32 = 0xffff_fff2
    private static let preflightVirgl2ResourceID: UInt32 = 0xffff_fff3
    private static let preflightVirgl2BufferResourceID: UInt32 = 0xffff_fff4
    private static let preflightVirgl2Resource2DID: UInt32 = 0xffff_fff5
    private static let preflightVirgl2SurfaceObjectID: UInt32 = 0xffff_fff6
    private static let preflightGlobalFenceID: UInt64 = 0x1_0000_00f1
    private static let preflightVirgl2FenceID: UInt64 = 0xffff_ffff_ffff_ffef
    private static let preflightVenusFenceID: UInt64 = 0xffff_ffff_ffff_fff0
    private static let preflightFenceTimeoutMilliseconds: Int32 = 3_000
    private static let logger = Logger(
        subsystem: "dev.dory.renderer-worker",
        category: "scanout"
    )
    private static let executionLogger = Logger(
        subsystem: "dev.dory.renderer-worker",
        category: "execution"
    )

    private enum State {
        case cold
        case active(ActiveState)
        case failed
    }

    private final class ActiveState {
        let bootstrap: DoryRendererWorkerBootstrap
        let session: any DoryRendererForeignSession
        var contexts = [UInt32: UInt32]()
        var resources = [UInt32: ResourceState]()
        var lastResourceGenerations = [UInt32: UInt64]()
        var leases = [UUID: ScanoutLeaseState]()
        var loggedScanoutRejections = Set<UInt32>()
        var pollDriver: PollDriver?

        init(
            bootstrap: DoryRendererWorkerBootstrap,
            session: any DoryRendererForeignSession
        ) {
            self.bootstrap = bootstrap
            self.session = session
        }
    }

    /// virglrenderer uses this descriptor for non-callback event retirement even with asynchronous
    /// fence callbacks enabled. Darwin can strip the thread-sync hint and return no descriptor; in
    /// that mode a bounded timer supplies the same required pump. The source never owns or closes a
    /// borrowed descriptor.
    private final class PollDriver: @unchecked Sendable {
        private let cancellationLock = NSLock()
        private var cancelled = false
        private let readSource: DispatchSourceRead?
        private let timerSource: DispatchSourceTimer?

        init(
            descriptor: Int32?,
            handler: @escaping @Sendable () -> Void
        ) {
            let queue = DispatchQueue(
                label: "dev.dory.renderer-worker.foreign-events",
                qos: .userInteractive
            )
            if let descriptor {
                let source = DispatchSource.makeReadSource(
                    fileDescriptor: descriptor,
                    queue: queue
                )
                readSource = source
                timerSource = nil
                source.setEventHandler(handler: handler)
                source.resume()
            } else {
                let source = DispatchSource.makeTimerSource(queue: queue)
                readSource = nil
                timerSource = source
                source.schedule(
                    deadline: .now() + .milliseconds(4),
                    repeating: .milliseconds(4),
                    leeway: .milliseconds(1)
                )
                source.setEventHandler(handler: handler)
                source.resume()
            }
        }

        func cancel() {
            cancellationLock.lock()
            defer { cancellationLock.unlock() }
            guard !cancelled else { return }
            cancelled = true
            readSource?.setEventHandler {}
            timerSource?.setEventHandler {}
            readSource?.cancel()
            timerSource?.cancel()
        }

        deinit { cancel() }
    }

    private struct PreflightResult {
        let capsets: [DoryRendererForeignCapset]
        let pollDescriptor: Int32?
    }

    private final class ResourceState {
        let generation: UInt64
        let blobSize: UInt64?
        let resource3DBind: UInt32?
        var backing: OwnedBacking?
        var attachedContexts = Set<UInt32>()
        var mapped = false
        var liveLeaseIDs = Set<UUID>()

        init(
            generation: UInt64,
            blobSize: UInt64?,
            resource3DBind: UInt32?,
            backing: OwnedBacking?
        ) {
            self.generation = generation
            self.blobSize = blobSize
            self.resource3DBind = resource3DBind
            self.backing = backing
        }
    }

    private struct ScanoutLeaseState {
        let resourceID: UInt32
        let resourceGeneration: UInt64
        let releaseToken: DoryRendererScanoutReleaseToken
        let sharedTextureHandle: MTLSharedTextureHandle?
    }

    private let verifier: any DoryRendererProductionArtifactVerifying
    private let sessionFactory: any DoryRendererForeignSessionCreating
    private let alignmentProvider: any DoryRendererScanoutAlignmentProviding
    private let executionLane = DoryRendererForeignExecutionLane()
    private let lock = NSLock()
    private var state: State = .cold

    public convenience init() throws {
        try self.init(
            verifier: DoryRendererProductionArtifactVerifier(),
            sessionFactory: DoryRendererCForeignSessionFactory(),
            alignmentProvider: DoryRendererSystemMetalAlignmentProvider()
        )
    }

    public init(
        verifier: any DoryRendererProductionArtifactVerifying,
        sessionFactory: any DoryRendererForeignSessionCreating,
        alignmentProvider: any DoryRendererScanoutAlignmentProviding
    ) {
        self.verifier = verifier
        self.sessionFactory = sessionFactory
        self.alignmentProvider = alignmentProvider
    }

    deinit { invalidate() }

    public func activate(
        bootstrap: DoryRendererWorkerBootstrap
    ) throws -> DoryRendererCapabilityReceipt {
        try executionLane.sync { [self] in
            try activateOnExecutionLane(bootstrap: bootstrap)
        }
    }

    private func activateOnExecutionLane(
        bootstrap: DoryRendererWorkerBootstrap
    ) throws -> DoryRendererCapabilityReceipt {
        lock.lock()
        defer { lock.unlock() }
        guard case .cold = state else {
            throw DoryRendererWorkerBackendActivationError.capabilityReceipt
        }
        do {
            let attestation: DoryRendererArtifactAttestation
            do {
                attestation = try verifier.verify(bootstrap: bootstrap)
            } catch {
                throw DoryRendererWorkerBackendActivationError.artifactAuthority
            }
            let session: any DoryRendererForeignSession
            do {
                session = try sessionFactory.create(attestation: attestation)
            } catch {
                throw DoryRendererWorkerBackendActivationError.rendererInitialization
            }
            do {
                let preflight = try Self.preflight(session: session)
                let receiptCapsets: [DoryRendererCapsetAttestation]
                do {
                    receiptCapsets = try preflight.capsets.map { capset in
                        try DoryRendererCapsetAttestation(
                            id: capset.id,
                            maximumVersion: capset.maximumVersion,
                            data: capset.bytes
                        )
                    }
                } catch {
                    throw DoryRendererWorkerBackendActivationError.capabilityReceipt
                }
                let receipt: DoryRendererCapabilityReceipt
                do {
                    receipt = try DoryRendererCapabilityReceipt(
                        accepting: bootstrap,
                        features: .productionAcceleration,
                        capsets: receiptCapsets
                    )
                } catch {
                    throw DoryRendererWorkerBackendActivationError.capabilityReceipt
                }
                let active = ActiveState(bootstrap: bootstrap, session: session)
                state = .active(active)
                active.pollDriver = PollDriver(
                    descriptor: preflight.pollDescriptor,
                    handler: { [weak self] in self?.pollForeignEvents() }
                )
                return receipt
            } catch {
                session.invalidate()
                throw error
            }
        } catch {
            state = .failed
            throw error
        }
    }

    public func execute(
        command: DoryRendererWorkerCommand,
        descriptors: [FileHandle]
    ) throws -> DoryRendererWorkerBackendExecution {
        try executionLane.sync { [self] in
            try executeOnExecutionLane(command: command, descriptors: descriptors)
        }
    }

    private func executeOnExecutionLane(
        command: DoryRendererWorkerCommand,
        descriptors: [FileHandle]
    ) throws -> DoryRendererWorkerBackendExecution {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard case .active(let active) = state else { return .rejected }
        do {
            return try executeLocked(
                command: command,
                descriptors: descriptors,
                active: active
            )
        } catch is DoryRendererWorkerContractError {
            throw errorForProtocolViolation()
        } catch {
            let now = DispatchTime.now().uptimeNanoseconds
            let diagnostic = Self.executionFailureDiagnostic(
                command: command,
                error: error,
                elapsedNanoseconds: now >= startedAt ? now - startedAt : 0
            )
            Self.executionLogger.error(
                "command-outcome-unknown operation=\(diagnostic.operation.rawValue, privacy: .public) request=\(diagnostic.requestID, privacy: .public) stage=\(diagnostic.stage.rawValue, privacy: .public) error-case=\(diagnostic.errorCase.rawValue, privacy: .public) foreign-operation=\(diagnostic.foreignOperation.rawValue, privacy: .public) status-present=\(diagnostic.statusIsAvailable, privacy: .public) status=\(diagnostic.status, privacy: .public) submit-diagnostic-present=\(diagnostic.submitDiagnosticIsAvailable, privacy: .public) virgl-decoder-diagnostic-present=\(diagnostic.virglDecoderDiagnosticIsAvailable, privacy: .public) submit-context=\(diagnostic.submitContextID, privacy: .public) virgl-command=\(diagnostic.virglCommandID, privacy: .public) virgl-command-status=\(diagnostic.virglCommandStatus, privacy: .public) create-object-subtype-disposition=\(diagnostic.createObjectSubtypeDisposition.rawValue, privacy: .public) create-object-subtype-present=\(diagnostic.createObjectSubtype != nil, privacy: .public) create-object-subtype=\(diagnostic.createObjectSubtype?.rawValue ?? 0, privacy: .public) create-object-candidate-count=\(diagnostic.createObjectCandidateCount, privacy: .public) create-object-subtype-mask=\(diagnostic.createObjectSubtypeMask, privacy: .public) surface-failure-reason=\(diagnostic.surfaceFailureReason.rawValue, privacy: .public) virgl-precursor-category=\(diagnostic.virglPrecursorCategory.rawValue, privacy: .public) elapsed-ns=\(diagnostic.elapsedNanoseconds, privacy: .public)"
            )
            teardownLocked(active)
            state = .failed
            return .outcomeUnknown
        }
    }

    static func executionFailureDiagnostic(
        command: DoryRendererWorkerCommand,
        error: any Error,
        elapsedNanoseconds: UInt64
    ) -> DoryRendererForeignExecutionFailureDiagnostic {
        let stage: DoryRendererForeignExecutionFailureStage
        let errorCase: DoryRendererForeignSessionErrorCase
        let foreignOperation: DoryRendererForeignOperationLabel
        let statusIsAvailable: Bool
        let status: Int32
        let submitDiagnostic: DoryRendererForeignSubmitFailure?
        switch error as? DoryRendererForeignSessionError {
        case .openFailed(let value):
            stage = .foreignSessionOpen
            errorCase = .openFailed
            foreignOperation = .sessionOpen
            statusIsAvailable = true
            status = value
            submitDiagnostic = nil
        case .callFailed(let operation, let value):
            stage = .foreignCall
            errorCase = .callFailed
            foreignOperation = DoryRendererForeignOperationLabel(rawValue: operation)
                ?? .unclassified
            statusIsAvailable = true
            status = value
            submitDiagnostic = nil
        case .submitFailed(let value, let diagnostic):
            stage = .foreignCall
            errorCase = .submitFailed
            foreignOperation = .submit3D
            statusIsAvailable = true
            status = value
            submitDiagnostic = diagnostic
        case .invalidResult(let operation):
            stage = .foreignResultValidation
            errorCase = .invalidResult
            foreignOperation = DoryRendererForeignOperationLabel(rawValue: operation)
                ?? .unclassified
            statusIsAvailable = false
            status = 0
            submitDiagnostic = nil
        case nil:
            stage = .backendInternal
            errorCase = .unexpected
            foreignOperation = .unclassified
            statusIsAvailable = false
            status = 0
            submitDiagnostic = nil
        }
        return DoryRendererForeignExecutionFailureDiagnostic(
            operation: command.operation,
            requestID: command.requestID,
            stage: stage,
            errorCase: errorCase,
            foreignOperation: foreignOperation,
            statusIsAvailable: statusIsAvailable,
            status: status,
            submitDiagnosticIsAvailable: submitDiagnostic != nil,
            virglDecoderDiagnosticIsAvailable:
                submitDiagnostic?.decoderDiagnosticIsAvailable ?? false,
            submitContextID: submitDiagnostic?.contextID ?? 0,
            virglCommandID: submitDiagnostic?.commandID ?? 0,
            virglCommandStatus: submitDiagnostic?.status ?? 0,
            createObjectSubtypeDisposition:
                submitDiagnostic?.createObjectSubtypeDisposition ?? .absent,
            createObjectSubtype: submitDiagnostic?.createObjectSubtype,
            createObjectCandidateCount: submitDiagnostic?.createObjectCandidateCount ?? 0,
            createObjectSubtypeMask: submitDiagnostic?.createObjectSubtypeMask ?? 0,
            surfaceFailureReason: submitDiagnostic?.surfaceFailureReason ?? .none,
            virglPrecursorCategory: submitDiagnostic?.precursorCategory ?? .none,
            elapsedNanoseconds: elapsedNanoseconds
        )
    }

    public func invalidate() {
        _ = try? executionLane.sync { [self] in
            lock.lock()
            defer { lock.unlock() }
            if case .active(let active) = state { teardownLocked(active) }
            state = .failed
        }
    }

    public func snapshot() -> DoryRendererWorkerVirglBackendSnapshot {
        let unavailable = DoryRendererWorkerVirglBackendSnapshot(
            isActive: false,
            contextCount: 0,
            resourceCount: 0,
            liveScanoutLeaseCount: 0
        )
        return (try? executionLane.sync { [self] in
            lock.withLock {
                switch state {
                case .cold, .failed:
                    return unavailable
                case .active(let active):
                    return DoryRendererWorkerVirglBackendSnapshot(
                        isActive: true,
                        contextCount: active.contexts.count,
                        resourceCount: active.resources.count,
                        liveScanoutLeaseCount: active.leases.count
                    )
                }
            }
        }) ?? unavailable
    }

    private func executeLocked(
        command: DoryRendererWorkerCommand,
        descriptors: [FileHandle],
        active: ActiveState
    ) throws -> DoryRendererWorkerBackendExecution {
        switch command.operation {
        case .createContext:
            guard active.contexts.count < Self.maximumContexts,
                  active.contexts[command.contextID] == nil else { return .rejected }
            let payload = try DoryRendererContextCreatePayload.decode(command.payload)
            guard payload.capsetID == 2 || payload.capsetID == 4 else { return .rejected }
            try active.session.createContext(
                id: command.contextID,
                capsetID: payload.capsetID,
                name: payload.name
            )
            active.contexts[command.contextID] = payload.capsetID
            return .success(payload: Data(), descriptors: [])

        case .createResource3D:
            guard active.resources.count < Self.maximumResources,
                  active.resources[command.resourceID] == nil else { return .rejected }
            let payload = try DoryRendererResource3DCreatePayload.decode(
                command.payload,
                maximumReferencedBytes: active.bootstrap.limits.maximumReferencedBytes
            )
            try active.session.createResource3D(
                DoryRendererForeignResource3DCreate(
                    resourceID: command.resourceID,
                    payload: payload
                )
            )
            let generation = try nextResourceGeneration(
                resourceID: command.resourceID,
                active: active
            )
            active.resources[command.resourceID] = ResourceState(
                generation: generation,
                blobSize: nil,
                resource3DBind: payload.bind,
                backing: nil
            )
            return .success(payload: Self.encodeUInt64(generation), descriptors: [])

        case .destroyContext:
            guard active.contexts.removeValue(forKey: command.contextID) != nil else {
                return .rejected
            }
            for (resourceID, resource) in active.resources
                where resource.attachedContexts.remove(command.contextID) != nil {
                // The local state proved both identities before this void foreign call.
                // Detaching first also makes retained backing teardown deterministic.
                active.session.detachResource(
                    contextID: command.contextID,
                    resourceID: resourceID
                )
            }
            active.session.destroyContext(id: command.contextID)
            return .success(payload: Data(), descriptors: [])

        case .attachResource:
            guard active.contexts[command.contextID] != nil,
                  let resource = matchingResource(command, active: active) else {
                return .rejected
            }
            // Linux GEM open can emit the same context/resource attach more than once. QEMU
            // forwards every request and virglrenderer treats an already-attached resource as a
            // successful no-op, so preserve that public lifecycle contract while still proving
            // both identities and the authenticated resource generation above.
            guard resource.attachedContexts.insert(command.contextID).inserted else {
                return .success(payload: Data(), descriptors: [])
            }
            active.session.attachResource(
                contextID: command.contextID,
                resourceID: command.resourceID
            )
            return .success(payload: Data(), descriptors: [])

        case .detachResource:
            guard active.contexts[command.contextID] != nil,
                  let resource = matchingResource(command, active: active) else {
                return .rejected
            }
            // The matching Linux GEM close path and virglrenderer detach callback are likewise
            // idempotent. Do not turn harmless duplicate cleanup into a guest-visible GPU fault.
            guard resource.attachedContexts.remove(command.contextID) != nil else {
                return .success(payload: Data(), descriptors: [])
            }
            active.session.detachResource(
                contextID: command.contextID,
                resourceID: command.resourceID
            )
            return .success(payload: Data(), descriptors: [])

        case .submit3D:
            guard active.contexts[command.contextID] != nil,
                  let region = command.sharedRegions.first else { return .rejected }
            let mapping = try OwnedBacking(
                regions: [region],
                descriptors: descriptors
            )
            guard let baseAddress = mapping.iovecs.pointee.iov_base else { return .rejected }
            try active.session.submit(
                contextID: command.contextID,
                bytes: UnsafeRawPointer(baseAddress),
                dwordCount: UInt32(region.length / 4)
            )
            return .success(payload: Data(), descriptors: [])

        case .createBlob:
            guard active.resources.count < Self.maximumResources,
                  active.resources[command.resourceID] == nil,
                  command.contextID == 0 || active.contexts[command.contextID] != nil else {
                return .rejected
            }
            let payload = try DoryRendererBlobCreatePayload.decode(command.payload)
            guard payload.size <= active.bootstrap.limits.maximumReferencedBytes else {
                return .rejected
            }
            let backing = command.sharedRegions.isEmpty
                ? nil
                : try OwnedBacking(regions: command.sharedRegions, descriptors: descriptors)
            try active.session.createBlob(
                DoryRendererForeignBlobCreate(
                    resourceID: command.resourceID,
                    contextID: command.contextID,
                    payload: payload
                ),
                iovecs: backing?.iovecs,
                iovecCount: backing?.count ?? 0
            )
            let generation = try nextResourceGeneration(
                resourceID: command.resourceID,
                active: active
            )
            active.resources[command.resourceID] = ResourceState(
                generation: generation,
                blobSize: payload.size,
                resource3DBind: nil,
                backing: backing
            )
            return .success(payload: Self.encodeUInt64(generation), descriptors: [])

        case .attachBacking:
            guard let resource = matchingResource(command, active: active),
                  resource.backing == nil,
                  !resource.mapped,
                  resource.liveLeaseIDs.isEmpty else { return .rejected }
            let backing = try OwnedBacking(
                regions: command.sharedRegions,
                descriptors: descriptors
            )
            try active.session.attachBacking(
                resourceID: command.resourceID,
                iovecs: backing.iovecs,
                iovecCount: backing.count
            )
            resource.backing = backing
            return .success(payload: Data(), descriptors: [])

        case .detachBacking:
            guard let resource = matchingResource(command, active: active),
                  resource.backing != nil,
                  !resource.mapped,
                  resource.liveLeaseIDs.isEmpty else { return .rejected }
            active.session.detachBacking(resourceID: command.resourceID)
            resource.backing = nil
            return .success(payload: Data(), descriptors: [])

        case .unrefResource:
            guard let resource = matchingResource(command, active: active),
                  resource.attachedContexts.isEmpty,
                  !resource.mapped,
                  resource.liveLeaseIDs.isEmpty else { return .rejected }
            if resource.backing != nil {
                // virglrenderer borrows these iovecs. Keep OwnedBacking (and its mmap regions)
                // alive through the foreign detach, then revoke that memory authority before the
                // resource handle is unreferenced or becomes eligible for same-ID reuse.
                active.session.detachBacking(resourceID: command.resourceID)
                resource.backing = nil
            }
            active.session.unrefResource(id: command.resourceID)
            active.resources.removeValue(forKey: command.resourceID)
            return .success(payload: Data(), descriptors: [])

        case .mapBlob:
            guard let resource = matchingResource(command, active: active),
                  let blobSize = resource.blobSize,
                  !resource.mapped else { return .rejected }
            let mapInfo = try active.session.mapInfo(resourceID: command.resourceID) & 0x0f
            let exported = try active.session.exportBlob(resourceID: command.resourceID)
            let validated = try Self.validateExportedSHM(
                exported,
                minimumBytes: blobSize,
                maximumBytes: active.bootstrap.limits.maximumReferencedBytes
            )
            do {
                let lease = try DoryRendererBlobMappingLease(
                    workerGeneration: active.bootstrap.generation,
                    resourceID: command.resourceID,
                    resourceGeneration: resource.generation,
                    sharedRegionID: DoryRendererSharedRegionID.random(),
                    descriptorIndex: 0,
                    mapInfo: mapInfo,
                    declaredFileSize: validated.fileSize,
                    mappingByteCount: blobSize,
                    limits: active.bootstrap.limits
                )
                resource.mapped = true
                return .success(
                    payload: DoryRendererBlobMappingLeaseCodec.encode(lease),
                    descriptors: [FileHandle(
                        fileDescriptor: validated.fileDescriptor,
                        closeOnDealloc: true
                    )]
                )
            } catch {
                close(validated.fileDescriptor)
                throw error
            }

        case .unmapBlob:
            guard let resource = matchingResource(command, active: active),
                  resource.mapped else { return .rejected }
            // `mapBlob` exported an owned SHM descriptor; it did not call the process-local
            // `virgl_renderer_resource_map`, so no foreign unmap state exists to release here.
            resource.mapped = false
            return .success(payload: Data(), descriptors: [])

        case .transferToHost3D, .transferFromHost3D:
            guard matchingResource(command, active: active) != nil,
                  command.contextID == 0 || active.contexts[command.contextID] != nil else {
                return .rejected
            }
            let payload = try DoryRendererTransfer3DPayload.decode(
                command.payload,
                operation: command.operation
            )
            let backing = command.sharedRegions.isEmpty
                ? nil
                : try OwnedBacking(regions: command.sharedRegions, descriptors: descriptors)
            try active.session.transfer(
                toHost: command.operation == .transferToHost3D,
                resourceID: command.resourceID,
                contextID: command.contextID,
                payload: payload,
                iovecs: backing?.iovecs,
                iovecCount: backing?.count ?? 0
            )
            return .success(payload: Data(), descriptors: [])

        case .createFence:
            let payload = try DoryRendererFencePayload.decode(command.payload)
            let hasAuthorizedTimeline = payload.isContextTimeline
                ? command.contextID != 0 && active.contexts[command.contextID] != nil
                : command.contextID == 0 || active.contexts[command.contextID] != nil
            guard hasAuthorizedTimeline else {
                // Context-timeline fences require an authenticated live context. Global fences
                // order ctx0 resource mutations or a live submit context, but never a stale one.
                return .rejected
            }
            if payload.isContextTimeline {
                try active.session.createFence(
                    contextID: command.contextID,
                    // The worker bit is protocol metadata. Virgl bit 0 means MERGEABLE, not
                    // "context timeline", so it must not be forwarded into the foreign ABI.
                    flags: 0,
                    ringIndex: payload.ringIndex,
                    fenceID: payload.fenceID
                )
            } else {
                try active.session.createGlobalFence(fenceID: payload.fenceID)
            }
            let brokerDescriptor = try active.session.exportFence(fenceID: payload.fenceID)
            return .success(
                payload: payload.encoded,
                descriptors: [FileHandle(
                    fileDescriptor: brokerDescriptor,
                    closeOnDealloc: true
                )]
            )

        case .acquireScanoutLease:
            guard let resource = matchingResource(command, active: active),
                  // Dumb-KMS RESOURCE_CREATE_2D scanouts are valid without a VirGL context.
                  // Blob scanouts remain context-owned, while classic resources must still pass
                  // the generation, SCANOUT-bind, resource-info, and Metal checks below.
                  resource.blobSize == nil || !resource.attachedContexts.isEmpty,
                  active.leases.count < active.bootstrap.limits.maximumLiveScanoutLeases else {
                return .rejected
            }
            let payload = try DoryRendererScanoutAcquirePayload.decode(command.payload)
            let pixelFormat: DoryRendererScanoutPixelFormat = switch payload.virglFormat {
            case 1: .bgra8Unorm
            case 67: .rgba8Unorm
            default: throw DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .acquireScanoutLease
            )
            }
            if resource.blobSize == nil {
                return try acquireSharedTextureScanout(
                    command: command,
                    payload: payload,
                    pixelFormat: pixelFormat,
                    resource: resource,
                    active: active
                )
            }
            guard let blobSize = resource.blobSize else { return .rejected }
            guard let rowAlignment = alignmentProvider.minimumLinearTextureAlignment(
                pixelFormat: pixelFormat
            ), rowAlignment >= 4,
               rowAlignment <= 65_536,
               rowAlignment.nonzeroBitCount == 1 else {
                logScanoutRejection(
                    active: active,
                    resourceID: command.resourceID,
                    reason: "invalid-metal-row-alignment"
                )
                return .rejected
            }
            // Venus blob resources have no pipe_resource, so virgl_renderer_resource_get_info
            // intentionally returns no dimensions or stride. The authenticated VMM supplies the
            // SET_SCANOUT_BLOB layout; this process independently proves it fits the exact worker
            // allocation and exported SHM object below.
            let (minimumStride, minimumStrideOverflow) = UInt64(payload.width)
                .multipliedReportingOverflow(by: pixelFormat.bytesPerPixel)
            guard !minimumStrideOverflow,
                  UInt64(payload.stride) >= minimumStride,
                  payload.stride.isMultiple(of: rowAlignment),
                  payload.storageOffset.isMultiple(of: rowAlignment) else {
                logScanoutRejection(
                    active: active,
                    resourceID: command.resourceID,
                    reason: "invalid-stride expected-min=\(minimumStride) alignment="
                        + "\(rowAlignment) actual=\(payload.stride) offset="
                        + "\(payload.storageOffset)"
                )
                return .rejected
            }
            let storageOffset = UInt64(payload.storageOffset)
            let (leaseBytes, leaseOverflow) = UInt64(payload.stride)
                .multipliedReportingOverflow(by: UInt64(payload.height))
            guard !leaseOverflow,
                  leaseBytes > 0,
                  leaseBytes <= active.bootstrap.limits.maximumScanoutBytes else {
                logScanoutRejection(
                    active: active,
                    resourceID: command.resourceID,
                    reason: "invalid-lease-size bytes=\(leaseBytes)"
                )
                return .rejected
            }
            let (requiredFileBytes, requiredFileBytesOverflow) = storageOffset
                .addingReportingOverflow(leaseBytes)
            guard !requiredFileBytesOverflow,
                  requiredFileBytes <= blobSize,
                  requiredFileBytes <= active.bootstrap.limits.maximumScanoutBytes else {
                logScanoutRejection(
                    active: active,
                    resourceID: command.resourceID,
                    reason: "scanout-exceeds-blob required=\(requiredFileBytes) blob=\(blobSize)"
                )
                return .rejected
            }
            let exported = try active.session.exportBlob(resourceID: command.resourceID)
            let validated = try Self.validateExportedSHM(
                exported,
                minimumBytes: requiredFileBytes,
                maximumBytes: active.bootstrap.limits.maximumScanoutBytes
            )
            do {
                let leaseID = try DoryRendererScanoutLeaseID(rawValue: UUID())
                let releaseToken = try DoryRendererScanoutReleaseToken(rawValue: UUID())
                let lease = try DoryRendererScanoutLease(
                    workerGeneration: active.bootstrap.generation,
                    resourceID: command.resourceID,
                    resourceGeneration: resource.generation,
                    leaseID: leaseID,
                    releaseToken: releaseToken,
                    sharedRegionID: DoryRendererSharedRegionID.random(),
                    sharedMemoryDescriptorIndex: 0,
                    synchronization: .managedGuestProducerCompleteFlush,
                    pixelFormat: pixelFormat,
                    yOriginTop: true,
                    width: payload.width,
                    height: payload.height,
                    stride: payload.stride,
                    rowAlignment: rowAlignment,
                    storageOffset: storageOffset,
                    declaredFileSize: validated.fileSize,
                    leaseByteCount: leaseBytes,
                    limits: active.bootstrap.limits
                )
                active.leases[leaseID.rawValue] = ScanoutLeaseState(
                    resourceID: command.resourceID,
                    resourceGeneration: resource.generation,
                    releaseToken: releaseToken,
                    sharedTextureHandle: nil
                )
                resource.liveLeaseIDs.insert(leaseID.rawValue)
                return .success(
                    payload: DoryRendererScanoutLeaseCodec.encode(lease),
                    descriptors: [
                        FileHandle(
                            fileDescriptor: validated.fileDescriptor,
                            closeOnDealloc: true
                        )
                    ]
                )
            } catch {
                close(validated.fileDescriptor)
                throw error
            }

        case .releaseScanoutLease:
            guard let resource = matchingResource(command, active: active) else {
                return .rejected
            }
            let releaseToken = try DoryRendererScanoutReleaseToken.decodeCommandPayload(
                command.payload
            )
            guard let lease = active.leases.first(where: {
                $0.value.resourceID == command.resourceID &&
                    $0.value.resourceGeneration == command.resourceGeneration &&
                    $0.value.releaseToken == releaseToken
            }),
            resource.liveLeaseIDs.remove(lease.key) != nil else { return .rejected }
            active.leases.removeValue(forKey: lease.key)
            return .success(payload: Data(), descriptors: [])

        case .resetAfterDeviceQuiesce:
            let reset = try DoryRendererResetPayload.decode(command.payload)
            guard reset.successorGeneration > active.bootstrap.generation.rawValue else {
                return .rejected
            }
            teardownLocked(active)
            state = .failed
            return .success(payload: reset.encoded, descriptors: [])
        }
    }

    private func acquireSharedTextureScanout(
        command: DoryRendererWorkerCommand,
        payload: DoryRendererScanoutAcquirePayload,
        pixelFormat: DoryRendererScanoutPixelFormat,
        resource: ResourceState,
        active: ActiveState
    ) throws -> DoryRendererWorkerBackendExecution {
        guard let bind = resource.resource3DBind,
              bind & UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT) != 0 else {
            return .rejected
        }
        let (minimumStride, strideOverflow) = payload.width.multipliedReportingOverflow(by: 4)
        guard !strideOverflow,
              payload.stride == minimumStride,
              payload.storageOffset == 0 else { return .rejected }
        let info = try active.session.resourceInfo(resourceID: command.resourceID)
        guard info.resourceID == command.resourceID,
              Self.canonicalScanoutFormat(info.format) == payload.virglFormat,
              info.width == payload.width,
              info.height == payload.height,
              info.flags & ~UInt32(1) == 0 else { return .rejected }

        let texture = try active.session.acquireScanoutMetalTexture(
            resourceID: command.resourceID,
            width: payload.width,
            height: payload.height,
            virglFormat: payload.virglFormat,
            stride: payload.stride,
            offset: payload.storageOffset
        )
        let expectedMetalFormat: MTLPixelFormat = switch pixelFormat {
        case .bgra8Unorm: .bgra8Unorm
        case .rgba8Unorm: .rgba8Unorm
        }
        guard texture.textureType == .type2D,
              texture.pixelFormat == expectedMetalFormat,
              texture.width == Int(payload.width),
              texture.height == Int(payload.height),
              texture.depth == 1,
              texture.arrayLength == 1,
              texture.mipmapLevelCount == 1,
              texture.sampleCount == 1,
              texture.storageMode == .private,
              texture.usage.contains(.shaderRead),
              let sharedTextureHandle = texture.makeSharedTextureHandle() else {
            return .rejected
        }

        let leaseID = try DoryRendererScanoutLeaseID(rawValue: UUID())
        let releaseToken = try DoryRendererScanoutReleaseToken(rawValue: UUID())
        let lease = try DoryRendererSharedTextureScanoutLease(
            workerGeneration: active.bootstrap.generation,
            resourceID: command.resourceID,
            resourceGeneration: resource.generation,
            leaseID: leaseID,
            releaseToken: releaseToken,
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: pixelFormat,
            yOriginTop: info.flags & 1 != 0,
            width: payload.width,
            height: payload.height,
            limits: active.bootstrap.limits
        )
        active.leases[leaseID.rawValue] = ScanoutLeaseState(
            resourceID: command.resourceID,
            resourceGeneration: resource.generation,
            releaseToken: releaseToken,
            sharedTextureHandle: sharedTextureHandle
        )
        resource.liveLeaseIDs.insert(leaseID.rawValue)
        return .success(
            payload: DoryRendererSharedTextureScanoutLeaseCodec.encode(lease),
            descriptors: [],
            sharedTextureHandle: sharedTextureHandle
        )
    }

    /// Virtio's XRGB/XBGR formats differ from their alpha variants only in whether scanout
    /// consumes the high byte. The VMM deliberately carries the alpha-equivalent Metal format
    /// across XPC, while virglrenderer reports the resource's original guest format. Compare both
    /// sides in that same closed color-layout vocabulary; no other format is admitted.
    private static func canonicalScanoutFormat(_ virglFormat: UInt32) -> UInt32? {
        switch virglFormat {
        case 1, 2: 1
        case 67, 68: 67
        default: nil
        }
    }

    private static func preflight(
        session: any DoryRendererForeignSession
    ) throws -> PreflightResult {
        let pollDescriptor: Int32?
        do {
            pollDescriptor = try session.pollDescriptor()
        } catch {
            throw DoryRendererWorkerBackendActivationError.fenceExport
        }
        let virgl2: DoryRendererForeignCapset
        do {
            virgl2 = try session.capset(id: 2)
        } catch {
            throw DoryRendererWorkerBackendActivationError.virgl2Capability
        }
        guard virgl2.maximumVersion > 0, !virgl2.bytes.isEmpty else {
            throw DoryRendererWorkerBackendActivationError.virgl2Capability
        }
        let venus: DoryRendererForeignCapset
        do {
            venus = try session.capset(id: 4)
        } catch {
            throw DoryRendererWorkerBackendActivationError.venusCapability
        }
        // `virgl_renderer_get_cap_set` deliberately reports Venus at outer version zero. The
        // returned payload carries the Venus wire/XML/spec versions and is the capability proof.
        guard venus.maximumVersion == 0, !venus.bytes.isEmpty else {
            throw DoryRendererWorkerBackendActivationError.venusCapability
        }

        let resource2DBackingByteCount = 4 * 4 * 4
        let resource2DBacking = UnsafeMutableRawPointer.allocate(
            byteCount: resource2DBackingByteCount,
            alignment: 16
        )
        resource2DBacking.initializeMemory(
            as: UInt8.self,
            repeating: 0xa5,
            count: resource2DBackingByteCount
        )
        defer { resource2DBacking.deallocate() }

        var virgl2Created = false
        var virgl2BufferCreated = false
        var virgl2Resource2DCreated = false
        var virgl2Resource2DBackingAttached = false
        var virgl2ResourceCreated = false
        var venusCreated = false
        var blobCreated = false
        defer {
            if blobCreated { session.unrefResource(id: preflightResourceID) }
            if virgl2ResourceCreated {
                session.detachResource(
                    contextID: preflightVirgl2ContextID,
                    resourceID: preflightVirgl2ResourceID
                )
                session.unrefResource(id: preflightVirgl2ResourceID)
            }
            if virgl2Resource2DCreated {
                session.detachResource(
                    contextID: preflightVirgl2ContextID,
                    resourceID: preflightVirgl2Resource2DID
                )
                if virgl2Resource2DBackingAttached {
                    session.detachBacking(resourceID: preflightVirgl2Resource2DID)
                }
                session.unrefResource(id: preflightVirgl2Resource2DID)
            }
            if virgl2BufferCreated {
                session.unrefResource(id: preflightVirgl2BufferResourceID)
            }
            if venusCreated { session.destroyContext(id: preflightVenusContextID) }
            if virgl2Created { session.destroyContext(id: preflightVirgl2ContextID) }
        }
        do {
            try session.createContext(
                id: preflightVirgl2ContextID,
                capsetID: 2,
                name: "dory-preflight-virgl2"
            )
            virgl2Created = true
            // Linux creates ordinary PIPE_BUFFER resources immediately after desktop readiness.
            // This exact allocation reaches vrend's glGenBuffersARB path, so it must succeed on
            // the persistent owner pthread before this worker may advertise VirGL2.
            let buffer = try DoryRendererResource3DCreatePayload(
                target: 0, // Pinned Gallium ABI: PIPE_BUFFER.
                format: 64, // Pinned virgl ABI: VIRGL_FORMAT_R8_UNORM.
                bind: 1 << 4, // Pinned Gallium ABI: PIPE_BIND_VERTEX_BUFFER.
                width: 4_096,
                height: 1,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                samples: 0,
                flags: 0
            )
            try session.createResource3D(
                DoryRendererForeignResource3DCreate(
                    resourceID: preflightVirgl2BufferResourceID,
                    payload: buffer
                )
            )
            virgl2BufferCreated = true
            // Match Dory's RESOURCE_CREATE_2D renderer translation exactly, then prove that the
            // resulting resource is visible in the VirGL context by creating and destroying a
            // surface object. This catches a silently ignored context attachment before VirGL2 is
            // advertised to Linux.
            let resource2D = try DoryRendererResource3DCreatePayload(
                target: 2, // Pinned Gallium ABI: PIPE_TEXTURE_2D.
                format: UInt32(DORY_VIRGL_RENDERER_FORMAT_BGRA8_UNORM),
                bind: UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET) |
                    UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT),
                width: 4,
                height: 4,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                samples: 0,
                flags: 1 // Pinned virgl ABI: VIRGL_RESOURCE_Y_0_TOP.
            )
            try session.createResource3D(
                DoryRendererForeignResource3DCreate(
                    resourceID: preflightVirgl2Resource2DID,
                    payload: resource2D
                )
            )
            virgl2Resource2DCreated = true
            session.attachResource(
                contextID: preflightVirgl2ContextID,
                resourceID: preflightVirgl2Resource2DID
            )
            var resource2DBackingIOVec = iovec(
                iov_base: resource2DBacking,
                iov_len: resource2DBackingByteCount
            )
            // Treat a foreign attach error as mutation-uncertain for cleanup: detaching is safe
            // before unref and keeps the backing allocation alive through the teardown attempt.
            virgl2Resource2DBackingAttached = true
            try session.attachBacking(
                resourceID: preflightVirgl2Resource2DID,
                iovecs: &resource2DBackingIOVec,
                iovecCount: 1
            )
            // Match RESOURCE_TRANSFER_TO_HOST_2D: ctx0, natural renderer strides, and the
            // resource's retained backing rather than an operation-local iovec override.
            try session.transfer(
                toHost: true,
                resourceID: preflightVirgl2Resource2DID,
                contextID: 0,
                payload: DoryRendererTransfer3DPayload(
                    level: 0,
                    stride: 0,
                    layerStride: 0,
                    offset: 0,
                    x: 0,
                    y: 0,
                    z: 0,
                    width: 4,
                    height: 4,
                    depth: 1
                ),
                iovecs: nil,
                iovecCount: 0
            )
            try submitVirgl2SurfaceLifecycle(session: session)
            let resource = try DoryRendererResource3DCreatePayload(
                target: 2,
                format: UInt32(DORY_VIRGL_RENDERER_FORMAT_BGRA8_UNORM),
                bind: UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET) |
                    UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SAMPLER_VIEW) |
                    UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT),
                width: 4,
                height: 4,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                samples: 0,
                flags: 0
            )
            try session.createResource3D(
                DoryRendererForeignResource3DCreate(
                    resourceID: preflightVirgl2ResourceID,
                    payload: resource
                )
            )
            virgl2ResourceCreated = true
            session.attachResource(
                contextID: preflightVirgl2ContextID,
                resourceID: preflightVirgl2ResourceID
            )
            let texture = try session.acquireScanoutMetalTexture(
                resourceID: preflightVirgl2ResourceID,
                width: 4,
                height: 4,
                virglFormat: UInt32(DORY_VIRGL_RENDERER_FORMAT_BGRA8_UNORM),
                stride: 16,
                offset: 0
            )
            guard texture.textureType == .type2D,
                  texture.pixelFormat == .bgra8Unorm,
                  texture.width == 4,
                  texture.height == 4,
                  texture.depth == 1,
                  texture.arrayLength == 1,
                  texture.mipmapLevelCount == 1,
                  texture.sampleCount == 1,
                  texture.storageMode == .private,
                  texture.usage.contains([
                      .shaderRead,
                      .shaderWrite,
                      .renderTarget,
                  ]),
                  let handle = texture.makeSharedTextureHandle(),
                  let imported = texture.device.makeSharedTexture(handle: handle),
                  imported.device === texture.device,
                  imported.pixelFormat == texture.pixelFormat,
                  imported.width == texture.width,
                  imported.height == texture.height,
                  imported.storageMode == .private,
                  imported.usage == texture.usage else {
                throw DoryRendererWorkerBackendActivationError.virgl2Context
            }
        } catch {
            throw DoryRendererWorkerBackendActivationError.virgl2Context
        }
        do {
            try session.createContext(
                id: preflightVenusContextID,
                capsetID: 4,
                name: "dory-preflight-venus"
            )
        } catch {
            throw DoryRendererWorkerBackendActivationError.venusContext
        }
        venusCreated = true
        let blob: DoryRendererBlobCreatePayload
        do {
            blob = try DoryRendererBlobCreatePayload(
                blobMemory: UInt32(DORY_VIRGL_RENDERER_BLOB_MEMORY_HOST3D),
                blobFlags: UInt32(DORY_VIRGL_RENDERER_BLOB_FLAG_MAPPABLE),
                // Venus reserves zero for a renderer-allocated, exportable SHM blob.
                blobID: 0,
                size: UInt64(getpagesize())
            )
            try session.createBlob(
                DoryRendererForeignBlobCreate(
                    resourceID: preflightResourceID,
                    contextID: preflightVenusContextID,
                    payload: blob
                ),
                iovecs: nil,
                iovecCount: 0
            )
        } catch {
            throw DoryRendererWorkerBackendActivationError.sharedMemoryExport
        }
        blobCreated = true
        let validated: ValidatedSHM
        do {
            let exported = try session.exportBlob(resourceID: preflightResourceID)
            validated = try validateExportedSHM(
                exported,
                minimumBytes: UInt64(getpagesize()),
                maximumBytes: UInt64(getpagesize()) * 16
            )
        } catch {
            throw DoryRendererWorkerBackendActivationError.sharedMemoryExport
        }
        close(validated.fileDescriptor)

        let globalFenceDescriptor: Int32
        do {
            // Prove the classic ctx0 callback path preserves a guest identity wider than VirGL's
            // 32-bit callback token before a production receipt can advertise acceleration.
            try session.createGlobalFence(fenceID: preflightGlobalFenceID)
            globalFenceDescriptor = try session.exportFence(fenceID: preflightGlobalFenceID)
            defer { close(globalFenceDescriptor) }
            try waitForFenceCompletion(
                descriptor: globalFenceDescriptor,
                session: session
            )
        } catch {
            throw DoryRendererWorkerBackendActivationError.fenceExport
        }

        let virgl2FenceDescriptor: Int32
        do {
            try session.createFence(
                contextID: preflightVirgl2ContextID,
                flags: 0,
                ringIndex: 0,
                fenceID: preflightVirgl2FenceID
            )
            virgl2FenceDescriptor = try session.exportFence(fenceID: preflightVirgl2FenceID)
            defer { close(virgl2FenceDescriptor) }
            try waitForFenceCompletion(
                descriptor: virgl2FenceDescriptor,
                session: session
            )
        } catch {
            throw DoryRendererWorkerBackendActivationError.fenceExport
        }

        let venusFenceDescriptor: Int32
        do {
            try session.createFence(
                contextID: preflightVenusContextID,
                flags: 0,
                ringIndex: 0,
                fenceID: preflightVenusFenceID
            )
            venusFenceDescriptor = try session.exportFence(fenceID: preflightVenusFenceID)
            defer { close(venusFenceDescriptor) }
            try waitForFenceCompletion(
                descriptor: venusFenceDescriptor,
                session: session
            )
        } catch {
            throw DoryRendererWorkerBackendActivationError.fenceExport
        }
        return PreflightResult(
            capsets: [virgl2, venus],
            pollDescriptor: pollDescriptor
        )
    }

    private static func submitVirgl2SurfaceLifecycle(
        session: any DoryRendererForeignSession
    ) throws {
        // Pinned virgl ABI: CREATE_OBJECT/SURFACE has five payload dwords. Destroying the object in
        // the same submit keeps activation cleanup complete even before the context is torn down.
        let dwords: [UInt32] = [
            (5 << 16) | (8 << 8) | 1,
            preflightVirgl2SurfaceObjectID,
            preflightVirgl2Resource2DID,
            UInt32(DORY_VIRGL_RENDERER_FORMAT_BGRA8_UNORM),
            0, // mip level
            0, // first layer 0, last layer 0
            (1 << 16) | (8 << 8) | 3,
            preflightVirgl2SurfaceObjectID,
        ]
        let byteCount = dwords.count * MemoryLayout<UInt32>.stride
        let alignedBytes = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { alignedBytes.deallocate() }
        dwords.withUnsafeBytes { source in
            alignedBytes.copyMemory(from: source.baseAddress!, byteCount: byteCount)
        }
        try session.submit(
            contextID: preflightVirgl2ContextID,
            bytes: UnsafeRawPointer(alignedBytes),
            dwordCount: UInt32(dwords.count)
        )
    }

    private static func waitForFenceCompletion(
        descriptor: Int32,
        session: any DoryRendererForeignSession
    ) throws {
        guard descriptor >= 0, fcntl(descriptor, F_GETFD) >= 0 else {
            throw DoryRendererWorkerBackendActivationError.fenceExport
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let timeoutNanoseconds = UInt64(preflightFenceTimeoutMilliseconds) * 1_000_000
        while true {
            session.poll()
            var event = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let status = Darwin.poll(&event, 1, 5)
            if status > 0 {
                guard event.revents & Int16(POLLNVAL | POLLERR) == 0,
                      event.revents & Int16(POLLIN | POLLHUP) != 0 else {
                    throw DoryRendererWorkerBackendActivationError.fenceExport
                }
                return
            }
            if status < 0, errno != EINTR {
                throw DoryRendererWorkerBackendActivationError.fenceExport
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= started, now - started < timeoutNanoseconds else {
                throw DoryRendererWorkerBackendActivationError.fenceExport
            }
        }
    }

    private struct ValidatedSHM {
        let fileDescriptor: Int32
        let fileSize: UInt64
    }

    private static func validateExportedSHM(
        _ exported: DoryRendererForeignExportedBlob,
        minimumBytes: UInt64,
        maximumBytes: UInt64
    ) throws -> ValidatedSHM {
        let descriptor = exported.ownedFileDescriptor
        guard exported.type == UInt32(DORY_VIRGL_RENDERER_BLOB_FD_TYPE_SHM),
              descriptor >= 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw DoryRendererForeignSessionError.invalidResult(operation: "non-shm-export")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            throw DoryRendererForeignSessionError.invalidResult(operation: "shm-export-stat")
        }
        // Darwin POSIX SHM descriptors report only their access mode (normally 0600), without
        // S_IFREG or another S_IF* type bit. An unlinked temporary filesystem file still reports
        // S_IFREG. Accept exactly those two shapes, then prove the descriptor has the private,
        // bounded, read/write-mappable semantics the zero-copy path requires.
        guard DoryRendererSharedMemoryDescriptorPolicy.accepts(mode: status.st_mode),
              status.st_nlink == 0,
              status.st_size > 0,
              UInt64(status.st_size) >= minimumBytes,
              UInt64(status.st_size) <= maximumBytes else {
            close(descriptor)
            throw DoryRendererForeignSessionError.invalidResult(operation: "shm-export-bounds")
        }
        let probeLength = Swift.min(Int(status.st_size), Int(getpagesize()))
        let probe = mmap(
            nil,
            probeLength,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            descriptor,
            0
        )
        guard probe != MAP_FAILED, let probe else {
            close(descriptor)
            throw DoryRendererForeignSessionError.invalidResult(operation: "shm-export-mapping")
        }
        guard munmap(probe, probeLength) == 0 else {
            close(descriptor)
            throw DoryRendererForeignSessionError.invalidResult(operation: "shm-export-unmapping")
        }
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            close(descriptor)
            throw DoryRendererForeignSessionError.invalidResult(operation: "shm-export-cloexec")
        }
        return ValidatedSHM(
            fileDescriptor: descriptor,
            fileSize: UInt64(status.st_size)
        )
    }

    private func logScanoutRejection(
        active: ActiveState,
        resourceID: UInt32,
        reason: String
    ) {
        guard active.loggedScanoutRejections.insert(resourceID).inserted else { return }
        Self.logger.error(
            "scanout-rejected resource=\(resourceID, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func matchingResource(
        _ command: DoryRendererWorkerCommand,
        active: ActiveState
    ) -> ResourceState? {
        guard let resource = active.resources[command.resourceID],
              resource.generation == command.resourceGeneration else { return nil }
        return resource
    }

    private func nextResourceGeneration(
        resourceID: UInt32,
        active: ActiveState
    ) throws -> UInt64 {
        let previous = active.lastResourceGenerations[resourceID] ?? 0
        let (next, overflow) = previous.addingReportingOverflow(1)
        guard !overflow, next != 0 else {
            throw DoryRendererForeignSessionError.invalidResult(operation: "resource-generation")
        }
        active.lastResourceGenerations[resourceID] = next
        return next
    }

    private func teardownLocked(_ active: ActiveState) {
        active.pollDriver?.cancel()
        active.pollDriver = nil
        active.leases.removeAll()
        active.resources.removeAll()
        active.contexts.removeAll()
        active.session.invalidate()
    }

    private func pollForeignEvents() {
        _ = try? executionLane.sync { [self] in
            lock.lock()
            defer { lock.unlock() }
            guard case .active(let active) = state else { return }
            active.session.poll()
        }
    }

    private static func encodeUInt64(_ value: UInt64) -> Data {
        Swift.withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func errorForProtocolViolation() -> Error {
        DoryRendererForeignSessionError.invalidResult(operation: "typed-operation-payload")
    }
}

private final class OwnedBacking {
    let iovecs: UnsafeMutablePointer<iovec>
    let count: UInt32
    private let mappings: [OwnedMapping]

    init(
        regions: [DoryRendererSharedRegionReference],
        descriptors: [FileHandle]
    ) throws {
        guard !regions.isEmpty,
              regions.count <= Int(UInt32.max),
              descriptors.count == (regions.map(\.descriptorIndex).max().map { Int($0) + 1 } ?? 0)
        else {
            throw DoryRendererWorkerContractError.invalidSharedRegionCount(
                limit: Int(UInt32.max),
                actual: regions.count
            )
        }
        var created = [OwnedMapping]()
        created.reserveCapacity(regions.count)
        for region in regions {
            let index = Int(region.descriptorIndex)
            guard descriptors.indices.contains(index) else {
                throw DoryRendererWorkerContractError.descriptorCountMismatch(
                    expected: index + 1,
                    actual: descriptors.count
                )
            }
            created.append(try OwnedMapping(
                region: region,
                source: descriptors[index].fileDescriptor
            ))
        }
        mappings = created
        count = UInt32(created.count)
        iovecs = .allocate(capacity: created.count)
        for (index, mapping) in created.enumerated() {
            iovecs.advanced(by: index).initialize(to: iovec(
                iov_base: mapping.regionBase,
                iov_len: mapping.regionLength
            ))
        }
    }

    deinit {
        iovecs.deinitialize(count: Int(count))
        iovecs.deallocate()
    }
}

private final class OwnedMapping {
    let mappingBase: UnsafeMutableRawPointer
    let mappingLength: Int
    let regionBase: UnsafeMutableRawPointer
    let regionLength: Int

    init(region: DoryRendererSharedRegionReference, source: Int32) throws {
        let descriptor = fcntl(source, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(descriptor) }
        let pageSize = UInt64(getpagesize())
        let mappingOffset = region.offset - region.offset % pageSize
        let delta = region.offset - mappingOffset
        let (byteCount, overflow) = delta.addingReportingOverflow(region.length)
        guard !overflow, byteCount <= UInt64(Int.max), mappingOffset <= UInt64(Int64.max),
              region.length <= UInt64(Int.max) else {
            throw DoryRendererWorkerContractError.invalidSharedRegionBounds
        }
        let protection = region.access == .readOnly ? PROT_READ : PROT_READ | PROT_WRITE
        let mapped = mmap(
            nil,
            Int(byteCount),
            protection,
            MAP_SHARED,
            descriptor,
            off_t(mappingOffset)
        )
        guard mapped != MAP_FAILED, let mapped else { throw POSIXError(.ENOMEM) }
        mappingBase = mapped
        mappingLength = Int(byteCount)
        regionBase = mapped.advanced(by: Int(delta))
        regionLength = Int(region.length)
    }

    deinit { munmap(mappingBase, mappingLength) }
}
