import Testing
import Foundation
@testable import Dory

struct HostBridgeForwardTests {
    @Test func forwardIsIdempotentPerMachinePort() {
        let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
        defer { fwd.stopAll() }
        let first = fwd.forwardLoopback(machine: "dev", port: 54010, ttl: 300)
        let second = fwd.forwardLoopback(machine: "dev", port: 54010, ttl: 300)
        #expect(first)
        #expect(second)
        #expect(fwd.activeLoopbackKeys() == ["dev:54010"])
    }

    @Test func teardownRemovesKey() {
        let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
        defer { fwd.stopAll() }
        _ = fwd.forwardLoopback(machine: "dev", port: 54011, ttl: 300)
        fwd.teardownLoopback(machine: "dev", port: 54011)
        #expect(fwd.activeLoopbackKeys().isEmpty)
    }

    @Test func distinctMachinesTracksSeparateKeys() {
        let fwd = HostPortForwarder(targetHost: "127.0.0.1", containerBinary: nil, engineName: "")
        defer { fwd.stopAll() }
        _ = fwd.forwardLoopback(machine: "a", port: 54012, ttl: 300)
        _ = fwd.forwardLoopback(machine: "b", port: 54013, ttl: 300)
        #expect(fwd.activeLoopbackKeys() == ["a:54012", "b:54013"])
    }
}
