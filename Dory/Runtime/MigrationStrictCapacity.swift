import DoryOperations
import Foundation

/// Capacity that the migration admission decision may actually rely on.
///
/// `logicalBytes` is the selected sparse host file's configured ceiling. `usableBytes` is derived
/// from the ext4 superblock, so growing only the APFS sparse file cannot make migration over-admit
/// before the guest has expanded its filesystem. The conservative 15/16 ratio preserves Dory's
/// qualified 120 GiB floor at the default 128 GiB size and scales it with later disk growth.
nonisolated struct MigrationEngineCapacity: Codable, Sendable, Equatable {
    static let defaultV1 = MigrationEngineCapacity(
        logicalBytes: DockerDataDisk.blankDiskBytes,
        usableBytes: 120 * DockerDataDisk.bytesPerGiB
    )

    let logicalBytes: Int64
    let usableBytes: Int64

    init(logicalBytes: Int64, usableBytes: Int64) {
        self.logicalBytes = logicalBytes
        self.usableBytes = usableBytes
    }

    static func selected(home: String) throws -> MigrationEngineCapacity {
        let store = try DoryDataDriveSelectionStore(home: home)
        guard let drive = try store.inspectSelection() else {
            throw MigrationStrictInventoryError.unsafe(
                "Dory has no verified selected data drive"
            )
        }
        let usage = try DockerDataDisk.usage(at: drive.engineDataDiskPath)
        guard usage.initialized,
              let ext4Bytes = try DockerDataDisk.expectedExt4ImageBytes(
                  at: drive.engineDataDiskPath
              ),
              ext4Bytes > 0 else {
            throw MigrationStrictInventoryError.unsafe(
                "Dory's selected Docker data disk has no verified ext4 capacity"
            )
        }
        let guestVisibleBytes = min(usage.logicalBytes, ext4Bytes)
        let usable = guestVisibleBytes.multipliedReportingOverflow(by: 15)
        guard !usable.overflow else {
            throw MigrationStrictInventoryError.incomplete(
                "Dory engine capacity overflow"
            )
        }
        return MigrationEngineCapacity(
            logicalBytes: usage.logicalBytes,
            usableBytes: usable.partialValue / 16
        )
    }
}

struct MigrationCapacityInput {
    let source: RuntimeSnapshot
    let target: RuntimeSnapshot
    let volumeBytes: [String: Int64]
    let writableSizes: [String: Int64]
    let targetDockerBytes: Int64
    let availableHostBytes: Int64
    let engineCapacity: MigrationEngineCapacity
}

/// Target usage together with the live guest-filesystem ceiling that admission may rely on.
///
/// The configured ext4 ceiling remains an upper bound, but the guest can expose less usable space
/// through reserved blocks or a changed filesystem. Keeping the effective value beside the usage
/// makes it part of the immutable capacity contract and therefore part of staging revalidation.
struct MigrationTargetCapacityUsage: Sendable, Equatable {
    let usedBytes: Int64
    let effectiveUsableBytes: Int64
}

extension MigrationStrictInventoryCollector {
    static func namedVolumeSizes(
        expected names: [String],
        runtime: any ContainerRuntime
    ) async throws -> [String: Int64] {
        if names.isEmpty { return [:] }
        let expected = Set(names)
        guard expected.count == names.count else {
            throw MigrationStrictInventoryError.incomplete(
                "the source volume inventory contains duplicate identities"
            )
        }
        for path in [
            "/system/df?type=volume&verbose=1",
            "/system/df?type=volume",
            "/system/df"
        ] {
            guard let response = await runtime.proxyRequest(
                method: "GET",
                path: path,
                headers: [(name: "Accept", value: "application/json")],
                body: Data()
            ), response.isSuccess,
                  let parsed = try? DockerDiskUsageParser.namedVolumeSizes(from: response.body) else {
                continue
            }
            if Set(parsed.keys) == expected { return parsed }
        }
        throw MigrationStrictInventoryError.incomplete(
            "Docker did not report every named-volume size"
        )
    }

    static func dockerUsage(runtime: any ContainerRuntime) async throws -> Int64 {
        try Task.checkCancellation()
        guard let response = await runtime.proxyRequest(
            method: "GET",
            path: "/system/df",
            headers: [(name: "Accept", value: "application/json")],
            body: Data()
        ) else {
            throw MigrationStrictInventoryError.incomplete(
                "target Docker storage usage request did not return a response"
            )
        }
        try Task.checkCancellation()
        guard response.isSuccess else {
            throw MigrationStrictInventoryError.incomplete(
                "target Docker storage usage request returned HTTP \(response.statusCode)"
            )
        }
        do {
            return try DockerDiskUsageParser.totalDockerBytes(from: response.body)
        } catch let error as DockerDiskUsageParserError {
            throw MigrationStrictInventoryError.incomplete(
                "target Docker storage usage response is invalid: \(error)"
            )
        } catch {
            throw MigrationStrictInventoryError.incomplete(
                "target Docker storage usage response could not be decoded: \(error)"
            )
        }
    }

    static func targetStorageUsage(
        runtime: any ContainerRuntime,
        engineCapacity: MigrationEngineCapacity
    ) async throws -> MigrationTargetCapacityUsage {
        try Task.checkCancellation()
        let authoritative: MigrationTargetStorageUsage?
        do {
            authoritative = try await runtime.migrationTargetStorageUsage()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MigrationStrictInventoryError.incomplete(
                "authoritative target data-disk usage is unavailable: \(error)"
            )
        }
        try Task.checkCancellation()
        guard let authoritative else {
            guard runtime.kind != .sharedVM else {
                throw MigrationStrictInventoryError.incomplete(
                    "Dory's shared-VM target did not provide authoritative guest data-disk usage"
                )
            }
            return MigrationTargetCapacityUsage(
                usedBytes: try await dockerUsage(runtime: runtime),
                effectiveUsableBytes: engineCapacity.usableBytes
            )
        }
        let liveUsableBytes = try validateTargetStorageUsage(
            authoritative,
            engineCapacity: engineCapacity
        )
        return MigrationTargetCapacityUsage(
            usedBytes: authoritative.usedBytes,
            effectiveUsableBytes: min(engineCapacity.usableBytes, liveUsableBytes)
        )
    }

    static func capacityContract(
        _ input: MigrationCapacityInput
    ) throws -> MigrationCapacityContract {
        let targetIDs = Set(input.target.images.map {
            MigrationOperationPlanBuilder.normalizedImageID($0.imageID)
        })
        let imageBytes = try sum(
            input.source.images.filter {
                !targetIDs.contains(MigrationOperationPlanBuilder.normalizedImageID($0.imageID))
            }.map(\.sizeBytes),
            field: "source images"
        )
        let volumeBytes = try sum(Array(input.volumeBytes.values), field: "source volumes")
        let writableBytes = try sum(
            Array(input.writableSizes.values),
            field: "source writable layers"
        )
        let transferBytes = try sum(
            [imageBytes, volumeBytes, writableBytes],
            field: "incoming data"
        )
        // Images are content-addressed and final tags do not duplicate their layers. Named volumes
        // and writable layers are staged, verified, then materialized into their published target;
        // admission therefore budgets both copies until staging cleanup is durably complete.
        let transactionPeakBytes = try sum(
            [transferBytes, volumeBytes, writableBytes],
            field: "transaction peak"
        )
        let requiredHostBytes = try requiredBytes(
            used: transactionPeakBytes,
            field: "host storage"
        )
        let usedAndIncoming = try sum(
            [input.targetDockerBytes, transactionPeakBytes],
            field: "target storage"
        )
        let requiredEngineBytes = try requiredBytes(used: usedAndIncoming, field: "engine storage")
        guard input.availableHostBytes >= requiredHostBytes else {
            throw MigrationStrictInventoryError.unsafe(
                "host storage has \(input.availableHostBytes) bytes but \(requiredHostBytes) are required"
            )
        }
        guard requiredEngineBytes <= input.engineCapacity.usableBytes else {
            throw MigrationStrictInventoryError.unsafe(
                "Dory's engine needs \(requiredEngineBytes) bytes but the selected "
                    + "\(input.engineCapacity.logicalBytes)-byte sparse disk currently exposes "
                    + "only \(input.engineCapacity.usableBytes) verified usable bytes"
            )
        }
        return MigrationCapacityContract(
            sourceVolumeBytes: input.volumeBytes,
            sourceWritableLayerBytes: input.writableSizes,
            targetDockerBytes: input.targetDockerBytes,
            availableHostBytes: input.availableHostBytes,
            requiredHostBytes: requiredHostBytes,
            requiredEngineBytes: requiredEngineBytes,
            engineLogicalBytes: input.engineCapacity.logicalBytes,
            engineUsableBytes: input.engineCapacity.usableBytes
        )
    }
}

private extension MigrationStrictInventoryCollector {
    static func validateTargetStorageUsage(
        _ usage: MigrationTargetStorageUsage,
        engineCapacity: MigrationEngineCapacity
    ) throws -> Int64 {
        let accounted = usage.usedBytes.addingReportingOverflow(usage.availableBytes)
        guard usage.totalBytes > 0,
              usage.usedBytes >= 0,
              usage.availableBytes >= 0,
              usage.usedBytes <= usage.totalBytes,
              usage.availableBytes <= usage.totalBytes,
              !accounted.overflow,
              accounted.partialValue > 0,
              accounted.partialValue <= usage.totalBytes else {
            throw MigrationStrictInventoryError.incomplete(
                "authoritative target data-disk usage is internally inconsistent"
            )
        }
        guard usage.totalBytes >= engineCapacity.usableBytes,
              usage.totalBytes <= engineCapacity.logicalBytes else {
            throw MigrationStrictInventoryError.incomplete(
                "authoritative target data-disk capacity does not match Dory's selected disk"
            )
        }
        return accounted.partialValue
    }

    static func requiredBytes(used: Int64, field: String) throws -> Int64 {
        guard used > 0 else { return 0 }
        return try sum([used, max(safetyFloorBytes, used / 5)], field: field)
    }

    static func sum(_ values: [Int64], field: String) throws -> Int64 {
        var result: Int64 = 0
        for value in values {
            guard value >= 0 else {
                throw MigrationStrictInventoryError.incomplete("negative \(field) usage")
            }
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw MigrationStrictInventoryError.incomplete("\(field) usage overflow")
            }
            result = addition.partialValue
        }
        return result
    }
}
