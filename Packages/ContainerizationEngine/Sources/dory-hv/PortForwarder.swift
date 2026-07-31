import Foundation
import DoryHV
import DoryCore

package struct PortForwardReconcileResult: Sendable, Equatable {
    package var publishedPortCount: Int
    package var desired: Set<PublishedPortForward>
    package var observed: Set<PublishedPortForward>
    package var addedForwardCount: Int
    package var removedForwardCount: Int
    package var missing: Set<PublishedPortForward>
    package var unexpected: Set<PublishedPortForward>
    package var error: String?

    package var succeeded: Bool {
        error == nil && missing.isEmpty && unexpected.isEmpty
    }
}

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
    private let registeredForwardsProvider: (() -> GVProxyForwardRegistry?)?
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
        registeredForwardsProvider: (() -> GVProxyForwardRegistry?)? = nil,
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
        timer.setEventHandler { [weak self] in _ = self?.sync(validate: false) }
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

    /// Runs manual repair on the normal reconciliation queue and returns only after a second live
    /// registry read proves whether gvproxy converged.
    package func reconcileNow() -> PortForwardReconcileResult {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return sync(validate: true)
        }
        return queue.sync { sync(validate: true) }
    }

    private func sync(
        validate: Bool,
        attemptsRemaining: Int = 3,
        addedSoFar: Int = 0,
        removedSoFar: Int = 0
    ) -> PortForwardReconcileResult {
        guard let ports = publishedPorts() else {
            return failure("Docker published-port inventory is unavailable")
        }
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
        let registry = registeredPublishedForwards()
        if validate, registry == nil {
            return failure(
                "gvproxy forward registry is unavailable or malformed",
                publishedPortCount: ports.count,
                desired: wanted
            )
        }
        let reconciliation = GVProxyForwardReconciliation(
            wanted: wanted,
            actual: registry,
            cached: exposed,
            protected: machineExposed,
            guestIP: guestIP
        )
        let observedBefore = reconciliation.observed
        exposed = observedBefore

        // gvproxy keys forwards by (protocol, local). Release orphans and entries occupying a
        // wanted key before exposing, otherwise the replacement fails with address-in-use.
        for forward in reconciliation.toUnexpose where unexpose(forward) {
            exposed.remove(forward)
            lastForwardFailureLog.removeValue(forKey: forward)
            log("port forward: released \(forward.localEndpoint)/\(forward.protocol.rawValue)")
        }
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
        lastForwardFailureLog = lastForwardFailureLog.filter { wanted.contains($0.key) }

        guard validate else {
            return PortForwardReconcileResult(
                publishedPortCount: ports.count,
                desired: wanted,
                observed: exposed,
                addedForwardCount: wanted.intersection(exposed).subtracting(observedBefore).count,
                removedForwardCount: reconciliation.toUnexpose.subtracting(exposed).count,
                missing: wanted.subtracting(exposed),
                unexpected: exposed.subtracting(wanted),
                error: nil
            )
        }

        guard let verifiedRegistry = registeredPublishedForwards() else {
            return failure(
                "gvproxy forward registry could not be read after reconciliation",
                publishedPortCount: ports.count,
                desired: wanted
            )
        }
        let observedAfter = managedPublishedForwards(in: verifiedRegistry, wanted: wanted)
        let conflictsAfter = verifiedRegistry.conflictingWantedForwards(wanted)
        let missing = wanted.subtracting(observedAfter)
        let unexpected = observedAfter.subtracting(wanted).union(conflictsAfter)
        let added = wanted.intersection(observedAfter)
            .subtracting(wanted.intersection(observedBefore)).count
        let removed = reconciliation.toUnexpose.subtracting(unexpected).count
        exposed = observedAfter
        guard let verifiedPorts = publishedPorts() else {
            return failure(
                "Docker published-port inventory could not be re-read after reconciliation",
                publishedPortCount: ports.count,
                desired: wanted
            )
        }
        if verifiedPorts != ports {
            guard attemptsRemaining > 1 else {
                let newestWanted = PublishedPortForwardPlan.forwards(
                    for: verifiedPorts,
                    publishHost: loopbackPolicy,
                    guestIP: guestIP
                )
                return PortForwardReconcileResult(
                    publishedPortCount: verifiedPorts.count,
                    desired: newestWanted,
                    observed: observedAfter,
                    addedForwardCount: addedSoFar + added,
                    removedForwardCount: removedSoFar + removed,
                    missing: newestWanted.subtracting(observedAfter),
                    unexpected: observedAfter.subtracting(newestWanted),
                    error: "Docker published-port inventory did not stabilize during reconciliation"
                )
            }
            return sync(
                validate: true,
                attemptsRemaining: attemptsRemaining - 1,
                addedSoFar: addedSoFar + added,
                removedSoFar: removedSoFar + removed
            )
        }
        let validationError: String? = missing.isEmpty && unexpected.isEmpty
            ? nil
            : "gvproxy registry did not converge (missing \(missing.count), unexpected \(unexpected.count))"
        return PortForwardReconcileResult(
            publishedPortCount: ports.count,
            desired: wanted,
            observed: observedAfter,
            addedForwardCount: addedSoFar + added,
            removedForwardCount: removedSoFar + removed,
            missing: missing,
            unexpected: unexpected,
            error: validationError
        )
    }

    private func failure(
        _ message: String,
        publishedPortCount: Int = 0,
        desired: Set<PublishedPortForward> = []
    ) -> PortForwardReconcileResult {
        PortForwardReconcileResult(
            publishedPortCount: publishedPortCount,
            desired: desired,
            observed: [],
            addedForwardCount: 0,
            removedForwardCount: 0,
            missing: desired,
            unexpected: [],
            error: message
        )
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
                let didExpose = self.expose(forward)
                if didExpose { self.machineExposed.insert(forward) }
                continuation.resume(returning: didExpose)
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
                let didUnexpose = self.unexpose(forward)
                if didUnexpose { self.machineExposed.remove(forward) }
                continuation.resume(returning: didUnexpose)
            }
        }
    }

    private func registeredPublishedForwards() -> GVProxyForwardRegistry? {
        if let registeredForwardsProvider { return registeredForwardsProvider() }
        guard let data = curlData(
            unixSocket: apiSocket,
            url: "http://gvproxy/services/forwarder/all"
        ) else {
            return nil
        }
        return GVProxyForwardRegistry.decode(data)
    }

    private func managedPublishedForwards(
        in registry: GVProxyForwardRegistry,
        wanted: Set<PublishedPortForward>
    ) -> Set<PublishedPortForward> {
        registry.publishedForwards(guestIP: guestIP)
            .subtracting(machineExposed.subtracting(wanted))
    }

    private func curlData(unixSocket: String, url: String) -> Data? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-s", "-f", "--max-time", "3", "--unix-socket", unixSocket, url]
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
