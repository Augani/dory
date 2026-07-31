import CoreFoundation
import Foundation

enum DockerStorageInventoryError: Error, Equatable {
    case invalidResponse
}

nonisolated enum DockerStorageInventoryParser {
    static func parse(_ data: Data, generatedAt: Date = Date()) throws -> DoryStorageInventorySnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerStorageInventoryError.invalidResponse
        }

        let images = objects(root: root, legacyKey: "Images", usageKey: "ImageUsage")
        let containers = objects(root: root, legacyKey: "Containers", usageKey: "ContainerUsage")
        let volumes = objects(root: root, legacyKey: "Volumes", usageKey: "VolumeUsage")
        let buildCache = objects(root: root, legacyKey: "BuildCache", usageKey: "BuildCacheUsage")

        return DoryStorageInventorySnapshot(generatedAt: generatedAt, groups: [
            DoryStorageInventoryGroup(
                kind: .images,
                totalBytes: usageTotal(root["ImageUsage"])
                    ?? nonnegativeInteger(root["LayersSize"])
                    ?? sum(images.map { nonnegativeInteger($0["Size"]) ?? 0 }),
                entries: imageEntries(images)
            ),
            DoryStorageInventoryGroup(
                kind: .containers,
                totalBytes: usageTotal(root["ContainerUsage"])
                    ?? sum(containers.map { nonnegativeInteger($0["SizeRw"]) ?? 0 }),
                entries: containerEntries(containers)
            ),
            DoryStorageInventoryGroup(
                kind: .volumes,
                totalBytes: usageTotal(root["VolumeUsage"])
                    ?? sum(volumes.map(volumeSize)),
                entries: volumeEntries(volumes)
            ),
            DoryStorageInventoryGroup(
                kind: .buildCache,
                totalBytes: usageTotal(root["BuildCacheUsage"])
                    ?? sum(buildCache.map { nonnegativeInteger($0["Size"]) ?? 0 }),
                entries: buildCacheEntries(buildCache)
            ),
        ])
    }

    private static func objects(
        root: [String: Any],
        legacyKey: String,
        usageKey: String
    ) -> [[String: Any]] {
        if let values = root[legacyKey] as? [[String: Any]] { return values }
        if let usage = root[usageKey] as? [String: Any],
           let values = usage["Items"] as? [[String: Any]] {
            return values
        }
        return []
    }

    private static func imageEntries(_ objects: [[String: Any]]) -> [DoryStorageInventoryEntry] {
        objects.map { object in
            let id = string(object["Id"]) ?? string(object["ID"]) ?? "unknown"
            let references = stringArray(object["RepoTags"])
            let name = references.first ?? shortID(id, fallback: "Untagged image")
            let size = nonnegativeInteger(object["Size"]) ?? 0
            let shared = nonnegativeInteger(object["SharedSize"]) ?? 0
            let containers = nonnegativeInteger(object["Containers"]) ?? 0
            var lines = [
                "Image: \(name)",
                "Image ID: \(id)",
                "Reported size: \(DoryStorageInventoryContract.formattedBytes(size))",
                "Shared layers: \(DoryStorageInventoryContract.formattedBytes(shared))",
                "Used by: \(containers) container\(containers == 1 ? "" : "s")",
            ]
            if references.count > 1 {
                lines.append("Other references: \(references.dropFirst().joined(separator: ", "))")
            }
            lines.append("")
            return entry(kind: .images, source: id, name: name, size: size, lines: lines)
        }
        .sorted(by: entryOrder)
    }

    private static func containerEntries(_ objects: [[String: Any]]) -> [DoryStorageInventoryEntry] {
        objects.map { object in
            let id = string(object["Id"]) ?? string(object["ID"]) ?? "unknown"
            let rawName = stringArray(object["Names"]).first ?? shortID(id, fallback: "Unnamed container")
            let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
            let size = nonnegativeInteger(object["SizeRw"]) ?? 0
            let image = string(object["Image"]) ?? "unknown"
            let state = string(object["State"]) ?? "unknown"
            let lines = [
                "Container: \(name)",
                "Container ID: \(id)",
                "Writable layer: \(DoryStorageInventoryContract.formattedBytes(size))",
                "Image: \(image)",
                "State: \(state)",
                "",
            ]
            return entry(kind: .containers, source: id, name: name, size: size, lines: lines)
        }
        .sorted(by: entryOrder)
    }

    private static func volumeEntries(_ objects: [[String: Any]]) -> [DoryStorageInventoryEntry] {
        objects.map { object in
            let name = string(object["Name"]) ?? "Unnamed volume"
            let usage = object["UsageData"] as? [String: Any]
            let size = nonnegativeInteger(usage?["Size"]) ?? 0
            let references = nonnegativeInteger(usage?["RefCount"]) ?? 0
            let driver = string(object["Driver"]) ?? "unknown"
            let lines = [
                "Volume: \(name)",
                "Stored data: \(DoryStorageInventoryContract.formattedBytes(size))",
                "Driver: \(driver)",
                "Used by: \(references) container\(references == 1 ? "" : "s")",
                "",
            ]
            return entry(kind: .volumes, source: name, name: name, size: size, lines: lines)
        }
        .sorted(by: entryOrder)
    }

    private static func buildCacheEntries(_ objects: [[String: Any]]) -> [DoryStorageInventoryEntry] {
        objects.map { object in
            let id = string(object["ID"]) ?? string(object["Id"]) ?? "unknown"
            let size = nonnegativeInteger(object["Size"]) ?? 0
            let type = string(object["Type"]) ?? "cache record"
            let inUse = (object["InUse"] as? Bool) == true
            let name = "\(type) \(shortID(id, fallback: "cache"))"
            let lines = [
                "Build cache: \(id)",
                "Stored data: \(DoryStorageInventoryContract.formattedBytes(size))",
                "Type: \(type)",
                "In use: \(inUse ? "Yes" : "No")",
                "",
            ]
            return entry(kind: .buildCache, source: id, name: name, size: size, lines: lines)
        }
        .sorted(by: entryOrder)
    }

    private static func entry(
        kind: DoryStorageInventoryKind,
        source: String,
        name: String,
        size: Int64,
        lines: [String]
    ) -> DoryStorageInventoryEntry {
        DoryStorageInventoryEntry(
            identifier: DoryStorageInventoryContract.stableIdentifier(kind: kind, source: source),
            name: name,
            sizeBytes: size,
            detail: lines.joined(separator: "\n")
        )
    }

    private static func entryOrder(
        _ lhs: DoryStorageInventoryEntry,
        _ rhs: DoryStorageInventoryEntry
    ) -> Bool {
        if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func volumeSize(_ object: [String: Any]) -> Int64 {
        nonnegativeInteger((object["UsageData"] as? [String: Any])?["Size"]) ?? 0
    }

    private static func usageTotal(_ value: Any?) -> Int64? {
        guard let object = value as? [String: Any] else { return nil }
        if object.isEmpty { return 0 }
        return nonnegativeInteger(object["TotalSize"])
    }

    private static func sum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { partial, value in
            let result = partial.addingReportingOverflow(max(0, value))
            return result.overflow ? Int64.max : result.partialValue
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [String] ?? []).filter { !$0.isEmpty && $0 != "<none>:<none>" }
    }

    private static func shortID(_ value: String, fallback: String) -> String {
        let clean = value.split(separator: ":").last.map(String.init) ?? value
        return clean.isEmpty || clean == "unknown" ? fallback : String(clean.prefix(12))
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.int64Value >= 0,
           let decimal = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")),
           decimal == Decimal(number.int64Value) {
            return number.int64Value
        }
        if let text = value as? String, let number = Int64(text), number >= 0 { return number }
        return nil
    }
}

extension DockerEngineRuntime {
    func storageInventory() async throws -> DoryStorageInventorySnapshot {
        let client = UnixSocketHTTP(path: socketPath, ioTimeout: operationIdleTimeout)
        let response = try await client.send(HTTPRequest(
            method: "GET",
            path: "/system/df",
            headers: [(name: "Accept", value: "application/json")]
        ))
        guard response.isSuccess else {
            throw HTTPError.status(
                code: response.statusCode,
                message: String(data: response.body, encoding: .utf8) ?? ""
            )
        }
        return try DockerStorageInventoryParser.parse(response.body)
    }
}
