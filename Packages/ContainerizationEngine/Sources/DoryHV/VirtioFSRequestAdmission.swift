import DoryFSWorkerContracts
import Foundation

/// Host-owned request envelope produced while the exact virtqueue lease is held. Execution code
/// never needs guest pointers, which is the seam a future out-of-process FUSE worker can consume.
struct VirtioFSAdmittedRequest: Sendable {
    let bytes: [UInt8]
    let header: FuseInHeader
    let opcode: FuseOpcode?
    let writableCapacity: Int
    let maximumResponseBytes: Int
    let expectsReply: Bool
}

enum VirtioFSRequestRejection: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyChain
    case zeroLengthDescriptor
    case readableAfterWritable
    case missingReadablePrefix
    case missingWritableSuffix
    case shortHeader
    case requestTooLarge(limit: Int, actual: Int)
    case lengthMismatch(declared: UInt32, actual: Int)
    case headerChangedDuringSnapshot
    case wrongQueue(queue: Int, opcode: UInt32)
    case responseTooLarge(limit: Int, requested: Int)
    case insufficientResponseCapacity(required: Int, actual: Int)

    var description: String {
        switch self {
        case .emptyChain: return "empty descriptor chain"
        case .zeroLengthDescriptor: return "zero-length descriptor"
        case .readableAfterWritable: return "readable descriptor follows writable suffix"
        case .missingReadablePrefix: return "missing readable request prefix"
        case .missingWritableSuffix: return "missing writable response suffix"
        case .shortHeader: return "request is shorter than fuse_in_header"
        case let .requestTooLarge(limit, actual):
            return "request size \(actual) exceeds \(limit) bytes"
        case let .lengthMismatch(declared, actual):
            return "fuse_in_header.len \(declared) does not equal readable size \(actual)"
        case .headerChangedDuringSnapshot:
            return "fuse_in_header changed while taking the host-owned request snapshot"
        case let .wrongQueue(queue, opcode):
            return "opcode \(opcode) is not permitted on queue \(queue)"
        case let .responseTooLarge(limit, requested):
            return "response bound \(requested) exceeds \(limit) bytes"
        case let .insufficientResponseCapacity(required, actual):
            return "response capacity \(actual) is smaller than required \(required)"
        }
    }
}

struct VirtioFSRejectedRequest: Sendable {
    let reason: VirtioFSRequestRejection
    /// A complete host-owned FUSE error frame when the validated writable suffix can hold one.
    let response: [UInt8]
}

enum VirtioFSRequestAdmissionDecision: Sendable {
    case execute(VirtioFSAdmittedRequest)
    case reject(VirtioFSRejectedRequest)
}

struct VirtioFSRequestAdmissionPreview: Sendable {
    let opcode: FuseOpcode?
    let requestBytes: Int?
    let responseBytes: Int?
}

enum VirtioFSRequestAdmission {
    /// Dory negotiates a one-MiB FUSE transfer payload. The common header is bounded separately so
    /// a legal maximum-sized WRITE remains representable without accepting an unbounded request.
    static let maximumPayloadBytes = 1 * 1_024 * 1_024
    static let maximumRequestBytes = FuseInHeader.byteCount + maximumPayloadBytes
    static let maximumResponseBytes = FuseOutHeader.byteCount + maximumPayloadBytes

    /// Computes only the exact admission-memory shape while the chain remains guest-owned. This
    /// bounded preview reads at most the FUSE header plus the fixed fields needed to size READ and
    /// READDIRPLUS replies; the full payload is copied exactly once, after a workspace lease has
    /// been reserved and the chain is popped.
    static func preview(
        chain: VirtqueueChain,
        access: VirtqueueLeaseAccess,
        queue: Int,
        maximumRequestBytes requestLimit: Int = maximumRequestBytes,
        maximumResponseBytes responseLimit: Int = maximumResponseBytes
    ) -> VirtioFSRequestAdmissionPreview {
        var readableBytes = 0
        var writableBytes = 0
        var sawReadable = false
        var sawWritable = false
        for segment in access.segments {
            guard segment.length > 0 else {
                return .init(opcode: nil, requestBytes: nil, responseBytes: nil)
            }
            if segment.isDeviceWritable {
                sawWritable = true
                guard let total = checkedAdd(writableBytes, segment.length) else {
                    return .init(opcode: nil, requestBytes: nil, responseBytes: nil)
                }
                writableBytes = total
            } else {
                guard !sawWritable,
                      let total = checkedAdd(readableBytes, segment.length) else {
                    return .init(opcode: nil, requestBytes: nil, responseBytes: nil)
                }
                sawReadable = true
                readableBytes = total
            }
        }
        guard !chain.containsZeroLengthDescriptor,
              sawReadable,
              readableBytes >= FuseInHeader.byteCount else {
            return .init(opcode: nil, requestBytes: nil, responseBytes: nil)
        }
        let prefix = access.readBytes(
            maximum: min(readableBytes, FuseInHeader.byteCount + 32)
        )
        guard prefix.count >= FuseInHeader.byteCount,
              let header = try? FuseProtocol.decodeInHeader(prefix) else {
            return .init(opcode: nil, requestBytes: nil, responseBytes: nil)
        }
        let opcode = FuseOpcode(rawValue: header.opcode)
        guard readableBytes <= requestLimit,
              header.length == UInt32(readableBytes) else {
            return .init(opcode: opcode, requestBytes: nil, responseBytes: nil)
        }
        let replylessForget = opcode == .forget || opcode == .batchForget
        let isHighPriority = replylessForget || opcode == .interrupt
        guard (queue == 0) == isHighPriority,
              replylessForget || sawWritable else {
            return .init(opcode: opcode, requestBytes: nil, responseBytes: nil)
        }
        guard let requiredCapacity = try? requiredResponseCapacity(
            opcode: opcode,
            request: prefix,
            maximumResponseBytes: responseLimit
        ), requiredCapacity <= responseLimit,
           writableBytes >= requiredCapacity else {
            return .init(opcode: opcode, requestBytes: nil, responseBytes: nil)
        }
        return VirtioFSRequestAdmissionPreview(
            opcode: opcode,
            requestBytes: readableBytes,
            responseBytes: opcode == .readlink
                ? min(writableBytes, responseLimit)
                : requiredCapacity
        )
    }

    static func inspect(
        chain: VirtqueueChain,
        access: VirtqueueLeaseAccess,
        queue: Int,
        maximumRequestBytes requestLimit: Int = maximumRequestBytes,
        maximumResponseBytes responseLimit: Int = maximumResponseBytes
    ) -> VirtioFSRequestAdmissionDecision {
        guard !access.segments.isEmpty else { return reject(.emptyChain) }
        guard !chain.containsZeroLengthDescriptor else {
            return reject(.zeroLengthDescriptor)
        }

        var sawReadable = false
        var sawWritable = false
        var readableBytes = 0
        var writableBytes = 0
        for segment in access.segments {
            guard segment.length > 0 else { return reject(.zeroLengthDescriptor) }
            if segment.isDeviceWritable {
                sawWritable = true
                guard let total = checkedAdd(writableBytes, segment.length) else {
                    return reject(.responseTooLarge(limit: maximumResponseBytes, requested: Int.max))
                }
                writableBytes = total
            } else {
                guard !sawWritable else { return reject(.readableAfterWritable) }
                sawReadable = true
                guard let total = checkedAdd(readableBytes, segment.length) else {
                    return reject(.requestTooLarge(limit: maximumRequestBytes, actual: Int.max))
                }
                readableBytes = total
            }
        }
        guard sawReadable else { return reject(.missingReadablePrefix) }
        guard readableBytes >= FuseInHeader.byteCount else { return reject(.shortHeader) }

        let headerBytes = access.readBytes(maximum: FuseInHeader.byteCount)
        guard headerBytes.count == FuseInHeader.byteCount,
              let observedHeader = try? FuseProtocol.decodeInHeader(headerBytes) else {
            return reject(.shortHeader)
        }
        guard readableBytes <= requestLimit else {
            return reject(
                .requestTooLarge(limit: requestLimit, actual: readableBytes),
                header: observedHeader,
                writableCapacity: sawWritable ? writableBytes : 0,
                errno: E2BIG
            )
        }
        guard observedHeader.length == UInt32(readableBytes) else {
            return reject(
                .lengthMismatch(declared: observedHeader.length, actual: readableBytes),
                header: observedHeader,
                writableCapacity: sawWritable ? writableBytes : 0,
                errno: EINVAL
            )
        }

        let request = access.readBytes(maximum: readableBytes)
        guard request.count == readableBytes else {
            return reject(.lengthMismatch(declared: observedHeader.length, actual: request.count))
        }
        guard let header = try? FuseProtocol.decodeInHeader(request),
              header.length == UInt32(readableBytes) else {
            return reject(
                .headerChangedDuringSnapshot,
                header: observedHeader,
                writableCapacity: sawWritable ? writableBytes : 0,
                errno: EINVAL
            )
        }
        guard header == observedHeader else {
            return reject(
                .headerChangedDuringSnapshot,
                header: header,
                writableCapacity: sawWritable ? writableBytes : 0,
                errno: EINVAL
            )
        }

        // Every decision that can authorize host work is derived from the immutable host-owned
        // snapshot above. The bounded preliminary header is used only to prove the copy size.
        let opcode = FuseOpcode(rawValue: header.opcode)
        let replylessForget = opcode == .forget || opcode == .batchForget
        let isHighPriority = replylessForget || opcode == .interrupt
        guard (queue == 0) == isHighPriority else {
            return reject(
                .wrongQueue(queue: queue, opcode: header.opcode),
                header: header,
                writableCapacity: sawWritable ? writableBytes : 0,
                errno: EPROTO
            )
        }
        if !replylessForget, !sawWritable {
            return reject(.missingWritableSuffix, header: header, writableCapacity: 0, errno: EIO)
        }
        let requiredCapacity: Int
        do {
            requiredCapacity = try requiredResponseCapacity(
                opcode: opcode,
                request: request,
                maximumResponseBytes: responseLimit
            )
        } catch let reason as VirtioFSRequestRejection {
            return reject(
                reason,
                header: header,
                writableCapacity: sawWritable ? writableBytes : 0,
                errno: EINVAL
            )
        } catch {
            return reject(
                .responseTooLarge(limit: maximumResponseBytes, requested: Int.max),
                header: header,
                writableCapacity: sawWritable ? writableBytes : 0,
                errno: EINVAL
            )
        }
        guard writableBytes >= requiredCapacity else {
            return reject(
                .insufficientResponseCapacity(required: requiredCapacity, actual: writableBytes),
                header: header,
                writableCapacity: writableBytes,
                errno: EIO
            )
        }
        guard requiredCapacity <= responseLimit else {
            return reject(
                .responseTooLarge(limit: responseLimit, requested: requiredCapacity),
                header: header,
                writableCapacity: writableBytes,
                errno: E2BIG
            )
        }

        return .execute(VirtioFSAdmittedRequest(
            bytes: request,
            header: header,
            opcode: opcode,
            writableCapacity: writableBytes,
            maximumResponseBytes: opcode == .readlink
                ? min(writableBytes, responseLimit)
                : requiredCapacity,
            expectsReply: !replylessForget
        ))
    }

    private static func requiredResponseCapacity(
        opcode: FuseOpcode?,
        request: [UInt8],
        maximumResponseBytes: Int
    ) throws -> Int {
        guard let opcode else { return FuseOutHeader.byteCount }
        switch opcode {
        case .forget, .batchForget:
            return 0
        case .initOp:
            return FuseOutHeader.byteCount + FuseInitOut.byteCount
        case .lookup, .symlink, .link, .mkdir:
            return FuseOutHeader.byteCount + 128
        case .getattr, .setattr:
            return FuseOutHeader.byteCount + 104
        case .open, .opendir:
            return FuseOutHeader.byteCount + 16
        case .read, .readdirplus:
            let payloadOffset = FuseInHeader.byteCount
            guard request.count >= payloadOffset + 20 else { return FuseOutHeader.byteCount }
            let payloadBytes = Int(request.leUInt32(at: payloadOffset + 16))
            let required = FuseOutHeader.byteCount + payloadBytes
            guard required <= maximumResponseBytes else {
                throw VirtioFSRequestRejection.responseTooLarge(
                    limit: maximumResponseBytes,
                    requested: required
                )
            }
            return required
        case .write:
            return FuseOutHeader.byteCount + 8
        case .statfs:
            return FuseOutHeader.byteCount + 80
        case .getlk:
            return FuseOutHeader.byteCount + 24
        case .listxattr:
            return FuseOutHeader.byteCount + 4
        case .create:
            return FuseOutHeader.byteCount + 144
        case .readlink:
            // READLINK neither mutates host state nor grants a resource. Its payload is validated
            // against the actual writable capacity after the single generic execution.
            return FuseOutHeader.byteCount
        case .unlink, .rmdir, .rename, .release, .fsync, .syncfs, .setxattr, .getxattr, .flush,
             .setlk, .setlkw, .interrupt, .releasedir, .setupmapping, .removemapping:
            // These implemented operations have either an empty success or a header-only error.
            // INTERRUPT remains reply-capable at the transport boundary even when no matching
            // pending server operation requires a payload.
            return FuseOutHeader.byteCount
        case .readdir, .fsyncdir, .bmap, .destroy, .ioctl, .poll, .notifyReply, .fallocate,
             .rename2, .lseek, .copyFileRange:
            // The generic FuseServer path explicitly rejects these with a header-only ENOSYS.
            // Keeping the classification exhaustive prevents a future mutating implementation
            // from silently inheriting an insufficient response preflight.
            return FuseOutHeader.byteCount
        }
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }

    private static func reject(_ reason: VirtioFSRequestRejection) -> VirtioFSRequestAdmissionDecision {
        .reject(VirtioFSRejectedRequest(reason: reason, response: []))
    }

    private static func reject(
        _ reason: VirtioFSRequestRejection,
        header: FuseInHeader,
        writableCapacity: Int,
        errno: Int32
    ) -> VirtioFSRequestAdmissionDecision {
        guard writableCapacity >= FuseOutHeader.byteCount else { return reject(reason) }
        let response = FuseProtocol.encodeOutHeader(FuseOutHeader(
            length: UInt32(FuseOutHeader.byteCount),
            error: -FuseProtocol.linuxErrno(errno),
            unique: header.unique
        ))
        return .reject(VirtioFSRejectedRequest(reason: reason, response: response))
    }
}
