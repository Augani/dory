import Darwin
import DoryRendererWorkerWireContracts
import Foundation
import Security

public enum DoryVMDisplayPeerRole: Equatable, Sendable {
    case application
    case runner
    case development
}

/// Authentication policy for doryd's user-scoped Mach service.
///
/// A production-signed daemon accepts only the signed Dory app and dorydctl from Dory's team. An
/// ad-hoc developer/test build cannot present a stable team identity, so it remains same-UID only.
/// A daemon carrying an unexpected non-empty team identity fails closed.
public enum DorydXPCSecurity {
    public static let productionTeamID = "864H636QW4"
    public static let productionClientRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(productionTeamID)\" "
        + "and (identifier \"com.pythonxi.Dory\" or identifier \"dorydctl\")"
    public static let productionDaemonRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(productionTeamID)\" "
        + "and identifier \"doryd\""
    public static let productionDisplayApplicationRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(productionTeamID)\" "
        + "and identifier \"com.pythonxi.Dory\""

    public static func acceptsConnection(
        clientUID: uid_t,
        daemonUID: uid_t,
        daemonTeamID: String?
    ) -> Bool {
        guard clientUID == daemonUID else { return false }
        guard let daemonTeamID, !daemonTeamID.isEmpty else {
            return true
        }
        return daemonTeamID == productionTeamID
    }

    public static func configureIncomingConnection(
        _ connection: NSXPCConnection,
        daemonUID: uid_t = geteuid(),
        daemonTeamID: String? = currentTeamIdentifier()
    ) -> Bool {
        guard acceptsConnection(
            clientUID: connection.effectiveUserIdentifier,
            daemonUID: daemonUID,
            daemonTeamID: daemonTeamID
        ) else {
            return false
        }
        if daemonTeamID == productionTeamID {
            connection.setCodeSigningRequirement(productionClientRequirement)
        }
        return true
    }

    public static func displayPeerRole(
        clientUID: uid_t,
        daemonUID: uid_t,
        daemonTeamID: String?,
        satisfiesApplicationRequirement: Bool,
        satisfiesRunnerRequirement: Bool
    ) -> DoryVMDisplayPeerRole? {
        guard clientUID == daemonUID else { return nil }
        guard let daemonTeamID, !daemonTeamID.isEmpty else {
            return .development
        }
        guard daemonTeamID == productionTeamID,
              satisfiesApplicationRequirement != satisfiesRunnerRequirement else {
            return nil
        }
        return satisfiesApplicationRequirement ? .application : .runner
    }

    public static func configureDisplayConnection(
        _ connection: NSXPCConnection,
        daemonUID: uid_t = geteuid(),
        daemonTeamID: String? = currentTeamIdentifier()
    ) -> DoryVMDisplayPeerRole? {
        let isProduction = daemonTeamID == productionTeamID
        let applicationMatches = isProduction && process(
            connection.processIdentifier,
            satisfies: productionDisplayApplicationRequirement
        )
        let runnerMatches = isProduction && process(
            connection.processIdentifier,
            satisfies: DoryRendererWorkerIdentity.runnerCodeSigningRequirement
        )
        guard let role = displayPeerRole(
            clientUID: connection.effectiveUserIdentifier,
            daemonUID: daemonUID,
            daemonTeamID: daemonTeamID,
            satisfiesApplicationRequirement: applicationMatches,
            satisfiesRunnerRequirement: runnerMatches
        ) else {
            return nil
        }
        switch role {
        case .application:
            connection.setCodeSigningRequirement(productionDisplayApplicationRequirement)
        case .runner:
            connection.setCodeSigningRequirement(
                DoryRendererWorkerIdentity.runnerCodeSigningRequirement
            )
        case .development:
            break
        }
        return role
    }

    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var signingInformation: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &signingInformation) == errSecSuccess,
              let values = signingInformation as? [CFString: Any],
              let team = values[kSecCodeInfoTeamIdentifier] as? String,
              !team.isEmpty else {
            return nil
        }
        return team
    }

    private static func process(_ pid: pid_t, satisfies requirementText: String) -> Bool {
        guard pid > 0,
              let requirement = try? securityRequirement(requirementText) else {
            return false
        }
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: pid),
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &code
        ) == errSecSuccess, let code else {
            return false
        }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }

    private static func securityRequirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            text as CFString,
            SecCSFlags(),
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return requirement
    }

    public static func isProductionDaemonIdentity(
        teamIdentifier: String?,
        signingIdentifier: String?
    ) -> Bool {
        teamIdentifier == productionTeamID && signingIdentifier == "doryd"
    }

    /// Checks the complete signed daemon requirement, not only team membership. This prevents a
    /// different binary signed by Dory's team from constructing production VM trust authority.
    public static func currentProcessSatisfiesProductionDaemonRequirement() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            productionDaemonRequirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement else {
            return false
        }
        return SecCodeCheckValidity(
            code,
            SecCSFlags(),
            requirement
        ) == errSecSuccess
    }
}
