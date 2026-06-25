import Testing
@testable import Dory

struct KubeResourceKindTests {
    @Test func apiKindMatchesKubectl() {
        #expect(KubeResourceKind.pods.apiKind == "pods")
        #expect(KubeResourceKind.deployments.apiKind == "deployments")
        #expect(KubeResourceKind.services.apiKind == "services")
        #expect(KubeResourceKind.configMaps.apiKind == "configmaps")
        #expect(KubeResourceKind.secrets.apiKind == "secrets")
        #expect(KubeResourceKind.ingresses.apiKind == "ingress")
        #expect(KubeResourceKind.configMaps.deleteKind == "configmap")
        #expect(KubeResourceKind.ingresses.deleteKind == "ingress")
    }
    @Test func labelsAreTitleCased() {
        #expect(KubeResourceKind.pods.label == "Pods")
        #expect(KubeResourceKind.services.label == "Services")
        #expect(KubeResourceKind.configMaps.label == "ConfigMaps")
        #expect(KubeResourceKind.ingresses.label == "Ingress")
    }
}
