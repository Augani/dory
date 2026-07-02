import Foundation

struct OpenRequest: Codable, Sendable {
    let url: String
    let cwd: String?
    let ts: Int
}

struct ForwardRequest: Codable, Sendable {
    let port: Int
    let ts: Int
    let ttlSec: Int?
}

enum HostBridge {
    static func decodeOpen(_ data: Data) -> OpenRequest? {
        guard data.count <= maxRequestBytes else { return nil }
        return try? JSONDecoder().decode(OpenRequest.self, from: data)
    }

    static func decodeForward(_ data: Data) -> ForwardRequest? {
        guard data.count <= maxRequestBytes else { return nil }
        return try? JSONDecoder().decode(ForwardRequest.self, from: data)
    }

    static let maxRequestBytes = 64 * 1024

    static func allowedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8192, let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard url.host?.isEmpty == false else { return nil }
        return url
    }

    static func allowedForwardPort(_ port: Int) -> Bool {
        port >= 1024 && port <= 65535
    }

    static func resolvedTTL(_ ttlSec: Int?) -> Int {
        guard let ttlSec, ttlSec > 0 else { return 300 }
        return min(ttlSec, 3600)
    }
}
