import Darwin
import DoryRendererWorkerContracts
import Foundation

/// Descriptor authorities and their ordered renderer iovec slices. One descriptor may back many
/// discontiguous guest-RAM regions; command streams instead use a separately sealed read-only
/// snapshot so a guest cannot mutate admitted bytes while the worker consumes them.
struct DoryRendererWorkerSharedRegionSet: @unchecked Sendable {
    let references: [DoryRendererSharedRegionReference]
    let descriptors: [FileHandle]

    static func guestBacking(
        entries: [VirtioGPUMemoryEntry],
        transport: VirtioMMIOTransport
    ) throws -> Self {
        guard !entries.isEmpty else { return Self(references: [], descriptors: []) }
        let descriptor = try transport.duplicateGuestMemoryBackingDescriptor()
        do {
            var references = [DoryRendererSharedRegionReference]()
            references.reserveCapacity(entries.count)
            var expectedFileSize: UInt64?
            for entry in entries {
                guard entry.length > 0, let guestAddress = entry.guestAddress else {
                    throw VMError.invalidConfiguration(
                        "renderer backing is not guest-memory descriptor backed"
                    )
                }
                let bounds = try transport.guestMemoryRegionBounds(
                    at: guestAddress,
                    count: UInt64(entry.length)
                )
                if let expectedFileSize {
                    guard expectedFileSize == bounds.declaredFileSize else {
                        throw VMError.invalidConfiguration(
                            "renderer backing spans different guest-memory authorities"
                        )
                    }
                } else {
                    expectedFileSize = bounds.declaredFileSize
                }
                references.append(try DoryRendererSharedRegionReference(
                    identity: .random(),
                    descriptorIndex: 0,
                    access: .readWrite,
                    offset: bounds.offset,
                    length: bounds.length,
                    declaredFileSize: bounds.declaredFileSize
                ))
            }
            return Self(references: references, descriptors: [descriptor])
        } catch {
            try? descriptor.close()
            throw error
        }
    }

    /// Copies one immutable submit stream directly from a lease-held virtqueue view into an
    /// unlinked shared mapping. No `[UInt8]` or XPC `Data` ever contains command dwords.
    static func immutableSubmit3D(
        from access: VirtqueueLeaseAccess,
        readableOffset: Int,
        byteCount: Int,
        maximumByteCount: Int
    ) throws -> Self {
        try immutableSubmit3D(
            from: access.segments,
            readableByteCount: access.readableByteCount,
            readableOffset: readableOffset,
            byteCount: byteCount,
            maximumByteCount: maximumByteCount
        )
    }

    static func immutableSubmit3D(
        from segments: [VirtqueueSegment],
        readableByteCount: Int,
        readableOffset: Int,
        byteCount: Int,
        maximumByteCount: Int
    ) throws -> Self {
        guard readableOffset >= 0,
              byteCount > 0,
              byteCount <= maximumByteCount,
              byteCount.isMultiple(of: 4),
              readableOffset.isMultiple(of: 8) else {
            throw VMError.invalidConfiguration("invalid descriptor-backed submit_3d range")
        }
        let (end, overflow) = readableOffset.addingReportingOverflow(byteCount)
        guard !overflow, end <= readableByteCount else {
            throw VMError.invalidConfiguration("submit_3d range exceeds its descriptor chain")
        }

        let authority = try ImmutableAuthority(byteCount: byteCount)
        do {
            var logicalOffset = 0
            var destinationOffset = 0
            for segment in segments where !segment.isDeviceWritable {
                let (segmentEnd, segmentOverflow) = logicalOffset.addingReportingOverflow(
                    segment.length
                )
                guard segment.length >= 0, !segmentOverflow else {
                    throw VMError.invalidConfiguration("invalid submit_3d descriptor length")
                }
                defer { logicalOffset = segmentEnd }
                guard segmentEnd > readableOffset,
                      logicalOffset < end else { continue }
                let sourceStart = max(readableOffset, logicalOffset)
                let sourceEnd = min(end, segmentEnd)
                let take = sourceEnd - sourceStart
                guard take > 0 else { continue }
                authority.mapping.advanced(by: destinationOffset).copyMemory(
                    from: segment.pointer.advanced(by: sourceStart - logicalOffset),
                    byteCount: take
                )
                destinationOffset += take
            }
            guard destinationOffset == byteCount else {
                throw VMError.invalidConfiguration("incomplete submit_3d descriptor snapshot")
            }
            let descriptor = try authority.finish()
            return Self(
                references: [try DoryRendererSharedRegionReference(
                    identity: .random(),
                    descriptorIndex: 0,
                    access: .readOnly,
                    offset: 0,
                    length: UInt64(byteCount),
                    declaredFileSize: UInt64(byteCount)
                )],
                descriptors: [descriptor]
            )
        } catch {
            authority.abort()
            throw error
        }
    }
}

private final class ImmutableAuthority {
    let mapping: UnsafeMutableRawPointer

    private let writableDescriptor: Int32
    private let readOnlyDescriptor: Int32
    private let byteCount: Int
    private var finished = false

    init(byteCount: Int) throws {
        let templateURL = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("dory-renderer-command.XXXXXX")
        var template = templateURL.path.utf8CString
        let writable = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        guard writable >= 0 else {
            throw VMError.outOfMemory("cannot create renderer command authority: errno \(errno)")
        }
        var readOnly: Int32 = -1
        var mapped: UnsafeMutableRawPointer?
        do {
            let writableFlags = fcntl(writable, F_GETFD)
            guard writableFlags >= 0,
                  fcntl(writable, F_SETFD, writableFlags | FD_CLOEXEC) == 0,
                  ftruncate(writable, off_t(byteCount)) == 0 else {
                throw VMError.outOfMemory(
                    "cannot size renderer command authority: errno \(errno)"
                )
            }
            readOnly = template.withUnsafeBufferPointer { buffer in
                open(buffer.baseAddress!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard readOnly >= 0 else {
                throw VMError.outOfMemory(
                    "cannot seal renderer command authority: errno \(errno)"
                )
            }
            let unlinkResult = template.withUnsafeBufferPointer { buffer in
                unlink(buffer.baseAddress!)
            }
            guard unlinkResult == 0 else {
                throw VMError.outOfMemory(
                    "cannot unlink renderer command authority: errno \(errno)"
                )
            }
            mapped = mmap(
                nil,
                byteCount,
                PROT_READ | PROT_WRITE,
                MAP_SHARED,
                writable,
                0
            )
            guard mapped != MAP_FAILED, mapped != nil else {
                throw VMError.outOfMemory(
                    "cannot map renderer command authority: errno \(errno)"
                )
            }
        } catch {
            if mapped != nil, mapped != MAP_FAILED { munmap(mapped, byteCount) }
            if readOnly >= 0 { close(readOnly) }
            close(writable)
            _ = template.withUnsafeBufferPointer { buffer in
                unlink(buffer.baseAddress!)
            }
            throw error
        }
        self.mapping = mapped!
        self.writableDescriptor = writable
        self.readOnlyDescriptor = readOnly
        self.byteCount = byteCount
    }

    func finish() throws -> FileHandle {
        guard !finished,
              mprotect(mapping, byteCount, PROT_READ) == 0 else {
            throw VMError.invalidConfiguration("cannot seal renderer command mapping")
        }
        munmap(mapping, byteCount)
        close(writableDescriptor)
        finished = true
        return FileHandle(fileDescriptor: readOnlyDescriptor, closeOnDealloc: true)
    }

    func abort() {
        guard !finished else { return }
        munmap(mapping, byteCount)
        close(writableDescriptor)
        close(readOnlyDescriptor)
        finished = true
    }

    deinit { abort() }
}
