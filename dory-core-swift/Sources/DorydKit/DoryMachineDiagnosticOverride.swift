import Foundation

/// Closed, non-secret diagnostic overrides honored by the compatibility raw-HV runtime.
///
/// Status and support evidence expose only these semantic identifiers. The corresponding values
/// may contain host paths and are never projected outside the daemon.
public enum DoryMachineDiagnosticOverride:
    String, Codable, Sendable, CaseIterable, Comparable, Hashable
{
    case gpuResourceTracing = "gpu-resource-tracing"

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func configured(
        in environment: [String: String]
    ) -> [Self] {
        allCases.filter { override in
            switch override {
            case .gpuResourceTracing:
                return environment["DORY_GPU_TRACE_RESOURCES"] == "1"
            }
        }.sorted()
    }
}
