import CoreFoundation
import DoryOperations
import Foundation

public enum DoryMachineSandboxPolicyWriteAuthorityError:
    Error, Sendable, Equatable, CustomStringConvertible
{
    case invalidField(String)

    public var description: String {
        switch self {
        case let .invalidField(field):
            "invalid sandbox policy field: \(field)"
        }
    }
}

/// Exact public write boundary for non-secret sandbox lifecycle and credential-grant intent.
///
/// Command environments, host paths, network destinations, and secret values are deliberately
/// excluded. They remain operation-scoped inputs and never become machine metadata.
public enum DoryMachineSandboxPolicyWriteAuthority {
    public static let xpcKey = "sandboxPolicy"

    public static func consumeCLIArguments(
        _ arguments: inout [String]
    ) throws -> DoryVMSandboxPolicy? {
        let requested = takeFlag("--sandbox", from: &arguments)
        let expiration = try takeOption("--sandbox-expires-at", from: &arguments)
        let rawAccess = try takeOption("--sandbox-ssh-agent", from: &arguments)
        let rawProfile = try takeOption("--sandbox-profile", from: &arguments)
        let rawTools = try takeOptions("--sandbox-tool", from: &arguments)
        let baseline = try takeOption("--sandbox-baseline", from: &arguments)

        let hasPolicyFields = expiration != nil || rawAccess != nil || rawProfile != nil
            || !rawTools.isEmpty || baseline != nil
        guard requested || !hasPolicyFields else {
            throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField("--sandbox")
        }
        guard requested else { return nil }

        let expiresAt: UInt64?
        if let expiration {
            guard let value = UInt64(expiration), value > 0 else {
                throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(
                    "--sandbox-expires-at"
                )
            }
            expiresAt = value
        } else {
            expiresAt = nil
        }
        let access: DoryVMSandboxSSHAgentAccess
        if let rawAccess {
            guard let value = DoryVMSandboxSSHAgentAccess(rawValue: rawAccess) else {
                throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(
                    "--sandbox-ssh-agent"
                )
            }
            access = value
        } else {
            access = .denied
        }
        let profile: DoryVMSandboxProfile
        if let rawProfile {
            guard let value = DoryVMSandboxProfile(rawValue: rawProfile) else {
                throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(
                    "--sandbox-profile"
                )
            }
            profile = value
        } else {
            profile = .standard
        }
        let tools = try rawTools.map { raw -> DoryVMSandboxTool in
            guard let tool = DoryVMSandboxTool(rawValue: raw) else {
                throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(
                    "--sandbox-tool"
                )
            }
            return tool
        }.sorted()
        let policy = DoryVMSandboxPolicy(
            expiresAtUnixSeconds: expiresAt,
            sshAgentAccess: access,
            profile: profile,
            tools: tools,
            baselineSnapshotID: baseline
        )
        guard policy.isValidForPersistence else {
            throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(xpcKey)
        }
        return policy
    }

    public static func decodeXPC(
        _ dictionary: NSDictionary
    ) throws -> DoryVMSandboxPolicy? {
        guard let raw = dictionary[xpcKey] else { return nil }
        guard let policy = normalizedDictionary(raw),
              hasExactlyRequiredAndOptionalKeys(policy),
              let schema = exactUInt64(policy["schemaVersion"]),
              schema == UInt64(DoryVMSandboxPolicy.currentSchemaVersion),
              let rawAccess = policy["sshAgentAccess"] as? String,
              let access = DoryVMSandboxSSHAgentAccess(rawValue: rawAccess),
              let rawProfile = policy["profile"] as? String,
              let profile = DoryVMSandboxProfile(rawValue: rawProfile),
              let rawTools = policy["tools"] as? NSArray else {
            throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(xpcKey)
        }
        let tools = try rawTools.map { raw -> DoryVMSandboxTool in
            guard let value = raw as? String,
                  let tool = DoryVMSandboxTool(rawValue: value) else {
                throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(
                    "\(xpcKey).tools"
                )
            }
            return tool
        }
        let expiresAt: UInt64?
        if let rawExpiration = policy["expiresAtUnixSeconds"] {
            guard let value = exactUInt64(rawExpiration), value > 0 else {
                throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(
                    "\(xpcKey).expiresAtUnixSeconds"
                )
            }
            expiresAt = value
        } else {
            expiresAt = nil
        }
        let baseline: String?
        if let rawBaseline = policy["baselineSnapshotID"] {
            guard let value = rawBaseline as? String else {
                throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(
                    "\(xpcKey).baselineSnapshotID"
                )
            }
            baseline = value
        } else {
            baseline = nil
        }
        let result = DoryVMSandboxPolicy(
            schemaVersion: UInt16(schema),
            expiresAtUnixSeconds: expiresAt,
            sshAgentAccess: access,
            profile: profile,
            tools: tools,
            baselineSnapshotID: baseline
        )
        guard result.isValidForPersistence else {
            throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(xpcKey)
        }
        return result
    }

    public static func xpcDictionary(
        _ policy: DoryVMSandboxPolicy
    ) throws -> NSDictionary {
        guard policy.isValidForPersistence else {
            throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(xpcKey)
        }
        var result: [String: Any] = [
            "schemaVersion": policy.schemaVersion,
            "sshAgentAccess": policy.sshAgentAccess.rawValue,
            "profile": policy.profile.rawValue,
            "tools": policy.tools.map(\.rawValue),
        ]
        if let expiresAtUnixSeconds = policy.expiresAtUnixSeconds {
            result["expiresAtUnixSeconds"] = expiresAtUnixSeconds
        }
        if let baselineSnapshotID = policy.baselineSnapshotID {
            result["baselineSnapshotID"] = baselineSnapshotID
        }
        return result as NSDictionary
    }

    public static func legacyEnvironment(
        for policy: DoryVMSandboxPolicy
    ) throws -> [String: String] {
        guard policy.isValidForPersistence else {
            throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(xpcKey)
        }
        var environment = [
            DoryVMSandboxPolicy.legacyMarkerEnvironmentKey: "1",
            DoryVMSandboxPolicy.legacyExpirationEnvironmentKey:
                policy.expiresAtUnixSeconds.map(String.init) ?? "0",
            DoryVMSandboxPolicy.legacySSHAgentEnvironmentKey:
                policy.sshAgentAccess == .granted ? "1" : "0",
        ]
        if policy.profile == .agentReady {
            environment[DoryVMSandboxPolicy.legacyProfileEnvironmentKey] =
                policy.profile.rawValue
            environment[DoryVMSandboxPolicy.legacyToolsEnvironmentKey] =
                policy.tools.map(\.rawValue).joined(separator: ",")
            environment[DoryVMSandboxPolicy.legacyBaselineEnvironmentKey] =
                policy.baselineSnapshotID
        }
        return environment
    }

    private static func hasExactlyRequiredAndOptionalKeys(
        _ dictionary: [String: Any]
    ) -> Bool {
        let required: Set<String> = [
            "schemaVersion", "sshAgentAccess", "profile", "tools",
        ]
        let allowed = required.union(["expiresAtUnixSeconds", "baselineSnapshotID"])
        let actual = Set(dictionary.keys)
        return required.isSubset(of: actual) && actual.isSubset(of: allowed)
    }

    private static func normalizedDictionary(_ raw: Any) -> [String: Any]? {
        if let value = raw as? [String: Any] { return value }
        guard let value = raw as? NSDictionary,
              let keys = value.allKeys as? [String] else { return nil }
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            value[key].map { (key, $0) }
        })
    }

    private static func exactUInt64(_ raw: Any?) -> UInt64? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue <= Double(UInt64.max) else { return nil }
        let value = number.uint64Value
        return number.doubleValue == Double(value) ? value : nil
    }

    private static func takeFlag(_ option: String, from arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: option) else { return false }
        arguments.remove(at: index)
        return true
    }

    private static func takeOption(
        _ option: String,
        from arguments: inout [String]
    ) throws -> String? {
        guard let index = arguments.firstIndex(of: option) else { return nil }
        guard index + 1 < arguments.count else {
            throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(option)
        }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        guard !arguments.contains(option) else {
            throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(option)
        }
        return value
    }

    private static func takeOptions(
        _ option: String,
        from arguments: inout [String]
    ) throws -> [String] {
        var result: [String] = []
        while let index = arguments.firstIndex(of: option) {
            guard index + 1 < arguments.count else {
                throw DoryMachineSandboxPolicyWriteAuthorityError.invalidField(option)
            }
            result.append(arguments[index + 1])
            arguments.removeSubrange(index...(index + 1))
        }
        return result
    }
}
