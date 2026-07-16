import DoryCore
import Foundation

/// Keeps Docker's published-port inventory synchronized with the gvproxy owned by the macOS 14
/// VZ fallback. This is the same fail-closed address policy used by dory-hv: localhost is the
/// default, explicit loopback requests are never widened, and LAN exposure requires an opt-in.
final class DoryVMMPortForwarder: @unchecked Sendable {
    private let dockerSocketPath: String
    private let gvproxyAPISocketPath: String
    private let publishHost: String
    private let sourcePreservingLANClient: (any SourcePreservingLANApplying)?
    private let sourcePreservingLANSessionID: String?
    private let sourcePreservingLANGVProxySocketPath: String?
    private let bridgeSubnetCIDR: String
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "dev.dory.dory-vmm.port-forwarder")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let timer: any DispatchSourceTimer
    private var exposed = Set<PublishedPortForward>()
    private let lock = NSLock()
    private var started = false
    private var lastLANFailureLog = Date.distantPast
    private var recoveringLANSession = false

    init(
        dockerSocketPath: String,
        gvproxyAPISocketPath: String,
        publishHost: String,
        sourcePreservingLANClient: (any SourcePreservingLANApplying)? = nil,
        sourcePreservingLANSessionID: String? = nil,
        sourcePreservingLANGVProxySocketPath: String? = nil,
        bridgeSubnetCIDR: String = DoryIPv4BridgeNetwork.defaultCIDR,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.dockerSocketPath = dockerSocketPath
        self.gvproxyAPISocketPath = gvproxyAPISocketPath
        self.publishHost = publishHost
        self.sourcePreservingLANClient = sourcePreservingLANClient
        self.sourcePreservingLANSessionID = sourcePreservingLANSessionID
        self.sourcePreservingLANGVProxySocketPath = sourcePreservingLANGVProxySocketPath
        self.bridgeSubnetCIDR = bridgeSubnetCIDR
        self.log = log
        queue.setSpecific(key: queueKey, value: 1)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.synchronize() }
    }

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        timer.resume()
    }

    func stop() {
        lock.lock()
        let wasStarted = started
        started = false
        lock.unlock()
        guard wasStarted else { return }
        timer.cancel()
        let removeForwards = { [self] in
            for forward in self.exposed where self.unexpose(forward) {
                self.exposed.remove(forward)
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            removeForwards()
        } else {
            queue.sync(execute: removeForwards)
        }
    }

    deinit {
        stop()
    }

    private func synchronize() {
        guard let ports = publishedPorts() else { return }
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
        let loopbackPolicy = sourcePreservingLANClient == nil ? publishHost : "127.0.0.1"
        let wanted = PublishedPortForwardPlan.forwards(
            for: ports,
            publishHost: loopbackPolicy,
            guestIP: "192.168.127.2"
        )
        for forward in wanted.subtracting(exposed) where expose(forward) {
            exposed.insert(forward)
        }
        for forward in exposed.subtracting(wanted) where unexpose(forward) {
            exposed.remove(forward)
        }
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

    private func publishedPorts() -> Set<PublishedPortBinding>? {
        guard let data = curlData(
            unixSocket: dockerSocketPath,
            url: "http://docker/v1.41/containers/json"
        ), let containers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var result = Set<PublishedPortBinding>()
        for container in containers {
            let labels = container["Labels"] as? [String: String]
            let intents = PublishedPortForwardPlan.loopbackIntents(
                fromLabel: labels?[PublishedPortForwardPlan.loopbackPortIntentLabel]
            )
            guard let ports = container["Ports"] as? [[String: Any]] else { continue }
            for port in ports {
                let dockerType = port["Type"] as? String ?? "tcp"
                let requestedHost = PublishedPortForwardPlan.requestedHost(
                    dockerHost: port["IP"] as? String,
                    containerPort: port["PrivatePort"] as? Int,
                    publicPort: port["PublicPort"] as? Int,
                    dockerType: dockerType,
                    loopbackIntents: intents
                )
                guard let publicPort = port["PublicPort"] as? Int,
                      let binding = PublishedPortBinding(
                        dockerType: dockerType,
                        publicPort: publicPort,
                        hostIP: requestedHost
                      ) else { continue }
                result.insert(binding)
            }
        }
        return result
    }

    private func expose(_ forward: PublishedPortForward) -> Bool {
        post(
            path: "/services/forwarder/expose",
            body: [
                "local": forward.localEndpoint,
                "remote": forward.remoteEndpoint,
                "protocol": forward.protocol.rawValue,
            ]
        )
    }

    private func unexpose(_ forward: PublishedPortForward) -> Bool {
        post(
            path: "/services/forwarder/unexpose",
            body: [
                "local": forward.localEndpoint,
                "protocol": forward.protocol.rawValue,
            ]
        )
    }

    private func curlData(unixSocket: String, url: String) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--fail", "--silent", "--max-time", "3",
            "--unix-socket", unixSocket,
            url,
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private func post(path: String, body: [String: String]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let bodyString = String(data: data, encoding: .utf8) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--fail", "--silent", "--max-time", "3",
            "--unix-socket", gvproxyAPISocketPath,
            "--request", "POST",
            "--data-binary", bodyString,
            "http://gvproxy\(path)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
