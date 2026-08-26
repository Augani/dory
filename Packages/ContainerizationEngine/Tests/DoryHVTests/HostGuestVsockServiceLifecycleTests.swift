import Darwin
@testable import DoryHV
import Foundation
import Testing

@Suite struct HostGuestVsockServiceLifecycleTests {
    @Test func emptyAIPortSetStillHasOneShotAttachmentLifecycle() throws {
        let device = VirtioVsock(guestCID: 3)
        let bridge = HostAIBridge(
            ports: [],
            host: "127.0.0.1"
        )
        try bridge.attach(to: device)
        #expect(throws: (any Error).self) {
            try bridge.attach(to: device)
        }
        bridge.stop(timeout: 2)
        #expect(throws: (any Error).self) {
            try bridge.attach(to: device)
        }
    }

    @Test func bridgeDeinitBreaksRegistrationLifetimeAndUnregisters() throws {
        let device = VirtioVsock(guestCID: 3)
        let port: UInt16 = 54_321
        weak var releasedBridge: HostAIBridge?
        do {
            let bridge = HostAIBridge(
                ports: [port],
                host: "127.0.0.1"
            )
            releasedBridge = bridge
            try bridge.attach(to: device)
        }
        #expect(waitUntil { releasedBridge == nil })
        #expect(try request(
            device,
            guestPort: 39_999,
            servicePort: UInt32(port)
        ) == .reset)
    }

    @Test func aiMultiportAttachRollsBackEarlierRegistrationOnConflict() throws {
        let device = VirtioVsock(guestCID: 3)
        let occupiedPort: UInt16 = 20_001
        let existing = try device.registerListener(port: UInt32(occupiedPort)) {
            $0.close()
        }
        defer { existing.close() }
        let bridge = HostAIBridge(
            ports: [20_000, occupiedPort],
            host: "127.0.0.1"
        )
        #expect(throws: VirtioVsockListenerRegistrationError.duplicatePort(
            UInt32(occupiedPort)
        )) {
            try bridge.attach(to: device)
        }
        #expect(try request(
            device,
            guestPort: 39_997,
            servicePort: 20_000
        ) == .reset)
        #expect(try request(
            device,
            guestPort: 39_998,
            servicePort: UInt32(occupiedPort)
        ) == .response)
    }

    @Test func sshBridgeRejectsDuplicateAndExcessSessionsThenUnregisters() throws {
        let directory = "/tmp/dory-host-ssh-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let socketPath = directory + "/agent.sock"
        let hostListener = try VsockUnixRelay.makeOwnedListener(
            socketPath: socketPath,
            mode: 0o600
        )
        defer {
            VsockUnixRelay.retireOwnedListener(hostListener, socketPath: socketPath)
        }

        let device = try serviceLimitedDevice(service: .sshAgent, limit: 1)
        let bridge = try HostSSHAgentBridge(
            socketPath: socketPath,
            expectedUID: geteuid()
        )
        try bridge.attach(to: device)
        #expect(throws: (any Error).self) {
            try bridge.attach(to: device)
        }

        #expect(try request(
            device,
            guestPort: 40_000,
            servicePort: VsockPorts.sshAgent
        ) == .response)
        #expect(waitUntil { bridge.activeSessionCount == 1 })

        #expect(try request(
            device,
            guestPort: 40_001,
            servicePort: VsockPorts.sshAgent
        ) == .response)
        #expect(waitUntil {
            bridge.serviceAdmissionSnapshot?.serviceCapacityRejections[.sshAgent] == 1
        })
        #expect(bridge.activeSessionCount == 1)

        let started = ProcessInfo.processInfo.systemUptime
        bridge.stop(timeout: 2)
        #expect(ProcessInfo.processInfo.systemUptime - started < 1.5)
        #expect(bridge.activeSessionCount == 0)
        bridge.stop(timeout: 2)
        #expect(try request(
            device,
            guestPort: 40_002,
            servicePort: VsockPorts.sshAgent
        ) == .reset)
        #expect(throws: (any Error).self) {
            try bridge.attach(to: device)
        }

        // Unregistration releases the port for an independently owned successor service.
        let successor = try HostSSHAgentBridge(
            socketPath: socketPath,
            expectedUID: geteuid()
        )
        try successor.attach(to: device)
        successor.stop(timeout: 2)
    }

    @Test func aiBridgeCapsSessionsAndStopDrainsStalledUpstream() throws {
        let hostListener = try makeTCPLoopbackListener()
        defer { close(hostListener.descriptor) }
        let device = try serviceLimitedDevice(service: .hostAI, limit: 1)
        let bridge = HostAIBridge(
            ports: [hostListener.port],
            host: "127.0.0.1"
        )
        try bridge.attach(to: device)

        #expect(try request(
            device,
            guestPort: 41_000,
            servicePort: UInt32(hostListener.port)
        ) == .response)
        #expect(waitUntil { bridge.activeSessionCount == 1 })
        #expect(try request(
            device,
            guestPort: 41_001,
            servicePort: UInt32(hostListener.port)
        ) == .response)
        #expect(waitUntil {
            bridge.serviceAdmissionSnapshot?.serviceCapacityRejections[.hostAI] == 1
        })

        let started = ProcessInfo.processInfo.systemUptime
        bridge.stop(timeout: 2)
        #expect(ProcessInfo.processInfo.systemUptime - started < 1.5)
        #expect(bridge.activeSessionCount == 0)
        #expect(try request(
            device,
            guestPort: 41_002,
            servicePort: UInt32(hostListener.port)
        ) == .reset)
    }

    @Test func aiBridgeGuestResetRetiresEstablishedSession() throws {
        let hostListener = try makeTCPLoopbackListener()
        defer { close(hostListener.descriptor) }
        let device = VirtioVsock(guestCID: 3)
        let bridge = HostAIBridge(
            ports: [hostListener.port],
            host: "127.0.0.1"
        )
        defer { bridge.stop(timeout: 2) }
        try bridge.attach(to: device)
        let guestPort: UInt32 = 42_000
        #expect(try request(
            device,
            guestPort: guestPort,
            servicePort: UInt32(hostListener.port)
        ) == .response)
        #expect(waitUntil { bridge.activeSessionCount == 1 })

        let accepted = accept(hostListener.descriptor, nil, nil)
        #expect(accepted >= 0)
        let serverFinished = DispatchGroup()
        serverFinished.enter()
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 256)
            while buffer.withUnsafeMutableBytes({ read(accepted, $0.baseAddress, $0.count) }) > 0 {}
            close(accepted)
            serverFinished.leave()
        }

        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: guestPort,
            destinationPort: UInt32(hostListener.port),
            length: 0,
            operation: .reset
        ).encoded())
        #expect(waitUntil { bridge.activeSessionCount == 0 })
        #expect(serverFinished.wait(timeout: .now() + 2) == .success)
    }

    @Test func aiBridgePreservesGuestRequestHalfCloseWhileStreamingReply() throws {
        let hostListener = try makeTCPLoopbackListener()
        defer { close(hostListener.descriptor) }
        let device = VirtioVsock(guestCID: 3)
        let bridge = HostAIBridge(
            ports: [hostListener.port],
            host: "127.0.0.1"
        )
        defer { bridge.stop(timeout: 2) }
        try bridge.attach(to: device)
        let guestPort: UInt32 = 43_000
        #expect(try request(
            device,
            guestPort: guestPort,
            servicePort: UInt32(hostListener.port)
        ) == .response)
        #expect(waitUntil { bridge.activeSessionCount == 1 })

        let accepted = accept(hostListener.descriptor, nil, nil)
        #expect(accepted >= 0)
        var noSigpipe: Int32 = 1
        _ = setsockopt(
            accepted,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        let serverFinished = DispatchGroup()
        serverFinished.enter()
        Thread.detachNewThread {
            var requestBytes = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 256)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    read(accepted, $0.baseAddress, $0.count)
                }
                if count <= 0 { break }
                requestBytes.append(contentsOf: buffer.prefix(count))
            }
            if requestBytes == Array("ping".utf8) {
                let response = Array("pong".utf8)
                _ = response.withUnsafeBytes {
                    write(accepted, $0.baseAddress, $0.count)
                }
            }
            shutdown(accepted, SHUT_WR)
            close(accepted)
            serverFinished.leave()
        }

        let payload = Array("ping".utf8)
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: guestPort,
            destinationPort: UInt32(hostListener.port),
            length: UInt32(payload.count),
            operation: .readWrite
        ).encoded() + payload)
        _ = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: guestPort,
            destinationPort: UInt32(hostListener.port),
            length: 0,
            operation: .shutdown,
            flags: 2
        ).encoded())

        var reply = [UInt8]()
        #expect(waitUntil {
            for packet in device.drainPendingGuestPackets() {
                guard let header = try? VirtioVsockHeader(decoding: packet),
                      header.operation == .readWrite else { continue }
                reply.append(contentsOf: packet.dropFirst(VirtioVsockHeader.byteCount))
            }
            return reply == Array("pong".utf8)
        })
        #expect(serverFinished.wait(timeout: .now() + 2) == .success)
        #expect(waitUntil { bridge.activeSessionCount == 0 })
    }

    @Test func aiConnectorHasBoundedFailureAndSafeDescriptorFlags() throws {
        let live = try makeTCPLoopbackListener()
        defer { close(live.descriptor) }
        let client = try #require(HostAIBridge.connectTCP(
            host: "127.0.0.1",
            port: live.port,
            timeoutMilliseconds: 500
        ))
        defer { close(client) }
        let accepted = accept(live.descriptor, nil, nil)
        #expect(accepted >= 0)
        defer { if accepted >= 0 { close(accepted) } }
        #expect(fcntl(client, F_GETFD, 0) & FD_CLOEXEC != 0)
        #expect(fcntl(client, F_GETFL, 0) & O_NONBLOCK == 0)
        var noSigpipe: Int32 = 0
        var noSigpipeLength = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            &noSigpipeLength
        ) == 0)
        #expect(noSigpipe == 1)

        #expect(HostAIBridge.connectTCP(
            host: "not-an-ip-address",
            port: live.port,
            timeoutMilliseconds: 20
        ) == nil)
        let unused = try makeTCPLoopbackListener()
        let unusedPort = unused.port
        close(unused.descriptor)
        let refusalStart = ProcessInfo.processInfo.systemUptime
        #expect(HostAIBridge.connectTCP(
            host: "127.0.0.1",
            port: unusedPort,
            timeoutMilliseconds: 100
        ) == nil)
        #expect(ProcessInfo.processInfo.systemUptime - refusalStart < 1)

        let timeoutStart = ProcessInfo.processInfo.systemUptime
        #expect(HostAIBridge.connectTCP(
            host: "192.0.2.1",
            port: 9,
            timeoutMilliseconds: 25
        ) == nil)
        #expect(ProcessInfo.processInfo.systemUptime - timeoutStart < 1)
    }

    private func request(
        _ device: VirtioVsock,
        guestPort: UInt32,
        servicePort: UInt32
    ) throws -> VirtioVsockHeader.Operation {
        let responses = try device.receive(packet: VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: guestPort,
            destinationPort: servicePort,
            length: 0,
            operation: .request
        ).encoded())
        return try VirtioVsockHeader(decoding: responses[0]).operation
    }

    private func serviceLimitedDevice(
        service: VirtioVsockService,
        limit: Int
    ) throws -> VirtioVsock {
        let limits = try VirtioVsockServiceAdmissionLimits(
            maximumSessionsTotal: 8,
            defaultMaximumSessionsPerService: 8,
            serviceOverrides: [service: limit]
        )
        return VirtioVsock(guestCID: 3, serviceAdmissionLimits: limits)
    }

    private func makeTCPLoopbackListener() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw POSIXError(.EINVAL)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 8) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var published = sockaddr_in()
        var publishedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &published) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &publishedLength)
            }
        }
        guard inspected == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        transferred = true
        return (descriptor, UInt16(bigEndian: published.sin_port))
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return true }
            usleep(1_000)
        }
        return predicate()
    }
}
