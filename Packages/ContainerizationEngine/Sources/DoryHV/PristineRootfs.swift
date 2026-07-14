import Foundation

/// Keeps `<state>/rootfs-pristine.ext4` in sync with the engine rootfs the app bundles.
///
/// The engine boots a throwaway clone of pristine every launch, so once a pristine exists a new app
/// version's bundled rootfs (new guest agent / new init) would be masked forever. This reinstalls
/// pristine on first run and whenever the bundled asset's identity changes, recorded in a sidecar
/// `<state>/rootfs-pristine.stamp` so the per-boot check stays O(1).
public enum PristineRootfs {
    /// Identity is `"<size>:<mtime_ns>"` of the bundled asset, not a content hash: hashing a ~1 GB
    /// image on every boot is too slow, and size+mtime already changes whenever the app ships a new
    /// rootfs.
    public static func identity(ofBundledRootfs path: String) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw VMError.invalidConfiguration("cannot read size of bundled rootfs \(path)")
        }
        guard let modified = attributes[.modificationDate] as? Date else {
            throw VMError.invalidConfiguration("cannot read mtime of bundled rootfs \(path)")
        }
        let mtimeNanoseconds = Int64((modified.timeIntervalSince1970 * 1_000_000_000).rounded())
        return "\(size):\(mtimeNanoseconds)"
    }

    /// (Re)installs the bundled rootfs into `<state>/rootfs-pristine.ext4` on first run and whenever
    /// the bundled identity differs from the recorded stamp. An ABSENT stamp is treated as stale so
    /// installs that predate stamping self-heal without manual deletion.
    public static func ensure(
        state: String,
        bundledRootfs: String,
        log: (String) -> Void = { _ in }
    ) throws {
        let pristine = state + "/rootfs-pristine.ext4"
        let stampPath = state + "/rootfs-pristine.stamp"
        let identity = try identity(ofBundledRootfs: bundledRootfs)

        let installed = FileManager.default.fileExists(atPath: pristine)
        let recordedStamp = try? String(contentsOfFile: stampPath, encoding: .utf8)
        let temporary = pristine + ".partial"
        // A SIGKILL can bypass defer/catch cleanup. This runs while EngineMode owns the state lock,
        // so an exact-name partial cannot belong to another active installer.
        try? FileManager.default.removeItem(atPath: temporary)
        guard !installed || recordedStamp != identity else { return }

        log(installed
            ? "engine rootfs changed; reinstalling pristine…"
            : "first run: installing bundled engine rootfs (one-time, offline)…")

        defer { try? FileManager.default.removeItem(atPath: temporary) }
        try FileManager.default.copyItem(atPath: bundledRootfs, toPath: temporary)
        try fsyncFile(temporary)
        // Same-directory rename atomically replaces an older pristine. The engine state lock
        // serializes callers, so a crash exposes either the complete old rootfs or the complete new
        // rootfs; the next run also removes any abandoned partial before copying.
        guard Darwin.rename(temporary, pristine) == 0 else {
            throw VMError.invalidConfiguration("cannot publish \(pristine): errno \(errno)")
        }
        // Stamp last: a crash before it lands leaves an absent/old stamp, and absent-means-stale
        // re-heals on the next boot rather than trusting a half-updated pair.
        try Data(identity.utf8).write(to: URL(fileURLWithPath: stampPath), options: .atomic)
    }

    /// Flushes the freshly copied pristine to stable storage before the rename, so a crash right
    /// after the rename cannot expose a file whose contents are still only in the page cache.
    private static func fsyncFile(_ path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw VMError.invalidConfiguration("cannot open \(path) to fsync: errno \(errno)")
        }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw VMError.invalidConfiguration("cannot fsync \(path): errno \(errno)")
        }
    }
}
