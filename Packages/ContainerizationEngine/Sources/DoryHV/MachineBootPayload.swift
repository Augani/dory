import CryptoKit
import Darwin
import Foundation

/// Exact authority for one anonymous, read-only boot blob inherited from the daemon.
///
/// `maximumByteCount` is a local allocation ceiling, not caller-controlled evidence. The child
/// validates the descriptor before allocating and uses `pread` so supervised restarts never share
/// or depend on an open-file-description offset.
public struct MachineInheritedBootBlob: Sendable, Equatable {
    public let descriptor: Int32
    public let byteCount: UInt64
    public let sha256: String
    public let maximumByteCount: UInt64

    public init(
        descriptor: Int32,
        byteCount: UInt64,
        sha256: String,
        maximumByteCount: UInt64
    ) {
        self.descriptor = descriptor
        self.byteCount = byteCount
        self.sha256 = sha256
        self.maximumByteCount = maximumByteCount
    }
}

/// Single-use ownership of resolved boot bytes.
///
/// Every `MachineBootPayload` copy shares this authority. Consumption removes the authority's
/// references before invoking the guest-memory loader and permanently retires the authority when
/// that loader returns or throws. Consequently a retained `MachineConfiguration` cannot keep a
/// second kernel/initrd copy alive or replay partially loaded resolved authority.
public final class MachineImmutableBootAuthority: @unchecked Sendable, Equatable {
    private struct Bytes {
        let kernel: Data
        let initrd: Data?
    }

    private enum State {
        case available(Bytes)
        case consuming
        case consumed
    }

    private let lock = NSLock()
    private var state: State

    fileprivate init(kernel: Data, initrd: Data?) {
        self.state = .available(Bytes(kernel: kernel, initrd: initrd))
    }

    public static func == (
        lhs: MachineImmutableBootAuthority,
        rhs: MachineImmutableBootAuthority
    ) -> Bool {
        lhs === rhs
    }

    fileprivate func consumeForGuestLoad(
        _ load: (Data, () throws -> Data?) throws -> Void
    ) throws {
        let bytes: Bytes
        lock.lock()
        switch state {
        case .available(let available):
            bytes = available
            state = .consuming
            lock.unlock()
        case .consuming:
            lock.unlock()
            throw VMError.invalidConfiguration(
                "resolved immutable boot payload is already being consumed"
            )
        case .consumed:
            lock.unlock()
            throw VMError.invalidConfiguration(
                "resolved immutable boot payload has already been consumed"
            )
        }

        defer {
            lock.lock()
            state = .consumed
            lock.unlock()
        }
        try load(bytes.kernel) { bytes.initrd }
    }

    /// Test-visible accounting of bytes retained by the authority itself. The count becomes zero
    /// before guest loading begins and remains zero after either success or failure.
    var retainedByteCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard case .available(let bytes) = state else { return 0 }
        return UInt64(bytes.kernel.count) + UInt64(bytes.initrd?.count ?? 0)
    }

    var isConsumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .consumed = state else { return false }
        return true
    }
}

/// A typed split between repeatable legacy pathname boot and one-shot resolved immutable-byte boot.
public enum MachineBootPayload: Sendable, Equatable {
    case legacyPaths(kernel: String, initrd: String?)
    case immutableBytes(authority: MachineImmutableBootAuthority)

    /// Source-compatible construction spelling for callers with already-verified bytes. Copies of
    /// the returned enum share one consumable authority rather than retaining independent `Data`.
    public static func immutableBytes(kernel: Data, initrd: Data?) -> Self {
        .immutableBytes(
            authority: MachineImmutableBootAuthority(kernel: kernel, initrd: initrd)
        )
    }

    public static func inheritedReadOnlyDescriptors(
        kernel: MachineInheritedBootBlob,
        initrd: MachineInheritedBootBlob?
    ) throws -> Self {
        var descriptors = [kernel.descriptor]
        if let initrd { descriptors.append(initrd.descriptor) }
        let ownedDescriptors = Set(descriptors.filter { $0 >= 3 })
        defer { ownedDescriptors.forEach { Darwin.close($0) } }
        guard descriptors.allSatisfy({ $0 >= 3 }),
              Set(descriptors).count == descriptors.count else {
            throw VMError.invalidConfiguration(
                "resolved boot descriptors must be unique inherited descriptors"
            )
        }
        let kernelData = try readExactAnonymousBlob(kernel, kind: "linuxKernel")
        let initrdData = try initrd.map {
            try readExactAnonymousBlob($0, kind: "linuxInitrd")
        }
        return .immutableBytes(kernel: kernelData, initrd: initrdData)
    }

    func consumeForGuestLoad(
        _ load: (Data, () throws -> Data?) throws -> Void
    ) throws {
        switch self {
        case .legacyPaths(let kernelPath, let initrdPath):
            let kernel = try Data(contentsOf: URL(fileURLWithPath: kernelPath))
            try load(kernel) {
                try Self.readLegacyInitrd(at: initrdPath)
            }
        case .immutableBytes(let authority):
            try authority.consumeForGuestLoad(load)
        }
    }

    var retainedImmutableByteCount: UInt64 {
        guard case .immutableBytes(let authority) = self else { return 0 }
        return authority.retainedByteCount
    }

    var immutableBytesWereConsumed: Bool {
        guard case .immutableBytes(let authority) = self else { return false }
        return authority.isConsumed
    }

    private static func readLegacyInitrd(at path: String?) throws -> Data? {
        guard let path else { return nil }
        let data = try Data(
            contentsOf: URL(fileURLWithPath: path),
            options: .mappedIfSafe
        )
        guard !data.isEmpty else {
            throw VMError.bootFailure("initrd is empty: \(path)")
        }
        return data
    }

    private static func readExactAnonymousBlob(
        _ authority: MachineInheritedBootBlob,
        kind: String
    ) throws -> Data {
        guard authority.byteCount > 0,
              authority.byteCount <= authority.maximumByteCount,
              let allocationCount = Int(exactly: authority.byteCount),
              isLowercaseSHA256(authority.sha256) else {
            throw VMError.invalidConfiguration(
                "resolved \(kind) metadata is outside its allocation or digest bounds"
            )
        }
        let accessFlags = fcntl(authority.descriptor, F_GETFL)
        var before = stat()
        guard accessFlags >= 0,
              accessFlags & O_ACCMODE == O_RDONLY,
              fstat(authority.descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 0,
              before.st_size > 0,
              UInt64(before.st_size) == authority.byteCount,
              before.st_mode & 0o077 == 0 else {
            throw VMError.invalidConfiguration(
                "resolved \(kind) is not the exact private anonymous read-only blob"
            )
        }

        var data = Data(count: allocationCount)
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                throw VMError.bootFailure("resolved \(kind) allocation is empty")
            }
            var offset = 0
            while offset < raw.count {
                let result = pread(
                    authority.descriptor,
                    base.advanced(by: offset),
                    raw.count - offset,
                    off_t(offset)
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw VMError.bootFailure(
                        "resolved \(kind) changed or ended during exact descriptor read"
                    )
                }
            }
        }

        var after = stat()
        guard fstat(authority.descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw VMError.bootFailure(
                "resolved \(kind) identity changed during descriptor read"
            )
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == authority.sha256 else {
            throw VMError.bootFailure("resolved \(kind) failed exact SHA-256 validation")
        }
        return data
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
