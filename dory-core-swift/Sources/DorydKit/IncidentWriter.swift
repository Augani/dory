import Darwin
import Foundation

public struct IncidentRecord: Sendable, Equatable {
    public var at: Date
    public var type: String
    public var detail: String?

    public init(at: Date = Date(), type: String, detail: String? = nil) {
        self.at = at
        self.type = type
        self.detail = detail
    }

    public var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "at": incidentISO8601String(at),
            "type": type,
        ]
        if let detail, !detail.isEmpty {
            dictionary["detail"] = detail
        }
        return dictionary as NSDictionary
    }
}

public final class IncidentWriter: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
    }

    public func record(type: String, detail: String? = nil, at: Date = Date()) {
        record(IncidentRecord(at: at, type: type, detail: detail))
    }

    public func record(_ incident: IncidentRecord) {
        lock.lock()
        defer { lock.unlock() }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let fd = open(path, O_CREAT | O_APPEND | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return }
        defer { close(fd) }
        fchmod(fd, S_IRUSR | S_IWUSR)

        guard var line = try? JSONSerialization.data(withJSONObject: incident.xpcDictionary, options: [.sortedKeys]) else {
            return
        }
        line.append(0x0A)
        line.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < line.count {
                let result = Darwin.write(fd, base.advanced(by: written), line.count - written)
                if result <= 0 {
                    return
                }
                written += result
            }
        }
    }

    public func read(limit: Int = 50) -> [IncidentRecord] {
        guard limit > 0,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        let rows = content
            .split(separator: "\n")
            .compactMap { IncidentRecord(jsonLine: String($0)) }
        return Array(rows.suffix(limit).reversed())
    }
}

private extension IncidentRecord {
    init?(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atString = raw["at"] as? String,
              let at = incidentISO8601Date(atString),
              let type = raw["type"] as? String else {
            return nil
        }
        self.init(at: at, type: type, detail: raw["detail"] as? String)
    }
}

private func incidentISO8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func incidentISO8601Date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}
