import Foundation

public enum FuseProtocolError: Error, Equatable {
    case shortFrame
    case unsupportedMinor(UInt32)
}

public enum FuseOpcode: UInt32, Sendable {
    case lookup = 1
    case forget = 2
    case getattr = 3
    case setattr = 4
    case readlink = 5
    case symlink = 6
    case mkdir = 9
    case unlink = 10
    case rmdir = 11
    case rename = 12
    case link = 13
    case open = 14
    case read = 15
    case write = 16
    case statfs = 17
    case release = 18
    case fsync = 20
    case setxattr = 21
    case getxattr = 22
    case listxattr = 23
    case flush = 25
    case initOp = 26
    case opendir = 27
    case readdir = 28
    case releasedir = 29
    case fsyncdir = 30
    case getlk = 31
    case setlk = 32
    case setlkw = 33
    case create = 35
    case interrupt = 36
    case bmap = 37
    case destroy = 38
    case ioctl = 39
    case poll = 40
    case notifyReply = 41
    case batchForget = 42
    case fallocate = 43
    case readdirplus = 44
    case rename2 = 45
    case lseek = 46
    case copyFileRange = 47
    case setupmapping = 48
    case removemapping = 49
}

public struct FuseInHeader: Equatable, Sendable {
    public static let byteCount = 40

    public var length: UInt32
    public var opcode: UInt32
    public var unique: UInt64
    public var nodeID: UInt64
    public var uid: UInt32
    public var gid: UInt32
    public var pid: UInt32
    public var totalExtlen: UInt16
    public var padding: UInt16

    public init(
        length: UInt32,
        opcode: UInt32,
        unique: UInt64,
        nodeID: UInt64,
        uid: UInt32,
        gid: UInt32,
        pid: UInt32,
        totalExtlen: UInt16 = 0,
        padding: UInt16 = 0
    ) {
        self.length = length
        self.opcode = opcode
        self.unique = unique
        self.nodeID = nodeID
        self.uid = uid
        self.gid = gid
        self.pid = pid
        self.totalExtlen = totalExtlen
        self.padding = padding
    }
}

public struct FuseOutHeader: Equatable, Sendable {
    public static let byteCount = 16

    public var length: UInt32
    public var error: Int32
    public var unique: UInt64

    public init(length: UInt32, error: Int32, unique: UInt64) {
        self.length = length
        self.error = error
        self.unique = unique
    }
}

public struct FuseForgetIn: Equatable, Sendable {
    public static let byteCount = 8

    public var lookupCount: UInt64

    public init(lookupCount: UInt64) {
        self.lookupCount = lookupCount
    }
}

public struct FuseForgetOne: Equatable, Sendable {
    public static let byteCount = 16

    public var nodeID: UInt64
    public var lookupCount: UInt64

    public init(nodeID: UInt64, lookupCount: UInt64) {
        self.nodeID = nodeID
        self.lookupCount = lookupCount
    }
}

public struct FuseBatchForgetIn: Equatable, Sendable {
    public static let headerByteCount = 8

    public var entries: [FuseForgetOne]

    public init(entries: [FuseForgetOne]) {
        self.entries = entries
    }
}

public struct FuseInitIn: Equatable, Sendable {
    public static let byteCount = 16

    public var major: UInt32
    public var minor: UInt32
    public var maxReadahead: UInt32
    public var flags: UInt32

    public init(major: UInt32, minor: UInt32, maxReadahead: UInt32, flags: UInt32) {
        self.major = major
        self.minor = minor
        self.maxReadahead = maxReadahead
        self.flags = flags
    }
}

public struct FuseInitOut: Equatable, Sendable {
    public static let byteCount = 64

    public var major: UInt32
    public var minor: UInt32
    public var maxReadahead: UInt32
    public var flags: UInt32
    public var maxBackground: UInt16
    public var congestionThreshold: UInt16
    public var maxWrite: UInt32
    public var timeGranularityNanoseconds: UInt32
    public var maxPages: UInt16
    public var mapAlignment: UInt16

    public init(
        major: UInt32 = FuseProtocol.majorVersion,
        minor: UInt32 = FuseProtocol.minorVersion,
        maxReadahead: UInt32 = 1 << 20,
        flags: UInt32 = FuseInitFlag.asyncRead.rawValue | FuseInitFlag.bigWrites.rawValue | FuseInitFlag.autoInvalidateData.rawValue,
        maxBackground: UInt16 = 64,
        congestionThreshold: UInt16 = 48,
        maxWrite: UInt32 = 1 << 20,
        timeGranularityNanoseconds: UInt32 = 1,
        maxPages: UInt16 = 256,
        mapAlignment: UInt16 = 0
    ) {
        self.major = major
        self.minor = minor
        self.maxReadahead = maxReadahead
        self.flags = flags
        self.maxBackground = maxBackground
        self.congestionThreshold = congestionThreshold
        self.maxWrite = maxWrite
        self.timeGranularityNanoseconds = timeGranularityNanoseconds
        self.maxPages = maxPages
        self.mapAlignment = mapAlignment
    }
}

public struct FuseInitFlag: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let asyncRead = FuseInitFlag(rawValue: 1 << 0)
    public static let bigWrites = FuseInitFlag(rawValue: 1 << 5)
    public static let autoInvalidateData = FuseInitFlag(rawValue: 1 << 12)
    public static let doReaddirplus = FuseInitFlag(rawValue: 1 << 13)
    public static let writebackCache = FuseInitFlag(rawValue: 1 << 16)
    public static let parallelDirops = FuseInitFlag(rawValue: 1 << 18)
    public static let maxPages = FuseInitFlag(rawValue: 1 << 22)
    public static let mapAlignment = FuseInitFlag(rawValue: 1 << 26)
    public static let handleKillprivV2 = FuseInitFlag(rawValue: 1 << 28)
}

public struct FuseGetattrFlag: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// `fuse_getattr_in.fh` identifies the open file whose attributes are requested.
    public static let fileHandle = FuseGetattrFlag(rawValue: 1 << 0)
    public static let allKnown = FuseGetattrFlag.fileHandle
}

/// The fixed-size FUSE 7.x `fuse_getattr_in` payload.
public struct FuseGetattrIn: Equatable, Sendable {
    public static let byteCount = 16

    public var flags: FuseGetattrFlag
    public var fileHandle: UInt64

    public init(flags: FuseGetattrFlag = [], fileHandle: UInt64 = 0) {
        self.flags = flags
        self.fileHandle = fileHandle
    }
}

public struct FuseSetattrValid: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let mode = FuseSetattrValid(rawValue: 1 << 0)
    public static let uid = FuseSetattrValid(rawValue: 1 << 1)
    public static let gid = FuseSetattrValid(rawValue: 1 << 2)
    public static let size = FuseSetattrValid(rawValue: 1 << 3)
    public static let atime = FuseSetattrValid(rawValue: 1 << 4)
    public static let mtime = FuseSetattrValid(rawValue: 1 << 5)
    public static let fileHandle = FuseSetattrValid(rawValue: 1 << 6)
    public static let atimeNow = FuseSetattrValid(rawValue: 1 << 7)
    public static let mtimeNow = FuseSetattrValid(rawValue: 1 << 8)
    public static let lockOwner = FuseSetattrValid(rawValue: 1 << 9)
    public static let ctime = FuseSetattrValid(rawValue: 1 << 10)
    public static let killSuidGid = FuseSetattrValid(rawValue: 1 << 11)

    /// Every SETATTR flag defined by the FUSE 7.38 protocol negotiated by Dory.
    public static let allKnown = FuseSetattrValid(rawValue: (1 << 12) - 1)
}

/// The fixed-size FUSE 7.x `fuse_setattr_in` payload.
///
/// Timestamp seconds are unsigned on the wire but carry a signed `time64_t` bit pattern. Keeping
/// them signed here preserves pre-epoch timestamps while encoding the exact same 64 bits.
public struct FuseSetattrIn: Equatable, Sendable {
    public static let byteCount = 88

    public var valid: FuseSetattrValid
    public var fileHandle: UInt64
    public var size: UInt64
    public var lockOwner: UInt64
    public var atimeSeconds: Int64
    public var mtimeSeconds: Int64
    public var ctimeSeconds: Int64
    public var atimeNsec: UInt32
    public var mtimeNsec: UInt32
    public var ctimeNsec: UInt32
    public var mode: UInt32
    public var uid: UInt32
    public var gid: UInt32

    public init(
        valid: FuseSetattrValid,
        fileHandle: UInt64 = 0,
        size: UInt64 = 0,
        lockOwner: UInt64 = 0,
        atimeSeconds: Int64 = 0,
        mtimeSeconds: Int64 = 0,
        ctimeSeconds: Int64 = 0,
        atimeNsec: UInt32 = 0,
        mtimeNsec: UInt32 = 0,
        ctimeNsec: UInt32 = 0,
        mode: UInt32 = 0,
        uid: UInt32 = 0,
        gid: UInt32 = 0
    ) {
        self.valid = valid
        self.fileHandle = fileHandle
        self.size = size
        self.lockOwner = lockOwner
        self.atimeSeconds = atimeSeconds
        self.mtimeSeconds = mtimeSeconds
        self.ctimeSeconds = ctimeSeconds
        self.atimeNsec = atimeNsec
        self.mtimeNsec = mtimeNsec
        self.ctimeNsec = ctimeNsec
        self.mode = mode
        self.uid = uid
        self.gid = gid
    }
}

public struct FuseSetupMappingIn: Equatable, Sendable {
    public static let byteCount = 40  // fuse_setupmapping_in: fh, foffset, len, flags, moffset (5x u64)

    public var fileHandle: UInt64
    public var fileOffset: UInt64
    public var length: UInt64
    public var flags: UInt64
    public var memoryOffset: UInt64

    public init(fileHandle: UInt64, fileOffset: UInt64, length: UInt64, flags: UInt64, memoryOffset: UInt64) {
        self.fileHandle = fileHandle
        self.fileOffset = fileOffset
        self.length = length
        self.flags = flags
        self.memoryOffset = memoryOffset
    }
}

public struct FuseSetupMappingFlag: OptionSet, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let write = FuseSetupMappingFlag(rawValue: 1 << 0)
    public static let read = FuseSetupMappingFlag(rawValue: 1 << 1)
}

public struct FuseRemoveMappingIn: Equatable, Sendable {
    public static let headerByteCount = 8
    public static let oneByteCount = 16

    public var mappings: [FuseRemoveMappingOne]

    public init(mappings: [FuseRemoveMappingOne]) {
        self.mappings = mappings
    }
}

public struct FuseRemoveMappingOne: Equatable, Sendable {
    public var memoryOffset: UInt64
    public var length: UInt64

    public init(memoryOffset: UInt64, length: UInt64) {
        self.memoryOffset = memoryOffset
        self.length = length
    }
}

public enum FuseProtocol {
    public static let majorVersion: UInt32 = 7
    public static let minorVersion: UInt32 = 38
    public static let minimumMinorVersion: UInt32 = 27
    public static let eproto: Int32 = 71

    // FUSE replies carry Linux errno values, but the server computes with Darwin's <errno.h>.
    // Codes 1...10 and 12...34 are ABI-compatible; EDEADLK and every code from EAGAIN onward are
    // not. Passing a Darwin code through can silently turn one error into an unrelated Linux error.
    // For example, Darwin ENOSYS(78) is Linux EREMCHG(78), preventing the guest's statx->getattr and
    // copy_file_range->read+write fallbacks. Keep this table exhaustive for Darwin's public errno
    // range and fail closed to EIO for future or invalid values.
    public static func linuxErrno(_ darwin: Int32) -> Int32 {
        switch darwin {
        case 0, 1...10, 12...34:
            return darwin
        case EDEADLK: return 35
        case EAGAIN: return 11
        case EINPROGRESS: return 115
        case EALREADY: return 114
        case ENOTSOCK: return 88
        case EDESTADDRREQ: return 89
        case EMSGSIZE: return 90
        case EPROTOTYPE: return 91
        case ENOPROTOOPT: return 92
        case EPROTONOSUPPORT: return 93
        case ESOCKTNOSUPPORT: return 94
        case ENOTSUP: return 95
        case EPFNOSUPPORT: return 96
        case EAFNOSUPPORT: return 97
        case EADDRINUSE: return 98
        case EADDRNOTAVAIL: return 99
        case ENETDOWN: return 100
        case ENETUNREACH: return 101
        case ENETRESET: return 102
        case ECONNABORTED: return 103
        case ECONNRESET: return 104
        case ENOBUFS: return 105
        case EISCONN: return 106
        case ENOTCONN: return 107
        case ESHUTDOWN: return 108
        case ETOOMANYREFS: return 109
        case ETIMEDOUT: return 110
        case ECONNREFUSED: return 111
        case ELOOP: return 40
        case ENAMETOOLONG: return 36
        case EHOSTDOWN: return 112
        case EHOSTUNREACH: return 113
        case ENOTEMPTY: return 39
        case EPROCLIM: return 11              // No Linux equivalent; retryable resource exhaustion.
        case EUSERS: return 87
        case EDQUOT: return 122
        case ESTALE: return 116
        case EREMOTE: return 66
        case EBADRPC, ERPCMISMATCH, EPROGUNAVAIL, EPROGMISMATCH, EPROCUNAVAIL:
            return eproto                    // Darwin RPC-only failures have no direct Linux errno.
        case ENOLCK: return 37
        case ENOSYS: return 38
        case EFTYPE: return 22               // No Linux equivalent; inappropriate file type.
        case EAUTH, ENEEDAUTH: return 13
        case EPWROFF, EDEVERR: return 5
        case EOVERFLOW: return 75
        case EBADEXEC, EBADARCH, ESHLIBVERS, EBADMACHO: return 8
        case ECANCELED: return 125
        case EIDRM: return 43
        case ENOMSG: return 42
        case EILSEQ: return 84
        case ENOATTR, ENODATA: return 61
        case EBADMSG: return 74
        case EMULTIHOP: return 72
        case ENOLINK: return 67
        case ENOSR: return 63
        case ENOSTR: return 60
        case EPROTO: return eproto
        case ETIME: return 62
        case EOPNOTSUPP, ENOPOLICY: return 95
        case ENOTRECOVERABLE: return 131
        case EOWNERDEAD: return 130
        case EQFULL: return 105              // Linux ENOBUFS is the closest queue-capacity error.
        case ENOTCAPABLE: return 13
        default: return 5
        }
    }

    public static func decodeInHeader(_ data: [UInt8]) throws -> FuseInHeader {
        guard data.count >= FuseInHeader.byteCount else { throw FuseProtocolError.shortFrame }
        return FuseInHeader(
            length: data.leUInt32(at: 0),
            opcode: data.leUInt32(at: 4),
            unique: data.leUInt64(at: 8),
            nodeID: data.leUInt64(at: 16),
            uid: data.leUInt32(at: 24),
            gid: data.leUInt32(at: 28),
            pid: data.leUInt32(at: 32),
            totalExtlen: data.leUInt16(at: 36),
            padding: data.leUInt16(at: 38)
        )
    }

    public static func encodeInHeader(_ header: FuseInHeader) -> [UInt8] {
        var data = [UInt8]()
        data.appendLE(header.length)
        data.appendLE(header.opcode)
        data.appendLE(header.unique)
        data.appendLE(header.nodeID)
        data.appendLE(header.uid)
        data.appendLE(header.gid)
        data.appendLE(header.pid)
        data.appendLE(header.totalExtlen)
        data.appendLE(header.padding)
        return data
    }

    public static func encodeOutHeader(_ header: FuseOutHeader) -> [UInt8] {
        var data = [UInt8]()
        data.appendLE(header.length)
        data.appendLE(UInt32(bitPattern: header.error))
        data.appendLE(header.unique)
        return data
    }

    public static func decodeOutHeader(_ data: [UInt8]) throws -> FuseOutHeader {
        guard data.count >= FuseOutHeader.byteCount else { throw FuseProtocolError.shortFrame }
        return FuseOutHeader(
            length: data.leUInt32(at: 0),
            error: Int32(bitPattern: data.leUInt32(at: 4)),
            unique: data.leUInt64(at: 8)
        )
    }

    public static func decodeInitIn(_ data: [UInt8]) throws -> FuseInitIn {
        guard data.count >= FuseInitIn.byteCount else { throw FuseProtocolError.shortFrame }
        return FuseInitIn(
            major: data.leUInt32(at: 0),
            minor: data.leUInt32(at: 4),
            maxReadahead: data.leUInt32(at: 8),
            flags: data.leUInt32(at: 12)
        )
    }

    public static func decodeGetattrIn(_ data: [UInt8]) throws -> FuseGetattrIn {
        try decodeGetattrIn(data[...])
    }

    public static func decodeGetattrIn(_ data: ArraySlice<UInt8>) throws -> FuseGetattrIn {
        guard data.count >= FuseGetattrIn.byteCount else { throw FuseProtocolError.shortFrame }
        return FuseGetattrIn(
            flags: FuseGetattrFlag(rawValue: data.leUInt32(at: 0)),
            fileHandle: data.leUInt64(at: 8)
        )
    }

    public static func encodeGetattrIn(_ value: FuseGetattrIn) -> [UInt8] {
        var data = [UInt8]()
        data.reserveCapacity(FuseGetattrIn.byteCount)
        data.appendLE(value.flags.rawValue)
        data.appendLE(UInt32(0))
        data.appendLE(value.fileHandle)
        return data
    }

    public static func decodeSetattrIn(_ data: [UInt8]) throws -> FuseSetattrIn {
        guard data.count >= FuseSetattrIn.byteCount else { throw FuseProtocolError.shortFrame }
        return FuseSetattrIn(
            valid: FuseSetattrValid(rawValue: data.leUInt32(at: 0)),
            fileHandle: data.leUInt64(at: 8),
            size: data.leUInt64(at: 16),
            lockOwner: data.leUInt64(at: 24),
            atimeSeconds: Int64(bitPattern: data.leUInt64(at: 32)),
            mtimeSeconds: Int64(bitPattern: data.leUInt64(at: 40)),
            ctimeSeconds: Int64(bitPattern: data.leUInt64(at: 48)),
            atimeNsec: data.leUInt32(at: 56),
            mtimeNsec: data.leUInt32(at: 60),
            ctimeNsec: data.leUInt32(at: 64),
            mode: data.leUInt32(at: 68),
            uid: data.leUInt32(at: 76),
            gid: data.leUInt32(at: 80)
        )
    }

    public static func encodeSetattrIn(_ value: FuseSetattrIn) -> [UInt8] {
        var data = [UInt8]()
        data.reserveCapacity(FuseSetattrIn.byteCount)
        data.appendLE(value.valid.rawValue)
        data.appendLE(UInt32(0))
        data.appendLE(value.fileHandle)
        data.appendLE(value.size)
        data.appendLE(value.lockOwner)
        data.appendLE(UInt64(bitPattern: value.atimeSeconds))
        data.appendLE(UInt64(bitPattern: value.mtimeSeconds))
        data.appendLE(UInt64(bitPattern: value.ctimeSeconds))
        data.appendLE(value.atimeNsec)
        data.appendLE(value.mtimeNsec)
        data.appendLE(value.ctimeNsec)
        data.appendLE(value.mode)
        data.appendLE(UInt32(0))
        data.appendLE(value.uid)
        data.appendLE(value.gid)
        data.appendLE(UInt32(0))
        return data
    }

    public static func decodeForgetIn(_ data: [UInt8]) throws -> FuseForgetIn {
        guard data.count >= FuseForgetIn.byteCount else { throw FuseProtocolError.shortFrame }
        return FuseForgetIn(lookupCount: data.leUInt64(at: 0))
    }

    public static func encodeForgetIn(_ value: FuseForgetIn) -> [UInt8] {
        var data = [UInt8]()
        data.appendLE(value.lookupCount)
        return data
    }

    public static func decodeBatchForgetIn(_ data: [UInt8]) throws -> FuseBatchForgetIn {
        guard data.count >= FuseBatchForgetIn.headerByteCount else { throw FuseProtocolError.shortFrame }
        let count = Int(data.leUInt32(at: 0))
        guard count <= (data.count - FuseBatchForgetIn.headerByteCount) / FuseForgetOne.byteCount else {
            throw FuseProtocolError.shortFrame
        }
        var entries = [FuseForgetOne]()
        entries.reserveCapacity(count)
        var offset = FuseBatchForgetIn.headerByteCount
        for _ in 0..<count {
            entries.append(FuseForgetOne(
                nodeID: data.leUInt64(at: offset),
                lookupCount: data.leUInt64(at: offset + 8)
            ))
            offset += FuseForgetOne.byteCount
        }
        return FuseBatchForgetIn(entries: entries)
    }

    public static func encodeBatchForgetIn(_ value: FuseBatchForgetIn) -> [UInt8] {
        var data = [UInt8]()
        data.appendLE(UInt32(value.entries.count))
        data.appendLE(UInt32(0))
        for entry in value.entries {
            data.appendLE(entry.nodeID)
            data.appendLE(entry.lookupCount)
        }
        return data
    }

    public static func encodeInitOut(_ value: FuseInitOut) -> [UInt8] {
        var data = [UInt8]()
        data.appendLE(value.major)
        data.appendLE(value.minor)
        data.appendLE(value.maxReadahead)
        data.appendLE(value.flags)
        data.appendLE(value.maxBackground)
        data.appendLE(value.congestionThreshold)
        data.appendLE(value.maxWrite)
        data.appendLE(value.timeGranularityNanoseconds)
        data.appendLE(value.maxPages)
        data.appendLE(value.mapAlignment)
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt16(0))
        for _ in 0..<11 {
            data.appendLE(UInt16(0))
        }
        return data
    }

    public static func negotiateInit(
        header: FuseInHeader,
        request: FuseInitIn,
        daxMapAlignmentLog2: UInt16? = nil,
        writebackCache: Bool = false,
        killPrivV2: Bool = false
    ) -> [UInt8] {
        guard request.minor >= minimumMinorVersion else {
            return encodeOutHeader(FuseOutHeader(length: UInt32(FuseOutHeader.byteCount), error: -eproto, unique: header.unique))
        }
        // FUSE_AUTO_INVAL_DATA is safe to advertise ONLY because getattr now reports real mtime
        // nanoseconds: under this flag the kernel drops the page cache whenever a cached read sees a
        // changed mtime, and previously every attr carried mtime_nsec=0, so an unchanged host file
        // still looked modified on each revalidation and lost its cache — collapsing reads to a FUSE
        // round-trip per 4 KiB. With correct nsecs it invalidates only on a genuine host change.
        // DO_READDIRPLUS (without READDIRPLUS_AUTO) forces the guest to use FUSE_READDIRPLUS, which
        // the server handles, for every directory read. Plain FUSE_READDIR is NOT handled, so
        // advertising AUTO — which lets the kernel fall back to plain readdir — would make some
        // `ls` calls list an empty directory. Force readdirplus until plain readdir is implemented.
        var flags = FuseInitFlag.asyncRead.rawValue | FuseInitFlag.bigWrites.rawValue
            | FuseInitFlag.autoInvalidateData.rawValue | FuseInitFlag.maxPages.rawValue
            | FuseInitFlag.doReaddirplus.rawValue | FuseInitFlag.parallelDirops.rawValue
        if writebackCache {
            // WRITEBACK_CACHE lets the guest coalesce buffered writes, removing the per-write round
            // trip on the create storm. Linux ignores FOPEN_NOFLUSH while it is enabled; the runtime
            // keeps an env opt-out (DORY_FUSE_WRITEBACK_CACHE=0) for the durability-strict benchmark arm.
            flags |= FuseInitFlag.writebackCache.rawValue
        }
        if killPrivV2 {
            // HANDLE_KILLPRIV_V2 delegates suid/sgid + security.capability clearing to the server, so
            // the kernel skips the pre-write SETATTR/GETXATTR probe. The write path honors
            // FUSE_WRITE_KILL_SUIDGID (and truncate clears the bits) to keep the contract correct.
            flags |= FuseInitFlag.handleKillprivV2.rawValue
        }
        if daxMapAlignmentLog2 != nil {
            flags |= FuseInitFlag.mapAlignment.rawValue
        }
        let response = FuseInitOut(
            major: majorVersion,
            minor: min(request.minor, minorVersion),
            maxReadahead: request.maxReadahead,
            flags: flags,
            mapAlignment: daxMapAlignmentLog2 ?? 0
        )
        return encodeOutHeader(FuseOutHeader(
            length: UInt32(FuseOutHeader.byteCount + FuseInitOut.byteCount),
            error: 0,
            unique: header.unique
        )) + encodeInitOut(response)
    }

    public static func decodeSetupMappingIn(_ data: [UInt8]) throws -> FuseSetupMappingIn {
        guard data.count >= FuseSetupMappingIn.byteCount else { throw FuseProtocolError.shortFrame }
        return FuseSetupMappingIn(
            fileHandle: data.leUInt64(at: 0),
            fileOffset: data.leUInt64(at: 8),
            length: data.leUInt64(at: 16),
            flags: data.leUInt64(at: 24),
            memoryOffset: data.leUInt64(at: 32)
        )
    }

    public static func encodeSetupMappingIn(_ value: FuseSetupMappingIn) -> [UInt8] {
        var data = [UInt8]()
        data.appendLE(value.fileHandle)
        data.appendLE(value.fileOffset)
        data.appendLE(value.length)
        data.appendLE(value.flags)
        data.appendLE(value.memoryOffset)
        return data
    }

    public static func decodeRemoveMappingIn(_ data: [UInt8]) throws -> FuseRemoveMappingIn {
        guard data.count >= FuseRemoveMappingIn.headerByteCount else { throw FuseProtocolError.shortFrame }
        let count = Int(data.leUInt32(at: 0))
        let expected = FuseRemoveMappingIn.headerByteCount + count * FuseRemoveMappingIn.oneByteCount
        guard data.count >= expected else { throw FuseProtocolError.shortFrame }
        var mappings = [FuseRemoveMappingOne]()
        mappings.reserveCapacity(count)
        var offset = FuseRemoveMappingIn.headerByteCount
        for _ in 0..<count {
            mappings.append(FuseRemoveMappingOne(
                memoryOffset: data.leUInt64(at: offset),
                length: data.leUInt64(at: offset + 8)
            ))
            offset += FuseRemoveMappingIn.oneByteCount
        }
        return FuseRemoveMappingIn(mappings: mappings)
    }

    public static func encodeRemoveMappingIn(_ value: FuseRemoveMappingIn) -> [UInt8] {
        var data = [UInt8]()
        data.appendLE(UInt32(value.mappings.count))
        data.appendLE(UInt32(0))
        for mapping in value.mappings {
            data.appendLE(mapping.memoryOffset)
            data.appendLE(mapping.length)
        }
        return data
    }
}
