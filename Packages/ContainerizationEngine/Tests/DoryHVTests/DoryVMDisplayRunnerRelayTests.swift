import DoryHV
import DoryVMDisplayWireContracts
import Foundation
import Metal
import Testing
@testable import dory_hv

struct DoryVMDisplayRunnerRelayTests {
    private final class Recorder<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Value] = []

        func append(_ value: Value) {
            lock.withLock { values.append(value) }
        }

        var snapshot: [Value] {
            lock.withLock { values }
        }
    }

    private final class FakeTransport: DoryVMDisplayRunnerTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [Data]
        private(set) var retireCount = 0
        private(set) var invalidateCount = 0
        private var publishedCursors: [Data] = []

        init(commands: [Data] = []) {
            self.commands = commands
        }

        func publishFrame(
            _ frame: Data,
            descriptors: [FileHandle],
            sharedTextureHandle: MTLSharedTextureHandle?,
            reply: @escaping @Sendable (Bool, String) -> Void
        ) {
            reply(false, "unused")
        }

        func publishCursor(
            _ cursor: Data,
            reply: @escaping @Sendable (Bool, String) -> Void
        ) {
            lock.withLock { publishedCursors.append(cursor) }
            reply(true, "")
        }

        func nextCommand(
            machineID: String,
            operationID: String,
            afterSequence: UInt64,
            reply: @escaping @Sendable (Bool, Data, String) -> Void
        ) {
            let command = lock.withLock {
                commands.isEmpty ? nil : commands.removeFirst()
            }
            if let command {
                reply(true, command, "")
            } else {
                reply(false, Data(), "no-command")
            }
        }

        func retireRunner(
            machineID: String,
            operationID: String,
            reply: @escaping @Sendable (Bool, String) -> Void
        ) {
            lock.withLock { retireCount += 1 }
            reply(true, "")
        }

        func invalidate() {
            lock.withLock { invalidateCount += 1 }
        }

        var lifecycleCounts: (retire: Int, invalidate: Int) {
            lock.withLock { (retireCount, invalidateCount) }
        }


        var cursors: [Data] { lock.withLock { publishedCursors } }
    }

    @Test func presentationIntervalsArePerScanoutBoundedAndNearestRanked() {
        let intervals = DoryVMDisplayPresentationIntervals(maximumSampleCount: 4)
        intervals.recordPresented(scanoutID: 0, monotonicNanoseconds: 100)
        intervals.recordPresented(scanoutID: 0, monotonicNanoseconds: 110)
        intervals.recordPresented(scanoutID: 1, monotonicNanoseconds: 1_000)
        intervals.recordPresented(scanoutID: 0, monotonicNanoseconds: 130)
        intervals.recordPresented(scanoutID: 1, monotonicNanoseconds: 1_030)
        intervals.recordPresented(scanoutID: 0, monotonicNanoseconds: 170)
        intervals.recordPresented(scanoutID: 0, monotonicNanoseconds: 220)

        #expect(intervals.metrics == DoryVMDisplayPresentationIntervalMetrics(
            sampleCount: 4,
            p95Nanoseconds: 50,
            p99Nanoseconds: 50
        ))
    }

    @Test func commandHandlerRoutesOnlyToSelectedVirtioEndpoint() throws {
        let inputs = Recorder<(DoryVMDisplayInputEndpoint, [VirtioInputEvent])>()
        let resizes = Recorder<(UInt32, UInt32, UInt32, UInt16, UInt16)>()
        let topologies = Recorder<[DoryVMDisplayTopologyEntry]>()
        let handler = DoryVMDisplayRunnerCommandHandler(
            input: { inputs.append(($0, $1)) },
            resize: { resizes.append(($0, $1, $2, $3, $4)) },
            topology: { topologies.append($0) }
        )
        let operationID = UUID()

        handler.apply(try .input(
            machineID: "ubuntu",
            operationID: operationID,
            sequence: 1,
            endpoint: .relativePointer,
            events: [DoryVMDisplayInputEvent(type: 2, code: 0, value: -12)]
        ))
        handler.apply(try .resize(
            machineID: "ubuntu",
            operationID: operationID,
            sequence: 2,
            scanoutID: 1,
            width: 2_560,
            height: 1_440,
            physicalWidthMillimeters: 310,
            physicalHeightMillimeters: 175
        ))
        let topology: [DoryVMDisplayTopologyEntry] = [
            .init(
                width: 2_560,
                height: 1_440,
                physicalWidthMillimeters: 310,
                physicalHeightMillimeters: 175
            ),
            .init(
                width: 1_920,
                height: 1_080,
                physicalWidthMillimeters: 286,
                physicalHeightMillimeters: 161
            ),
        ]
        handler.apply(try .topology(
            machineID: "ubuntu",
            operationID: operationID,
            sequence: 3,
            displays: topology
        ))

        #expect(inputs.snapshot.count == 1)
        #expect(inputs.snapshot[0].0 == .relativePointer)
        #expect(inputs.snapshot[0].1 == [VirtioInputEvent(type: 2, code: 0, value: -12)])
        #expect(resizes.snapshot.count == 1)
        #expect(resizes.snapshot[0].0 == 1)
        #expect(resizes.snapshot[0].1 == 2_560)
        #expect(resizes.snapshot[0].2 == 1_440)
        #expect(resizes.snapshot[0].3 == 310)
        #expect(resizes.snapshot[0].4 == 175)
        #expect(topologies.snapshot == [topology])
    }

    @Test func relayPollsCanonicalCommandAndRetiresExactlyOnce() throws {
        let operationID = UUID()
        let command = try DoryVMDisplayCommand.input(
            machineID: "fedora",
            operationID: operationID,
            sequence: 1,
            endpoint: .keyboard,
            events: [DoryVMDisplayInputEvent(type: 1, code: 30, value: 1)]
        )
        let transport = FakeTransport(commands: [try DoryVMDisplayCommandCodec.encode(command)])
        let delivered = DispatchSemaphore(value: 0)
        let inputs = Recorder<[VirtioInputEvent]>()
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "fedora",
            operationID: operationID,
            transport: transport,
            commandHandler: DoryVMDisplayRunnerCommandHandler(
                input: { _, events in
                    inputs.append(events)
                    delivered.signal()
                },
                resize: { _, _, _, _, _ in }
            )
        )

        relay.start()
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        relay.stop()
        relay.stop()

        #expect(inputs.snapshot == [[VirtioInputEvent(type: 1, code: 30, value: 1)]])
        #expect(transport.lifecycleCounts.retire == 1)
        #expect(transport.lifecycleCounts.invalidate == 1)
    }

    @Test func relayPublishesCopiedCursorAndExplicitHideForEveryScanout() throws {
        let operationID = UUID()
        let transport = FakeTransport()
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "ubuntu",
            operationID: operationID,
            transport: transport,
            commandHandler: .init(input: { _, _ in }, resize: { _, _, _, _, _ in })
        )
        relay.publishCursor(.init(
            scanoutID: 1,
            resourceID: 8,
            x: 12,
            y: 24,
            width: 2,
            height: 2,
            hotX: 1,
            hotY: 1,
            bytes: Data(repeating: 0xA5, count: 16)
        ), scanoutCount: 2)
        relay.publishCursor(nil, scanoutCount: 2)

        let cursors = try transport.cursors.map(DoryVMDisplayCursorCodec.decode)
        #expect(cursors.count == 3)
        #expect(cursors[0].scanoutID == 1)
        #expect(cursors[0].visible)
        #expect(cursors[0].bytes == Data(repeating: 0xA5, count: 16))
        #expect(cursors[1].scanoutID == 0 && !cursors[1].visible)
        #expect(cursors[2].scanoutID == 1 && !cursors[2].visible)
        #expect(cursors.map(\.sequence) == [1, 2, 3])
        relay.stop()
    }
}
