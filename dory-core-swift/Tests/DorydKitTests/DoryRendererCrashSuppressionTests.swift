import Foundation
import Testing
@testable import DorydKit
import DoryRendererWorkerWireContracts

@Suite("Renderer crash suppression")
struct DoryRendererCrashSuppressionTests {
    @Test("one exact candidate is durably suppressed and a rebuilt worker is not")
    func exactCandidateSuppression() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let candidate = try makeCandidate(runtime: "a", inventory: "b", worker: "c")
        let rebuiltWorker = try makeCandidate(runtime: "a", inventory: "b", worker: "d")
        let store = DoryRendererCrashSuppressionStore(
            stateDirectory: root.path,
            suppressionInterval: 120,
            now: { clock.value }
        )

        #expect(!store.isSuppressed(candidate))
        try store.recordFailure(candidate)
        #expect(store.isSuppressed(candidate))
        #expect(!store.isSuppressed(rebuiltWorker))

        let reopened = DoryRendererCrashSuppressionStore(
            stateDirectory: root.path,
            suppressionInterval: 120,
            now: { clock.value }
        )
        #expect(reopened.isSuppressed(candidate))
        clock.advance(seconds: 121)
        #expect(!reopened.isSuppressed(candidate))
    }

    @Test("successful readiness clears only the matching candidate")
    func successfulReadinessClearsCandidate() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let first = try makeCandidate(runtime: "a", inventory: "b", worker: "c")
        let second = try makeCandidate(runtime: "a", inventory: "b", worker: "d")
        let store = DoryRendererCrashSuppressionStore(
            stateDirectory: root.path,
            now: { clock.value }
        )

        try store.recordFailure(first)
        try store.recordFailure(second)
        try store.recordSuccessfulReadiness(first)
        #expect(!store.isSuppressed(first))
        #expect(store.isSuppressed(second))
    }

    @Test("corrupt health evidence fails acceleration closed")
    func corruptStateFailsClosed() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("not canonical renderer health\n".utf8).write(
            to: root.appendingPathComponent(".renderer-runtime-health-v1.json")
        )
        let candidate = try makeCandidate(runtime: "a", inventory: "b", worker: "c")
        let store = DoryRendererCrashSuppressionStore(stateDirectory: root.path)
        #expect(store.isSuppressed(candidate))
    }

    @Test("production renderer host fact consults the exact circuit breaker")
    func productionHostFactUsesSuppression() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try makeAdmission(runtime: "a", inventory: "b", worker: "c")
        let runtime = DoryDaemonVerifiedBackendRuntime(
            descriptor: RawHVLinuxMachineBackend.backendDescriptor,
            executablePath: "/verified/DoryHVRunner.app/Contents/MacOS/dory-hv",
            runtimeBuildIdentifier: admission.runtimeBuildIdentifier,
            components: [],
            rendererAccelerationAdmission: admission
        )
        let store = DoryRendererCrashSuppressionStore(stateDirectory: root.path)
        #expect(runtime.productionAccelerationIsAdmissible(
            crashSuppressionStore: store
        ))

        try store.recordFailure(
            DoryRendererCrashSuppressionCandidate(admission: admission)
        )
        #expect(!runtime.productionAccelerationIsAdmissible(
            crashSuppressionStore: store
        ))
    }

    private func makeCandidate(
        runtime: Character,
        inventory: Character,
        worker: Character
    ) throws -> DoryRendererCrashSuppressionCandidate {
        DoryRendererCrashSuppressionCandidate(admission: try makeAdmission(
            runtime: runtime,
            inventory: inventory,
            worker: worker
        ))
    }

    private func makeAdmission(
        runtime: Character,
        inventory: Character,
        worker: Character
    ) throws -> DoryDaemonRendererAccelerationAdmission {
        DoryDaemonRendererAccelerationAdmission(
            runtimeBuildIdentifier: "sha256:" + String(repeating: runtime, count: 64),
            candidateInventory: try digest(inventory),
            guestMesa: try DoryRendererArtifactDigest(
                lowercaseSHA256: DoryRendererSourceTuple.guestMesaRuntimeSHA256
            ),
            rendererWorkerExecutable: try digest(worker),
            bootstrapQualification: try digest("e")
        )
    }

    private func digest(_ character: Character) throws -> DoryRendererArtifactDigest {
        try DoryRendererArtifactDigest(
            lowercaseSHA256: String(repeating: character, count: 64)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-renderer-suppression-tests-" + UUID().uuidString,
            isDirectory: true
        )
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ value: Date) {
        stored = value
    }

    var value: Date {
        lock.withLock { stored }
    }

    func advance(seconds: TimeInterval) {
        lock.withLock { stored = stored.addingTimeInterval(seconds) }
    }
}
