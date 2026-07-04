import Foundation
import Testing
@testable import Dory

struct KubernetesProvisionerImageTests {
    @Test func defaultImageIsCatalogLatest() {
        #expect(KubernetesProvisioner.defaultImage == KubeVersionCatalog.latest.image)
    }

    @Test func createJSONInterpolatesTheGivenImage() {
        let image = KubeVersionCatalog.all[2].image
        let json = KubernetesProvisioner.createJSON(image: image)
        #expect(json.contains("\"Image\":\"\(image)\""))
        #expect(json.contains("\"server\""))
        #expect(json.contains("--disable=traefik"))
        #expect(json.contains("PortBindings"))
    }

    @Test func createJSONWithoutExtrasMatchesLegacyShape() {
        let image = KubeVersionCatalog.latest.image
        let json = KubernetesProvisioner.createJSON(image: image)
        #expect(json.contains("\"ExposedPorts\":{\"6443/tcp\":{}}"))
        #expect(json.contains("\"PortBindings\":{\"6443/tcp\":[{\"HostPort\":\"6443\"}]}"))
        #expect(!json.contains("Binds"))
    }

    @Test func createJSONPublishesExtraPortsAlongsideAPI() {
        let ports = [KubernetesProvisioner.PortPublish(host: 30500, container: 30500, proto: "tcp")]
        let json = KubernetesProvisioner.createJSON(image: KubernetesProvisioner.defaultImage, extraPorts: ports)
        #expect(json.contains("\"6443/tcp\":[{\"HostPort\":\"6443\"}]"))
        #expect(json.contains("\"30500/tcp\":{}"))
        #expect(json.contains("\"30500/tcp\":[{\"HostPort\":\"30500\"}]"))
    }

    @Test func createJSONIgnoresExtraPortDuplicatingAPIPort() {
        let ports = [KubernetesProvisioner.PortPublish(host: 6443, container: 6443, proto: "tcp")]
        let json = KubernetesProvisioner.createJSON(image: KubernetesProvisioner.defaultImage, extraPorts: ports)
        #expect(json.contains("\"ExposedPorts\":{\"6443/tcp\":{}}"))
    }

    @Test func createJSONBindsRegistriesConfigWhenProvided() {
        let json = KubernetesProvisioner.createJSON(
            image: KubernetesProvisioner.defaultImage,
            registriesBind: "/Users/me/.dory/k8s/registries.yaml"
        )
        #expect(json.contains("\"Binds\":[\"/Users/me/.dory/k8s/registries.yaml:/etc/rancher/k3s/registries.yaml:ro\"]"))
    }

    @Test func portPublishParsesLinesAndSkipsCommentsAndGarbage() {
        #expect(KubernetesProvisioner.PortPublish.parse("30500:30500")
            == KubernetesProvisioner.PortPublish(host: 30500, container: 30500, proto: "tcp"))
        #expect(KubernetesProvisioner.PortPublish.parse("  8080:80/udp ")
            == KubernetesProvisioner.PortPublish(host: 8080, container: 80, proto: "udp"))
        #expect(KubernetesProvisioner.PortPublish.parse("# comment") == nil)
        #expect(KubernetesProvisioner.PortPublish.parse("") == nil)
        #expect(KubernetesProvisioner.PortPublish.parse("30500") == nil)
        #expect(KubernetesProvisioner.PortPublish.parse("a:b") == nil)
        #expect(KubernetesProvisioner.PortPublish.parse("0:70000") == nil)
        #expect(KubernetesProvisioner.PortPublish.parse("80:80/sctp") == nil)
    }

    @Test func renameContextRewritesAllDefaultNames() {
        let k3sYaml = """
        apiVersion: v1
        clusters:
        - cluster:
            server: https://127.0.0.1:6443
          name: default
        contexts:
        - context:
            cluster: default
            user: default
          name: default
        current-context: default
        kind: Config
        users:
        - name: default
          user:
            client-certificate-data: abc
        """
        let renamed = KubernetesProvisioner.renameContext(k3sYaml)
        #expect(!renamed.contains("default"))
        #expect(renamed.contains("name: dory"))
        #expect(renamed.contains("cluster: dory"))
        #expect(renamed.contains("user: dory"))
        #expect(renamed.contains("current-context: dory"))
        #expect(renamed.contains("client-certificate-data: abc"))
    }
}
