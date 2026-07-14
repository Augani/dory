import DoryCore
import DoryHV
import Foundation
import Synchronization

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
        /// Durable user-data drive path. Runtime sockets/rootfs clones stay in stateDirectory.
        var dockerDataDiskPath: String?
        /// Canonical root of the managed data drive, when one owns dockerDataDiskPath.
        var dataDriveRoot: String?
        /// Offline builds pass a decompressed engine rootfs here so first launch needs no network;
        /// online builds leave it nil and the engine fetches the image once.
        var bundledRootfs: String?
        var shares: [VirtioFSShareConfiguration] = []
        var directIP: DirectIPBridgeConfiguration?
        var gpuMode: GPUAccelerationMode = .off
        /// Register FEX's seccomp-correct binfmt handler and Dory OCI runtime so
        /// `--platform linux/amd64` images run on the arm64 engine.
        var amd64Emulation: Bool = false
        /// Host address published container ports bind to. Defaults to loopback; set to 0.0.0.0 only
        /// when the user opts into LAN visibility (Settings → Network / `dory network --lan-visible`).
        var publishHost: String = "127.0.0.1"
        /// Unix socket the Rust dataplane's ForwardBackend dials (re-platform docker tier): each
        /// connection opens a preamble-named guest vsock stream. nil keeps the forward off.
        var agentVsockForward: String?
        var sshAgentSocket: String?
        /// Current guest agent binary supplied by the app/doryd bundle for this boot. It is copied
        /// into the read-only boot-config share so stale files under the user's home cannot shadow it.
        var guestAgentPath: String?
    }

    enum GPUAccelerationMode: String {
        case off
        case venus
    }

    /// gvproxy is launched and stopped under the same lock so a shutdown signal cannot race the
    /// post-spawn registration window or run cleanup twice. The forced-exit watchdog must call the
    /// cleanup directly because `exit` does not unwind Swift `defer` blocks.
    private static let sidecarLock = NSLock()
    nonisolated(unsafe) private static var sidecarProcess: Process?
    nonisolated(unsafe) private static var signalSources: [any DispatchSourceSignal] = []
    nonisolated(unsafe) private static var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    private static func launchGVProxy(_ process: Process) throws {
        sidecarLock.lock()
        defer { sidecarLock.unlock() }
        guard sidecarProcess == nil else {
            throw VMError.invalidConfiguration("gvproxy sidecar is already registered")
        }
        try process.run()
        sidecarProcess = process
    }

    private static func stopGVProxy(gracePeriod: TimeInterval = 2) {
        sidecarLock.lock()
        defer { sidecarLock.unlock() }
        guard let process = sidecarProcess else { return }
        let outcome = ChildProcessTerminator.terminateAndReap(process, gracePeriod: gracePeriod)
        sidecarProcess = nil
        if outcome == .killed {
            note("gvproxy ignored SIGTERM for \(gracePeriod)s; sent SIGKILL and reaped it")
        }
    }

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
                let watchdog = DoryEngineShutdownTiming.helperWatchdogSeconds
                DispatchQueue.global().asyncAfter(deadline: .now() + watchdog) {
                    note("guest did not stop in \(watchdog)s, forcing exit")
                    stopGVProxy()
                    exit(1)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    static var reclaimModeIsSenpai: Bool {
        (ProcessInfo.processInfo.environment["DORY_ENGINE_RECLAIM_MODE"]?.lowercased() ?? "dropcaches") == "senpai"
    }

    // P1.2 host-pressure tier: when macOS reports memory pressure, ping the guest's reclaim listener so
    // it hands memory back exactly when the host needs it (the free-page-reporting moat, on demand).
    // Mirrors the shutdown channel: a forwarded unix socket → guest tcp 2378. Gated to senpai mode.
    private static func installHostPressureReclaim(reclaimSocket: String) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler {
            note("host memory pressure — asking the guest to reclaim")
            DispatchQueue.global().async { _ = touchUnixSocket(reclaimSocket) }
        }
        source.resume()
        memoryPressureSource = source
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

    private static func installPortReconcileSignal(portForwarder: PortForwarder) {
        signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .global())
        source.setEventHandler {
            note("manual port reconcile requested")
            portForwarder.reconcileNow()
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
        let channel = AgentChannel(connection: connection)
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

    /// Monitors a private gvproxy forward without depending on public Internet reachability. The
    /// Docker witness takes the independent engine.sock -> vsock path, so only a repeated canary
    /// failure while Docker still answers is allowed to restart the VM.
    private static func monitorGVProxyDatapath(
        healthSocket: String,
        dockerSocket: String,
        apiSocket: String,
        diagnosticPath: String,
        gvproxyPID: Int32,
        network: VirtioNet,
        machine: Machine
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            // Guest boot, dockerd readiness, and the asynchronous forward registration all happen
            // after machine.run() starts. Keep that startup window outside the recovery policy.
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return
            }

            var guardState = GVProxyDatapathGuard(failureThreshold: 3)
            var reportedInconclusive = false
            while !Task.isCancelled {
                let canaryResponse = UnixSocketHTTPClient.get(
                    socketPath: healthSocket,
                    path: "/_ping",
                    timeout: 2,
                    maximumBodyBytes: 64
                )
                let canaryReachable = canaryResponse.map {
                    $0.statusCode == 200 && String(decoding: $0.body, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        == "OK"
                } ?? false
                let dockerResponse = UnixSocketHTTPClient.get(
                    socketPath: dockerSocket,
                    path: "/_ping",
                    timeout: 2,
                    maximumBodyBytes: 64
                )
                let dockerReachable = dockerResponse.map {
                    $0.statusCode == 200 && String(decoding: $0.body, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
                } ?? false

                switch guardState.observe(
                    gvproxyCanaryReachable: canaryReachable,
                    dockerAPIReachable: dockerReachable
                ) {
                case .healthy, .restartAlreadyRequested:
                    reportedInconclusive = false
                case .recovered(let previousFailures):
                    persistGVProxyDiagnostic(
                        path: diagnosticPath,
                        reason: "recovered",
                        consecutiveFailures: previousFailures,
                        gvproxyPID: gvproxyPID,
                        apiSocket: apiSocket,
                        statistics: network.statistics
                    )
                    note("gvproxy datapath canary recovered after \(previousFailures) failed probe(s)")
                    reportedInconclusive = false
                case .inconclusive:
                    // Do not blame gvproxy when the independent guest witness is unavailable. Log
                    // once per inconclusive run and leave VM lifecycle to the Docker supervisor.
                    if !reportedInconclusive {
                        note("gvproxy datapath probe inconclusive: Docker witness is unavailable; no restart requested")
                        reportedInconclusive = true
                    }
                case .suspected(let failures):
                    reportedInconclusive = false
                    persistGVProxyDiagnostic(
                        path: diagnosticPath,
                        reason: "suspected",
                        consecutiveFailures: failures,
                        gvproxyPID: gvproxyPID,
                        apiSocket: apiSocket,
                        statistics: network.statistics
                    )
                    note("gvproxy datapath canary failed while Docker remained responsive (\(failures)/\(guardState.failureThreshold))")
                case .restartRequired(let failures):
                    let reason = "gvproxy remained alive but its local datapath canary failed \(failures) consecutive times while Docker remained responsive"
                    persistGVProxyDiagnostic(
                        path: diagnosticPath,
                        reason: "restart-required",
                        consecutiveFailures: failures,
                        gvproxyPID: gvproxyPID,
                        apiSocket: apiSocket,
                        statistics: network.statistics
                    )
                    note("\(reason); requesting bounded engine restart (diagnostic: \(diagnosticPath))")
                    machine.requestStop(.crash(reason))
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private static func persistGVProxyDiagnostic(
        path: String,
        reason: String,
        consecutiveFailures: Int,
        gvproxyPID: Int32,
        apiSocket: String,
        statistics: VirtioNetStatistics
    ) {
        let proxyStats = UnixSocketHTTPClient.get(
            socketPath: apiSocket,
            path: "/stats",
            timeout: 2,
            maximumBodyBytes: 32 * 1_024
        ).flatMap { response in
            response.statusCode == 200 ? String(decoding: response.body, as: UTF8.self) : nil
        }
        let diagnostic = GVProxyDatapathDiagnostic(
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            reason: reason,
            consecutiveFailures: consecutiveFailures,
            gvproxyPID: gvproxyPID,
            transmitPackets: statistics.transmitPackets,
            transmitBytes: statistics.transmitBytes,
            transmitDrops: statistics.transmitDrops,
            receivePackets: statistics.receivePackets,
            receiveBytes: statistics.receiveBytes,
            receiveDeferred: statistics.receiveDeferred,
            receiveDrops: statistics.receiveDrops,
            receiveTruncations: statistics.receiveTruncations,
            gvproxyStats: proxyStats
        )
        guard let data = try? JSONEncoder().encode(diagnostic) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private struct GVProxyDatapathDiagnostic: Codable {
        var recordedAt: String
        var reason: String
        var consecutiveFailures: Int
        var gvproxyPID: Int32
        var transmitPackets: UInt64
        var transmitBytes: UInt64
        var transmitDrops: UInt64
        var receivePackets: UInt64
        var receiveBytes: UInt64
        var receiveDeferred: UInt64
        var receiveDrops: UInt64
        var receiveTruncations: UInt64
        var gvproxyStats: String?
    }

    static func run(_ configuration: Configuration) async throws {
        try DockerSocketBridge.validateSocketPath(configuration.engineSocket)
        if let forwardSocket = configuration.agentVsockForward {
            try AgentVsockForward.validateSocketPath(forwardSocket)
        }
        let sshAgentBridge = try configuration.sshAgentSocket.map {
            try HostSSHAgentBridge(socketPath: $0, log: { note($0) })
        }
        try VirtioFSShareConfiguration.validateWritableTopology(configuration.shares)
        let nativeIPv6 = try NativeIPv6NetworkPlan(directIP: configuration.directIP)
        let sourcePreservingLAN = configuration.publishHost == "0.0.0.0"
        let state = URL(fileURLWithPath: configuration.stateDirectory).standardizedFileURL.path
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        let stateDirectoryLock = try EngineStateDirectoryLock(stateDirectory: state)
        defer { withExtendedLifetime(stateDirectoryLock) {} }

        let pristineRootfs = state + "/rootfs-pristine.ext4"
        let bootRootfs = state + "/rootfs-boot.ext4"
        let dataDisk = URL(fileURLWithPath: configuration.dockerDataDiskPath ?? (state + "/docker-data.ext4"))
            .standardizedFileURL.path
        let dataDiskDirectory = URL(fileURLWithPath: dataDisk).deletingLastPathComponent().path
        let dataDriveLock: EngineStateDirectoryLock?
        if let dataDriveRoot = configuration.dataDriveRoot {
            dataDriveLock = try EngineStateDirectoryLock(
                stateDirectory: dataDriveRoot,
                lockFileName: "drive.lock"
            )
        } else if dataDiskDirectory != state {
            dataDriveLock = try EngineStateDirectoryLock(stateDirectory: dataDiskDirectory)
        } else {
            dataDriveLock = nil
        }
        defer { withExtendedLifetime(dataDriveLock) {} }

        // Both one-time artifacts are built at a temp path and atomically renamed into place, so an
        // interrupted first run leaves no half-written file that the fileExists guard would then
        // treat as complete forever.
        if let bundledRootfs = configuration.bundledRootfs,
           FileManager.default.fileExists(atPath: bundledRootfs) {
            // Offline build: the engine image ships in the app, no network on first launch. Reinstall
            // whenever the bundled rootfs changes so a new app version's guest agent/init is not masked
            // by a stale pristine.
            try PristineRootfs.ensure(state: state, bundledRootfs: bundledRootfs) { note($0) }
        } else if FileManager.default.fileExists(atPath: pristineRootfs) {
            note("reusing installed engine rootfs from \(pristineRootfs)")
        } else {
            throw VMError.invalidConfiguration("dory-hv engine requires an installed or bundled engine rootfs")
        }
        try? FileManager.default.removeItem(atPath: bootRootfs)
        try FileManager.default.copyItem(atPath: pristineRootfs, toPath: bootRootfs)

        let dataDiskPreparation = try DockerDataDisk.prepare(destination: dataDisk)
        switch dataDiskPreparation {
        case .alreadyPresent:
            break
        case .createdBlank:
            note("first run: created docker data disk")
        }
        let allowDockerDataFormat: Bool
        switch dataDiskPreparation {
        case .createdBlank:
            allowDockerDataFormat = true
        case .alreadyPresent:
            // Host validation admits a non-ext4 existing file only when it has zero allocated
            // blocks, which is a first-boot sparse blank left by an interrupted earlier launch.
            allowDockerDataFormat = try !DockerDataDisk.isExt4Image(at: dataDisk)
        }

        let bootConfigShare = try writeBootConfiguration(stateDirectory: state, script: guestBootScript(
            shares: configuration.shares,
            gpuMode: configuration.gpuMode,
            amd64Emulation: configuration.amd64Emulation,
            nativeIPv6: nativeIPv6,
            sourcePreservingLAN: sourcePreservingLAN,
            allowDockerDataFormat: allowDockerDataFormat
        ), guestAgentPath: configuration.guestAgentPath)
        let guestLogShare = try guestLogShareConfiguration(stateDirectory: state)

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
        backends.append(VirtioRng())
        backends.append(VirtioBalloon(memory: machine.memory) { note($0) })
        var daxSlot: UInt64 = 0
        if configuration.gpuMode == .venus {
            let renderer = try VenusModeRequirement.require {
                try VirglRenderer.discover()
            }
            let hostMemoryBase = GuestLayout.daxWindowBase + daxSlot * DaxWindow.defaultSize
            let hostVisibleMemory = try VirtioGPUHostVisibleMemory(guestBase: hostMemoryBase)
            daxSlot += 1
            backends.append(VirtioGPU(
                hostMemoryBase: hostMemoryBase,
                renderer: renderer,
                hostVisibleMemory: hostVisibleMemory
            ))
            note(
                "experimental gpu=venus: attached virtio-gpu with virglrenderer "
                    + "\(renderer.libraryPath) and MoltenVK ICD \(renderer.moltenVKICDPath)"
            )
        }
        let vsock = VirtioVsock(guestCID: 3)
        backends.append(vsock)
        HostAIBridge(log: { note($0) }).attach(to: vsock)
        sshAgentBridge?.attach(to: vsock)
        let requestedFuseQueues = ProcessInfo.processInfo.environment["DORY_FUSE_QUEUES"]
            .flatMap(Int.init) ?? configuration.cpus
        let fuseRequestQueues = min(8, max(1, requestedFuseQueues))
        backends.append(try bootConfigShare.makeBackend(requestQueueCount: fuseRequestQueues))
        backends.append(try guestLogShare.makeBackend(requestQueueCount: fuseRequestQueues))
        var coherenceEndpoints = [HostShareCoherenceEndpoint]()
        for share in configuration.shares {
            let daxBase = share.dax ? GuestLayout.daxWindowBase + daxSlot * DaxWindow.defaultSize : nil
            if share.dax { daxSlot += 1 }
            let backend = try share.makeBackend(
                daxGuestBase: daxBase,
                requestQueueCount: fuseRequestQueues
            )
            backends.append(backend)
            // Read-only shares cannot accept the same-mode watcher nudge, but they still need host
            // reverse invalidation so open-file page cache cannot stay stale. Keep metadata caching
            // disabled and skip only the fsnotify approximation for those endpoints.
            coherenceEndpoints.append(HostShareCoherenceEndpoint(
                share: HostFSEventShare(
                    hostRoot: share.path,
                    guestRoot: share.guestMountPoint ?? "/mnt/dory/\(share.tag)"
                ),
                backend: backend,
                watcherNudgesEnabled: !share.readOnly
            ))
            note("sharing \(share.path) as virtiofs tag \(share.tag)\(share.readOnly ? " (ro)" : "")\(share.dax ? " (dax)" : "")")
        }

        let datapathSocket = state + "/net.sock"
        let lanDatapathSocket = state + "/lan-net.sock"
        let apiSocket = state + "/gvproxy-api.sock"
        let shutdownSocket = state + "/shutdown.sock"
        let gvproxyHealthSocket = state + "/gvproxy-health.sock"
        try? FileManager.default.removeItem(atPath: datapathSocket)
        try? FileManager.default.removeItem(atPath: lanDatapathSocket)
        try? FileManager.default.removeItem(atPath: apiSocket)
        // Install before spawning gvproxy. A signal arriving during the remaining VM setup must use
        // the watchdog cleanup path rather than taking the default signal action and orphaning it.
        installGracefulShutdown(shutdownSocket: shutdownSocket)
        let gvproxy = Process()
        gvproxy.executableURL = URL(fileURLWithPath: configuration.gvproxyPath)
        gvproxy.arguments = [
            "-mtu", "1500",
            "-listen-vfkit", "unixgram://\(datapathSocket)",
            "-listen", "unix://\(apiSocket)",
        ]
        if sourcePreservingLAN {
            gvproxy.arguments?.append(contentsOf: [
                "-listen-qemu", "unix://\(lanDatapathSocket)",
            ])
        }
        if let nativeIPv6 {
            let configPath = state + "/gvproxy-dual-stack.yaml"
            try nativeIPv6.gvproxyYAML.write(toFile: configPath, atomically: true, encoding: .utf8)
            gvproxy.arguments?.append(contentsOf: ["-config", configPath])
        } else {
            // In flag-only mode gvproxy otherwise creates its legacy 127.0.0.1:2222 SSH forward.
            // Config-file mode never creates that default and warns if -ssh-port is supplied.
            gvproxy.arguments?.append(contentsOf: ["-ssh-port", "-1"])
        }
        gvproxy.standardOutput = FileHandle.standardError
        gvproxy.standardError = FileHandle.standardError
        let gvproxyTerminationExpected = Atomic<Bool>(false)
        // gvproxy is the engine's only Internet path. If it dies, keeping the VM and Docker socket
        // alive reports a false-running engine whose pulls and package installs simply hang. Stop the
        // VM so doryd's bounded full-tier restart can rebuild the sidecar and every dependent socket.
        // This callback deliberately takes no sidecarLock: stopGVProxy waits for termination while
        // holding that lock, and Process invokes this handler as part of the same termination path.
        gvproxy.terminationHandler = { process in
            guard !gvproxyTerminationExpected.load(ordering: .acquiring) else { return }
            let cause = process.terminationReason == .uncaughtSignal ? "signal" : "exit"
            let detail = "gvproxy terminated (\(cause) \(process.terminationStatus))"
            note(detail)
            machine.requestStop(.crash(detail))
        }
        defer {
            gvproxyTerminationExpected.store(true, ordering: .releasing)
            stopGVProxy()
        }
        try launchGVProxy(gvproxy)
        for _ in 0..<100 {
            let primaryReady = FileManager.default.fileExists(atPath: datapathSocket)
            let lanReady = !sourcePreservingLAN
                || FileManager.default.fileExists(atPath: lanDatapathSocket)
            if primaryReady && lanReady { break }
            usleep(50_000)
        }
        let virtioNet = try VirtioNet(socketPath: state + "/vm-net.sock", remotePath: datapathSocket)
        backends.append(virtioNet)
        var sourcePreservingLANClient: SourcePreservingLANPrivilegedClient?
        var sourcePreservingLANSessionID: String?
        if sourcePreservingLAN {
            let client = SourcePreservingLANPrivilegedClient()
            let sessionID = "hv-\(getpid())"
            let response = try client.apply(SourcePreservingLANRequest(
                operation: .activate,
                sessionID: sessionID,
                gvproxySocketPath: lanDatapathSocket
            ))
            guard response.status == "active" else {
                throw VMError.invalidConfiguration("source-preserving LAN helper did not activate")
            }
            sourcePreservingLANClient = client
            sourcePreservingLANSessionID = sessionID
            note("source-preserving LAN packet bridge active on \(response.interfaceName ?? "unknown interface")")
        }
        defer {
            if let client = sourcePreservingLANClient, let sessionID = sourcePreservingLANSessionID {
                _ = try? client.apply(SourcePreservingLANRequest(
                    operation: .deactivate,
                    sessionID: sessionID
                ))
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
        // engine.sock is the sole Docker path: dory-hv serves it over vsock from boot. A gvproxy unix
        // forward instead tears the stream down on the docker CLI's post-request half-close, which
        // silences every foreground `docker run`/`attach`, so we never republish engineSocket to one.
        // Connections before the guest agent listens fail fast and the app's readiness probe retries,
        // so nothing waits on the sidecar.
        // The Rust dataplane cannot establish its authoritative agent channel without this forward.
        // Bind it before publishing engine.sock and propagate any listener error out of run(), so a
        // configured-but-impossible path terminates dory-hv instead of advertising a half-alive VM.
        if let forwardSocket = configuration.agentVsockForward {
            try AgentVsockForward(socketPath: forwardSocket, guestCID: 3, log: { note($0) }).attach(to: vsock)
        }
        // engine.sock is the sole Docker API endpoint, so its listener is just as required as the
        // dataplane forward. Propagate bind/listen/chmod failures before entering machine.run().
        try DockerSocketBridge(socketPath: configuration.engineSocket, log: { note($0) }).attach(to: vsock)
        publishForward(local: shutdownSocket, guestPort: 2377, apiSocket: apiSocket, label: "shutdown channel")
        publishForward(
            local: gvproxyHealthSocket,
            guestPort: 2375,
            apiSocket: apiSocket,
            label: "gvproxy datapath canary"
        )
        installClockSyncSignal(vsock: vsock)
        if reclaimModeIsSenpai {
            let reclaimSocket = state + "/reclaim.sock"
            publishForward(local: reclaimSocket, guestPort: 2378, apiSocket: apiSocket, label: "host-pressure reclaim channel")
            installHostPressureReclaim(reclaimSocket: reclaimSocket)
        }

        // Keep gvproxy's forwards in sync with the ports containers publish, so `docker run -p` is
        // reachable from the host across the userspace network.
        let portForwarder = PortForwarder(
            engineSocket: configuration.engineSocket,
            apiSocket: apiSocket,
            guestIP: "192.168.127.2",
            localHost: configuration.publishHost,
            sourcePreservingLANClient: sourcePreservingLANClient,
            sourcePreservingLANSessionID: sourcePreservingLANSessionID,
            sourcePreservingLANGVProxySocketPath: sourcePreservingLANClient == nil ? nil : lanDatapathSocket,
            log: { note($0) }
        )
        installPortReconcileSignal(portForwarder: portForwarder)
        portForwarder.start()
        let gvproxyDatapathTask = monitorGVProxyDatapath(
            healthSocket: gvproxyHealthSocket,
            dockerSocket: configuration.engineSocket,
            apiSocket: apiSocket,
            diagnosticPath: state + "/gvproxy-health-last-failure.json",
            gvproxyPID: gvproxy.processIdentifier,
            network: virtioNet,
            machine: machine
        )
        defer { gvproxyDatapathTask.cancel() }
        note("engine starting: \(configuration.memoryMB)MiB ceiling, \(configuration.cpus) cpus, socket \(configuration.engineSocket)")

        // The host usbip bridge exists, but attach/detach is deliberately unavailable until the
        // authoritative protobuf agent protocol has a real guest vhci RPC. The capability gate runs
        // before HostUsbDeviceFactory.open, so commands fail closed without claiming host hardware.
        let usbipManager = UsbipManager()
        usbipManager.attachListener(to: vsock)
        let usbControlHandler = UsbControlHandler(
            manager: usbipManager,
            ensureSupported: { throw UsbControlError.guestAgentRPCUnavailable },
            openDevice: { busID, mode in try HostUsbDeviceFactory.open(busID: busID, mode: mode) },
            notifyAttach: { _ in throw UsbControlError.guestAgentRPCUnavailable },
            notifyDetach: { _ in throw UsbControlError.guestAgentRPCUnavailable }
        )
        let usbControlServer = UsbControlServer(path: configuration.stateDirectory + "/usb-control.sock", handler: usbControlHandler)
        do { try usbControlServer.start() } catch { note("usb control server unavailable: \(error)") }

        let memory = machine.memory
        let gauge = DispatchSource.makeTimerSource(queue: .global())
        gauge.schedule(deadline: .now() + 60, repeating: 60)
        gauge.setEventHandler {
            let released = memory.releasedBytes.load()
            let restored = memory.restoredBytes.load()
            note("reclaim gauge: released \(released >> 20)MiB, restored \(restored >> 20)MiB, net \(Int64(bitPattern: released &- restored) / 1_048_576)MiB")
            let network = virtioNet.statistics
            note("network gauge: tx \(network.transmitPackets)p/\(network.transmitBytes)B drops=\(network.transmitDrops), rx \(network.receivePackets)p/\(network.receiveBytes)B deferred=\(network.receiveDeferred) drops=\(network.receiveDrops) truncated=\(network.receiveTruncations)")
        }
        gauge.resume()

        var hostFSEventRelay: HostFSEventRelay?
        var cacheReadinessTask: Task<Void, Never>?
        if !coherenceEndpoints.isEmpty {
            let activeEndpoints = coherenceEndpoints
            let coordinator = HostShareCoherenceCoordinator(
                endpoints: activeEndpoints,
                guestEvents: GuestFSEventBridge(vsock: vsock),
                onDegraded: { note($0) },
                onRecovered: { note($0) },
                onFatalRecoveryRequired: { reason in
                    note("host-share coherence requires VM restart: \(reason)")
                    machine.requestStop(.crash(reason))
                }
            )
            let relay = HostFSEventRelay(
                shares: activeEndpoints.map(\.share),
                observeRootsOnDemand: true,
                send: { changes in
                    try await coordinator.process(changes)
                    coordinator.relayDeliverySucceeded()
                },
                onFailure: { error in
                    let message = String(describing: error)
                    // This updates the readiness generation and drops response TTLs synchronously;
                    // actor bookkeeping cannot race cache activation back on for a failed batch.
                    coordinator.relayDeliveryFailed("host-share event relay failed: \(message)")
                    note("host-share event relay: \(message)")
                }
            )
            let relayStarted = relay.start()
            try HostShareCoherenceStartupPolicy.requireEventRelay(
                started: relayStarted,
                productionShareCount: activeEndpoints.count
            )
            for endpoint in activeEndpoints {
                endpoint.backend.hostFS.setEventObservationHandler { hostPath in
                    guard relay.observe(hostPath: hostPath) else {
                        let reason = "failed to start narrow host-share observation for \(hostPath)"
                        coordinator.relayDeliveryFailed(reason)
                        note(reason)
                        machine.requestStop(.crash(reason))
                        return
                    }
                }
            }
            hostFSEventRelay = relay
            let watcherCount = activeEndpoints.filter(\.watcherNudgesEnabled).count
            note("host-share invalidation relay active for \(activeEndpoints.count) share(s), watcher nudges on \(watcherCount)")
            // The VM has not entered its run loop yet, so FUSE INIT, the 16 stable notify
            // buffers, and the guest agent arrive asynchronously. Poll only the fail-closed
            // readiness predicate; no environment flag can bypass these gates.
            if activeEndpoints.contains(where: \.watcherNudgesEnabled) {
                cacheReadinessTask = Task.detached(priority: .userInitiated) {
                    var lastError: String?
                    let deadline = ProcessInfo.processInfo.systemUptime + 120
                    while ProcessInfo.processInfo.systemUptime < deadline {
                        guard !Task.isCancelled else { return }
                        do {
                            if try await coordinator.activateCachingIfReady() {
                                note("host-share coherent metadata cache active (\(VirtioFS.maximumCoherentCacheValiditySeconds)s bounded TTL)")
                                return
                            }
                        } catch {
                            lastError = String(describing: error)
                        }
                        do {
                            try await Task.sleep(nanoseconds: 100_000_000)
                        } catch {
                            return
                        }
                    }
                    let detail = lastError.map { ": \($0)" } ?? ""
                    note("host-share cache readiness timed out; zero-cache safety retained\(detail)")
                }
            }
        }
        defer {
            cacheReadinessTask?.cancel()
            for endpoint in coherenceEndpoints {
                endpoint.backend.hostFS.setEventObservationHandler(nil)
            }
            hostFSEventRelay?.stop()
        }

        let stop = try machine.run()
        gauge.cancel()
        note("engine stopped: \(stop)")
    }

    private static func writeBootConfiguration(
        stateDirectory: String,
        script: String,
        guestAgentPath: String?
    ) throws -> VirtioFSShareConfiguration {
        let directory = stateDirectory + "/boot-config"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/boot.sh"
        let temporary = path + ".partial"
        try? FileManager.default.removeItem(atPath: temporary)
        try Data(script.utf8).write(to: URL(fileURLWithPath: temporary), options: .atomic)
        guard chmod(temporary, S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH) == 0 else {
            throw VMError.invalidConfiguration("cannot chmod \(temporary): errno \(errno)")
        }
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: temporary, toPath: path)
        try stageGuestAgent(sourcePath: guestAgentPath, directory: directory)
        return try VirtioFSShareConfiguration(tag: "dorycfg", path: directory, readOnly: true)
    }

    private static func stageGuestAgent(sourcePath: String?, directory: String) throws {
        let destination = directory + "/dory-agent"
        let temporary = destination + ".partial"
        try? FileManager.default.removeItem(atPath: temporary)
        guard let sourcePath, FileManager.default.fileExists(atPath: sourcePath) else {
            try? FileManager.default.removeItem(atPath: destination)
            return
        }
        do {
            try FileManager.default.copyItem(atPath: sourcePath, toPath: temporary)
            guard chmod(temporary, S_IRUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH) == 0 else {
                throw VMError.invalidConfiguration("cannot chmod \(temporary): errno \(errno)")
            }
            try? FileManager.default.removeItem(atPath: destination)
            try FileManager.default.moveItem(atPath: temporary, toPath: destination)
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            try? FileManager.default.removeItem(atPath: destination)
            throw error
        }
    }

    private static func guestLogShareConfiguration(stateDirectory: String) throws -> VirtioFSShareConfiguration {
        let directory = stateDirectory + "/guest-logs"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return try VirtioFSShareConfiguration(tag: "dorylogs", path: directory, readOnly: false)
    }

    /// Guest boot: mounts (docker state on the journaled /dev/vdb), DHCP through gvproxy,
    /// dockerd on unix + tcp 2375 (virtual network only), a shutdown listener on tcp 2377 (any
    /// connection triggers sync + poweroff, giving the host a clean-unmount path), and a light
    /// workload-aware page-cache cap so free page reporting (which handles free pages automatically
    /// at 16 KiB granularity) has cold pages to hand back when the engine is idle.
    private static func guestBootScript(
        shares: [VirtioFSShareConfiguration] = [],
        gpuMode: GPUAccelerationMode = .off,
        amd64Emulation: Bool = false,
        nativeIPv6: NativeIPv6NetworkPlan? = nil,
        sourcePreservingLAN: Bool = false,
        allowDockerDataFormat: Bool = false
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
            "mkdir -p /mnt/dory-logs",
            "if mount -t virtiofs dorylogs /mnt/dory-logs 2>/dev/null; then",
            "  { echo BOOT; uname -a; cat /proc/cmdline; } >/mnt/dory-logs/boot.log 2>&1 || true",
            "  ( while [ ! -e /var/log/dockerd.log ]; do sleep 0.2; done; tail -n +1 -f /var/log/dockerd.log >/mnt/dory-logs/dockerd.log 2>&1 ) & true",
            "  ( while [ ! -e /var/log/dory-agent.log ]; do sleep 0.2; done; tail -n +1 -f /var/log/dory-agent.log >/mnt/dory-logs/dory-agent.log 2>&1 ) & true",
            "fi",
            "mkdir -p /var/lib/docker",
            // First boot receives a sparse blank disk from the host. Format it inside the guest so
            // the macOS 14 helper does not need Apple's macOS 15-only EXT4 formatter.
            "DORY_DOCKER_MOUNT_OPTS=noatime,lazytime,commit=30",
            "DORY_DOCKER_MOUNT_FALLBACK_OPTS=noatime,commit=30",
            "DORY_ALLOW_DATA_FORMAT=\(allowDockerDataFormat ? 1 : 0)",
            "dory_mount_docker_data() { mount -t ext4 -o \"$DORY_DOCKER_MOUNT_OPTS\" /dev/vdb /var/lib/docker || mount -t ext4 -o \"$DORY_DOCKER_MOUNT_FALLBACK_OPTS\" /dev/vdb /var/lib/docker || mount -t ext4 /dev/vdb /var/lib/docker; }",
            "dory_format_docker_data() { mkfs.ext4 -F -O fast_commit /dev/vdb >/var/log/dory-data-mkfs.log 2>&1 || mkfs.ext4 -F /dev/vdb >>/var/log/dory-data-mkfs.log 2>&1; }",
            "dory_grow_docker_data() {",
            "  DORY_DATA_DEVICE_BYTES=$(blockdev --getsize64 /dev/vdb 2>/dev/null || true)",
            "  DORY_DATA_GEOMETRY=$(dumpe2fs -h /dev/vdb 2>/dev/null | awk '/^Block count:/{blocks=$3} /^Block size:/{size=$3} END{if(blocks && size) print blocks, size}')",
            "  set -- $DORY_DATA_GEOMETRY",
            "  DORY_DATA_FS_BLOCKS=${1:-}; DORY_DATA_FS_BLOCK_SIZE=${2:-}",
            "  case \"$DORY_DATA_DEVICE_BYTES\" in ''|*[!0-9]*) echo invalid block-device size >/var/log/dory-data-resize.log; return 2;; esac",
            "  case \"$DORY_DATA_FS_BLOCKS\" in ''|*[!0-9]*) echo invalid ext4 block count >/var/log/dory-data-resize.log; return 2;; esac",
            "  case \"$DORY_DATA_FS_BLOCK_SIZE\" in ''|*[!0-9]*) echo invalid ext4 block size >/var/log/dory-data-resize.log; return 2;; esac",
            "  DORY_DATA_FS_BYTES=$((DORY_DATA_FS_BLOCKS * DORY_DATA_FS_BLOCK_SIZE))",
            "  [ \"$DORY_DATA_FS_BYTES\" -le \"$DORY_DATA_DEVICE_BYTES\" ] || { echo ext4 geometry exceeds block device >/var/log/dory-data-resize.log; return 2; }",
            "  if [ $((DORY_DATA_FS_BYTES + DORY_DATA_FS_BLOCK_SIZE)) -gt \"$DORY_DATA_DEVICE_BYTES\" ]; then echo ext4 already spans block device >/var/log/dory-data-resize.log; return 0; fi",
            "  e2fsck -p /dev/vdb >/var/log/dory-data-resize.log 2>&1",
            "  DORY_E2FSCK_STATUS=$?; [ $DORY_E2FSCK_STATUS -le 1 ] || return $DORY_E2FSCK_STATUS",
            "  resize2fs /dev/vdb >>/var/log/dory-data-resize.log 2>&1",
            "}",
            "if blkid /dev/vdb 2>/dev/null | grep -q 'TYPE=\"ext4\"'; then",
            "  dory_grow_docker_data || { echo DATA-DISK-RESIZE-FAILED; cat /var/log/dory-data-resize.log 2>/dev/null; sync; poweroff -f; exit 1; }",
            "  dory_mount_docker_data || { echo DATA-DISK-MOUNT-FAILED-EXISTING-EXT4; sync; poweroff -f; exit 1; }",
            "elif [ \"$DORY_ALLOW_DATA_FORMAT\" -eq 1 ]; then",
            "  echo DATA-DISK-FORMAT-PROVEN-BLANK",
            "  dory_format_docker_data && dory_mount_docker_data || { echo DATA-DISK-FORMAT-OR-MOUNT-FAILED; sync; poweroff -f; exit 1; }",
            "else",
            "  echo DATA-DISK-UNKNOWN-FILESYSTEM-REFUSING-FORMAT",
            "  sync; poweroff -f; exit 1",
            "fi",
            // The raw virtio-blk backend maps DISCARD to APFS hole punching. Reclaim blocks from
            // deleted Docker layers/volumes before admission checks so an old sparse image does
            // not remain physically full even though ext4 reports substantial free space.
            "fstrim -v /var/lib/docker >/var/log/dory-data-trim.log 2>&1 || true",
            "cp /var/log/dory-data-trim.log /mnt/dory-logs/data-trim.log 2>/dev/null || true",
            "awk '$2==\"/var/lib/docker\"{print $4}' /proc/mounts >/var/log/dory-data-mount-options.log 2>&1 || true",
            "ip link set lo up",
            "ip link set eth0 up",
            // Internet access is not optional for the Docker tier. Do not publish a healthy Docker
            // socket around a guest with no address/default route/DNS: package managers then hang in
            // a way that looks like a container or registry bug. Preserve the DHCP transcript in the
            // host-visible guest log before powering off so the supervisor can retry the whole tier.
            "udhcpc -i eth0 -q -n -t 5 -T 1 >/var/log/dory-dhcp.log 2>&1 || { echo DORY-DHCP-FAILED >&2; cat /var/log/dory-dhcp.log >&2; cp /var/log/dory-dhcp.log /mnt/dory-logs/network.log 2>/dev/null || true; sync; poweroff -f; exit 1; }",
        ]
        if let nativeIPv6 {
            script += nativeIPv6.guestSetupCommands
            script.append("DORY_IPV6_DOCKER_ARGS='\(nativeIPv6.dockerDaemonArguments)'")
        } else {
            script.append("DORY_IPV6_DOCKER_ARGS=''")
        }
        if sourcePreservingLAN {
            script += SourcePreservingLANPlan.guestSetupCommands
        }
        script += [
            "{ ip -details address show dev eth0; ip route show; ip -6 route show; echo RESOLV-CONF; cat /etc/resolv.conf; } >/mnt/dory-logs/network.log 2>&1 || true",
            "echo 2 > /sys/module/page_reporting/parameters/page_reporting_order 2>/dev/null",
            // Keep the normal kernel dentry/inode balance during active workloads. Free page
            // reporting and the idle cache cap below handle reclaim without making metadata-heavy
            // container runs fight their own warm caches.
            "echo 100 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null",
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
            script.append("DORY_AMD64_RUNTIME_ARGS='--add-runtime dory-runc=/usr/local/bin/dory-runc --default-runtime dory-runc'")
        } else {
            script.append("DORY_AMD64_RUNTIME_ARGS=''")
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
            // Keep Docker's reference runc as the normal default. When amd64 translation is enabled,
            // dory-runc becomes the default and delegates to that same runc after injecting the
            // private FEX bundle. crun remains an explicit opt-in only when io.max is available.
            "if [ -x /usr/local/bin/crun ]; then echo +io > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; mkdir -p /sys/fs/cgroup/.dory-crun-probe 2>/dev/null; [ -e /sys/fs/cgroup/.dory-crun-probe/io.max ] && DORY_RUNTIME_ARGS='--add-runtime crun=/usr/local/bin/crun' || DORY_RUNTIME_ARGS=''; rmdir /sys/fs/cgroup/.dory-crun-probe 2>/dev/null; else DORY_RUNTIME_ARGS=''; fi",
            "dockerd -H unix:///var/run/docker.sock -H tcp://0.0.0.0:2375 --tls=false --log-level=warn --feature containerd-snapshotter=true $DORY_RUNTIME_ARGS $DORY_AMD64_RUNTIME_ARGS $DORY_IPV6_DOCKER_ARGS >/var/log/dockerd.log 2>&1 & true",
            GuestShutdownCommand.listener(),
            GuestMemoryReclaimBootCommand.hostPressureListener(
                experimentalSenpai: reclaimModeIsSenpai
            ),
            // Idle memory reclaim. Default is a gentle pagecache-only drop_caches when the guest is
            // quiet (no compaction — it re-faults the pages free-page reporting already handed back;
            // no root memory.reclaim — write-rejected on the root cgroup). DORY_ENGINE_RECLAIM_MODE=senpai
            // swaps in a coldest-first, working-set-protected feeder (MGLRU min_ttl_ms + DAMON_RECLAIM,
            // memory.reclaim fallback) per the research §5. Kept opt-in until the memory A/B lands.
            GuestMemoryReclaimBootCommand.idleLoop(
                experimentalSenpai: reclaimModeIsSenpai
            ),
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
        paths.append("/mnt/dory-config/dory-agent")
        for share in shares {
            let root = share.guestMountPoint ?? "/mnt/dory/\(share.tag)"
            paths.append("\(root)/.dory/bin/dory-agent-linux-\(hostLinuxArch())")
            paths.append("\(root)/.dory/bin/dory-agent")
        }
        paths.append("/usr/bin/dory-agent")
        let quotedPaths = paths.map(shellQuote).joined(separator: " ")
        let ports = HostAIBridge.defaultPorts.map(String.init).joined(separator: ",")
        return "( for i in $(seq 1 100); do if pgrep -x dory-agent >/dev/null 2>&1; then exit 0; fi; for p in \(quotedPaths); do if [ -r \"$p\" ]; then cp \"$p\" /run/dory-agent && chmod 0755 /run/dory-agent && DORY_HOST_AI_BRIDGE_PORTS=\(shellQuote(ports)) /run/dory-agent >/var/log/dory-agent.log 2>&1 & exit 0; fi; done; sleep 0.2; done; echo 'dory-agent not found after waiting: \(quotedPaths)' >/var/log/dory-agent.log ) & true"
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
        return "\(console) root=/dev/vda rw panic=0 init=/sbin/init"
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
