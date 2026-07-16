import Darwin
import DoryOperations
import Foundation

nonisolated enum DesktopMachineDistro: String, CaseIterable, Identifiable, Sendable {
    case debian
    case ubuntu
    case kali

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .debian: "Debian"
        case .ubuntu: "Ubuntu"
        case .kali: "Kali Linux"
        }
    }

    var version: String {
        switch self {
        case .debian: "13"
        case .ubuntu: "24.04 LTS"
        case .kali: "Rolling"
        }
    }

    var desktopName: String { "Xfce" }

    var summary: String {
        switch self {
        case .debian: "Stable, clean desktop for everyday Linux and development"
        case .ubuntu: "Familiar Ubuntu base with long-term support packages"
        case .kali: "Security lab desktop with Kali's official rolling repository"
        }
    }

    var logoName: String { "logo-\(rawValue)" }

    var badgeHex: UInt32 {
        switch self {
        case .debian: 0xA80030
        case .ubuntu: 0xE95420
        case .kali: 0x367BF0
        }
    }

    var resourceStem: String { "dory-desktop-\(rawValue)-rootfs" }

    static func resolve(_ rawValue: String?) -> DesktopMachineDistro {
        rawValue.flatMap(Self.init(rawValue:)) ?? .debian
    }
}

nonisolated struct DesktopMachineAssets: Sendable, Equatable {
    var kernelPath: String
    var rootfsPath: String
}

nonisolated enum DesktopMachineAssetError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedHost
    case dataDriveUnavailable(String)
    case missingAsset(String)
    case unsafeAsset(String)
    case invalidAsset(String)
    case filesystem(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedHost:
            return "Desktop Linux currently requires an Apple Silicon Mac. Intel support is planned for a later release."
        case .dataDriveUnavailable(let detail):
            return "The selected Dory data drive is unavailable: \(detail)"
        case .missingAsset(let name):
            return "The Dory app is missing its verified Desktop Linux \(name) asset."
        case .unsafeAsset(let path):
            return "Dory refused an unsafe Desktop Linux asset at \(path)."
        case .invalidAsset(let path):
            return "The Desktop Linux asset failed validation: \(path)."
        case .filesystem(let detail):
            return "Could not prepare Desktop Linux on the selected Dory data drive: \(detail)"
        }
    }
}

nonisolated enum DesktopMachineAssetProvisioner {
    static let rootfsCapacityBytes: Int64 = 64 * 1024 * 1024 * 1024

    private struct Source {
        var path: String
        var compressed: Bool
    }

    static func prepare(
        home: String,
        environment: [String: String],
        resourceDirectory: String? = Bundle.main.resourcePath
    ) throws -> DesktopMachineAssets {
        #if arch(arm64)
        let arch = "arm64"
        #else
        throw DesktopMachineAssetError.unsupportedHost
        #endif
        let distro = DesktopMachineDistro.resolve(environment["DORY_DESKTOP_DISTRO"])

        let drive: DoryDataDrive
        do {
            let selection = try DoryDataDriveSelectionStore(home: home)
            guard let selected = try selection.inspectSelection() else {
                throw DesktopMachineAssetError.dataDriveUnavailable("no data drive is selected")
            }
            drive = selected
        } catch let error as DesktopMachineAssetError {
            throw error
        } catch {
            throw DesktopMachineAssetError.dataDriveUnavailable(String(describing: error))
        }

        let kernel = try source(
            overrideKeys: [
                "DORYD_DESKTOP_MACHINE_KERNEL",
                "DORYD_DESKTOP_KERNEL",
                "DORYD_MACHINE_KERNEL",
                "DORYD_GUEST_KERNEL",
            ],
            resourceNames: ["dory-desktop-kernel-\(arch)"],
            kind: "kernel",
            environment: environment,
            resourceDirectory: resourceDirectory
        )
        let rootfs = try source(
            overrideKeys: [
                "DORYD_DESKTOP_\(distro.rawValue.uppercased())_ROOTFS",
                "DORYD_DESKTOP_MACHINE_ROOTFS",
                "DORYD_DESKTOP_ROOTFS",
                "DORYD_MACHINE_ROOTFS",
                "DORYD_GUEST_ROOTFS",
            ],
            resourceNames: rootfsResourceNames(for: distro, arch: arch),
            kind: "root filesystem",
            environment: environment,
            resourceDirectory: resourceDirectory
        )
        return try prepare(
            kernel: kernel,
            rootfs: rootfs,
            destinationDirectory: drive.machinesDirectory + "/.assets",
            arch: arch,
            distro: distro
        )
    }

    static func prepare(
        kernelSource: String,
        rootfsSource: String,
        destinationDirectory: String,
        distro: DesktopMachineDistro = .debian,
        rootfsCapacity: Int64 = rootfsCapacityBytes
    ) throws -> DesktopMachineAssets {
        try prepare(
            kernel: Source(path: kernelSource, compressed: kernelSource.hasSuffix(".lzfse")),
            rootfs: Source(path: rootfsSource, compressed: rootfsSource.hasSuffix(".lzfse")),
            destinationDirectory: destinationDirectory,
            arch: "arm64",
            distro: distro,
            rootfsCapacity: rootfsCapacity
        )
    }

    private static func source(
        overrideKeys: [String],
        resourceNames: [String],
        kind: String,
        environment: [String: String],
        resourceDirectory: String?
    ) throws -> Source {
        for key in overrideKeys {
            guard let path = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { continue }
            guard isRegularFile(path) else {
                throw DesktopMachineAssetError.invalidAsset(path)
            }
            return Source(path: path, compressed: path.hasSuffix(".lzfse"))
        }
        if environment["DORYD_DISABLE_BUNDLED_MACHINE_ASSETS"] == "1" {
            throw DesktopMachineAssetError.missingAsset(kind)
        }
        if let resourceDirectory {
            for name in resourceNames {
                for suffix in [".lzfse", ""] {
                    let path = resourceDirectory + "/" + name + suffix
                    if isRegularFile(path) {
                        return Source(path: path, compressed: suffix == ".lzfse")
                    }
                }
            }
        }
        throw DesktopMachineAssetError.missingAsset(kind)
    }

    private static func prepare(
        kernel: Source,
        rootfs: Source,
        destinationDirectory: String,
        arch: String,
        distro: DesktopMachineDistro,
        rootfsCapacity: Int64 = rootfsCapacityBytes
    ) throws -> DesktopMachineAssets {
        guard rootfsCapacity >= 2 * 1024 * 1024 else {
            throw DesktopMachineAssetError.invalidAsset(rootfs.path)
        }
        try ensurePrivateDirectory(destinationDirectory)
        let lockPath = destinationDirectory + "/.prepare.lock"
        let lockDescriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard lockDescriptor >= 0 else {
            throw DesktopMachineAssetError.filesystem(errnoDescription("open asset lock"))
        }
        defer { close(lockDescriptor) }
        var lockInfo = stat()
        guard fstat(lockDescriptor, &lockInfo) == 0,
              (lockInfo.st_mode & S_IFMT) == S_IFREG,
              lockInfo.st_uid == getuid(),
              lockInfo.st_nlink == 1,
              fchmod(lockDescriptor, mode_t(0o600)) == 0 else {
            throw DesktopMachineAssetError.unsafeAsset(lockPath)
        }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw DesktopMachineAssetError.filesystem(errnoDescription("lock desktop assets"))
        }
        defer { flock(lockDescriptor, LOCK_UN) }

        let kernelPath = destinationDirectory + "/dory-desktop-kernel-\(arch)"
        let rootfsPath = destinationDirectory + "/" + preparedRootfsName(for: distro, arch: arch)
        try materialize(
            source: kernel,
            destination: kernelPath,
            tokenSuffix: "kernel-v1",
            validate: validateKernel
        )
        try materialize(
            source: rootfs,
            destination: rootfsPath,
            tokenSuffix: "rootfs-v1-capacity-\(rootfsCapacity)",
            prepareOutput: { path in
                guard truncate(path, off_t(rootfsCapacity)) == 0 else {
                    throw DesktopMachineAssetError.filesystem(errnoDescription("grow desktop root filesystem"))
                }
            },
            validate: { path in
                try validateRootfs(path, expectedCapacity: rootfsCapacity)
            }
        )
        return DesktopMachineAssets(kernelPath: kernelPath, rootfsPath: rootfsPath)
    }

    private static func rootfsResourceNames(for distro: DesktopMachineDistro, arch: String) -> [String] {
        let named = "\(distro.resourceStem)-\(arch).ext4"
        return distro == .debian ? [named, "dory-desktop-rootfs-\(arch).ext4"] : [named]
    }

    private static func preparedRootfsName(for distro: DesktopMachineDistro, arch: String) -> String {
        distro == .debian
            ? "dory-desktop-rootfs-\(arch).ext4"
            : "dory-desktop-\(distro.rawValue)-rootfs-\(arch).ext4"
    }

    private static func materialize(
        source: Source,
        destination: String,
        tokenSuffix: String,
        prepareOutput: (String) throws -> Void = { _ in },
        validate: (String) throws -> Void
    ) throws {
        let token = try sourceToken(source) + "|" + tokenSuffix
        let stamp = destination + ".source"
        if let current = try? String(contentsOfFile: stamp, encoding: .utf8),
           current == token,
           (try? validate(destination)) != nil {
            return
        }
        try rejectUnsafeExistingFile(destination)
        try rejectUnsafeExistingFile(stamp)

        let temporary = destination + ".partial-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        do {
            if source.compressed {
                try LZFSE.decompress(source: source.path, destination: temporary)
            } else {
                try FileManager.default.copyItem(atPath: source.path, toPath: temporary)
            }
            guard chmod(temporary, mode_t(0o600)) == 0 else {
                throw DesktopMachineAssetError.filesystem(errnoDescription("secure prepared desktop asset"))
            }
            try prepareOutput(temporary)
            try validate(temporary)
            let descriptor = open(temporary, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0, fsync(descriptor) == 0 else {
                if descriptor >= 0 { close(descriptor) }
                throw DesktopMachineAssetError.filesystem(errnoDescription("sync prepared desktop asset"))
            }
            close(descriptor)
            guard rename(temporary, destination) == 0 else {
                throw DesktopMachineAssetError.filesystem(errnoDescription("publish prepared desktop asset"))
            }
            try Data(token.utf8).write(to: URL(fileURLWithPath: stamp), options: .atomic)
            guard chmod(stamp, mode_t(0o600)) == 0 else {
                throw DesktopMachineAssetError.filesystem(errnoDescription("secure desktop asset stamp"))
            }
        } catch let error as DesktopMachineAssetError {
            throw error
        } catch {
            throw DesktopMachineAssetError.filesystem(String(describing: error))
        }
    }

    private static func sourceToken(_ source: Source) throws -> String {
        var info = stat()
        guard lstat(source.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0 else {
            throw DesktopMachineAssetError.invalidAsset(source.path)
        }
        return [
            source.path,
            String(info.st_dev),
            String(info.st_ino),
            String(info.st_size),
            String(info.st_mtimespec.tv_sec),
            String(info.st_mtimespec.tv_nsec),
            source.compressed ? "lzfse" : "raw",
        ].joined(separator: "|")
    }

    private static func ensurePrivateDirectory(_ path: String) throws {
        if mkdir(path, mode_t(0o700)) != 0, errno != EEXIST {
            throw DesktopMachineAssetError.filesystem(errnoDescription("create desktop asset directory"))
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else {
            throw DesktopMachineAssetError.unsafeAsset(path)
        }
    }

    private static func rejectUnsafeExistingFile(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw DesktopMachineAssetError.filesystem(errnoDescription("inspect desktop asset"))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1 else {
            throw DesktopMachineAssetError.unsafeAsset(path)
        }
    }

    private static func validateKernel(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 1024 * 1024,
              read(path: path, offset: 0x38, count: 4) == Data([0x41, 0x52, 0x4d, 0x64]) else {
            throw DesktopMachineAssetError.invalidAsset(path)
        }
    }

    private static func validateRootfs(_ path: String, expectedCapacity: Int64) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == expectedCapacity,
              read(path: path, offset: 1_080, count: 2) == Data([0x53, 0xef]) else {
            throw DesktopMachineAssetError.invalidAsset(path)
        }
    }

    private static func read(path: String, offset: off_t, count: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, count, offset)
        }
        guard result == count else { return nil }
        return Data(bytes)
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_size > 0
    }

    private static func errnoDescription(_ operation: String) -> String {
        "\(operation): \(String(cString: strerror(errno)))"
    }
}
