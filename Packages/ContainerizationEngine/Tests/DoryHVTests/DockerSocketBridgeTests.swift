import Darwin
import Foundation
import Testing
@testable import DoryHV

@Suite struct DockerSocketBridgeTests {
    @Test func requiredDockerBridgePropagatesBindFailure() {
        let missingParent = "/tmp/missing-docker-parent-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let path = missingParent + "/engine.sock"
        try? FileManager.default.removeItem(atPath: missingParent)

        #expect(throws: UnixSocketListenerError.systemCall(
            operation: "bind",
            path: path,
            code: ENOENT
        )) {
            try DockerSocketBridge(socketPath: path).attach(to: VirtioVsock(guestCID: 3))
        }
    }
}
