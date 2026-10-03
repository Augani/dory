import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized)
struct VirtioGPUBackingLifetimeTests {
    @Test func unrefRetainsBackingUntilDisplayAckAndRendererTeardown() throws {
        let gate = DispatchSemaphore(value: 0)
        let renderer = BackingLifetimeRenderer(unrefGate: gate)
        let releases = BackingLifetimeReleases()
        let fixture = try BackingLifetimeFixture(renderer: renderer, releases: releases)
        defer { gate.signal(); releases.acknowledgeAll() }
        try fixture.createAndAttach()
        #expect(fixture.releaseBacking() == .rejected)

        #expect(try fixture.submit(BackingLifetimeFixture.resourceRequest(0x0102)) == 0x1100)
        #expect(releases.values.count == 1)
        #expect(fixture.releaseBacking() == .rejected)
        releases.acknowledgeAll()
        #expect(renderer.unrefEntered.wait(timeout: .now() + 2) == .success)
        #expect(fixture.releaseBacking() == .rejected)

        gate.signal()
        #expect(backingLifetimeEventually { fixture.releaseBacking() == .reclaimed })
    }

    @Test func resetRetainsBackingThroughDisplayAckUnrefAndFinalResetBarrier() throws {
        let gate = DispatchSemaphore(value: 0)
        let renderer = BackingLifetimeRenderer(resetGate: gate)
        let releases = BackingLifetimeReleases()
        let fixture = try BackingLifetimeFixture(renderer: renderer, releases: releases)
        defer { gate.signal(); releases.acknowledgeAll() }
        try fixture.createAndAttach()

        let receipt = fixture.gpu.quiesce(reason: .deviceReset)
        #expect(receipt.outcome == nil)
        #expect(fixture.releaseBacking() == .rejected)
        releases.acknowledgeAll()
        #expect(renderer.resetEntered.wait(timeout: .now() + 2) == .success)
        #expect(fixture.releaseBacking() == .rejected)

        gate.signal()
        #expect(receipt.wait(timeout: 2) == .completed)
        #expect(fixture.releaseBacking() == .reclaimed)
    }

    @Test func failedUnrefQuarantinesBackingAfterAcknowledgement() throws {
        let renderer = BackingLifetimeRenderer(failure: .unref)
        let releases = BackingLifetimeReleases()
        let fixture = try BackingLifetimeFixture(renderer: renderer, releases: releases)
        defer { releases.acknowledgeAll() }
        try fixture.createAndAttach()
        #expect(try fixture.submit(BackingLifetimeFixture.resourceRequest(0x0102)) == 0x1100)
        releases.acknowledgeAll()
        #expect(backingLifetimeEventually {
            if case .failed = fixture.gpu.rendererLifecycleHealth { return true }
            return false
        })
        #expect(fixture.releaseBacking() == .rejected)

        let receipt = fixture.gpu.quiesce(reason: .shutdown)
        if let outcome = receipt.outcome, case .failed = outcome {} else {
            Issue.record("unknown renderer destruction was treated as successful teardown")
        }
        releases.acknowledgeAll()
        #expect(fixture.releaseBacking() == .rejected)
    }

    @Test func failedResetDoesNotReleaseBackingAfterSuccessfulUnref() throws {
        let renderer = BackingLifetimeRenderer(failure: .reset)
        let releases = BackingLifetimeReleases()
        let fixture = try BackingLifetimeFixture(renderer: renderer, releases: releases)
        defer { releases.acknowledgeAll() }
        try fixture.createAndAttach()
        let receipt = fixture.gpu.quiesce(reason: .deviceReset)
        releases.acknowledgeAll()
        let outcome = receipt.wait(timeout: 2)
        if let outcome, case .failed = outcome {} else {
            Issue.record("renderer reset without an epoch barrier was treated as successful")
        }
        #expect(fixture.releaseBacking() == .rejected)
    }

    @Test(arguments: [false, true])
    func unknownAttachOrCreateRetainsBackingEvenBeforeResourceCommit(blob: Bool) throws {
        let renderer = BackingLifetimeRenderer(failure: blob ? .createBlob : .attach)
        let releases = BackingLifetimeReleases()
        let fixture = try BackingLifetimeFixture(renderer: renderer, releases: releases)
        defer { releases.acknowledgeAll() }
        if !blob {
            #expect(try fixture.submit(BackingLifetimeFixture.create2DRequest()) == 0x1100)
        }
        let before = try fixture.usedIndex()
        _ = try fixture.submit(blob ? fixture.createBlobRequest() : fixture.attachRequest())
        #expect(try fixture.usedIndex() == before)
        #expect(fixture.releaseBacking() == .rejected)

        let receipt = fixture.gpu.quiesce(reason: .shutdown)
        if let outcome = receipt.outcome, case .failed = outcome {} else {
            Issue.record("unknown guest backing ownership was discarded during quiescence")
        }
        releases.acknowledgeAll()
        #expect(fixture.releaseBacking() == .rejected)
    }

    @Test func provenRejectedAttachDoesNotQuarantineUnpublishedBacking() throws {
        let renderer = BackingLifetimeRenderer(failure: .rejectedAttach)
        let releases = BackingLifetimeReleases()
        let fixture = try BackingLifetimeFixture(renderer: renderer, releases: releases)
        #expect(try fixture.submit(BackingLifetimeFixture.create2DRequest()) == 0x1100)
        #expect(try fixture.submit(fixture.attachRequest()) == 0x1205)
        #expect(fixture.releaseBacking() == .reclaimed)
    }

    @Test(arguments: [false, true])
    func rejectedOrUnknownReplacementPreservesPriorNon2DBacking(rejected: Bool) throws {
        let renderer = BackingLifetimeRenderer(failure: rejected ? .rejectedAttach : .attach)
        let releases = BackingLifetimeReleases()
        let fixture = try BackingLifetimeFixture(renderer: renderer, releases: releases)
        defer { releases.acknowledgeAll() }
        // Blob backing uses the non-2D resourceEntries owner, not the 2D resource's copy.
        #expect(try fixture.submit(fixture.createBlobRequest()) == 0x1100)
        #expect(fixture.releaseBacking() == .rejected)
        let replacementAddress = fixture.backingAddress + HostPage.size
        let before = try fixture.usedIndex()
        let response = try fixture.submit(fixture.attachRequest(address: replacementAddress))

        #expect(fixture.releaseBacking() == .rejected)
        let replacementResult = fixture.memory.releaseRange(
            guestAddress: replacementAddress, length: HostPage.size)
        if rejected {
            #expect(response == 0x1205)
            #expect(try fixture.usedIndex() == before + 1)
            #expect(replacementResult == .reclaimed)
        } else {
            #expect(try fixture.usedIndex() == before)
            #expect(replacementResult == .rejected)
            let receipt = fixture.gpu.quiesce(reason: .shutdown)
            if let outcome = receipt.outcome, case .failed = outcome {} else {
                Issue.record("unknown replacement was treated as proven backing teardown")
            }
            releases.acknowledgeAll()
            #expect(fixture.releaseBacking() == .rejected)
            #expect(fixture.memory.releaseRange(guestAddress: replacementAddress,
                length: HostPage.size) == .rejected)
        }
    }
}

private final class BackingLifetimeFixture {
    static let resourceID: UInt32 = 41
    let memory: GuestMemory
    let gpu: VirtioGPU
    let transport: VirtioMMIOTransport
    let backingAddress: UInt64
    private let descriptorTable: UInt64
    private let availableRing: UInt64
    private let usedRing: UInt64
    private let requestBuffer: UInt64
    private let responseBuffer: UInt64
    private var availableIndex: UInt16 = 0

    init(renderer: BackingLifetimeRenderer, releases: BackingLifetimeReleases) throws {
        let base: UInt64 = 0xEA00_0000
        memory = try GuestMemory(guestBase: base, size: 16 * HostPage.size,
            reclaimOperations: GuestMemoryReclaimOperations(
                unmap: { _, _ in true }, map: { _, _, _ in true },
                markReusable: { _, _ in true }, markInUse: { _, _ in true }
            ))
        descriptorTable = base + 0x100
        availableRing = base + HostPage.size
        usedRing = base + 2 * HostPage.size
        requestBuffer = base + 3 * HostPage.size
        responseBuffer = base + 4 * HostPage.size
        backingAddress = base + 6 * HostPage.size
        gpu = VirtioGPU(hostMemoryBase: base + 0x1_0000_0000, scanoutCount: 1,
            renderer: renderer, onScanoutResourceReleased: { releases.append($0) })
        transport = makeNegotiatedMMIOTestTransport(baseAddress: GuestLayout.virtioBase,
            backend: gpu, memory: memory, interrupt: {})
        transport.queues[0].configure(size: 8, descriptorTable: descriptorTable,
            availRing: availableRing, usedRing: usedRing)
        #expect(transport.queues[0].setReady(true))
    }

    func createAndAttach() throws {
        #expect(try submit(Self.create2DRequest()) == 0x1100)
        #expect(try submit(attachRequest()) == 0x1100)
    }

    func usedIndex() throws -> UInt16 { try memory.read(UInt16.self, at: usedRing + 2) }

    func releaseBacking() -> GuestMemoryReleaseResult {
        memory.releaseRange(guestAddress: backingAddress, length: HostPage.size)
    }

    func submit(_ request: [UInt8]) throws -> UInt32 {
        try writeDescriptor(index: 0, address: requestBuffer, length: UInt32(request.count), flags: 1, next: 1)
        try writeDescriptor(index: 1, address: responseBuffer, length: 512, flags: 2, next: 0)
        try memory.write(request, at: requestBuffer)
        try memory.write([UInt8](repeating: 0, count: 512), at: responseBuffer)
        try memory.write(UInt16(0), at: availableRing + 4 + UInt64(availableIndex % 8) * 2)
        availableIndex &+= 1
        try memory.write(availableIndex, at: availableRing + 2)
        gpu.handleKick(queue: 0, transport: transport)
        return try memory.read(UInt32.self, at: responseBuffer)
    }

    private func writeDescriptor(index: UInt64, address: UInt64, length: UInt32, flags: UInt16, next: UInt16) throws {
        let descriptor = descriptorTable + index * 16
        try memory.write(address, at: descriptor)
        try memory.write(length, at: descriptor + 8)
        try memory.write(flags, at: descriptor + 12)
        try memory.write(next, at: descriptor + 14)
    }

    private static func header(_ command: UInt32) -> [UInt8] {
        var request: [UInt8] = []
        request.appendLE(command)
        request.appendLE(UInt32(0))
        request.appendLE(UInt64(0))
        request.appendLE(UInt32(0))
        request.appendLE(UInt32(0))
        return request
    }

    static func create2DRequest() -> [UInt8] {
        var request = header(0x0101)
        request.appendLE(resourceID)
        request.appendLE(UInt32(1))
        request.appendLE(UInt32(2))
        request.appendLE(UInt32(2))
        return request
    }

    static func resourceRequest(_ command: UInt32) -> [UInt8] {
        var request = header(command)
        request.appendLE(resourceID)
        request.appendLE(UInt32(0))
        return request
    }

    func attachRequest(address: UInt64? = nil) -> [UInt8] {
        var request = Self.header(0x0106)
        request.appendLE(Self.resourceID)
        request.appendLE(UInt32(1))
        request.appendLE(address ?? backingAddress)
        request.appendLE(UInt32(HostPage.size))
        request.appendLE(UInt32(0))
        return request
    }

    func createBlobRequest() -> [UInt8] {
        var request = Self.header(0x010C)
        request.appendLE(Self.resourceID)
        request.appendLE(UInt32(1))
        request.appendLE(UInt32(0))
        request.appendLE(UInt32(1))
        request.appendLE(UInt64(101))
        request.appendLE(HostPage.size)
        request.appendLE(backingAddress)
        request.appendLE(UInt32(HostPage.size))
        request.appendLE(UInt32(0))
        return request
    }
}

private final class BackingLifetimeReleases: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VirtioGPUScanoutResourceRelease] = []

    var values: [VirtioGPUScanoutResourceRelease] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ release: VirtioGPUScanoutResourceRelease) {
        lock.lock()
        stored.append(release)
        lock.unlock()
    }

    func acknowledgeAll() { for release in values { release.acknowledgeAll() } }
}

private func backingLifetimeEventually(_ predicate: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: 2)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return predicate()
}

private final class BackingLifetimeRenderer: VirtioGPURenderer, @unchecked Sendable {
    enum Failure { case none, attach, rejectedAttach, createBlob, unref, reset }
    let capsets: [VirtioGPUCapset] = []
    let unrefEntered = DispatchSemaphore(value: 0)
    let resetEntered = DispatchSemaphore(value: 0)
    private let failure: Failure
    private let unrefGate: DispatchSemaphore?
    private let resetGate: DispatchSemaphore?
    var onRuntimeFailure: ((VirtioGPURendererRuntimeFailure) -> Void)?
    var onFenceSignaled: ((UInt32, UInt32, UInt64) -> Void)?

    init(failure: Failure = .none, unrefGate: DispatchSemaphore? = nil, resetGate: DispatchSemaphore? = nil) {
        self.failure = failure
        self.unrefGate = unrefGate
        self.resetGate = resetGate
    }

    func createContext(id: UInt32, flags: UInt32, name: String) throws {}
    func destroyContext(id: UInt32) throws {}
    func attachResource(contextID: UInt32, resourceID: UInt32) throws {}
    func detachResource(contextID: UInt32, resourceID: UInt32) throws {}
    func submit3D(contextID: UInt32, command: [UInt8]) throws {}
    func createResource3D(_ resource: VirtioGPUResourceCreate3D, entries: [VirtioGPUMemoryEntry]) throws {}
    func createBlob(resourceID: UInt32, contextID: UInt32, blobMemory: UInt32, blobFlags: UInt32,
                    blobID: UInt64, size: UInt64, entries: [VirtioGPUMemoryEntry]) throws {
        if failure == .createBlob { throw VMError.invalidConfiguration("unknown create-blob outcome") }
    }
    func attachBacking(resourceID: UInt32, entries: [VirtioGPUMemoryEntry]) throws {
        // Deliberately never retain entries here: only the device can protect its guest mapping.
        if failure == .attach { throw VMError.invalidConfiguration("unknown attach outcome") }
        if failure == .rejectedAttach { throw VirtioGPURendererCommandRejected("no backing admitted") }
    }
    func detachBacking(resourceID: UInt32) throws {}
    func unrefResource(resourceID: UInt32) throws {
        unrefEntered.signal()
        if let unrefGate, unrefGate.wait(timeout: .now() + 3) != .success {
            throw VMError.invalidConfiguration("unref fixture timed out")
        }
        if failure == .unref { throw VMError.invalidConfiguration("unknown unref outcome") }
    }
    func mapBlob(resourceID: UInt32) throws -> VirtioGPUBlobMapping {
        throw VirtioGPURendererCommandRejected("fixture has no blob mapping")
    }
    func unmapBlob(resourceID: UInt32) throws {}
    func transferToHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws {}
    func transferFromHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws {}
    func createFence(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64, contextFence: Bool) throws {}
    func resetAfterDeviceQuiesce() throws -> VirtioGPURendererResetResult {
        resetEntered.signal()
        if let resetGate, resetGate.wait(timeout: .now() + 3) != .success {
            throw VMError.invalidConfiguration("reset fixture timed out")
        }
        return failure == .reset ? .requiresRecreation("reset ownership is not proven") : .ready
    }
}
