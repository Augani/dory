import Foundation

nonisolated struct MigrationImageTarHeader {
    let path: String
    let size: UInt64
    let type: UInt8
}

nonisolated struct MigrationImageTarPendingMetadata {
    var path: String?
    var size: UInt64?

    var isEmpty: Bool { path == nil && size == nil }

    mutating func reset() {
        path = nil
        size = nil
    }
}

nonisolated enum MigrationImageTarHeaderDecoder {
    static let blockBytes = 512

    static func decode(_ header: Data.SubSequence) throws -> MigrationImageTarHeader {
        guard header.count == blockBytes else {
            throw MigrationImageArchiveError.invalid("tar header is truncated")
        }
        try validateChecksum(header)
        return MigrationImageTarHeader(
            path: try headerPath(header),
            size: try number(header, range: 124..<136),
            type: header[header.startIndex + 156]
        )
    }

    static func parsePAX(_ payload: Data) throws -> MigrationImageTarPendingMetadata {
        var metadata = MigrationImageTarPendingMetadata()
        var cursor = payload.startIndex
        while cursor < payload.endIndex {
            let record = try decodePAXRecord(payload, cursor: cursor)
            switch record.key {
            case "path":
                guard metadata.path == nil else {
                    throw MigrationImageArchiveError.invalid("PAX path is duplicated")
                }
                metadata.path = record.value
            case "size":
                guard metadata.size == nil, let size = UInt64(record.value) else {
                    throw MigrationImageArchiveError.invalid("PAX size is invalid")
                }
                metadata.size = size
            case "atime", "ctime", "mtime":
                break
            case let key where key.hasPrefix("GNU.sparse.")
                || key == "SCHILY.realsize"
                || key == "SCHILY.xattr"
                || key.hasPrefix("SCHILY.xattr."):
                throw MigrationImageArchiveError.invalid("sparse and xattr PAX metadata is not accepted")
            default:
                break
            }
            cursor = record.end
        }
        return metadata
    }

    static func parseLongName(_ payload: Data) throws -> String {
        guard let terminator = payload.firstIndex(of: 0),
              payload[terminator...].allSatisfy({ $0 == 0 }),
              let path = String(bytes: payload[..<terminator], encoding: .utf8),
              !path.isEmpty else {
            throw MigrationImageArchiveError.invalid("GNU long name is malformed")
        }
        return path
    }
}

private extension MigrationImageTarHeaderDecoder {
    nonisolated static func decodePAXRecord(
        _ payload: Data,
        cursor: Data.Index
    ) throws -> MigrationImagePAXRecord {
        guard let space = payload[cursor...].firstIndex(of: UInt8(ascii: " ")),
              let lengthText = String(bytes: payload[cursor..<space], encoding: .utf8),
              !lengthText.isEmpty,
              lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
              lengthText.first != "0",
              let length = Int(lengthText), length > 0 else {
            throw MigrationImageArchiveError.invalid("PAX record length is malformed")
        }
        let (recordEnd, overflow) = cursor.addingReportingOverflow(length)
        guard !overflow, recordEnd <= payload.endIndex,
              space < recordEnd - 2,
              payload[recordEnd - 1] == UInt8(ascii: "\n") else {
            throw MigrationImageArchiveError.invalid("PAX record is truncated")
        }
        let record = payload[(space + 1)..<(recordEnd - 1)]
        guard let equals = record.firstIndex(of: UInt8(ascii: "=")),
              let key = String(bytes: record[..<equals], encoding: .utf8),
              let value = String(bytes: record[(equals + 1)...], encoding: .utf8) else {
            throw MigrationImageArchiveError.invalid("PAX record is malformed")
        }
        return MigrationImagePAXRecord(key: key, value: value, end: recordEnd)
    }

    nonisolated static func validateChecksum(_ header: Data.SubSequence) throws {
        let stored = try number(header, range: 148..<156)
        var sum: UInt64 = 0
        for index in 0..<blockBytes {
            sum += (148..<156).contains(index)
                ? 32
                : UInt64(header[header.startIndex + index])
        }
        guard stored == sum else {
            throw MigrationImageArchiveError.invalid("tar header checksum mismatch")
        }
    }

    nonisolated static func headerPath(_ header: Data.SubSequence) throws -> String {
        let name = try text(header, range: 0..<100)
        let prefix = try text(header, range: 345..<500)
        let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.utf8.contains(0) else {
            throw MigrationImageArchiveError.invalid("tar header path is invalid")
        }
        return path
    }

    nonisolated static func text(
        _ header: Data.SubSequence,
        range: Range<Int>
    ) throws -> String {
        let field = header[
            (header.startIndex + range.lowerBound)..<(header.startIndex + range.upperBound)
        ]
        let content = field.prefix { $0 != 0 }
        guard let value = String(bytes: content, encoding: .utf8) else {
            throw MigrationImageArchiveError.invalid("tar header text is not UTF-8")
        }
        return value
    }

    nonisolated static func number(
        _ header: Data.SubSequence,
        range: Range<Int>
    ) throws -> UInt64 {
        let field = header[
            (header.startIndex + range.lowerBound)..<(header.startIndex + range.upperBound)
        ]
        guard let first = field.first else {
            throw MigrationImageArchiveError.invalid("tar number is empty")
        }
        if first & 0x80 != 0 { return try base256(field) }
        guard let encoded = String(bytes: field, encoding: .utf8) else {
            throw MigrationImageArchiveError.invalid("tar number is not UTF-8")
        }
        let text = encoded.trimmingCharacters(in: CharacterSet(charactersIn: " \u{0}"))
        guard text.allSatisfy({ ("0"..."7").contains($0) }),
              let value = text.isEmpty ? 0 : UInt64(text, radix: 8) else {
            throw MigrationImageArchiveError.invalid("tar number is malformed")
        }
        return value
    }

    nonisolated static func base256(_ field: Data.SubSequence) throws -> UInt64 {
        guard let first = field.first, first & 0x40 == 0 else {
            throw MigrationImageArchiveError.invalid("negative base-256 tar number")
        }
        var result: UInt64 = 0
        for (index, byte) in field.enumerated() {
            let value = index == 0 ? byte & 0x7f : byte
            let multiplication = result.multipliedReportingOverflow(by: 256)
            let addition = multiplication.partialValue.addingReportingOverflow(UInt64(value))
            guard !multiplication.overflow, !addition.overflow else {
                throw MigrationImageArchiveError.invalid("base-256 tar number overflows")
            }
            result = addition.partialValue
        }
        return result
    }
}

private nonisolated struct MigrationImagePAXRecord {
    let key: String
    let value: String
    let end: Data.Index
}
