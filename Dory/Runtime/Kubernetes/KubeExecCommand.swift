import Foundation

nonisolated struct KubeExecTarget: Hashable, Codable, Sendable {
    let pod: String
    let namespace: String
    let container: String?
    let kubeconfig: String
}

nonisolated enum KubeExecCommand {
    static func shell(target: KubeExecTarget) -> String {
        var parts = ["kubectl"]
        if !target.kubeconfig.isEmpty { parts += ["--kubeconfig", shellQuote(target.kubeconfig)] }
        parts += ["exec", "-it", shellQuote(target.pod), "-n", shellQuote(target.namespace)]
        if let container = target.container, !container.isEmpty { parts += ["-c", shellQuote(container)] }
        parts += ["--", "sh", "-c", "'command -v bash >/dev/null && exec bash || exec sh'"]
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+=,-")
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
