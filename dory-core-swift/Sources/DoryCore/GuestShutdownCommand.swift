import Foundation

/// Applies Linux guest defaults that container workloads normally expect their VM provider to own.
/// `vm.max_map_count` is host-wide rather than container-namespaced, so macOS users cannot set it
/// through an ordinary Docker container. Docker 29 also stopped supplying its former high nofile
/// default, which exposes the minimal guest kernel's 4096-descriptor limit unless the daemon has an
/// explicit default.
public enum GuestContainerCompatibilityCommand {
    public static let maximumMapCount = 262_144
    public static let defaultOpenFiles = 65_536

    public static func configureKernel() -> String {
        "if ! printf '%s\\n' '\(maximumMapCount)' >/proc/sys/vm/max_map_count 2>/dev/null; "
            + "then echo DORY-VM-MAX-MAP-COUNT-FAILED >&2; fi"
    }
}

/// Builds the guest-side listener used when a Dory VM is asked to stop.
///
/// `sync; poweroff -f` alone makes the filesystem structurally recoverable, but it can still leave
/// Docker's container metadata ahead of containerd's snapshot transaction. Stop dockerd first and
/// wait for it to quiesce; only the bounded fallback is allowed to force the daemon down. Once no
/// daemon can allocate new blocks, trim free ext4 extents through virtio discard before the final
/// sync/unmount so deleted Docker data is returned to the host safely.
public enum GuestShutdownCommand {
    public static func listener(port: UInt16 = 2377) -> String {
        "( while true; do nc -l -p \(port) >/dev/null 2>&1; echo shutdown requested; "
            + shutdownSequence()
            + "; done ) & true"
    }

    /// Runs from a dory-agent exec request. The short delay lets the agent return the successful
    /// RPC before its child powers off the guest and closes the control connection.
    public static func detachedAgentRequest() -> String {
        "( sleep 0.1; echo shutdown requested; "
            + shutdownSequence()
            + " ) >/var/log/dory-shutdown.log 2>&1 </dev/null &"
    }

    /// Requests a normal systemd shutdown for a full desktop guest.
    ///
    /// Unlike the minimal Docker guest, a desktop has a graphical user session whose applications
    /// need SIGTERM and time to persist their state. Forcing power off makes Firefox count every
    /// ordinary VM stop as a crash and eventually relaunch in Troubleshoot Mode. The VMM's bounded
    /// watchdog remains the fallback if systemd cannot complete the request.
    public static func detachedDesktopRequest() -> String {
        // Let PID 1 own the delayed request. A shell backgrounded by dory-agent remains in the
        // agent's process group/cgroup and can be reaped before it reaches `systemctl poweroff`.
        // A transient systemd service survives the RPC process and gives the agent time to return
        // its success response before the graphical session begins shutting down.
        "echo shutdown requested >/var/log/dory-shutdown.log; sync; "
            + "systemd-run --quiet --collect --unit=dory-host-poweroff "
            + "--on-active=1s /usr/bin/systemctl poweroff "
            + ">>/var/log/dory-shutdown.log 2>&1"
    }

    private static func shutdownSequence() -> String {
        let attempts = DoryEngineShutdownTiming.dockerdPollAttempts
        let interval = DoryEngineShutdownTiming.pollIntervalSeconds
        return "DORY_DOCKERD_PID=$(cat /var/run/docker.pid 2>/dev/null || pidof dockerd 2>/dev/null || true); "
            + "if [ -n \"$DORY_DOCKERD_PID\" ]; then kill -TERM $DORY_DOCKERD_PID 2>/dev/null || true; "
            + "DORY_DOCKERD_WAIT=0; while kill -0 $DORY_DOCKERD_PID 2>/dev/null "
            + "&& [ \"$DORY_DOCKERD_WAIT\" -lt \(attempts) ]; do sleep \(interval); "
            + "DORY_DOCKERD_WAIT=$((DORY_DOCKERD_WAIT + 1)); done; "
            + "if kill -0 $DORY_DOCKERD_PID 2>/dev/null; then echo dockerd shutdown timed out; "
            + "kill -KILL $DORY_DOCKERD_PID 2>/dev/null || true; sleep 1; fi; fi; "
            + "fstrim -v /var/lib/docker >/var/log/dory-data-trim.log 2>&1 || true; "
            + "cp /var/log/dory-data-trim.log /mnt/dory-logs/data-trim.log 2>/dev/null || true; "
            + "sync; umount /var/lib/docker 2>/dev/null || true; sync; poweroff -f"
    }
}

/// Periodically returns free ext4 extents to the sparse host image while the engine remains up.
/// Boot and shutdown trims remain the authoritative boundary checks; this loop keeps a long-running
/// engine from retaining deleted Docker layers and volume data until its next restart.
public enum GuestStorageReclaimCommand {
    public static let defaultIntervalSeconds: UInt64 = 3_600

    public static func periodicLoop(
        intervalSeconds: UInt64 = defaultIntervalSeconds
    ) -> String {
        let interval = max(60, intervalSeconds)
        return "( while true; do sleep \(interval); "
            + "if mountpoint -q /var/lib/docker; then "
            + "fstrim -v /var/lib/docker >/var/log/dory-data-trim.log 2>&1 || true; "
            + "cp /var/log/dory-data-trim.log /mnt/dory-logs/data-trim.log 2>/dev/null || true; "
            + "fi; done ) & true"
    }
}

/// Keeps BuildKit cache useful without letting it grow to the full sparse disk capacity.
/// Docker evaluates its normal age and value-aware policies, but Dory lowers the cache ceiling
/// because the engine drive is intended to contain images and volumes as well as build data.
public enum GuestBuildCacheGCCommand {
    public static let defaultKeepStorage = "2GB"

    public static func configureDaemon() -> String {
        let openFiles = GuestContainerCompatibilityCommand.defaultOpenFiles
        let configuration = #"{"builder":{"gc":{"enabled":true,"defaultKeepStorage":"\#(defaultKeepStorage)"}},"default-ulimits":{"nofile":{"Name":"nofile","Hard":\#(openFiles),"Soft":\#(openFiles)}}}"#
        return "mkdir -p /etc/docker; printf '%s\\n' '\(configuration)' >/etc/docker/daemon.json"
    }
}
