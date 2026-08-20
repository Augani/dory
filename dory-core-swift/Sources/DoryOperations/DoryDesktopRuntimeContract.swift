import Foundation

/// Stable host/guest contract for choosing the desktop virtualization implementation.
///
/// `automatic` is the product default: doryd prefers Dory's accelerated raw-Hypervisor runtime
/// when it is available, while retaining Virtualization.framework as the selectable compatibility
/// runtime. The explicit values are useful for qualification and for recovering a machine on a
/// host whose accelerated graphics stack is temporarily unavailable.
public enum DoryDesktopVMMPreference: String, CaseIterable, Sendable, Codable {
    public static let environmentKey = "DORY_DESKTOP_VMM"

    case automatic = "auto"
    case accelerated
    case compatible

    public init(environment: [String: String]) throws {
        let raw = environment[Self.environmentKey] ?? Self.automatic.rawValue
        guard let value = Self(rawValue: raw) else {
            throw DoryDesktopRuntimeContractError.invalidValue(
                key: Self.environmentKey,
                value: raw,
                allowed: Self.allCases.map(\.rawValue)
            )
        }
        self = value
    }
}

/// Requested graphics behavior for Dory's raw-Hypervisor desktop runtime.
///
/// The default first attempts the combined VirGL2 + Venus backend: VirGL accelerates the desktop
/// compositor while Venus gives Vulkan applications a real Apple-GPU path. Hosts without a
/// qualified Venus renderer fall back to classic VirGL, then to virtio-gpu 2D, so graphics
/// acceleration cannot make the Linux desktop unbootable.
public enum DoryDesktopGraphicsPreference: String, CaseIterable, Sendable, Codable {
    public static let environmentKey = "DORY_DESKTOP_GRAPHICS"
    public static let legacyClassicOnlyEnvironmentKey = "DORY_VIRGL_CLASSIC_ONLY"

    case automatic = "auto"
    case virgl
    case virglVenus = "virgl-venus"
    case software

    public init(environment: [String: String]) throws {
        if let raw = environment[Self.environmentKey] {
            guard let value = Self(rawValue: raw) else {
                throw DoryDesktopRuntimeContractError.invalidValue(
                    key: Self.environmentKey,
                    value: raw,
                    allowed: Self.allCases.map(\.rawValue)
                )
            }
            self = value
            return
        }

        // Preserve machines created while the experimental toggle was the only public contract.
        switch environment[Self.legacyClassicOnlyEnvironmentKey] {
        case "1": self = .virgl
        case "0": self = .virglVenus
        default: self = .automatic
        }
    }
}

/// The graphics backend actually attached to a running raw-Hypervisor desktop.
public enum DoryDesktopGraphicsBackend: String, Sendable, Codable {
    case virgl
    case virglVenus = "virgl-venus"
    case software

    public var isAccelerated: Bool { self != .software }

    /// Kernel token read by the versioned guest integration scripts.
    public var kernelArgument: String { "dory.graphics=\(rawValue)" }

    /// Compatibility token for desktop images predating `dory.graphics`.
    public var legacyKernelArgument: String? {
        isAccelerated ? "dory.gpu=venus" : nil
    }

    public var displayName: String {
        switch self {
        case .virgl: "VirGL2"
        case .virglVenus: "VirGL2 + Venus"
        case .software: "software"
        }
    }
}

public enum DoryDesktopRuntimeContractError: Error, Equatable, LocalizedError {
    case invalidValue(key: String, value: String, allowed: [String])

    public var errorDescription: String? {
        switch self {
        case let .invalidValue(key, value, allowed):
            "Invalid \(key)=\(value); expected one of \(allowed.joined(separator: ", "))"
        }
    }
}
