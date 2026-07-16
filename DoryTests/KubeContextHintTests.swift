import Testing
@testable import Dory

struct KubeContextHintTests {
    @Test func mergedSnippetIsContextOnly() {
        let snippet = KubeContextHint.snippet(kubeconfigPath: "/Users/x/.kube/dory-config", merged: true)
        #expect(snippet == "kubectl --context dory get pods -A")
    }

    @Test func sideFileSnippetKeepsExportAndPath() {
        let snippet = KubeContextHint.snippet(kubeconfigPath: "/Users/x/.kube/dory-config", merged: false)
        #expect(snippet.contains("export KUBECONFIG=/Users/x/.kube/dory-config"))
        #expect(snippet.contains("kubectl --context dory get pods -A"))
    }
}
