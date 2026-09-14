import Dispatch
import Foundation
import Hypervisor
import Testing
@testable import DoryHV

#if arch(arm64)
@Suite struct GICRedistributorMMIOTests {
    // Block each stage, including both halves of the fallback read-modify-write.
    @Test(arguments: [
        BlockedAccess(path: .read, call: 1),
        BlockedAccess(path: .write, call: 1),
        BlockedAccess(path: .fallbackRead, call: 1),
        BlockedAccess(path: .fallbackRead, call: 2),
        BlockedAccess(path: .fallbackWrite, call: 1),
        BlockedAccess(path: .fallbackWrite, call: 2),
        BlockedAccess(path: .fallbackWrite, call: 3),
    ])
    func removalDrainsEntireAccessThenMakesFrameAbsent(blocked: BlockedAccess) throws {
        let probe = RegisterProbe(blockedCall: blocked.call)
        let removalLockAcquired = DispatchSemaphore(value: 0)
        let device = SharedDevice(probe: probe, removalLockAcquired: {
            // Observe drainage while removal holds accessLock, before it mutates the mapping.
            #expect(probe.completedCalls == blocked.path.expectedCalls.count)
            #expect(probe.calls == blocked.path.expectedCalls)
            removalLockAcquired.signal()
        })
        device.mmio.setHandle(41, at: 3)
        let accessed = DispatchSemaphore(value: 0)
        let removed = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            blocked.path.perform(on: device.mmio, frame: 3)
            accessed.signal()
        }
        // Always release a blocked accessor if a prerequisite assertion fails.
        defer { probe.release.signal() }
        try #require(probe.entered.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async {
            device.mmio.removeHandle(41, at: 3)
            removed.signal()
        }
        probe.release.signal()
        try #require(removalLockAcquired.wait(timeout: .now() + 5) == .success)
        try #require(accessed.wait(timeout: .now() + 5) == .success)
        try #require(removed.wait(timeout: .now() + 5) == .success)
        #expect(probe.calls == blocked.path.expectedCalls)

        let retiredCalls = probe.calls
        for registerOffset: UInt64 in [0, 4] {
            #expect(device.mmio.read(offset: 3 * frameStride + registerOffset, width: 4) == 0)
            device.mmio.write(offset: 3 * frameStride + registerOffset, value: 99, width: 4)
        }
        #expect(probe.calls == retiredCalls)
    }

    @Test func retirementUsesAssignedFrameAndPreservesOtherRegistrations() {
        let probe = RegisterProbe()
        let device = SharedDevice(probe: probe)
        // CPU 0 was assigned frame 3; CPU 1 was assigned frame 0.
        device.mmio.setHandle(41, at: 3)
        device.mmio.setHandle(82, at: 0)
        device.mmio.removeHandle(41, at: 3)
        #expect(device.mmio.read(offset: 3 * frameStride, width: 8) == 0)
        device.mmio.write(offset: 3 * frameStride, value: 99, width: 8)
        #expect(probe.calls.isEmpty)
        #expect(device.mmio.read(offset: 0, width: 8) == registerValue)
        device.mmio.write(offset: 0, value: 99, width: 8)
        #expect(probe.calls == [
            RegisterCall(handle: 82, offset: 0, writtenValue: nil),
            RegisterCall(handle: 82, offset: 0, writtenValue: 99),
        ])
    }

    @Test func staleRemovalCannotClearNewRegistrationAndMissingFramesAreRAZWI() {
        let probe = RegisterProbe()
        let device = SharedDevice(probe: probe)
        device.mmio.setHandle(41, at: 3)
        device.mmio.setHandle(82, at: 3)
        device.mmio.removeHandle(41, at: 3)
        device.mmio.removeHandle(41, at: 12)
        for frame: UInt64 in [0, 2, 12] {
            #expect(device.mmio.read(offset: frame * frameStride + 4, width: 4) == 0)
            device.mmio.write(offset: frame * frameStride + 4, value: 99, width: 4)
        }
        #expect(probe.calls.isEmpty)
        #expect(device.mmio.read(offset: 3 * frameStride, width: 8) == registerValue)
        device.mmio.write(offset: 3 * frameStride, value: 99, width: 8)
        #expect(probe.calls.allSatisfy { $0.handle == 82 })
        #expect(probe.calls.count == 2)
    }
}

private let frameStride: UInt64 = 0x2_0000
private let registerValue: UInt64 = 0x1122_3344_5566_7788

struct BlockedAccess: Sendable {
    let path: AccessPath
    let call: Int
}

enum AccessPath: Sendable {
    case read, write, fallbackRead, fallbackWrite

    fileprivate func perform(on mmio: GICRedistributorMMIO, frame: UInt64) {
        let offset = frame * frameStride
        switch self {
        case .read:
            #expect(mmio.read(offset: offset, width: 8) == registerValue)
        case .write:
            mmio.write(offset: offset, value: 0xAABB_CCDD, width: 8)
        case .fallbackRead:
            #expect(mmio.read(offset: offset + 4, width: 4) == registerValue >> 32)
        case .fallbackWrite:
            mmio.write(offset: offset + 4, value: 0xAABB_CCDD, width: 4)
        }
    }

    fileprivate var expectedCalls: [RegisterCall] {
        let read = RegisterCall(handle: 41, offset: 0, writtenValue: nil)
        switch self {
        case .read: return [read]
        case .write: return [RegisterCall(handle: 41, offset: 0, writtenValue: 0xAABB_CCDD)]
        case .fallbackRead:
            return [RegisterCall(handle: 41, offset: 4, writtenValue: nil), read]
        case .fallbackWrite:
            return [
                RegisterCall(handle: 41, offset: 4, writtenValue: 0xAABB_CCDD), read,
                RegisterCall(handle: 41, offset: 0, writtenValue: 0xAABB_CCDD_5566_7788),
            ]
        }
    }
}

private struct RegisterCall: Equatable, Sendable {
    let handle: hv_vcpu_t
    let offset: UInt32
    let writtenValue: UInt64?
}

// Test-only sharing: the device protects its mapping and full operations with its access lock.
private final class SharedDevice: @unchecked Sendable {
    let mmio: GICRedistributorMMIO

    init(probe: RegisterProbe, removalLockAcquired: @escaping @Sendable () -> Void = {}) {
        mmio = GICRedistributorMMIO(
            baseAddress: 0, size: 16 * frameStride, stride: frameStride,
            registerAccess: .init(
                read: { handle, register, value in
                    defer { probe.completeAccess() }
                    probe.access(handle: handle, offset: register.rawValue, writtenValue: nil)
                    value = registerValue
                    return hv_return_t(truncatingIfNeeded: register.rawValue == 4 ? HV_BAD_ARGUMENT : HV_SUCCESS)
                },
                write: { handle, register, value in
                    defer { probe.completeAccess() }
                    probe.access(handle: handle, offset: register.rawValue, writtenValue: value)
                    return hv_return_t(truncatingIfNeeded: register.rawValue == 4 ? HV_BAD_ARGUMENT : HV_SUCCESS)
                },
                removalLockAcquired: removalLockAcquired
            )
        )
    }
}

private final class RegisterProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let blockedCall: Int?
    private var recordedCalls: [RegisterCall] = []
    private var completed = 0

    init(blockedCall: Int? = nil) { self.blockedCall = blockedCall }
    var calls: [RegisterCall] { lock.withLock { recordedCalls } }
    var completedCalls: Int { lock.withLock { completed } }

    func access(handle: hv_vcpu_t, offset: UInt32, writtenValue: UInt64?) {
        let shouldBlock = lock.withLock {
            recordedCalls.append(RegisterCall(handle: handle, offset: offset, writtenValue: writtenValue))
            return recordedCalls.count == blockedCall
        }
        if shouldBlock {
            entered.signal()
            #expect(release.wait(timeout: .now() + 5) == .success)
        }
    }

    func completeAccess() { lock.withLock { completed += 1 } }
}
#endif
