import Foundation

/// Produces the machine shape that is safe to print, log, or place in a support bundle.
///
/// Legacy machine configuration can contain arbitrary host/guest environment values. Those values
/// are launch authority, not diagnostics, and an opaque credential cannot be identified reliably
/// from its bytes. The public CLI therefore removes environment containers structurally instead of
/// attempting value-pattern redaction.
public enum DoryMachineDiagnosticsProjection {
    private static let environmentKeys: Set<String> = [
        "env",
        "environment",
        "environment_variables",
        "environmentvariables",
    ]

    public static func supportSafeMachineStatus(_ status: NSDictionary) -> NSDictionary {
        sanitize(status) as? NSDictionary ?? [:]
    }

    public static func supportSafeMachineList(_ statuses: NSArray) -> NSArray {
        sanitize(statuses) as? NSArray ?? []
    }

    private static func sanitize(_ value: Any) -> Any {
        if let dictionary = value as? NSDictionary {
            let result = NSMutableDictionary(capacity: dictionary.count)
            for (rawKey, item) in dictionary {
                guard let key = rawKey as? String else { continue }
                if environmentKeys.contains(key.lowercased()) { continue }
                result[key] = sanitize(item)
            }
            return result.copy() as? NSDictionary ?? [:]
        }
        if let array = value as? NSArray {
            return array.map(sanitize) as NSArray
        }
        return value
    }
}
