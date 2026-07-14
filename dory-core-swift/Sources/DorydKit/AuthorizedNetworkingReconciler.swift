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
}

/// Keeps the root-owned PF anchor aligned with live Docker publications after the user grants the
/// initial authorization. It never prompts and cannot create authorization; the root helper binds
/// every update to the persisted owner UID and re-derives the submitted plan.
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
