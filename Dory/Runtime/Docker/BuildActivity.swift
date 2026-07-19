import Foundation

nonisolated struct BuildActivityRecord: Identifiable, Sendable, Equatable, Decodable {
    let ref: String
    let name: String
    let status: String
    let createdAt: Date
    let completedAt: Date?
    let completedSteps: Int
    let totalSteps: Int
    let cachedSteps: Int

    var id: String { ref }
    var isActive: Bool {
        let value = status.lowercased()
        return value == "running" || value == "in progress" || value == "pending"
    }
    var succeeded: Bool { status.caseInsensitiveCompare("completed") == .orderedSame }
    var progress: Double {
        guard totalSteps > 0 else { return isActive ? 0 : 1 }
        return min(1, max(0, Double(completedSteps) / Double(totalSteps)))
    }
    func elapsed(at now: Date = Date()) -> TimeInterval {
        max(0, (completedAt ?? now).timeIntervalSince(createdAt))
    }

    private enum CodingKeys: String, CodingKey {
        case ref, name, status
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case completedSteps = "completed_steps"
        case totalSteps = "total_steps"
        case cachedSteps = "cached_steps"
    }

    init(
        ref: String,
        name: String,
        status: String,
        createdAt: Date,
        completedAt: Date?,
        completedSteps: Int,
        totalSteps: Int,
        cachedSteps: Int
    ) {
        self.ref = ref
        self.name = name
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.cachedSteps = cachedSteps
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ref = try values.decode(String.self, forKey: .ref)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Untitled build"
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "Unknown"
        let created = try values.decode(String.self, forKey: .createdAt)
        guard let parsedCreated = BuildActivityParser.date(created) else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: values, debugDescription: "invalid BuildKit timestamp")
        }
        createdAt = parsedCreated
        if let raw = try values.decodeIfPresent(String.self, forKey: .completedAt), !raw.isEmpty {
            guard let parsed = BuildActivityParser.date(raw) else {
                throw DecodingError.dataCorruptedError(forKey: .completedAt, in: values, debugDescription: "invalid BuildKit timestamp")
            }
            completedAt = parsed
        } else {
            completedAt = nil
        }
        completedSteps = try values.decodeIfPresent(Int.self, forKey: .completedSteps) ?? 0
        totalSteps = try values.decodeIfPresent(Int.self, forKey: .totalSteps) ?? 0
        cachedSteps = try values.decodeIfPresent(Int.self, forKey: .cachedSteps) ?? 0
    }
}

nonisolated struct BuildCacheUsage: Sendable, Equatable {
    var totalBytes: Int64
    var reclaimableBytes: Int64
    var records: Int

    static let empty = BuildCacheUsage(totalBytes: 0, reclaimableBytes: 0, records: 0)
}

nonisolated enum BuildActivityParser {
    private struct CacheRow: Decodable {
        let Size: String
        let Reclaimable: Bool
    }

    static func history(_ output: String) throws -> [BuildActivityRecord] {
        try nonemptyLines(output).map { line in
            try JSONDecoder().decode(BuildActivityRecord.self, from: Data(line.utf8))
        }
    }

    static func cache(_ output: String) throws -> BuildCacheUsage {
        var total: Int64 = 0
        var reclaimable: Int64 = 0
        let lines = nonemptyLines(output)
        for line in lines {
            let row = try JSONDecoder().decode(CacheRow.self, from: Data(line.utf8))
            guard let bytes = bytes(row.Size) else {
                throw CocoaError(.coderReadCorrupt)
            }
            total = total.addingReportingOverflow(bytes).overflow ? Int64.max : min(Int64.max, total + bytes)
            if row.Reclaimable {
                reclaimable = reclaimable.addingReportingOverflow(bytes).overflow
                    ? Int64.max
                    : min(Int64.max, reclaimable + bytes)
            }
        }
        return BuildCacheUsage(totalBytes: total, reclaimableBytes: reclaimable, records: lines.count)
    }

    static func bytes(_ raw: String) -> Int64? {
        let compact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return nil }
        let split = compact.firstIndex { !$0.isNumber && $0 != "." && $0 != "," }
        let numberText = String(split.map { compact[..<$0] } ?? compact[...]).replacingOccurrences(of: ",", with: "")
        guard let value = Double(numberText), value.isFinite, value >= 0 else { return nil }
        let suffix = split.map { String(compact[$0...]).lowercased() } ?? "b"
        let multiplier: Double
        switch suffix {
        case "b", "bytes": multiplier = 1
        case "kb": multiplier = 1_000
        case "mb": multiplier = 1_000_000
        case "gb": multiplier = 1_000_000_000
        case "tb": multiplier = 1_000_000_000_000
        case "kib": multiplier = 1_024
        case "mib": multiplier = 1_048_576
        case "gib": multiplier = 1_073_741_824
        case "tib": multiplier = 1_099_511_627_776
        default: return nil
        }
        let bytes = value * multiplier
        guard bytes <= Double(Int64.max) else { return Int64.max }
        return Int64(bytes.rounded())
    }

    static func date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func nonemptyLines(_ output: String) -> [String] {
        output.split(whereSeparator: { $0.isNewline }).map(String.init).filter { !$0.isEmpty }
    }
}
