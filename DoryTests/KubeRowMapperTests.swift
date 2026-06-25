import Foundation
import Testing
@testable import Dory

struct KubeRowMapperTests {
    private func decode<T: Decodable>(_ json: String, as type: T.Type) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func deploymentReadyRatio() {
        let list = decode(#"{"items":[{"metadata":{"name":"web","namespace":"default","creationTimestamp":null},"spec":{"replicas":3},"status":{"readyReplicas":2,"availableReplicas":2,"updatedReplicas":3}}]}"#, as: KubeDeploymentList.self)
        let rows = KubeRowMapper.deployments(list)
        #expect(rows.count == 1)
        #expect(rows[0].name == "web")
        #expect(rows[0].ready == "2/3")
        #expect(rows[0].available == 2)
        #expect(rows[0].replicas == 3)
    }

    @Test func servicesIncludeHeadlessResources() {
        let list = decode(#"{"items":[{"metadata":{"name":"db","namespace":"data"},"spec":{"type":"ClusterIP","clusterIP":"None","ports":[{"port":5432,"protocol":"TCP"}]}},{"metadata":{"name":"web","namespace":"default"},"spec":{"type":"ClusterIP","clusterIP":"10.0.0.5","ports":[{"port":80,"protocol":"TCP"},{"port":443,"protocol":"TCP"}]}}]}"#, as: KubeServiceList.self)
        let rows = KubeRowMapper.services(list)
        #expect(rows.map(\.name) == ["db", "web"])
        #expect(rows[0].clusterIP == "None")
        #expect(rows[0].isHeadless)
        #expect(rows[1].ports == "80/TCP, 443/TCP")
    }

    @Test func podsReproduceExistingMapping() {
        let list = decode(#"{"items":[{"metadata":{"name":"web-1","namespace":"default"},"status":{"phase":"Running","containerStatuses":[{"name":"app","ready":true,"restartCount":2}]}}]}"#, as: KubePodList.self)
        let rows = KubeRowMapper.pods(list)
        #expect(rows.count == 1)
        #expect(rows[0].id == "default/web-1")
        #expect(rows[0].ready == "1/1")
        #expect(rows[0].restarts == 2)
        #expect(rows[0].phase == .running)
        #expect(rows[0].containers == ["app"])
    }

    @Test func podsPreserveSpecContainerNames() {
        let list = decode(#"{"items":[{"metadata":{"name":"web-1","namespace":"default"},"spec":{"containers":[{"name":"app"},{"name":"sidecar"}]},"status":{"phase":"Running","containerStatuses":[{"name":"sidecar","ready":true,"restartCount":0},{"name":"app","ready":true,"restartCount":1}]}}]}"#, as: KubePodList.self)
        let rows = KubeRowMapper.pods(list)
        #expect(rows.count == 1)
        #expect(rows[0].containers == ["app", "sidecar"])
        #expect(rows[0].primaryContainer == "app")
        #expect(rows[0].streamsAllContainerLogs)
    }

    @Test func podsSurfaceCrashLoopBackOffFromContainerState() {
        let list = decode(#"{"items":[{"metadata":{"name":"api-1","namespace":"default"},"status":{"phase":"Running","containerStatuses":[{"ready":false,"restartCount":7,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}"#, as: KubePodList.self)
        let rows = KubeRowMapper.pods(list)
        #expect(rows.count == 1)
        #expect(rows[0].ready == "0/1")
        #expect(rows[0].restarts == 7)
        #expect(rows[0].phase == .crashLoopBackOff)
    }

    @Test func podsUseNamespaceQualifiedIdentity() {
        let list = decode(#"{"items":[{"metadata":{"name":"web","namespace":"default"},"status":{"phase":"Running","containerStatuses":[{"ready":true,"restartCount":0}]}},{"metadata":{"name":"web","namespace":"preview"},"status":{"phase":"Running","containerStatuses":[{"ready":true,"restartCount":0}]}}]}"#, as: KubePodList.self)
        let rows = KubeRowMapper.pods(list)
        #expect(rows.map(\.id) == ["default/web", "preview/web"])
        #expect(Set(rows.map(\.id)).count == 2)
    }

    @Test func namespacesExtractNames() {
        let list = decode(#"{"items":[{"metadata":{"name":"default"}},{"metadata":{"name":"kube-system"}}]}"#, as: KubeNamespaceList.self)
        #expect(KubeRowMapper.namespaces(list) == ["default", "kube-system"])
    }

    @Test func configMapsExposeSortedKeysAndData() {
        let list = decode(#"{"items":[{"metadata":{"name":"web-config","namespace":"default"},"data":{"B":"2","A":"1"}}]}"#, as: KubeConfigMapList.self)
        let rows = KubeRowMapper.configMaps(list)
        #expect(rows.count == 1)
        #expect(rows[0].keys == ["A", "B"])
        #expect(rows[0].data["B"] == "2")
    }

    @Test func secretsExposeTypeKeysAndDecodedValues() {
        let list = decode(#"{"items":[{"metadata":{"name":"web-secret","namespace":"default"},"type":"Opaque","data":{"password":"czNjcjN0","raw":"not-base64!"}}]}"#, as: KubeSecretList.self)
        let rows = KubeRowMapper.secrets(list)
        #expect(rows.count == 1)
        #expect(rows[0].type == "Opaque")
        #expect(rows[0].keys == ["password", "raw"])
        let decoded = KubeSecretDecode.decode(rows[0].data)
        #expect(decoded.first { $0.key == "password" }?.value == "s3cr3t")
        #expect(decoded.first { $0.key == "raw" }?.value == "not-base64!")
    }

    @Test func ingressesSummarizeHostsAddressesAndPaths() {
        let list = decode(#"{"items":[{"metadata":{"name":"web","namespace":"default"},"spec":{"rules":[{"host":"web.local","http":{"paths":[{"path":"/","backend":{"service":{"name":"web"}}}]}}]},"status":{"loadBalancer":{"ingress":[{"ip":"127.0.0.1"}]}}}]}"#, as: KubeIngressList.self)
        let rows = KubeRowMapper.ingresses(list)
        #expect(rows.count == 1)
        #expect(rows[0].hosts == "web.local")
        #expect(rows[0].address == "127.0.0.1")
        #expect(rows[0].paths == "/ → web")
    }
}
