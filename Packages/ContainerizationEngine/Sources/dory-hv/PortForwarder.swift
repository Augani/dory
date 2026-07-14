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
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "dev.dory.hv.port-forwarder")
    private let timer: any DispatchSourceTimer
    private var exposed = Set<PublishedPortForward>()
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
        log: @escaping (String) -> Void
    ) {
        self.engineSocket = engineSocket
        self.apiSocket = apiSocket
        self.guestIP = guestIP
        self.localHost = localHost
        self.sourcePreservingLANClient = sourcePreservingLANClient
        self.sourcePreservingLANSessionID = sourcePreservingLANSessionID
        self.sourcePreservingLANGVProxySocketPath = sourcePreservingLANGVProxySocketPath
        self.log = log
        self.timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 2)
        timer.setEventHandler { [weak self] in self?.sync() }
    }

    func start() { timer.resume() }

    /// Coalesces manual repair with the normal two-second reconciliation loop on the same serial
    /// queue, keeping the tracked forward set race-free.
    func reconcileNow() {
        queue.async { [weak self] in self?.sync() }
    }

    private func sync() {
        guard let ports = publishedPorts() else { return }  // docker not ready or unreachable
        if let client = sourcePreservingLANClient, let sessionID = sourcePreservingLANSessionID {
            do {
                _ = try client.apply(SourcePreservingLANRequest(
                    operation: .refresh,
                    sessionID: sessionID,
                    bindings: ports
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
        for forward in wanted.subtracting(exposed) {
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
        for forward in exposed.subtracting(wanted) where unexpose(forward) {
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
                bindings: bindings
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
        return curlPost(unixSocket: apiSocket, url: "http://gvproxy/services/forwarder/unexpose",
                        body: gvproxyBody(
                            local: forward.localEndpoint,
                            transportProtocol: forward.protocol.rawValue
                        ))
    }

    func exposeMachinePort(_ port: UInt16) async -> Bool {
        let binding = PublishedPortBinding(protocol: .tcp, port: Int(port))
        return expose(PublishedPortForwardPlan.forward(for: binding, localHost: localHost, guestIP: guestIP))
    }

    func unexposeMachinePort(_ port: UInt16) async -> Bool {
        let binding = PublishedPortBinding(protocol: .tcp, port: Int(port))
        return unexpose(PublishedPortForwardPlan.forward(for: binding, localHost: localHost, guestIP: guestIP))
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
