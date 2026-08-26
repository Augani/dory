import CryptoKit
import Darwin
import DoryOperations
import Foundation
import XCTest

final class DoryInstalledLinuxBootBundleTests: XCTestCase {
    func testBundleRoundTripsAndMaterializesVerifiedArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-installed-boot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("kernel")
        let kernelOutput = directory.appendingPathComponent("direct-kernel")
        let initrdOutput = directory.appendingPathComponent("direct-initrd")
        let kernel = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0) })
        let initrd = Data((0..<131_101).map { UInt8(truncatingIfNeeded: $0 * 3) })
        let assets = DoryLinuxInstallerBootAssets(
            kernel: kernel,
            initrd: initrd,
            kernelISOPath: "casper/vmlinuz",
            initrdISOPath: "casper/initrd"
        )

        try DoryInstalledLinuxBootBundle.write(
            assets: assets,
            rootDevice: "/dev/vda2",
            toPath: bundle.path
        )

        XCTAssertTrue(DoryInstalledLinuxBootBundle.isBundle(atPath: bundle.path))
        XCTAssertEqual(
            try DoryInstalledLinuxBootBundle.descriptor(atPath: bundle.path),
            DoryInstalledLinuxBootDescriptor(
                rootDevice: "/dev/vda2",
                kernelLength: UInt64(kernel.count),
                initrdLength: UInt64(initrd.count),
                kernelSHA256: digest(kernel),
                initrdSHA256: digest(initrd)
            )
        )
        let descriptor = try DoryInstalledLinuxBootBundle.materialize(
            fromPath: bundle.path,
            kernelPath: kernelOutput.path,
            initrdPath: initrdOutput.path
        )
        XCTAssertEqual(descriptor.rootDevice, "/dev/vda2")
        XCTAssertEqual(try Data(contentsOf: kernelOutput), kernel)
        XCTAssertEqual(try Data(contentsOf: initrdOutput), initrd)
    }

    func testMaterializationRejectsCorruptPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-installed-boot-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("kernel")
        try DoryInstalledLinuxBootBundle.write(
            assets: DoryLinuxInstallerBootAssets(
                kernel: Data(repeating: 0x41, count: 4_096),
                initrd: Data(repeating: 0x42, count: 8_192),
                kernelISOPath: "kernel",
                initrdISOPath: "initrd"
            ),
            rootDevice: "/dev/vda7",
            toPath: bundle.path
        )
        let handle = try FileHandle(forUpdating: bundle)
        try handle.seekToEnd()
        try handle.seek(toOffset: try handle.offset() - 1)
        try handle.write(contentsOf: Data([0xff]))
        try handle.close()

        XCTAssertThrowsError(try DoryInstalledLinuxBootBundle.materialize(
            fromPath: bundle.path,
            kernelPath: directory.appendingPathComponent("kernel.out").path,
            initrdPath: directory.appendingPathComponent("initrd.out").path
        )) { error in
            XCTAssertEqual(error as? DoryInstalledLinuxBootBundleError, .digestMismatch)
        }
    }

    func testDescriptorMaterializationUsesPinnedBundleAndExactPlanDigest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-installed-boot-fd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("kernel")
        let originalKernel = Data(repeating: 0x31, count: 32_769)
        let originalInitrd = Data(repeating: 0x41, count: 65_539)
        try DoryInstalledLinuxBootBundle.write(
            assets: .init(
                kernel: originalKernel,
                initrd: originalInitrd,
                kernelISOPath: "kernel",
                initrdISOPath: "initrd"
            ),
            rootDevice: "/dev/vda3",
            toPath: bundle.path
        )
        let expectedBundleDigest = digest(try Data(contentsOf: bundle))
        let input = open(bundle.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(input, 0)
        defer { close(input) }

        let pinned = directory.appendingPathComponent("pinned")
        try FileManager.default.moveItem(at: bundle, to: pinned)
        try DoryInstalledLinuxBootBundle.write(
            assets: .init(
                kernel: Data(repeating: 0x51, count: 4_096),
                initrd: Data(repeating: 0x61, count: 8_192),
                kernelISOPath: "replacement-kernel",
                initrdISOPath: "replacement-initrd"
            ),
            rootDevice: "/dev/vda9",
            toPath: bundle.path
        )

        let kernelPath = directory.appendingPathComponent("kernel.out").path
        let initrdPath = directory.appendingPathComponent("initrd.out").path
        let kernelOutput = open(kernelPath, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        let initrdOutput = open(initrdPath, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(kernelOutput, 0)
        XCTAssertGreaterThanOrEqual(initrdOutput, 0)
        defer {
            close(kernelOutput)
            close(initrdOutput)
        }

        let descriptor = try DoryInstalledLinuxBootBundle.materializeVerifiedContents(
            fromFileDescriptor: input,
            expectedBundleSHA256: expectedBundleDigest,
            kernelFileDescriptor: kernelOutput,
            initrdFileDescriptor: initrdOutput
        )
        XCTAssertEqual(descriptor.rootDevice, "/dev/vda3")
        XCTAssertEqual(descriptor.kernelSHA256, digest(originalKernel))
        XCTAssertEqual(descriptor.initrdSHA256, digest(originalInitrd))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: kernelPath)), originalKernel)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: initrdPath)), originalInitrd)
    }

    func testDescriptorMaterializationRejectsWrongWholeBundleDigestBeforeCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-installed-boot-wrong-digest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("kernel")
        try DoryInstalledLinuxBootBundle.write(
            assets: .init(
                kernel: Data(repeating: 0x71, count: 4_096),
                initrd: Data(repeating: 0x81, count: 8_192),
                kernelISOPath: "kernel",
                initrdISOPath: "initrd"
            ),
            rootDevice: "/dev/vda2",
            toPath: bundle.path
        )
        let input = open(bundle.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        let kernelOutput = open(
            directory.appendingPathComponent("kernel.out").path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
            0o600
        )
        let initrdOutput = open(
            directory.appendingPathComponent("initrd.out").path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
            0o600
        )
        XCTAssertGreaterThanOrEqual(input, 0)
        XCTAssertGreaterThanOrEqual(kernelOutput, 0)
        XCTAssertGreaterThanOrEqual(initrdOutput, 0)
        defer {
            close(input)
            close(kernelOutput)
            close(initrdOutput)
        }

        XCTAssertThrowsError(try DoryInstalledLinuxBootBundle.materializeVerifiedContents(
            fromFileDescriptor: input,
            expectedBundleSHA256: String(repeating: "0", count: 64),
            kernelFileDescriptor: kernelOutput,
            initrdFileDescriptor: initrdOutput
        )) { error in
            XCTAssertEqual(
                error as? DoryInstalledLinuxBootBundleError,
                .artifactDigestMismatch
            )
        }
        var kernelInfo = stat()
        var initrdInfo = stat()
        XCTAssertEqual(fstat(kernelOutput, &kernelInfo), 0)
        XCTAssertEqual(fstat(initrdOutput, &initrdInfo), 0)
        XCTAssertEqual(kernelInfo.st_size, 0)
        XCTAssertEqual(initrdInfo.st_size, 0)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
