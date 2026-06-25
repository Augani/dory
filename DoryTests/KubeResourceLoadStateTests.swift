import Foundation
import Testing
@testable import Dory

@MainActor
struct KubeResourceLoadStateTests {
    @Test func failedPodLoadClearsOnlyPodsAndSelection() {
        let store = AppStore()
        store.pods = [Pod(name: "web", namespace: "default", phase: .running, ready: "1/1", restarts: 0, age: "1m")]
        store.deployments = [KubeDeploymentRow(name: "web", namespace: "default", ready: "1/1", upToDate: 1, available: 1, age: "1m", replicas: 1)]
        store.selectedPodID = "default/web"

        store.applyKubeResourceLoad(kind: .pods, result: .failure(.nonZero(1, "namespace not found\n")))

        #expect(store.pods.isEmpty)
        #expect(store.selectedPodID == nil)
        #expect(store.deployments.count == 1)
        #expect(store.actionError == "namespace not found")
    }

    @Test func decodeFailureClearsConfigMapsAndSelection() {
        let store = AppStore()
        store.configMaps = [
            KubeConfigMapRow(name: "web-config", namespace: "default", keys: ["A"], data: ["A": "1"], age: "1m")
        ]
        store.secrets = [
            KubeSecretRow(name: "web-secret", namespace: "default", type: "Opaque", keys: ["token"], data: ["token": "czNjcjN0"], age: "1m")
        ]
        store.selectedConfigMap = store.configMaps[0]

        store.applyKubeResourceLoad(kind: .configMaps, result: .success(Data("not-json".utf8)))

        #expect(store.configMaps.isEmpty)
        #expect(store.selectedConfigMap == nil)
        #expect(store.secrets.count == 1)
        #expect(store.actionError == "Could not read the cluster response.")
    }

    @Test func successfulDeploymentLoadDropsMissingSelection() {
        let store = AppStore()
        store.deployments = [
            KubeDeploymentRow(name: "old", namespace: "default", ready: "1/1", upToDate: 1, available: 1, age: "1m", replicas: 1)
        ]
        store.selectedDeploymentID = "default/old"
        store.actionError = "previous failure"
        let data = Data(#"{"items":[{"metadata":{"name":"new","namespace":"default"},"spec":{"replicas":2},"status":{"readyReplicas":2,"availableReplicas":2,"updatedReplicas":2}}]}"#.utf8)

        store.applyKubeResourceLoad(kind: .deployments, result: .success(data))

        #expect(store.deployments.map(\.id) == ["default/new"])
        #expect(store.selectedDeploymentID == nil)
        #expect(store.actionError == nil)
    }

    @Test func successfulIngressLoadDropsMissingSelection() {
        let store = AppStore()
        store.ingresses = [
            KubeIngressRow(name: "old", namespace: "default", hosts: "old.local", address: "127.0.0.1", paths: "/ -> old", age: "1m")
        ]
        store.selectedIngress = store.ingresses[0]
        let data = Data(#"{"items":[{"metadata":{"name":"new","namespace":"default"},"spec":{"rules":[{"host":"new.local","http":{"paths":[{"path":"/","backend":{"service":{"name":"new"}}}]}}]}}]}"#.utf8)

        store.applyKubeResourceLoad(kind: .ingresses, result: .success(data))

        #expect(store.ingresses.map(\.id) == ["default/new"])
        #expect(store.selectedIngress == nil)
        #expect(store.actionError == nil)
    }

    @Test func openingHeadlessServiceSurfacesActionError() {
        let store = AppStore()
        let service = KubeServiceRow(
            name: "db",
            namespace: "data",
            type: "ClusterIP",
            clusterIP: "None",
            ports: "5432/TCP",
            age: "1m"
        )

        store.openService(service)

        #expect(store.actionError == "Headless services do not expose a cluster IP to open in the browser.")
    }

    @Test func mockResourceReloadUsesMockDataAndNamespaceFilter() async {
        let store = AppStore()
        store.kubeResource = .services
        store.kubeNamespace = "cache"
        store.actionError = "previous failure"

        await store.loadKubeResource()

        #expect(store.kubeServices.map(\.id) == ["cache/redis"])
        #expect(store.actionError == nil)
    }

    @Test func mockInitialLoadUsesSelectedResourceAndNamespace() async {
        let store = AppStore()
        store.kubeResource = .deployments
        store.kubeNamespace = "jobs"

        await store.loadKubernetes()

        #expect(store.kubernetesReachable)
        #expect(store.kubeNamespaces == ["default", "cache", "data", "jobs"])
        #expect(store.deployments.map(\.id) == ["jobs/worker"])
    }
}
