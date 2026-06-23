import Foundation

enum KubeContextHint {
    static func snippet(kubeconfigPath: String) -> String {
        """
        export KUBECONFIG=\(kubeconfigPath)
        kubectl get pods -A
        """
    }
}
