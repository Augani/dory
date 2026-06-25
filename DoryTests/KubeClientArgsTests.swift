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

    @Test func clusterScopedKindsOmitNamespaceFlags() {
        #expect(KubeClient.args(kind: "namespaces", namespace: nil, kubeconfig: "/k")
            == ["--kubeconfig", "/k", "get", "namespaces", "-o", "json"])
        #expect(KubeClient.args(kind: "nodes", namespace: "default", kubeconfig: "/k")
            == ["--kubeconfig", "/k", "get", "nodes", "-o", "json"])
    }

    @Test func deleteArgsScopeToNamespace() {
        #expect(KubeClient.deleteArgs(kind: "pod", name: "web-1", namespace: "default", kubeconfig: "/k")
            == ["--kubeconfig", "/k", "delete", "pod", "web-1", "-n", "default"])
    }

    @Test func deleteArgsOmitNamespaceForClusterScopedKinds() {
        #expect(KubeClient.deleteArgs(kind: "namespace", name: "preview", namespace: "default", kubeconfig: "/k")
            == ["--kubeconfig", "/k", "delete", "namespace", "preview"])
    }

    @Test func scaleArgsBuildReplicaFlag() {
        #expect(KubeClient.scaleArgs(deployment: "web", namespace: "default", replicas: 3, kubeconfig: "/k")
            == ["--kubeconfig", "/k", "scale", "deployment", "web", "-n", "default", "--replicas=3"])
    }

    @Test func rolloutRestartArgsBuild() {
        #expect(KubeClient.rolloutRestartArgs(deployment: "web", namespace: "default", kubeconfig: "/k")
            == ["--kubeconfig", "/k", "rollout", "restart", "deployment", "web", "-n", "default"])
    }

    @Test func logsArgsBuildTailWithTimestamps() {
        #expect(KubeClient.logsArgs(pod: "web-1", namespace: "default", tail: 200, kubeconfig: "/k")
            == ["--kubeconfig", "/k", "logs", "web-1", "-n", "default", "--tail=200", "--timestamps"])
    }

    @Test func logsArgsBuildFollowWithSinceAndContainer() {
        #expect(KubeClient.logsArgs(
            pod: "web-1",
            namespace: "default",
            container: "app",
            follow: true,
            since: "1s",
            kubeconfig: "/k"
        ) == ["--kubeconfig", "/k", "logs", "web-1", "-n", "default", "-c", "app", "-f", "--since=1s", "--timestamps"])
    }

    @Test func logsArgsCanReadAllContainers() {
        #expect(KubeClient.logsArgs(
            pod: "web-1",
            namespace: "default",
            allContainers: true,
            tail: 50,
            kubeconfig: "/k"
        ) == ["--kubeconfig", "/k", "logs", "web-1", "-n", "default", "--all-containers=true", "--tail=50", "--timestamps"])
    }

    @Test func logsArgsCanOmitKubeconfigAndTimestamps() {
        #expect(KubeClient.logsArgs(pod: "web-1", namespace: "default", timestamps: false, kubeconfig: nil)
            == ["logs", "web-1", "-n", "default"])
    }
}
