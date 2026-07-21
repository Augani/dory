import Foundation
import Testing
@testable import Dory

struct DockerStorageInventoryTests {
    @Test func legacyInventoryReportsObjectsAndUsesActualCategoryTotals() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "LayersSize": 100,
            "Images": [[
                "Id": "sha256:image-one",
                "RepoTags": ["alpine:latest"],
                "Size": 500,
                "SharedSize": 400,
                "Containers": 1,
            ]],
            "Containers": [[
                "Id": "container-one",
                "Names": ["/web"],
                "Image": "alpine:latest",
                "State": "running",
                "SizeRw": 20,
            ]],
            "Volumes": [[
                "Name": "database",
                "Driver": "local",
                "UsageData": ["Size": 300, "RefCount": 1],
            ]],
            "BuildCache": [[
                "ID": "cache-one",
                "Type": "regular",
                "Size": 40,
                "InUse": false,
            ]],
        ], options: [.sortedKeys])

        let snapshot = try DockerStorageInventoryParser.parse(data, generatedAt: Date(timeIntervalSince1970: 10))
        #expect(snapshot.totalBytes == 460)
        #expect(snapshot.groups.first(where: { $0.kind == .images })?.totalBytes == 100)
        #expect(snapshot.groups.first(where: { $0.kind == .images })?.entries.first?.sizeBytes == 500)
        #expect(snapshot.groups.first(where: { $0.kind == .containers })?.entries.first?.name == "web")
        #expect(snapshot.groups.first(where: { $0.kind == .volumes })?.entries.first?.detail.contains("300 bytes") == true)
    }

    @Test func currentUsageShapeSupportsItemsAndSortsLargestFirst() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "ImageUsage": ["TotalSize": 12, "Items": []],
            "ContainerUsage": ["TotalSize": 0, "Items": []],
            "VolumeUsage": [
                "TotalSize": 35,
                "Items": [
                    ["Name": "small", "UsageData": ["Size": 5, "RefCount": 0]],
                    ["Name": "large", "UsageData": ["Size": 30, "RefCount": 0]],
                ],
            ],
            "BuildCacheUsage": ["TotalSize": 7, "Items": []],
        ], options: [.sortedKeys])

        let snapshot = try DockerStorageInventoryParser.parse(data)
        let volumes = try #require(snapshot.groups.first(where: { $0.kind == .volumes }))
        #expect(volumes.totalBytes == 35)
        #expect(volumes.entries.map(\.name) == ["large", "small"])
        #expect(snapshot.totalBytes == 54)
    }

    @Test func finderNamesAreSafeStableAndDoNotPretendReportFilesConsumeDockerBytes() {
        let first = DoryStorageInventoryContract.stableIdentifier(kind: .images, source: "sha256:abc")
        let second = DoryStorageInventoryContract.stableIdentifier(kind: .images, source: "sha256:abc")
        let entry = DoryStorageInventoryEntry(
            identifier: first,
            name: "repo/image:latest\nunsafe",
            sizeBytes: 1_073_741_824,
            detail: "small report"
        )

        #expect(first == second)
        #expect(!entry.finderFilename.contains("/"))
        #expect(!entry.finderFilename.contains("\n"))
        #expect(entry.finderFilename.contains("1 GB"))
        #expect(entry.detail.utf8.count < entry.sizeBytes)
    }

    @Test func invalidJSONFailsWithoutPublishingAnEmptyInventory() {
        #expect(throws: DockerStorageInventoryError.invalidResponse) {
            try DockerStorageInventoryParser.parse(Data("not-json".utf8))
        }
    }
}
