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
        operationID: UUID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
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
            scanoutID: 0,
            sequence: sequence,
            displayResourceGeneration: sequence,
            transport: .sharedMemory,
            leasePayload: DoryRendererScanoutLeaseCodec.encode(lease),
            sourceRect: .init(x: 0, y: 0, width: 1_920, height: 1_080),
            dirtyRect: .init(x: 0, y: 0, width: 1_920, height: 1_080)
        )
    }
}
