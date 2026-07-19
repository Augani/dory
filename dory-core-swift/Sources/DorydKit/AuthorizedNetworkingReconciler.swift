import DoryCore
import Foundation

public protocol AuthorizedNetworkingApplying: Sendable {
    /// Returns false when the user has not granted the initial system authorization.
    func reconcile(_ plan: NetworkingAuthorizationPlan) throws -> Bool
}

public final class AuthorizedNetworkingClient: AuthorizedNetworkingApplying, @unchecked Sendable {
    private let timeout: TimeInterval
    private let connectionFactory: @Sendable () -> NSXPCConnection

    public init(
        timeout: TimeInterval = 15,
        connectionFactory: (@Sendable () -> NSXPCConnection)? = nil
    ) {
        self.timeout = timeout
        self.connectionFactory = connectionFactory ?? {
            NSXPCConnection(
                machServiceName: DoryPrivilegedNetworkXPC.serviceName,
                options: .privileged
            )
        }
    }

    public func reconcile(_ plan: NetworkingAuthorizationPlan) throws -> Bool {
        let connection = connectionFactory()
        connection.remoteObjectInterface = NSXPCInterface(with: DoryPrivilegedNetworkControl.self)
        connection.setCodeSigningRequirement(DoryPrivilegedNetworkXPC.productionHelperRequirement)
        connection.resume()
        defer { connection.invalidate() }

        let completion = AuthorizedNetworkingReplyBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion.finish(reconciled: false, error: "\(error)")
        }) as? DoryPrivilegedNetworkControl else {
            throw SourcePreservingLANClientError.invalidResponse
        }
        proxy.reconcileAuthorizedNetworking(try JSONEncoder().encode(plan) as NSData) {
            reconciled, error in
            completion.finish(reconciled: reconciled, error: error as String?)
        }
        guard completion.wait(timeout: timeout) else {
            throw SourcePreservingLANClientError.timeout
        }
        if let error = completion.error {
            throw SourcePreservingLANClientError.remote(error)
        }
        return completion.reconciled
    }

    /// Removes the caller's exact root-owned authorization and any live source-preserving LAN
    /// session. The root service verifies the signing identity and effective UID.
    public func removeOwnedNetworking() throws -> Bool {
        try performRemoval { proxy, reply in
            proxy.removeOwnedNetworking(withReply: reply)
        }
    }

    /// Removes only the caller's persisted resolver, CA snapshot, and system PF authorization.
    /// Dory.app separately removes user trust after this succeeds. Source-preserving LAN remains
    /// available while Dory is installed.
    public func removeAuthorizedNetworking() throws -> Bool {
        try performRemoval { proxy, reply in
            proxy.removeAuthorizedNetworking(withReply: reply)
        }
    }

    private func performRemoval(
        _ invoke: (
            DoryPrivilegedNetworkControl,
            @escaping (Bool, NSString?) -> Void
        ) -> Void
    ) throws -> Bool {
        let connection = connectionFactory()
        connection.remoteObjectInterface = NSXPCInterface(with: DoryPrivilegedNetworkControl.self)
        connection.setCodeSigningRequirement(DoryPrivilegedNetworkXPC.productionHelperRequirement)
        connection.resume()
        defer { connection.invalidate() }

        let completion = AuthorizedNetworkingReplyBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion.finish(reconciled: false, error: "\(error)")
        }) as? DoryPrivilegedNetworkControl else {
            throw SourcePreservingLANClientError.invalidResponse
        }
        invoke(proxy) { removed, error in
            completion.finish(reconciled: removed, error: error as String?)
        }
        guard completion.wait(timeout: timeout) else {
            throw SourcePreservingLANClientError.timeout
        }
        if let error = completion.error {
            throw SourcePreservingLANClientError.remote(error)
        }
        return completion.reconciled
    }
}

/// Keeps low-port loopback listeners and the legacy root-owned PF anchor aligned with live Docker
/// publications. The user-space listeners do not require authorization; root reconciliation never
/// prompts and cannot create authorization, and remains temporarily for installed authorization
/// state created by earlier releases.
public final class AuthorizedNetworkingReconciler: @unchecked Sendable {
    public typealias PublishedPortsProvider = @Sendable () -> [DoryListenPort]
    public typealias FailureHandler = @Sendable (String) -> Void

    private let networkingController: NetworkingController
    private let publishedPorts: PublishedPortsProvider
    private let applier: any AuthorizedNetworkingApplying
    private let failureHandler: FailureHandler
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "dev.dory.doryd.authorized-networking")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastReconciledPlan: NetworkingAuthorizationPlan?
    private var lastLoopbackFailures: [UInt16: String] = [:]

    public init(
        networkingController: NetworkingController,
        interval: TimeInterval = 5,
        publishedPorts: @escaping PublishedPortsProvider,
        applier: any AuthorizedNetworkingApplying = AuthorizedNetworkingClient(),
        failureHandler: @escaping FailureHandler = { _ in }
    ) {
        self.networkingController = networkingController
        self.interval = max(1, interval)
        self.publishedPorts = publishedPorts
        self.applier = applier
        self.failureHandler = failureHandler
    }

    @discardableResult
    public func reconcileNow() throws -> Bool {
        let forwards = PrivilegedPortMapping.forwards(from: publishedPorts())
        let loopbackResult = networkingController.reconcileLoopbackTCPForwarders(
            additionalPrivilegedTCPForwards: forwards
        )
        lock.lock()
        let loopbackFailuresChanged = lastLoopbackFailures != loopbackResult.failures
        lastLoopbackFailures = loopbackResult.failures
        lock.unlock()
        if loopbackFailuresChanged, !loopbackResult.failures.isEmpty {
            let detail = loopbackResult.failures.keys.sorted().compactMap { port in
                loopbackResult.failures[port].map { "\(port): \($0)" }
            }.joined(separator: "; ")
            failureHandler("loopback low-port forwarding unavailable: \(detail)")
        }
        let plan = try networkingController.authorizationPlan(
            additionalPrivilegedTCPForwards: forwards
        )
        lock.lock()
        let unchanged = lastReconciledPlan == plan
        lock.unlock()
        if unchanged { return true }

        let reconciled = try applier.reconcile(plan)
        if reconciled {
            lock.lock()
            lastReconciledPlan = plan
            lock.unlock()
        }
        return reconciled
    }

    public func start() {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                _ = try self.reconcileNow()
            } catch {
                self.failureHandler("\(error)")
            }
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    public func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }

    deinit {
        stop()
    }
}

private final class AuthorizedNetworkingReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var finished = false
    private(set) var reconciled = false
    private(set) var error: String?

    func finish(reconciled: Bool, error: String?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        self.reconciled = reconciled
        self.error = error
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}
