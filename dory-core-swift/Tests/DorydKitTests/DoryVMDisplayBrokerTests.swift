import DoryRendererWorkerWireContracts
import DoryVMDisplayWireContracts
import Foundation
import XCTest
@testable import DorydKit

final class DoryVMDisplayBrokerTests: XCTestCase {
    func testPublishReplyWaitsForOwningApplicationAcknowledgement() throws {
        let broker = broker()
        let runnerSession = UUID()
        let appSession = UUID()
        let wrongAppSession = UUID()
        let frame = try makeFrame(sequence: 1)
        let completion = CompletionCapture()
        let pipe = Pipe()

        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(frame),
            descriptors: [pipe.fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: runnerSession,
            processIdentifier: 42,
            reply: completion.record
        )
        XCTAssertTrue(completion.values.isEmpty)
        let delivery = try XCTUnwrap(broker.nextFrame(
            machineID: "ubuntu",
            scanoutID: 0,
            afterSequence: 0,
            applicationSessionID: appSession
        ))
        XCTAssertEqual(try DoryVMDisplayFrameCodec.decode(delivery.frame), frame)
        XCTAssertEqual(delivery.descriptors.count, 1)

        let leaseID = try frame.leaseID.rawValue
        XCTAssertThrowsError(try broker.acknowledgeFrame(
            machineID: "ubuntu",
            leaseID: leaseID,
            presented: true,
            metalCommandBufferCompletionID: 73,
            applicationSessionID: wrongAppSession
        ))
        XCTAssertTrue(completion.values.isEmpty)
        XCTAssertThrowsError(try broker.acknowledgeFrame(
            machineID: "ubuntu",
            leaseID: leaseID,
            presented: true,
            metalCommandBufferCompletionID: 0,
            applicationSessionID: appSession
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .invalidAcknowledgement)
        }
        XCTAssertThrowsError(try broker.acknowledgeFrame(
            machineID: "ubuntu",
            leaseID: leaseID,
            presented: false,
            metalCommandBufferCompletionID: 73,
            applicationSessionID: appSession
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .invalidAcknowledgement)
        }
        XCTAssertTrue(completion.values.isEmpty)
        try broker.acknowledgeFrame(
            machineID: "ubuntu",
            leaseID: leaseID,
            presented: true,
            metalCommandBufferCompletionID: 73,
            applicationSessionID: appSession
        )
        XCTAssertEqual(completion.values, [
            .init(presented: true, metalCommandBufferCompletionID: 73, detail: ""),
        ])
        XCTAssertThrowsError(try broker.acknowledgeFrame(
            machineID: "ubuntu",
            leaseID: leaseID,
            presented: true,
            metalCommandBufferCompletionID: 74,
            applicationSessionID: appSession
        ))
        XCTAssertEqual(completion.values.count, 1)
    }

    func testRunnerReplacementDeliversFirstFrameDespiteOldApplicationSequence() throws {
        let oldOperation = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let newOperation = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let broker = DoryVMDisplayBroker { machineID, operationID, pid in
            machineID == "ubuntu" && pid == 42
                && (operationID == oldOperation.uuidString.lowercased()
                    || operationID == newOperation.uuidString.lowercased())
        }
        let app = UUID()
        let oldRunner = UUID()
        let oldFrame = try makeFrame(sequence: 100, operationID: oldOperation)
        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(oldFrame),
            descriptors: [Pipe().fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: oldRunner,
            processIdentifier: 42,
            reply: { _, _, _ in }
        )
        XCTAssertNotNil(try broker.nextFrame(
            machineID: "ubuntu", scanoutID: 0, afterSequence: 0,
            applicationSessionID: app
        ))
        try broker.acknowledgeFrame(
            machineID: "ubuntu", leaseID: oldFrame.leaseID.rawValue,
            presented: true, metalCommandBufferCompletionID: 1,
            applicationSessionID: app
        )
        broker.invalidateRunner(sessionID: oldRunner)

        let newRunner = UUID()
        let firstNewFrame = try makeFrame(sequence: 1, operationID: newOperation)
        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(firstNewFrame),
            descriptors: [Pipe().fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: newRunner,
            processIdentifier: 42,
            reply: { _, _, _ in }
        )
        let delivered = try XCTUnwrap(broker.nextFrame(
            machineID: "ubuntu", scanoutID: 0, afterSequence: 100,
            applicationSessionID: app
        ))
        XCTAssertEqual(try DoryVMDisplayFrameCodec.decode(delivered.frame), firstNewFrame)
        try broker.acknowledgeFrame(
            machineID: "ubuntu", leaseID: firstNewFrame.leaseID.rawValue,
            presented: true, metalCommandBufferCompletionID: 2,
            applicationSessionID: app
        )

        let secondNewFrame = try makeFrame(sequence: 2, operationID: newOperation)
        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(secondNewFrame),
            descriptors: [Pipe().fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: newRunner,
            processIdentifier: 42,
            reply: { _, _, _ in }
        )
        let next = try XCTUnwrap(broker.nextFrame(
            machineID: "ubuntu", scanoutID: 0, afterSequence: 1,
            applicationSessionID: app
        ))
        XCTAssertEqual(try DoryVMDisplayFrameCodec.decode(next.frame), secondNewFrame)
    }

    func testApplicationDisconnectRejectsDeliveredLeaseExactlyOnce() throws {
        let broker = broker()
        let appSession = UUID()
        let completion = CompletionCapture()
        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(makeFrame(sequence: 1)),
            descriptors: [Pipe().fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: UUID(),
            processIdentifier: 42,
            reply: completion.record
        )
        XCTAssertNotNil(try broker.nextFrame(
            machineID: "ubuntu",
            scanoutID: 0,
            afterSequence: 0,
            applicationSessionID: appSession
        ))
        broker.invalidateApplication(sessionID: appSession)
        broker.invalidateApplication(sessionID: appSession)
        XCTAssertEqual(completion.values, [
            .init(
                presented: false,
                metalCommandBufferCompletionID: 0,
                detail: "application-disconnected"
            ),
        ])
    }

    func testGuestResetRevokesQueuedAndDeliveredCPUFramesWithoutRetiringRenderer() throws {
        let broker = broker()
        let runner = UUID()
        let app = UUID()
        let queued = try makeCPUFrame(sequence: 2)
        let delivered = try makeCPUFrame(sequence: 1)
        let renderer = try makeFrame(sequence: 3, scanoutID: 1)
        let deliveredCompletion = CompletionCapture()
        let queuedCompletion = CompletionCapture()
        let rendererCompletion = CompletionCapture()
        func publish(_ frame: DoryVMDisplayFrame, _ completion: CompletionCapture) throws {
            broker.publish(
                frameData: try DoryVMDisplayFrameCodec.encode(frame),
                descriptors: [Pipe().fileHandleForReading],
                sharedTextureHandle: nil,
                runnerSessionID: runner,
                processIdentifier: 42,
                reply: completion.record
            )
        }
        try publish(delivered, deliveredCompletion)
        XCTAssertNotNil(try broker.nextFrame(
            machineID: "ubuntu", scanoutID: 0, afterSequence: 0,
            applicationSessionID: app
        ))
        try publish(queued, queuedCompletion)
        try publish(renderer, rendererCompletion)
        try broker.retireCPUFrames(
            machineID: "ubuntu",
            operationID: delivered.operationID,
            runnerSessionID: runner,
            processIdentifier: 42
        )
        let rejected = [CompletionValue(
            presented: false,
            metalCommandBufferCompletionID: 0,
            detail: "guest-reset"
        )]
        XCTAssertEqual(deliveredCompletion.values, rejected)
        XCTAssertEqual(queuedCompletion.values, rejected)
        XCTAssertTrue(rendererCompletion.values.isEmpty)
        XCTAssertEqual(try DoryVMDisplayFrameCodec.decode(XCTUnwrap(broker.nextFrame(
            machineID: "ubuntu", scanoutID: 1, afterSequence: 0,
            applicationSessionID: app
        )).frame), renderer)
        XCTAssertThrowsError(try broker.acknowledgeFrame(
            machineID: "ubuntu", leaseID: delivered.leaseID.rawValue,
            presented: true, metalCommandBufferCompletionID: 9,
            applicationSessionID: UUID()
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .unknownLease)
        }
        XCTAssertThrowsError(try broker.acknowledgeFrame(
            machineID: "ubuntu", leaseID: delivered.leaseID.rawValue,
            presented: true, metalCommandBufferCompletionID: 9,
            applicationSessionID: app
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .retiredFrame)
        }
        try broker.acknowledgeFrame(
            machineID: "ubuntu", leaseID: renderer.leaseID.rawValue,
            presented: true, metalCommandBufferCompletionID: 10,
            applicationSessionID: app
        )
        XCTAssertEqual(rendererCompletion.values, [CompletionValue(
            presented: true, metalCommandBufferCompletionID: 10, detail: ""
        )])
    }

    func testResourceRetirementRevokesOnlyMatchingCPUFramesAndRejectsLatePublish() throws {
        let broker = broker()
        let runner = UUID()
        let app = UUID()
        let old = try makeCPUFrame(sequence: 1, resourceID: 7, resourceGeneration: 3)
        let other = try makeCPUFrame(sequence: 2, resourceID: 8, resourceGeneration: 1)
        let oldCompletion = CompletionCapture()
        let otherCompletion = CompletionCapture()
        func publish(_ frame: DoryVMDisplayFrame, _ completion: CompletionCapture) throws {
            broker.publish(
                frameData: try DoryVMDisplayFrameCodec.encode(frame),
                descriptors: [Pipe().fileHandleForReading],
                sharedTextureHandle: nil,
                runnerSessionID: runner,
                processIdentifier: 42,
                reply: completion.record
            )
        }
        try publish(old, oldCompletion)
        XCTAssertNotNil(try broker.nextFrame(
            machineID: "ubuntu", scanoutID: 0, afterSequence: 0,
            applicationSessionID: app))
        try publish(other, otherCompletion)
        try broker.retireCPUResource(
            machineID: "ubuntu", operationID: old.operationID,
            resourceID: 7, throughGeneration: 3,
            runnerSessionID: runner, processIdentifier: 42)
        XCTAssertEqual(oldCompletion.values.map(\.detail), ["resource-retired"])
        XCTAssertTrue(otherCompletion.values.isEmpty)
        XCTAssertEqual(try DoryVMDisplayFrameCodec.decode(XCTUnwrap(broker.nextFrame(
            machineID: "ubuntu", scanoutID: 0, afterSequence: 0,
            applicationSessionID: app)).frame), other)
        let staleCompletion = CompletionCapture()
        try publish(try makeCPUFrame(
            sequence: 3, resourceID: 7, resourceGeneration: 3), staleCompletion)
        XCTAssertEqual(staleCompletion.values.map(\.detail), ["retired-frame"])
    }

    func testResetBeforeFirstFrameRejectsDelayedOldEpoch() throws {
        let broker = broker()
        let runner = UUID()
        let operationID = "10000000-0000-0000-0000-000000000001"
        try broker.retireCPUFrames(
            machineID: "ubuntu", operationID: operationID,
            runnerSessionID: runner, processIdentifier: 42)
        XCTAssertThrowsError(try broker.retireCPUFrames(
            machineID: "ubuntu", operationID: operationID,
            runnerSessionID: UUID(), processIdentifier: 42
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .staleRunner)
        }
        let staleCompletion = CompletionCapture()
        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(makeCPUFrame(sequence: 1)),
            descriptors: [Pipe().fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: runner, processIdentifier: 42,
            reply: staleCompletion.record)
        XCTAssertEqual(staleCompletion.values.map(\.detail), ["retired-frame"])
        let currentCompletion = CompletionCapture()
        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(makeCPUFrame(
                sequence: 2, cpuEpoch: 2)),
            descriptors: [Pipe().fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: runner, processIdentifier: 42,
            reply: currentCompletion.record)
        XCTAssertTrue(currentCompletion.values.isEmpty)
    }

    func testResourceRetirementBeforeFirstFrameRejectsDelayedUnref() throws {
        let broker = broker()
        let runner = UUID()
        let operationID = "10000000-0000-0000-0000-000000000001"
        try broker.retireCPUResource(
            machineID: "ubuntu", operationID: operationID,
            resourceID: 7, throughGeneration: 3,
            runnerSessionID: runner, processIdentifier: 42)
        let staleCompletion = CompletionCapture()
        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(makeCPUFrame(
                sequence: 1, resourceID: 7, resourceGeneration: 3)),
            descriptors: [Pipe().fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: runner, processIdentifier: 42,
            reply: staleCompletion.record)
        XCTAssertEqual(staleCompletion.values.map(\.detail), ["retired-frame"])
        let currentCompletion = CompletionCapture()
        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(makeCPUFrame(
                sequence: 2, resourceID: 7, resourceGeneration: 4)),
            descriptors: [Pipe().fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: runner, processIdentifier: 42,
            reply: currentCompletion.record)
        XCTAssertTrue(currentCompletion.values.isEmpty)
    }

    func testRunnerSessionCannotStealGenerationAndDisconnectRetiresIt() throws {
        let broker = broker()
        let owner = UUID()
        let attacker = UUID()
        let first = CompletionCapture()
        let rejected = CompletionCapture()
        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(makeFrame(sequence: 1)),
            descriptors: [Pipe().fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: owner,
            processIdentifier: 42,
            reply: first.record
        )
        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(makeFrame(sequence: 2)),
            descriptors: [Pipe().fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: attacker,
            processIdentifier: 42,
            reply: rejected.record
        )
        XCTAssertEqual(rejected.values, [
            .init(
                presented: false,
                metalCommandBufferCompletionID: 0,
                detail: "stale-runner"
            ),
        ])
        broker.invalidateRunner(sessionID: owner)
        XCTAssertEqual(first.values, [
            .init(
                presented: false,
                metalCommandBufferCompletionID: 0,
                detail: "runner-disconnected"
            ),
        ])
    }

    func testCursorRegistersRunnerAndOnlyPublishesMonotonicLatestUpdate() throws {
        let broker = broker()
        let runner = UUID()
        let first = try makeCursor(sequence: 1, visible: true)
        try broker.publishCursor(
            cursorData: DoryVMDisplayCursorCodec.encode(first),
            runnerSessionID: runner,
            processIdentifier: 42
        )
        let delivered = try XCTUnwrap(broker.nextCursor(
            machineID: "ubuntu",
            scanoutID: 0,
            afterSequence: 0
        ))
        XCTAssertEqual(try DoryVMDisplayCursorCodec.decode(delivered), first)
        XCTAssertNil(try broker.nextCursor(
            machineID: "ubuntu",
            scanoutID: 0,
            afterSequence: 1
        ))
        XCTAssertThrowsError(try broker.publishCursor(
            cursorData: DoryVMDisplayCursorCodec.encode(first),
            runnerSessionID: runner,
            processIdentifier: 42
        ))

        let hidden = try makeCursor(sequence: 2, visible: false)
        try broker.publishCursor(
            cursorData: DoryVMDisplayCursorCodec.encode(hidden),
            runnerSessionID: runner,
            processIdentifier: 42
        )
        XCTAssertEqual(
            try DoryVMDisplayCursorCodec.decode(XCTUnwrap(broker.nextCursor(
                machineID: "ubuntu",
                scanoutID: 0,
                afterSequence: 1
            ))),
            hidden
        )
        broker.invalidateRunner(sessionID: runner)
        XCTAssertThrowsError(try broker.nextCursor(
            machineID: "ubuntu",
            scanoutID: 0,
            afterSequence: 0
        ))
    }

    func testCommandStatusRequiresOwningRunnerApplication() throws {
        let broker = broker()
        let runner = UUID()
        let operationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        broker.publish(
            frameData: try DoryVMDisplayFrameCodec.encode(makeFrame(sequence: 1)),
            descriptors: [Pipe().fileHandleForReading],
            sharedTextureHandle: nil,
            runnerSessionID: runner,
            processIdentifier: 42,
            reply: { _, _, _ in }
        )
        let command = try DoryVMDisplayCommand.input(
            machineID: "ubuntu",
            operationID: operationID,
            sequence: 1,
            endpoint: .keyboard,
            events: [
                .init(type: 1, code: 28, value: 1),
                .init(type: 1, code: 28, value: 0),
            ]
        )
        let appSession = UUID()
        try broker.registerApplication(sessionID: appSession)
        try broker.send(
            commandData: DoryVMDisplayCommandCodec.encode(command),
            applicationSessionID: appSession
        )
        XCTAssertEqual(
            broker.commandStatus(
                machineID: "ubuntu",
                operationID: operationID.uuidString.lowercased(),
                sequence: 1
            ).detail,
            "pending"
        )
        XCTAssertNotNil(try broker.nextCommand(
            machineID: "ubuntu",
            operationID: operationID.uuidString.lowercased(),
            afterSequence: 0,
            runnerSessionID: runner,
            processIdentifier: 42
        ))
        XCTAssertThrowsError(try broker.acknowledgeCommand(
            machineID: "ubuntu",
            operationID: operationID.uuidString.lowercased(),
            sequence: 1,
            applied: true,
            detail: "",
            runnerSessionID: UUID(),
            processIdentifier: 42
        ))
        try broker.acknowledgeCommand(
            machineID: "ubuntu",
            operationID: operationID.uuidString.lowercased(),
            sequence: 1,
            applied: true,
            detail: "",
            runnerSessionID: runner,
            processIdentifier: 42
        )
        let status = broker.commandStatus(
            machineID: "ubuntu",
            operationID: operationID.uuidString.lowercased(),
            sequence: 1
        )
        XCTAssertTrue(status.known)
        XCTAssertTrue(status.applied)
        XCTAssertEqual(status.detail, "")
    }

    func testConfirmedHotUnplugRetiresOnlyRemovedDisplayLeases() throws {
        let broker = broker()
        let runner = UUID()
        let app = UUID()
        let operationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let delivered = try makeFrame(sequence: 1, scanoutID: 1)
        let queued = try makeFrame(sequence: 2, scanoutID: 1)
        let retained = try makeFrame(sequence: 1, scanoutID: 0)
        let deliveredCompletion = CompletionCapture()
        let queuedCompletion = CompletionCapture()
        let retainedCompletion = CompletionCapture()
        func publish(_ frame: DoryVMDisplayFrame, _ completion: CompletionCapture) throws {
            broker.publish(
                frameData: try DoryVMDisplayFrameCodec.encode(frame),
                descriptors: [Pipe().fileHandleForReading],
                sharedTextureHandle: nil,
                runnerSessionID: runner,
                processIdentifier: 42,
                reply: completion.record
            )
        }
        try publish(delivered, deliveredCompletion)
        XCTAssertNotNil(try broker.nextFrame(
            machineID: "ubuntu", scanoutID: 1, afterSequence: 0,
            applicationSessionID: app
        ))
        try publish(queued, queuedCompletion)
        try publish(retained, retainedCompletion)

        let topology = try DoryVMDisplayCommand.topology(
            machineID: "ubuntu",
            operationID: operationID,
            sequence: 1,
            displays: [.init(
                width: 1_280,
                height: 800,
                physicalWidthMillimeters: 203,
                physicalHeightMillimeters: 127
            )]
        )
        try broker.registerApplication(sessionID: app)
        try broker.send(
            commandData: DoryVMDisplayCommandCodec.encode(topology),
            applicationSessionID: app
        )
        XCTAssertNotNil(try broker.nextCommand(
            machineID: "ubuntu", operationID: delivered.operationID,
            afterSequence: 0, runnerSessionID: runner, processIdentifier: 42
        ))
        XCTAssertTrue(deliveredCompletion.values.isEmpty)
        try broker.acknowledgeCommand(
            machineID: "ubuntu", operationID: delivered.operationID,
            sequence: 1, applied: true, detail: "",
            runnerSessionID: runner, processIdentifier: 42
        )
        let retired = [CompletionValue(
            presented: false,
            metalCommandBufferCompletionID: 0,
            detail: "scanout-removed"
        )]
        XCTAssertTrue(deliveredCompletion.values.isEmpty)
        XCTAssertEqual(queuedCompletion.values, retired)
        XCTAssertTrue(retainedCompletion.values.isEmpty)
        XCTAssertNil(try broker.nextFrame(
            machineID: "ubuntu", scanoutID: 1, afterSequence: 0,
            applicationSessionID: app
        ))
        XCTAssertThrowsError(try broker.acknowledgeFrame(
            machineID: "ubuntu", leaseID: delivered.leaseID.rawValue,
            presented: true, metalCommandBufferCompletionID: 9,
            applicationSessionID: app
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .retiredFrame)
        }
        XCTAssertEqual(deliveredCompletion.values, retired)
        let lateCompletion = CompletionCapture()
        try publish(try makeFrame(sequence: 3, scanoutID: 1), lateCompletion)
        XCTAssertEqual(lateCompletion.values, [CompletionValue(
            presented: false,
            metalCommandBufferCompletionID: 0,
            detail: "inactive-scanout"
        )])
        let staleCursor = try DoryVMDisplayCursor.visible(
            machineID: "ubuntu",
            operationID: operationID,
            scanoutID: 1,
            sequence: 1,
            resourceID: 2,
            x: 0,
            y: 0,
            width: 2,
            height: 2,
            hotX: 0,
            hotY: 0,
            bytes: Data(repeating: 0xFF, count: 16)
        )
        XCTAssertThrowsError(try broker.publishCursor(
            cursorData: DoryVMDisplayCursorCodec.encode(staleCursor),
            runnerSessionID: runner,
            processIdentifier: 42
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .inactiveScanout)
        }
        let hidden = try DoryVMDisplayCursor.hidden(
            machineID: "ubuntu",
            operationID: operationID,
            scanoutID: 1,
            sequence: 2
        )
        try broker.publishCursor(
            cursorData: DoryVMDisplayCursorCodec.encode(hidden),
            runnerSessionID: runner,
            processIdentifier: 42
        )
        XCTAssertNotNil(try broker.nextFrame(
            machineID: "ubuntu", scanoutID: 0, afterSequence: 0,
            applicationSessionID: app
        ))
    }

    private func broker() -> DoryVMDisplayBroker {
        DoryVMDisplayBroker { machineID, operationID, pid in
            machineID == "ubuntu"
                && operationID == "10000000-0000-0000-0000-000000000001"
                && pid == 42
        }
    }

    private func makeFrame(
        sequence: UInt64,
        scanoutID: UInt32 = 0,
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
            width: 64,
            height: 64,
            stride: 256,
            rowAlignment: 256,
            storageOffset: 0,
            declaredFileSize: 16_384,
            leaseByteCount: 16_384
        )
        return try DoryVMDisplayFrame(
            machineID: "ubuntu",
            operationID: operationID,
            scanoutID: scanoutID,
            sequence: sequence,
            displayResourceGeneration: sequence,
            transport: .sharedMemory,
            leasePayload: DoryRendererScanoutLeaseCodec.encode(lease),
            sourceRect: .init(x: 0, y: 0, width: 64, height: 64),
            dirtyRect: .init(x: 0, y: 0, width: 64, height: 64)
        )
    }

    private func makeCPUFrame(
        sequence: UInt64,
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
            scanoutID: 0,
            sequence: sequence,
            displayResourceGeneration: generation,
            transport: .cpuCopy,
            leasePayload: DoryVMDisplayCPUFrameLeaseCodec.encode(lease),
            sourceRect: .init(x: 0, y: 0, width: 64, height: 64),
            dirtyRect: .init(x: 0, y: 0, width: 64, height: 64)
        )
    }

    private func makeCursor(
        sequence: UInt64,
        visible: Bool
    ) throws -> DoryVMDisplayCursor {
        let operationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        if visible {
            return try .visible(
                machineID: "ubuntu",
                operationID: operationID,
                scanoutID: 0,
                sequence: sequence,
                resourceID: 2,
                x: 4,
                y: 8,
                width: 2,
                height: 2,
                hotX: 0,
                hotY: 1,
                bytes: Data(repeating: 0xFF, count: 16)
            )
        }
        return try .hidden(
            machineID: "ubuntu",
            operationID: operationID,
            scanoutID: 0,
            sequence: sequence
        )
    }
}

private struct CompletionValue: Equatable {
    let presented: Bool
    let metalCommandBufferCompletionID: UInt64
    let detail: String
}

private final class CompletionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CompletionValue] = []

    var values: [CompletionValue] { lock.withLock { storage } }

    func record(
        presented: Bool,
        metalCommandBufferCompletionID: UInt64,
        detail: String
    ) {
        lock.withLock {
            storage.append(.init(
                presented: presented,
                metalCommandBufferCompletionID: metalCommandBufferCompletionID,
                detail: detail
            ))
        }
    }
}
