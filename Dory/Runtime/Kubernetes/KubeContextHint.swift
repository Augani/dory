import Foundation

enum KubeContextHint {
    /// `merged` mirrors the enable-time merge condition (host kubectl present): the context then
    /// lives in ~/.kube/config and no KUBECONFIG export is needed. Without kubectl the side file
    /// is the only access path, so the hint keeps the export line.
    static func snippet(kubeconfigPath: String, merged: Bool) -> String {
        let command = "kubectl --context \(KubernetesProvisioner.contextName) get pods -A"
        guard !merged else { return command }
        return """
        export KUBECONFIG=\(kubeconfigPath)
        \(command)
        """
    }
}
