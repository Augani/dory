import Testing
@testable import Dory

struct KubeExecCommandTests {
    @Test func execWithContainerAndKubeconfig() {
        let target = KubeExecTarget(pod: "web-1", namespace: "default", container: "app", kubeconfig: "/k")
        #expect(KubeExecCommand.shell(target: target)
            == "kubectl --kubeconfig /k exec -it web-1 -n default -c app -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    @Test func execWithoutContainer() {
        let target = KubeExecTarget(pod: "web-1", namespace: "default", container: nil, kubeconfig: "/k")
        #expect(KubeExecCommand.shell(target: target)
            == "kubectl --kubeconfig /k exec -it web-1 -n default -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    @Test func execWithEmptyKubeconfigOmitsFlag() {
        let target = KubeExecTarget(pod: "web-1", namespace: "default", container: nil, kubeconfig: "")
        #expect(KubeExecCommand.shell(target: target)
            == "kubectl exec -it web-1 -n default -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    @Test func execQuotesShellSensitiveValues() {
        let target = KubeExecTarget(
            pod: "web pod",
            namespace: "team space",
            container: "app'sidecar",
            kubeconfig: "/Users/Augustus Otu/.kube/dory config"
        )
        #expect(KubeExecCommand.shell(target: target)
            == #"kubectl --kubeconfig '/Users/Augustus Otu/.kube/dory config' exec -it 'web pod' -n 'team space' -c 'app'\''sidecar' -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'"#)
    }
}
