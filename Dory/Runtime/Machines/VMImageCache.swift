import Foundation

@MainActor
final class VMImageCache {
    static let baseDirectory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/machines")

    private let fileManager = FileManager.default

    func prepareBaseImage(for distro: VMDistro, progress: @escaping (String) -> Void) async throws {
        let cache = cacheDirectory(for: distro)
        try ensureDirectory(cache)
        let kernel = cache.appendingPathComponent("vmlinuz")
        let initrd = cache.appendingPathComponent("initrd")
        let rootTar = cache.appendingPathComponent("root.tar.xz")
        let baseDisk = cache.appendingPathComponent("base-disk.img")

        progress("Downloading \(distro.name) kernel…")
        try await VMFileDownloader.downloadIfNeeded(from: distro.kernelURL, to: kernel)
        progress("Downloading \(distro.name) initrd…")
        try await VMFileDownloader.downloadIfNeeded(from: distro.initrdURL, to: initrd)
        progress("Downloading \(distro.name) root filesystem…")
        try await VMFileDownloader.downloadIfNeeded(from: distro.rootTarURL, to: rootTar)

        guard !fileManager.fileExists(atPath: baseDisk.path) else { return }
        progress("Building base disk image (one-time, ~8 GB)…")
        try await buildBaseDisk(rootTar: rootTar, baseDisk: baseDisk, progress: progress)
    }

    func baseDisk(for distro: VMDistro) -> URL {
        cacheDirectory(for: distro).appendingPathComponent("base-disk.img")
    }

    func kernel(for distro: VMDistro) -> URL {
        cacheDirectory(for: distro).appendingPathComponent("vmlinuz")
    }

    func initrd(for distro: VMDistro) -> URL {
        cacheDirectory(for: distro).appendingPathComponent("initrd")
    }

    func vmDirectory(name: String) -> URL {
        Self.baseDirectory.appendingPathComponent(name)
    }

    private func cacheDirectory(for distro: VMDistro) -> URL {
        Self.baseDirectory.appendingPathComponent(".cache/\(distro.imageName)")
    }

    private func ensureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func buildBaseDisk(rootTar: URL, baseDisk: URL, progress: @escaping (String) -> Void) async throws {
        guard let binary = SharedVMProvisioner.containerBinary() else {
            throw VMError.sharedEngineUnavailable
        }
        let cache = rootTar.deletingLastPathComponent()
        let script = """
        set -e
        rm -f /cache/base-disk.img
        truncate -s 8589934592 /cache/base-disk.img
        LOOP=$(losetup -f --show /cache/base-disk.img)
        mkfs.ext4 -F "$LOOP"
        mkdir -p /mnt
        mount "$LOOP" /mnt
        tar -xpf /cache/root.tar.xz -C /mnt
        umount /mnt
        losetup -d "$LOOP"
        """
        let result = await Shell.runAsyncResult(binary, [
            "run", "--rm", "--cap-add", "ALL",
            "-v", "\(cache.path):/cache",
            "ubuntu:24.04", "sh", "-c", script
        ])
        guard result.exit == 0 else {
            throw VMError.diskBuildFailed(result.output)
        }
        progress("Base disk ready.")
    }
}
