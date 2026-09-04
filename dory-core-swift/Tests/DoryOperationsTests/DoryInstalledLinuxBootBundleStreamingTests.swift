import CryptoKit
import Darwin
import DoryOperations
import Foundation
import XCTest

final class DoryInstalledLinuxBootBundleStreamingTests: XCTestCase {
    func testRepeatedVerificationDrainsReadBuffersBeforeWorkerPoolDrains() throws {
        try withBundle { bundle, expected in
            try assertBoundedReadBuffers {
                XCTAssertEqual(try DoryInstalledLinuxBootBundle.verifyContents(atPath: bundle.path), expected)
            }
        }
    }

    func testRepeatedMaterializationDrainsReadBuffersAndPreservesPartialFinalChunks() throws {
        try withBundle { bundle, expected in
            let kernel = bundle.deletingLastPathComponent().appendingPathComponent("kernel.out")
            let initrd = bundle.deletingLastPathComponent().appendingPathComponent("initrd.out")
            try assertBoundedReadBuffers {
                let copied = try DoryInstalledLinuxBootBundle.materialize(
                    fromPath: bundle.path, kernelPath: kernel.path, initrdPath: initrd.path
                )
                XCTAssertEqual(copied, expected)
            }
            XCTAssertEqual(try digest(Data(contentsOf: kernel, options: .mappedIfSafe)), expected.kernelSHA256)
            XCTAssertEqual(try digest(Data(contentsOf: initrd, options: .mappedIfSafe)), expected.initrdSHA256)
        }
    }

    private func assertBoundedReadBuffers(_ operation: () throws -> Void) throws {
        // Warm the operation and drain its temporaries before measuring a long-lived worker pool.
        try autoreleasepool { try operation() }
        try autoreleasepool {
            let before = try residentBytes()
            for _ in 0..<4 { try operation() }
            let growth = Int64(clamping: try residentBytes()) - Int64(clamping: before)
            print("Installed boot bundle retained read-buffer growth: \(growth) bytes")
            // Four 68 MiB passes retain over 256 MiB without per-chunk pools. Allow ample allocator
            // headroom while rejecting growth proportional to the complete artifact payload.
            XCTAssertLessThan(growth, 64 * 1_024 * 1_024)
        }
    }

    private func residentBytes() throws -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return usage.ri_resident_size
    }

    private func withBundle(_ body: (URL, DoryInstalledLinuxBootDescriptor) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-installed-boot-streaming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("boot.bundle")
        let expected = try autoreleasepool {
            var kernel = Data(repeating: 0x31, count: 4 * 1_024 * 1_024 + 3)
            var initrd = Data(repeating: 0x52, count: 64 * 1_024 * 1_024 + 37)
            kernel[kernel.count - 1] = 0x91
            initrd[initrd.count - 1] = 0xa2
            try DoryInstalledLinuxBootBundle.write(
                assets: .init(kernel: kernel, initrd: initrd, kernelISOPath: "kernel", initrdISOPath: "initrd"),
                rootDevice: "/dev/vda3", toPath: bundle.path
            )
            return DoryInstalledLinuxBootDescriptor(
                rootDevice: "/dev/vda3", kernelLength: UInt64(kernel.count), initrdLength: UInt64(initrd.count),
                kernelSHA256: digest(kernel), initrdSHA256: digest(initrd)
            )
        }
        try body(bundle, expected)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
