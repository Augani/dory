import DoryRendererWorkerWireContracts
import Foundation
import Security

/// Exact signed identity for the one RawHV runner generation selected by the live daemon release.
/// Identifier and Team ID are fixed by the wire-contract leaf; only the final running-slice
/// CodeDirectory hash varies between signed candidates.
struct DoryLiveRunnerCodeIdentity: Equatable, Sendable {
    let codeDirectoryHash: DoryCodeDirectoryHash

    init(codeDirectoryHash: DoryCodeDirectoryHash) {
        self.codeDirectoryHash = codeDirectoryHash
    }

    var exactRequirement: String {
        DoryRendererWorkerIdentity.exactRunnerCodeSigningRequirement(
            codeDirectoryHash: codeDirectoryHash
        )
    }
}

enum DorySuspendedChildCodeValidationError: Error, Equatable, Sendable {
    case invalidProcessIdentifier(pid_t)
    case requirementCreationFailed(OSStatus)
    case dynamicCodeLookupFailed(OSStatus)
    case dynamicCodeRejected(OSStatus)
}

/// Validation seam used by `HvProcess`. Production resolves the dynamic code object for the
/// stack-owned suspended PID; tests inject a recorder so lifecycle and cleanup races are
/// deterministic without weakening the production requirement.
protocol DorySuspendedChildCodeValidating: Sendable {
    func validateSuspendedChild(
        pid: pid_t,
        expectedIdentity: DoryLiveRunnerCodeIdentity
    ) throws
}

struct DorySecuritySuspendedChildCodeValidator:
    DorySuspendedChildCodeValidating,
    Sendable
{
    func validateSuspendedChild(
        pid: pid_t,
        expectedIdentity: DoryLiveRunnerCodeIdentity
    ) throws {
        guard pid > 0 else {
            throw DorySuspendedChildCodeValidationError.invalidProcessIdentifier(pid)
        }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            expectedIdentity.exactRequirement as CFString,
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
