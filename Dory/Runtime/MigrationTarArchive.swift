import Foundation

enum MigrationTarArchiveError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(detail): "invalid Docker archive: \(detail)"
        }
    }
}

/// Strictly extracts one expected regular file from Docker's tar response. Metadata-only tar
/// records are accepted, but links, devices, path traversal, duplicate files, and trailing data
/// fail closed before any manifest bytes are trusted.
enum MigrationTarArchive {
    static let blockBytes = 512
    static let maximumManifestArchiveBytes = MigrationVolumeManifest.maximumBytes + 16 * 1_024 * 1_024

    static func extractSingleRegularFile(
        named expectedName: String,
        from archive: Data
    ) throws -> Data {
        guard !archive.isEmpty, archive.count <= maximumManifestArchiveBytes,
              archive.count.isMultiple(of: blockBytes),
              isSafeRelativePath(expectedName) else {
            throw MigrationTarArchiveError.invalid("archive size or expected path is invalid")
        }
        var parser = Parser(archive: archive, expectedName: expectedName)
        return try parser.parse()
    }
}

private extension MigrationTarArchive {
    struct PendingMetadata {
        var path: String?
        var size: Int?

        mutating func reset() {
            path = nil
            size = nil
        }
    }

    struct Parser {
        let archive: Data
        let expectedName: String
        var offset = 0
        var pending = PendingMetadata()
        var extracted: Data?
        var sawTerminator = false

        mutating func parse() throws -> Data {
            while offset + blockBytes <= archive.count {
                let headerRange = offset..<(offset + blockBytes)
                let header = archive[headerRange]
                if header.allSatisfy({ $0 == 0 }) {
                    let secondStart = offset + blockBytes
                    let secondEnd = secondStart + blockBytes
                    guard secondEnd <= archive.count,
                          archive[secondStart..<secondEnd].allSatisfy({ $0 == 0 }) else {
                        throw MigrationTarArchiveError.invalid("tar terminator is incomplete")
                    }
                    sawTerminator = true
                    offset = secondEnd
                    break
                }
                try validateChecksum(header)
                let headerSize = try parseTarNumber(header, range: 124..<136)
                let contentStart = offset + blockBytes
                let (contentEnd, overflow) = contentStart.addingReportingOverflow(headerSize)
                guard !overflow, contentEnd <= archive.count else {
                    throw MigrationTarArchiveError.invalid("entry payload is truncated")
                }
                let type = archive[offset + 156]
                let rawName = try headerPath(header)
                let payload = archive[contentStart..<contentEnd]
                try consume(type: type, rawName: rawName, headerSize: headerSize, payload: payload)
                let padded = try paddedSize(headerSize)
                let (next, nextOverflow) = contentStart.addingReportingOverflow(padded)
                guard !nextOverflow, next <= archive.count else {
                    throw MigrationTarArchiveError.invalid("entry padding is truncated")
                }
                offset = next
            }
            guard sawTerminator, archive[offset...].allSatisfy({ $0 == 0 }), let extracted else {
                throw MigrationTarArchiveError.invalid("missing terminator or expected regular file")
            }
            return extracted
        }

        mutating func consume(
            type: UInt8,
            rawName: String,
            headerSize: Int,
            payload: Data.SubSequence
        ) throws {
            switch type {
            case 0, UInt8(ascii: "0"):
                try consumeRegular(rawName: rawName, headerSize: headerSize, payload: payload)
            case UInt8(ascii: "x"):
                try consumePAX(payload)
            case UInt8(ascii: "L"):
                try consumeLongName(payload)
            case UInt8(ascii: "5"):
                try requireNoPendingMetadata()
            case UInt8(ascii: "g"):
                throw MigrationTarArchiveError.invalid("global PAX metadata is not accepted")
            default:
                throw MigrationTarArchiveError.invalid("unsupported tar entry type \(type)")
            }
        }

        mutating func consumeRegular(
            rawName: String,
            headerSize: Int,
            payload: Data.SubSequence
        ) throws {
            let path = pending.path ?? rawName
            let size = pending.size ?? headerSize
            guard size == headerSize, isSafeRelativePath(path), path == expectedName,
                  extracted == nil else {
                throw MigrationTarArchiveError.invalid(
                    "archive contains an unexpected, duplicate, or size-mismatched file"
                )
            }
            extracted = Data(payload)
            pending.reset()
        }

        mutating func consumePAX(_ payload: Data.SubSequence) throws {
            try requireNoPendingMetadata()
            pending = try parsePAX(payload)
        }

        mutating func consumeLongName(_ payload: Data.SubSequence) throws {
            guard pending.path == nil else {
                throw MigrationTarArchiveError.invalid("stacked long-name records")
            }
            let bytes = payload.prefix { $0 != 0 }
            guard let path = String(bytes: bytes, encoding: .utf8), isSafeRelativePath(path) else {
                throw MigrationTarArchiveError.invalid("GNU long name is unsafe")
            }
            pending.path = path
        }

        func requireNoPendingMetadata() throws {
            guard pending.path == nil, pending.size == nil else {
                throw MigrationTarArchiveError.invalid("metadata record was not consumed")
            }
        }

        func validateChecksum(_ header: Data.SubSequence) throws {
            let stored = try parseTarNumber(header, range: 148..<156)
            var sum = 0
            for index in 0..<blockBytes {
                sum += (148..<156).contains(index) ? 32 : Int(header[header.startIndex + index])
            }
            guard stored == sum else {
                throw MigrationTarArchiveError.invalid("header checksum mismatch")
            }
        }

        func headerPath(_ header: Data.SubSequence) throws -> String {
            let name = try nullTerminatedUTF8(header, range: 0..<100)
            let prefix = try nullTerminatedUTF8(header, range: 345..<500)
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            guard isSafeRelativePath(path) else {
                throw MigrationTarArchiveError.invalid("entry path is unsafe")
            }
            return path
        }

        func nullTerminatedUTF8(
            _ header: Data.SubSequence,
            range: Range<Int>
        ) throws -> String {
            let field = header[(header.startIndex + range.lowerBound)..<(header.startIndex + range.upperBound)]
            let content = field.prefix { $0 != 0 }
            guard let value = String(bytes: content, encoding: .utf8) else {
                throw MigrationTarArchiveError.invalid("header path is not UTF-8")
            }
            return value
        }

        func parseTarNumber(
            _ header: Data.SubSequence,
            range: Range<Int>
        ) throws -> Int {
            let field = header[(header.startIndex + range.lowerBound)..<(header.startIndex + range.upperBound)]
            guard field.first.map({ $0 & 0x80 == 0 }) ?? false else {
                throw MigrationTarArchiveError.invalid("base-256 tar numbers are not accepted")
            }
            guard let encoded = String(bytes: field, encoding: .utf8) else {
                throw MigrationTarArchiveError.invalid("tar number is not UTF-8")
            }
            let text = encoded.trimmingCharacters(in: CharacterSet(charactersIn: " \u{0}"))
            guard text.allSatisfy({ ("0"..."7").contains($0) }),
                  let value = text.isEmpty ? 0 : Int(text, radix: 8), value >= 0 else {
                throw MigrationTarArchiveError.invalid("tar number is malformed")
            }
            return value
        }

        func paddedSize(_ size: Int) throws -> Int {
            let (adjusted, overflow) = size.addingReportingOverflow(blockBytes - 1)
            guard !overflow else { throw MigrationTarArchiveError.invalid("entry size overflows") }
            return adjusted / blockBytes * blockBytes
        }

        func parsePAX(_ payload: Data.SubSequence) throws -> PendingMetadata {
            var metadata = PendingMetadata()
            var cursor = payload.startIndex
            while cursor < payload.endIndex {
                guard let space = payload[cursor...].firstIndex(of: UInt8(ascii: " ")),
                      let lengthText = String(bytes: payload[cursor..<space], encoding: .utf8),
                      let length = Int(lengthText),
                      length > 0 else {
                    throw MigrationTarArchiveError.invalid("PAX record length is malformed")
                }
                let (recordEnd, overflow) = cursor.addingReportingOverflow(length)
                guard !overflow, recordEnd <= payload.endIndex,
                      payload[recordEnd - 1] == UInt8(ascii: "\n") else {
                    throw MigrationTarArchiveError.invalid("PAX record is truncated")
                }
                let valueStart = space + 1
                let record = payload[valueStart..<(recordEnd - 1)]
                guard let equals = record.firstIndex(of: UInt8(ascii: "=")),
                      let key = String(bytes: record[..<equals], encoding: .utf8),
                      let value = String(bytes: record[(equals + 1)...], encoding: .utf8) else {
                    throw MigrationTarArchiveError.invalid("PAX record is malformed")
                }
                switch key {
                case "path":
                    guard metadata.path == nil, isSafeRelativePath(value) else {
                        throw MigrationTarArchiveError.invalid("PAX path is duplicate or unsafe")
                    }
                    metadata.path = value
                case "size":
                    guard metadata.size == nil, let size = Int(value), size >= 0 else {
                        throw MigrationTarArchiveError.invalid("PAX size is duplicate or invalid")
                    }
                    metadata.size = size
                case "atime", "ctime", "mtime", "SCHILY.xattr":
                    break
                default:
                    // Docker may attach implementation metadata. It cannot alter extraction unless
                    // it is one of the explicitly handled path/size fields above.
                    break
                }
                cursor = recordEnd
            }
            return metadata
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
