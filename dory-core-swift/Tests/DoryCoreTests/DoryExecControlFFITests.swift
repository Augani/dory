import Darwin
import Foundation
import Testing
@testable import DoryCore

@Suite("Exec wait cancellation across Swift and Rust")
struct DoryExecControlFFITests {
    @Test("a silent connected peer cannot hold a cancelled Swift exec wait")
    func cancelsInFlightWait() throws {
        var descriptors: [Int32] = [-1, -1]
        let created = socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors)
        try #require(created == 0)
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        let configured = setsockopt(descriptors[1], SOL_SOCKET, SO_RCVTIMEO, &timeout,
                                    socklen_t(MemoryLayout<timeval>.size))
        #expect(configured == 0)
        // The real versioned handshake is four little-endian version bytes plus a build string.
        // Thereafter this peer consumes the exec frame but deliberately never replies.
        let hello = littleEndian(DoryCore.protocolVersion()) + Data("test".utf8)
        try peer.write(contentsOf: littleEndian(UInt32(hello.count)) + hello)
        let handle = try DoryCore.connectAgentControlOverFD(descriptors[0])
        defer { handle.close(); try? peer.close() }
        _ = try readFrame(peer)

        let token = DoryExecControl()
        let completion = ExecWaitCompletion()
        DispatchQueue.global().async {
            do {
                _ = try handle.exec(argv: ["/bin/true"], timeoutMs: 600_000, control: token)
                completion.finish(nil)
            } catch {
                completion.finish(error)
            }
        }
        let request = try readFrame(peer)
        #expect(request.count > 9)
        #expect(request[8] == 1) // mux request kind, not a synthesized response
        token.cancel()
        #expect(completion.done.wait(timeout: .now() + 1) == .success)
        #expect(completion.error as? DoryExecControlError == .cancelledGuestStateUnknown)
        #expect(throws: DoryExecControlError.alreadyUsed) {
            try handle.exec(argv: ["/bin/true"], control: token)
        }
        let beforeDispatch = DoryExecControl()
        beforeDispatch.cancel()
        #expect(throws: DoryExecControlError.cancelledGuestStateUnknown) {
            try handle.execWithInput(argv: ["/bin/cat"], stdin: Data([0, 255]), control: beforeDispatch)
        }
    }

    private func littleEndian(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private func readFrame(_ peer: FileHandle) throws -> Data {
        let prefix = try read(peer, count: 4)
        let count = prefix.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
        guard count <= 1024 * 1024 else { throw ExecWaitFixtureError.invalidFrame }
        return try read(peer, count: Int(count))
    }

    private func read(_ peer: FileHandle, count: Int) throws -> Data {
        var output = Data()
        while output.count < count {
            guard let chunk = try peer.read(upToCount: count - output.count), !chunk.isEmpty else {
                throw ExecWaitFixtureError.invalidFrame
            }
            output.append(chunk)
        }
        return output
    }
}

private enum ExecWaitFixtureError: Error { case invalidFrame }

private final class ExecWaitCompletion: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: (any Error)?
    var error: (any Error)? { lock.withLock { result } }
    func finish(_ error: (any Error)?) {
        lock.withLock { result = error }
        done.signal()
    }
}
