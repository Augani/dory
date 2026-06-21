import Foundation

enum VMFileDownloader {
    static func downloadIfNeeded(from remote: URL, to local: URL) async throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: local.path) { return }
        try? manager.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (tempURL, _) = try await URLSession.shared.download(from: remote)
        try manager.moveItem(at: tempURL, to: local)
    }
}
