import DoryOperations
import XCTest

final class DoryInstallerISOTests: XCTestCase {
    func testDiscoversRootPartitionFromOptInInstalledDisk() throws {
        guard let path = ProcessInfo.processInfo.environment["DORY_TEST_INSTALLED_DISK"],
              !path.isEmpty else {
            throw XCTSkip("set DORY_TEST_INSTALLED_DISK for the real-disk GPT smoke test")
        }
        XCTAssertEqual(
            try DoryLinuxInstalledDiskInspector.rootDevice(atPath: path),
            "/dev/vda2"
        )
    }

    func testExtractsBootAssetsFromOptInRealInstallerISO() throws {
        guard let path = ProcessInfo.processInfo.environment["DORY_TEST_INSTALLER_ISO"],
              !path.isEmpty else {
            throw XCTSkip("set DORY_TEST_INSTALLER_ISO for the bounded real-media smoke test")
        }

        let compressedKernel = try DoryInstallerISOInspector.fileData(
            atISOPath: path,
            fromPath: "casper/vmlinuz",
            maximumBytes: 128 * 1024 * 1024
        )
        XCTAssertGreaterThan(compressedKernel.count, 1024 * 1024)
        let assets = try DoryLinuxInstallerBootAssetExtractor.extract(atPath: path)

        XCTAssertGreaterThan(assets.kernel.count, 1024 * 1024)
        XCTAssertGreaterThan(assets.initrd.count, 1024 * 1024)
        XCTAssertEqual(assets.kernel[0x38], 0x41)
        XCTAssertEqual(assets.kernel[0x39], 0x52)
        XCTAssertEqual(assets.kernel[0x3a], 0x4d)
        XCTAssertEqual(assets.kernel[0x3b], 0x64)
    }

    func testInstallerResourcePolicyUsesBalancedDefaultsWithoutClaimingCompatibility() {
        XCTAssertEqual(DoryInstallerMachinePolicy.defaultCPUCount, 4)
        XCTAssertEqual(DoryInstallerMachinePolicy.defaultMemoryMB, 4_096)
    }

    func testDetectsEFILoaderArchitectureAcrossChunkBoundary() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-iso-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let arm = base.appendingPathComponent("arm.iso")
        var armBytes = Data(repeating: 0, count: 1024 * 1024 - 4)
        armBytes.append(Data("bootaa64.efi".utf8))
        try armBytes.write(to: arm)
        XCTAssertEqual(
            try DoryInstallerISOInspector.architecture(atPath: arm.path),
            .arm64
        )

        let x86 = base.appendingPathComponent("x86.iso")
        try Data("EFI/BOOT/BOOTX64.EFI".utf8).write(to: x86)
        XCTAssertEqual(
            try DoryInstallerISOInspector.architecture(atPath: x86.path),
            .x86_64
        )
    }

    func testReportsMultiArchitectureAndUnknownMedia() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-iso-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let mixed = base.appendingPathComponent("mixed.iso")
        try Data("BOOTAA64.EFI---BOOTX64.EFI".utf8).write(to: mixed)
        XCTAssertEqual(
            try DoryInstallerISOInspector.architecture(atPath: mixed.path),
            .multiArchitecture
        )

        let unknown = base.appendingPathComponent("unknown.iso")
        try Data("custom loader".utf8).write(to: unknown)
        XCTAssertEqual(
            try DoryInstallerISOInspector.architecture(atPath: unknown.path),
            .unknown
        )
    }

    func testCompatibilityMessagesMatchTheHostArchitecture() {
        XCTAssertEqual(
            DoryInstallerISOInspector.compatibility(of: .arm64, hostArchitecture: "arm64"),
            .compatible
        )
        XCTAssertEqual(
            DoryInstallerISOInspector.compatibility(of: .multiArchitecture, hostArchitecture: "arm64"),
            .compatible
        )
        XCTAssertEqual(
            DoryInstallerISOInspector.compatibility(of: .unknown, hostArchitecture: "arm64"),
            .unknown
        )
        guard case let .incompatible(message) = DoryInstallerISOInspector.compatibility(
            of: .x86_64,
            hostArchitecture: "aarch64"
        ) else {
            return XCTFail("x86_64 media should be incompatible with Apple Silicon")
        }
        XCTAssertTrue(message.contains("Intel x86_64-only"))
        XCTAssertTrue(message.contains("Apple Silicon"))
    }

    func testMediaIdentityIncludesArchitectureSizeAndSHA256() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-iso-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let media = base.appendingPathComponent("installer.iso")
        let contents = Data("EFI/BOOT/BOOTAA64.EFI\nqualified-by-digest".utf8)
        try contents.write(to: media)

        let identity = try DoryInstallerISOInspector.mediaIdentity(atPath: media.path)

        XCTAssertEqual(identity.architecture, .arm64)
        XCTAssertEqual(identity.byteCount, UInt64(contents.count))
        XCTAssertEqual(
            identity.sha256,
            "8f0bf0de7de4e656b9f29d4252461df93c6cb0d075d9cb993accd5722f48c27e"
        )
    }

    func testRuntimeCatalogSeparatesArchitectureFromExactHostMediaEvidence() {
        let ubuntu24044 = DoryInstallerISOMediaIdentity(
            architecture: .arm64,
            sha256: DoryInstallerISORuntimeCatalog.ubuntu24044DesktopARM64SHA256,
            byteCount: 3_556_515_840
        )
        let failingHost = DoryInstallerHostRuntime(
            architecture: "arm64",
            hardwareModel: "Mac14,10",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
            operatingSystemBuild: "26A5406e",
            runtimeProfile: DoryInstallerRuntimeProfile.legacyVirtioBlockV1.rawValue
        )
        guard case let .knownUnstable(message) = DoryInstallerISORuntimeCatalog.qualification(
            of: ubuntu24044,
            on: failingHost
        ) else {
            return XCTFail("the observed host/media tuple must be kept out of the installer path")
        }
        XCTAssertTrue(message.contains("retired VirtIO-block EFI profile"))

        let ubuntu24043 = DoryInstallerISOMediaIdentity(
            architecture: .arm64,
            sha256: DoryInstallerISORuntimeCatalog.ubuntu24043DesktopARM64SHA256,
            byteCount: 3_473_190_912
        )
        guard case .knownUnstable = DoryInstallerISORuntimeCatalog.qualification(
            of: ubuntu24043,
            on: failingHost
        ) else {
            return XCTFail("24.04.3 also froze under the retired VirtIO-block profile")
        }

        let currentStorageProfile = DoryInstallerHostRuntime(
            architecture: "arm64",
            hardwareModel: "Mac14,10",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
            operatingSystemBuild: "26A5406e",
            runtimeProfile: DoryInstallerRuntimeProfile.nativeNVMeFsyncV1.rawValue
        )
        XCTAssertEqual(
            DoryInstallerISORuntimeCatalog.qualification(of: ubuntu24043, on: currentStorageProfile),
            .unqualified
        )

        let differentBuild = DoryInstallerHostRuntime(
            architecture: "arm64",
            hardwareModel: "Mac14,10",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0),
            operatingSystemBuild: "26B100",
            runtimeProfile: DoryInstallerRuntimeProfile.legacyVirtioBlockV1.rawValue
        )
        XCTAssertEqual(
            DoryInstallerISORuntimeCatalog.qualification(of: ubuntu24044, on: differentBuild),
            .unqualified
        )
    }

    func testStagesCompatibleMediaAsAPrivateRegularFile() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-iso-stager-\(UUID().uuidString)")
        let sourceDirectory = base.appendingPathComponent("source", isDirectory: true)
        let stagingDirectory = base.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let source = sourceDirectory.appendingPathComponent("ubuntu.iso")
        let contents = Data("EFI/BOOT/BOOTAA64.EFI\nubuntu desktop".utf8)
        try contents.write(to: source)

        let staged = try DoryInstallerISOStager.stage(
            atPath: source.path,
            stagingDirectory: stagingDirectory,
            hostArchitecture: "arm64"
        )

        XCTAssertEqual(staged.architecture, .arm64)
        XCTAssertEqual(staged.identity.byteCount, UInt64(contents.count))
        XCTAssertFalse(staged.sha256.isEmpty)
        XCTAssertEqual(staged.runtimeQualification, .unqualified)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: staged.path)), contents)
        let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: stagingDirectory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testRejectsIncompatibleMediaBeforeCreatingAStagingDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-iso-stager-rejection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("omarchy.iso")
        let stagingDirectory = base.appendingPathComponent("staging", isDirectory: true)
        try Data("EFI/BOOT/BOOTX64.EFI".utf8).write(to: source)

        XCTAssertThrowsError(try DoryInstallerISOStager.stage(
            atPath: source.path,
            stagingDirectory: stagingDirectory,
            hostArchitecture: "arm64"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("Intel x86_64-only"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    func testRejectsOptInRealX86InstallerBeforeStaging() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["DORY_TEST_X86_64_INSTALLER_ISO"],
              !sourcePath.isEmpty else {
            throw XCTSkip(
                "set DORY_TEST_X86_64_INSTALLER_ISO for the real-media architecture gate"
            )
        }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-real-iso-rejection-\(UUID().uuidString)")
        let stagingDirectory = base.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let identity = try DoryInstallerISOInspector.mediaIdentity(atPath: sourcePath)
        XCTAssertEqual(identity.architecture, .x86_64)
        if let expectedSHA256 = environment["DORY_TEST_INSTALLER_ISO_SHA256"],
           !expectedSHA256.isEmpty {
            XCTAssertEqual(identity.sha256, expectedSHA256.lowercased())
        }

        XCTAssertThrowsError(try DoryInstallerISOStager.stage(
            atPath: sourcePath,
            stagingDirectory: stagingDirectory,
            hostArchitecture: "arm64"
        )) { error in
            guard case let .incompatible(message) = error as? DoryInstallerISOStagingError else {
                return XCTFail("expected an incompatible-media rejection, got \(error)")
            }
            XCTAssertEqual(
                message,
                "This ISO is Intel x86_64-only. Apple Silicon requires an arm64 EFI ISO."
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagingDirectory.path),
            "the rejected ISO must not be copied or cloned into managed staging"
        )
    }
}
