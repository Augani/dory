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
            applicationSessionID: wrongAppSession
        ))
        XCTAssertTrue(completion.values.isEmpty)
        try broker.acknowledgeFrame(
            machineID: "ubuntu",
            leaseID: leaseID,
            presented: true,
            applicationSessionID: appSession
        )
        XCTAssertEqual(completion.values, [.init(presented: true, detail: "")])
        XCTAssertThrowsError(try broker.acknowledgeFrame(
            machineID: "ubuntu",
            leaseID: leaseID,
            presented: true,
            applicationSessionID: appSession
        ))
        XCTAssertEqual(completion.values.count, 1)
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
            .init(presented: false, detail: "application-disconnected"),
        ])
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
        XCTAssertEqual(rejected.values, [.init(presented: false, detail: "stale-runner")])
        broker.invalidateRunner(sessionID: owner)
        XCTAssertEqual(first.values, [.init(presented: false, detail: "runner-disconnected")])
    }

    private func broker() -> DoryVMDisplayBroker {
        DoryVMDisplayBroker { machineID, operationID, pid in
            machineID == "ubuntu"
                && operationID == "10000000-0000-0000-0000-000000000001"
                && pid == 42
        }
    }

    private func makeFrame(sequence: UInt64) throws -> DoryVMDisplayFrame {
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
            operationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            scanoutID: 0,
            sequence: sequence,
            displayResourceGeneration: sequence,
            transport: .sharedMemory,
            leasePayload: DoryRendererScanoutLeaseCodec.encode(lease),
            sourceRect: .init(x: 0, y: 0, width: 64, height: 64),
            dirtyRect: .init(x: 0, y: 0, width: 64, height: 64)
        )
    }
}

private struct CompletionValue: Equatable {
    let presented: Bool
    let detail: String
}

private final class CompletionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CompletionValue] = []

    var values: [CompletionValue] { lock.withLock { storage } }

    func record(presented: Bool, detail: String) {
        lock.withLock { storage.append(.init(presented: presented, detail: detail)) }
    }
}
