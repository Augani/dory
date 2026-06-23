import Testing
@testable import Dory

struct KubeClientArgsTests {
    @Test func allNamespacesUsesAllFlag() {
        #expect(KubeClient.args(kind: "pods", namespace: nil, kubeconfig: "/k")
            == ["--kubeconfig", "/k", "get", "pods", "-A", "-o", "json"])
    }

    @Test func concreteNamespaceScopes() {
        #expect(KubeClient.args(kind: "pods", namespace: "kube-system", kubeconfig: "/k")
            == ["--kubeconfig", "/k", "get", "pods", "-n", "kube-system", "-o", "json"])
    }

    @Test func missingKubeconfigOmitsFlag() {
        #expect(KubeClient.args(kind: "deployments", namespace: nil, kubeconfig: nil)
            == ["get", "deployments", "-A", "-o", "json"])
    }

    @Test func deleteArgsScopeToNamespace() {
        #expect(KubeClient.deleteArgs(kind: "pod", name: "web-1", namespace: "default", kubeconfig: "/k")
            == ["--kubeconfig", "/k", "delete", "pod", "web-1", "-n", "default"])
    }
}
