import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import DoryHV
import Foundation

/// `dory-hv engine`: the production mode SharedVMProvisioner spawns. Owns the full lifecycle:
/// pulls docker:dind once, unpacks it to a persistent engine disk, boots the VMM with
/// networking, and publishes the Docker API at the unix socket the app already consumes.
///
/// Unlike the VZ helper, the engine disk is NOT re-cloned per boot: images, containers, and
/// volumes survive engine restarts. Stale pid files live in tmpfs and clear themselves.
enum EngineMode {
    struct Configuration {
        var engineSocket: String
        var kernelPath: String
        var gvproxyPath: String
        var memoryMB: UInt64
        var cpus: Int
        var stateDirectory: String
    }

    /// gvproxy pid for the signal path: a SIGTERM to the helper must not orphan the sidecar.
    nonisolated(unsafe) private static var sidecarPID: pid_t = 0

    static func installSignalTeardown() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig) { _ in
                if EngineMode.sidecarPID > 0 { kill(EngineMode.sidecarPID, SIGTERM) }
                exit(0)
            }
        }
    }

    static func run(_ configuration: Configuration) async throws {
        let state = configuration.stateDirectory
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        let engineDisk = state + "/engine-disk.ext4"

        if !FileManager.default.fileExists(atPath: engineDisk) {
            note("first run: preparing engine disk (one-time)…")
            try await prepareEngineDisk(at: engineDisk, stateDirectory: state)
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
        backends.append(try VirtioBlk(path: engineDisk, identity: "dory-engine"))
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
        publishEngineSocket(configuration.engineSocket, apiSocket: apiSocket)
        note("engine starting: \(configuration.memoryMB)MiB ceiling, \(configuration.cpus) cpus, socket \(configuration.engineSocket)")

        let stop = try machine.runBootCPU()
        note("engine stopped: \(stop)")
    }

    private static func prepareEngineDisk(at path: String, stateDirectory: String) async throws {
        let store = try ImageStore(path: URL(fileURLWithPath: stateDirectory + "/content"))
        let image = try await store.get(reference: "docker.io/library/docker:dind", pull: true)
        _ = try await EXT4Unpacker(blockSizeInBytes: 8 * 1024 * 1024 * 1024)
            .unpack(image, for: Platform(arch: "arm64", os: "linux"), at: URL(fileURLWithPath: path))
    }

    /// Guest boot: mounts, DHCP through gvproxy, dockerd on unix + tcp 2375 (virtual network
    /// only), and the elasticity trim loop (reporting granularity 16 KiB, cgroup2 proactive
    /// reclaim of cold page cache, periodic compaction so freed fragments become reportable).
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
            "ip link set lo up",
            "ip link set eth0 up",
            "udhcpc -i eth0 -q >/dev/null 2>&1",
            "echo 2 > /sys/module/page_reporting/parameters/page_reporting_order 2>/dev/null",
            "dockerd -H unix:///var/run/docker.sock -H tcp://0.0.0.0:2375 --tls=false >/var/log/dockerd.log 2>&1 & true",
            "while true; do sleep 30; c=$(grep Cached: /proc/meminfo | head -1 | tr -s \\  | cut -d\\  -f2); [ ${c:-0} -gt 204800 ] && echo 128M > /sys/fs/cgroup/memory.reclaim 2>/dev/null; echo 1 > /proc/sys/vm/compact_memory 2>/dev/null; done",
        ].joined(separator: "; ")
        return "console=ttyAMA0 root=/dev/vda rw panic=0 init=/bin/sh -- -c \"\(script)\""
    }

    /// Asks gvproxy to serve the Docker API as a host unix socket, retrying until the listener
    /// lands (dockerd readiness is the app's probe, not ours).
    private static func publishEngineSocket(_ socketPath: String, apiSocket: String) {
        try? FileManager.default.removeItem(atPath: socketPath)
        let body = "{\"local\":\"\(socketPath)\",\"remote\":\"tcp://192.168.127.2:2375\",\"protocol\":\"unix\"}"
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
                        note("docker socket published at \(socketPath)")
                        return
                    }
                }
                sleep(1)
            }
            note("WARNING: could not publish \(socketPath) through gvproxy")
        }
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("dory-hv: \(message)\n".utf8))
    }
}
