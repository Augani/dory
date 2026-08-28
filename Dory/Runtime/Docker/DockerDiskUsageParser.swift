import CoreFoundation
import Foundation

enum DockerDiskUsageParserError: Error, Equatable {
    case invalidJSON
    case missingVolumeInventory
    case invalidVolumeUsage(String)
    case conflictingVolumeInventories
    case missingTotalUsage
    case invalidTotalUsage(String)
}

/// Strict compatibility decoder for Docker Engine `/system/df` responses.
///
/// API 1.40–1.51 use the top-level `Volumes` array. API 1.52 can return that array
/// together with `VolumeUsage.Items`, and API 1.53+ return only the type-specific usage object.
nonisolated enum DockerDiskUsageParser {
    static func namedVolumeSizes(from data: Data) throws -> [String: Int64] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerDiskUsageParserError.invalidJSON
        }

        var inventories: [[String: Int64]] = []
        if let legacy = try legacyInventory(root["Volumes"]) {
            inventories.append(legacy)
        }
        for key in ["VolumeUsage", "VolumesUsage"] {
            if let current = try currentInventory(root[key], key: key) {
                inventories.append(current)
            }
        }
        guard let first = inventories.first else {
            throw DockerDiskUsageParserError.missingVolumeInventory
        }
        guard inventories.dropFirst().allSatisfy({ $0 == first }) else {
            throw DockerDiskUsageParserError.conflictingVolumeInventories
        }
        return first
    }

    static func totalDockerBytes(from data: Data) throws -> Int64 {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerDiskUsageParserError.invalidJSON
        }
        let images = try reconciledUsage(
            aggregateUsageValues(
                root: root,
                keys: ["ImageUsage", "ImagesUsage"],
                itemSize: nil
            ) + legacyImageUsageValues(root),
            field: "image"
        )
        let volumes = try reconciledUsage(
            aggregateUsageValues(
                root: root,
                keys: ["VolumeUsage", "VolumesUsage"],
                itemSize: volumeSize
            ) + optionalValue(
                try usageItems(root["Volumes"], field: "Volumes", size: volumeSize)
            ),
            field: "volume"
        )
        let containers = try reconciledUsage(
            aggregateUsageValues(
                root: root,
                keys: ["ContainerUsage", "ContainersUsage"],
                itemSize: containerSize
            ) + optionalValue(
                try usageItems(root["Containers"], field: "Containers", size: containerSize)
            ),
            field: "container"
        )
        let buildCache = try reconciledUsage(
            aggregateUsageValues(
                root: root,
                keys: ["BuildCacheUsage"],
                itemSize: directSize
            ) + optionalValue(
                try usageItems(root["BuildCache"], field: "BuildCache", size: directSize)
            ),
            field: "build-cache"
        )
        guard let images, let volumes, let containers, let buildCache else {
            throw DockerDiskUsageParserError.missingTotalUsage
        }
        return try sum([images, volumes, containers, buildCache], field: "total usage")
    }

    private static func legacyInventory(_ value: Any?) throws -> [String: Int64]? {
        guard let value else { return nil }
        if value is NSNull { return [:] }
        guard let items = value as? [Any] else {
            throw DockerDiskUsageParserError.invalidVolumeUsage("Volumes must be an array or null")
        }
        return try parse(items: items, field: "Volumes")
    }

    private static func currentInventory(_ value: Any?, key: String) throws -> [String: Int64]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let usage = value as? [String: Any] else {
            throw DockerDiskUsageParserError.invalidVolumeUsage("\(key) must be an object")
        }
        guard let itemsValue = usage["Items"], !(itemsValue is NSNull) else { return nil }
        guard let items = itemsValue as? [Any] else {
            throw DockerDiskUsageParserError.invalidVolumeUsage("\(key).Items must be an array or null")
        }
        let totalCount: Int64
        if let rawTotalCount = usage["TotalCount"] {
            guard let decoded = exactNonnegativeInteger(rawTotalCount) else {
                throw DockerDiskUsageParserError.invalidVolumeUsage(
                    "\(key).TotalCount is invalid"
                )
            }
            totalCount = decoded
        } else {
            totalCount = 0
        }
        guard totalCount == Int64(items.count) else {
            throw DockerDiskUsageParserError.invalidVolumeUsage(
                "\(key).Items count does not match TotalCount"
            )
        }
        if let rawActiveCount = usage["ActiveCount"] {
            guard let activeCount = exactNonnegativeInteger(rawActiveCount),
                  activeCount <= totalCount else {
                throw DockerDiskUsageParserError.invalidVolumeUsage(
                    "\(key).ActiveCount is invalid"
                )
            }
        }
        return try parse(items: items, field: "\(key).Items")
    }

    private static func parse(items: [Any], field: String) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (index, value) in items.enumerated() {
            guard let volume = value as? [String: Any],
                  let name = volume["Name"] as? String,
                  isValidVolumeName(name),
                  let usage = volume["UsageData"] as? [String: Any],
                  let size = exactNonnegativeInteger(usage["Size"]) else {
                throw DockerDiskUsageParserError.invalidVolumeUsage("invalid \(field)[\(index)]")
            }
            guard result.updateValue(size, forKey: name) == nil else {
                throw DockerDiskUsageParserError.invalidVolumeUsage("duplicate volume name \(name)")
            }
        }
        return result
    }

    private static func usageItems(
        _ value: Any?,
        field: String,
        size: ([String: Any]) -> Int64?
    ) throws -> Int64? {
        guard let value else { return nil }
        if value is NSNull { return 0 }
        guard let items = value as? [Any] else {
            throw DockerDiskUsageParserError.invalidTotalUsage("\(field) must be an array or null")
        }
        var sizes: [Int64] = []
        for (index, item) in items.enumerated() {
            guard let object = item as? [String: Any], let value = size(object) else {
                throw DockerDiskUsageParserError.invalidTotalUsage("invalid \(field)[\(index)]")
            }
            sizes.append(value)
        }
        return try sum(sizes, field: field)
    }

    private static func aggregateUsageValues(
        root: [String: Any],
        keys: [String],
        itemSize: (([String: Any]) -> Int64?)?
    ) throws -> [Int64] {
        let allowedKeys: Set<String> = [
            "ActiveCount", "TotalCount", "Reclaimable", "TotalSize", "Items",
        ]
        var results: [Int64] = []
        for key in keys {
            guard let value = root[key] else { continue }
            guard let usage = value as? [String: Any] else {
                throw DockerDiskUsageParserError.invalidTotalUsage("\(key) must be an object")
            }
            let unknownKeys = Set(usage.keys).subtracting(allowedKeys)
            guard unknownKeys.isEmpty else {
                throw DockerDiskUsageParserError.invalidTotalUsage(
                    "\(key) contains unknown fields"
                )
            }

            var evidence: [Int64] = []
            // An empty aggregate is Moby's canonical encoding for an exact all-zero record.
            // When the object is nonempty but TotalSize is omitted, require evidence that could
            // only describe a real zero-byte category: a nonzero object count or an Items list.
            // Zero-valued scalar fields are themselves omitted by Moby, so accepting a lone
            // `TotalCount: 0` (or equivalent) would widen the contract to a noncanonical partial
            // record and make a malformed response indistinguishable from exact capacity data.
            var exactOmittedZeroEvidence = usage.isEmpty
            var activeCount: Int64 = 0
            var totalCount: Int64 = 0
            var reclaimable: Int64 = 0
            for (field, destination) in [
                ("ActiveCount", 0),
                ("TotalCount", 1),
                ("Reclaimable", 2),
            ] {
                guard let raw = usage[field] else { continue }
                guard let decoded = exactNonnegativeInteger(raw) else {
                    throw DockerDiskUsageParserError.invalidTotalUsage(
                        "\(key).\(field) is invalid"
                    )
                }
                switch destination {
                case 0:
                    activeCount = decoded
                    exactOmittedZeroEvidence = exactOmittedZeroEvidence || decoded > 0
                case 1:
                    totalCount = decoded
                    exactOmittedZeroEvidence = exactOmittedZeroEvidence || decoded > 0
                default: reclaimable = decoded
                }
            }
            guard activeCount <= totalCount else {
                throw DockerDiskUsageParserError.invalidTotalUsage(
                    "\(key) has more active objects than total objects"
                )
            }
            let aggregateTotal: Int64
            if let totalValue = usage["TotalSize"] {
                guard let total = exactNonnegativeInteger(totalValue) else {
                    throw DockerDiskUsageParserError.invalidTotalUsage("\(key).TotalSize is invalid")
                }
                aggregateTotal = total
                evidence.append(total)
            } else {
                // Moby declares TotalSize with `omitempty`. A real aggregate may therefore contain
                // non-zero object counts while omitting TotalSize when every object consumes zero
                // bytes. Infer zero only after recognizing an otherwise exact aggregate record;
                // an object containing only unknown data is not storage evidence.
                aggregateTotal = 0
            }
            guard reclaimable <= aggregateTotal else {
                throw DockerDiskUsageParserError.invalidTotalUsage(
                    "\(key).Reclaimable exceeds TotalSize"
                )
            }
            if let itemsValue = usage["Items"] {
                if itemsValue is NSNull {
                    guard usage["TotalSize"] != nil else {
                        throw DockerDiskUsageParserError.invalidTotalUsage(
                            "\(key).Items is null without an exact total"
                        )
                    }
                } else if let items = itemsValue as? [Any] {
                    guard totalCount == Int64(items.count) else {
                        throw DockerDiskUsageParserError.invalidTotalUsage(
                            "\(key).Items count does not match TotalCount"
                        )
                    }
                    exactOmittedZeroEvidence = true
                    if items.isEmpty {
                        evidence.append(0)
                    } else if let itemSize {
                        evidence.append(try sumUsageItems(items, field: "\(key).Items", size: itemSize))
                    } else if !items.allSatisfy({ $0 is [String: Any] }) {
                        throw DockerDiskUsageParserError.invalidTotalUsage(
                            "invalid \(key).Items"
                        )
                    }
                } else {
                    throw DockerDiskUsageParserError.invalidTotalUsage(
                        "\(key).Items must be an array or null"
                    )
                }
            }
            if usage["TotalSize"] == nil, exactOmittedZeroEvidence {
                evidence.append(0)
            }
            guard let exact = try reconciledUsage(evidence, field: key) else {
                throw DockerDiskUsageParserError.invalidTotalUsage(
                    "\(key) does not contain an exact total"
                )
            }
            results.append(exact)
        }
        return results
    }

    private static func legacyImageUsageValues(_ root: [String: Any]) throws -> [Int64] {
        var results: [Int64] = []
        if let value = root["LayersSize"] {
            guard let total = exactNonnegativeInteger(value) else {
                throw DockerDiskUsageParserError.invalidTotalUsage("LayersSize is invalid")
            }
            results.append(total)
        }
        if let value = root["Images"] {
            if value is NSNull {
                results.append(0)
            } else {
                guard let items = value as? [Any] else {
                    throw DockerDiskUsageParserError.invalidTotalUsage(
                        "Images must be an array or null"
                    )
                }
                // Image summary sizes overlap through shared layers, so they cannot be summed.
                // An explicitly empty list is nevertheless exact evidence of zero image usage.
                if items.isEmpty {
                    results.append(0)
                }
            }
        }
        return results
    }

    private static func optionalValue(_ value: Int64?) -> [Int64] {
        value.map { [$0] } ?? []
    }

    private static func reconciledUsage(_ values: [Int64], field: String) throws -> Int64? {
        guard let first = values.first else { return nil }
        guard values.dropFirst().allSatisfy({ $0 == first }) else {
            throw DockerDiskUsageParserError.invalidTotalUsage(
                "conflicting \(field) usage representations"
            )
        }
        return first
    }

    private static func sumUsageItems(
        _ items: [Any],
        field: String,
        size: ([String: Any]) -> Int64?
    ) throws -> Int64 {
        var sizes: [Int64] = []
        for (index, item) in items.enumerated() {
            guard let object = item as? [String: Any], let value = size(object) else {
                throw DockerDiskUsageParserError.invalidTotalUsage("invalid \(field)[\(index)]")
            }
            sizes.append(value)
        }
        return try sum(sizes, field: field)
    }

    private static func volumeSize(_ object: [String: Any]) -> Int64? {
        exactNonnegativeInteger((object["UsageData"] as? [String: Any])?["Size"])
    }

    private static func containerSize(_ object: [String: Any]) -> Int64? {
        if let rawSize = object["SizeRw"] {
            return exactNonnegativeInteger(rawSize)
        }
        let statesWithSchemaDefinedZero: Set<String> = [
            "created", "restarting", "running", "removing", "paused", "exited", "dead",
        ]
        guard let state = object["State"] as? String,
              statesWithSchemaDefinedZero.contains(state.lowercased()) else {
            return nil
        }
        // Moby declares Summary.SizeRw with `omitempty`; absence is therefore the exact wire
        // representation of zero for every valid container state. Explicit null and malformed
        // values took the branch above and remain invalid.
        return 0
    }

    private static func directSize(_ object: [String: Any]) -> Int64? {
        exactNonnegativeInteger(object["Size"])
    }

    private static func sum(_ values: [Int64], field: String) throws -> Int64 {
        var result: Int64 = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw DockerDiskUsageParserError.invalidTotalUsage("\(field) overflow")
            }
            result = addition.partialValue
        }
        return result
    }

    private static func isValidVolumeName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    private static func exactNonnegativeInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.int64Value >= 0,
              let decimal = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")),
              decimal == Decimal(number.int64Value) else { return nil }
        return number.int64Value
    }
}
