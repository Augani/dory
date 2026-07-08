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
        routes: [DomainRoute]
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
    }
}

public final class NetworkingController: @unchecked Sendable {
    private let configuration: NetworkingConfiguration
    private let router: DomainRouter
    private let dnsServer: DoryDNSServer
    private let httpProxy: DoryHTTPProxyServer
    private var tlsProxy: DoryTLSProxyServer?

    public init(configuration: NetworkingConfiguration = NetworkingConfiguration()) {
        self.configuration = configuration
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
        do {
            try dnsServer.start()
            try httpProxy.start()
            if let localCACertificatePath = configuration.localCACertificatePath {
                let ca = DoryLocalCA(directory: URL(fileURLWithPath: localCACertificatePath).deletingLastPathComponent())
                let p12 = try ca.issuePKCS12(
                    domain: configuration.suffix,
                    password: "dory",
                    extraSANs: [
                        "*.k8s.\(configuration.suffix)",
                        "*.default.k8s.\(configuration.suffix)",
                        "*.kube-system.k8s.\(configuration.suffix)",
                    ]
                )
                let proxy = try DoryTLSProxyServer(
                    port: configuration.httpsProxyPort,
                    p12Path: p12.path,
                    password: "dory",
                    router: router,
                    routes: dnsServer.currentRoutes()
                )
                try proxy.start()
                tlsProxy = proxy
            }
        } catch {
            dnsServer.stop()
            httpProxy.stop()
            tlsProxy?.stop()
            tlsProxy = nil
            throw error
        }
    }

    public func stop() {
        dnsServer.stop()
        httpProxy.stop()
        tlsProxy?.stop()
        tlsProxy = nil
    }

    public func replaceRoutes(_ routes: [DomainRoute]) {
        dnsServer.updateRoutes(routes)
        httpProxy.updateRoutes(routes)
        tlsProxy?.updateRoutes(routes)
    }

    public func status() -> NetworkingStatus {
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
            routes: dnsServer.currentRoutes()
        )
    }

    public func authorizationPlan() throws -> NetworkingAuthorizationPlan {
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
        return try NetworkingAuthorizationPlan.make(configuration: live)
    }

    deinit {
        stop()
    }
}
