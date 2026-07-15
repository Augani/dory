import Foundation

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
