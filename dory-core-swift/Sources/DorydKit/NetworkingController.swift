import Foundation

public struct PrivilegedTCPForward: Sendable, Equatable, Hashable, Codable {
    public var listenPort: UInt16
    public var targetPort: UInt16

    public init(listenPort: UInt16, targetPort: UInt16) {
        self.listenPort = listenPort
        self.targetPort = targetPort
    }
}

public struct NetworkingConfiguration: Sendable, Equatable {
    public var suffix: String
    public var dnsBindAddress: String
    public var dnsPort: UInt16
    public var httpProxyPort: UInt16
    public var httpsProxyPort: UInt16
    public var privilegedTCPForwards: [PrivilegedTCPForward]
    public var localCACertificatePath: String?

    public init(
        suffix: String = "dory.local",
        dnsBindAddress: String = "127.0.0.1",
        dnsPort: UInt16 = 1053,
        httpProxyPort: UInt16 = 8080,
        httpsProxyPort: UInt16 = 8443,
        privilegedTCPForwards: [PrivilegedTCPForward] = [],
        localCACertificatePath: String? = nil
    ) {
        self.suffix = suffix
        self.dnsBindAddress = dnsBindAddress
        self.dnsPort = dnsPort
        self.httpProxyPort = httpProxyPort
        self.httpsProxyPort = httpsProxyPort
        self.privilegedTCPForwards = privilegedTCPForwards
        self.localCACertificatePath = localCACertificatePath
    }
}

public struct NetworkingStatus: Sendable, Equatable {
    public var mode: String
    public var suffix: String
    public var dnsBindAddress: String
    public var dnsPort: UInt16
    public var dnsRunning: Bool
    public var httpProxyPort: UInt16
    public var httpProxyRunning: Bool
    public var httpsProxyPort: UInt16
    public var httpsProxyRunning: Bool
    public var routes: [DomainRoute]
    public var privilegedTCPForwards: [PrivilegedTCPForward]
    public var privilegedTCPForwardFailures: [UInt16: String]

    public init(
        mode: String,
        suffix: String,
        dnsBindAddress: String,
        dnsPort: UInt16,
        dnsRunning: Bool,
        httpProxyPort: UInt16,
        httpProxyRunning: Bool,
        httpsProxyPort: UInt16,
        httpsProxyRunning: Bool,
        routes: [DomainRoute],
        privilegedTCPForwards: [PrivilegedTCPForward] = [],
        privilegedTCPForwardFailures: [UInt16: String] = [:]
    ) {
        self.mode = mode
        self.suffix = suffix
        self.dnsBindAddress = dnsBindAddress
        self.dnsPort = dnsPort
        self.dnsRunning = dnsRunning
        self.httpProxyPort = httpProxyPort
        self.httpProxyRunning = httpProxyRunning
        self.httpsProxyPort = httpsProxyPort
        self.httpsProxyRunning = httpsProxyRunning
        self.routes = routes
        self.privilegedTCPForwards = privilegedTCPForwards
        self.privilegedTCPForwardFailures = privilegedTCPForwardFailures
    }
}

public enum NetworkingRepairTarget: String, Sendable {
    case dns
    case domains
    case routes
}

public final class NetworkingController: @unchecked Sendable {
    private let configuration: NetworkingConfiguration
    private let router: DomainRouter
    private let dnsServer: DoryDNSServer
    private let httpProxy: DoryHTTPProxyServer
    private let loopbackTCPForwarders: LoopbackTCPForwarderSet
    private let controlLock = NSLock()
    private var tlsProxy: DoryTLSProxyServer?
    private var additionalPrivilegedTCPForwards: [PrivilegedTCPForward] = []
    private var lastPrivilegedTCPForwardResult = LoopbackTCPForwardReconcileResult(active: [], failures: [:])
    var tlsRouteNames: Set<String> = []

    public init(
        configuration: NetworkingConfiguration = NetworkingConfiguration(),
        loopbackTCPForwarders: LoopbackTCPForwarderSet = LoopbackTCPForwarderSet()
    ) {
        self.configuration = configuration
        self.loopbackTCPForwarders = loopbackTCPForwarders
        let router = DomainRouter(suffix: configuration.suffix)
        self.router = router
        self.dnsServer = DoryDNSServer(
            bindAddress: configuration.dnsBindAddress,
            port: configuration.dnsPort,
            router: router
        )
        self.httpProxy = DoryHTTPProxyServer(
            bindAddress: "127.0.0.1",
            port: configuration.httpProxyPort,
            router: router
        )
    }

    public func start() throws {
        controlLock.lock()
        defer { controlLock.unlock() }
        try startLocked()
    }

    private func startLocked() throws {
        do {
            try dnsServer.start()
            try httpProxy.start()
            if configuration.localCACertificatePath != nil {
                let (proxy, routeNames) = try makeTLSProxy(routes: dnsServer.currentRoutes())
                try proxy.start()
                tlsProxy = proxy
                tlsRouteNames = routeNames
            }
            lastPrivilegedTCPForwardResult = reconcileLoopbackTCPForwardersLocked()
        } catch {
            dnsServer.stop()
            httpProxy.stop()
            tlsProxy?.stop()
            tlsProxy = nil
            loopbackTCPForwarders.stop()
            throw error
        }
    }

    public func stop() {
        controlLock.lock()
        defer { controlLock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        dnsServer.stop()
        httpProxy.stop()
        tlsProxy?.stop()
        tlsProxy = nil
        tlsRouteNames = []
        loopbackTCPForwarders.stop()
        lastPrivilegedTCPForwardResult = LoopbackTCPForwardReconcileResult(active: [], failures: [:])
    }

    public func replaceRoutes(_ routes: [DomainRoute]) {
        controlLock.lock()
        defer { controlLock.unlock() }
        replaceRoutesLocked(routes)
    }

    private func replaceRoutesLocked(_ routes: [DomainRoute]) {
        dnsServer.updateRoutes(routes)
        httpProxy.updateRoutes(routes)
        refreshTLSProxyLocked(routes: routes)
    }

    public func status() -> NetworkingStatus {
        controlLock.lock()
        defer { controlLock.unlock() }
        return statusLocked()
    }

    private func statusLocked() -> NetworkingStatus {
        NetworkingStatus(
            mode: tlsProxy?.isRunning == true ? "high-port-dns-http-https-proxy" : "high-port-dns-http-proxy",
            suffix: configuration.suffix,
            dnsBindAddress: configuration.dnsBindAddress,
            dnsPort: dnsServer.port == 0 ? configuration.dnsPort : dnsServer.port,
            dnsRunning: dnsServer.isRunning,
            httpProxyPort: httpProxy.port == 0 ? configuration.httpProxyPort : httpProxy.port,
            httpProxyRunning: httpProxy.isRunning,
            httpsProxyPort: (tlsProxy?.port ?? 0) == 0 ? configuration.httpsProxyPort : tlsProxy?.port ?? configuration.httpsProxyPort,
            httpsProxyRunning: tlsProxy?.isRunning == true,
            routes: dnsServer.currentRoutes(),
            privilegedTCPForwards: lastPrivilegedTCPForwardResult.active,
            privilegedTCPForwardFailures: lastPrivilegedTCPForwardResult.failures
        )
    }

    /// Restarts one host networking component without touching the VM or its workloads. Routes are
    /// retained by each listener, so a repair cannot briefly publish an empty routing table.
    @discardableResult
    public func repair(_ target: NetworkingRepairTarget) throws -> NetworkingStatus {
        controlLock.lock()
        defer { controlLock.unlock() }
        switch target {
        case .dns:
            dnsServer.stop()
            try dnsServer.start()
        case .domains:
            httpProxy.stop()
            tlsProxy?.stop()
            do {
                try httpProxy.start()
                try tlsProxy?.start()
                lastPrivilegedTCPForwardResult = reconcileLoopbackTCPForwardersLocked()
            } catch {
                httpProxy.stop()
                tlsProxy?.stop()
                loopbackTCPForwarders.stop()
                lastPrivilegedTCPForwardResult = LoopbackTCPForwardReconcileResult(active: [], failures: [:])
                throw error
            }
        case .routes:
            replaceRoutesLocked(dnsServer.currentRoutes())
        }
        return statusLocked()
    }

    private static func ephemeralPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<24)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    private func makeTLSProxy(routes: [DomainRoute]) throws -> (DoryTLSProxyServer, Set<String>) {
        guard let localCACertificatePath = configuration.localCACertificatePath else {
            throw NetworkingControllerError.tlsUnavailable
        }
        let routeNames = tlsNames(for: routes)
        let ca = DoryLocalCA(directory: URL(fileURLWithPath: localCACertificatePath).deletingLastPathComponent())
        let password = Self.ephemeralPassword()
        let p12 = try ca.issuePKCS12(
            domain: configuration.suffix,
            password: password,
            extraSANs: Array(routeNames).sorted()
        )
        return (try DoryTLSProxyServer(
            port: configuration.httpsProxyPort,
            p12Path: p12.path,
            password: password,
            router: router,
            routes: routes
        ), routeNames)
    }

    private func tlsNames(for routes: [DomainRoute]) -> Set<String> {
        var names: Set<String> = [
            "*.k8s.\(configuration.suffix)",
            "*.default.k8s.\(configuration.suffix)",
            "*.kube-system.k8s.\(configuration.suffix)",
        ]
        for route in routes {
            let hostname = DomainRouter.normalize(route.hostname)
            guard !router.owns(hostname),
                  !DoryHTTPProxyServer.isLoopbackHost(hostname),
                  DomainRouter.isValidHostnamePattern(hostname) else {
                continue
            }
            names.insert(hostname)
        }
        return names
    }

    private func refreshTLSProxyLocked(routes: [DomainRoute]) {
        guard configuration.localCACertificatePath != nil else { return }
        let desiredNames = tlsNames(for: routes)
        guard !desiredNames.isSubset(of: tlsRouteNames) else {
            tlsProxy?.updateRoutes(routes)
            return
        }
        do {
            let (candidate, routeNames) = try makeTLSProxy(routes: routes)
            let previous = tlsProxy
            previous?.stop()
            do {
                try candidate.start()
                tlsProxy = candidate
                tlsRouteNames = routeNames
            } catch {
                try? previous?.start()
                previous?.updateRoutes(routes)
                tlsProxy = previous
            }
        } catch {
            tlsProxy?.updateRoutes(routes)
        }
    }

    public func authorizationPlan(additionalPrivilegedTCPForwards: [PrivilegedTCPForward] = []) throws -> NetworkingAuthorizationPlan {
        controlLock.lock()
        defer { controlLock.unlock() }
        var live = configuration
        let activeDNSPort = dnsServer.port
        if activeDNSPort != 0 {
            live.dnsPort = activeDNSPort
        }
        let activeHTTPPort = httpProxy.port
        if activeHTTPPort != 0 {
            live.httpProxyPort = activeHTTPPort
        }
        if let tlsProxy, tlsProxy.port != 0 {
            live.httpsProxyPort = tlsProxy.port
        }
        if !additionalPrivilegedTCPForwards.isEmpty {
            live.privilegedTCPForwards += additionalPrivilegedTCPForwards
        }
        return try NetworkingAuthorizationPlan.make(configuration: live)
    }

    /// Keeps low TCP publications reachable without relying on PF translation. The listeners bind
    /// wildcard IPv4/IPv6 because macOS permits that for unprivileged low ports, then reject every
    /// non-loopback peer before opening a backend connection.
    @discardableResult
    public func reconcileLoopbackTCPForwarders(
        additionalPrivilegedTCPForwards: [PrivilegedTCPForward] = []
    ) -> LoopbackTCPForwardReconcileResult {
        controlLock.lock()
        defer { controlLock.unlock() }
        self.additionalPrivilegedTCPForwards = additionalPrivilegedTCPForwards
        let result = reconcileLoopbackTCPForwardersLocked()
        lastPrivilegedTCPForwardResult = result
        return result
    }

    private func reconcileLoopbackTCPForwardersLocked() -> LoopbackTCPForwardReconcileResult {
        guard httpProxy.isRunning else {
            return loopbackTCPForwarders.reconcile([])
        }
        var desired: [UInt16: UInt16] = [
            80: httpProxy.port == 0 ? configuration.httpProxyPort : httpProxy.port,
        ]
        if let tlsProxy, tlsProxy.isRunning {
            desired[443] = tlsProxy.port == 0 ? configuration.httpsProxyPort : tlsProxy.port
        }
        for forward in configuration.privilegedTCPForwards + additionalPrivilegedTCPForwards
            where !PrivilegedPortMapping.proxyReservedListenPorts.contains(forward.listenPort) {
            desired[forward.listenPort] = forward.targetPort
        }
        let forwards = desired.map {
            PrivilegedTCPForward(listenPort: $0.key, targetPort: $0.value)
        }
        return loopbackTCPForwarders.reconcile(forwards)
    }

    deinit {
        stop()
    }
}

private enum NetworkingControllerError: Error {
    case tlsUnavailable
}
