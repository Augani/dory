@testable import DoryOperations
import DoryCore
import XCTest

final class DoryInstallerISOTests: XCTestCase {
    func testMaterializesPEWrappedZstdZbootKernelWithExactBounds() throws {
        let rawKernel = rawARM64Image(marker: 0xa7)
        let compressedPayload = Data("synthetic-zstd-frame".utf8)
        let zboot = makeZboot(payload: compressedPayload, compression: "zstd")
        let wrapped = makePELinuxWrapper(sections: [(".linux", zboot)])

        let materialized = try DoryLinuxInstallerBootAssetExtractor.materializeARM64Kernel(
            wrapped,
            source: "casper/vmlinuz",
            zstdDecompressor: { payload, maximumOutputBytes in
                XCTAssertEqual(payload, compressedPayload)
                XCTAssertEqual(maximumOutputBytes, 256 * 1024 * 1024)
                return rawKernel
            }
        )

        XCTAssertEqual(materialized, rawKernel)
    }

    func testZbootParserRejectsUnavailableDecoderAndMalformedPEAuthority() throws {
        let zboot = makeZboot(payload: Data([0x28, 0xb5, 0x2f, 0xfd]), compression: "zstd")
        XCTAssertThrowsError(
            try DoryLinuxInstallerBootAssetExtractor.materializeARM64Kernel(
                zboot,
                source: "vmlinuz",
                zstdDecompressor: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? DoryLinuxInstallerBootAssetError,
                .zstdDecoderUnavailable("vmlinuz")
            )
        }

        let duplicate = makePELinuxWrapper(sections: [
            (".linux", zboot),
            (".linux", zboot),
        ])
        let fallbackRawKernel = rawARM64Image(marker: 0)
        XCTAssertThrowsError(
            try DoryLinuxInstallerBootAssetExtractor.materializeARM64Kernel(
                duplicate,
                source: "vmlinuz",
                zstdDecompressor: { _, _ in fallbackRawKernel }
            )
        ) { error in
            XCTAssertEqual(
                error as? DoryLinuxInstallerBootAssetError,
                .invalidPE("vmlinuz")
            )
        }

        var malformed = zboot
        putUInt32(UInt32(malformed.count - 2), into: &malformed, at: 8)
        putUInt32(8, into: &malformed, at: 12)
        XCTAssertThrowsError(
            try DoryLinuxInstallerBootAssetExtractor.materializeARM64Kernel(
                malformed,
                source: "vmlinuz",
                zstdDecompressor: { _, _ in fallbackRawKernel }
            )
        ) { error in
            XCTAssertEqual(
                error as? DoryLinuxInstallerBootAssetError,
                .invalidZboot("vmlinuz")
            )
        }
    }

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
        let assets = try DoryLinuxInstallerBootAssetExtractor.extract(
            atPath: path,
            zstdDecompressor: { body, maximumOutputBytes in
                try DoryCore.decompressZstd(
                    body,
                    maximumOutputBytes: maximumOutputBytes
                )
            }
        )

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

    private func rawARM64Image(marker: UInt8) -> Data {
        var data = Data(repeating: marker, count: 4 * 1024)
        putUInt32(0x644d_5241, into: &data, at: 0x38)
        return data
    }

    private func makeZboot(payload: Data, compression: String) -> Data {
        let payloadOffset = 0x100
        var data = Data(repeating: 0, count: payloadOffset + payload.count)
        data.replaceSubrange(0..<8, with: Data([0x4d, 0x5a, 0, 0, 0x7a, 0x69, 0x6d, 0x67]))
        putUInt32(UInt32(payloadOffset), into: &data, at: 8)
        putUInt32(UInt32(payload.count), into: &data, at: 12)
        let compressionBytes = Data(compression.utf8) + Data([0])
        data.replaceSubrange(24..<(24 + compressionBytes.count), with: compressionBytes)
        putUInt32(0x40, into: &data, at: 0x3c)
        data.replaceSubrange(0x40..<0x44, with: Data([0x50, 0x45, 0, 0]))
        putUInt16(0xaa64, into: &data, at: 0x44)
        data.replaceSubrange(payloadOffset..<(payloadOffset + payload.count), with: payload)
        return data
    }

    private func makePELinuxWrapper(sections: [(String, Data)]) -> Data {
        let peOffset = 0x80
        let sectionTableOffset = peOffset + 24
        let dataOffset = 0x400
        let totalPayloadSize = sections.reduce(0) { $0 + $1.1.count }
        var data = Data(repeating: 0, count: dataOffset + totalPayloadSize)
        data[0] = 0x4d
        data[1] = 0x5a
        putUInt32(UInt32(peOffset), into: &data, at: 0x3c)
        data.replaceSubrange(peOffset..<(peOffset + 4), with: Data([0x50, 0x45, 0, 0]))
        putUInt16(0xaa64, into: &data, at: peOffset + 4)
        putUInt16(UInt16(sections.count), into: &data, at: peOffset + 6)
        putUInt16(0, into: &data, at: peOffset + 20)

        var nextDataOffset = dataOffset
        for (index, section) in sections.enumerated() {
            let headerOffset = sectionTableOffset + index * 40
            let name = Array(section.0.utf8.prefix(8))
            data.replaceSubrange(
                headerOffset..<(headerOffset + name.count),
                with: Data(name)
            )
            putUInt32(UInt32(section.1.count), into: &data, at: headerOffset + 16)
            putUInt32(UInt32(nextDataOffset), into: &data, at: headerOffset + 20)
            data.replaceSubrange(
                nextDataOffset..<(nextDataOffset + section.1.count),
                with: section.1
            )
            nextDataOffset += section.1.count
        }
        return data
    }

    private func putUInt16(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func putUInt32(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
