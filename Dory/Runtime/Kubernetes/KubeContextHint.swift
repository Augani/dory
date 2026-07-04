import Foundation

enum KubeContextHint {
    static func snippet(kubeconfigPath: String) -> String {
        """
        export KUBECONFIG=\(kubeconfigPath)
        kubectl --context \(KubernetesProvisioner.contextName) get pods -A
        """
    }
}
