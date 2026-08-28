import Darwin
import Foundation
import Testing
@testable import dory_hv

struct EngineRuntimePolicyTests {
    private let dockerDataDiskUUID = UUID(
        uuidString: "12345678-90ab-4cde-8fab-1234567890ab"
    )!

    @Test func engineMemoryPolicyRejectsAnUnrepresentableGuestMappingBeforeBoot() throws {
        try EngineMode.validateMemoryMB(62 * 1_024)

        do {
            try EngineMode.validateMemoryMB(64 * 1_024)
            Issue.record("64 GiB must exceed the ARM guest-physical aperture")
        } catch {
            #expect(String(describing: error).contains("must not exceed 63488 MiB"))
            #expect(String(describing: error).contains("64-GiB"))
        }
    }

    @Test func reclaimPolicyHasOnlyExplicitStableWireValues() {
        #expect(EngineMode.ReclaimPolicy(rawValue: "drop-caches") == .dropCaches)
        #expect(EngineMode.ReclaimPolicy(rawValue: "senpai") == .senpai)
        #expect(EngineMode.ReclaimPolicy(rawValue: "dropcaches") == nil)
        #expect(EngineMode.ReclaimPolicy(rawValue: "SENPAI") == nil)
    }

    @Test func fuseQueuePolicyIsBoundedAndDeterministic() throws {
        #expect(EngineMode.FuseRequestQueuePolicy.automatic.resolved(cpuCount: 0) == 1)
        #expect(EngineMode.FuseRequestQueuePolicy.automatic.resolved(cpuCount: 4) == 4)
        #expect(EngineMode.FuseRequestQueuePolicy.automatic.resolved(cpuCount: 64) == 8)
        #expect(
            try EngineMode.FuseRequestQueuePolicy(fixedCount: 3).resolved(cpuCount: 64) == 3
        )
        #expect(throws: (any Error).self) {
            _ = try EngineMode.FuseRequestQueuePolicy(fixedCount: 0)
        }
        #expect(throws: (any Error).self) {
            _ = try EngineMode.FuseRequestQueuePolicy(fixedCount: 9)
        }
    }

    @Test func inheritedDockerDataDiskArgumentsRequireTheExactSupervisorTuple() throws {
        var arguments = EngineMode.DockerDataDiskArguments()
        try arguments.setDataDrive("/Volumes/Test/Dory.dorydrive")
        try arguments.setInheritedFileDescriptor("19")
        try arguments.setExpectedFilesystemUUID(
            dockerDataDiskUUID.uuidString.lowercased()
        )

        #expect(
            try arguments.resolvedSelection() == .inherited(
                fileDescriptor: 19,
                expectedFilesystemUUID: dockerDataDiskUUID,
                dataDriveArgument: "/Volumes/Test/Dory.dorydrive"
            )
        )

        var wrongDescriptor = EngineMode.DockerDataDiskArguments()
        #expect(
            throws: EngineMode.DockerDataDiskArgumentError.invalidFileDescriptor("18")
        ) {
            try wrongDescriptor.setInheritedFileDescriptor("18")
        }

        var noncanonicalUUID = EngineMode.DockerDataDiskArguments()
        #expect(
            throws: EngineMode.DockerDataDiskArgumentError.invalidFilesystemUUID(
                dockerDataDiskUUID.uuidString
            )
        ) {
            try noncanonicalUUID.setExpectedFilesystemUUID(
                dockerDataDiskUUID.uuidString
            )
        }
    }

    @Test func dockerDataDiskArgumentsRejectDuplicatesMixesAndIncompletePairs() throws {
        var duplicateDrive = EngineMode.DockerDataDiskArguments()
        try duplicateDrive.setDataDrive("/Volumes/One/Dory.dorydrive")
        #expect(throws: EngineMode.DockerDataDiskArgumentError.duplicate("--data-drive")) {
            try duplicateDrive.setDataDrive("/Volumes/Two/Dory.dorydrive")
        }

        var duplicateDescriptor = EngineMode.DockerDataDiskArguments()
        try duplicateDescriptor.setInheritedFileDescriptor("19")
        #expect(
            throws: EngineMode.DockerDataDiskArgumentError.duplicate(
                "--docker-data-disk-fd"
            )
        ) {
            try duplicateDescriptor.setInheritedFileDescriptor("19")
        }

        var duplicateUUID = EngineMode.DockerDataDiskArguments()
        try duplicateUUID.setExpectedFilesystemUUID(
            dockerDataDiskUUID.uuidString.lowercased()
        )
        #expect(
            throws: EngineMode.DockerDataDiskArgumentError.duplicate(
                "--docker-data-disk-uuid"
            )
        ) {
            try duplicateUUID.setExpectedFilesystemUUID(
                dockerDataDiskUUID.uuidString.lowercased()
            )
        }

        var duplicateLegacyPath = EngineMode.DockerDataDiskArguments()
        try duplicateLegacyPath.setLegacyPath("/tmp/one.ext4")
        #expect(throws: EngineMode.DockerDataDiskArgumentError.duplicate("--data-disk")) {
            try duplicateLegacyPath.setLegacyPath("/tmp/two.ext4")
        }

        var mixed = EngineMode.DockerDataDiskArguments()
        try mixed.setDataDrive("/Volumes/Test/Dory.dorydrive")
        try mixed.setLegacyPath("/tmp/docker.ext4")
        #expect(throws: EngineMode.DockerDataDiskArgumentError.conflictingAuthorities) {
            _ = try mixed.resolvedSelection()
        }

        var legacyWithInheritedDescriptor = EngineMode.DockerDataDiskArguments()
        try legacyWithInheritedDescriptor.setLegacyPath("/tmp/docker.ext4")
        try legacyWithInheritedDescriptor.setInheritedFileDescriptor("19")
        #expect(throws: EngineMode.DockerDataDiskArgumentError.conflictingAuthorities) {
            _ = try legacyWithInheritedDescriptor.resolvedSelection()
        }

        var legacyWithInheritedUUID = EngineMode.DockerDataDiskArguments()
        try legacyWithInheritedUUID.setLegacyPath("/tmp/docker.ext4")
        try legacyWithInheritedUUID.setExpectedFilesystemUUID(
            dockerDataDiskUUID.uuidString.lowercased()
        )
        #expect(throws: EngineMode.DockerDataDiskArgumentError.conflictingAuthorities) {
            _ = try legacyWithInheritedUUID.resolvedSelection()
        }

        var missingDescriptor = EngineMode.DockerDataDiskArguments()
        try missingDescriptor.setDataDrive("/Volumes/Test/Dory.dorydrive")
        try missingDescriptor.setExpectedFilesystemUUID(
            dockerDataDiskUUID.uuidString.lowercased()
        )
        #expect(throws: EngineMode.DockerDataDiskArgumentError.missingFileDescriptor) {
            _ = try missingDescriptor.resolvedSelection()
        }

        var missingUUID = EngineMode.DockerDataDiskArguments()
        try missingUUID.setDataDrive("/Volumes/Test/Dory.dorydrive")
        try missingUUID.setInheritedFileDescriptor("19")
        #expect(throws: EngineMode.DockerDataDiskArgumentError.missingFilesystemUUID) {
            _ = try missingUUID.resolvedSelection()
        }

        var missingDrive = EngineMode.DockerDataDiskArguments()
        try missingDrive.setInheritedFileDescriptor("19")
        try missingDrive.setExpectedFilesystemUUID(
            dockerDataDiskUUID.uuidString.lowercased()
        )
        #expect(throws: EngineMode.DockerDataDiskArgumentError.missingDataDrive) {
            _ = try missingDrive.resolvedSelection()
        }
    }

    @Test func explicitStandaloneDockerDataDiskArgumentsRemainAvailable() throws {
        var managedDrive = EngineMode.DockerDataDiskArguments()
        try managedDrive.setDataDrive("/Volumes/Test/Dory.dorydrive")
        #expect(
            try managedDrive.resolvedSelection()
                == .standaloneDataDrive("/Volumes/Test/Dory.dorydrive")
        )

        var developerPath = EngineMode.DockerDataDiskArguments()
        try developerPath.setLegacyPath("/tmp/docker-data.ext4")
        #expect(
            try developerPath.resolvedSelection()
                == .standalonePath("/tmp/docker-data.ext4")
        )

        let empty = EngineMode.DockerDataDiskArguments()
        #expect(throws: EngineMode.DockerDataDiskArgumentError.missingAuthority) {
            _ = try empty.resolvedSelection()
        }
    }

    @Test func inheritedDockerDataDiskUUIDIsFormattedAndVerifiedBeforeMutation() {
        let script = EngineMode.guestBootScript(
            allowDockerDataFormat: true,
            expectedDockerDataDiskUUID: dockerDataDiskUUID
        )
        let canonicalUUID = dockerDataDiskUUID.uuidString.lowercased()
        #expect(script.contains("DORY_DOCKER_DATA_UUID='\(canonicalUUID)'"))
        let formatPrefix = #"mkfs.ext4 -U "$DORY_DOCKER_DATA_UUID""#
        #expect(script.components(separatedBy: formatPrefix).count - 1 == 2)

        let lines = script.split(separator: "\n").map(String.init)
        let existingMarker = lines.firstIndex(
            of: #"if blkid /dev/vdb 2>/dev/null | grep -q 'TYPE="ext4"'; then"#
        )
        let verifyExisting = lines.firstIndex(
            of: "  dory_verify_docker_data_uuid || { echo DATA-DISK-UUID-MISMATCH; sync; poweroff -f; exit 1; }"
        )
        let growExisting = lines.firstIndex {
            $0.hasPrefix("  dory_grow_docker_data ||")
        }
        let mountExisting = lines.firstIndex {
            $0.hasPrefix("  dory_mount_docker_data ||")
        }
        #expect(existingMarker != nil)
        #expect(verifyExisting != nil)
        #expect(growExisting != nil)
        #expect(mountExisting != nil)
        if let existingMarker, let verifyExisting, let growExisting, let mountExisting {
            #expect(existingMarker < verifyExisting)
            #expect(verifyExisting < growExisting)
            #expect(growExisting < mountExisting)
        }
        #expect(
            script.contains(
                "dory_format_docker_data && dory_verify_docker_data_uuid && dory_mount_docker_data"
            )
        )
    }

    @Test func engineStateDirectoryIsOwnerPrivateAndDoesNotFollowFinalSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-engine-state-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fresh = root.appendingPathComponent("fresh", isDirectory: true).path
        #expect(try EngineMode.prepareStateDirectory(fresh) == fresh)
        var freshStatus = stat()
        #expect(lstat(fresh, &freshStatus) == 0)
        #expect(freshStatus.st_uid == geteuid())
        #expect(freshStatus.st_mode & mode_t(0o7777) == mode_t(0o700))

        let state = root.appendingPathComponent("runtime", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: false)
        #expect(chmod(state, mode_t(0o755)) == 0)

        #expect(try EngineMode.prepareStateDirectory(state) == state)
        var status = stat()
        #expect(lstat(state, &status) == 0)
        #expect(status.st_uid == geteuid())
        #expect(status.st_mode & mode_t(0o7777) == mode_t(0o700))

        let target = root.appendingPathComponent("target", isDirectory: true).path
        let alias = root.appendingPathComponent("alias", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
        #expect(symlink(target, alias) == 0)
        #expect(throws: (any Error).self) {
            _ = try EngineMode.prepareStateDirectory(alias)
        }
    }

    @Test func helperSourcesContainNoLegacyAmbientFilesystemPolicy() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )
        let forbidden = ["DORY_FUSE_", "DORY_ENGINE_RECLAIM_MODE"]
        var violations: [String] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbidden where source.contains(token) {
                violations.append("\(fileURL.lastPathComponent):\(token)")
            }
        }

        #expect(violations.isEmpty)
    }
}
