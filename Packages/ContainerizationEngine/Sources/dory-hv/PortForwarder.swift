import Foundation
import DoryHV
import DoryCore

/// Publishes container ports to the host through gvproxy. dockerd inside the guest binds published
/// ports (`docker run -p 8080:80`) to the guest's address; gvproxy's userspace network is not
/// directly routable from the host, so each published port must be exposed explicitly. This polls
/// the docker socket and keeps gvproxy's forwards in sync with the live set of published ports.
final class PortForwarder: MachinePortForwarding, @unchecked Sendable {
    private let engineSocket: String
    private let apiSocket: String
    private let guestIP: String
    /// Host address published ports bind to: 127.0.0.1 (default, localhost-only) or 0.0.0.0 when the
    /// user opts into LAN visibility.
    private let localHost: String
    private let sourcePreservingLANClient: (any SourcePreservingLANApplying)?
    private let sourcePreservingLANSessionID: String?
    private let sourcePreservingLANGVProxySocketPath: String?
    private let bridgeSubnetCIDR: String
    private let log: (String) -> Void
    private let publishedPortsProvider: (() -> Set<PublishedPortBinding>?)?
    private let registeredForwardsProvider: (() -> Set<PublishedPortForward>?)?
    private let exposeProvider: ((PublishedPortForward) -> Bool)?
    private let unexposeProvider: ((PublishedPortForward) -> Bool)?
    private let queue = DispatchQueue(label: "dev.dory.hv.port-forwarder")
    private let queueKey = DispatchSpecificKey<Void>()
    private let timer: any DispatchSourceTimer
    private let timerLock = NSLock()
    private var timerActivated = false
    private var timerCancelled = false
    private var exposed = Set<PublishedPortForward>()
    private var machineExposed = Set<PublishedPortForward>()
    private var lastForwardFailureLog: [PublishedPortForward: Date] = [:]
    private var lastLANFailureLog = Date.distantPast
    private var recoveringLANSession = false

    init(
        engineSocket: String,
        apiSocket: String,
        guestIP: String,
        localHost: String = "127.0.0.1",
        sourcePreservingLANClient: (any SourcePreservingLANApplying)? = nil,
        sourcePreservingLANSessionID: String? = nil,
        sourcePreservingLANGVProxySocketPath: String? = nil,
        bridgeSubnetCIDR: String = DoryIPv4BridgeNetwork.defaultCIDR,
        log: @escaping (String) -> Void,
        publishedPortsProvider: (() -> Set<PublishedPortBinding>?)? = nil,
        registeredForwardsProvider: (() -> Set<PublishedPortForward>?)? = nil,
        exposeProvider: ((PublishedPortForward) -> Bool)? = nil,
        unexposeProvider: ((PublishedPortForward) -> Bool)? = nil
    ) {
        self.engineSocket = engineSocket
        self.apiSocket = apiSocket
        self.guestIP = guestIP
        self.localHost = localHost
        self.sourcePreservingLANClient = sourcePreservingLANClient
        self.sourcePreservingLANSessionID = sourcePreservingLANSessionID
        self.sourcePreservingLANGVProxySocketPath = sourcePreservingLANGVProxySocketPath
        self.bridgeSubnetCIDR = bridgeSubnetCIDR
        self.log = log
        self.publishedPortsProvider = publishedPortsProvider
        self.registeredForwardsProvider = registeredForwardsProvider
        self.exposeProvider = exposeProvider
        self.unexposeProvider = unexposeProvider
        self.timer = DispatchSource.makeTimerSource(queue: queue)
        queue.setSpecific(key: queueKey, value: ())
        timer.schedule(deadline: .now() + 3, repeating: 2)
        timer.setEventHandler { [weak self] in self?.sync() }
    }

    func start() {
        timerLock.lock()
        defer { timerLock.unlock() }
        guard !timerActivated, !timerCancelled else { return }
        timerActivated = true
        timer.resume()
    }

    package func stop() {
        timerLock.lock()
        guard !timerCancelled else {
            timerLock.unlock()
            return
        }
        timer.setEventHandler {}
        if !timerActivated {
            timerActivated = true
            timer.resume()
        }
        timerCancelled = true
        timer.cancel()
        timerLock.unlock()
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
    }

    deinit {
        stop()
    }

    /// Runs manual repair on the normal reconciliation queue and returns after gvproxy operations
    /// finish, keeping the tracked forward set race-free and tests deterministic.
    func reconcileNow() {
        queue.sync { sync() }
    }

    private func sync() {
        guard let ports = publishedPorts() else { return }  // docker not ready or unreachable
        if let client = sourcePreservingLANClient, let sessionID = sourcePreservingLANSessionID {
            do {
                _ = try client.apply(SourcePreservingLANRequest(
                    operation: .refresh,
                    sessionID: sessionID,
                    bindings: ports,
                    bridgeSubnetCIDR: bridgeSubnetCIDR
                ))
                if recoveringLANSession {
                    recoveringLANSession = false
                    log("source-preserving LAN session recovered")
                }
            } catch {
                recoverLANSession(client: client, sessionID: sessionID, bindings: ports, refreshError: error)
            }
        }
        let loopbackPolicy = sourcePreservingLANClient == nil ? localHost : "127.0.0.1"
        let wanted = PublishedPortForwardPlan.forwards(
            for: ports,
            publishHost: loopbackPolicy,
            guestIP: guestIP
        )
        let reconciliation = GVProxyForwardReconciliation(
            wanted: wanted,
            actual: registeredPublishedForwards(),
            cached: exposed,
            protected: machineExposed
        )
        exposed = reconciliation.observed
        for forward in reconciliation.toExpose {
            if expose(forward) {
                exposed.insert(forward)
                lastForwardFailureLog.removeValue(forKey: forward)
                log("port forward: \(forward.localEndpoint)/\(forward.protocol.rawValue) -> container:\(forward.guestPort)/\(forward.protocol.rawValue)")
            } else {
                let now = Date()
                if now.timeIntervalSince(lastForwardFailureLog[forward] ?? .distantPast) >= 30 {
                    lastForwardFailureLog[forward] = now
                    log("port forward unavailable: \(forward.localEndpoint)/\(forward.protocol.rawValue); retaining bounded retry")
                }
            }
        }
        // Only forget the port once gvproxy confirms the forward is gone; a failed unexpose stays
        // tracked and is retried on the next tick, so a stale host forward can't leak.
        for forward in reconciliation.toUnexpose where unexpose(forward) {
            exposed.remove(forward)
            lastForwardFailureLog.removeValue(forKey: forward)
            log("port forward: released \(forward.localEndpoint)/\(forward.protocol.rawValue)")
        }
        lastForwardFailureLog = lastForwardFailureLog.filter { wanted.contains($0.key) }
    }

    private func recoverLANSession(
        client: any SourcePreservingLANApplying,
        sessionID: String,
        bindings: Set<PublishedPortBinding>,
        refreshError: Error
    ) {
        recoveringLANSession = true
        guard let socketPath = sourcePreservingLANGVProxySocketPath else {
            logLANFailure("source-preserving LAN refresh failed closed: \(refreshError)")
            return
        }
        do {
            let response = try client.apply(SourcePreservingLANRequest(
                operation: .activate,
                sessionID: sessionID,
                gvproxySocketPath: socketPath,
                bindings: bindings,
                bridgeSubnetCIDR: bridgeSubnetCIDR
            ))
            guard response.status == "active" else {
                logLANFailure("source-preserving LAN recovery failed closed: unexpected status \(response.status)")
                return
            }
            recoveringLANSession = false
            log("source-preserving LAN session recovered after helper restart")
        } catch {
            logLANFailure("source-preserving LAN recovery failed closed after refresh error \(refreshError): \(error)")
        }
    }

    private func logLANFailure(_ message: String) {
        let now = Date()
        guard now.timeIntervalSince(lastLANFailureLog) >= 30 else { return }
        lastLANFailureLog = now
        log(message)
    }

    /// The set of host ports currently published by any running container.
    private func publishedPorts() -> Set<PublishedPortBinding>? {
        if let publishedPortsProvider { return publishedPortsProvider() }
        guard let data = curlData(unixSocket: engineSocket, url: "http://d/v1.41/containers/json"),
              let containers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var ports = Set<PublishedPortBinding>()
        for container in containers {
            let labels = container["Labels"] as? [String: String]
            let loopbackIntents = PublishedPortForwardPlan.loopbackIntents(
                fromLabel: labels?[PublishedPortForwardPlan.loopbackPortIntentLabel]
            )
            guard let list = container["Ports"] as? [[String: Any]] else { continue }
            for entry in list {
                let proto = entry["Type"] as? String ?? "tcp"
                let requestedHost = PublishedPortForwardPlan.requestedHost(
                    dockerHost: entry["IP"] as? String,
                    containerPort: entry["PrivatePort"] as? Int,
                    publicPort: entry["PublicPort"] as? Int,
                    dockerType: proto,
                    loopbackIntents: loopbackIntents
                )
                guard let publicPort = entry["PublicPort"] as? Int,
                      let binding = PublishedPortBinding(
                        dockerType: proto,
                        publicPort: publicPort,
                        hostIP: requestedHost
                      ) else {
                    continue
                }
                ports.insert(binding)
            }
        }
        return ports
    }

    private func expose(_ forward: PublishedPortForward) -> Bool {
        if let exposeProvider { return exposeProvider(forward) }
        // gvproxy's TCP forward wants a bare host:port remote (no scheme), unlike the unix-socket
        // forward used for the docker socket.
        return curlPost(unixSocket: apiSocket, url: "http://gvproxy/services/forwarder/expose",
                        body: gvproxyBody(
                            local: forward.localEndpoint,
                            remote: forward.remoteEndpoint,
                            transportProtocol: forward.protocol.rawValue
                        ))
    }

    private func unexpose(_ forward: PublishedPortForward) -> Bool {
        if let unexposeProvider { return unexposeProvider(forward) }
        return curlPost(unixSocket: apiSocket, url: "http://gvproxy/services/forwarder/unexpose",
                        body: gvproxyBody(
                            local: forward.localEndpoint,
                            transportProtocol: forward.protocol.rawValue
                        ))
    }

    func exposeMachinePort(_ port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                let binding = PublishedPortBinding(protocol: .tcp, port: Int(port))
                let forward = PublishedPortForwardPlan.forward(
                    for: binding,
                    localHost: self.localHost,
                    guestIP: self.guestIP
                )
                let exposed = self.expose(forward)
                if exposed { self.machineExposed.insert(forward) }
                continuation.resume(returning: exposed)
            }
        }
    }

    func unexposeMachinePort(_ port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                let binding = PublishedPortBinding(protocol: .tcp, port: Int(port))
                let forward = PublishedPortForwardPlan.forward(
                    for: binding,
                    localHost: self.localHost,
                    guestIP: self.guestIP
                )
                let unexposed = self.unexpose(forward)
                if unexposed { self.machineExposed.remove(forward) }
                continuation.resume(returning: unexposed)
            }
        }
    }

    private func registeredPublishedForwards() -> Set<PublishedPortForward>? {
        if let registeredForwardsProvider { return registeredForwardsProvider() }
        guard let data = curlData(
            unixSocket: apiSocket,
            url: "http://gvproxy/services/forwarder/all"
        ) else {
            return nil
        }
        return GVProxyForwardRegistry.publishedForwards(from: data, guestIP: guestIP)
    }

    private func curlData(unixSocket: String, url: String) -> Data? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-s", "--max-time", "3", "--unix-socket", unixSocket, url]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return task.terminationStatus == 0 ? data : nil
    }

    private func gvproxyBody(local: String, remote: String? = nil, transportProtocol: String) -> String {
        var body: [String: String] = [
            "local": local,
            "protocol": transportProtocol,
        ]
        if let remote {
            body["remote"] = remote
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    @discardableResult
    private func curlPost(unixSocket: String, url: String, body: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-s", "-f", "--max-time", "3", "--unix-socket", unixSocket, "-X", "POST", "-d", body, url]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
