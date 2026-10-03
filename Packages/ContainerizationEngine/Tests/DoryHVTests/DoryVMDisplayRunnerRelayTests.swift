import DoryHV
import DoryVMDisplayWireContracts
import Foundation
import Metal
import Testing
@testable import dory_hv

struct DoryVMDisplayRunnerRelayTests {
    @Test func acceleratedFrameBudgetIsPerScanoutAndReleasesAfterAcknowledgement() {
        let maximum = 3
        let pending: [UInt32] = [0, 1, 0, 1, 0]
        #expect(!DoryVMDisplayAcceleratedFrameAdmission.accepts(
            scanoutID: 0, pendingScanoutIDs: pending, maximumPerScanout: maximum))
        #expect(DoryVMDisplayAcceleratedFrameAdmission.accepts(
            scanoutID: 1, pendingScanoutIDs: pending, maximumPerScanout: maximum))
        #expect(DoryVMDisplayAcceleratedFrameAdmission.accepts(
            scanoutID: 0, pendingScanoutIDs: pending.dropLast(), maximumPerScanout: maximum))
    }

    @Test func expectedLeaseRetirementDoesNotMasqueradeAsRendererFailure() {
        for detail in [
            "frame-evicted", "scanout-removed", "application-disconnected",
            "runner-stopped", "runner-retired", "runner-disconnected",
        ] {
            #expect(DoryVMDisplayPresentationDisposition.isExpectedRetirement(detail))
        }
        for detail in [
            "relay-saturated", "presentation-rejected", "frame-encoding-failed",
            "renderer-generation-revoked-before-presentation",
        ] {
            #expect(!DoryVMDisplayPresentationDisposition.isExpectedRetirement(detail))
        }
    }

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
        struct PublishedFrame: Sendable {
            var frame: Data
            var pixels: Data
            var descriptorCount: Int
            var hasSharedTextureHandle: Bool
        }

        private let lock = NSLock()
        private var commands: [Data]
        private(set) var retireCount = 0
        private(set) var retireCPUFrameCount = 0
        private(set) var retireCPUResourceCount = 0
        private(set) var invalidateCount = 0
        var acceptsCPUFrameRetirement = true
        private var publishedCursors: [Data] = []
        private var publishedFrames: [PublishedFrame] = []
        private var frameReplies: [@Sendable (Bool, UInt64, String) -> Void] = []
        private var acknowledgedCommandSequences: [UInt64] = []
        private let commandAcknowledgement = DispatchSemaphore(value: 0)
        private let automaticallyReplyToFrames: Bool
        private let holdCommandReply: Bool
        private var heldCommand: (Data, @Sendable (Bool, Data, String) -> Void)?
        private let commandRequested = DispatchSemaphore(value: 0)

        init(commands: [Data] = [], automaticallyReplyToFrames: Bool = true,
             holdCommandReply: Bool = false) {
            self.commands = commands
            self.automaticallyReplyToFrames = automaticallyReplyToFrames
            self.holdCommandReply = holdCommandReply
        }

        func publishFrame(
            _ frame: Data,
            descriptors: [FileHandle],
            sharedTextureHandle: MTLSharedTextureHandle?,
            reply: @escaping @Sendable (Bool, UInt64, String) -> Void
        ) {
            let pixels = descriptors.first.flatMap { try? $0.readToEnd() } ?? Data()
            let shouldReply = lock.withLock {
                publishedFrames.append(PublishedFrame(
                    frame: frame,
                    pixels: pixels,
                    descriptorCount: descriptors.count,
                    hasSharedTextureHandle: sharedTextureHandle != nil
                ))
                if !automaticallyReplyToFrames { frameReplies.append(reply) }
                return automaticallyReplyToFrames
            }
            if shouldReply { reply(true, 1, "") }
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
                if holdCommandReply {
                    lock.withLock { heldCommand = (command, reply) }
                    commandRequested.signal()
                    return
                }
                reply(true, command, "")
            } else {
                reply(false, Data(), "no-command")
            }
        }

        func waitForHeldCommand() -> DispatchTimeoutResult {
            commandRequested.wait(timeout: .now() + 1)
        }

        func deliverHeldCommand() {
            let held = lock.withLock { () -> (Data, @Sendable (Bool, Data, String) -> Void)? in
                defer { heldCommand = nil }
                return heldCommand
            }
            if let held { held.1(true, held.0, "") }
        }

        func acknowledgeCommand(
            machineID: String,
            operationID: String,
            sequence: UInt64,
            applied: Bool,
            detail: String,
            reply: @escaping @Sendable (Bool, String) -> Void
        ) {
            if applied, detail.isEmpty {
                lock.withLock { acknowledgedCommandSequences.append(sequence) }
                commandAcknowledgement.signal()
                reply(true, "")
            } else {
                reply(false, "invalid-acknowledgement")
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

        func retireCPUFrames(
            machineID: String,
            operationID: String,
            reply: @escaping @Sendable (Bool, String) -> Void
        ) {
            let accepted = lock.withLock { () -> Bool in
                retireCPUFrameCount += 1
                return acceptsCPUFrameRetirement
            }
            reply(accepted, accepted ? "" : "retirement-denied")
        }

        func retireCPUResource(
            machineID: String,
            operationID: String,
            resourceID: UInt32,
            throughGeneration: UInt64,
            reply: @escaping @Sendable (Bool, String) -> Void
        ) {
            let accepted = lock.withLock { () -> Bool in
                retireCPUResourceCount += 1
                return acceptsCPUFrameRetirement
            }
            reply(accepted, accepted ? "" : "retirement-denied")
        }

        func invalidate() {
            lock.withLock { invalidateCount += 1 }
        }

        var lifecycleCounts: (retire: Int, invalidate: Int) {
            lock.withLock { (retireCount, invalidateCount) }
        }


        var cursors: [Data] { lock.withLock { publishedCursors } }
        var frames: [PublishedFrame] { lock.withLock { publishedFrames } }
        var commandSequences: [UInt64] { lock.withLock { acknowledgedCommandSequences } }

        func completeNextFrame(presented: Bool = true) {
            let reply = lock.withLock { frameReplies.isEmpty ? nil : frameReplies.removeFirst() }
            reply?(presented, presented ? 1 : 0, presented ? "" : "rejected")
        }

        func waitForCommandAcknowledgement() -> DispatchTimeoutResult {
            commandAcknowledgement.wait(timeout: .now() + 1)
        }
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
        let graphicsRestarts = Recorder<Int>()
        let handler = DoryVMDisplayRunnerCommandHandler(
            input: {
                inputs.append(($0, $1))
                return true
            },
            resize: { resizes.append(($0, $1, $2, $3, $4)); return true },
            topology: { topologies.append($0); return true },
            restartGraphics: { graphicsRestarts.append(1); return true }
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
        handler.apply(try .restartGraphics(
            machineID: "ubuntu",
            operationID: operationID,
            sequence: 4
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
        #expect(graphicsRestarts.snapshot == [1])
    }

    @Test func resizeTargetRejectsCommandsBeforeAnActiveGPUIsInstalled() {
        let target = DoryVMDisplayRunnerResizeTarget()
        #expect(!target.apply(
            scanoutID: 0,
            width: 1_920,
            height: 1_080,
            physicalWidthMillimeters: 286,
            physicalHeightMillimeters: 161
        ))
        #expect(!target.apply(topology: [
            .init(
                width: 1_920,
                height: 1_080,
                physicalWidthMillimeters: 286,
                physicalHeightMillimeters: 161
            ),
        ]))
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
                    return true
                },
                resize: { _, _, _, _, _ in true }
            )
        )

        relay.start()
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        #expect(transport.waitForCommandAcknowledgement() == .success)
        relay.stop()
        relay.stop()

        #expect(inputs.snapshot == [[VirtioInputEvent(type: 1, code: 30, value: 1)]])
        #expect(transport.commandSequences == [1])
        #expect(transport.lifecycleCounts.retire == 1)
        #expect(transport.lifecycleCounts.invalidate == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func stoppedRelayRejectsHeldInputAndFocusReplies(isFocus: Bool, brokerDisconnected: Bool) throws {
        let operationID = UUID()
        let command = try isFocus
            ? DoryVMDisplayCommand.focus(machineID: "fedora", operationID: operationID,
                                         sequence: 1, leaseID: UUID(), active: true)
            : DoryVMDisplayCommand.input(machineID: "fedora", operationID: operationID,
                                         sequence: 1, endpoint: .keyboard,
                                         events: [.init(type: 1, code: 30, value: 1)])
        let transport = FakeTransport(commands: [try DoryVMDisplayCommandCodec.encode(command)],
                                      holdCommandReply: true)
        let effects = Recorder<String>()
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "fedora", operationID: operationID, transport: transport,
            commandHandler: .init(input: { _, _ in effects.append("input"); return true },
                                  resize: { _, _, _, _, _ in true },
                                  focus: { _, _, _ in effects.append("focus"); return true },
                                  revokeFocus: { effects.append("revoke") },
                                  releaseInput: { effects.append("release-input") })
        )
        relay.start()
        #expect(transport.waitForHeldCommand() == .success)
        if brokerDisconnected { relay.transportInvalidated() } else { relay.stop() }
        transport.deliverHeldCommand()
        relay.stop()
        relay.transportInvalidated()
        #expect(effects.snapshot == ["revoke", "release-input"])
        #expect(transport.commandSequences.isEmpty)
    }

    @Test(arguments: [false, true])
    func disconnectRequestsDurableReleaseEvenWhenInputAdmissionReportedFalse(applied: Bool) throws {
        let operationID = UUID()
        let command = try DoryVMDisplayCommand.input(
            machineID: "fedora", operationID: operationID, sequence: 1,
            endpoint: .keyboard, events: [.init(type: 1, code: 30, value: 1)]
        )
        let transport = FakeTransport(commands: [try DoryVMDisplayCommandCodec.encode(command)])
        let effects = Recorder<String>()
        let delivered = DispatchSemaphore(value: 0)
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "fedora", operationID: operationID, transport: transport,
            commandHandler: .init(
                input: { _, _ in effects.append("possible-press"); delivered.signal(); return applied },
                resize: { _, _, _, _, _ in true },
                revokeFocus: { effects.append("revoke-focus") },
                releaseInput: { effects.append("durable-release") }
            )
        )
        relay.start()
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        relay.transportInvalidated()
        relay.transportInvalidated()
        relay.stop()
        #expect(effects.snapshot == ["possible-press", "revoke-focus", "durable-release"])
    }

    @Test func relayPublishesCopiedCursorAndExplicitHideForEveryScanout() throws {
        let operationID = UUID()
        let transport = FakeTransport()
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "ubuntu",
            operationID: operationID,
            transport: transport,
            commandHandler: .init(input: { _, _ in true }, resize: { _, _, _, _, _ in true })
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
        relay.publishHiddenCursor(scanoutID: 1)

        let cursors = try transport.cursors.map(DoryVMDisplayCursorCodec.decode)
        #expect(cursors.count == 4)
        #expect(cursors[0].scanoutID == 1)
        #expect(cursors[0].visible)
        #expect(cursors[0].bytes == Data(repeating: 0xA5, count: 16))
        #expect(cursors[1].scanoutID == 0 && !cursors[1].visible)
        #expect(cursors[2].scanoutID == 1 && !cursors[2].visible)
        #expect(cursors[3].scanoutID == 1 && !cursors[3].visible)
        #expect(cursors.map(\.sequence) == [1, 2, 3, 4])
        relay.stop()
    }

    @Test func relayPublishesAccumulatedCPUFrameWithoutRendererReadiness() throws {
        let transport = FakeTransport()
        let rendererCompletions = Recorder<UInt64>()
        let rendererFailures = Recorder<UInt64>()
        let cpuCompletions = Recorder<DoryVMDisplayCPUFrameCompletion>()
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "ubuntu",
            operationID: UUID(),
            transport: transport,
            commandHandler: .init(input: { _, _ in true }, resize: { _, _, _, _, _ in true }),
            onPresentationCompleted: { generation, _ in
                rendererCompletions.append(generation)
            },
            onPresentationFailed: { generation, _ in rendererFailures.append(generation) },
            onCPUPresentationCompleted: { cpuCompletions.append($0) }
        )

        relay.publish(VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 7,
            resourceGeneration: 2,
            format: 1,
            width: 2,
            height: 2,
            stride: 4,
            dirtyRect: .init(x: 0, y: 0, width: 1, height: 1),
            bytes: Data([1, 2, 3, 4])
        ))
        relay.publish(VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 7,
            resourceGeneration: 2,
            format: 1,
            width: 2,
            height: 2,
            stride: 4,
            dirtyRect: .init(x: 1, y: 1, width: 1, height: 1),
            bytes: Data([5, 6, 7, 8])
        ))

        let published = transport.frames
        #expect(published.count == 2)
        let frame = try DoryVMDisplayFrameCodec.decode(published[1].frame)
        #expect(frame.transport == .cpuCopy)
        #expect(published[1].descriptorCount == 1)
        #expect(!published[1].hasSharedTextureHandle)
        #expect(published[1].pixels == Data([
            1, 2, 3, 4, 0, 0, 0, 0,
            0, 0, 0, 0, 5, 6, 7, 8,
        ]))
        #expect(rendererCompletions.snapshot.isEmpty)
        #expect(rendererFailures.snapshot.isEmpty)
        #expect(cpuCompletions.snapshot.map(\.scanoutID) == [0, 0])
        #expect(cpuCompletions.snapshot.map(\.resourceID) == [7, 7])
        #expect(cpuCompletions.snapshot.map(\.resourceGeneration) == [2, 2])
        let everyCPUFrameContainedVisibleContent = cpuCompletions.snapshot.allSatisfy {
            $0.visibleContent
        }
        #expect(everyCPUFrameContainedVisibleContent)
        relay.stop()
    }

    @Test func relayDoesNotPrepareAnotherCPUFrameWhileOneIsInFlight() throws {
        let transport = FakeTransport(automaticallyReplyToFrames: false)
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "ubuntu",
            operationID: UUID(),
            transport: transport,
            commandHandler: .init(input: { _, _ in true }, resize: { _, _, _, _, _ in true })
        )
        let frame = VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 7,
            resourceGeneration: 2,
            format: 1,
            width: 2,
            height: 2,
            stride: 8,
            dirtyRect: .init(x: 0, y: 0, width: 2, height: 2),
            bytes: Data(repeating: 0xA5, count: 16)
        )

        relay.publish(frame)
        #expect(relay.canPublishCPUFrame(scanoutID: 0))
        #expect(relay.canPublishCPUFrame(scanoutID: 0))
        var refreshedFrame = frame
        refreshedFrame.bytes = Data(repeating: 0x5A, count: 16)
        relay.publish(refreshedFrame)
        #expect(relay.canPublishCPUFrame(scanoutID: 0))
        refreshedFrame.bytes = Data(repeating: 0x3C, count: 16)
        relay.publish(refreshedFrame)
        #expect(transport.frames.count == 1)

        transport.completeNextFrame()
        #expect(transport.frames.count == 2)
        #expect(transport.frames[1].pixels == Data(repeating: 0x3C, count: 16))
        transport.completeNextFrame()
        #expect(transport.frames.count == 2)
        relay.stop()
    }

    @Test func deferredCPURefreshRequestsOneLatestCopyAfterReceipt() {
        let transport = FakeTransport(automaticallyReplyToFrames: false)
        let requests = Recorder<UInt32>()
        let requested = DispatchSemaphore(value: 0)
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "ubuntu",
            operationID: UUID(),
            transport: transport,
            commandHandler: .init(input: { _, _ in true }, resize: { _, _, _, _, _ in true }),
            onDeferredCPUFrameRefresh: { scanoutID in
                requests.append(scanoutID)
                requested.signal()
            }
        )
        let frame = VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 7,
            resourceGeneration: 2,
            format: 1,
            width: 2,
            height: 2,
            stride: 8,
            dirtyRect: .init(x: 0, y: 0, width: 2, height: 2),
            bytes: Data(repeating: 0x11, count: 16)
        )
        relay.publish(frame)
        #expect(!relay.canPublishCPUFrame(scanoutID: 0))
        #expect(!relay.canPublishCPUFrame(scanoutID: 0))
        #expect(transport.frames.count == 1)
        transport.completeNextFrame()
        #expect(requested.wait(timeout: .now() + 1) == .success)
        #expect(requests.snapshot == [0])
        var latest = frame
        latest.bytes = Data(repeating: 0x33, count: 16)
        relay.publish(latest)
        #expect(transport.frames.count == 2)
        #expect(transport.frames[1].pixels == Data(repeating: 0x33, count: 16))
        transport.completeNextFrame()
        #expect(transport.frames.count == 2)
        relay.stop()
    }

    @Test func resetRetiresOldCPUFrameAndDoesNotReplayItsDeferredRefresh() throws {
        let transport = FakeTransport(automaticallyReplyToFrames: false)
        let completions = Recorder<DoryVMDisplayCPUFrameCompletion>()
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "ubuntu",
            operationID: UUID(),
            transport: transport,
            commandHandler: .init(input: { _, _ in true }, resize: { _, _, _, _, _ in true }),
            onCPUPresentationCompleted: { completions.append($0) }
        )
        func frame(generation: UInt64, pixel: UInt8) -> VirtioGPUScanoutFrame {
            VirtioGPUScanoutFrame(
                scanoutID: 0,
                resourceID: 7,
                resourceGeneration: generation,
                format: 1,
                width: 2,
                height: 2,
                stride: 8,
                dirtyRect: .init(x: 0, y: 0, width: 2, height: 2),
                bytes: Data(repeating: pixel, count: 16)
            )
        }

        relay.publish(frame(generation: 2, pixel: 0x11))
        relay.publish(frame(generation: 2, pixel: 0x22))
        #expect(transport.frames.count == 1)
        #expect(relay.resetCPUFrames())
        #expect(transport.retireCPUFrameCount == 1)
        relay.publish(frame(generation: 3, pixel: 0x33))
        #expect(transport.frames.count == 2)
        #expect(transport.frames[1].pixels == Data(repeating: 0x33, count: 16))

        transport.completeNextFrame()
        #expect(transport.frames.count == 2)
        #expect(completions.snapshot.isEmpty)
        transport.completeNextFrame()
        #expect(completions.snapshot.map(\.resourceGeneration) == [3])
        relay.stop()
    }

    @Test func resetFailsClosedWhenBrokerCannotRetireOldCPUFrames() throws {
        let transport = FakeTransport(automaticallyReplyToFrames: false)
        transport.acceptsCPUFrameRetirement = false
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "ubuntu",
            operationID: UUID(),
            transport: transport,
            commandHandler: .init(input: { _, _ in true }, resize: { _, _, _, _, _ in true })
        )
        #expect(!relay.resetCPUFrames())
        #expect(transport.retireCPUFrameCount == 1)
        relay.stop()
    }

    @Test func resourceRetirementDropsDelayedCPUFramesWithoutClearingOtherResources() throws {
        let transport = FakeTransport(automaticallyReplyToFrames: false)
        let completions = Recorder<DoryVMDisplayCPUFrameCompletion>()
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "ubuntu",
            operationID: UUID(),
            transport: transport,
            commandHandler: .init(input: { _, _ in true }, resize: { _, _, _, _, _ in true }),
            onCPUPresentationCompleted: { completions.append($0) }
        )
        func frame(resourceID: UInt32, generation: UInt64) -> VirtioGPUScanoutFrame {
            VirtioGPUScanoutFrame(
                scanoutID: 0,
                resourceID: resourceID,
                resourceGeneration: generation,
                format: 1,
                width: 2,
                height: 2,
                stride: 8,
                dirtyRect: .init(x: 0, y: 0, width: 2, height: 2),
                bytes: Data(repeating: 0xA5, count: 16)
            )
        }
        relay.publish(frame(resourceID: 7, generation: 2))
        #expect(transport.frames.count == 1)
        #expect(relay.retireCPUResource(resourceID: 7, throughGeneration: 2))
        #expect(transport.retireCPUResourceCount == 1)
        relay.publish(frame(resourceID: 7, generation: 2))
        #expect(transport.frames.count == 1)
        relay.publish(frame(resourceID: 8, generation: 1))
        #expect(transport.frames.count == 2)
        transport.completeNextFrame()
        #expect(completions.snapshot.isEmpty)
        transport.completeNextFrame()
        #expect(completions.snapshot.map(\.resourceID) == [8])
        relay.stop()
    }

    @Test func copiedSurfacesRespectAggregateBudgetAndRetirementReleasesIt() {
        let transport = FakeTransport()
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "ubuntu",
            operationID: UUID(),
            transport: transport,
            commandHandler: .init(input: { _, _ in true }, resize: { _, _, _, _, _ in true }),
            maximumCPUSurfaceBytes: 32
        )
        func frame(scanoutID: UInt32, resourceID: UInt32) -> VirtioGPUScanoutFrame {
            VirtioGPUScanoutFrame(
                scanoutID: scanoutID,
                resourceID: resourceID,
                resourceGeneration: 1,
                format: 1,
                width: 2,
                height: 2,
                stride: 8,
                dirtyRect: .init(x: 0, y: 0, width: 2, height: 2),
                bytes: Data(repeating: 0xA5, count: 16)
            )
        }
        relay.publish(frame(scanoutID: 0, resourceID: 7))
        relay.publish(frame(scanoutID: 1, resourceID: 8))
        relay.publish(frame(scanoutID: 2, resourceID: 9))
        #expect(transport.frames.count == 2)
        #expect(relay.retireCPUResource(resourceID: 7, throughGeneration: 1))
        relay.publish(frame(scanoutID: 2, resourceID: 9))
        #expect(transport.frames.count == 3)
        relay.stop()
    }

    @Test func copiedSurfaceRejectsOverflowingGuestGeometryWithoutPublishing() {
        let transport = FakeTransport()
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "ubuntu",
            operationID: UUID(),
            transport: transport,
            commandHandler: .init(input: { _, _ in true }, resize: { _, _, _, _, _ in true })
        )
        relay.publish(VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 7,
            resourceGeneration: 1,
            format: 1,
            width: .max,
            height: .max,
            stride: 4,
            dirtyRect: .init(x: 0, y: 0, width: 1, height: 1),
            bytes: Data(repeating: 0xA5, count: 4)
        ))
        #expect(transport.frames.isEmpty)
        relay.stop()
    }

    @Test func rejectedFrameCannotClearAnotherFrameInFlight() {
        let transport = FakeTransport(automaticallyReplyToFrames: false)
        let relay = DoryVMDisplayRunnerRelay(
            machineID: "ubuntu",
            operationID: UUID(),
            transport: transport,
            commandHandler: .init(input: { _, _ in true }, resize: { _, _, _, _, _ in true })
        )
        func frame(resourceID: UInt32, pixel: UInt8) -> VirtioGPUScanoutFrame {
            VirtioGPUScanoutFrame(
                scanoutID: 0,
                resourceID: resourceID,
                resourceGeneration: 1,
                format: 1,
                width: 2,
                height: 2,
                stride: 8,
                dirtyRect: .init(x: 0, y: 0, width: 2, height: 2),
                bytes: Data(repeating: pixel, count: 16)
            )
        }
        relay.publish(frame(resourceID: 7, pixel: 0x11))
        relay.publish(frame(resourceID: 0, pixel: 0x22))
        relay.publish(frame(resourceID: 7, pixel: 0x33))
        #expect(transport.frames.count == 1)
        transport.completeNextFrame()
        #expect(transport.frames.count == 2)
        #expect(transport.frames[1].pixels == Data(repeating: 0x33, count: 16))
        transport.completeNextFrame()
        relay.stop()
    }
}
