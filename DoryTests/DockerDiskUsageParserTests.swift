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
                "TotalCount": 1,
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

    @Test func totalUsageSupportsDockerAPI140Through155Shapes() throws {
        let legacy: [String: Any] = [
            "LayersSize": 100,
            "Volumes": [["UsageData": ["Size": 200]]],
            "Containers": [["State": "running", "SizeRw": 300]],
            "BuildCache": [["Size": 400]]
        ]
        let current: [String: Any] = [
            "ImageUsage": ["TotalSize": 100],
            "VolumeUsage": ["TotalSize": 200],
            "ContainerUsage": ["TotalSize": 300],
            "BuildCacheUsage": ["TotalSize": 400]
        ]

        for minor in 40...55 {
            var response = minor <= 52 ? legacy : [:]
            if minor >= 52 {
                response.merge(current) { _, current in current }
            }
            #expect(
                try DockerDiskUsageParser.totalDockerBytes(from: data(response)) == 1_000,
                "failed Docker Engine API 1.\(minor) response shape"
            )
        }
    }

    @Test func totalUsageReconcilesEachCategoryIndependently() throws {
        let mixed = try data([
            "ImageUsage": ["TotalSize": 100],
            "Volumes": [["UsageData": ["Size": 200]]],
            "ContainerUsage": ["TotalSize": 300],
            "BuildCache": [["Size": 400]]
        ])

        #expect(try DockerDiskUsageParser.totalDockerBytes(from: mixed) == 1_000)
    }

    @Test func overlappingUsageRepresentationsMustAgreePerCategory() throws {
        let conflicts: [[String: Any]] = [
            [
                "ImageUsage": ["TotalSize": 100],
                "LayersSize": 101,
                "VolumeUsage": ["TotalSize": 200],
                "ContainerUsage": ["TotalSize": 300],
                "BuildCacheUsage": ["TotalSize": 400]
            ],
            [
                "ImageUsage": ["TotalSize": 100],
                "VolumeUsage": ["TotalSize": 200],
                "Volumes": [["UsageData": ["Size": 201]]],
                "ContainerUsage": ["TotalSize": 300],
                "BuildCacheUsage": ["TotalSize": 400]
            ],
            [
                "ImageUsage": ["TotalSize": 100],
                "VolumeUsage": ["TotalSize": 200],
                "ContainerUsage": ["TotalSize": 300],
                "Containers": [["State": "running", "SizeRw": 301]],
                "BuildCacheUsage": ["TotalSize": 400]
            ],
            [
                "ImageUsage": ["TotalSize": 100],
                "VolumeUsage": ["TotalSize": 200],
                "ContainerUsage": ["TotalSize": 300],
                "BuildCacheUsage": ["TotalSize": 400],
                "BuildCache": [["Size": 401]]
            ],
            [
                "ImageUsage": ["TotalSize": 100],
                "VolumeUsage": [
                    "TotalSize": 200,
                    "Items": [["UsageData": ["Size": 201]]]
                ],
                "ContainerUsage": ["TotalSize": 300],
                "BuildCacheUsage": ["TotalSize": 400]
            ]
        ]

        for response in conflicts {
            #expect(throws: DockerDiskUsageParserError.self) {
                try DockerDiskUsageParser.totalDockerBytes(from: data(response))
            }
        }
    }

    @Test func api152DualShapeCountsSharedBuildCacheLikeTheDaemonAggregate() throws {
        // Moby's daemon adds every build-cache record to BuildCacheUsage.TotalSize, including
        // records marked Shared. API 1.52 returns that aggregate together with the same legacy
        // records, so reconciliation must use the daemon's all-record wire semantics rather than
        // the Docker client's separate pre-1.52 display de-duplication policy.
        let response = try data([
            "ImageUsage": ["TotalSize": 100],
            "LayersSize": 100,
            "VolumeUsage": ["TotalSize": 200],
            "Volumes": [["UsageData": ["Size": 200]]],
            "ContainerUsage": ["TotalSize": 300],
            "Containers": [["State": "running", "SizeRw": 300]],
            "BuildCacheUsage": ["TotalSize": 700],
            "BuildCache": [
                ["Size": 400, "Shared": false],
                ["Size": 300, "Shared": true],
            ],
        ])

        #expect(try DockerDiskUsageParser.totalDockerBytes(from: response) == 1_300)
    }

    @Test func explicitEmptyBuildCacheIsZeroButAnAbsentCategoryIsUnknown() throws {
        let withoutBuildCache: [String: Any] = [
            "ImageUsage": ["TotalSize": 100],
            "VolumeUsage": ["TotalSize": 200],
            "ContainerUsage": ["TotalSize": 300]
        ]
        let explicitEmptyRepresentations: [Any] = [
            [String: Any](),
            ["Items": []] as [String: Any]
        ]

        #expect(throws: DockerDiskUsageParserError.missingTotalUsage) {
            try DockerDiskUsageParser.totalDockerBytes(from: data(withoutBuildCache))
        }
        for usage in explicitEmptyRepresentations {
            var response = withoutBuildCache
            response["BuildCacheUsage"] = usage
            #expect(try DockerDiskUsageParser.totalDockerBytes(from: data(response)) == 600)
        }
        var legacyEmpty = withoutBuildCache
        legacyEmpty["BuildCache"] = []
        #expect(try DockerDiskUsageParser.totalDockerBytes(from: data(legacyEmpty)) == 600)
    }

    @Test func documentedPluralAggregateAliasesAreAcceptedButCannotConflict() throws {
        let aliases = try data([
            "ImagesUsage": ["TotalSize": 100],
            "VolumesUsage": ["TotalSize": 200],
            "ContainersUsage": ["TotalSize": 300],
            "BuildCacheUsage": ["TotalSize": 400]
        ])
        #expect(try DockerDiskUsageParser.totalDockerBytes(from: aliases) == 1_000)

        #expect(throws: DockerDiskUsageParserError.self) {
            try DockerDiskUsageParser.totalDockerBytes(from: data([
                "ImageUsage": ["TotalSize": 100],
                "ImagesUsage": ["TotalSize": 101],
                "VolumeUsage": ["TotalSize": 200],
                "ContainerUsage": ["TotalSize": 300],
                "BuildCacheUsage": ["TotalSize": 400]
            ]))
        }
    }

    @Test func emptyDocker29AndVersionedLegacyResponsesAreExactZero() throws {
        let docker29 = Data(#"{"Images":[],"Containers":[],"Volumes":[],"BuildCache":[],"ImageUsage":{},"ContainerUsage":{},"VolumeUsage":{},"BuildCacheUsage":{}}"#.utf8)
        let versionedLegacy = Data(#"{"Images":[],"Containers":[],"Volumes":[],"BuildCache":[]}"#.utf8)

        #expect(try DockerDiskUsageParser.totalDockerBytes(from: docker29) == 0)
        #expect(try DockerDiskUsageParser.totalDockerBytes(from: versionedLegacy) == 0)
    }

    @Test func zeroSizeAggregatesMayOmitTotalSizeWhileRetainingCounts() throws {
        // Moby encodes every aggregate scalar with `omitempty`. Categories containing zero-byte
        // objects therefore retain their counts while omitting an exact zero TotalSize.
        let response = try data([
            "ImageUsage": ["TotalCount": 2],
            "VolumeUsage": ["TotalCount": 1, "Items": [["UsageData": ["Size": 0]]]],
            "ContainerUsage": [
                "ActiveCount": 1,
                "TotalCount": 1,
                "Items": [["State": "running", "SizeRw": 0]],
            ],
            "BuildCacheUsage": ["TotalCount": 1, "Items": [["Size": 0]]],
        ])

        #expect(try DockerDiskUsageParser.totalDockerBytes(from: response) == 0)
    }

    @Test func omittedAggregateTotalRequiresExactNonconflictingWireEvidence() throws {
        let invalid: [[String: Any]] = [
            [
                "ImageUsage": ["FutureMetric": 0],
                "VolumeUsage": [:],
                "ContainerUsage": [:],
                "BuildCacheUsage": [:],
            ],
            [
                "ImageUsage": ["TotalCount": "1"],
                "VolumeUsage": [:],
                "ContainerUsage": [:],
                "BuildCacheUsage": [:],
            ],
            [
                "ImageUsage": ["ActiveCount": 2, "TotalCount": 1],
                "VolumeUsage": [:],
                "ContainerUsage": [:],
                "BuildCacheUsage": [:],
            ],
            [
                "ImageUsage": ["TotalCount": 1, "Reclaimable": 1],
                "VolumeUsage": [:],
                "ContainerUsage": [:],
                "BuildCacheUsage": [:],
            ],
            [
                "ImageUsage": [:],
                "VolumeUsage": [
                    "TotalCount": 1,
                    "Items": [["UsageData": ["Size": 1]]],
                ],
                "ContainerUsage": [:],
                "BuildCacheUsage": [:],
            ],
            [
                "ImageUsage": ["Items": NSNull()],
                "VolumeUsage": [:],
                "ContainerUsage": [:],
                "BuildCacheUsage": [:],
            ],
        ]

        for response in invalid {
            #expect(throws: DockerDiskUsageParserError.self) {
                try DockerDiskUsageParser.totalDockerBytes(from: data(response))
            }
        }
    }

    @Test func aggregateItemsMustExactlyMatchTheirDeclaredCount() throws {
        let contradictory: [[String: Any]] = [
            [
                "ImageUsage": ["TotalCount": 1, "Items": []],
                "VolumeUsage": [:],
                "ContainerUsage": [:],
                "BuildCacheUsage": [:],
            ],
            [
                "ImageUsage": [:],
                "VolumeUsage": [
                    "Items": [["UsageData": ["Size": 0]]],
                ],
                "ContainerUsage": [:],
                "BuildCacheUsage": [:],
            ],
            [
                "ImageUsage": [:],
                "VolumeUsage": [:],
                "ContainerUsage": ["TotalCount": 2, "Items": [[
                    "State": "running", "SizeRw": 0,
                ]]],
                "BuildCacheUsage": [:],
            ],
            [
                "ImageUsage": [:],
                "VolumeUsage": [:],
                "ContainerUsage": [:],
                "BuildCacheUsage": ["TotalCount": 0, "Items": [["Size": 0]]],
            ],
        ]

        for response in contradictory {
            #expect(throws: DockerDiskUsageParserError.self) {
                try DockerDiskUsageParser.totalDockerBytes(from: data(response))
            }
        }

        #expect(throws: DockerDiskUsageParserError.invalidVolumeUsage(
            "VolumeUsage.Items count does not match TotalCount"
        )) {
            try DockerDiskUsageParser.namedVolumeSizes(from: data([
                "VolumeUsage": [
                    "TotalCount": 2,
                    "Items": legacyVolumes(["database": 42]),
                ],
            ]))
        }
    }

    @Test func omittedContainerSizeIsExactZeroForEveryMobyState() throws {
        let states = ["created", "restarting", "running", "removing", "paused", "exited", "dead"]
        for state in states {
            let legacy = try data([
                "Images": [],
                "Volumes": [],
                "Containers": [["State": state]],
                "BuildCache": [],
            ])
            let current = try data([
                "ImageUsage": [:],
                "VolumeUsage": [:],
                "ContainerUsage": ["TotalCount": 1, "Items": [["State": state]]],
                "BuildCacheUsage": [:],
            ])
            #expect(try DockerDiskUsageParser.totalDockerBytes(from: legacy) == 0)
            #expect(try DockerDiskUsageParser.totalDockerBytes(from: current) == 0)
        }

        let malformed = [
            ["State": "running", "SizeRw": NSNull()] as [String: Any],
            ["State": "unknown"] as [String: Any],
        ]
        for container in malformed {
            #expect(throws: DockerDiskUsageParserError.self) {
                try DockerDiskUsageParser.totalDockerBytes(from: data([
                    "Images": [],
                    "Volumes": [],
                    "Containers": [container],
                    "BuildCache": [],
                ]))
            }
        }
    }

    @Test func emptyUsageMustStillBeCompleteAndUnambiguous() throws {
        let invalid: [[String: Any]] = [
            [
                "ImageUsage": [:],
                "VolumeUsage": [:],
                "ContainerUsage": [:]
            ],
            [
                "ImageUsage": ["TotalCount": 0],
                "VolumeUsage": [:],
                "ContainerUsage": [:],
                "BuildCacheUsage": [:]
            ],
            [
                "Containers": [],
                "Volumes": [],
                "BuildCache": []
            ]
        ]

        for object in invalid {
            #expect(throws: DockerDiskUsageParserError.self) {
                try DockerDiskUsageParser.totalDockerBytes(from: data(object))
            }
        }
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
            "TotalCount": sizes.count,
            "TotalSize": sizes.values.reduce(0, +),
            "Items": legacyVolumes(sizes)
        ]
    }

    private func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
