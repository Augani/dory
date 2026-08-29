import DoryOperations
import Foundation

enum DesktopRendererRuntimeFailureKind: String, Equatable, Sendable {
    case worker = "renderer-worker"
    case metalDevice = "metal-device"
    case gpuQuiescence = "gpu-quiescence"
}

/// Candidate-scoped failure emitted only after hardware acceleration admitted an exact renderer
/// worker. The type is the local classification boundary consumed by `main.swift`; ordinary guest
/// and readiness errors deliberately never become this type.
struct DesktopRendererRuntimeFailure: Error, Equatable, Sendable, CustomStringConvertible {
    let kind: DesktopRendererRuntimeFailureKind
    let reason: String

    var description: String { "\(kind.rawValue): \(reason)" }
}

/// Worker and Metal callbacks arrive on different queues. Preserve the first candidate-scoped
/// failure so a secondary teardown fault cannot replace the cause that actually stopped the VM.
final class DesktopRendererRuntimeFailureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: DesktopRendererRuntimeFailure?

    func record(kind: DesktopRendererRuntimeFailureKind, reason: String) {
        lock.withLock {
            guard storedFailure == nil else { return }
            storedFailure = DesktopRendererRuntimeFailure(kind: kind, reason: reason)
        }
    }

    var failure: DesktopRendererRuntimeFailure? {
        lock.withLock { storedFailure }
    }
}

func desktopHelperExitStatus(for error: any Error) -> DoryDesktopHelperExitStatus {
    error is DesktopRendererRuntimeFailure
        ? .rendererCandidateFailure
        : .generalFailure
}

func desktopGPUShutdownFailure(
    _ result: DesktopGPUShutdownBoundaryResult,
    rendererFailureLatch: DesktopRendererRuntimeFailureLatch?
) -> (any Error)? {
    guard let genericFailure = result.failure else { return nil }
    guard let rendererFailureLatch else { return genericFailure }
    rendererFailureLatch.record(
        kind: .gpuQuiescence,
        reason: result.logDescription
    )
    return rendererFailureLatch.failure ?? genericFailure
}
