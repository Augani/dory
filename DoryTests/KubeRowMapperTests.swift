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

    @Test func servicesSkipHeadless() {
        let list = decode(#"{"items":[{"metadata":{"name":"db","namespace":"data"},"spec":{"type":"ClusterIP","clusterIP":"None","ports":[{"port":5432,"protocol":"TCP"}]}},{"metadata":{"name":"web","namespace":"default"},"spec":{"type":"ClusterIP","clusterIP":"10.0.0.5","ports":[{"port":80,"protocol":"TCP"},{"port":443,"protocol":"TCP"}]}}]}"#, as: KubeServiceList.self)
        let rows = KubeRowMapper.services(list)
        #expect(rows.count == 1)
        #expect(rows[0].name == "web")
        #expect(rows[0].ports == "80/TCP, 443/TCP")
    }

    @Test func podsReproduceExistingMapping() {
        let list = decode(#"{"items":[{"metadata":{"name":"web-1","namespace":"default"},"status":{"phase":"Running","containerStatuses":[{"ready":true,"restartCount":2}]}}]}"#, as: KubePodList.self)
        let rows = KubeRowMapper.pods(list)
        #expect(rows.count == 1)
        #expect(rows[0].ready == "1/1")
        #expect(rows[0].restarts == 2)
        #expect(rows[0].phase == .running)
    }

    @Test func namespacesExtractNames() {
        let list = decode(#"{"items":[{"metadata":{"name":"default"}},{"metadata":{"name":"kube-system"}}]}"#, as: KubeNamespaceList.self)
        #expect(KubeRowMapper.namespaces(list) == ["default", "kube-system"])
    }
}
