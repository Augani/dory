import DoryOperations
import DoryRendererWorkerWireContracts
import Foundation

/// A numeric version prefix reported by a stock Linux guest. Distro suffixes such as
/// `6.14.0-29-generic` are deliberately ignored; admission depends on the upstream ABI level,
/// not a vendor's package revision spelling.
public struct DoryGraphicsVersion: Sendable, Equatable, Hashable, Comparable, Codable {
    public let major: UInt32
    public let minor: UInt32
    public let patch: UInt32

    public init(major: UInt32, minor: UInt32, patch: UInt32 = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(reportedValue: String) {
        let numericPrefix = reportedValue.prefix { character in
            character.isNumber || character == "."
        }
        let components = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count),
              components.allSatisfy({ !$0.isEmpty }),
              let major = UInt32(components[0]),
              let minor = UInt32(components[1]),
              let patch = components.count == 3 ? UInt32(components[2]) : 0 else {
            return nil
        }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum DoryGraphicsFenceVerification: String, Sendable, Equatable, Codable {
    case observedAtRuntime
}

/// The managed case remains representable for a future product, but Dory intentionally has no
/// managed-guest admission path in this release. Stock guests qualify through observed behavior.
public enum DoryGraphicsGuestProfile: Sendable, Equatable {
    case managed(
        kernelSHA256: String,
        mesaSHA256: String,
        fence: DoryRendererProducerFenceContract
    )
    case stock(
        minimumKernel: DoryGraphicsVersion,
        minimumMesa: DoryGraphicsVersion,
        fenceVerification: DoryGraphicsFenceVerification
    )

    public static let supportedStock = Self.stock(
        minimumKernel: DoryGraphicsVersion(major: 6, minor: 13),
        minimumMesa: DoryGraphicsVersion(major: 24, minor: 0),
        fenceVerification: .observedAtRuntime
    )
}

public enum DoryGraphicsCompatibilityObservation: String, Sendable, Equatable, Codable {
    case unobserved
    case compatible
    case incompatible
}

public enum DoryGraphicsFenceObservation: String, Sendable, Equatable, Codable {
    case unobserved
    case verified
    case violated
}

public struct DoryGraphicsAdmissionRequest: Sendable, Equatable {
    public let requestedGraphics: DoryGraphicsAccelerationLevel
    public let guest: DoryGuestPlatform
    public let profile: DoryGraphicsGuestProfile

    public init(
        requestedGraphics: DoryGraphicsAccelerationLevel,
        guest: DoryGuestPlatform,
        profile: DoryGraphicsGuestProfile
    ) {
        self.requestedGraphics = requestedGraphics
        self.guest = guest
        self.profile = profile
    }
}

public struct DoryGraphicsAdmissionEvidence: Sendable, Equatable {
    public let signedWorkerIdentityVerified: Bool
    public let signedRuntimeIdentityVerified: Bool
    public let observedKernel: DoryGraphicsVersion?
    public let observedMesa: DoryGraphicsVersion?
    public let venusCapset: DoryGraphicsCompatibilityObservation
    public let fenceOrdering: DoryGraphicsFenceObservation

    public init(
        signedWorkerIdentityVerified: Bool,
        signedRuntimeIdentityVerified: Bool,
        observedKernel: DoryGraphicsVersion? = nil,
        observedMesa: DoryGraphicsVersion? = nil,
        venusCapset: DoryGraphicsCompatibilityObservation = .unobserved,
        fenceOrdering: DoryGraphicsFenceObservation = .unobserved
    ) {
        self.signedWorkerIdentityVerified = signedWorkerIdentityVerified
        self.signedRuntimeIdentityVerified = signedRuntimeIdentityVerified
        self.observedKernel = observedKernel
        self.observedMesa = observedMesa
        self.venusCapset = venusCapset
        self.fenceOrdering = fenceOrdering
    }
}

public struct DoryGraphicsAdmissionHostFacts: Sendable, Equatable {
    public let metalAvailable: Bool
    public let generationArenaAvailable: Bool

    public init(metalAvailable: Bool, generationArenaAvailable: Bool) {
        self.metalAvailable = metalAvailable
        self.generationArenaAvailable = generationArenaAvailable
    }
}

public enum DoryGraphicsAdmissionDowngradeReason: String, Sendable, Equatable, Codable {
    case managedProfileUnavailable
    case unsupportedGuest
    case hostMetalUnavailable
    case guestVRAMArenaUnavailable
    case rendererWorkerIdentityUnverified
    case runtimeIdentityUnverified
    case guestKernelTooOld
    case guestMesaTooOld
    case venusCapsetIncompatible
    case guestKernelLacksPrepareFB

    public var userMessage: String {
        switch self {
        case .managedProfileUnavailable:
            "This Dory release accelerates stock Linux guests only."
        case .unsupportedGuest:
            "Hardware graphics currently requires an ARM64 Linux guest."
        case .hostMetalUnavailable:
            "Metal is unavailable on this host."
        case .guestVRAMArenaUnavailable:
            "The host-visible GPU memory arena is unavailable."
        case .rendererWorkerIdentityUnverified:
            "The signed renderer worker could not be verified."
        case .runtimeIdentityUnverified:
            "The signed VM runtime could not be verified."
        case .guestKernelTooOld:
            "The guest kernel is older than 6.13; install the distro's current HWE kernel."
        case .guestMesaTooOld:
            "The guest Mesa version is too old for Dory's Venus renderer."
        case .venusCapsetIncompatible:
            "The guest and host do not share a compatible Venus protocol."
        case .guestKernelLacksPrepareFB:
            "The guest displayed a frame before its producer fence completed."
        }
    }
}

public enum DoryGraphicsVerificationState: Sendable, Equatable, Hashable, Codable {
    case notRequired
    case provisional
    case verified
    case downgraded(DoryGraphicsAdmissionDowngradeReason)
}

public struct DoryGraphicsAdmissionDecision: Sendable, Equatable {
    public let requestedGraphics: DoryGraphicsAccelerationLevel
    public let admittedGraphics: DoryGraphicsAccelerationLevel
    public let verificationState: DoryGraphicsVerificationState

    public init(
        requestedGraphics: DoryGraphicsAccelerationLevel,
        admittedGraphics: DoryGraphicsAccelerationLevel,
        verificationState: DoryGraphicsVerificationState
    ) {
        self.requestedGraphics = requestedGraphics
        self.admittedGraphics = admittedGraphics
        self.verificationState = verificationState
    }
}

public enum DoryGraphicsAdmission {
    /// Pure admission policy. Unknown guest observations keep a stock launch provisional; explicit
    /// incompatibility always produces a truthful software fallback with a stable reason.
    public static func admit(
        _ request: DoryGraphicsAdmissionRequest,
        evidence: DoryGraphicsAdmissionEvidence,
        hostFacts: DoryGraphicsAdmissionHostFacts
    ) -> DoryGraphicsAdmissionDecision {
        guard request.requestedGraphics == .hardwareAccelerated3D else {
            return DoryGraphicsAdmissionDecision(
                requestedGraphics: request.requestedGraphics,
                admittedGraphics: request.requestedGraphics,
                verificationState: .notRequired
            )
        }

        func downgrade(
            _ reason: DoryGraphicsAdmissionDowngradeReason
        ) -> DoryGraphicsAdmissionDecision {
            DoryGraphicsAdmissionDecision(
                requestedGraphics: request.requestedGraphics,
                admittedGraphics: .software,
                verificationState: .downgraded(reason)
            )
        }

        guard case let .stock(minimumKernel, minimumMesa, fenceVerification) = request.profile else {
            return downgrade(.managedProfileUnavailable)
        }
        guard request.guest.family == .linux, request.guest.architecture == .arm64 else {
            return downgrade(.unsupportedGuest)
        }
        guard hostFacts.metalAvailable else { return downgrade(.hostMetalUnavailable) }
        guard hostFacts.generationArenaAvailable else {
            return downgrade(.guestVRAMArenaUnavailable)
        }
        guard evidence.signedWorkerIdentityVerified else {
            return downgrade(.rendererWorkerIdentityUnverified)
        }
        guard evidence.signedRuntimeIdentityVerified else {
            return downgrade(.runtimeIdentityUnverified)
        }
        if let observedKernel = evidence.observedKernel, observedKernel < minimumKernel {
            return downgrade(.guestKernelTooOld)
        }
        if let observedMesa = evidence.observedMesa, observedMesa < minimumMesa {
            return downgrade(.guestMesaTooOld)
        }
        guard evidence.venusCapset != .incompatible else {
            return downgrade(.venusCapsetIncompatible)
        }
        guard evidence.fenceOrdering != .violated else {
            return downgrade(.guestKernelLacksPrepareFB)
        }

        let verified = fenceVerification == .observedAtRuntime
            && evidence.fenceOrdering == .verified
            && evidence.venusCapset == .compatible
        return DoryGraphicsAdmissionDecision(
            requestedGraphics: request.requestedGraphics,
            admittedGraphics: .hardwareAccelerated3D,
            verificationState: verified ? .verified : .provisional
        )
    }
}
