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

    func testPortableEFIIdentityRejectsAnUnstructuredLoaderMarker() throws {
        let media = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-portable-efi-bait-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: media) }
        try Data("EFI/BOOT/BOOTAA64.EFI\nnot-an-iso".utf8).write(to: media)

        XCTAssertEqual(
            try DoryInstallerISOInspector.architecture(atPath: media.path),
            .arm64,
            "the permissive preflight may still provide a compatibility hint"
        )
        XCTAssertThrowsError(
            try DoryInstallerISOInspector.portableEFIMediaIdentity(atPath: media.path)
        ) { error in
            guard case .notPortableEFIBootable = error as? DoryInstallerISOInspectionError else {
                return XCTFail("expected structural EFI rejection, got \(error)")
            }
        }
    }

    func testPortableEFIIdentityDoesNotTreatISO9660FilenameAsBootCarrier() throws {
        let media = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-portable-efi-arm64-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: media) }
        let contents = makePortableISO9660(loaderName: "BOOTAA64.EFI")
        try contents.write(to: media)

        XCTAssertEqual(contents.count, 24 * 2_048)
        XCTAssertThrowsError(
            try DoryInstallerISOInspector.portableEFIMediaIdentity(atPath: media.path)
        )
    }

    func testPortableEFIIdentityRejectsFilenameBaitWithInvalidPEApplication() throws {
        let media = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-portable-efi-invalid-pe-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: media) }
        try makePortableISO9660(
            loaderName: "BOOTAA64.EFI",
            validEFIApplication: false
        ).write(to: media)

        XCTAssertThrowsError(
            try DoryInstallerISOInspector.portableEFIMediaIdentity(atPath: media.path)
        ) { error in
            guard case .notPortableEFIBootable = error as? DoryInstallerISOInspectionError else {
                return XCTFail("expected invalid EFI application rejection, got \(error)")
            }
        }
    }

    func testPortableEFIIdentityTraversesFAT12FallbackPathAndIgnoresSlackBait() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-portable-fat12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let valid = base.appendingPathComponent("valid.img")
        try makeMBRFAT12EFI(includesFallbackEntry: true).write(to: valid)
        XCTAssertEqual(
            try DoryInstallerISOInspector.portableEFIMediaIdentity(atPath: valid.path)
                .architecture,
            .arm64
        )

        let bait = base.appendingPathComponent("slack-bait.img")
        try makeMBRFAT12EFI(includesFallbackEntry: false).write(to: bait)
        XCTAssertThrowsError(
            try DoryInstallerISOInspector.portableEFIMediaIdentity(atPath: bait.path)
        )
    }

    func testPortableEFIIdentityAcceptsCompleteFAT16LoaderLargerThanFourMiB() throws {
        let media = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-portable-fat16-large-loader-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: media) }
        try makeMBRFAT16EFIWithLargeLoader().write(to: media)

        XCTAssertEqual(
            try DoryInstallerISOInspector.portableEFIMediaIdentity(atPath: media.path)
                .architecture,
            .x86_64
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

        // Exercise the same strict carrier/FAT/PE path used by portable production admission,
        // rather than accepting a filename or raw marker as architecture authority.
        let identity = try DoryInstallerISOInspector.portableEFIMediaIdentity(
            atPath: sourcePath
        )
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

    private func makePortableISO9660(
        loaderName: String,
        validEFIApplication: Bool = true
    ) -> Data {
        let blockSize = 2_048
        var image = Data(repeating: 0, count: 24 * blockSize)
        let loader = validEFIApplication
            ? makeEFIApplicationPE(
                machine: loaderName.caseInsensitiveCompare("BOOTAA64.EFI") == .orderedSame
                    ? 0xAA64
                    : 0x8664
            )
            : Data("MZ\0\0filename-bait".utf8)

        var primary = Data(repeating: 0, count: blockSize)
        primary[0] = 1
        primary.replaceSubrange(1..<6, with: Data("CD001".utf8))
        primary[6] = 1
        let rootRecord = iso9660DirectoryRecord(
            identifier: Data([0]),
            extentLBA: 20,
            byteCount: UInt32(blockSize),
            isDirectory: true
        )
        primary.replaceSubrange(156..<(156 + rootRecord.count), with: rootRecord)
        image.replaceSubrange((16 * blockSize)..<(17 * blockSize), with: primary)

        var terminator = Data(repeating: 0, count: blockSize)
        terminator[0] = 255
        terminator.replaceSubrange(1..<6, with: Data("CD001".utf8))
        terminator[6] = 1
        image.replaceSubrange((17 * blockSize)..<(18 * blockSize), with: terminator)

        writeISO9660Directory(
            records: [
                iso9660DirectoryRecord(
                    identifier: Data([0]), extentLBA: 20,
                    byteCount: UInt32(blockSize), isDirectory: true
                ),
                iso9660DirectoryRecord(
                    identifier: Data([1]), extentLBA: 20,
                    byteCount: UInt32(blockSize), isDirectory: true
                ),
                iso9660DirectoryRecord(
                    identifier: Data("EFI".utf8), extentLBA: 21,
                    byteCount: UInt32(blockSize), isDirectory: true
                ),
            ],
            atLBA: 20,
            in: &image,
            blockSize: blockSize
        )
        writeISO9660Directory(
            records: [
                iso9660DirectoryRecord(
                    identifier: Data([0]), extentLBA: 21,
                    byteCount: UInt32(blockSize), isDirectory: true
                ),
                iso9660DirectoryRecord(
                    identifier: Data([1]), extentLBA: 20,
                    byteCount: UInt32(blockSize), isDirectory: true
                ),
                iso9660DirectoryRecord(
                    identifier: Data("BOOT".utf8), extentLBA: 22,
                    byteCount: UInt32(blockSize), isDirectory: true
                ),
            ],
            atLBA: 21,
            in: &image,
            blockSize: blockSize
        )
        writeISO9660Directory(
            records: [
                iso9660DirectoryRecord(
                    identifier: Data([0]), extentLBA: 22,
                    byteCount: UInt32(blockSize), isDirectory: true
                ),
                iso9660DirectoryRecord(
                    identifier: Data([1]), extentLBA: 21,
                    byteCount: UInt32(blockSize), isDirectory: true
                ),
                iso9660DirectoryRecord(
                    identifier: Data(loaderName.utf8), extentLBA: 23,
                    byteCount: UInt32(loader.count), isDirectory: false
                ),
            ],
            atLBA: 22,
            in: &image,
            blockSize: blockSize
        )
        image.replaceSubrange(
            (23 * blockSize)..<(23 * blockSize + loader.count),
            with: loader
        )
        return image
    }

    private func makeEFIApplicationPE(machine: UInt16) -> Data {
        let peOffset = 0x80
        let optionalHeaderSize = 0xF0
        var data = Data(repeating: 0, count: 512)
        data[0] = 0x4D
        data[1] = 0x5A
        putUInt32(UInt32(peOffset), into: &data, at: 0x3C)
        data.replaceSubrange(peOffset..<(peOffset + 4), with: Data([0x50, 0x45, 0, 0]))
        putUInt16(machine, into: &data, at: peOffset + 4)
        putUInt16(1, into: &data, at: peOffset + 6)
        putUInt16(UInt16(optionalHeaderSize), into: &data, at: peOffset + 20)
        putUInt16(0x0002, into: &data, at: peOffset + 22)
        putUInt16(0x020B, into: &data, at: peOffset + 24)
        putUInt32(64, into: &data, at: peOffset + 24 + 4)
        putUInt32(0x1C0, into: &data, at: peOffset + 24 + 16)
        putUInt32(0x1C0, into: &data, at: peOffset + 24 + 20)
        putUInt32(0x20, into: &data, at: peOffset + 24 + 32)
        putUInt32(0x20, into: &data, at: peOffset + 24 + 36)
        putUInt32(0x200, into: &data, at: peOffset + 24 + 56)
        putUInt32(0x1C0, into: &data, at: peOffset + 24 + 60)
        putUInt16(10, into: &data, at: peOffset + 24 + 68)
        putUInt32(16, into: &data, at: peOffset + 24 + 108)
        let section = peOffset + 24 + optionalHeaderSize
        data.replaceSubrange(section..<(section + 5), with: Data(".text".utf8))
        putUInt32(64, into: &data, at: section + 8)
        putUInt32(0x1C0, into: &data, at: section + 12)
        putUInt32(64, into: &data, at: section + 16)
        putUInt32(0x1C0, into: &data, at: section + 20)
        putUInt32(0x6000_0020, into: &data, at: section + 36)
        data[0x1C0] = 0xC3
        return data
    }

    private func makeMBRFAT12EFI(includesFallbackEntry: Bool) -> Data {
        let sectorBytes = 512
        let partitionSectors = 2_880
        let partitionOffset = sectorBytes
        var image = Data(repeating: 0, count: (partitionSectors + 1) * sectorBytes)
        image[446 + 4] = 0xEF
        putUInt32(1, into: &image, at: 446 + 8)
        putUInt32(UInt32(partitionSectors), into: &image, at: 446 + 12)
        image[510] = 0x55
        image[511] = 0xAA

        var boot = Data(repeating: 0, count: sectorBytes)
        boot.replaceSubrange(0..<3, with: Data([0xEB, 0x3C, 0x90]))
        putUInt16(UInt16(sectorBytes), into: &boot, at: 11)
        boot[13] = 1
        putUInt16(1, into: &boot, at: 14)
        boot[16] = 2
        putUInt16(224, into: &boot, at: 17)
        putUInt16(UInt16(partitionSectors), into: &boot, at: 19)
        boot[21] = 0xF0
        putUInt16(9, into: &boot, at: 22)
        boot[510] = 0x55
        boot[511] = 0xAA
        image.replaceSubrange(
            partitionOffset..<(partitionOffset + sectorBytes),
            with: boot
        )

        var fat = Data(repeating: 0, count: 9 * sectorBytes)
        fat[0] = 0xF0
        fat[1] = 0xFF
        fat[2] = 0xFF
        for cluster: UInt16 in [2, 3, 4] {
            putFAT12(0x0FFF, forCluster: cluster, into: &fat)
        }
        let firstFATOffset = partitionOffset + sectorBytes
        image.replaceSubrange(
            firstFATOffset..<(firstFATOffset + fat.count),
            with: fat
        )
        image.replaceSubrange(
            (firstFATOffset + fat.count)..<(firstFATOffset + fat.count * 2),
            with: fat
        )

        let rootOffset = partitionOffset + 19 * sectorBytes
        var root = Data(repeating: 0, count: 14 * sectorBytes)
        writeFATShortEntry(
            base: "EFI",
            ext: "",
            attributes: 0x10,
            firstCluster: 2,
            byteCount: 0,
            at: 0,
            in: &root
        )
        image.replaceSubrange(rootOffset..<(rootOffset + root.count), with: root)

        let dataOffset = partitionOffset + 33 * sectorBytes
        var efiDirectory = Data(repeating: 0, count: sectorBytes)
        writeFATShortEntry(
            base: "BOOT",
            ext: "",
            attributes: 0x10,
            firstCluster: 3,
            byteCount: 0,
            at: 0,
            in: &efiDirectory
        )
        image.replaceSubrange(dataOffset..<(dataOffset + sectorBytes), with: efiDirectory)

        var bootDirectory = Data(repeating: 0, count: sectorBytes)
        if includesFallbackEntry {
            writeFATShortEntry(
                base: "BOOTAA64",
                ext: "EFI",
                attributes: 0x20,
                firstCluster: 4,
                byteCount: 512,
                at: 0,
                in: &bootDirectory
            )
        } else {
            bootDirectory.replaceSubrange(128..<140, with: Data("BOOTAA64.EFI".utf8))
        }
        image.replaceSubrange(
            (dataOffset + sectorBytes)..<(dataOffset + 2 * sectorBytes),
            with: bootDirectory
        )
        let loader = makeEFIApplicationPE(machine: 0xAA64)
        image.replaceSubrange(
            (dataOffset + 2 * sectorBytes)..<(dataOffset + 2 * sectorBytes + loader.count),
            with: loader
        )
        return image
    }

    /// A standards-shaped FAT16 ESP whose fallback loader is deliberately larger than the old
    /// four-MiB inspection prefix. Its complete chain must be present before PE admission passes.
    private func makeMBRFAT16EFIWithLargeLoader() -> Data {
        let sectorBytes = 512
        let partitionSectors = 16_384
        let fatSectors = 64
        let rootDirectorySectors = 32
        let partitionOffset = sectorBytes
        let dataStartSector = 1 + 2 * fatSectors + rootDirectorySectors
        let loaderBytes = 5 * 1_024 * 1_024 + sectorBytes
        let loaderClusters = loaderBytes / sectorBytes
        var image = Data(repeating: 0, count: (partitionSectors + 1) * sectorBytes)

        image[446 + 4] = 0xEF
        putUInt32(1, into: &image, at: 446 + 8)
        putUInt32(UInt32(partitionSectors), into: &image, at: 446 + 12)
        image[510] = 0x55
        image[511] = 0xAA

        var boot = Data(repeating: 0, count: sectorBytes)
        boot.replaceSubrange(0..<3, with: Data([0xEB, 0x3C, 0x90]))
        putUInt16(UInt16(sectorBytes), into: &boot, at: 11)
        boot[13] = 1
        putUInt16(1, into: &boot, at: 14)
        boot[16] = 2
        putUInt16(512, into: &boot, at: 17)
        putUInt16(UInt16(partitionSectors), into: &boot, at: 19)
        boot[21] = 0xF8
        putUInt16(UInt16(fatSectors), into: &boot, at: 22)
        boot[510] = 0x55
        boot[511] = 0xAA
        image.replaceSubrange(
            partitionOffset..<(partitionOffset + sectorBytes),
            with: boot
        )

        var fat = Data(repeating: 0, count: fatSectors * sectorBytes)
        putUInt16(0xFFF8, into: &fat, at: 0)
        putUInt16(0xFFFF, into: &fat, at: 2)
        putUInt16(0xFFFF, into: &fat, at: 2 * 2)
        putUInt16(0xFFFF, into: &fat, at: 3 * 2)
        for index in 0..<loaderClusters {
            let cluster = 4 + index
            let next: UInt16 = index == loaderClusters - 1
                ? 0xFFFF
                : UInt16(cluster + 1)
            putUInt16(next, into: &fat, at: cluster * 2)
        }
        let firstFATOffset = partitionOffset + sectorBytes
        image.replaceSubrange(
            firstFATOffset..<(firstFATOffset + fat.count),
            with: fat
        )
        image.replaceSubrange(
            (firstFATOffset + fat.count)..<(firstFATOffset + fat.count * 2),
            with: fat
        )

        let rootOffset = partitionOffset + (1 + 2 * fatSectors) * sectorBytes
        var root = Data(repeating: 0, count: rootDirectorySectors * sectorBytes)
        writeFATShortEntry(
            base: "EFI", ext: "", attributes: 0x10,
            firstCluster: 2, byteCount: 0, at: 0, in: &root
        )
        image.replaceSubrange(rootOffset..<(rootOffset + root.count), with: root)

        let dataOffset = partitionOffset + dataStartSector * sectorBytes
        var efiDirectory = Data(repeating: 0, count: sectorBytes)
        writeFATShortEntry(
            base: "BOOT", ext: "", attributes: 0x10,
            firstCluster: 3, byteCount: 0, at: 0, in: &efiDirectory
        )
        image.replaceSubrange(dataOffset..<(dataOffset + sectorBytes), with: efiDirectory)

        var bootDirectory = Data(repeating: 0, count: sectorBytes)
        writeFATShortEntry(
            base: "BOOTX64", ext: "EFI", attributes: 0x20,
            firstCluster: 4, byteCount: UInt32(loaderBytes), at: 0,
            in: &bootDirectory
        )
        image.replaceSubrange(
            (dataOffset + sectorBytes)..<(dataOffset + 2 * sectorBytes),
            with: bootDirectory
        )

        var loader = Data(repeating: 0, count: loaderBytes)
        loader.replaceSubrange(0..<512, with: makeEFIApplicationPE(machine: 0x8664))
        image.replaceSubrange(
            (dataOffset + 2 * sectorBytes)..<(dataOffset + 2 * sectorBytes + loader.count),
            with: loader
        )
        return image
    }

    private func putFAT12(
        _ value: UInt16,
        forCluster cluster: UInt16,
        into fat: inout Data
    ) {
        let offset = Int(cluster) + Int(cluster / 2)
        if cluster & 1 == 0 {
            fat[offset] = UInt8(truncatingIfNeeded: value)
            fat[offset + 1] = (fat[offset + 1] & 0xF0)
                | UInt8(truncatingIfNeeded: value >> 8) & 0x0F
        } else {
            fat[offset] = (fat[offset] & 0x0F)
                | UInt8(truncatingIfNeeded: value << 4) & 0xF0
            fat[offset + 1] = UInt8(truncatingIfNeeded: value >> 4)
        }
    }

    private func writeFATShortEntry(
        base: String,
        ext: String,
        attributes: UInt8,
        firstCluster: UInt16,
        byteCount: UInt32,
        at offset: Int,
        in directory: inout Data
    ) {
        let baseBytes = Array(base.uppercased().utf8.prefix(8))
        let extBytes = Array(ext.uppercased().utf8.prefix(3))
        directory.replaceSubrange(offset..<(offset + 8), with: Data(
            baseBytes + Array(repeating: 0x20, count: 8 - baseBytes.count)
        ))
        directory.replaceSubrange((offset + 8)..<(offset + 11), with: Data(
            extBytes + Array(repeating: 0x20, count: 3 - extBytes.count)
        ))
        directory[offset + 11] = attributes
        putUInt16(firstCluster, into: &directory, at: offset + 26)
        putUInt32(byteCount, into: &directory, at: offset + 28)
    }

    private func iso9660DirectoryRecord(
        identifier: Data,
        extentLBA: UInt32,
        byteCount: UInt32,
        isDirectory: Bool
    ) -> Data {
        let padding = identifier.count.isMultiple(of: 2) ? 1 : 0
        var record = Data(repeating: 0, count: 33 + identifier.count + padding)
        record[0] = UInt8(record.count)
        putUInt32(extentLBA, into: &record, at: 2)
        putUInt32(byteCount, into: &record, at: 10)
        record[25] = isDirectory ? 0x02 : 0
        putUInt16(1, into: &record, at: 28)
        record[32] = UInt8(identifier.count)
        record.replaceSubrange(33..<(33 + identifier.count), with: identifier)
        return record
    }

    private func writeISO9660Directory(
        records: [Data],
        atLBA lba: Int,
        in image: inout Data,
        blockSize: Int
    ) {
        var directory = Data(repeating: 0, count: blockSize)
        var offset = 0
        for record in records {
            directory.replaceSubrange(offset..<(offset + record.count), with: record)
            offset += record.count
        }
        image.replaceSubrange((lba * blockSize)..<((lba + 1) * blockSize), with: directory)
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
