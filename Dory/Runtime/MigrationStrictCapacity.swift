import Foundation

struct MigrationCapacityInput {
    let source: RuntimeSnapshot
    let target: RuntimeSnapshot
    let volumeBytes: [String: Int64]
    let writableSizes: [String: Int64]
    let targetDockerBytes: Int64
    let availableHostBytes: Int64
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
        guard let response = await runtime.proxyRequest(
            method: "GET",
            path: "/system/df",
            headers: [(name: "Accept", value: "application/json")],
            body: Data()
        ), response.isSuccess,
              let usage = try? DockerDiskUsageParser.totalDockerBytes(from: response.body) else {
            throw MigrationStrictInventoryError.incomplete(
                "target Docker storage usage is unavailable"
            )
        }
        return usage
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
        guard requiredEngineBytes <= engineUsableBytes else {
            throw MigrationStrictInventoryError.unsafe(
                "Dory's engine needs \(requiredEngineBytes) bytes but its usable floor is "
                    + "\(engineUsableBytes)"
            )
        }
        return MigrationCapacityContract(
            sourceVolumeBytes: input.volumeBytes,
            sourceWritableLayerBytes: input.writableSizes,
            targetDockerBytes: input.targetDockerBytes,
            availableHostBytes: input.availableHostBytes,
            requiredHostBytes: requiredHostBytes,
            requiredEngineBytes: requiredEngineBytes
        )
    }
}

private extension MigrationStrictInventoryCollector {
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
