import Darwin
import DoryVirtio
import Foundation
import Testing
@testable import dory_hv

@Suite(.serialized) struct DoryPCGVProxyNetworkBackendTests {
    @Test func stopJoinsCapturedReceiveAndClosesExactDescriptorForEveryCaller() throws {
        let (backend, endpoint, peer) = try makeBackend()
        defer { close(peer); backend.stop() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let received = NetworkCallbackCounter()
        backend.connectReceiveSink { _ in
            received.increment()
            entered.signal()
            if received.value == 1 { #expect(release.wait(timeout: .now() + 2) == .success) }
        }
        defer { release.signal() }
        try sendFrame(to: peer, marker: 1)
        #expect(entered.wait(timeout: .now() + 1) == .success)
        let finished = DispatchSemaphore(value: 0)
        let stopResults = NetworkStopResults()
        for _ in 0..<2 {
            DispatchQueue.global().async {
                stopResults.append(backend.stop())
                finished.signal()
            }
        }
        let deadline = Date().addingTimeInterval(1)
        while !backend.isStopped, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        try #require(backend.isStopped)
        #expect(finished.wait(timeout: .now() + 0.02) == .timedOut)
        // A queued successor cannot pass the revoked admission after the captured callback exits.
        try sendFrame(to: peer, marker: 2)
        release.signal()
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(stopResults.values == [true, true])
        #expect(received.value == 1)
        #expect(fcntl(endpoint, F_GETFD) == -1)
        #expect(errno == EBADF)
        backend.connectReceiveSink { _ in received.increment() }
        #expect(throws: DoryPCGVProxyNetworkError.self) {
            try backend.transmit(frame: frame(marker: 3))
        }
        #expect(received.value == 1)
    }

    @Test func replacementSinkCannotReturnBeforeCapturedOldSinkFinishes() throws {
        let (backend, _, peer) = try makeBackend()
        defer { close(peer); backend.stop() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let oldCallbacks = NetworkCallbackCounter()
        backend.connectReceiveSink { _ in
            oldCallbacks.increment()
            entered.signal()
            #expect(release.wait(timeout: .now() + 2) == .success)
        }
        let oldGeneration = backend.receiveGeneration
        defer { release.signal() }
        try sendFrame(to: peer, marker: 1)
        #expect(entered.wait(timeout: .now() + 1) == .success)
        let replaced = DispatchSemaphore(value: 0)
        let successor = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            backend.connectReceiveSink { _ in successor.signal() }
            replaced.signal()
        }
        let deadline = Date().addingTimeInterval(1)
        while backend.receiveGeneration == oldGeneration, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        try #require(backend.receiveGeneration != oldGeneration)
        #expect(replaced.wait(timeout: .now() + 0.02) == .timedOut)
        try sendFrame(to: peer, marker: 2)
        release.signal()
        #expect(replaced.wait(timeout: .now() + 1) == .success)
        try sendFrame(to: peer, marker: 3)
        #expect(successor.wait(timeout: .now() + 1) == .success)
        #expect(backend.stop())
        #expect(oldCallbacks.value == 1)
    }

    @Test func receiveQueueStopRevokesImmediatelyButReportsUnjoinedUntilExternalJoin() throws {
        let (backend, endpoint, peer) = try makeBackend()
        defer { close(peer); backend.stop() }
        let callbackFinished = DispatchSemaphore(value: 0)
        let results = NetworkStopResults()
        backend.connectReceiveSink { [weak backend] _ in
            guard let backend else { return }
            results.append(backend.stop())
            callbackFinished.signal()
        }
        try sendFrame(to: peer, marker: 1)
        #expect(callbackFinished.wait(timeout: .now() + 1) == .success)
        #expect(results.values == [false])
        #expect(backend.stop())
        #expect(fcntl(endpoint, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    @Test func backendRetirementRevokesSemanticDeviceAndLateRegistration() throws {
        let (backend, _, peer) = try makeBackend()
        defer { close(peer); backend.stop() }
        let device = try DoryVirtioNetworkDevice(
            backend: backend, macAddress: [0x02, 1, 2, 3, 4, 5]
        )
        #expect(!device.isStopped)
        #expect(backend.stop())
        #expect(device.isStopped)
        #expect(!device.receive(frame: frame(marker: 1)))
        #expect(!device.setLinkUp(true))
        let lateDevice = try DoryVirtioNetworkDevice(
            backend: backend, macAddress: [0x02, 1, 2, 3, 4, 6]
        )
        #expect(lateDevice.isStopped)
    }

    @Test func reconnectPermanentlyRetiresPreviousSemanticDevice() throws {
        let (backend, _, peer) = try makeBackend()
        defer { close(peer); backend.stop() }
        let previous = try DoryVirtioNetworkDevice(
            backend: backend, macAddress: [0x02, 1, 2, 3, 4, 5]
        )
        let replacement = try DoryVirtioNetworkDevice(
            backend: backend, macAddress: [0x02, 1, 2, 3, 4, 6]
        )
        #expect(previous.isStopped)
        #expect(!replacement.isStopped)
        #expect(!previous.receive(frame: frame(marker: 1)))
        #expect(backend.stop())
        #expect(replacement.isStopped)
    }

    @Test func rejectsOversizedDatagramsWithoutDeliveringOrBlockingSuccessor() throws {
        let (backend, _, peer) = try makeBackend()
        defer { close(peer); backend.stop() }
        let delivered = DispatchSemaphore(value: 0)
        let received = NetworkCallbackCounter()
        backend.connectReceiveSink { _ in received.increment(); delivered.signal() }
        let oversized = [UInt8](repeating: 0, count: 1_519)
        let count = oversized.withUnsafeBytes {
            Darwin.send(peer, $0.baseAddress, $0.count, MSG_DONTWAIT)
        }
        #expect(count == oversized.count)
        try sendFrame(to: peer, marker: 2)
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        #expect(backend.stop())
        #expect(received.value == 1)
        #expect(DoryPCGVProxyNetworkBackend.maximumReceiveDatagramsPerTurn == 64)
    }

    private func makeBackend() throws -> (DoryPCGVProxyNetworkBackend, Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
            throw DoryPCGVProxyNetworkError.systemCall("test socketpair", errno)
        }
        do {
            let backend = try DoryPCGVProxyNetworkBackend(
                connectedDescriptor: descriptors[0], maximumFrameBytes: 1_518
            )
            return (backend, descriptors[0], descriptors[1])
        } catch {
            close(descriptors[0]); close(descriptors[1])
            throw error
        }
    }

    private func sendFrame(to descriptor: Int32, marker: UInt8) throws {
        let bytes = frame(marker: marker)
        let count = bytes.withUnsafeBytes {
            Darwin.send(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT)
        }
        guard count == bytes.count else {
            throw DoryPCGVProxyNetworkError.systemCall("test send", errno)
        }
    }

    private func frame(marker: UInt8) -> [UInt8] {
        [0x02, 0, 0, 0, 0, 1, 0x02, 0, 0, 0, 0, 2, 0x08, 0]
            + [UInt8](repeating: marker, count: 50)
    }
}

private final class NetworkCallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class NetworkStopResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool] = []
    var values: [Bool] { lock.withLock { results } }
    func append(_ result: Bool) { lock.withLock { results.append(result) } }
}
