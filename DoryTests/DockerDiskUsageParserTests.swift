import Foundation
import Testing
@testable import Dory

struct DockerDiskUsageParserTests {
    @Test func supportsEveryAppleSiliconLaunchAPIVersionShape() throws {
        let expected = ["cache": Int64(17), "database": Int64(4_096)]
        for minor in 40...55 {
            let legacy = legacyVolumes(expected)
            let current = currentVolumeUsage(expected)
            let response: [String: Any]
            switch minor {
            case 40...51:
                response = ["Volumes": legacy]
            case 52:
                response = ["Volumes": legacy, "VolumeUsage": current]
            default:
                response = ["VolumeUsage": current]
            }

            #expect(
                try DockerDiskUsageParser.namedVolumeSizes(from: data(response)) == expected,
                "failed Docker Engine API 1.\(minor) response shape"
            )
        }
    }

    @Test func dualShapeResponseMustDescribeTheSameExactVolumes() throws {
        let legacy = legacyVolumes(["database": 100])
        let current = currentVolumeUsage(["database": 101])
        let response = try data(["Volumes": legacy, "VolumeUsage": current])

        #expect(throws: DockerDiskUsageParserError.conflictingVolumeInventories) {
            try DockerDiskUsageParser.namedVolumeSizes(from: response)
        }
    }

    @Test func nullAndEmptyInventoriesAreHandledWithoutInventingData() throws {
        #expect(try DockerDiskUsageParser.namedVolumeSizes(from: data(["Volumes": NSNull()])) == [:])
        #expect(try DockerDiskUsageParser.namedVolumeSizes(from: data([
            "VolumeUsage": ["Items": []]
        ])) == [:])
        #expect(try DockerDiskUsageParser.namedVolumeSizes(from: data([
            "Volumes": legacyVolumes(["database": 12]),
            "VolumeUsage": ["Items": NSNull()]
        ])) == ["database": 12])
        #expect(throws: DockerDiskUsageParserError.missingVolumeInventory) {
            try DockerDiskUsageParser.namedVolumeSizes(from: data([
                "VolumeUsage": ["Items": NSNull()]
            ]))
        }
    }

    @Test func documentedPluralUsageAliasIsAcceptedButCannotConflict() throws {
        let expected = ["database": Int64(99)]
        #expect(try DockerDiskUsageParser.namedVolumeSizes(from: data([
            "VolumesUsage": currentVolumeUsage(expected)
        ])) == expected)
        #expect(throws: DockerDiskUsageParserError.conflictingVolumeInventories) {
            try DockerDiskUsageParser.namedVolumeSizes(from: data([
                "VolumeUsage": currentVolumeUsage(expected),
                "VolumesUsage": currentVolumeUsage(["database": 100])
            ]))
        }
    }

    @Test func malformedOrAmbiguousVolumeRecordsFailClosed() {
        let malformed = [
            #"{}"#,
            #"{"Volumes":{}}"#,
            #"{"Volumes":[null]}"#,
            #"{"Volumes":[{"Name":"database"}]}"#,
            #"{"Volumes":[{"Name":"database","UsageData":{"Size":-1}}]}"#,
            #"{"Volumes":[{"Name":"database","UsageData":{"Size":1.5}}]}"#,
            #"{"Volumes":[{"Name":"database","UsageData":{"Size":true}}]}"#,
            #"{"Volumes":[{"Name":" database","UsageData":{"Size":1}}]}"#,
            #"{"Volumes":[{"Name":"database","UsageData":{"Size":1}},{"Name":"database","UsageData":{"Size":1}}]}"#,
            #"{"VolumeUsage":{"Items":{}}}"#,
            #"{"VolumeUsage":{"Items":[null]}}"#
        ]

        for response in malformed {
            #expect(throws: DockerDiskUsageParserError.self) {
                try DockerDiskUsageParser.namedVolumeSizes(from: Data(response.utf8))
            }
        }
    }

    @Test func openSchemaFieldsDoNotBreakExactKnownFields() throws {
        let response = try data([
            "VolumeUsage": [
                "TotalSize": 42,
                "FutureSummary": ["value": true],
                "Items": [[
                    "Name": "database",
                    "FutureVolumeField": "ignored",
                    "UsageData": ["Size": 42, "RefCount": 1]
                ]]
            ]
        ])

        #expect(try DockerDiskUsageParser.namedVolumeSizes(from: response) == ["database": 42])
    }

    @Test func totalUsageSupportsCurrentAggregateAndLegacyShapes() throws {
        let current = try data([
            "ImageUsage": ["TotalSize": 100],
            "VolumeUsage": ["TotalSize": 200],
            "ContainerUsage": ["TotalSize": 300],
            "BuildCacheUsage": ["TotalSize": 400]
        ])
        let legacy = try data([
            "LayersSize": 100,
            "Volumes": [["UsageData": ["Size": 200]]],
            "Containers": [
                ["State": "running", "SizeRw": 300],
                ["State": "created"]
            ],
            "BuildCache": [["Size": 400]]
        ])

        #expect(try DockerDiskUsageParser.totalDockerBytes(from: current) == 1_000)
        #expect(try DockerDiskUsageParser.totalDockerBytes(from: legacy) == 1_000)
    }

    @Test func totalUsageFailsClosedOnIncompleteNegativeFractionalAndOverflowValues() throws {
        let invalid: [[String: Any]] = [
            ["ImageUsage": ["TotalSize": 1]],
            [
                "LayersSize": 1,
                "Volumes": [["UsageData": ["Size": -1]]],
                "Containers": [],
                "BuildCache": []
            ],
            [
                "LayersSize": 1,
                "Volumes": [],
                "Containers": [["State": "running", "SizeRw": 1.5]],
                "BuildCache": []
            ],
            [
                "ImageUsage": ["TotalSize": Int64.max],
                "VolumeUsage": ["TotalSize": 1],
                "ContainerUsage": ["TotalSize": 0],
                "BuildCacheUsage": ["TotalSize": 0]
            ]
        ]

        for object in invalid {
            #expect(throws: DockerDiskUsageParserError.self) {
                try DockerDiskUsageParser.totalDockerBytes(from: data(object))
            }
        }
    }

    private func legacyVolumes(_ sizes: [String: Int64]) -> [[String: Any]] {
        sizes.sorted { $0.key < $1.key }.map { name, size in
            ["Name": name, "UsageData": ["Size": size, "RefCount": 0]]
        }
    }

    private func currentVolumeUsage(_ sizes: [String: Int64]) -> [String: Any] {
        [
            "TotalSize": sizes.values.reduce(0, +),
            "Items": legacyVolumes(sizes)
        ]
    }

    private func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
