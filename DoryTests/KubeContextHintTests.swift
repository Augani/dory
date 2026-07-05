import Testing
@testable import Dory

struct KubeContextHintTests {
    @Test func snippetContainsExportAndPath() {
        let snippet = KubeContextHint.snippet(kubeconfigPath: "/Users/x/.kube/dory-config")
        #expect(snippet.contains("export KUBECONFIG=/Users/x/.kube/dory-config"))
        #expect(snippet.contains("kubectl --context dory get pods -A"))
    }
}
