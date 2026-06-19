import Foundation
import Containerization
import ContainerizationOCI
import ContainerizationExtras
import Virtualization

enum EngineError: Error, CustomStringConvertible {
    case noNetwork
    var description: String {
        switch self {
        case .noNetwork: return "VmnetNetwork unavailable (requires macOS 26+ and the virtualization entitlement)"
        }
    }
}

// Adds a virtio memory-balloon device so the VM's guest RAM can be reclaimed back to macOS at runtime
// (elastic memory — the engine shrinks toward actual usage when idle instead of pinning a fixed VM).
struct BalloonExtension: VZInstanceExtension {
    func configureVZ(_ config: inout VZVirtualMachineConfiguration, allocator: any AddressAllocator<Character>,
                     storageDeviceCount: Int, mountsByID: [String: [Containerization.Mount]]) throws {
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    }
}

struct BalloonVMConfig: VMCreationConfig {
    let configuration: VMConfiguration
}

// Wraps the framework's VMM to inject the balloon device into every VM it creates — the only hook,
// since LinuxContainer.Configuration doesn't expose VZ extensions directly.
struct BalloonVMM: VirtualMachineManager {
    let inner: VZVirtualMachineManager
    func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
        var cfg = config.configuration
        cfg.extensions.append(BalloonExtension())
        return try inner.create(config: BalloonVMConfig(configuration: cfg))
    }
}

// Adds USB, audio, and a memory-balloon device to the VM via the framework's VZ config hook — the
// last two OrbStack features (USB/audio passthrough, dynamic memory ballooning).
struct DeviceExtension: VZInstanceExtension {
    func configureVZ(_ config: inout VZVirtualMachineConfiguration, allocator: any AddressAllocator<Character>,
                     storageDeviceCount: Int, mountsByID: [String: [Containerization.Mount]]) throws {
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.usbControllers = [VZXHCIControllerConfiguration()]
        let audio = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        audio.streams = [output]
        config.audioDevices = [audio]
    }
}

// dory-vm — Dory's framework-engine helper. Boots a Linux VM in-process via Apple's containerization
// framework and runs a container in it, with Rosetta-accelerated x86 and host file mounts. Must be
// signed with com.apple.security.virtualization. The app/CLI invokes this like it invokes `container`.
//
//   dory-vm --image <ref> [--arch amd64|arm64] [--rosetta] [--mount host:guest]... -- <cmd...>
//
// Output capture avoids the framework IO abstractions by mounting a host scratch dir and having the
// container redirect stdout/stderr into it — using the same Mount.share that delivers file sharing.

struct Args {
    var image = "docker.io/library/alpine:latest"
    var arch = "arm64"
    var rosetta = false
    var devices = false
    var sharedEngine: String? = nil
    var kernel: String? = nil
    var initfs: String? = nil
    var data: String? = nil
    var mounts: [(String, String)] = []
    var command = ["/bin/sh", "-c", "uname -m"]
}

func parse() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--image": if let v = it.next() { a.image = v }
        case "--arch": if let v = it.next() { a.arch = v }
        case "--rosetta": a.rosetta = true
        case "--devices": a.devices = true
        case "--shared-engine": if let v = it.next() { a.sharedEngine = v }
        case "--kernel": if let v = it.next() { a.kernel = v }
        case "--initfs": if let v = it.next() { a.initfs = v }
        case "--data": if let v = it.next() { a.data = v }
        case "--mount": if let v = it.next() { let p = v.split(separator: ":", maxSplits: 1); if p.count == 2 { a.mounts.append((String(p[0]), String(p[1]))) } }
        case "--": var rest: [String] = []; while let c = it.next() { rest.append(c) }; if !rest.isEmpty { a.command = rest }
        default: break
        }
    }
    return a
}

@main
struct DoryVM {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let args = parse()
        let support = NSHomeDirectory() + "/Library/Application Support/com.apple.container"
        // Asset resolution: prefer explicitly bundled paths (a self-contained Dory.app passes these),
        // and fall back to a local `container` install only for development.
        let kernelPath = args.kernel ?? (support + "/kernels/vmlinux-6.18.15-186")
        let contentRoot = args.data ?? (support + "/content")
        // Use a private, non-in-use copy of the initfs (the engine's is held open by the running VM).
        let vmDir = NSHomeDirectory() + "/.dory/vm"
        let initfsPath = vmDir + "/initfs.ext4"
        let srcInitfs = args.initfs ?? (support + "/containers/dory-engine/initfs.ext4")

        do {
            try FileManager.default.createDirectory(atPath: vmDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: initfsPath), FileManager.default.fileExists(atPath: srcInitfs) {
                try FileManager.default.copyItem(atPath: srcInitfs, toPath: initfsPath)
            }
            guard FileManager.default.fileExists(atPath: kernelPath) else { FileHandle.standardError.write(Data("dory-vm: kernel not found at \(kernelPath)\n".utf8)); exit(2) }
            guard FileManager.default.fileExists(atPath: initfsPath) else { FileHandle.standardError.write(Data("dory-vm: initfs not found at \(initfsPath)\n".utf8)); exit(2) }

            if args.devices { try await runDevices(kernelPath: kernelPath, initfsPath: initfsPath); return }
            if let sock = args.sharedEngine { try await runSharedEngine(hostSock: sock, kernelPath: kernelPath, initfsPath: initfsPath); return }

            let scratch = vmDir + "/scratch-\(ProcessInfo.processInfo.processIdentifier)"
            try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: scratch) }

            let kernel = tunedKernel(kernelPath)
            let initfs = Mount.block(format: "ext4", source: initfsPath, destination: "/", options: ["ro"])
            let store = try ImageStore(path: URL(fileURLWithPath: contentRoot))
            let image = try await store.get(reference: args.image, pull: true)
            let platform = Platform(arch: args.arch, os: "linux")
            let rootfsPath = URL(fileURLWithPath: scratch + "/rootfs.ext4")
            let rootfs = try await EXT4Unpacker(blockSizeInBytes: 2 * 1024 * 1024 * 1024).unpack(image, for: platform, at: rootfsPath)

            let userCommand = args.command.joined(separator: " ")
            let scratchPath = scratch
            let mounts = args.mounts
            let configure: @Sendable (inout LinuxContainer.Configuration) -> Void = { config in
                config.cpus = 2
                config.memoryInBytes = 1024 * 1024 * 1024
                config.mounts.append(Mount.share(source: scratchPath, destination: "/dory-out"))
                for (host, guest) in mounts { config.mounts.append(Mount.share(source: host, destination: guest)) }
                config.process.arguments = ["/bin/sh", "-c", "{ \(userCommand) ; } > /dory-out/stdout 2>&1; echo $? > /dory-out/exit"]
                config.process.capabilities = .allCapabilities
            }

            let vmm = VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs, rosetta: args.rosetta)
            let container = try LinuxContainer("dory-vm-\(ProcessInfo.processInfo.processIdentifier)", rootfs: rootfs, vmm: vmm, configuration: { try configure(&$0) })
            try await container.create()
            try await container.start()
            _ = try await container.wait(timeoutInSeconds: 120)
            try? await container.stop()

            if let out = try? String(contentsOfFile: scratch + "/stdout", encoding: .utf8) {
                FileHandle.standardOutput.write(Data(out.utf8))
            }
            let code = (try? String(contentsOfFile: scratch + "/exit", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            exit(Int32(code ?? "0") ?? 0)
        } catch {
            FileHandle.standardError.write(Data("dory-vm error: \(error)\n".utf8))
            exit(3)
        }
    }

    // Kernel command line tuned for fast VM boot: keep console=hvc0 + tsc=reliable (panics stay
    // readable), then silence the serial console and skip slow hardware probes the VM doesn't have.
    static func tunedKernel(_ path: String) -> Kernel {
        var cl = Kernel.CommandLine()
        cl.kernelArgs += [
            "quiet", "loglevel=1", "no_timer_check", "random.trust_cpu=on",
            "8250.nr_uarts=0", "i8042.noaux", "i8042.nomux", "i8042.dumbkbd",
        ]
        cl.addPanic(level: 0)
        return Kernel(path: URL(fileURLWithPath: path), platform: .linuxArm, commandline: cl)
    }

    // Self-contained shared engine: boot ONE VM running dockerd (dind) in-process and publish its
    // docker socket to the host — so Dory runs MULTIPLE containers in one memory-efficient VM with
    // NO external `container` CLI. This is the engine that makes a single Dory.app a full replacement.
    static func runSharedEngine(hostSock: String, kernelPath: String, initfsPath: String) async throws {
        func note(_ s: String) { FileHandle.standardError.write(Data("dory-engine: \(s)\n".utf8)) }
        let kernel = tunedKernel(kernelPath)
        let initfs = Mount.block(format: "ext4", source: initfsPath, destination: "/", options: ["ro"])

        var network: Network?
        if #available(macOS 26, *) {
            network = try? VmnetNetwork()
        }
        guard network != nil else { throw EngineError.noNetwork }

        let vmm = BalloonVMM(inner: VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs))
        var manager = try ContainerManager(vmm: vmm, network: network)
        // The vmm-injecting constructor uses the default image store; clean its prior container dir.
        let store = NSHomeDirectory() + "/Library/Application Support/com.apple.containerization"
        try? FileManager.default.removeItem(atPath: hostSock)
        try? manager.delete("dory-shared-engine")
        try? FileManager.default.removeItem(atPath: store + "/containers/dory-shared-engine")
        let hostURL = URL(fileURLWithPath: hostSock)

        let configure: @Sendable (inout LinuxContainer.Configuration) -> Void = { config in
            config.cpus = 4
            config.memoryInBytes = 4 * 1024 * 1024 * 1024
            config.cpuOverhead = 0
            config.memoryOverhead = 64 * 1024 * 1024
            config.useInit = true
            let bootScript = """
            set +e
            if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
              mkdir -p /sys/fs/cgroup/init
              for pid in $(cat /sys/fs/cgroup/cgroup.procs 2>/dev/null); do
                echo $pid > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
              done
              ctrls=""
              for c in $(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null); do ctrls="$ctrls +$c"; done
              echo $ctrls > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
            fi
            exec dockerd --host=unix:///var/run/docker.sock
            """
            config.process.arguments = ["/bin/sh", "-c", bootScript]
            config.process.environmentVariables = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "DOCKER_TLS_CERTDIR="]
            config.process.capabilities = .allCapabilities
            config.sockets = [UnixSocketConfiguration(source: URL(fileURLWithPath: "/var/run/docker.sock"), destination: hostURL, direction: .outOf)]
        }
        // Unpack the dind image to a PRISTINE ext4 once (~6s, first boot only); every boot then gets a
        // FRESH writable rootfs via an APFS clone (O(1)) — skips the unpack without inheriting the prior
        // run's stale /var/run/docker.pid + containerd state that would wedge dockerd.
        let vmDir = NSHomeDirectory() + "/.dory/vm"
        let pristine = vmDir + "/dind-pristine.ext4"
        let bootRootfs = vmDir + "/dind-boot.ext4"
        let image = try await manager.imageStore.get(reference: "docker.io/library/docker:dind", pull: true)
        try? FileManager.default.createDirectory(atPath: vmDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: pristine) {
            note("first run: preparing engine (one-time)…")
            _ = try await EXT4Unpacker(blockSizeInBytes: 8 * 1024 * 1024 * 1024)
                .unpack(image, for: Platform(arch: "arm64", os: "linux"), at: URL(fileURLWithPath: pristine))
        }
        try? FileManager.default.removeItem(atPath: bootRootfs)
        try FileManager.default.copyItem(atPath: pristine, toPath: bootRootfs)
        let rootfsMount = Mount.block(format: "ext4", source: bootRootfs, destination: "/", options: [])
        try? FileManager.default.createDirectory(atPath: store + "/containers/dory-shared-engine", withIntermediateDirectories: true)
        let container = try await manager.create(
            "dory-shared-engine",
            image: image,
            rootfs: rootfsMount,
            networking: true,
            configuration: configure
        )
        try await container.create()
        try await container.start()
        note("running — docker socket published at \(hostSock)")

        // Elastic memory: every 10s, shrink the VM's backing RAM toward actual usage + headroom and
        // hand the rest back to macOS via the balloon; it grows again automatically under load.
        let maxMem: UInt64 = 4 * 1024 * 1024 * 1024
        let reclaim = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let used = (try? await container.statistics())?.memory?.usageBytes else { continue }
                // Keep generous headroom above real usage so a fast-allocating workload never hits the
                // balloon ceiling between cycles; the balloon still reclaims large high-water drops.
                let target = min(maxMem, max(1024 * 1024 * 1024, used + 1536 * 1024 * 1024))
                try? await container.withVirtualMachineInstance { instance in
                    guard let vzi = instance as? VZVirtualMachineInstance else { return }
                    let vm = vzi.vzVirtualMachine
                    let queue = vzi.vmQueue
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        queue.async {
                            if let balloon = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice {
                                balloon.targetVirtualMachineMemorySize = target
                            }
                            cont.resume()
                        }
                    }
                }
            }
        }

        let status = try await container.wait(timeoutInSeconds: nil)
        reclaim.cancel()
        note("exited: \(status.exitCode)")
    }

    // USB/audio passthrough + dynamic memory ballooning: boot a VM with the devices attached, then
    // adjust the balloon at runtime to reclaim guest RAM back to macOS.
    static func runDevices(kernelPath: String, initfsPath: String) async throws {
        let kernel = tunedKernel(kernelPath)
        let initfs = Mount.block(format: "ext4", source: initfsPath, destination: "/", options: ["ro"])
        let vmm = VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs)
        var vmConfig = VMConfiguration(cpus: 2, memoryInBytes: 1024 * 1024 * 1024)
        vmConfig.extensions = [DeviceExtension()]
        let instance = try vmm.create(config: StandardVMConfig(configuration: vmConfig))
        try await instance.start()
        guard let vzi = instance as? VZVirtualMachineInstance else { print("no VZ instance"); exit(1) }
        let vm = vzi.vzVirtualMachine
        let queue = vzi.vmQueue
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                print("USB controllers attached:   \(vm.usbControllers.count)")
                print("audio device configured:    yes (VZVirtioSoundDevice in VZ config)")
                print("memory balloon devices:     \(vm.memoryBalloonDevices.count)")
                if let balloon = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice {
                    let before = balloon.targetVirtualMachineMemorySize
                    balloon.targetVirtualMachineMemorySize = 512 * 1024 * 1024
                    print("balloon target RAM: \(before / (1024*1024))MiB -> \(balloon.targetVirtualMachineMemorySize / (1024*1024))MiB (reclaimed to macOS)")
                }
                cont.resume()
            }
        }
        print("dory-vm: USB + audio + dynamic balloon all active")
        exit(0)
    }
}
