import Foundation

struct KubeExecTarget: Hashable, Codable, Sendable {
    let pod: String
    let namespace: String
    let container: String?
    let kubeconfig: String
}

enum KubeExecCommand {
    static func shell(target: KubeExecTarget) -> String {
        var parts = ["kubectl"]
        if !target.kubeconfig.isEmpty { parts += ["--kubeconfig", target.kubeconfig] }
        parts += ["exec", "-it", target.pod, "-n", target.namespace]
        if let container = target.container, !container.isEmpty { parts += ["-c", container] }
        parts += ["--", "sh", "-c", "'command -v bash >/dev/null && exec bash || exec sh'"]
        return parts.joined(separator: " ")
    }
}
