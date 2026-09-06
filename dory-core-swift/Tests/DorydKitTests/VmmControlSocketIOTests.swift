import Darwin
import Foundation
import Testing
@testable import DorydKit

@Suite struct VmmControlSocketIOTests {
    @Test func eofDelimitedRequestAndResponseRoundTrip() throws {
        try withPair { server, client in
            let payload = try JSONEncoder().encode(VmmControlRequest(command: "deviceTelemetry"))
            try VmmControlSocketIO.writeResponseData(payload, to: client)
            #expect(shutdown(client, SHUT_WR) == 0)
            let received = try VmmControlSocketIO.readRequestData(from: server)
            #expect(try JSONDecoder().decode(VmmControlRequest.self, from: received).command == "deviceTelemetry")
            let reply = try JSONEncoder().encode(VmmControlResponse(ok: true))
            try VmmControlSocketIO.writeResponseData(reply, to: server)
            #expect(shutdown(server, SHUT_WR) == 0)
            #expect(try VmmControlSocketIO.readRequestData(from: client) == reply)
        }
    }

    @Test func trickleDoesNotExtendAbsoluteRequestDeadline() throws {
        try withPair { server, client in
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { finished.signal() }
                var byte: UInt8 = 1
                for _ in 0..<12 {
                    _ = send(client, &byte, 1, MSG_NOSIGNAL)
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            defer { _ = finished.wait(timeout: .now() + 2) }
            let start = DispatchTime.now().uptimeNanoseconds
            expectTimeout { _ = try VmmControlSocketIO.readRequestData(from: server, timeoutMilliseconds: 40) }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            #expect(elapsed >= 40_000_000)
            #expect(elapsed < 1_000_000_000)
        }
    }

    @Test func oversizedRequestIsRejected() throws {
        try withPair { server, client in
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { finished.signal() }
                let bytes = [UInt8](repeating: 1, count: VmmControlSocketIO.maximumMessageBytes + 1)
                bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let count = send(client, raw.baseAddress!.advanced(by: offset), raw.count - offset, MSG_NOSIGNAL)
                        if count <= 0 { break }
                        offset += count
                    }
                }
                _ = shutdown(client, SHUT_WR)
            }
            defer { _ = finished.wait(timeout: .now() + 2) }
            do {
                _ = try VmmControlSocketIO.readRequestData(from: server)
                Issue.record("oversized control frame was accepted")
            } catch VmmControlError.rejected(let reason) {
                #expect(reason.contains("exceeded"))
            }
        }
    }

    @Test func nonReadingClientCannotHoldResponseWriter() throws {
        try withPair { server, _ in
            var size: Int32 = 1024
            #expect(setsockopt(server, SOL_SOCKET, SO_SNDBUF, &size,
                socklen_t(MemoryLayout<Int32>.size)) == 0)
            expectTimeout {
                try VmmControlSocketIO.writeResponseData(
                    Data(repeating: 1, count: VmmControlSocketIO.maximumMessageBytes),
                    to: server, timeoutMilliseconds: 40)
            }
        }
    }

    @Test func clientFractionalDeadlineBoundsTrickledResponse() throws {
        let directory = "/tmp/dory-control-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let listener = try VmmControlSocketListener(path: directory + "/control.sock")
        defer { listener.stop() }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                while true {
                    switch try listener.acceptClient() {
                    case .retry: continue
                    case .stopped: return
                    case .client(let fd):
                        defer { close(fd) }
                        _ = try VmmControlSocketIO.readRequestData(from: fd)
                        var byte: UInt8 = 32
                        for _ in 0..<10 {
                            if send(fd, &byte, 1, MSG_NOSIGNAL) != 1 { break }
                            Thread.sleep(forTimeInterval: 0.03)
                        }
                        return
                    }
                }
            } catch { Issue.record("test peer failed: \(error)") }
        }
        defer { listener.stop(); _ = finished.wait(timeout: .now() + 2) }
        let start = DispatchTime.now().uptimeNanoseconds
        expectTimeout {
            _ = try VmmControlClient.send(socketPath: directory + "/control.sock",
                request: VmmControlRequest(command: "deviceTelemetry"), timeoutSeconds: 0.075)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        #expect(elapsed >= 75_000_000)
        #expect(elapsed < 1_000_000_000)
    }

    private func expectTimeout(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("control transfer did not time out")
        } catch VmmControlError.syscall(_, let code) {
            #expect(code == ETIMEDOUT)
        } catch {
            Issue.record("unexpected control transfer error: \(error)")
        }
    }

    private func withPair(_ body: (Int32, Int32) throws -> Void) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw VmmControlError.syscall("socketpair", errno)
        }
        defer { close(descriptors[0]); close(descriptors[1]) }
        try body(descriptors[0], descriptors[1])
    }
}
