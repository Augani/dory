import Darwin
import DoryRendererWorkerContracts
import DoryVirtio
import Foundation

public enum DoryPCVirGLRendererAuthorityError: Error, Sendable, Equatable {
    case rendererUnavailable
    case unknownResource(UInt32)
    case duplicateBacking(UInt32)
    case missingBacking(UInt32)
    case commandTimedOut
    case workerCommandFailed
}

/// DoryPC adapter for the already-qualified signed renderer worker.
///
/// The initial cut exposes only VirGL2. Guest RAM in the DBT machine is not file-backed, so this
/// authority gives each renderer resource a bounded shared staging allocation and synchronizes it
/// at the architectural transfer boundaries. No guest pointer crosses XPC. Venus remains hidden
/// until DoryPC owns a proper host-visible blob BAR and generation-bound mapping lifecycle.
public final class DoryPCVirGLRendererAuthority: DoryVirtioGPUAccelerationAuthority,
    @unchecked Sendable
{
    public let capabilities: DoryVirtioGPUAccelerationCapabilities

    private let lane: DoryRendererWorkerVirtioCommandLane
    private let lock = NSLock()
    private let commandTimeout: TimeInterval
    private var deviceGeneration: UInt64
    private var active = true
    private var admittedCommand = false
    private var resourceGenerations: [UInt32: UInt64] = [:]
    private var backings: [UInt32: DoryPCVirGLBackingAuthority] = [:]

    public init(
        lane: DoryRendererWorkerVirtioCommandLane,
        deviceGeneration: UInt64,
        commandTimeout: TimeInterval = 6
    ) throws {
        guard deviceGeneration != 0, commandTimeout > 0 else {
            throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
        }
        let virgl = lane.authenticatedCapsets.filter { $0.id == 2 }
        guard !virgl.isEmpty else {
            throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
        }
        capabilities = try DoryVirtioGPUAccelerationCapabilities(
            features: [.gpuVirgl, .gpuResourceUUID, .gpuContextInit],
            capsets: virgl.map {
                .init(id: $0.id, maximumVersion: $0.maxVersion, data: $0.data)
            }
        )
        self.lane = lane
        self.deviceGeneration = deviceGeneration
        self.commandTimeout = commandTimeout
    }

    public func reset() {
        let transition = lock.withLock { () -> (source: UInt64, successor: UInt64, used: Bool)? in
            guard active else { return nil }
            let successor = deviceGeneration &+ 1
            guard successor != 0 else {
                active = false
                return nil
            }
            return (deviceGeneration, successor, admittedCommand)
        }
        guard let transition else { return }
        if !transition.used,
            lane.rebindPristineDeviceGeneration(
                from: transition.source,
                to: transition.successor
            )
        {
            lock.withLock { deviceGeneration = transition.successor }
            return
        }
        lane.revoke(deviceGeneration: transition.source)
        lock.withLock {
            active = false
            resourceGenerations.removeAll(keepingCapacity: false)
            backings.removeAll(keepingCapacity: false)
        }
    }

    public func createContext(id: UInt32, capsetID: UInt32, name: String) throws {
        let generation = try admit()
        try wait { completion in
            try lane.createContext(
                contextID: id,
                capsetID: capsetID,
                name: name,
                deviceGeneration: generation,
                completion: completion
            )
        }
    }

    public func destroyContext(id: UInt32) throws {
        let generation = try admit()
        try wait { completion in
            try lane.destroyContext(
                contextID: id,
                deviceGeneration: generation,
                completion: completion
            )
        }
    }

    public func createResource3D(_ resource: DoryVirtioGPUResource3D) throws {
        let generation = try admit()
        let payload = try DoryRendererResource3DCreatePayload(
            target: resource.target,
            format: resource.format,
            bind: resource.bind,
            width: resource.width,
            height: resource.height,
            depth: resource.depth,
            arraySize: resource.arraySize,
            lastLevel: resource.lastLevel,
            samples: resource.samples,
            flags: resource.flags
        )
        let resourceGeneration: UInt64 = try wait { completion in
            try lane.createResource3D(
                resourceID: resource.resourceID,
                payload: payload,
                deviceGeneration: generation,
                completion: completion
            )
        }
        lock.withLock { resourceGenerations[resource.resourceID] = resourceGeneration }
    }

    public func attachBacking(
        resourceID: UInt32,
        entries: [DoryVirtioGPUBackingEntry],
        memory: any DoryVirtioGuestMemory
    ) throws {
        let deviceGeneration = try admit()
        let resourceGeneration = try generation(for: resourceID)
        guard lock.withLock({ backings[resourceID] == nil }) else {
            throw DoryPCVirGLRendererAuthorityError.duplicateBacking(resourceID)
        }
        let backing = try DoryPCVirGLBackingAuthority(entries: entries, memory: memory)
        try wait { completion in
            try lane.attachBacking(
                resourceID: resourceID,
                resourceGeneration: resourceGeneration,
                regions: backing.regions,
                deviceGeneration: deviceGeneration,
                completion: completion
            )
        }
        lock.withLock { backings[resourceID] = backing }
    }

    public func detachBacking(resourceID: UInt32) throws {
        let deviceGeneration = try admit()
        let resourceGeneration = try generation(for: resourceID)
        guard lock.withLock({ backings[resourceID] != nil }) else {
            throw DoryPCVirGLRendererAuthorityError.missingBacking(resourceID)
        }
        try wait { completion in
            try lane.detachBacking(
                resourceID: resourceID,
                resourceGeneration: resourceGeneration,
                deviceGeneration: deviceGeneration,
                completion: completion
            )
        }
        _ = lock.withLock { backings.removeValue(forKey: resourceID) }
    }

    public func attachResource(contextID: UInt32, resourceID: UInt32) throws {
        let deviceGeneration = try admit()
        let resourceGeneration = try generation(for: resourceID)
        try wait { completion in
            try lane.attachResource(
                contextID: contextID,
                resourceID: resourceID,
                resourceGeneration: resourceGeneration,
                deviceGeneration: deviceGeneration,
                completion: completion
            )
        }
    }

    public func detachResource(contextID: UInt32, resourceID: UInt32) throws {
        let deviceGeneration = try admit()
        let resourceGeneration = try generation(for: resourceID)
        try wait { completion in
            try lane.detachResource(
                contextID: contextID,
                resourceID: resourceID,
                resourceGeneration: resourceGeneration,
                deviceGeneration: deviceGeneration,
                completion: completion
            )
        }
    }

    public func submit3D(contextID: UInt32, command: [UInt8]) throws {
        let generation = try admit()
        let regions = try DoryRendererWorkerSharedRegionSet.immutableSubmit3D(
            bytes: command,
            maximumByteCount: DoryRendererWorkerLimits.production.maximumCommandBytes
        )
        try wait { completion in
            try lane.submit3D(
                contextID: contextID,
                regions: regions,
                deviceGeneration: generation,
                completion: completion
            )
        }
    }

    public func transfer3D(
        _ transfer: DoryVirtioGPUTransfer3D,
        entries: [DoryVirtioGPUBackingEntry],
        memory: any DoryVirtioGuestMemory
    ) throws {
        let deviceGeneration = try admit()
        let resourceGeneration = try generation(for: transfer.resourceID)
        guard let backing = lock.withLock({ backings[transfer.resourceID] }),
            backing.entries == entries
        else {
            throw DoryPCVirGLRendererAuthorityError.missingBacking(transfer.resourceID)
        }
        if transfer.direction == .toHost { try backing.synchronizeFromGuest(memory) }
        let payload = try DoryRendererTransfer3DPayload(
            level: transfer.level,
            stride: transfer.stride,
            layerStride: transfer.layerStride,
            offset: transfer.offset,
            x: transfer.x,
            y: transfer.y,
            z: transfer.z,
            width: transfer.width,
            height: transfer.height,
            depth: transfer.depth
        )
        try wait { completion in
            switch transfer.direction {
            case .toHost:
                try lane.transferToHost3D(
                    resourceID: transfer.resourceID,
                    resourceGeneration: resourceGeneration,
                    contextID: transfer.contextID,
                    payload: payload,
                    deviceGeneration: deviceGeneration,
                    completion: completion
                )
            case .fromHost:
                try lane.transferFromHost3D(
                    resourceID: transfer.resourceID,
                    resourceGeneration: resourceGeneration,
                    contextID: transfer.contextID,
                    payload: payload,
                    deviceGeneration: deviceGeneration,
                    completion: completion
                )
            }
        }
        if transfer.direction == .fromHost { try backing.synchronizeToGuest(memory) }
    }

    public func unrefResource(resourceID: UInt32) throws {
        let deviceGeneration = try admit()
        let resourceGeneration = try generation(for: resourceID)
        try wait { completion in
            try lane.unrefResource(
                resourceID: resourceID,
                resourceGeneration: resourceGeneration,
                deviceGeneration: deviceGeneration,
                completion: completion
            )
        }
        lock.withLock {
            resourceGenerations.removeValue(forKey: resourceID)
            backings.removeValue(forKey: resourceID)
        }
    }

    private func admit() throws -> UInt64 {
        try lock.withLock {
            guard active else { throw DoryPCVirGLRendererAuthorityError.rendererUnavailable }
            admittedCommand = true
            return deviceGeneration
        }
    }

    private func generation(for resourceID: UInt32) throws -> UInt64 {
        guard let generation = lock.withLock({ resourceGenerations[resourceID] }) else {
            throw DoryPCVirGLRendererAuthorityError.unknownResource(resourceID)
        }
        return generation
    }

    private func wait<T: Sendable>(
        _ submit: (
            @escaping @Sendable (Result<T, DoryRendererWorkerVirtioCommandLaneError>) -> Void
        )
            throws -> Void
    ) throws -> T {
        let receipt = DoryPCSynchronousRendererReceipt<T>()
        try submit { receipt.complete($0) }
        guard let result = receipt.wait(timeout: commandTimeout) else {
            throw DoryPCVirGLRendererAuthorityError.commandTimedOut
        }
        switch result {
        case .success(let value): return value
        case .failure: throw DoryPCVirGLRendererAuthorityError.workerCommandFailed
        }
    }
}

private final class DoryPCSynchronousRendererReceipt<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Value, DoryRendererWorkerVirtioCommandLaneError>?

    func complete(_ result: Result<Value, DoryRendererWorkerVirtioCommandLaneError>) {
        condition.lock()
        guard self.result == nil else {
            condition.unlock()
            return
        }
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Result<Value, DoryRendererWorkerVirtioCommandLaneError>? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while result == nil, condition.wait(until: deadline) {}
        return result
    }
}

private final class DoryPCVirGLBackingAuthority: @unchecked Sendable {
    let entries: [DoryVirtioGPUBackingEntry]
    let regions: DoryRendererWorkerSharedRegionSet

    private let mapping: UnsafeMutableRawPointer
    private let byteCount: Int
    private let descriptor: FileHandle

    init(entries: [DoryVirtioGPUBackingEntry], memory: any DoryVirtioGuestMemory) throws {
        guard !entries.isEmpty else {
            throw DoryPCVirGLRendererAuthorityError.missingBacking(0)
        }
        let total = try entries.reduce(UInt64(0)) { partial, entry in
            let (sum, overflow) = partial.addingReportingOverflow(UInt64(entry.length))
            guard entry.length > 0, !overflow, sum <= UInt64(Int.max) else {
                throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
            }
            return sum
        }
        let templateURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dory-pc-virgl.XXXXXX")
        var template = templateURL.path.utf8CString
        let fileDescriptor = template.withUnsafeMutableBufferPointer {
            mkstemp($0.baseAddress!)
        }
        guard fileDescriptor >= 0 else {
            throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
        }
        var mapped: UnsafeMutableRawPointer?
        do {
            let descriptorFlags = fcntl(fileDescriptor, F_GETFD)
            guard descriptorFlags >= 0,
                fcntl(fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
                ftruncate(fileDescriptor, off_t(total)) == 0,
                template.withUnsafeBufferPointer({ unlink($0.baseAddress!) }) == 0
            else {
                throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
            }
            mapped = mmap(nil, Int(total), PROT_READ | PROT_WRITE, MAP_SHARED, fileDescriptor, 0)
            guard mapped != MAP_FAILED, mapped != nil else {
                throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
            }
            var offset: UInt64 = 0
            var references: [DoryRendererSharedRegionReference] = []
            references.reserveCapacity(entries.count)
            for entry in entries {
                references.append(
                    try .init(
                        identity: .random(),
                        descriptorIndex: 0,
                        access: .readWrite,
                        offset: offset,
                        length: UInt64(entry.length),
                        declaredFileSize: total
                    ))
                offset += UInt64(entry.length)
            }
            offset = 0
            for entry in entries {
                let bytes = try memory.read(
                    at: entry.guestAddress,
                    byteCount: Int(entry.length)
                )
                bytes.withUnsafeBytes { source in
                    mapped!.advanced(by: Int(offset)).copyMemory(
                        from: source.baseAddress!,
                        byteCount: bytes.count
                    )
                }
                offset += UInt64(bytes.count)
            }
            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
            self.entries = entries
            self.mapping = mapped!
            self.byteCount = Int(total)
            self.descriptor = handle
            self.regions = .init(references: references, descriptors: [handle])
        } catch {
            if mapped != nil, mapped != MAP_FAILED { munmap(mapped, Int(total)) }
            close(fileDescriptor)
            _ = template.withUnsafeBufferPointer { unlink($0.baseAddress!) }
            throw error
        }
    }

    deinit { munmap(mapping, byteCount) }

    func synchronizeFromGuest(_ memory: any DoryVirtioGuestMemory) throws {
        var offset = 0
        for entry in entries {
            let bytes = try memory.read(
                at: entry.guestAddress,
                byteCount: Int(entry.length)
            )
            bytes.withUnsafeBytes { source in
                mapping.advanced(by: offset).copyMemory(
                    from: source.baseAddress!,
                    byteCount: bytes.count
                )
            }
            offset += bytes.count
        }
    }

    func synchronizeToGuest(_ memory: any DoryVirtioGuestMemory) throws {
        var offset = 0
        for entry in entries {
            let count = Int(entry.length)
            let bytes = Array(
                UnsafeRawBufferPointer(start: mapping.advanced(by: offset), count: count)
            )
            try memory.write(at: entry.guestAddress, bytes: bytes)
            offset += count
        }
    }
}
