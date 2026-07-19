import Darwin
import Foundation
import Security

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
}
