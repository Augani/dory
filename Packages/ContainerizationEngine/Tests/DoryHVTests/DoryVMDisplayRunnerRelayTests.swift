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
    }

    @Test func commandHandlerRoutesOnlyToSelectedVirtioEndpoint() throws {
        let inputs = Recorder<(DoryVMDisplayInputEndpoint, [VirtioInputEvent])>()
        let resizes = Recorder<(UInt32, UInt32, UInt32, UInt16, UInt16)>()
        let handler = DoryVMDisplayRunnerCommandHandler(
            input: { inputs.append(($0, $1)) },
            resize: { resizes.append(($0, $1, $2, $3, $4)) }
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

        #expect(inputs.snapshot.count == 1)
        #expect(inputs.snapshot[0].0 == .relativePointer)
        #expect(inputs.snapshot[0].1 == [VirtioInputEvent(type: 2, code: 0, value: -12)])
        #expect(resizes.snapshot.count == 1)
        #expect(resizes.snapshot[0].0 == 1)
        #expect(resizes.snapshot[0].1 == 2_560)
        #expect(resizes.snapshot[0].2 == 1_440)
        #expect(resizes.snapshot[0].3 == 310)
        #expect(resizes.snapshot[0].4 == 175)
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
}
