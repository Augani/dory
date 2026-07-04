import CoreServices
import Foundation

public struct FSEventBatchParams: Codable, Sendable, Equatable {
    public var paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }
}

public struct FSEventBatchResult: Decodable, Sendable, Equatable {
    public var touched: Int
}

public struct HostFSEventShare: Sendable, Equatable {
    public var hostRoot: String
    public var guestRoot: String

    public init(hostRoot: String, guestRoot: String) {
        self.hostRoot = URL(fileURLWithPath: hostRoot).standardizedFileURL.path
        self.guestRoot = guestRoot
    }
}

public final class FSEventBatcher: @unchecked Sendable {
    private let shares: [HostFSEventShare]
    private let send: @Sendable ([String]) async -> Void
    private let lock = NSLock()
    private var pending = Set<String>()

    public init(shares: [HostFSEventShare], send: @escaping @Sendable ([String]) async -> Void) {
        self.shares = shares
        self.send = send
    }

    public func enqueue(hostPaths: [String]) {
        let guestPaths = hostPaths.compactMap(mapHostPathToGuest)
        guard !guestPaths.isEmpty else { return }
        lock.withLock {
            pending.formUnion(guestPaths)
        }
    }

    public func flushNow() async {
        let paths = lock.withLock { () -> [String] in
            let paths = pending.sorted()
            pending.removeAll()
            return paths
        }
        guard !paths.isEmpty else { return }
        await send(paths)
    }

    public var hasPending: Bool {
        lock.withLock { !pending.isEmpty }
    }

    public func mapHostPathToGuest(_ path: String) -> String? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        for share in shares {
            if normalized == share.hostRoot {
                return share.guestRoot
            }
            let prefix = share.hostRoot.hasSuffix("/") ? share.hostRoot : share.hostRoot + "/"
            guard normalized.hasPrefix(prefix) else { continue }
            let relative = String(normalized.dropFirst(prefix.count))
            guard !relative.isEmpty else { return share.guestRoot }
            return share.guestRoot + "/" + relative
        }
        return nil
    }
}

public final class HostFSEventRelay: @unchecked Sendable {
    public typealias SendBatch = @Sendable ([String]) async -> Void

    private let shares: [HostFSEventShare]
    private let batcher: FSEventBatcher
    private let debounceNanoseconds: UInt64
    private let queue = DispatchQueue(label: "dev.dory.hostfs.fsevents")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?
    private var flushScheduled = false

    public init(
        shares: [HostFSEventShare],
        debounceMilliseconds: UInt64 = 50,
        send: @escaping SendBatch
    ) {
        self.shares = shares
        self.batcher = FSEventBatcher(shares: shares, send: send)
        self.debounceNanoseconds = debounceMilliseconds * 1_000_000
    }

    deinit {
        stop()
    }

    public func start() {
        guard stream == nil, !shares.isEmpty else { return }
        let paths = shares.map(\.hostRoot) as CFArray
        let box = CallbackBox(relay: self)
        callbackBox = box
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let created = FSEventStreamCreate(
            nil,
            { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
                let pathsPointer = unsafeBitCast(eventPaths, to: NSArray.self)
                let paths = (0..<count).compactMap { pathsPointer.object(at: $0) as? String }
                box.relay?.record(hostPaths: paths)
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            callbackBox = nil
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackBox = nil
    }

    public func record(hostPaths: [String]) {
        batcher.enqueue(hostPaths: hostPaths)
        scheduleFlush()
    }

    private func scheduleFlush() {
        let shouldSchedule = lock.withLock { () -> Bool in
            guard !flushScheduled else { return false }
            flushScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            await self.batcher.flushNow()
            let shouldReschedule = self.lock.withLock { () -> Bool in
                self.flushScheduled = false
                return self.batcher.hasPending
            }
            if shouldReschedule {
                self.scheduleFlush()
            }
        }
    }
}

private final class CallbackBox {
    weak var relay: HostFSEventRelay?

    init(relay: HostFSEventRelay) {
        self.relay = relay
    }
}

public extension AgentChannel {
    func sendFSEventBatch(paths: [String]) async throws -> FSEventBatchResult {
        try await call("fsevents.batch", FSEventBatchParams(paths: paths))
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
