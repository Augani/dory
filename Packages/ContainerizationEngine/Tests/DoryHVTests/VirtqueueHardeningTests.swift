import Foundation
import Testing
@testable import DoryHV

@Suite struct VirtqueueHardeningTests {
    private let base: UInt64 = 0x8000_0000
    private let descriptorTable: UInt64 = 0x8000_1000
    private let availRing: UInt64 = 0x8000_4000
    private let usedRing: UInt64 = 0x8000_6000
    private let dataA: UInt64 = 0x8000_8000
    private let dataB: UInt64 = 0x8000_9000
    private let indirectTableA: UInt64 = 0x8000_A000
    private let indirectTableB: UInt64 = 0x8000_B000

    private final class RetainedChainBox: @unchecked Sendable {
        let chain: VirtqueueChain

        init(_ chain: VirtqueueChain) {
            self.chain = chain
        }
    }

    private func makeMemory() throws -> GuestMemory {
        try GuestMemory(guestBase: base, size: 64 * HostPage.size)
    }

    private func makeReadyQueue(
        memory: GuestMemory,
        size: UInt64 = 8,
        limits: VirtqueueLimits = .hardenedDefault
    ) throws -> Virtqueue {
        let queue = Virtqueue(memory: memory, limits: limits)
        guard queue.configure(
            untrustedSize: size,
            descriptorTable: descriptorTable,
            availRing: availRing,
            usedRing: usedRing
        ), queue.setReady(true) else {
            throw VMError.unexpectedExit("test queue configuration was rejected")
        }
        return queue
    }

    private func writeDescriptor(
        _ memory: GuestMemory,
        table: UInt64,
        index: UInt64,
        address: UInt64,
        length: UInt32,
        flags: UInt16,
        next: UInt16 = 0
    ) throws {
        let descriptor = table + index * 16
        try memory.write(address, at: descriptor)
        try memory.write(length, at: descriptor + 8)
        try memory.write(flags, at: descriptor + 12)
        try memory.write(next, at: descriptor + 14)
    }

    private func publish(_ memory: GuestMemory, head: UInt16 = 0, index: UInt16 = 1) throws {
        try memory.write(UInt16(0), at: availRing)
        try memory.write(head, at: availRing + 4)
        try memory.write(index, at: availRing + 2)
    }

    @Test func queueConfigurationRejectsInvalidSizesAndAddressOverflow() throws {
        let memory = try makeMemory()
        let queue = Virtqueue(memory: memory)

        for size: UInt64 in [0, 3, Virtqueue.maximumSize + 1, UInt64.max] {
            #expect(!queue.configure(
                untrustedSize: size,
                descriptorTable: descriptorTable,
                availRing: availRing,
                usedRing: usedRing
            ))
            #expect(!queue.setReady(true))
            #expect(!queue.ready)
        }

        #expect(!queue.configure(
            untrustedSize: 8,
            descriptorTable: UInt64.max - 15,
            availRing: availRing,
            usedRing: usedRing
        ))
        #expect(!queue.configure(
            untrustedSize: 8,
            descriptorTable: descriptorTable,
            availRing: UInt64.max - 1,
            usedRing: usedRing
        ))
        #expect(!queue.configure(
            untrustedSize: 8,
            descriptorTable: descriptorTable,
            availRing: availRing,
            usedRing: UInt64.max - 3
        ))
    }

    @Test func queueConfigurationAcceptsEverySupportedPowerOfTwo() throws {
        let memory = try makeMemory()
        let queue = Virtqueue(memory: memory)

        for size: UInt64 in [1, 2, 4, 8, 16, 32, 64, 128, Virtqueue.maximumSize] {
            #expect(queue.configure(
                untrustedSize: size,
                descriptorTable: descriptorTable,
                availRing: availRing,
                usedRing: usedRing
            ))
            #expect(queue.setReady(true))
            #expect(queue.size == UInt16(size))
            queue.reset()
        }
    }

    @Test func availableIndexCannotOverrunTheRing() throws {
        let memory = try makeMemory()
        let queue = try makeReadyQueue(memory: memory)
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 0,
            address: dataA,
            length: 4,
            flags: 0
        )
        try publish(memory, index: 9)

        #expect(!queue.hasPending)
        #expect(throws: (any Error).self) { _ = try queue.pop() }
    }

    @Test func oneIndirectTableRemainsSupported() throws {
        let memory = try makeMemory()
        let queue = try makeReadyQueue(memory: memory)
        queue.setNegotiatedFeatures(VirtqueueFeature.indirectDescriptors)
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 0,
            address: indirectTableA,
            length: 32,
            flags: 4
        )
        try writeDescriptor(
            memory,
            table: indirectTableA,
            index: 0,
            address: dataA,
            length: 4,
            flags: 1,
            next: 1
        )
        try writeDescriptor(
            memory,
            table: indirectTableA,
            index: 1,
            address: dataB,
            length: 8,
            flags: 2
        )
        try memory.write([0x11, 0x22, 0x33, 0x44], at: dataA)
        try publish(memory)

        let chain = try #require(try queue.pop())
        #expect(chain.readBytes() == [0x11, 0x22, 0x33, 0x44])
        #expect(chain.withLeaseHeld { $0.writableSegments.map(\.length) } == [8])
    }

    @Test func nestedIndirectTablesAreRejected() throws {
        let memory = try makeMemory()
        let queue = try makeReadyQueue(memory: memory)
        queue.setNegotiatedFeatures(VirtqueueFeature.indirectDescriptors)
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 0,
            address: indirectTableA,
            length: 16,
            flags: 4
        )
        try writeDescriptor(
            memory,
            table: indirectTableA,
            index: 0,
            address: indirectTableB,
            length: 16,
            flags: 4
        )
        try writeDescriptor(
            memory,
            table: indirectTableB,
            index: 0,
            address: dataA,
            length: 4,
            flags: 0
        )
        try publish(memory)

        #expect(throws: (any Error).self) { _ = try queue.pop() }
    }

    @Test func malformedIndirectLayoutsAndOverflowingAddressesAreRejected() throws {
        do {
            let memory = try makeMemory()
            let queue = try makeReadyQueue(memory: memory)
            queue.setNegotiatedFeatures(VirtqueueFeature.indirectDescriptors)
            try writeDescriptor(
                memory,
                table: descriptorTable,
                index: 0,
                address: UInt64.max - 7,
                length: 16,
                flags: 4
            )
            try publish(memory)
            #expect(throws: (any Error).self) { _ = try queue.pop() }
        }

        do {
            let memory = try makeMemory()
            let queue = try makeReadyQueue(memory: memory)
            queue.setNegotiatedFeatures(VirtqueueFeature.indirectDescriptors)
            try writeDescriptor(
                memory,
                table: descriptorTable,
                index: 0,
                address: indirectTableA,
                length: UInt32.max,
                flags: 4
            )
            try publish(memory)
            #expect(throws: (any Error).self) { _ = try queue.pop() }
        }
    }

    @Test func descriptorCountLimitIsEnforced() throws {
        let memory = try makeMemory()
        let limits = VirtqueueLimits(
            maximumDescriptorCount: 1,
            maximumSegmentCount: 8,
            maximumSegmentBytes: 64,
            maximumTotalBytes: 64
        )
        let queue = try makeReadyQueue(memory: memory, limits: limits)
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 0,
            address: dataA,
            length: 4,
            flags: 1,
            next: 1
        )
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 1,
            address: dataB,
            length: 4,
            flags: 0
        )
        try publish(memory)

        #expect(throws: (any Error).self) { _ = try queue.pop() }
    }

    @Test func segmentCountLimitIsEnforced() throws {
        let memory = try makeMemory()
        let limits = VirtqueueLimits(
            maximumDescriptorCount: 8,
            maximumSegmentCount: 1,
            maximumSegmentBytes: 64,
            maximumTotalBytes: 64
        )
        let queue = try makeReadyQueue(memory: memory, limits: limits)
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 0,
            address: dataA,
            length: 4,
            flags: 1,
            next: 1
        )
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 1,
            address: dataB,
            length: 4,
            flags: 0
        )
        try publish(memory)

        #expect(throws: (any Error).self) { _ = try queue.pop() }
    }

    @Test func individualAndAggregateByteLimitsAreEnforced() throws {
        do {
            let memory = try makeMemory()
            let limits = VirtqueueLimits(
                maximumDescriptorCount: 8,
                maximumSegmentCount: 8,
                maximumSegmentBytes: 3,
                maximumTotalBytes: 64
            )
            let queue = try makeReadyQueue(memory: memory, limits: limits)
            try writeDescriptor(
                memory,
                table: descriptorTable,
                index: 0,
                address: dataA,
                length: 4,
                flags: 0
            )
            try publish(memory)
            #expect(throws: (any Error).self) { _ = try queue.pop() }
        }

        do {
            let memory = try makeMemory()
            let limits = VirtqueueLimits(
                maximumDescriptorCount: 8,
                maximumSegmentCount: 8,
                maximumSegmentBytes: 8,
                maximumTotalBytes: 7
            )
            let queue = try makeReadyQueue(memory: memory, limits: limits)
            try writeDescriptor(
                memory,
                table: descriptorTable,
                index: 0,
                address: dataA,
                length: 4,
                flags: 1,
                next: 1
            )
            try writeDescriptor(
                memory,
                table: descriptorTable,
                index: 1,
                address: dataB,
                length: 4,
                flags: 0
            )
            try publish(memory)
            #expect(throws: (any Error).self) { _ = try queue.pop() }
        }
    }

    @Test func guestSegmentAddressAndUsedLengthNeverTrapConversions() throws {
        do {
            let memory = try makeMemory()
            let limits = VirtqueueLimits(maximumSegmentBytes: UInt64(UInt32.max))
            let queue = try makeReadyQueue(memory: memory, limits: limits)
            try writeDescriptor(
                memory,
                table: descriptorTable,
                index: 0,
                address: UInt64.max - 3,
                length: 8,
                flags: 0
            )
            try publish(memory)
            #expect(throws: (any Error).self) { _ = try queue.pop() }
        }

        do {
            let memory = try makeMemory()
            let queue = try makeReadyQueue(memory: memory)
            try writeDescriptor(
                memory,
                table: descriptorTable,
                index: 0,
                address: dataA,
                length: 4,
                flags: 0
            )
            try publish(memory)
            let chain = try #require(try queue.pop())
            #expect(throws: (any Error).self) { _ = try queue.push(chain, written: -1) }
            #expect(throws: (any Error).self) {
                _ = try queue.push(chain, written: Int(UInt32.max) + 1)
            }
        }
    }

    @Test func indirectDescriptorRequiresNegotiatedRingFeature() throws {
        let memory = try makeMemory()
        let queue = try makeReadyQueue(memory: memory)
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 0,
            address: indirectTableA,
            length: 16,
            flags: 4
        )
        try writeDescriptor(
            memory,
            table: indirectTableA,
            index: 0,
            address: dataA,
            length: 4,
            flags: 0
        )
        try publish(memory)

        #expect(queue.negotiatedFeatures & VirtqueueFeature.indirectDescriptors == 0)
        #expect(throws: (any Error).self) { _ = try queue.pop() }
    }

    @Test func retainedChainLeaseIsRevokedByQueueReadyChangeAndReconfigure() throws {
        let memory = try makeMemory()
        let queue = try makeReadyQueue(memory: memory)
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 0,
            address: dataA,
            length: 4,
            flags: 1,
            next: 1
        )
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 1,
            address: dataB,
            length: 8,
            flags: 2
        )
        try memory.write([1, 2, 3, 4], at: dataA)
        try publish(memory)

        let chain = try #require(try queue.pop())
        let originalLease = chain.lease
        #expect(chain.isLeaseValid)
        #expect(queue.isLeaseValid(chain))
        #expect(chain.readBytes() == [1, 2, 3, 4])

        queue.setReady(false)

        #expect(!chain.isLeaseValid)
        #expect(!queue.isLeaseValid(originalLease))
        // Raw pointer views exist only inside withLeaseHeld. Public shape queries, checked I/O, and
        // completion all fail closed once the queue revokes the lease.
        #expect(chain.readableSegmentCount == 0)
        #expect(chain.writableSegmentCount == 0)
        #expect(chain.withLeaseHeld { $0.segments.count } == nil)
        #expect(chain.readBytes().isEmpty)
        #expect(chain.writeBytes([9, 9, 9]) == 0)
        #expect(try queue.push(chain, written: 0) == false)

        #expect(queue.configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availRing,
            usedRing: usedRing
        ))
        #expect(queue.setReady(true))
        let replacement = try #require(try queue.pop())
        #expect(replacement.isLeaseValid)
        #expect(replacement.lease != originalLease)
        #expect(try queue.push(chain, written: 4) == false)
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)

        #expect(queue.configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availRing,
            usedRing: usedRing
        ))
        #expect(!replacement.isLeaseValid)
        #expect(try queue.push(replacement, written: 0) == false)
    }

    @Test func chainLeaseCannotBeCompletedOnAnotherQueue() throws {
        let memory = try makeMemory()
        let source = try makeReadyQueue(memory: memory)
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 0,
            address: dataA,
            length: 4,
            flags: 0
        )
        try publish(memory)
        let chain = try #require(try source.pop())

        let other = Virtqueue(memory: memory)
        #expect(other.configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availRing,
            usedRing: usedRing
        ))
        #expect(other.setReady(true))

        #expect(!other.isLeaseValid(chain))
        #expect(try other.push(chain, written: 0) == false)
    }

    @Test func heldLeaseMakesResetWaitForDirectGuestBufferAccess() throws {
        let memory = try makeMemory()
        let queue = try makeReadyQueue(memory: memory)
        try writeDescriptor(
            memory,
            table: descriptorTable,
            index: 0,
            address: dataB,
            length: 8,
            flags: 2
        )
        try publish(memory)
        let chain = try #require(try queue.pop())
        let retained = RetainedChainBox(chain)
        let accessEntered = DispatchSemaphore(value: 0)
        let releaseAccess = DispatchSemaphore(value: 0)
        let accessFinished = DispatchSemaphore(value: 0)
        let resetStarted = DispatchSemaphore(value: 0)
        let resetFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = retained.chain.withLeaseHeld { access in
                accessEntered.signal()
                _ = releaseAccess.wait(timeout: .now() + .seconds(2))
                _ = access.writeBytes([1, 2, 3, 4])
            }
            accessFinished.signal()
        }
        defer { releaseAccess.signal() }
        #expect(accessEntered.wait(timeout: .now() + .seconds(1)) == .success)

        DispatchQueue.global().async {
            resetStarted.signal()
            queue.reset()
            resetFinished.signal()
        }
        #expect(resetStarted.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(resetFinished.wait(timeout: .now() + .milliseconds(50)) == .timedOut)

        releaseAccess.signal()
        #expect(accessFinished.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(resetFinished.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(try memory.readBytes(at: dataB, count: 4) == [1, 2, 3, 4])
        #expect(!chain.isLeaseValid)
        #expect(chain.withLeaseHeld { _ in true } == nil)
    }
}

@Suite struct VirtioMMIOQueueHardeningTests {
    private final class Backend: VirtioDeviceBackend {
        let deviceID: UInt32 = 1
        let deviceFeatures: UInt64 = 0
        let queueCount = 1
        let configSpace: [UInt8] = []
        var readyEvents = [Bool]()
        var deviceReadyCount = 0

        func handleKick(queue: Int, transport: VirtioMMIOTransport) {}

        func deviceReady(transport: VirtioMMIOTransport) {
            deviceReadyCount += 1
        }

        func queueStateChanged(queue: Int, ready: Bool, transport: VirtioMMIOTransport) {
            readyEvents.append(ready)
        }
    }

    @Test func transportRejectsInvalidQueueNumbersAndAcceptsAValidLayout() throws {
        let base = GuestLayout.ramBase
        let memory = try GuestMemory(guestBase: base, size: 64 * HostPage.size)
        let backend = Backend()
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}
        let descriptor = base + 0x1_000
        let available = base + 0x4_000
        let used = base + 0x6_000

        transport.write(offset: 0x030, value: 0, width: 4)
        for count: UInt64 in [0, 3, Virtqueue.maximumSize + 1, UInt64.max] {
            transport.write(offset: 0x038, value: count, width: 4)
            transport.write(offset: 0x044, value: 1, width: 4)
            #expect(transport.read(offset: 0x044, width: 4) == 0)
            #expect(backend.readyEvents.last == false)
        }

        func writeAddress(lowRegister: UInt64, _ address: UInt64) {
            transport.write(offset: lowRegister, value: address & 0xFFFF_FFFF, width: 4)
            transport.write(offset: lowRegister + 4, value: address >> 32, width: 4)
        }
        transport.write(offset: 0x038, value: 8, width: 4)
        writeAddress(lowRegister: 0x080, descriptor)
        writeAddress(lowRegister: 0x090, available)
        writeAddress(lowRegister: 0x0A0, used)
        transport.write(offset: 0x044, value: 1, width: 4)

        #expect(transport.read(offset: 0x034, width: 4) == Virtqueue.maximumSize)
        #expect(transport.read(offset: 0x044, width: 4) == 1)
        #expect(backend.readyEvents.last == true)
    }

    @Test func oversizedQueueSelectionAndNotificationAreIgnoredWithoutConversionTraps() throws {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 64 * HostPage.size)
        let backend = Backend()
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}

        transport.write(offset: 0x030, value: UInt64.max, width: 8)
        transport.write(offset: 0x038, value: 8, width: 4)
        transport.write(offset: 0x044, value: 1, width: 4)
        transport.write(offset: 0x050, value: UInt64.max, width: 8)

        #expect(backend.readyEvents.isEmpty)
        #expect(transport.statistics.queueNotifications == 0)
        #expect(transport.read(offset: 0x044, width: 4) == 0)
    }

    @Test func transportOffersAndPropagatesNegotiatedIndirectDescriptorFeature() throws {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 64 * HostPage.size)
        let backend = Backend()
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}

        #expect(
            transport.read(offset: 0x010, width: 4)
                & VirtqueueFeature.indirectDescriptors != 0
        )
        writeDriverFeatures(
            VirtqueueFeature.indirectDescriptors | VirtqueueFeature.version1,
            to: transport
        )
        transport.write(offset: 0x070, value: 0x0B, width: 4)

        #expect(
            transport.negotiatedFeatures
                == (VirtqueueFeature.indirectDescriptors | VirtqueueFeature.version1)
        )
        #expect(
            transport.queues[0].negotiatedFeatures
                == (VirtqueueFeature.indirectDescriptors | VirtqueueFeature.version1)
        )
        #expect(transport.read(offset: 0x070, width: 4) == 0x0B)
        #expect(backend.deviceReadyCount == 0)

        transport.write(offset: 0x070, value: 0x0F, width: 4)
        transport.write(offset: 0x070, value: 0x0F, width: 4)
        #expect(backend.deviceReadyCount == 1)

        let lease = transport.queues[0].currentLease
        transport.write(offset: 0x070, value: 0, width: 4)
        #expect(transport.queues[0].negotiatedFeatures == 0)
        #expect(!transport.queues[0].isLeaseValid(lease))
    }

    @Test func transportClearsFeaturesOKForUnsupportedOrLegacyFeatureSets() throws {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 64 * HostPage.size)
        let backend = Backend()
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}

        writeDriverFeatures(
            VirtqueueFeature.version1 | VirtqueueFeature.indirectDescriptors | (1 << 27),
            to: transport
        )
        transport.write(offset: 0x070, value: 0x0F, width: 4)
        #expect(transport.read(offset: 0x070, width: 4) == 0x03)
        #expect(transport.negotiatedFeatures == 0)
        #expect(transport.queues[0].negotiatedFeatures == 0)
        #expect(backend.deviceReadyCount == 0)

        transport.write(offset: 0x070, value: 0, width: 4)
        writeDriverFeatures(VirtqueueFeature.indirectDescriptors, to: transport)
        transport.write(offset: 0x070, value: 0x0F, width: 4)
        #expect(transport.read(offset: 0x070, width: 4) == 0x03)
        #expect(transport.negotiatedFeatures == 0)
        #expect(backend.deviceReadyCount == 0)
    }

    @Test func featureSelectorsExposeOnlyTwoMaskedWords() throws {
        let memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: 64 * HostPage.size)
        let backend = Backend()
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: backend,
            memory: memory
        ) {}

        transport.write(offset: 0x014, value: 0, width: 4)
        #expect(
            transport.read(offset: 0x010, width: 4)
                & VirtqueueFeature.indirectDescriptors != 0
        )
        transport.write(offset: 0x014, value: 1, width: 4)
        #expect(transport.read(offset: 0x010, width: 4) == 1)
        transport.write(offset: 0x014, value: 2, width: 4)
        #expect(transport.read(offset: 0x010, width: 4) == 0)
        transport.write(offset: 0x014, value: UInt64.max, width: 8)
        #expect(transport.read(offset: 0x010, width: 4) == 0)

        transport.write(offset: 0x024, value: 0, width: 4)
        transport.write(
            offset: 0x020,
            value: VirtqueueFeature.indirectDescriptors,
            width: 4
        )
        transport.write(offset: 0x024, value: 1, width: 4)
        transport.write(offset: 0x020, value: 0xFFFF_FFFF_0000_0001, width: 8)
        transport.write(offset: 0x024, value: 2, width: 4)
        transport.write(offset: 0x020, value: 0, width: 8)
        transport.write(offset: 0x070, value: 0x0B, width: 4)

        #expect(transport.read(offset: 0x070, width: 4) == 0x0B)
        #expect(
            transport.negotiatedFeatures
                == (VirtqueueFeature.indirectDescriptors | VirtqueueFeature.version1)
        )
    }

    private func writeDriverFeatures(
        _ features: UInt64,
        to transport: VirtioMMIOTransport
    ) {
        transport.write(offset: 0x024, value: 0, width: 4)
        transport.write(offset: 0x020, value: features & 0xFFFF_FFFF, width: 4)
        transport.write(offset: 0x024, value: 1, width: 4)
        transport.write(offset: 0x020, value: features >> 32, width: 4)
    }
}
