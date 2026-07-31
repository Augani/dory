import Foundation

nonisolated enum DoryStorageInventoryContract {
    static let appGroupIdentifier = "864H636QW4.group.com.pythonxi.Dory"
    static let domainIdentifier = "dory-storage"
    static let summaryIdentifier = "storage-summary"
    static let snapshotFilename = "storage-inventory.json"

    static func snapshotURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(snapshotFilename, isDirectory: false)
    }

    static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .binary)
    }

    static func stableIdentifier(kind: DoryStorageInventoryKind, source: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "entry-\(kind.rawValue)-\(String(hash, radix: 16))"
    }

    static func safeFilename(_ value: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\0\n\r\t")
        let cleaned = value.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? fallback : cleaned).prefix(180))
    }
}

nonisolated enum DoryStorageInventoryKind: String, Codable, CaseIterable, Sendable {
    case images
    case containers
    case volumes
    case buildCache = "build-cache"

    var displayName: String {
        switch self {
        case .images: "Images"
        case .containers: "Containers"
        case .volumes: "Volumes"
        case .buildCache: "Build Cache"
        }
    }

    var folderIdentifier: String { "folder-\(rawValue)" }
}

nonisolated struct DoryStorageInventoryEntry: Codable, Equatable, Sendable {
    var identifier: String
    var name: String
    var sizeBytes: Int64
    var detail: String

    var finderFilename: String {
        let safe = DoryStorageInventoryContract.safeFilename(name, fallback: "Unnamed item")
        return "\(safe) - \(DoryStorageInventoryContract.formattedBytes(sizeBytes)).txt"
    }
}

nonisolated struct DoryStorageInventoryGroup: Codable, Equatable, Sendable {
    var kind: DoryStorageInventoryKind
    var totalBytes: Int64
    var entries: [DoryStorageInventoryEntry]

    var finderFolderName: String {
        "\(kind.displayName) - \(DoryStorageInventoryContract.formattedBytes(totalBytes))"
    }
}

nonisolated struct DoryStorageInventorySnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var revision: Int64
    var generatedAt: Date
    var groups: [DoryStorageInventoryGroup]
    var removedIdentifiers: [String]

    init(
        revision: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        generatedAt: Date = Date(),
        groups: [DoryStorageInventoryGroup],
        removedIdentifiers: [String] = []
    ) {
        self.schemaVersion = Self.schemaVersion
        self.revision = revision
        self.generatedAt = generatedAt
        self.groups = DoryStorageInventoryKind.allCases.map { kind in
            groups.first(where: { $0.kind == kind })
                ?? DoryStorageInventoryGroup(kind: kind, totalBytes: 0, entries: [])
        }
        self.removedIdentifiers = removedIdentifiers.sorted()
    }

    var totalBytes: Int64 {
        groups.reduce(0) { partial, group in
            let result = partial.addingReportingOverflow(max(0, group.totalBytes))
            return result.overflow ? Int64.max : result.partialValue
        }
    }

    var summary: String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Dory Storage",
            "",
            "Updated: \(formatter.string(from: generatedAt))",
            "Reported Docker storage: \(DoryStorageInventoryContract.formattedBytes(totalBytes))",
            "",
        ]
        for kind in DoryStorageInventoryKind.allCases {
            let group = groups.first(where: { $0.kind == kind })
            lines.append(
                "\(kind.displayName): \(DoryStorageInventoryContract.formattedBytes(group?.totalBytes ?? 0))"
                    + " (\(group?.entries.count ?? 0) items)"
            )
        }
        lines.append(contentsOf: [
            "",
            "This is a read-only view of Dory's Docker storage.",
            "Image entries show their reported image size. Images can share layers, so their individual sizes may overlap.",
            "Container entries show writable-layer size. Named volume entries show stored data size.",
            "The total does not include filesystem metadata or reserved sparse capacity.",
            "Stop Dory's engine to remove this location from Finder.",
            "",
        ])
        return lines.joined(separator: "\n")
    }
}
