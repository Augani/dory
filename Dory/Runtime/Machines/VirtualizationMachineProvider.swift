import Foundation
import Virtualization

@MainActor
final class VirtualizationMachineProvider {
    private let cache = VMImageCache()
    private let fileManager = FileManager.default
    private var vms: [String: VZVirtualMachine] = [:]

    var isAvailable: Bool {
        VZVirtualMachine.isSupported
    }

    func list() -> [Machine] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: VMImageCache.baseDirectory.path) else { return [] }
        return names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            return loadMachine(name: name)
        }
    }

    func create(name: String, distro: VMDistro, progress: @escaping (String) -> Void) async throws {
        guard VZVirtualMachine.isSupported else { throw VMError.virtualizationUnavailable }
        try await ensureBaseImage(for: distro, progress: progress)

        let vmDir = cache.vmDirectory(name: name)
        try fileManager.createDirectory(at: vmDir, withIntermediateDirectories: true)
        let share = vmDir.appendingPathComponent("share")
        try fileManager.createDirectory(at: share, withIntermediateDirectories: true)

        let disk = vmDir.appendingPathComponent("disk.img")
        let baseDisk = cache.baseDisk(for: distro)
        if !fileManager.fileExists(atPath: disk.path) {
            try fileManager.copyItem(at: baseDisk, to: disk)
        }

        let keyPair = try generateSSHKey(in: vmDir)
        let seed = vmDir.appendingPathComponent("seed.iso")
        try await VMCloudInit.createSeedISO(name: name, publicKey: keyPair.publicKey, shareURL: share, outputURL: seed)

        let config = VMConfig(name: name, distro: distro.name, version: distro.version)
        try saveConfig(config, at: vmDir.appendingPathComponent("config.json"))

        progress("VM created. Starting…")
        try await start(name: name)
    }

    func start(name: String) async throws {
        guard VZVirtualMachine.isSupported else { throw VMError.virtualizationUnavailable }
        let vmDir = cache.vmDirectory(name: name)
        _ = try loadConfig(at: vmDir.appendingPathComponent("config.json"))
        let distro = VMDistro.ubuntu2404
        let vzConfig = try makeConfiguration(vmDir: vmDir, distro: distro)
        let vm = VZVirtualMachine(configuration: vzConfig)
        vms[name] = vm

        return try await withCheckedThrowingContinuation { continuation in
            vm.start { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: VMError.vmStartFailed(error.localizedDescription))
                }
            }
        }
    }

    func stop(name: String) async throws {
        guard let vm = vms[name] else { throw VMError.vmNotFound(name) }
        return try await withCheckedThrowingContinuation { continuation in
            vm.stop { error in
                if let error {
                    continuation.resume(throwing: VMError.vmStopFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func delete(name: String) async throws {
        if vms[name] != nil {
            _ = try? await stop(name: name)
            vms.removeValue(forKey: name)
        }
        let vmDir = cache.vmDirectory(name: name)
        try? fileManager.removeItem(at: vmDir)
    }

    func ipAddress(for name: String) -> String? {
        let path = cache.vmDirectory(name: name).appendingPathComponent("share/ip.txt").path
        guard let data = fileManager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sshKeyPath(for name: String) -> URL {
        cache.vmDirectory(name: name).appendingPathComponent("ssh_key")
    }

    func waitForIP(name: String, timeout: Duration = .seconds(120)) async -> String? {
        let start = ContinuousClock().now
        while ContinuousClock().now - start < timeout {
            if let ip = ipAddress(for: name), !ip.isEmpty { return ip }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    private func ensureBaseImage(for distro: VMDistro, progress: @escaping (String) -> Void) async throws {
        try await cache.prepareBaseImage(for: distro, progress: progress)
    }

    private func makeConfiguration(vmDir: URL, distro: VMDistro) throws -> VZVirtualMachineConfiguration {
        let kernel = cache.kernel(for: distro)
        let initrd = cache.initrd(for: distro)
        let disk = vmDir.appendingPathComponent("disk.img")
        let seed = vmDir.appendingPathComponent("seed.iso")
        let share = vmDir.appendingPathComponent("share")

        let bootLoader = VZLinuxBootLoader(kernelURL: kernel)
        bootLoader.initialRamdiskURL = initrd
        bootLoader.commandLine = "root=/dev/vda ro console=hvc0"

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = bootLoader
        configuration.cpuCount = 4
        configuration.memorySize = UInt64(4 * 1024 * 1024 * 1024)

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
        let diskDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)

        let seedAttachment = try VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true)
        let seedDevice = VZVirtioBlockDeviceConfiguration(attachment: seedAttachment)
        configuration.storageDevices = [diskDevice, seedDevice]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]

        let sharedDir = VZSharedDirectory(url: share, readOnly: false)
        let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: "share")
        fsDevice.share = VZSingleDirectoryShare(directory: sharedDir)
        configuration.directorySharingDevices = [fsDevice]

        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try configuration.validate()
        return configuration
    }

    private func loadMachine(name: String) -> Machine? {
        let vmDir = cache.vmDirectory(name: name)
        guard let config = try? loadConfig(at: vmDir.appendingPathComponent("config.json")) else { return nil }
        let running = vms[name]?.state == .running
        let info = AppleContainerRuntime.distroInfo(config.distro)
        return Machine(
            name: config.name,
            distro: info.distro,
            version: config.version,
            status: running ? .running : .stopped,
            cpuPercent: 0,
            memoryDisplay: "—",
            ip: ipAddress(for: name) ?? "—",
            letter: info.letter,
            badgeHex: info.hex
        )
    }

    private func generateSSHKey(in directory: URL) throws -> (privateKey: URL, publicKey: String) {
        let key = directory.appendingPathComponent("ssh_key")
        _ = try Shell.run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-f", key.path, "-N", ""])
        let pubPath = key.appendingPathExtension("pub")
        guard let data = fileManager.contents(atPath: pubPath.path),
              let pub = String(data: data, encoding: .utf8) else {
            throw VMError.cloudInitFailed("Could not read generated public key")
        }
        return (key, pub.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func saveConfig(_ config: VMConfig, at url: URL) throws {
        let data = try JSONEncoder().encode(config)
        try data.write(to: url)
    }

    private func loadConfig(at url: URL) throws -> VMConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VMConfig.self, from: data)
    }
}

private struct VMConfig: Codable {
    let name: String
    let distro: String
    let version: String
}
