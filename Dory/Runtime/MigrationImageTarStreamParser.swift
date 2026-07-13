import CryptoKit
import Foundation

nonisolated struct MigrationImageTarStreamParser {
    static let maximumArchiveBytes: UInt64 = 160 * 1_024 * 1_024 * 1_024
    static let maximumEntryBytes: UInt64 = 128 * 1_024 * 1_024 * 1_024
    static let maximumMetadataBytes: UInt64 = 1 * 1_024 * 1_024
    static let maximumCapturedMetadataBytes: UInt64 = 64 * 1_024 * 1_024
    static let maximumEntries = 100_000

    private enum EntryRole {
        case regular
        case directory
        case pax
        case longName
    }

    private struct ActiveEntry {
        let role: EntryRole
        let path: String
        let logicalBytes: UInt64
        var remainingBytes: UInt64
        var hasher = SHA256()
        var capture: Data?
        let captureOnlyJSONObject: Bool
    }

    private var buffer = Data()
    private var cursor = 0
    private var active: ActiveEntry?
    private var paddingBytes: UInt64 = 0
    private var pending = MigrationImageTarPendingMetadata()
    private var entries: [String: MigrationImageTarEntry] = [:]
    private var capturedEntries: [String: Data] = [:]
    private var capturedMetadataBytes: UInt64 = 0
    private var manifest: Data?
    private var zeroBlocks = 0
    private var terminated = false
    private var archiveBytes: UInt64 = 0

    mutating func feed(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let addition = archiveBytes.addingReportingOverflow(UInt64(data.count))
        guard !addition.overflow, addition.partialValue <= Self.maximumArchiveBytes else {
            throw MigrationImageArchiveError.invalid("archive exceeds its qualified size limit")
        }
        archiveBytes = addition.partialValue
        buffer.append(data)
        try process()
        compactBuffer()
    }

    mutating func finish() throws -> MigrationImageTarArchive {
        try process()
        guard terminated,
              active == nil,
              paddingBytes == 0,
              pending.isEmpty,
              cursor == buffer.count,
              let manifest else {
            throw MigrationImageArchiveError.invalid("archive is truncated or has no manifest.json")
        }
        return MigrationImageTarArchive(
            entries: entries,
            capturedEntries: capturedEntries,
            manifest: manifest,
            archiveBytes: archiveBytes
        )
    }
}

private extension MigrationImageTarStreamParser {
    nonisolated mutating func process() throws {
        while true {
            if terminated {
                guard buffer[cursor...].allSatisfy({ $0 == 0 }) else {
                    throw MigrationImageArchiveError.invalid("archive has data after its terminator")
                }
                cursor = buffer.count
                return
            }
            if active != nil {
                guard try consumeActive() else { return }
                continue
            }
            if paddingBytes > 0 {
                guard try consumePadding() else { return }
                continue
            }
            guard try consumeHeader() else { return }
        }
    }

    nonisolated mutating func consumeHeader() throws -> Bool {
        guard buffer.count - cursor >= MigrationImageTarHeaderDecoder.blockBytes else { return false }
        let end = cursor + MigrationImageTarHeaderDecoder.blockBytes
        let header = buffer[cursor..<end]
        cursor = end
        if header.allSatisfy({ $0 == 0 }) {
            zeroBlocks += 1
            if zeroBlocks == 2 { terminated = true }
            return true
        }
        guard zeroBlocks == 0 else {
            throw MigrationImageArchiveError.invalid("tar terminator is incomplete")
        }
        try begin(MigrationImageTarHeaderDecoder.decode(header))
        return true
    }

    nonisolated mutating func begin(_ header: MigrationImageTarHeader) throws {
        let role = try role(for: header.type)
        if role == .pax || role == .longName {
            guard pending.isEmpty, header.size <= Self.maximumMetadataBytes else {
                throw MigrationImageArchiveError.invalid("tar metadata is stacked or too large")
            }
            active = ActiveEntry(
                role: role,
                path: header.path,
                logicalBytes: header.size,
                remainingBytes: header.size,
                capture: Data(),
                captureOnlyJSONObject: false
            )
            try finalizeEmptyActiveIfNeeded()
            return
        }
        let rawPath = pending.path ?? header.path
        let size = pending.size ?? header.size
        pending.reset()
        let path = try normalizedPath(rawPath, directory: role == .directory)
        guard size <= Self.maximumEntryBytes,
              entries[path] == nil,
              entries.count < Self.maximumEntries else {
            throw MigrationImageArchiveError.invalid("tar entry is duplicate or exceeds limits")
        }
        if role == .directory, size != 0 {
            throw MigrationImageArchiveError.invalid("directory entry has a payload")
        }
        let capturesPayload = try shouldCapturePayload(path: path, size: size, role: role)
        active = ActiveEntry(
            role: role,
            path: path,
            logicalBytes: size,
            remainingBytes: size,
            capture: capturesPayload ? Data() : nil,
            captureOnlyJSONObject: isContentAddressedBlob(path)
        )
        try finalizeEmptyActiveIfNeeded()
    }

    nonisolated private func role(for type: UInt8) throws -> EntryRole {
        switch type {
        case 0, UInt8(ascii: "0"): .regular
        case UInt8(ascii: "5"): .directory
        case UInt8(ascii: "x"): .pax
        case UInt8(ascii: "L"): .longName
        case UInt8(ascii: "g"):
            throw MigrationImageArchiveError.invalid("global PAX metadata is not accepted")
        default:
            throw MigrationImageArchiveError.invalid("unsupported outer tar entry type \(type)")
        }
    }

    nonisolated mutating func consumeActive() throws -> Bool {
        guard var entry = active else { return true }
        guard entry.remainingBytes > 0 else {
            try finalizeActive(entry)
            return true
        }
        let available = buffer.count - cursor
        guard available > 0 else { return false }
        let count = entry.remainingBytes > UInt64(available)
            ? available
            : Int(entry.remainingBytes)
        let end = cursor + count
        let bytes = buffer[cursor..<end]
        if entry.role == .regular { entry.hasher.update(data: bytes) }
        entry.capture?.append(bytes)
        if entry.captureOnlyJSONObject,
           let capture = entry.capture,
           let first = capture.first(where: { !Self.jsonWhitespace.contains($0) }),
           first != UInt8(ascii: "{") {
            entry.capture = nil
        }
        entry.remainingBytes -= UInt64(count)
        cursor = end
        active = entry
        if entry.remainingBytes == 0 { try finalizeActive(entry) }
        return true
    }

    nonisolated mutating func finalizeEmptyActiveIfNeeded() throws {
        if let active, active.remainingBytes == 0 { try finalizeActive(active) }
    }

    nonisolated private mutating func finalizeActive(_ entry: ActiveEntry) throws {
        switch entry.role {
        case .regular:
            let hasher = entry.hasher
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            entries[entry.path] = MigrationImageTarEntry(
                path: entry.path,
                kind: .regular,
                logicalBytes: entry.logicalBytes,
                sha256: digest
            )
            if entry.path == "manifest.json" {
                guard manifest == nil, let capture = entry.capture else {
                    throw MigrationImageArchiveError.invalid("manifest.json is duplicated")
                }
                manifest = capture
            }
            if let capture = entry.capture {
                let total = capturedMetadataBytes.addingReportingOverflow(UInt64(capture.count))
                guard !total.overflow, total.partialValue <= Self.maximumCapturedMetadataBytes else {
                    throw MigrationImageArchiveError.invalid("captured archive metadata exceeds its limit")
                }
                capturedMetadataBytes = total.partialValue
                capturedEntries[entry.path] = capture
            }
        case .directory:
            entries[entry.path] = MigrationImageTarEntry(
                path: entry.path,
                kind: .directory,
                logicalBytes: 0,
                sha256: nil
            )
        case .pax:
            guard let capture = entry.capture else {
                throw MigrationImageArchiveError.invalid("PAX metadata disappeared")
            }
            pending = try MigrationImageTarHeaderDecoder.parsePAX(capture)
        case .longName:
            guard let capture = entry.capture else {
                throw MigrationImageArchiveError.invalid("GNU long name disappeared")
            }
            pending.path = try MigrationImageTarHeaderDecoder.parseLongName(capture)
        }
        paddingBytes = padding(for: entry.logicalBytes)
        active = nil
    }

    nonisolated mutating func consumePadding() throws -> Bool {
        let available = buffer.count - cursor
        guard available > 0 else { return false }
        let count = paddingBytes > UInt64(available) ? available : Int(paddingBytes)
        let end = cursor + count
        guard buffer[cursor..<end].allSatisfy({ $0 == 0 }) else {
            throw MigrationImageArchiveError.invalid("tar entry padding is not zero-filled")
        }
        cursor = end
        paddingBytes -= UInt64(count)
        return true
    }

    nonisolated func padding(for size: UInt64) -> UInt64 {
        let remainder = size % UInt64(MigrationImageTarHeaderDecoder.blockBytes)
        return remainder == 0 ? 0 : UInt64(MigrationImageTarHeaderDecoder.blockBytes) - remainder
    }

    nonisolated func normalizedPath(_ raw: String, directory: Bool) throws -> String {
        let path = directory && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              path.utf8.count <= 4_096, !path.utf8.contains(0),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw MigrationImageArchiveError.invalid("tar entry path is unsafe")
        }
        return path
    }

    nonisolated private func shouldCapturePayload(
        path: String,
        size: UInt64,
        role: EntryRole
    ) throws -> Bool {
        guard role == .regular else { return false }
        let isManifest = path == "manifest.json"
        let isRootJSON = !path.contains("/") && path.hasSuffix(".json")
        let isBlob = isContentAddressedBlob(path)
        guard isManifest || isRootJSON || isBlob else { return false }
        if isManifest || isRootJSON {
            guard size <= MigrationImageArchiveManifest.maximumManifestBytes else {
                throw MigrationImageArchiveError.invalid("captured archive metadata exceeds its size limit")
            }
            return true
        }
        return size <= MigrationImageArchiveManifest.maximumManifestBytes
    }

    nonisolated func isContentAddressedBlob(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 3
            && components[0] == "blobs"
            && components[1] == "sha256"
    }

    nonisolated mutating func compactBuffer() {
        guard cursor > 0, cursor == buffer.count || cursor >= 1_024 * 1_024 else { return }
        buffer.removeSubrange(buffer.startIndex..<cursor)
        cursor = 0
    }
}

private extension MigrationImageTarStreamParser {
    nonisolated static let jsonWhitespace: Set<UInt8> = [9, 10, 13, 32]
}
