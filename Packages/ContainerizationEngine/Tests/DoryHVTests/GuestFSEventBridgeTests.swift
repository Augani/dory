import DoryFSWorkerContracts
import Foundation
import Testing
@testable import DoryHV

struct GuestFSEventBridgeTests {
    @Test func requestCodecMatchesGuestLittleEndianWireShape() throws {
        let operationID: UInt64 = 0x1020_3040_5060_7080
        let frame = try GuestFSEventBatchCodec.encodeRequest(operationID: operationID, paths: [
            "/work/src/a.ts",
            "/work/space b.ts",
        ])

        #expect(frame.leUInt32(at: 0) == UInt32(frame.count - 4))
        #expect(frame.leUInt32(at: 4) == GuestFSEventBatchCodec.protocolVersion)
        #expect(frame.leUInt64(at: 8) == operationID)
        #expect(frame.leUInt32(at: 16) == 2)
        let firstLength = Int(frame.leUInt32(at: 20))
        #expect(String(decoding: frame[24..<(24 + firstLength)], as: UTF8.self) == "/work/src/a.ts")
        let secondLengthOffset = 24 + firstLength
        let secondLength = Int(frame.leUInt32(at: secondLengthOffset))
        #expect(String(
            decoding: frame[(secondLengthOffset + 4)..<(secondLengthOffset + 4 + secondLength)],
            as: UTF8.self
        ) == "/work/space b.ts")
    }

    @Test func requestCodecRejectsRelativeTraversalAndOversizedPaths() throws {
        #expect(throws: GuestFSEventBridgeError.invalidOperationID) {
            _ = try GuestFSEventBatchCodec.encodeRequest(operationID: 0, paths: ["/work/a"])
        }
        #expect(try GuestFSEventBatchCodec.encodeRequest(operationID: 0, paths: []).leUInt64(at: 8) == 0)
        #expect(throws: GuestFSEventBridgeError.invalidPath("relative")) {
            _ = try GuestFSEventBatchCodec.encodeRequest(operationID: 1, paths: ["relative"])
        }
        #expect(throws: GuestFSEventBridgeError.invalidPath("/work/../secret")) {
            _ = try GuestFSEventBatchCodec.encodeRequest(operationID: 1, paths: ["/work/../secret"])
        }
        let oversized = "/" + String(repeating: "x", count: GuestFSEventBatchCodec.maximumPathBytes)
        #expect(throws: GuestFSEventBridgeError.invalidPath(oversized)) {
            _ = try GuestFSEventBatchCodec.encodeRequest(operationID: 1, paths: [oversized])
        }
    }

    @Test func responseCodecValidatesOperationShapeAndExactFailedIndices() throws {
        let operationID: UInt64 = 987_654_321
        var frame = [UInt8]()
        frame.appendLE(UInt32(32))
        frame.appendLE(GuestFSEventBatchCodec.protocolVersion)
        frame.appendLE(operationID)
        frame.appendLE(UInt32(7))
        frame.appendLE(UInt32(0))
        frame.appendLE(UInt32(2))
        frame.appendLE(UInt32(1))
        frame.appendLE(UInt32(5))

        #expect(try GuestFSEventBatchCodec.decodeResponse(
            frame: frame,
            expectedOperationID: operationID,
            expectedPathCount: 7
        ) == .init(pathCount: 7, failedIndices: [1, 5]))
        #expect(throws: GuestFSEventBridgeError.invalidResponse) {
            _ = try GuestFSEventBatchCodec.decodeResponse(
                frame: Array(frame.dropLast()),
                expectedOperationID: operationID,
                expectedPathCount: 7
            )
        }
        #expect(throws: GuestFSEventBridgeError.invalidResponse) {
            _ = try GuestFSEventBatchCodec.decodeResponse(
                frame: frame,
                expectedOperationID: operationID + 1,
                expectedPathCount: 7
            )
        }

        var duplicateIndex = frame
        duplicateIndex.replaceSubrange(32..<36, with: UInt32(1).littleEndianBytes)
        #expect(throws: GuestFSEventBridgeError.invalidResponse) {
            _ = try GuestFSEventBatchCodec.decodeResponse(
                frame: duplicateIndex,
                expectedOperationID: operationID,
                expectedPathCount: 7
            )
        }
    }

    @Test func responseCodecSurfacesExplicitDedupeRejections() {
        var frame = [UInt8]()
        frame.appendLE(UInt32(24))
        frame.appendLE(GuestFSEventBatchCodec.protocolVersion)
        frame.appendLE(UInt64(55))
        frame.appendLE(UInt32(1))
        frame.appendLE(UInt32(1))
        frame.appendLE(UInt32(0))

        #expect(throws: GuestFSEventBridgeError.operationIDConflict) {
            _ = try GuestFSEventBatchCodec.decodeResponse(
                frame: frame,
                expectedOperationID: 55,
                expectedPathCount: 1
            )
        }
    }

    @Test func operationIDsAreUniqueAcrossConcurrentCallers() async {
        let values = await withTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for _ in 0..<1_000 {
                group.addTask { GuestFSEventOperationIDs.next() }
            }
            var values = [UInt64]()
            for await value in group { values.append(value) }
            return values
        }
        #expect(Set(values).count == values.count)
        #expect(!values.contains(0))
    }

    @Test func firstRoundTripRetriesOnlyStartupTransportFailure() throws {
        let clock = GuestFSEventGateClock()
        let gate = GuestFSEventReadinessGate(
            attemptTimeoutNanoseconds: 2_000_000_000,
            startupGraceNanoseconds: 30_000_000_000,
            retryDelayNanoseconds: 50_000_000,
            uptime: clock.uptime,
            sleep: clock.sleep
        )
        var attempts = 0
        var observedTimeouts = [UInt64]()

        #expect(throws: GuestFSEventBridgeError.watcherNotReady) {
            _ = try gate.perform { _ in "should not run" }
        }

        let value: String = try gate.establish { timeout in
            attempts += 1
            observedTimeouts.append(timeout)
            if attempts <= 2 { throw GuestFSEventBridgeError.connectionClosed }
            return "ready"
        }

        #expect(value == "ready")
        #expect(attempts == 3)
        #expect(observedTimeouts == [2_000_000_000, 2_000_000_000, 2_000_000_000])
        #expect(clock.sleeps == [50_000_000, 100_000_000])
        #expect(gate.isReady)

        #expect(throws: GuestFSEventBridgeError.timedOut) {
            _ = try gate.perform { _ -> String in
                attempts += 1
                throw GuestFSEventBridgeError.timedOut
            }
        }
        #expect(attempts == 4)
        #expect(clock.sleeps == [50_000_000, 100_000_000])
    }

    @Test func startupSemanticFailureNeverRetries() {
        let clock = GuestFSEventGateClock()
        let gate = GuestFSEventReadinessGate(
            attemptTimeoutNanoseconds: 2_000_000_000,
            startupGraceNanoseconds: 30_000_000_000,
            retryDelayNanoseconds: 50_000_000,
            uptime: clock.uptime,
            sleep: clock.sleep
        )
        var attempts = 0

        #expect(throws: GuestFSEventBridgeError.guestExecutionFailed) {
            _ = try gate.establish { _ -> String in
                attempts += 1
                throw GuestFSEventBridgeError.guestExecutionFailed
            }
        }
        #expect(attempts == 1)
        #expect(clock.sleeps.isEmpty)
        #expect(!gate.isReady)
    }

    @Test func nestedTimeoutBudgetsCannotExpireOuterTransactionsFirst() {
        #expect(
            DoryFSWorkerCoherenceTiming.reverseExchangeNanoseconds
                > 1_000_000_000
                    + DoryFSWorkerCoherenceTiming.guestWatcherAttemptNanoseconds
        )
        #expect(
            DoryFSWorkerCoherenceTiming.activationRequestNanoseconds
                > DoryFSWorkerCoherenceTiming.activationCatchupNanoseconds
                    + DoryFSWorkerCoherenceTiming.reverseExchangeNanoseconds
        )
    }
}

private final class GuestFSEventGateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 100
    private var recordedSleeps = [UInt64]()

    var sleeps: [UInt64] { lock.withLock { recordedSleeps } }

    func uptime() -> TimeInterval { lock.withLock { current } }

    func sleep(_ nanoseconds: UInt64) {
        lock.withLock {
            recordedSleeps.append(nanoseconds)
            current += Double(nanoseconds) / 1_000_000_000
        }
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
