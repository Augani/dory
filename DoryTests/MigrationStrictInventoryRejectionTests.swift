import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationStrictInventoryRejectionTests: StrictInventoryTestCase {
    @Test func externalVolumeAndNetworkSemanticsAreRejected() async {
        do {
            let fixture = makeFixture()
            fixture.source.snapshotValue.volumes[0].options = ["type": "nfs"]
            await #expect(throws: MigrationStrictInventoryError.unsupported(
                "volume db-data uses driver/options backed by external host state"
            )) {
                _ = try await collect(fixture)
            }
        }
        do {
            let fixture = makeFixture()
            fixture.source.networkInspections["backend"] = networkInspection(driver: "overlay")
            await #expect(throws: MigrationStrictInventoryError.unsupported(
                "network backend depends on non-local bridge or swarm state"
            )) {
                _ = try await collect(fixture)
            }
        }
        do {
            let fixture = makeFixture()
            fixture.source.containerInspections["container-id"] = legacyNamedVolumeInspection(
                modes: "z"
            )
            await #expect(throws: MigrationContainerInspectionError.unsupported(
                "container app uses unsupported named-volume modes in db-data:/var/lib/app:z"
            )) {
                _ = try await collect(fixture)
            }
        }
    }

    @Test func emptyDockerConfigFromSentinelIsPortableButARealDependencyIsRejected() async throws {
        do {
            let fixture = makeFixture()
            var inspection = networkInspection()
            inspection["ConfigFrom"] = ["Network": ""]
            fixture.source.networkInspections["backend"] = inspection
            _ = try await collect(fixture)
        }
        do {
            let fixture = makeFixture()
            var inspection = networkInspection()
            inspection["ConfigFrom"] = ["Network": "swarm-config"]
            fixture.source.networkInspections["backend"] = inspection
            await #expect(throws: MigrationStrictInventoryError.unsupported(
                "network backend depends on non-local bridge or swarm state"
            )) {
                _ = try await collect(fixture)
            }
        }
    }

    @Test func deviceCustomRuntimeAndOutsideHomeBindsAreRejected() async {
        do {
            let fixture = makeFixture()
            fixture.source.containerInspections["container-id"] = containerInspection(
                mount: volumeMount,
                devices: [[
                    "PathOnHost": "/dev/sda",
                    "PathInContainer": "/dev/xvda",
                    "CgroupPermissions": "rwm"
                ]]
            )
            await #expect(throws: MigrationContainerInspectionError.unsupported(
                "container app uses host devices that are not portable into Dory's VM"
            )) {
                _ = try await collect(fixture)
            }
        }
        do {
            let fixture = makeFixture()
            fixture.source.containerInspections["container-id"] = containerInspection(
                mount: volumeMount,
                runtime: "nvidia"
            )
            await #expect(throws: MigrationContainerInspectionError.unsupported(
                "container app requires unbundled runtime nvidia"
            )) {
                _ = try await collect(fixture)
            }
        }
        await outsideHomeBindIsRejected()
    }

    @Test func capacityUnknownHostAndTransactionPeakFailuresAreRejected() async {
        do {
            let fixture = makeFixture()
            await #expect(throws: MigrationStrictInventoryError.incomplete(
                "macOS did not report available host storage"
            )) {
                _ = try await collect(fixture, availableHostBytes: -1)
            }
        }
        do {
            let fixture = makeFixture()
            await #expect(throws: MigrationStrictInventoryError.unsafe(
                "host storage has 4000000000 bytes but 4012010240 are required"
            )) {
                _ = try await collect(fixture, availableHostBytes: 4_000_000_000)
            }
        }
        await oversizedAndOverflowingInventoriesAreRejected()
    }

    @Test func hostArchitectureEngineBindingAndUnfinishedArtifactsFailClosed() async {
        do {
            let fixture = makeFixture()
            await #expect(throws: MigrationStrictInventoryError.unsupported(
                "public v1 requires an Apple Silicon Mac"
            )) {
                _ = try await collect(fixture, hostArchitecture: "x86_64")
            }
        }
        do {
            let fixture = makeFixture()
            fixture.source.snapshotValue.engineVersion = "changed"
            await #expect(throws: MigrationStrictInventoryError.incomplete(
                "engine version and running-state authority changed during collection"
            )) {
                _ = try await collect(fixture)
            }
        }
        await unfinishedArtifactsAreRejected()
    }

    @Test func malformedInspectAndUnsupportedMountTypesFailClosed() async {
        do {
            let fixture = makeFixture()
            var inspection = containerInspection(mount: volumeMount)
            inspection["HostConfig"] = "not-an-object"
            fixture.source.containerInspections["container-id"] = inspection
            await #expect(throws: MigrationContainerInspectionError.invalid("app")) {
                _ = try await collect(fixture)
            }
        }
        do {
            let fixture = makeFixture()
            fixture.source.containerInspections["container-id"] = containerInspection(mount: [
                "Type": "image",
                "Source": "ghcr.io/example/config:v1",
                "Target": "/config",
                "ReadOnly": true
            ])
            await #expect(throws: MigrationContainerInspectionError.unsupported(
                "container app uses unsupported image mount at /config"
            )) {
                _ = try await collect(fixture)
            }
        }
    }

    @Test func namedVolumesRequireThePinnedSignedHelperContract() async {
        let fixture = makeFixture()

        await #expect(throws: MigrationOperationPlanError.unsupportedCapability(
            "named volumes require the signed arm64 transfer helper"
        )) {
            _ = try await collect(fixture, transferHelper: nil)
        }
    }
}

@MainActor
private extension MigrationStrictInventoryRejectionTests {
    func outsideHomeBindIsRejected() async {
        let fixture = makeFixture()
        fixture.source.containerInspections["container-id"] = containerInspection(
            mount: [
                "Type": "bind",
                "Source": "/private/var/not-shared",
                "Target": "/data",
                "ReadOnly": false
            ]
        )
        await #expect(throws: MigrationContainerInspectionError.unsupported(
            "container app bind source /private/var/not-shared is outside Dory's shared home"
        )) {
            _ = try await collect(fixture)
        }
    }

    func oversizedAndOverflowingInventoriesAreRejected() async {
        do {
            let fixture = makeFixture()
            fixture.source.snapshotValue.images[0].sizeBytes = 120 * 1_024 * 1_024 * 1_024
            await #expect(throws: MigrationStrictInventoryError.self) {
                _ = try await collect(fixture)
            }
        }
        do {
            let fixture = makeFixture()
            fixture.source.snapshotValue.images[0].sizeBytes = Int64.max
            await #expect(throws: MigrationStrictInventoryError.incomplete(
                "incoming data usage overflow"
            )) {
                _ = try await collect(fixture)
            }
        }
        do {
            let fixture = makeFixture()
            fixture.source.snapshotValue.images[0].sizeBytes = -1
            await #expect(throws: MigrationStrictInventoryError.incomplete(
                "negative source images usage"
            )) {
                _ = try await collect(fixture)
            }
        }
    }

    func unfinishedArtifactsAreRejected() async {
        let fixture = makeFixture()
        fixture.source.snapshotValue.images[0].labels = [
            "dev.dory.operation.id": "unfinished",
            "dev.dory.operation.state": "staged"
        ]
        await #expect(throws: MigrationStrictInventoryError.unsafe(
            "the source engine contains unfinished Dory operation objects; recover them first"
        )) {
            _ = try await collect(fixture)
        }
    }
}
