import Foundation

public enum DaxWindowError: Error, Equatable {
    case invalidWindow
    case unaligned
    case outOfBounds
    case overlap
    case missingMapping
    case mappingFailed(String)
    case unmappingFailed(String)
}

public struct DaxMapping: Equatable, Sendable {
    public var fileHandle: UInt64
    public var fileOffset: UInt64
    public var memoryOffset: UInt64
    public var length: UInt64
    public var flags: UInt64

    public init(fileHandle: UInt64, fileOffset: UInt64, memoryOffset: UInt64, length: UInt64, flags: UInt64 = 0) {
        self.fileHandle = fileHandle
        self.fileOffset = fileOffset
        self.memoryOffset = memoryOffset
        self.length = length
        self.flags = flags
    }
}

public protocol DaxMappingBackend: AnyObject, Sendable {
    func map(_ mapping: DaxMapping, fileDescriptor: Int32, guestAddress: UInt64) throws
    func unmap(_ mapping: DaxMapping, guestAddress: UInt64) throws
}

public final class DaxWindow: @unchecked Sendable {
    public static let defaultSize: UInt64 = 4 * 1024 * 1024 * 1024
    public static let pageSize: UInt64 = HostPage.size

    public let guestBase: UInt64
    public let length: UInt64
    private let backend: DaxMappingBackend?
    private var mappings: [DaxMapping] = []
    private let lock = NSLock()

    public init(guestBase: UInt64, length: UInt64 = DaxWindow.defaultSize, backend: DaxMappingBackend? = nil) throws {
        guard length > 0, guestBase.isMultiple(of: Self.pageSize), length.isMultiple(of: Self.pageSize) else {
            throw DaxWindowError.invalidWindow
        }
        self.guestBase = guestBase
        self.length = length
        self.backend = backend
    }

    public var activeMappings: [DaxMapping] {
        lock.lock()
        defer { lock.unlock() }
        return mappings.sorted { $0.memoryOffset < $1.memoryOffset }
    }

    public func setup(_ request: FuseSetupMappingIn, fileDescriptor: Int32? = nil) throws -> DaxMapping {
        let mapping = DaxMapping(
            fileHandle: request.fileHandle,
            fileOffset: request.fileOffset,
            memoryOffset: request.memoryOffset,
            length: request.length,
            flags: request.flags
        )
        try validate(mapping)
        if backend != nil, fileDescriptor == nil {
            throw DaxWindowError.mappingFailed("missing file descriptor")
        }
        lock.lock()
        defer { lock.unlock() }
        guard !mappings.contains(where: { rangesOverlap($0.memoryOffset, $0.length, mapping.memoryOffset, mapping.length) }) else {
            throw DaxWindowError.overlap
        }
        if let backend, let fileDescriptor {
            try backend.map(mapping, fileDescriptor: fileDescriptor, guestAddress: try guestAddress(forMemoryOffset: mapping.memoryOffset))
        }
        mappings.append(mapping)
        return mapping
    }

    public func remove(_ request: FuseRemoveMappingIn) throws {
        lock.lock()
        defer { lock.unlock() }
        for entry in request.mappings {
            guard entry.memoryOffset.isMultiple(of: Self.pageSize),
                  entry.length > 0,
                  entry.length.isMultiple(of: Self.pageSize) else {
                throw DaxWindowError.unaligned
            }
            let overlapping = mappings.indices.filter {
                rangesOverlap(mappings[$0].memoryOffset, mappings[$0].length, entry.memoryOffset, entry.length)
            }
            for index in overlapping.reversed() {
                let mapping = mappings[index]
                if let backend {
                    try backend.unmap(mapping, guestAddress: try guestAddress(forMemoryOffset: mapping.memoryOffset))
                }
                mappings.remove(at: index)
            }
        }
    }

    public func guestAddress(forMemoryOffset offset: UInt64) throws -> UInt64 {
        guard offset < length else { throw DaxWindowError.outOfBounds }
        return guestBase + offset
    }

    private func validate(_ mapping: DaxMapping) throws {
        guard mapping.fileOffset.isMultiple(of: Self.pageSize),
              mapping.memoryOffset.isMultiple(of: Self.pageSize),
              mapping.length > 0,
              mapping.length.isMultiple(of: Self.pageSize) else {
            throw DaxWindowError.unaligned
        }
        guard mapping.memoryOffset < length,
              mapping.length <= length,
              mapping.memoryOffset <= length - mapping.length else {
            throw DaxWindowError.outOfBounds
        }
    }

    private func rangesOverlap(_ aStart: UInt64, _ aLength: UInt64, _ bStart: UInt64, _ bLength: UInt64) -> Bool {
        let aEnd = aStart + aLength
        let bEnd = bStart + bLength
        return aStart < bEnd && bStart < aEnd
    }
}
