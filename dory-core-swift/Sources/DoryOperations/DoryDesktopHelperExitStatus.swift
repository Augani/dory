/// Stable process-status contract between Dory's raw-Hypervisor desktop helper and its daemon.
///
/// A renderer-candidate failure is intentionally distinct from an ordinary desktop failure so the
/// daemon can suppress only the exact admitted renderer release after a worker crash, Metal device
/// loss, or renderer-fence/quiescence failure. Guest boot, guest readiness, configuration, and
/// handoff failures remain `generalFailure` and must never poison a renderer candidate.
public enum DoryDesktopHelperExitStatus: Int32, Sendable {
    case generalFailure = 1
    case rendererCandidateFailure = 86
}
