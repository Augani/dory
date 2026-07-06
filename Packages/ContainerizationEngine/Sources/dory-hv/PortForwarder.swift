import Foundation
import DoryHV

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
    private let log: (String) -> Void
    private let timer: any DispatchSourceTimer
    private var exposed = Set<Int>()

    init(engineSocket: String, apiSocket: String, guestIP: String, localHost: String = "127.0.0.1", log: @escaping (String) -> Void) {
        self.engineSocket = engineSocket
        self.apiSocket = apiSocket
        self.guestIP = guestIP
        self.localHost = localHost
        self.log = log
        self.timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 3, repeating: 2)
        timer.setEventHandler { [weak self] in self?.sync() }
    }

    func start() { timer.resume() }

    private func sync() {
        guard let wanted = publishedPorts() else { return }  // docker not ready or unreachable
        for port in wanted.subtracting(exposed) where expose(port) {
            exposed.insert(port)
            log("port forward: \(localHost):\(port) -> container")
        }
        // Only forget the port once gvproxy confirms the forward is gone; a failed unexpose stays
        // tracked and is retried on the next tick, so a stale host forward can't leak.
        for port in exposed.subtracting(wanted) where unexpose(port) {
            exposed.remove(port)
            log("port forward: released \(localHost):\(port)")
        }
    }

    /// The set of host ports currently published by any running container.
    private func publishedPorts() -> Set<Int>? {
        guard let data = curlData(unixSocket: engineSocket, url: "http://d/v1.41/containers/json"),
              let containers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var ports = Set<Int>()
        for container in containers {
            guard let list = container["Ports"] as? [[String: Any]] else { continue }
            for entry in list {
                if let publicPort = entry["PublicPort"] as? Int { ports.insert(publicPort) }
            }
        }
        return ports
    }

    private func expose(_ port: Int) -> Bool {
        // gvproxy's TCP forward wants a bare host:port remote (no scheme), unlike the unix-socket
        // forward used for the docker socket.
        curlPost(unixSocket: apiSocket, url: "http://gvproxy/services/forwarder/expose",
                 body: "{\"local\":\"\(localHost):\(port)\",\"remote\":\"\(guestIP):\(port)\",\"protocol\":\"tcp\"}")
    }

    private func unexpose(_ port: Int) -> Bool {
        curlPost(unixSocket: apiSocket, url: "http://gvproxy/services/forwarder/unexpose",
                 body: "{\"local\":\"\(localHost):\(port)\",\"protocol\":\"tcp\"}")
    }

    func exposeMachinePort(_ port: UInt16) async -> Bool {
        expose(Int(port))
    }

    func unexposeMachinePort(_ port: UInt16) async -> Bool {
        unexpose(Int(port))
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
