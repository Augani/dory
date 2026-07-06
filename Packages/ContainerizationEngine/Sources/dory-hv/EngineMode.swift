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
        /// Offline builds pass a decompressed engine rootfs here so first launch needs no network;
        /// online builds leave it nil and the engine fetches the image once.
        var bundledRootfs: String?
        var shares: [VirtioFSShareConfiguration] = []
        var directIP: DirectIPBridgeConfiguration?
        var gpuMode: GPUAccelerationMode = .off
        /// Register a qemu binfmt handler in the guest so `--platform linux/amd64` images run on the
        /// arm64 engine. Opt-in (Settings → Rosetta x86) to keep the default guest lean.
        var amd64Emulation: Bool = false
    }

    enum GPUAccelerationMode: String {
        case off
        case venus
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
                // Retry the poweroff touch: SIGTERM can arrive during guest boot, before the
                // gvproxy forward is registered or the guest's listener is up. The run loop returns
                // once the guest powers off (and the process exits cleanly); the watchdog only
                // fires if the guest never stops.
                DispatchQueue.global().async {
                    for _ in 0..<40 {
                        if touchUnixSocket(shutdownSocket) { return }
                        usleep(250_000)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                    note("guest did not stop in 12s, forcing exit")
                    if sidecarPID > 0 { kill(sidecarPID, SIGTERM) }
                    exit(1)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func installClockSyncSignal(vsock: VirtioVsock) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
        source.setEventHandler {
            Task.detached {
                await syncGuestClock(vsock: vsock, reason: "signal")
            }
        }
        source.resume()
        signalSources.append(source)
    }

    private static func syncGuestClock(
        vsock: VirtioVsock,
        reason: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) async {
        let connection = vsock.connect(port: VsockPorts.agent)
        defer { connection.close() }
        let transport = AgentVsockTransport(connection: connection, readTimeoutNanoseconds: 2_000_000_000)
        let channel = AgentChannel(transport: transport)
        let hostEpochNanoseconds = Int64((now().timeIntervalSince1970 * 1_000_000_000).rounded())
        do {
            let result = try await channel.syncClock(hostEpochNanoseconds: hostEpochNanoseconds)
            note("clock sync \(reason): \(result.synced ? "ok" : "agent declined")")
        } catch {
            note("clock sync \(reason) failed: \(error)")
        }
    }

    /// Opens and closes a connection to a unix socket; the guest's listener treats any connection
    /// as the power-off request. Returns whether the connection was actually established, so the
    /// caller can retry until the forward and the guest listener both exist.
    @discardableResult
    private static func touchUnixSocket(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            let bytes = [UInt8](path.utf8.prefix(destination.count - 1))
            destination.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(descriptor, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    static func run(_ configuration: Configuration) async throws {
        let state = configuration.stateDirectory
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)

        let pristineRootfs = state + "/rootfs-pristine.ext4"
        let bootRootfs = state + "/rootfs-boot.ext4"
        let dataDisk = state + "/docker-data.ext4"

        // Both one-time artifacts are built at a temp path and atomically renamed into place, so an
        // interrupted first run leaves no half-written file that the fileExists guard would then
        // treat as complete forever.
        if !FileManager.default.fileExists(atPath: pristineRootfs) {
            let temporary = pristineRootfs + ".partial"
            try? FileManager.default.removeItem(atPath: temporary)
            if let bundled = configuration.bundledRootfs, FileManager.default.fileExists(atPath: bundled) {
                // Offline build: the engine image ships in the app, no network on first launch.
                note("first run: installing bundled engine rootfs (one-time, offline)…")
                try FileManager.default.copyItem(atPath: bundled, toPath: temporary)
            } else {
                note("first run: fetching engine image (one-time)…")
                try await prepareEngineDisk(at: temporary, stateDirectory: state)
            }
            try fsyncFile(temporary)
            try FileManager.default.moveItem(atPath: temporary, toPath: pristineRootfs)
        }
        try? FileManager.default.removeItem(atPath: bootRootfs)
        try FileManager.default.copyItem(atPath: pristineRootfs, toPath: bootRootfs)

        if !FileManager.default.fileExists(atPath: dataDisk) {
            note("first run: creating journaled docker data disk…")
            let temporary = dataDisk + ".partial"
            try? FileManager.default.removeItem(atPath: temporary)
            let formatter = try EXT4.Formatter(
                FilePath(temporary),
                minDiskSize: 16 * 1024 * 1024 * 1024,
                journal: EXT4.JournalConfig.default
            )
            try formatter.close()
            try fsyncFile(temporary)
            try FileManager.default.moveItem(atPath: temporary, toPath: dataDisk)
        }

        let bootScriptDisk = state + "/boot-script.ext4"
        try makeBootScriptDisk(at: bootScriptDisk, script: guestBootScript(
            shares: configuration.shares,
            gpuMode: configuration.gpuMode,
            amd64Emulation: configuration.amd64Emulation
        ))

        let machine = try Machine(configuration: MachineConfiguration(
            kernelPath: configuration.kernelPath,
            commandLine: guestCommandLine(),
            memoryBytes: configuration.memoryMB << 20,
            cpuCount: configuration.cpus
        ))
        attachPlatformDevices(to: machine)

        var backends: [VirtioDeviceBackend] = []
        backends.append(try VirtioBlk(path: bootRootfs, identity: "dory-rootfs"))
        backends.append(try VirtioBlk(path: dataDisk, identity: "dory-data"))
        backends.append(try VirtioBlk(path: bootScriptDisk, identity: "dory-bootscript"))
        backends.append(VirtioRng())
        backends.append(VirtioBalloon(memory: machine.memory) { note($0) })
        var daxSlot: UInt64 = 0
        if configuration.gpuMode == .venus {
            do {
                let renderer = try VirglRenderer.discover()
                let hostMemoryBase = GuestLayout.daxWindowBase + daxSlot * DaxWindow.defaultSize
                let hostVisibleMemory = try VirtioGPUHostVisibleMemory(guestBase: hostMemoryBase)
                daxSlot += 1
                backends.append(VirtioGPU(
                    hostMemoryBase: hostMemoryBase,
                    renderer: renderer,
                    hostVisibleMemory: hostVisibleMemory
                ))
                note("experimental gpu=venus: attached virtio-gpu with virglrenderer \(renderer.libraryPath) and MoltenVK ICD \(renderer.moltenVKICDPath)")
            } catch {
                note("experimental gpu=venus unavailable, continuing headless: \(error)")
            }
        }
        let vsock = VirtioVsock(guestCID: 3)
        backends.append(vsock)
        HostAIBridge(log: { note($0) }).attach(to: vsock)
        for share in configuration.shares {
            let daxBase = share.dax ? GuestLayout.daxWindowBase + daxSlot * DaxWindow.defaultSize : nil
            if share.dax { daxSlot += 1 }
            backends.append(try share.makeBackend(daxGuestBase: daxBase))
            note("sharing \(share.path) as virtiofs tag \(share.tag)\(share.readOnly ? " (ro)" : "")\(share.dax ? " (dax)" : "")")
        }

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
        var directIPBridge: DirectIPBridge?
        if let config = configuration.directIP {
            do {
                let bridge = try DirectIPBridge(configuration: DirectIPBridgeConfiguration(
                    subnetCIDR: config.subnetCIDR,
                    gateway: config.gateway,
                    gvproxySocketPath: datapathSocket,
                    localSocketPath: config.localSocketPath,
                    interfaceNamePath: config.interfaceNamePath
                )) { note($0) }
                try bridge.start()
                directIPBridge = bridge
            } catch {
                note("direct-ip disabled: \(error)")
                directIPBridge = nil
            }
        }

        for (slot, backend) in backends.enumerated() {
            let spi = GuestLayout.virtioFirstIRQ + UInt32(slot)
            let transport = VirtioMMIOTransport(
                baseAddress: GuestLayout.virtioBase + UInt64(slot) * GuestLayout.virtioSlotSize,
                backend: backend,
                memory: machine.memory
            ) { [weak machine] in
                machine?.raiseGSI(spi)
            }
            machine.attachVirtioSlot(transport)
        }

        try machine.loadBootPayload()
        // engine.sock is served by dory-hv itself and relayed to guest dockerd over vsock: the
        // gvproxy unix forward it replaces tears the stream down on a client half-close, which the
        // docker CLI does right after every attach/exec request — so `docker run` output was lost.
        DockerSocketBridge(socketPath: configuration.engineSocket, log: { note($0) }).attach(to: vsock)
        let shutdownSocket = state + "/shutdown.sock"
        publishForward(local: shutdownSocket, guestPort: 2377, apiSocket: apiSocket, label: "shutdown channel")
        installGracefulShutdown(shutdownSocket: shutdownSocket)
        installClockSyncSignal(vsock: vsock)

        // Keep gvproxy's forwards in sync with the ports containers publish, so `docker run -p` is
        // reachable from the host across the userspace network.
        let portForwarder = PortForwarder(
            engineSocket: configuration.engineSocket,
            apiSocket: apiSocket,
            guestIP: "192.168.127.2",
            log: { note($0) }
        )
        portForwarder.start()
        note("engine starting: \(configuration.memoryMB)MiB ceiling, \(configuration.cpus) cpus, socket \(configuration.engineSocket)")

        // USB passthrough: the listener serves guest usbip dials on VsockPorts.usbip, and the control
        // server drives `dory usb attach/detach` — it claims the host device, registers it with the
        // manager, and tells the guest agent to dial. The listener is a no-op until a device is claimed.
        let usbipManager = UsbipManager()
        usbipManager.attachListener(to: vsock)
        let usbControlHandler = UsbControlHandler(
            manager: usbipManager,
            openDevice: { busID, mode in try HostUsbDeviceFactory.open(busID: busID, mode: mode) },
            notifyAttach: { request in
                let connection = vsock.connect(port: VsockPorts.agent)
                defer { connection.close() }
                let channel = AgentChannel(transport: AgentVsockTransport(connection: connection, readTimeoutNanoseconds: 10_000_000_000))
                let _: UsbAgentReply = try await channel.call("usb.attach", request)
            },
            notifyDetach: { request in
                let connection = vsock.connect(port: VsockPorts.agent)
                defer { connection.close() }
                let channel = AgentChannel(transport: AgentVsockTransport(connection: connection, readTimeoutNanoseconds: 10_000_000_000))
                let _: UsbAgentReply = try await channel.call("usb.detach", request)
            }
        )
        let usbControlServer = UsbControlServer(path: configuration.stateDirectory + "/usb-control.sock", handler: usbControlHandler)
        do { try usbControlServer.start() } catch { note("usb control server unavailable: \(error)") }

        let agentFeatures = AgentFeatureHandles()
        let shares = configuration.shares
        Task.detached {
            guard await probeAgent(vsock: vsock) else {
                note("guest agent unavailable; machine port-forward/clock/fs-relay disabled")
                return
            }
            note("guest agent reachable; enabling machine port-forward and file-event relay")
            agentFeatures.setMachinePortTimer(startMachinePortWatcher(vsock: vsock, forwarder: portForwarder))
            agentFeatures.setRelay(startFileEventRelay(shares: shares, vsock: vsock))
        }

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
        directIPBridge?.stop()
        agentFeatures.cancel()
        gauge.cancel()
        note("engine stopped: \(stop)")
    }

    private final class AgentFeatureHandles: @unchecked Sendable {
        private let lock = NSLock()
        private var machinePortTimer: (any DispatchSourceTimer)?
        private var relay: HostFSEventRelay?

        func setMachinePortTimer(_ timer: any DispatchSourceTimer) {
            lock.lock()
            defer { lock.unlock() }
            machinePortTimer = timer
        }

        func setRelay(_ relay: HostFSEventRelay?) {
            lock.lock()
            defer { lock.unlock() }
            self.relay = relay
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            machinePortTimer?.cancel()
            machinePortTimer = nil
            relay?.stop()
            relay = nil
        }
    }

    /// Flushes a freshly written file to stable storage before it is renamed into place, so a
    /// crash right after the rename can never expose a file whose contents are still in the page
    /// cache (EXT4.Formatter.close does not fsync).
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

    private static func prepareEngineDisk(at path: String, stateDirectory: String) async throws {
        let store = try ImageStore(path: URL(fileURLWithPath: stateDirectory + "/content"))
        let image = try await store.get(reference: "docker.io/library/docker:dind", pull: true)
        _ = try await EXT4Unpacker(blockSizeInBytes: 8 * 1024 * 1024 * 1024)
            .unpack(image, for: Platform(arch: hostLinuxArch(), os: "linux"), at: URL(fileURLWithPath: path))
    }

    /// Guest boot: mounts (docker state on the journaled /dev/vdb), DHCP through gvproxy,
    /// dockerd on unix + tcp 2375 (virtual network only), a shutdown listener on tcp 2377 (any
    /// connection triggers sync + poweroff, giving the host a clean-unmount path), and a light
    /// page-cache cap so free page reporting (which handles free pages automatically at 16 KiB
    /// granularity) has cold pages to hand back when the cache bloats.
    private static func guestBootScript(
        shares: [VirtioFSShareConfiguration] = [],
        gpuMode: GPUAccelerationMode = .off,
        amd64Emulation: Bool = false
    ) -> String {
        var script = [
            "export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
            "mount -t proc proc /proc",
            "mount -t sysfs sys /sys",
            "mount -t cgroup2 none /sys/fs/cgroup",
            "mount -t tmpfs tmpfs /run",
            "mount -t tmpfs tmpfs /tmp",
            "mkdir -p /dev/pts",
            "mount -t devpts devpts /dev/pts",
            "mkdir -p /var/lib/docker",
            // Fail hard if the persistent data disk will not mount: never let dockerd write to the
            // throwaway rootfs, which the next boot destroys (silent total data loss). Powering off
            // surfaces the failure to the host, which falls back to another engine.
            "mount -t ext4 /dev/vdb /var/lib/docker || { echo DATA-DISK-MOUNT-FAILED; sync; poweroff -f; }",
            "ip link set lo up",
            "ip link set eth0 up",
            "udhcpc -i eth0 -q >/dev/null 2>&1",
            "echo 2 > /sys/module/page_reporting/parameters/page_reporting_order 2>/dev/null",
            // Bias the guest toward returning cold cache instead of hoarding it; free page
            // reporting then hands the freed pages back to the host automatically.
            "echo 200 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null",
            "echo 262144 > /proc/sys/vm/min_free_kbytes 2>/dev/null",
        ]
        if gpuMode == .venus {
            script += [
                "export DORY_GPU=venus",
                "for n in $(seq 1 80); do [ -d /dev/dri ] && break; sleep 0.1; done",
                "[ -d /dev/dri ] && chmod a+rw /dev/dri/renderD* /dev/dri/card* 2>/dev/null || echo DORY-GPU-NO-DRI",
            ]
        }
        if amd64Emulation {
            script += BinfmtRegistration.bootCommands()
        }
        for share in shares {
            let tag = shellQuote(share.tag)
            let mountPoint = shellQuote(share.guestMountPoint ?? "/mnt/dory/\(share.tag)")
            var options = share.readOnly ? "ro" : "rw"
            if share.dax { options += ",dax=always" }
            script.append("mkdir -p \(mountPoint)")
            script.append("mount -t virtiofs -o \(options) \(tag) \(mountPoint) || echo VIRTIOFS-MOUNT-FAILED-\(share.tag)")
        }
        script += [
            guestAgentStartCommand(shares: shares),
            "dockerd -H unix:///var/run/docker.sock -H tcp://0.0.0.0:2375 --tls=false >/var/log/dockerd.log 2>&1 & true",
            amd64Emulation ? BinfmtRegistration.dockerFallbackCommand() : "true",
            "( while true; do nc -l -p 2377 >/dev/null 2>&1; echo shutdown requested; sync; umount /var/lib/docker 2>/dev/null; sync; poweroff -f; done ) & true",
            // Cache cap only. NO compaction (it migrates pages and re-faults the ones free page
            // reporting already handed back to the host — pure churn) and NO root memory.reclaim
            // (write-rejected on the root cgroup). A gentle pagecache-only drop fires when the
            // cache passes ~320 MiB, capping the idle footprint while leaving a healthy working
            // set for active containers.
            "( while true; do sleep 30; c=$(awk '/^Cached:/{print $2; exit}' /proc/meminfo); [ ${c:-0} -gt 327680 ] && echo 1 > /proc/sys/vm/drop_caches 2>/dev/null; done ) & true",
            // Hand PID 1 to tini (docker-init, shipped in docker:dind) as a reaping init. exec
            // replaces the boot shell in place, so tini keeps PID 1 while dockerd and the loops
            // above continue as its children. Container shims double-fork and orphan their exited
            // children onto PID 1; tini reaps them, so they never pile up as zombies until PID
            // exhaustion. If tini is ever missing, fall back to an idle shell (accepting zombies
            // over a failed boot).
            "[ -x /usr/local/bin/docker-init ] && exec /usr/local/bin/docker-init -s -- sleep 2147483647",
            "while true; do sleep 2147483647; done",
        ]
        return script.joined(separator: "\n") + "\n"
    }

    private static func guestAgentStartCommand(shares: [VirtioFSShareConfiguration]) -> String {
        // The share copy comes first: the app refreshes ~/.dory/bin/dory-agent-* from its bundle on
        // every launch, so preferring it over the rootfs-baked /usr/bin/dory-agent means agent fixes
        // ship with app updates instead of waiting for a re-bundled engine rootfs.
        var paths = [String]()
        for share in shares {
            let root = share.guestMountPoint ?? "/mnt/dory/\(share.tag)"
            paths.append("\(root)/.dory/bin/dory-agent-linux-\(hostLinuxArch())")
            paths.append("\(root)/.dory/bin/dory-agent")
        }
        paths.append("/usr/bin/dory-agent")
        let quotedPaths = paths.map(shellQuote).joined(separator: " ")
        let ports = HostAIBridge.defaultPorts.map(String.init).joined(separator: ",")
        return "for p in \(quotedPaths); do if [ -r \"$p\" ] && ! pgrep -x dory-agent >/dev/null 2>&1; then cp \"$p\" /run/dory-agent && chmod 0755 /run/dory-agent && DORY_HOST_AI_BRIDGE_PORTS=\(shellQuote(ports)) /run/dory-agent >/var/log/dory-agent.log 2>&1 & break; fi; done; true"
    }

    /// The full boot script lives on a dedicated ext4 disk (vdc), so the kernel command line stays
    /// tiny and quote-free: it can never overflow COMMAND_LINE_SIZE or be mis-parsed by the guest
    /// shell, the failure a multi-KB embedded script invites.
    private static func guestCommandLine() -> String {
        #if arch(arm64)
        let console = "console=ttyAMA0"
        #else
        let console = "console=ttyS0 earlyprintk=serial,ttyS0,115200"
        #endif
        return "\(console) root=/dev/vda rw panic=0 init=/bin/sh -- -c \"mkdir -p /mnt && mount -t ext4 /dev/vdc /mnt && exec /bin/sh /mnt/boot.sh\""
    }

    private static func makeBootScriptDisk(at path: String, script: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        let temporary = path + ".partial"
        try? FileManager.default.removeItem(atPath: temporary)
        let formatter = try EXT4.Formatter(FilePath(temporary), minDiskSize: 1 * 1024 * 1024)
        let stream = InputStream(data: Data(script.utf8))
        stream.open()
        defer { stream.close() }
        try formatter.create(path: FilePath("/boot.sh"), mode: EXT4.Inode.Mode(.S_IFREG, 0o755), buf: stream)
        try formatter.close()
        try FileManager.default.moveItem(atPath: temporary, toPath: path)
    }

    private static func attachPlatformDevices(to machine: Machine) {
        #if arch(arm64)
        machine.bus.attach(PL031(baseAddress: GuestLayout.rtcBase))
        machine.attachConsole(PL011(baseAddress: GuestLayout.uartBase) { byte in
            FileHandle.standardOutput.write(Data([byte]))
        })
        #else
        machine.attachConsole(UART16550(basePort: UInt16(truncatingIfNeeded: GuestLayout.uartBase)) { byte in
            FileHandle.standardOutput.write(Data([byte]))
        })
        machine.attachRTC(CMOSRTC(basePort: UInt16(truncatingIfNeeded: GuestLayout.rtcBase)))
        machine.attachResetController(I8042 { [weak machine] in
            note("guest requested i8042 reset")
            machine?.requestStop(.reset)
        })
        #endif
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func startFileEventRelay(shares: [VirtioFSShareConfiguration], vsock: VirtioVsock) -> HostFSEventRelay? {
        guard !shares.isEmpty else { return nil }
        let eventShares = shares.map {
            HostFSEventShare(hostRoot: $0.path, guestRoot: "/mnt/dory/\($0.tag)")
        }
        let relay = HostFSEventRelay(shares: eventShares) { paths in
            guard !paths.isEmpty else { return }
            let connection = vsock.connect(port: VsockPorts.agent)
            defer { connection.close() }
            let transport = AgentVsockTransport(connection: connection, readTimeoutNanoseconds: 2_000_000_000)
            let channel = AgentChannel(transport: transport)
            do {
                let result = try await channel.sendFSEventBatch(paths: paths)
                note("file event relay touched \(result.touched)/\(paths.count) paths")
            } catch {
                note("file event relay skipped batch: \(error)")
            }
        }
        relay.start()
        note("file event relay watching \(shares.count) share(s)")
        return relay
    }

    private final class ForwardedPortSet: @unchecked Sendable {
        private let lock = NSLock()
        private var ports = Set<UInt16>()

        func snapshot() -> Set<UInt16> {
            lock.lock()
            defer { lock.unlock() }
            return ports
        }

        func insert(_ port: UInt16) {
            lock.lock()
            defer { lock.unlock() }
            ports.insert(port)
        }

        func remove(_ port: UInt16) {
            lock.lock()
            defer { lock.unlock() }
            ports.remove(port)
        }
    }

    private static func reconcileMachinePorts(
        snapshot: AgentPortSnapshot,
        forwarded: ForwardedPortSet,
        forwarder: PortForwarder
    ) async {
        let desired = Set(snapshot.ports.filter { $0.protocol == "tcp" || $0.protocol == "tcp6" }.map(\.port))
        let alreadyForwarded = forwarded.snapshot()
        for port in desired.subtracting(alreadyForwarded) {
            if await forwarder.exposeMachinePort(port) {
                forwarded.insert(port)
                note("machine port forward: exposed 127.0.0.1:\(port)")
            }
        }
        for port in alreadyForwarded.subtracting(desired) {
            if await forwarder.unexposeMachinePort(port) {
                forwarded.remove(port)
                note("machine port forward: released 127.0.0.1:\(port)")
            }
        }
    }

    private static func startMachinePortWatcher(vsock: VirtioVsock, forwarder: PortForwarder) -> any DispatchSourceTimer {
        let forwarded = ForwardedPortSet()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 5, repeating: 2)
        timer.setEventHandler {
            Task.detached {
                let connection = vsock.connect(port: VsockPorts.agent)
                defer { connection.close() }
                let transport = AgentVsockTransport(connection: connection, readTimeoutNanoseconds: 2_000_000_000)
                let channel = AgentChannel(transport: transport)
                do {
                    let snapshot = try await channel.watchPorts()
                    await reconcileMachinePorts(snapshot: snapshot, forwarded: forwarded, forwarder: forwarder)
                } catch {
                    note("machine port watch skipped poll: \(error)")
                }
            }
        }
        timer.resume()
        note("machine port watcher polling guest agent")
        return timer
    }

    private static func probeAgent(vsock: VirtioVsock, attempts: Int = 15) async -> Bool {
        for attempt in 0..<attempts {
            let connection = vsock.connect(port: VsockPorts.agent)
            let transport = AgentVsockTransport(connection: connection, readTimeoutNanoseconds: 1_000_000_000)
            let channel = AgentChannel(transport: transport)
            do {
                _ = try await channel.watchPorts()
                connection.close()
                return true
            } catch {
                connection.close()
                if attempt < attempts - 1 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        return false
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

private func hostLinuxArch() -> String {
    #if arch(arm64)
    "arm64"
    #else
    "amd64"
    #endif
}
