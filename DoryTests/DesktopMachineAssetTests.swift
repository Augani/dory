import Foundation
import Testing
@testable import Dory

struct DesktopMachineAssetTests {
    @Test func preparesVerifiedSparseAssetsInTheDriveAndReusesMatchingOutputs() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-desktop-assets-\(UUID().uuidString)")
        let assets = base.appendingPathComponent("machines/.assets")
        let kernel = base.appendingPathComponent("Image-desktop")
        let rootfs = base.appendingPathComponent("desktop.ext4")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: assets.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var kernelBytes = Data(repeating: 0, count: 1024 * 1024)
        kernelBytes.replaceSubrange(0x38..<0x3c, with: [0x41, 0x52, 0x4d, 0x64])
        try kernelBytes.write(to: kernel)
        var rootfsBytes = Data(repeating: 0, count: 2 * 1024 * 1024)
        rootfsBytes.replaceSubrange(1_080..<1_082, with: [0x53, 0xef])
        try rootfsBytes.write(to: rootfs)

        let prepared = try DesktopMachineAssetProvisioner.prepare(
            kernelSource: kernel.path,
            rootfsSource: rootfs.path,
            destinationDirectory: assets.path,
            rootfsCapacity: 8 * 1024 * 1024
        )
        #expect(prepared.kernelPath == assets.appendingPathComponent("dory-desktop-kernel-arm64").path)
        #expect(prepared.rootfsPath == assets.appendingPathComponent("dory-desktop-rootfs-arm64.ext4").path)
        let rootfsSize = try #require(
            try FileManager.default.attributesOfItem(atPath: prepared.rootfsPath)[.size] as? NSNumber
        )
        #expect(rootfsSize.int64Value == 8 * 1024 * 1024)
        let firstModification = try #require(
            try FileManager.default.attributesOfItem(atPath: prepared.rootfsPath)[.modificationDate] as? Date
        )

        let reused = try DesktopMachineAssetProvisioner.prepare(
            kernelSource: kernel.path,
            rootfsSource: rootfs.path,
            destinationDirectory: assets.path,
            rootfsCapacity: 8 * 1024 * 1024
        )
        let secondModification = try #require(
            try FileManager.default.attributesOfItem(atPath: reused.rootfsPath)[.modificationDate] as? Date
        )
        #expect(secondModification == firstModification)
    }

    @Test func expandsLZFSEAppResourcesBeforeValidation() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-desktop-compressed-assets-\(UUID().uuidString)")
        let assets = base.appendingPathComponent("machines/.assets")
        let kernel = base.appendingPathComponent("Image-desktop")
        let rootfs = base.appendingPathComponent("desktop.ext4")
        let compressedKernel = base.appendingPathComponent("dory-desktop-kernel-arm64.lzfse")
        let compressedRootfs = base.appendingPathComponent("dory-desktop-rootfs-arm64.ext4.lzfse")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: assets.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var kernelBytes = Data(repeating: 0, count: 1024 * 1024)
        kernelBytes.replaceSubrange(0x38..<0x3c, with: [0x41, 0x52, 0x4d, 0x64])
        try kernelBytes.write(to: kernel)
        var rootfsBytes = Data(repeating: 0, count: 2 * 1024 * 1024)
        rootfsBytes.replaceSubrange(1_080..<1_082, with: [0x53, 0xef])
        try rootfsBytes.write(to: rootfs)
        try compressLZFSE(kernel, to: compressedKernel)
        try compressLZFSE(rootfs, to: compressedRootfs)

        let prepared = try DesktopMachineAssetProvisioner.prepare(
            kernelSource: compressedKernel.path,
            rootfsSource: compressedRootfs.path,
            destinationDirectory: assets.path,
            rootfsCapacity: 8 * 1024 * 1024
        )
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: prepared.kernelPath))
                .subdata(in: 0x38..<0x3c) == Data([0x41, 0x52, 0x4d, 0x64])
        )
        let rootfsSize = try #require(
            try FileManager.default.attributesOfItem(atPath: prepared.rootfsPath)[.size] as? NSNumber
        )
        #expect(rootfsSize.int64Value == 8 * 1024 * 1024)
    }

    @Test func keepsDistributionRootFilesystemsIsolated() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-desktop-distro-assets-\(UUID().uuidString)")
        let assets = base.appendingPathComponent("machines/.assets")
        let kernel = base.appendingPathComponent("Image-desktop")
        let rootfs = base.appendingPathComponent("ubuntu.ext4")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: assets.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var kernelBytes = Data(repeating: 0, count: 1024 * 1024)
        kernelBytes.replaceSubrange(0x38..<0x3c, with: [0x41, 0x52, 0x4d, 0x64])
        try kernelBytes.write(to: kernel)
        var rootfsBytes = Data(repeating: 0, count: 2 * 1024 * 1024)
        rootfsBytes.replaceSubrange(1_080..<1_082, with: [0x53, 0xef])
        try rootfsBytes.write(to: rootfs)

        let prepared = try DesktopMachineAssetProvisioner.prepare(
            kernelSource: kernel.path,
            rootfsSource: rootfs.path,
            destinationDirectory: assets.path,
            distro: .ubuntu,
            rootfsCapacity: 8 * 1024 * 1024
        )

        #expect(prepared.rootfsPath == assets.appendingPathComponent("dory-desktop-ubuntu-rootfs-arm64.ext4").path)
    }

    @Test func rejectsSymlinkedAssetDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-desktop-assets-symlink-\(UUID().uuidString)")
        let target = base.appendingPathComponent("target")
        let assets = base.appendingPathComponent("assets")
        let kernel = base.appendingPathComponent("Image-desktop")
        let rootfs = base.appendingPathComponent("desktop.ext4")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: target)
        try Data(repeating: 0, count: 16).write(to: kernel)
        try Data(repeating: 0, count: 2 * 1024 * 1024).write(to: rootfs)

        #expect(throws: DesktopMachineAssetError.self) {
            try DesktopMachineAssetProvisioner.prepare(
                kernelSource: kernel.path,
                rootfsSource: rootfs.path,
                destinationDirectory: assets.path,
                rootfsCapacity: 8 * 1024 * 1024
            )
        }
    }

    private func compressLZFSE(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/compression_tool")
        process.arguments = [
            "-encode",
            "-a", "lzfse",
            "-i", source.path,
            "-o", destination.path,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
