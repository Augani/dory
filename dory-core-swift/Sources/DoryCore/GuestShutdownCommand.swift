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
/// Keep live-restore for daemon-only restarts, but disable it before terminating the whole VM.
public enum GuestShutdownCommand {
    public static func listener(port: UInt16 = 2377) -> String {
        "( while true; do nc -l -p \(port) >/dev/null 2>&1; echo shutdown requested; "
            + shutdownSequence()
            + "\nexit $?; done ) & true"
    }

    /// Runs from a dory-agent exec request. The short delay lets the agent return the successful
    /// RPC before its child powers off the guest and closes the control connection.
    public static func detachedAgentRequest() -> String {
        "( sleep 0.1; echo shutdown requested; "
            + shutdownSequence()
            + " ) >/dev/console 2>&1 </dev/null &"
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

    static func shutdownSequence() -> String {
        let interval = DoryEngineShutdownTiming.pollIntervalSeconds
        return """
        dory_shutdown_clock() {
          read DORY_UPTIME DORY_IDLE </proc/uptime || return 1
          DORY_NOW=$(( ${DORY_UPTIME%.*} * 100 + 1${DORY_UPTIME#*.} - 100 ))
        }
        dory_service_pids() {
          for DORY_PID in $(pidof "$1" 2>/dev/null); do [ "$DORY_PID" = 1 ] || echo "$DORY_PID"; done
        }
        dory_stop_service() {
          DORY_SERVICE=$1; DORY_WAIT=0; DORY_PIDS=$(dory_service_pids "$DORY_SERVICE")
          [ -n "$DORY_PIDS" ] || return 0
          kill -TERM $DORY_PIDS || return 1
          while [ -n "$(dory_service_pids "$DORY_SERVICE")" ]; do
            [ "$DORY_WAIT" -lt "$2" ] || { echo "DORY-SHUTDOWN-FAILED: $DORY_SERVICE still running" >&2; return 1; }
            sleep \(interval); DORY_WAIT=$((DORY_WAIT + 1))
          done
        }
        dory_shutdown() {
          DORY_DOCKER_PIDS=$(dory_service_pids dockerd)
          if [ -n "$DORY_DOCKER_PIDS" ]; then
            dory_shutdown_clock || return 1
            DORY_RELOAD_DEADLINE=$((DORY_NOW + \(Int(DoryEngineShutdownTiming.reloadGraceSeconds * 100))))
            DORY_CONFIG=/etc/docker/daemon.json
            DORY_CONFIG_TMP=$DORY_CONFIG.shutdown.$$
            [ -f "$DORY_CONFIG" ] && [ ! -L "$DORY_CONFIG" ] || { echo 'DORY-SHUTDOWN-FAILED: missing daemon config' >&2; return 1; }
            grep -q '"live-restore":true' "$DORY_CONFIG" || { echo 'DORY-SHUTDOWN-FAILED: expected generated live-restore config' >&2; return 1; }
            (umask 077; set -C; : >"$DORY_CONFIG_TMP") || return 1
            if ! cp -p "$DORY_CONFIG" "$DORY_CONFIG_TMP" ||
               ! sed 's/"live-restore":true/"live-restore":false/' "$DORY_CONFIG" >"$DORY_CONFIG_TMP"; then
              rm -f "$DORY_CONFIG_TMP"; return 1
            fi
            if ! timeout -k 1 2 /usr/local/bin/dockerd --validate --config-file "$DORY_CONFIG_TMP" >/dev/null 2>&1; then
              rm -f "$DORY_CONFIG_TMP"; echo 'DORY-SHUTDOWN-FAILED: invalid daemon config' >&2; return 1
            fi
            if ! mv "$DORY_CONFIG_TMP" "$DORY_CONFIG"; then rm -f "$DORY_CONFIG_TMP"; return 1; fi
            kill -HUP $DORY_DOCKER_PIDS || { echo 'DORY-SHUTDOWN-FAILED: daemon reload signal' >&2; return 1; }
            while :; do
              [ -n "$(dory_service_pids dockerd)" ] || { echo 'DORY-SHUTDOWN-FAILED: dockerd exited before reload confirmation; task state unverified' >&2; return 1; }
              dory_shutdown_clock || return 1
              [ "$DORY_NOW" -lt "$DORY_RELOAD_DEADLINE" ] || { echo 'DORY-SHUTDOWN-FAILED: live-restore reload not confirmed' >&2; return 1; }
              DORY_REMAINING=$((DORY_RELOAD_DEADLINE - DORY_NOW))
              if [ "$DORY_REMAINING" -lt 2 ]; then sleep 0.01; continue; fi
              DORY_PROBE=$((DORY_REMAINING / 2)); [ "$DORY_PROBE" -le 100 ] || DORY_PROBE=100
              DORY_GRACE=$((DORY_REMAINING - DORY_PROBE)); [ "$DORY_GRACE" -le 100 ] || DORY_GRACE=100
              DORY_PROBE=$(printf '%s.%02d' "$((DORY_PROBE / 100))" "$((DORY_PROBE % 100))")
              DORY_GRACE=$(printf '%s.%02d' "$((DORY_GRACE / 100))" "$((DORY_GRACE % 100))")
              DORY_LIVE_RESTORE=$(timeout -k "$DORY_GRACE" "$DORY_PROBE" /usr/local/bin/docker -H unix:///var/run/docker.sock info --format '{{.LiveRestoreEnabled}}') &&
                [ "$DORY_LIVE_RESTORE" = false ] && break
              dory_shutdown_clock || return 1
              DORY_PAUSE=$((DORY_RELOAD_DEADLINE - DORY_NOW))
              [ "$DORY_PAUSE" -le \(Int(DoryEngineShutdownTiming.pollIntervalSeconds * 100)) ] || DORY_PAUSE=\(Int(DoryEngineShutdownTiming.pollIntervalSeconds * 100))
              [ "$DORY_PAUSE" -le 0 ] || sleep "$(printf '0.%02d' "$DORY_PAUSE")"
            done
          fi
          dory_stop_service dockerd \(DoryEngineShutdownTiming.dockerdPollAttempts) || return 1
          dory_stop_service containerd \(DoryEngineShutdownTiming.servicePollAttempts) || return 1
          dory_stop_service dory-agent \(DoryEngineShutdownTiming.servicePollAttempts) || return 1
          DORY_RECLAIM_PID=$(cat /run/dory-storage-reclaim.pid 2>/dev/null || true)
          case "$DORY_RECLAIM_PID" in
            '') ;;
            *[!0-9]*|0|1) echo 'DORY-SHUTDOWN-FAILED: invalid reclaim PID' >&2; return 1 ;;
            *)
              if kill -0 "$DORY_RECLAIM_PID" 2>/dev/null; then
                kill -TERM "$DORY_RECLAIM_PID" || return 1
                DORY_WAIT=0
                while kill -0 "$DORY_RECLAIM_PID" 2>/dev/null; do
                  [ "$DORY_WAIT" -lt \(DoryEngineShutdownTiming.servicePollAttempts) ] || { echo 'DORY-SHUTDOWN-FAILED: reclaim still running' >&2; return 1; }
                  sleep \(interval); DORY_WAIT=$((DORY_WAIT + 1))
                done
              fi ;;
          esac
          if mountpoint -q /var/lib/docker; then
            timeout -k 1 1 fstrim -v /var/lib/docker || echo 'DORY: shutdown trim skipped' >&2
            sync || return 1
            umount /var/lib/docker || { echo 'DORY-SHUTDOWN-FAILED: data unmount' >&2; return 1; }
          fi
          sync || return 1
          mount -o remount,ro / || { echo 'DORY-SHUTDOWN-FAILED: root remount' >&2; return 1; }
          echo 'DORY-SHUTDOWN-CLEAN: data unmounted, root read-only'
          poweroff -f
        }
        dory_shutdown || { echo 'DORY-SHUTDOWN-FAILED: refusing clean poweroff; host watchdog may force exit' >&2; sync; exit 1; }
        """
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
        return """
        /bin/sh -c '
          child=
          stop_reclaim() { [ -z "$child" ] || { kill -TERM "$child" 2>/dev/null; wait "$child"; }; exit 0; }
          trap stop_reclaim TERM INT
          while true; do
            sleep \(interval) & child=$!; wait "$child"; child=
            if mountpoint -q /var/lib/docker; then
              fstrim -v /var/lib/docker >/var/log/dory-data-trim.log 2>&1 & child=$!; wait "$child"; child=
              cp /var/log/dory-data-trim.log /mnt/dory-logs/data-trim.log 2>/dev/null || true
            fi
          done
        ' & echo $! >/run/dory-storage-reclaim.pid
        """
    }
}

/// Keeps BuildKit cache useful without letting it grow to the full sparse disk capacity.
/// Docker evaluates its normal age and value-aware policies, but Dory lowers the cache ceiling
/// because the engine drive is intended to contain images and volumes as well as build data.
public enum GuestBuildCacheGCCommand {
    public static let defaultKeepStorage = "2GB"

    public static func configureDaemon() -> String {
        let openFiles = GuestContainerCompatibilityCommand.defaultOpenFiles
        let configuration = #"{"live-restore":true,"builder":{"gc":{"enabled":true,"defaultKeepStorage":"\#(defaultKeepStorage)"}},"default-ulimits":{"nofile":{"Name":"nofile","Hard":\#(openFiles),"Soft":\#(openFiles)}}}"#
        return "mkdir -p /etc/docker; printf '%s\\n' '\(configuration)' >/etc/docker/daemon.json"
    }
}
