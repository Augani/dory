@testable import DorydKit
import XCTest

final class DoryVMMShimTests: XCTestCase {
    func testDoryVMMExecutableSendsReadyHandoffAndExits() throws {
        let helper = FileManager.default.currentDirectoryPath + "/.build/debug/dory-vmm"
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw XCTSkip("dory-vmm helper not built at \(helper)")
        }

        let base = "/tmp/dory-vmm-shim-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let got = DispatchSemaphore(value: 0)
        let resultBox = LockedShimHandoffResult()
        let server = VmmHandoffServer(path: base + "/handoff.sock") { result in
            resultBox.result = result
            got.signal()
        }
        try server.start()
        defer { server.stop() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [
            "--machine-id", "dev",
            "--handoff-sock", server.path,
            "--agent-build", "dory-vmm/test",
            "--agent-sock", "/run/agent.sock",
            "--dockerd-sock", "/run/docker.sock",
            "--exit-after-handoff",
        ]
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(got.wait(timeout: .now() + 2), .success)
        let handoff = try resultBox.get()
        XCTAssertEqual(handoff.ready.machineID, "dev")
        XCTAssertEqual(handoff.ready.agentBuild, "dory-vmm/test")
        XCTAssertEqual(handoff.ready.agentSocketPath, "/run/agent.sock")
        XCTAssertEqual(handoff.ready.dockerdSocketPath, "/run/docker.sock")
    }
}

private final class LockedShimHandoffResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<VmmHandoff, Error>?

    var result: Result<VmmHandoff, Error>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    func get() throws -> VmmHandoff {
        switch try XCTUnwrap(result) {
        case let .success(handoff):
            return handoff
        case let .failure(error):
            throw error
        }
    }
}
