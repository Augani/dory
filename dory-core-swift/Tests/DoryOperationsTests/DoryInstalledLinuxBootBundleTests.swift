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
                initrdLength: UInt64(initrd.count)
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
}
