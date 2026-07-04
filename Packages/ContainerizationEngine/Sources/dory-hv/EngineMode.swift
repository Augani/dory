import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import DoryHV
import Foundation
import SystemPackage

/// `dory-hv engine`: the production mode SharedVMProvisioner spawns. Owns the full lifecycle:
/// pulls docker:dind once, boots the VMM with networking, and publishes the Docker API at the
/// unix socket the app already consumes.
///
/// Disk layout: the ROOTFS is a throwaway APFS clone of the pristine unpack, recreated every
/// boot so system state can never rot; DOCKER STATE lives on a separate journaled ext4 mounted
/// at /var/lib/docker, so images, containers, and volumes survive restarts and unclean exits.
enum EngineMode {
    struct Configuration {
        var engineSocket: String
        var kernelPath: String
        var gvproxyPath: String
        var memoryMB: UInt64
        var cpus: Int
        var stateDirectory: String
    }

    /// gvproxy pid for the teardown path: stopping the helper must not orphan the sidecar.
    nonisolated(unsafe) private static var sidecarPID: pid_t = 0
    nonisolated(unsafe) private static var signalSources: [any DispatchSourceSignal] = []

    /// SIGTERM/SIGINT ask the guest to power off (sync + unmount + PSCI) through the shutdown
    /// socket; the run loop then returns and the process exits cleanly with a consistent disk.
    /// If the guest does not stop in time, fall back to killing everything.
    private static func installGracefulShutdown(shutdownSocket: String) {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                note("shutdown requested, asking the guest to power off…")
                touchUnixSocket(shutdownSocket)
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    note("guest did not stop in 10s, forcing exit")
                    if sidecarPID > 0 { kill(sidecarPID, SIGTERM) }
                    exit(1)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Opens and closes a connection to a unix socket; the guest's listener treats any
    /// connection as the power-off request.
    private static func touchUnixSocket(_ path: String) {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            let bytes = [UInt8](path.utf8.prefix(destination.count - 1))
            destination.copyBytes(from: bytes)
        }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(descriptor, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func run(_ configuration: Configuration) async throws {
        let state = configuration.stateDirectory
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)

        let pristineRootfs = state + "/rootfs-pristine.ext4"
        let bootRootfs = state + "/rootfs-boot.ext4"
        let dataDisk = state + "/docker-data.ext4"

        if !FileManager.default.fileExists(atPath: pristineRootfs) {
            note("first run: preparing engine rootfs (one-time)…")
            try await prepareEngineDisk(at: pristineRootfs, stateDirectory: state)
        }
        try? FileManager.default.removeItem(atPath: bootRootfs)
        try FileManager.default.copyItem(atPath: pristineRootfs, toPath: bootRootfs)

        if !FileManager.default.fileExists(atPath: dataDisk) {
            note("first run: creating journaled docker data disk…")
            let formatter = try EXT4.Formatter(
                FilePath(dataDisk),
                minDiskSize: 16 * 1024 * 1024 * 1024,
                journal: EXT4.JournalConfig.default
            )
            try formatter.close()
        }

        let machine = try Machine(configuration: MachineConfiguration(
            kernelPath: configuration.kernelPath,
            commandLine: guestCommandLine(),
            memoryBytes: configuration.memoryMB << 20,
            cpuCount: configuration.cpus
        ))
        machine.bus.attach(PL031(baseAddress: GuestLayout.rtcBase))
        machine.attachConsole(PL011(baseAddress: GuestLayout.uartBase) { byte in
            FileHandle.standardOutput.write(Data([byte]))
        })

        var backends: [VirtioDeviceBackend] = []
        backends.append(try VirtioBlk(path: bootRootfs, identity: "dory-rootfs"))
        backends.append(try VirtioBlk(path: dataDisk, identity: "dory-data"))
        backends.append(VirtioRng())
        backends.append(VirtioBalloon(memory: machine.memory) { note($0) })

        let datapathSocket = state + "/net.sock"
        let apiSocket = state + "/gvproxy-api.sock"
        try? FileManager.default.removeItem(atPath: datapathSocket)
        try? FileManager.default.removeItem(atPath: apiSocket)
        let gvproxy = Process()
        gvproxy.executableURL = URL(fileURLWithPath: configuration.gvproxyPath)
        gvproxy.arguments = [
            "-mtu", "1500",
            "-listen-vfkit", "unixgram://\(datapathSocket)",
            "-listen", "unix://\(apiSocket)",
        ]
        gvproxy.standardOutput = FileHandle.standardError
        gvproxy.standardError = FileHandle.standardError
        try gvproxy.run()
        sidecarPID = gvproxy.processIdentifier
        defer { gvproxy.terminate() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: datapathSocket) { break }
            usleep(50_000)
        }
        backends.append(try VirtioNet(socketPath: state + "/vm-net.sock", remotePath: datapathSocket))

        for (slot, backend) in backends.enumerated() {
            let spi = GuestLayout.virtioFirstIRQ + UInt32(slot)
            let transport = VirtioMMIOTransport(
                baseAddress: GuestLayout.virtioBase + UInt64(slot) * GuestLayout.virtioSlotSize,
                backend: backend,
                memory: machine.memory
            ) { [weak machine] in
                machine?.raiseSPI(spi)
            }
            machine.attachVirtioSlot(transport)
        }

        try machine.loadBootPayload()
        publishForward(local: configuration.engineSocket, guestPort: 2375, apiSocket: apiSocket, label: "docker socket")
        let shutdownSocket = state + "/shutdown.sock"
        publishForward(local: shutdownSocket, guestPort: 2377, apiSocket: apiSocket, label: "shutdown channel")
        installGracefulShutdown(shutdownSocket: shutdownSocket)
        note("engine starting: \(configuration.memoryMB)MiB ceiling, \(configuration.cpus) cpus, socket \(configuration.engineSocket)")

        let memory = machine.memory
        let gauge = DispatchSource.makeTimerSource(queue: .global())
        gauge.schedule(deadline: .now() + 60, repeating: 60)
        gauge.setEventHandler {
            let released = memory.releasedBytes.load(ordering: .relaxed)
            let restored = memory.restoredBytes.load(ordering: .relaxed)
            note("reclaim gauge: released \(released >> 20)MiB, restored \(restored >> 20)MiB, net \(Int64(bitPattern: released &- restored) / 1_048_576)MiB")
        }
        gauge.resume()

        let stop = try machine.run()
        gauge.cancel()
        note("engine stopped: \(stop)")
    }

    private static func prepareEngineDisk(at path: String, stateDirectory: String) async throws {
        let store = try ImageStore(path: URL(fileURLWithPath: stateDirectory + "/content"))
        let image = try await store.get(reference: "docker.io/library/docker:dind", pull: true)
        _ = try await EXT4Unpacker(blockSizeInBytes: 8 * 1024 * 1024 * 1024)
            .unpack(image, for: Platform(arch: "arm64", os: "linux"), at: URL(fileURLWithPath: path))
    }

    /// Guest boot: mounts (docker state on the journaled /dev/vdb), DHCP through gvproxy,
    /// dockerd on unix + tcp 2375 (virtual network only), a shutdown listener on tcp 2377 (any
    /// connection triggers sync + poweroff, giving the host a clean-unmount path), and the
    /// elasticity trim loop (reporting granularity 16 KiB, cgroup2 proactive reclaim of cold
    /// page cache, periodic compaction so freed fragments become reportable).
    private static func guestCommandLine() -> String {
        let script = [
            "export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
            "mount -t proc proc /proc",
            "mount -t sysfs sys /sys",
            "mount -t cgroup2 none /sys/fs/cgroup",
            "mount -t tmpfs tmpfs /run",
            "mount -t tmpfs tmpfs /tmp",
            "mkdir -p /dev/pts",
            "mount -t devpts devpts /dev/pts",
            "mkdir -p /var/lib/docker",
            "mount -t ext4 /dev/vdb /var/lib/docker || echo DATA-DISK-MOUNT-FAILED",
            "ip link set lo up",
            "ip link set eth0 up",
            "udhcpc -i eth0 -q >/dev/null 2>&1",
            "echo 2 > /sys/module/page_reporting/parameters/page_reporting_order 2>/dev/null",
            "echo 200 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null",
            "dockerd -H unix:///var/run/docker.sock -H tcp://0.0.0.0:2375 --tls=false >/var/log/dockerd.log 2>&1 & true",
            "while true; do nc -l -p 2377 >/dev/null 2>&1; echo shutdown requested; sync; umount /var/lib/docker 2>/dev/null; sync; poweroff -f; done & true",
            "while true; do sleep 15; c=$(grep Cached: /proc/meminfo | head -1 | tr -s \\  | cut -d\\  -f2); [ ${c:-0} -gt 131072 ] && echo $((c/2))K > /sys/fs/cgroup/memory.reclaim 2>/dev/null; echo 1 > /proc/sys/vm/compact_memory 2>/dev/null; done",
        ].joined(separator: "; ")
        return "console=ttyAMA0 root=/dev/vda rw panic=0 init=/bin/sh -- -c \"\(script)\""
    }

    /// Asks gvproxy to serve a guest TCP port as a host unix socket, retrying until the listener
    /// lands (dockerd readiness is the app's probe, not ours).
    private static func publishForward(local socketPath: String, guestPort: Int, apiSocket: String, label: String) {
        try? FileManager.default.removeItem(atPath: socketPath)
        let body = "{\"local\":\"\(socketPath)\",\"remote\":\"tcp://192.168.127.2:\(guestPort)\",\"protocol\":\"unix\"}"
        DispatchQueue.global().async {
            for _ in 0..<30 {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                task.arguments = [
                    "-s", "-f", "--unix-socket", apiSocket,
                    "-X", "POST", "-d", body,
                    "http://gvproxy/services/forwarder/expose",
                ]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                if (try? task.run()) != nil {
                    task.waitUntilExit()
                    if task.terminationStatus == 0 {
                        note("\(label) published at \(socketPath)")
                        return
                    }
                }
                sleep(1)
            }
            note("WARNING: could not publish \(label) at \(socketPath) through gvproxy")
        }
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("dory-hv: \(message)\n".utf8))
    }
}
