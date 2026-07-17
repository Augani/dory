import Foundation

public final class NetworkRouteReconciler: @unchecked Sendable {
    public typealias ContainerProvider = @Sendable () -> DockerContainerList
    public typealias MachineProvider = @Sendable () -> [DoryMachineStatus]
    public typealias AdditionalRouteProvider = @Sendable (
        _ suffix: String,
        _ containers: DockerContainerList
    ) -> [DomainRoute]

    private let networkingController: NetworkingController
    private let suffix: String
    private let containerProvider: ContainerProvider
    private let machineProvider: MachineProvider
    private let additionalRouteProvider: AdditionalRouteProvider
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "dev.dory.doryd.network-routes")
    private var timer: DispatchSourceTimer?

    public init(
        networkingController: NetworkingController,
        suffix: String,
        containerProvider: @escaping ContainerProvider,
        machineProvider: @escaping MachineProvider,
        additionalRouteProvider: @escaping AdditionalRouteProvider = { _, _ in [] },
        interval: TimeInterval = 5
    ) {
        self.networkingController = networkingController
        self.suffix = suffix
        self.containerProvider = containerProvider
        self.machineProvider = machineProvider
        self.additionalRouteProvider = additionalRouteProvider
        self.interval = max(1, interval)
    }

    @discardableResult
    public func reconcileNow() -> [DomainRoute] {
        let containers = containerProvider()
        let routes = Self.routes(
            containers: containers,
            machines: machineProvider(),
            suffix: suffix,
            additionalRoutes: additionalRouteProvider(suffix, containers)
        )
        networkingController.replaceRoutes(routes)
        return routes
    }

    public func start() {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in
                _ = self?.reconcileNow()
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    public static func routes(
        containers containerList: DockerContainerList,
        machines: [DoryMachineStatus],
        suffix rawSuffix: String,
        additionalRoutes: [DomainRoute] = []
    ) -> [DomainRoute] {
        let suffix = DomainRouter.normalize(rawSuffix).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var routes: [String: DomainRoute] = [:]

        if case let .ok(containers) = containerList {
            for container in containers where container.isRunning {
                guard let publishedPort = preferredPublishedPort(container.ports),
                      let backendPort = UInt16(exactly: PrivilegedPortMapping.effectiveBackendPort(forPublishedPort: publishedPort)) else {
                    continue
                }
                for rawName in container.names {
                    let name = normalizedContainerName(rawName)
                    guard !name.isEmpty else { continue }
                    let hostname = DomainRouter.normalize("\(name).\(suffix)")
                    routes[hostname] = DomainRoute(hostname: hostname, address: "127.0.0.1", port: backendPort)
                }
                if publishedPort == 80 {
                    routes["localhost"] = DomainRoute(hostname: "localhost", address: "127.0.0.1", port: backendPort)
                    routes["127.0.0.1"] = DomainRoute(hostname: "127.0.0.1", address: "127.0.0.1", port: backendPort)
                }
            }
        }

        for machine in machines where machine.state == .running {
            guard let address = machine.address.map(DomainRouter.normalize),
                  IPv4Address(address) != nil else {
                continue
            }
            let hostname = DomainRouter.normalize("\(machine.id).\(suffix)")
            routes[hostname] = DomainRoute(hostname: hostname, address: address, port: 80)
        }

        for route in additionalRoutes {
            let hostname = DomainRouter.normalize(route.hostname)
            guard IPv4Address(route.address) != nil else { continue }
            routes[hostname] = DomainRoute(
                hostname: hostname,
                address: route.address,
                port: route.port,
                pathPrefix: route.pathPrefix
            )
        }

        return routes.values.sorted {
            if $0.hostname == $1.hostname {
                if $0.address == $1.address { return $0.port < $1.port }
                return $0.address < $1.address
            }
            return $0.hostname < $1.hostname
        }
    }

    private static func preferredPublishedPort(_ ports: [DockerContainerPort]) -> UInt16? {
        ports.compactMap { port -> UInt16? in
            let proto = (port.type ?? "tcp").lowercased()
            guard proto == "tcp" || proto == "tcp6",
                  let publicPort = port.publicPort,
                  publicPort > 0 else {
                return nil
            }
            return UInt16(exactly: publicPort)
        }.min()
    }

    private static func normalizedContainerName(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    deinit {
        stop()
    }
}
