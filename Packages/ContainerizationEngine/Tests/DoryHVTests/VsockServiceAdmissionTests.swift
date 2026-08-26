import Foundation
import Testing
@testable import DoryHV

@Suite struct VsockServiceAdmissionTests {
    @Test func perServiceAndAggregateLimitsAreOneSharedBudget() throws {
        let limits = try VirtioVsockServiceAdmissionLimits(
            maximumSessionsTotal: 2,
            defaultMaximumSessionsPerService: 1
        )
        let device = VirtioVsock(guestCID: 3, serviceAdmissionLimits: limits)

        let docker = try device.connectForServiceIfCapacity(
            port: VsockPorts.docker,
            service: .docker
        )
        #expect(throws: VirtioVsockServiceAdmissionError.serviceCapacityReached(
            service: .docker,
            limit: 1
        )) {
            _ = try device.connectForServiceIfCapacity(
                port: VsockPorts.docker,
                service: .docker
            )
        }

        let ssh = try device.connectForServiceIfCapacity(
            port: VsockPorts.sshAgent,
            service: .sshAgent
        )
        #expect(throws: VirtioVsockServiceAdmissionError.aggregateCapacityReached(limit: 2)) {
            _ = try device.connectForServiceIfCapacity(
                port: VsockPorts.fsevents,
                service: .fileEvents
            )
        }

        let saturated = device.serviceAdmissionSnapshot
        #expect(saturated.activeSessionsTotal == 2)
        #expect(saturated.activeSessionsByService[.docker] == 1)
        #expect(saturated.activeSessionsByService[.sshAgent] == 1)
        #expect(saturated.serviceCapacityRejections[.docker] == 1)
        #expect(saturated.aggregateCapacityRejections == 1)

        docker.close()
        #expect(device.serviceAdmissionSnapshot.activeSessionsTotal == 1)
        let replacement = try device.connectForServiceIfCapacity(
            port: VsockPorts.docker,
            service: .docker
        )
        #expect(device.serviceAdmissionSnapshot.activeSessionsTotal == 2)
        replacement.close()
        ssh.close()
        #expect(device.serviceAdmissionSnapshot.activeSessionsTotal == 0)
        #expect(device.serviceAdmissionSnapshot.completedSessions == 3)
    }

    @Test func resetRevokesSessionsPreservesListenerAndAllowsNewGeneration() throws {
        let limits = try VirtioVsockServiceAdmissionLimits(
            maximumSessionsTotal: 2,
            defaultMaximumSessionsPerService: 1
        )
        let device = VirtioVsock(guestCID: 3, serviceAdmissionLimits: limits)
        let accepted = ServiceAdmissionLockedConnections()
        let registration = try device.registerServiceListener(
            port: 11_434,
            service: .hostAI
        ) { connection in
            accepted.append(connection)
        }
        defer { registration.close() }

        #expect(try request(device, guestPort: 40_000, servicePort: 11_434) == .response)
        let original = try #require(accepted.connection(at: 0))
        #expect(device.serviceAdmissionSnapshot.activeSessionsByService[.hostAI] == 1)

        let transport = try makeTransport(device: device)
        device.deviceReset(transport: transport)

        #expect(original.isPeerClosed)
        let reset = device.serviceAdmissionSnapshot
        #expect(reset.activeSessionsTotal == 0)
        #expect(reset.resetRevocations == 1)
        #expect(!reset.isResetting)
        #expect(!reset.isQuiesced)
        #expect(device.resourceSnapshot.listeners == 1)

        #expect(try request(device, guestPort: 40_001, servicePort: 11_434) == .response)
        let replacement = try #require(accepted.connection(at: 1))
        #expect(device.serviceAdmissionSnapshot.activeSessionsByService[.hostAI] == 1)
        replacement.close()
        #expect(device.serviceAdmissionSnapshot.activeSessionsTotal == 0)
    }

    @Test func resetRejectsLateReservationPublicationWithoutRunningWork() throws {
        let device = VirtioVsock(guestCID: 3)
        let reservation = try device.reserveServiceSession(.docker)
        let transport = try makeTransport(device: device)
        device.deviceReset(transport: transport)

        let stopFlag = ServiceAdmissionLockedFlag()
        let lease = device.publishServiceSession(
            reservation,
            requestStop: { stopFlag.set() }
        )
        #expect(lease == nil)
        #expect(!stopFlag.value)
        let snapshot = device.serviceAdmissionSnapshot
        #expect(snapshot.activeSessionsTotal == 0)
        #expect(snapshot.resetRevocations == 1)
        #expect(snapshot.latePublicationRejections == 1)
    }

    @Test func terminalQuiesceStopsOwnedSessionAndRejectsReconnect() throws {
        let limits = try VirtioVsockServiceAdmissionLimits(
            maximumSessionsTotal: 1,
            defaultMaximumSessionsPerService: 1
        )
        let device = VirtioVsock(guestCID: 3, serviceAdmissionLimits: limits)
        let connection = try device.connectForServiceIfCapacity(
            port: VsockPorts.agent,
            service: .agentRPC
        )
        #expect(device.serviceAdmissionSnapshot.activeSessionsTotal == 1)

        _ = device.quiesce()
        #expect(connection.isPeerClosed)
        let terminal = device.serviceAdmissionSnapshot
        #expect(terminal.activeSessionsTotal == 0)
        #expect(terminal.terminalRevocations == 1)
        #expect(terminal.isQuiesced)
        #expect(throws: VirtioVsockServiceAdmissionError.deviceQuiesced) {
            _ = try device.connectForServiceIfCapacity(
                port: VsockPorts.agent,
                service: .agentRPC
            )
        }
        #expect(device.serviceAdmissionSnapshot.quiescedRejections == 1)
    }

    private func request(
        _ device: VirtioVsock,
        guestPort: UInt32,
        servicePort: UInt32
    ) throws -> VirtioVsockHeader.Operation {
        let packet = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: guestPort,
            destinationPort: servicePort,
            length: 0,
            operation: .request
        )
        let response = try #require(device.receive(packet: packet.encoded()).first)
        return try VirtioVsockHeader(decoding: response).operation
    }

    private func makeTransport(device: VirtioVsock) throws -> VirtioMMIOTransport {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 0x20_000)
        return VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
    }
}

private final class ServiceAdmissionLockedConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections = [VsockConnection]()

    func append(_ connection: VsockConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
    }

    func connection(at index: Int) -> VsockConnection? {
        lock.lock()
        defer { lock.unlock() }
        guard connections.indices.contains(index) else { return nil }
        return connections[index]
    }
}

private final class ServiceAdmissionLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}
