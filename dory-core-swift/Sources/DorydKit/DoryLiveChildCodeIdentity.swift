import DoryRendererWorkerWireContracts
import Foundation
import Security

/// Exact signed identity for the one RawHV runner generation selected by the live daemon release.
/// Identifier and Team ID are fixed by the wire-contract leaf; only the final running-slice
/// CodeDirectory hash varies between signed candidates.
struct DoryLiveRunnerCodeIdentity: Equatable, Sendable {
    let codeDirectoryHash: DoryCodeDirectoryHash?
    private let baseRequirement: String

    init(codeDirectoryHash: DoryCodeDirectoryHash) {
        self.codeDirectoryHash = codeDirectoryHash
        baseRequirement = DoryRendererWorkerIdentity.runnerCodeSigningRequirement
    }

    /// The signed application identity used for compatibility launches that predate an exact
    /// renderer release receipt. This is still a Developer-ID/team-bound requirement; it is not a
    /// path or PID trust decision.
    static let signedApplication = DoryLiveRunnerCodeIdentity(
        codeDirectoryHash: nil,
        baseRequirement: DoryRendererWorkerIdentity.runnerCodeSigningRequirement
    )

    /// Virtualization.framework desktops run in their own signed application so macOS attributes
    /// microphone permission to Dory Desktop rather than to the unentitled doryd daemon.
    static let signedVirtualizationApplication = DoryLiveRunnerCodeIdentity(
        codeDirectoryHash: nil,
        baseRequirement: DoryDesktopApplicationCodeIdentity.vmmRequirement
    )

    private init(codeDirectoryHash: DoryCodeDirectoryHash?, baseRequirement: String) {
        self.codeDirectoryHash = codeDirectoryHash
        self.baseRequirement = baseRequirement
    }

    var exactRequirement: String {
        guard let codeDirectoryHash else {
            return baseRequirement
        }
        return baseRequirement + " and cdhash H\"\(codeDirectoryHash.lowercaseHexadecimal)\""
    }
}

enum DoryDesktopApplicationCodeIdentity {
    static let vmmBundleIdentifier = "dory-vmm"
    static let vmmRequirement =
        #"anchor apple generic and identifier "dory-vmm" and certificate leaf[subject.OU] = "864H636QW4""#
}

enum DorySuspendedChildCodeValidationError: Error, Equatable, Sendable {
    case invalidProcessIdentifier(pid_t)
    case requirementCreationFailed(OSStatus)
    case dynamicCodeLookupFailed(OSStatus)
    case dynamicCodeRejected(OSStatus)
}

/// Validation seam used by `HvProcess`. A direct child is stopped before its first instruction;
/// a LaunchServices application is blocked in the daemon-owned descriptor handoff gate. In both
/// cases production validates the live mapped code object before granting runtime authority.
protocol DoryLaunchGatedChildCodeValidating: Sendable {
    func validateLaunchGatedChild(
        pid: pid_t,
        expectedIdentity: DoryLiveRunnerCodeIdentity
    ) throws
}

struct DorySecurityLaunchGatedChildCodeValidator:
    DoryLaunchGatedChildCodeValidating,
    Sendable
{
    func validateLaunchGatedChild(
        pid: pid_t,
        expectedIdentity: DoryLiveRunnerCodeIdentity
    ) throws {
        try DorySecurityDynamicCodeValidator.validate(
            pid: pid,
            requirementText: expectedIdentity.exactRequirement
        )
    }
}

enum DorySecurityDynamicCodeValidator {
    static func validate(pid: pid_t, requirementText: String) throws {
        guard pid > 0 else {
            throw DorySuspendedChildCodeValidationError.invalidProcessIdentifier(pid)
        }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw DorySuspendedChildCodeValidationError.requirementCreationFailed(
                requirementStatus
            )
        }

        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: pid),
        ] as CFDictionary
        var dynamicCode: SecCode?
        let lookupStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &dynamicCode
        )
        guard lookupStatus == errSecSuccess, let dynamicCode else {
            throw DorySuspendedChildCodeValidationError.dynamicCodeLookupFailed(
                lookupStatus
            )
        }

        // This must remain a dynamic SecCode check. Converting it to SecStaticCode or reopening
        // the spawn path would reintroduce the hash-to-exec replacement race this boundary closes.
        let validityStatus = SecCodeCheckValidity(
            dynamicCode,
            SecCSFlags(),
            requirement
        )
        guard validityStatus == errSecSuccess else {
            throw DorySuspendedChildCodeValidationError.dynamicCodeRejected(validityStatus)
        }
    }
}
