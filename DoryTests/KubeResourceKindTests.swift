import Testing
@testable import Dory

struct KubeResourceKindTests {
    @Test func apiKindMatchesKubectl() {
        #expect(KubeResourceKind.pods.apiKind == "pods")
        #expect(KubeResourceKind.deployments.apiKind == "deployments")
        #expect(KubeResourceKind.services.apiKind == "services")
    }
    @Test func labelsAreTitleCased() {
        #expect(KubeResourceKind.pods.label == "Pods")
        #expect(KubeResourceKind.services.label == "Services")
    }
}
