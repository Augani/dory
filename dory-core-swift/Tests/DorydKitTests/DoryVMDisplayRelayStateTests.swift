import DoryRendererWorkerWireContracts
import DoryVMDisplayWireContracts
import XCTest
@testable import DorydKit

final class DoryVMDisplayRelayStateTests: XCTestCase {
    func testQueueEvictsOldestUndeliveredFrameAndAcknowledgesExactlyOnce() throws {
        var state = DoryVMDisplayRelayState<String>()
        XCTAssertTrue(try state.publish(frame: frame(sequence: 1), authority: "one").evicted.isEmpty)
        XCTAssertTrue(try state.publish(frame: frame(sequence: 2), authority: "two").evicted.isEmpty)
        let result = try state.publish(frame: frame(sequence: 3), authority: "three")
        XCTAssertEqual(result.evicted.map(\.authority), ["one"])

        let next = try XCTUnwrap(state.nextFrame(
            machineID: "ubuntu",
            scanoutID: 0,
            afterSequence: 0
        ))
        XCTAssertEqual(next.frame.sequence, 2)
        let leaseID = try next.frame.leaseID.rawValue
        XCTAssertEqual(try state.acknowledgeFrame(
            machineID: "ubuntu",
            leaseID: leaseID
        ).authority, "two")
        XCTAssertThrowsError(try state.acknowledgeFrame(
            machineID: "ubuntu",
            leaseID: leaseID
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .unknownLease)
        }
    }

    func testDeliveredFramesCannotBeEvictedAndBackpressureRejectsPublisher() throws {
        var state = DoryVMDisplayRelayState<Int>()
        _ = try state.publish(frame: frame(sequence: 1), authority: 1)
        _ = try state.publish(frame: frame(sequence: 2), authority: 2)
        XCTAssertNotNil(try state.nextFrame(machineID: "ubuntu", scanoutID: 0, afterSequence: 0))
        XCTAssertNotNil(try state.nextFrame(machineID: "ubuntu", scanoutID: 0, afterSequence: 1))
        XCTAssertThrowsError(try state.publish(frame: frame(sequence: 3), authority: 3)) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .saturated)
        }
    }

    func testRunnerGenerationAndSequencesFailClosed() throws {
        var state = DoryVMDisplayRelayState<Int>()
        _ = try state.publish(frame: frame(sequence: 2), authority: 1)
        XCTAssertThrowsError(try state.publish(frame: frame(sequence: 2), authority: 2)) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .nonMonotonicSequence)
        }
        XCTAssertThrowsError(try state.publish(
            frame: frame(
                sequence: 3,
                operationID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
            ),
            authority: 3
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .staleRunner)
        }
    }

    func testGuestResetRetiresCPUFramesButPreservesRendererAndSequence() throws {
        var state = DoryVMDisplayRelayState<String>()
        let deliveredCPU = try cpuFrame(sequence: 1)
        let queuedCPU = try cpuFrame(sequence: 2)
        let renderer = try frame(sequence: 3, scanoutID: 1)
        _ = try state.publish(frame: deliveredCPU, authority: "delivered-cpu")
        XCTAssertNotNil(try state.nextFrame(machineID: "ubuntu", scanoutID: 0, afterSequence: 0))
        _ = try state.publish(frame: queuedCPU, authority: "queued-cpu")
        _ = try state.publish(frame: renderer, authority: "renderer")

        let retired = try state.retireCPUFrames(
            machineID: "ubuntu",
            operationID: deliveredCPU.operationID
        )
        XCTAssertEqual(retired.queued.map(\.authority), ["queued-cpu"])
        XCTAssertEqual(retired.delivered.map(\.authority), ["delivered-cpu"])
        XCTAssertEqual(try state.nextFrame(
            machineID: "ubuntu", scanoutID: 1, afterSequence: 0
        )?.authority, "renderer")
        XCTAssertThrowsError(try state.acknowledgeFrame(
            machineID: "ubuntu", leaseID: deliveredCPU.leaseID.rawValue
        ))
        XCTAssertThrowsError(try state.publish(
            frame: cpuFrame(sequence: 2), authority: "stale-cpu"
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .retiredFrame)
        }
        _ = try state.publish(frame: cpuFrame(sequence: 4, cpuEpoch: 2), authority: "new-cpu")
    }

    func testCPUFrameCannotClaimFutureResetEpoch() throws {
        var state = DoryVMDisplayRelayState<String>()
        let current = try cpuFrame(sequence: 1)
        _ = try state.publish(frame: current, authority: "current")
        XCTAssertThrowsError(try state.publish(
            frame: cpuFrame(sequence: 2, cpuEpoch: 2), authority: "future"
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .retiredFrame)
        }
        _ = try state.retireCPUFrames(
            machineID: "ubuntu", operationID: current.operationID)
        _ = try state.publish(
            frame: cpuFrame(sequence: 2, cpuEpoch: 2), authority: "after-reset")
    }

    func testRetireCPUResourcePreservesOtherIncarnationsAndScanouts() throws {
        var state = DoryVMDisplayRelayState<String>()
        let old = try cpuFrame(sequence: 1, resourceID: 7, resourceGeneration: 3)
        let replacement = try cpuFrame(sequence: 2, resourceID: 7, resourceGeneration: 4)
        let other = try cpuFrame(
            sequence: 1, scanoutID: 1, resourceID: 8, resourceGeneration: 1)
        _ = try state.publish(frame: old, authority: "old")
        XCTAssertNotNil(try state.nextFrame(machineID: "ubuntu", scanoutID: 0,
            afterSequence: 0))
        _ = try state.publish(frame: replacement, authority: "replacement")
        _ = try state.publish(frame: other, authority: "other")

        let retired = try state.retireCPUResource(
            machineID: "ubuntu", operationID: old.operationID,
            resourceID: 7, throughGeneration: 3)
        XCTAssertTrue(retired.queued.isEmpty)
        XCTAssertEqual(retired.delivered.map(\.authority), ["old"])
        XCTAssertThrowsError(try state.publish(
            frame: cpuFrame(sequence: 3, resourceID: 7, resourceGeneration: 3),
            authority: "stale")) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .retiredFrame)
        }
        XCTAssertEqual(try state.nextFrame(machineID: "ubuntu", scanoutID: 0,
            afterSequence: 0)?.authority, "replacement")
        XCTAssertEqual(try state.nextFrame(machineID: "ubuntu", scanoutID: 1,
            afterSequence: 0)?.authority, "other")
    }

    func testAppliedTopologyRetiresRemovedScanoutAndRejectsLateFrames() throws {
        var state = DoryVMDisplayRelayState<String>()
        let delivered = try frame(sequence: 1, scanoutID: 2)
        let queued = try frame(sequence: 2, scanoutID: 2)
        let remaining = try frame(sequence: 1, scanoutID: 1)
        _ = try state.publish(frame: delivered, authority: "delivered")
        XCTAssertNotNil(try state.nextFrame(
            machineID: "ubuntu", scanoutID: 2, afterSequence: 0
        ))
        _ = try state.publish(frame: queued, authority: "queued")
        _ = try state.publish(frame: remaining, authority: "remaining")

        let retired = try state.applyTopology(
            machineID: "ubuntu",
            operationID: delivered.operationID,
            activeScanoutCount: 2
        )
        XCTAssertEqual(retired.queuedRetired.map(\.authority), ["queued"])
        XCTAssertEqual(retired.deliveredToRevoke.map(\.authority), ["delivered"])
        XCTAssertEqual(try state.acknowledgeFrame(
            machineID: "ubuntu", leaseID: delivered.leaseID.rawValue
        ).authority, "delivered")
        XCTAssertEqual(try state.nextFrame(
            machineID: "ubuntu", scanoutID: 1, afterSequence: 0
        )?.authority, "remaining")
        XCTAssertThrowsError(try state.publish(
            frame: frame(sequence: 3, scanoutID: 2), authority: "late"
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .inactiveScanout)
        }
        _ = try state.applyTopology(
            machineID: "ubuntu",
            operationID: delivered.operationID,
            activeScanoutCount: 3
        )
        _ = try state.publish(frame: frame(sequence: 3, scanoutID: 2), authority: "reconnected")
    }

    func testCommandsAreOrderedToActiveRunnerAndRetiredWithFrames() throws {
        var state = DoryVMDisplayRelayState<String>()
        _ = try state.publish(frame: frame(sequence: 1), authority: "frame")
        let operationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let command = try DoryVMDisplayCommand.resize(
            machineID: "ubuntu",
            operationID: operationID,
            sequence: 4,
            scanoutID: 0,
            width: 1_920,
            height: 1_080,
            physicalWidthMillimeters: 300,
            physicalHeightMillimeters: 170
        )
        try state.send(command: command)
        XCTAssertEqual(try state.nextCommand(
            machineID: "ubuntu",
            operationID: operationID.uuidString.lowercased(),
            afterSequence: 0
        ), command)
        XCTAssertThrowsError(try state.send(command: command)) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .nonMonotonicSequence)
        }

        let retired = try state.retireRunner(
            machineID: "ubuntu",
            operationID: operationID.uuidString.lowercased()
        )
        XCTAssertEqual(retired.frames.map(\.authority), ["frame"])
        XCTAssertTrue(retired.commands.isEmpty)
        XCTAssertThrowsError(try state.nextFrame(
            machineID: "ubuntu",
            scanoutID: 0,
            afterSequence: 0
        ))
    }

    private func frame(
        sequence: UInt64,
        operationID: UUID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        scanoutID: UInt32 = 0
    ) throws -> DoryVMDisplayFrame {
        let lease = try DoryRendererScanoutLease(
            workerGeneration: .init(rawValue: 1),
            resourceID: 1,
            resourceGeneration: sequence,
            leaseID: .init(rawValue: UUID()),
            releaseToken: .init(rawValue: UUID()),
            sharedRegionID: .init(rawValue: UUID()),
            sharedMemoryDescriptorIndex: 0,
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: .bgra8Unorm,
            yOriginTop: true,
            width: 1_920,
            height: 1_080,
            stride: 7_680,
            rowAlignment: 256,
            storageOffset: 0,
            declaredFileSize: 8_294_400,
            leaseByteCount: 8_294_400
        )
        return try DoryVMDisplayFrame(
            machineID: "ubuntu",
            operationID: operationID,
            scanoutID: scanoutID,
            sequence: sequence,
            displayResourceGeneration: sequence,
            transport: .sharedMemory,
            leasePayload: DoryRendererScanoutLeaseCodec.encode(lease),
            sourceRect: .init(x: 0, y: 0, width: 1_920, height: 1_080),
            dirtyRect: .init(x: 0, y: 0, width: 1_920, height: 1_080)
        )
    }

    private func cpuFrame(
        sequence: UInt64,
        scanoutID: UInt32 = 0,
        resourceID: UInt32 = 1,
        resourceGeneration: UInt64? = nil,
        cpuEpoch: UInt64 = 1
    ) throws -> DoryVMDisplayFrame {
        let generation = resourceGeneration ?? sequence
        let lease = try DoryVMDisplayCPUFrameLease(
            leaseID: UUID(),
            releaseToken: UUID(),
            resourceID: resourceID,
            resourceGeneration: generation,
            cpuEpoch: cpuEpoch,
            pixelFormat: DoryRendererScanoutPixelFormat.bgra8Unorm.rawValue,
            yOriginTop: true,
            width: 64,
            height: 64,
            stride: 256,
            declaredFileSize: 16_384
        )
        return try DoryVMDisplayFrame(
            machineID: "ubuntu",
            operationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            scanoutID: scanoutID,
            sequence: sequence,
            displayResourceGeneration: generation,
            transport: .cpuCopy,
            leasePayload: DoryVMDisplayCPUFrameLeaseCodec.encode(lease),
            sourceRect: .init(x: 0, y: 0, width: 64, height: 64),
            dirtyRect: .init(x: 0, y: 0, width: 64, height: 64)
        )
    }
}
