/// Generates the guest-side memory reclaim daemons embedded in the engine boot script.
///
/// The default page-cache policy is deliberately kept separate from the experimental Senpai
/// policy. Senpai must be explicitly enabled by the engine and its PSI fallback must fail closed:
/// inability to prove that guest memory pressure is low is never permission to reclaim.
public enum GuestMemoryReclaimBootCommand {
    private static let quietGate = "set -- $(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t,$5; exit}' /proc/stat); total=${1:-0}; idle=${2:-0}; quiet=0; if [ ${prev_total:-0} -gt 0 ]; then dt=$((total-prev_total)); di=$((idle-prev_idle)); [ $dt -gt 0 ] && [ $((100 - (di * 100 / dt))) -le 8 ] && quiet=1; fi; prev_total=$total; prev_idle=$idle; running=$(docker -H unix:///var/run/docker.sock ps -q 2>/dev/null | wc -l | tr -d ' '); if [ ${running:-0} -gt 0 ] && [ $quiet -eq 1 ]; then quiet_running_ticks=$((quiet_running_ticks+1)); else quiet_running_ticks=0; fi"

    /// Emits the idle-reclaim daemon. `experimentalSenpai` must only be true for the explicit
    /// `DORY_ENGINE_RECLAIM_MODE=senpai` opt-in; false preserves the established drop-caches path.
    public static func idleLoop(
        experimentalSenpai: Bool,
        pressureMemoryPath: String = "/proc/pressure/memory"
    ) -> String {
        let dropCaches = "( prev_total=0; prev_idle=0; quiet_running_ticks=0; while true; do sleep 5; \(quietGate); [ $quiet_running_ticks -ge 2 ] || continue; c=$(awk '/^Cached:/{print $2; exit}' /proc/meminfo); [ ${c:-0} -gt 327680 ] && echo 1 > /proc/sys/vm/drop_caches 2>/dev/null; done ) & true"
        guard experimentalSenpai else { return dropCaches }

        let setup = "[ -w /sys/kernel/mm/lru_gen/min_ttl_ms ] && echo 2000 > /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null; if [ -d /sys/module/damon_reclaim/parameters ]; then echo 2000000 > /sys/module/damon_reclaim/parameters/min_age 2>/dev/null; echo Y > /sys/module/damon_reclaim/parameters/enabled 2>/dev/null; damon=1; else damon=0; fi"
        let psiGate = experimentalSenpaiPSIAllowsReclaimCondition(pressureMemoryPath: pressureMemoryPath)
        let cgroupReclaim = "for r in $(find /sys/fs/cgroup -maxdepth 4 -name memory.reclaim 2>/dev/null | grep -Ei 'docker|containerd|kubepods|system.slice'); do echo 67108864 > \"$r\" 2>/dev/null; done"

        return "( \(setup); prev_total=0; prev_idle=0; quiet_running_ticks=0; while true; do sleep 5; [ ${damon:-0} -eq 1 ] && continue; \(quietGate); [ $quiet_running_ticks -ge 2 ] || continue; \(psiGate) || continue; \(cgroupReclaim); done ) & true"
    }

    /// A shell condition that succeeds only when a well-formed PSI `some avg10` value exists and
    /// is below the experimental reclaim threshold. Missing, unreadable, or malformed input makes
    /// the condition fail, so callers can append `|| continue` and retain the working set.
    public static func experimentalSenpaiPSIAllowsReclaimCondition(
        pressureMemoryPath: String = "/proc/pressure/memory"
    ) -> String {
        let path = shellQuote(pressureMemoryPath)
        let extract = "psi=$(awk '/^some[[:space:]]/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){split($i,a,\"=\"); if(a[2] ~ /^[0-9]+([.][0-9]+)?$/){print a[2]; found=1}; exit}} END{if(!found) exit 1}' \(path) 2>/dev/null)"
        return "\(extract) && awk -v p=\"$psi\" 'BEGIN{exit !(p+0 < 1.0)}'"
    }

    /// Emits the host-pressure listener. It remains a no-op unless experimental Senpai mode was
    /// explicitly selected by the engine.
    public static func hostPressureListener(experimentalSenpai: Bool) -> String {
        guard experimentalSenpai else { return "true" }
        return "( while true; do nc -l -p 2378 >/dev/null 2>&1; sync; echo 1 > /proc/sys/vm/drop_caches 2>/dev/null; for r in $(find /sys/fs/cgroup -maxdepth 4 -name memory.reclaim 2>/dev/null | grep -Ei 'docker|containerd|kubepods|system.slice'); do echo 268435456 > \"$r\" 2>/dev/null; done; done ) & true"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
