import Foundation
import Testing
@testable import Dory

struct KubernetesProvisionerImageTests {
    private struct CreateBody: Decodable {
        let Image: String
        let Cmd: [String]
        let ExposedPorts: [String: EmptyObject]
        let HostConfig: HostConfig

        struct EmptyObject: Decodable {}

        struct HostConfig: Decodable {
            let Privileged: Bool
            let PortBindings: [String: [PortBinding]]
            let Binds: [String]?
        }

        struct PortBinding: Decodable {
            let HostPort: String
            let HostIp: String?
        }
    }

    @Test func defaultImageIsCatalogLatest() {
        #expect(KubernetesProvisioner.defaultImage == KubeVersionCatalog.latest.image)
    }

    @Test func createJSONEncodesStructuredCreateBody() throws {
        let image = KubeVersionCatalog.all[2].image
        let body = try decodeCreateBody(KubernetesProvisioner.createJSON(image: image))
        #expect(body.Image == image)
        #expect(body.Cmd == ["server", "--disable=traefik", "--tls-san=127.0.0.1", "--tls-san=host.docker.internal"])
        #expect(Array(body.ExposedPorts.keys).sorted() == ["6443/tcp"])
        #expect((body.HostConfig.PortBindings["6443/tcp"] ?? []).map(\.HostPort) == ["6443"])
        #expect(body.HostConfig.Privileged)
        #expect(body.HostConfig.Binds == nil)
    }

    @Test func createJSONPublishesExtraPortsAlongsideAPI() throws {
        let ports = [KubernetesProvisioner.PortPublish(host: 30500, container: 30500, proto: "tcp")]
        let body = try decodeCreateBody(KubernetesProvisioner.createJSON(image: KubernetesProvisioner.defaultImage, extraPorts: ports))
        #expect(Array(body.ExposedPorts.keys).sorted() == ["30500/tcp", "6443/tcp"])
        #expect((body.HostConfig.PortBindings["30500/tcp"] ?? []).map(\.HostPort) == ["30500"])
        #expect((body.HostConfig.PortBindings["6443/tcp"] ?? []).map(\.HostPort) == ["6443"])
    }

    @Test func createJSONMergesRepeatedContainerProtoBindings() throws {
        let ports = [
            KubernetesProvisioner.PortPublish(host: 30500, container: 80, proto: "tcp"),
            KubernetesProvisioner.PortPublish(host: 30501, container: 80, proto: "tcp"),
            KubernetesProvisioner.PortPublish(host: 30500, container: 80, proto: "tcp"),
        ]
        let body = try decodeCreateBody(KubernetesProvisioner.createJSON(image: KubernetesProvisioner.defaultImage, extraPorts: ports))
        let hostPorts = (body.HostConfig.PortBindings["80/tcp"] ?? []).map(\.HostPort).sorted()
        #expect(hostPorts == ["30500", "30501"])
        #expect(body.ExposedPorts["80/tcp"] != nil)
    }

    @Test func createJSONKeepsExtraAPIPortBindingWhenHostDiffers() throws {
        let ports = [
            KubernetesProvisioner.PortPublish(host: 6443, container: 6443, proto: "tcp"),
            KubernetesProvisioner.PortPublish(host: 16443, container: 6443, proto: "tcp"),
        ]
        let body = try decodeCreateBody(KubernetesProvisioner.createJSON(image: KubernetesProvisioner.defaultImage, extraPorts: ports))
        let hostPorts = (body.HostConfig.PortBindings["6443/tcp"] ?? []).map(\.HostPort).sorted()
        #expect(hostPorts == ["16443", "6443"])
    }

    @Test func createJSONEscapesImageAndRegistriesBind() throws {
        let image = "registry.example.com/team/ki\"nd:dev\\test"
        let bind = "/Users/me/Application Support/\"dory\"\\registries.yaml"
        let body = try decodeCreateBody(
            KubernetesProvisioner.createJSON(
                image: image,
                registriesBind: bind
            )
        )
        #expect(body.Image == image)
        #expect(body.HostConfig.Binds == ["\(bind):/etc/rancher/k3s/registries.yaml:ro"])
    }

    @Test func portPublishParsesLinesAndSkipsCommentsAndGarbage() {
        #expect(KubernetesProvisioner.PortPublish.parse("30500:30500")
            == KubernetesProvisioner.PortPublish(host: 30500, container: 30500, proto: "tcp"))
        #expect(KubernetesProvisioner.PortPublish.parse("30500:30500\r")
            == KubernetesProvisioner.PortPublish(host: 30500, container: 30500, proto: "tcp"))
        #expect(KubernetesProvisioner.PortPublish.parse("30500:30500 # registry")
            == KubernetesProvisioner.PortPublish(host: 30500, container: 30500, proto: "tcp"))
        #expect(KubernetesProvisioner.PortPublish.parse("  8080 : 80 / udp # service ")
            == KubernetesProvisioner.PortPublish(host: 8080, container: 80, proto: "udp"))
        #expect(KubernetesProvisioner.PortPublish.parse("  8080:80/udp ")
            == KubernetesProvisioner.PortPublish(host: 8080, container: 80, proto: "udp"))
        #expect(KubernetesProvisioner.PortPublish.parse("# comment") == nil)
        #expect(KubernetesProvisioner.PortPublish.parse("") == nil)
        #expect(KubernetesProvisioner.PortPublish.parse("30500") == nil)
        #expect(KubernetesProvisioner.PortPublish.parse("a:b") == nil)
        #expect(KubernetesProvisioner.PortPublish.parse("0:70000") == nil)
        #expect(KubernetesProvisioner.PortPublish.parse("80:80/sctp") == nil)
    }

    @Test func loadExtraPortsStripsInlineComments() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        30500:30500 # registry
        # full-line comment

          8080 : 80 / udp # service
        """.write(to: url, atomically: true, encoding: .utf8)

        #expect(try KubernetesProvisioner.loadExtraPorts(path: url.path) == [
            KubernetesProvisioner.PortPublish(host: 30500, container: 30500, proto: "tcp"),
            KubernetesProvisioner.PortPublish(host: 8080, container: 80, proto: "udp"),
        ])
    }

    @Test func loadExtraPortsThrowsOnInvalidNonCommentLines() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try """
        # comment
        invalid
        """.write(to: url, atomically: true, encoding: .utf8)

        do {
            _ = try KubernetesProvisioner.loadExtraPorts(path: url.path)
            Issue.record("expected invalid port config error")
        } catch KubernetesProvisioner.K8sError.invalidPortConfig(let path, let line, let value) {
            #expect(path == url.path)
            #expect(line == 2)
            #expect(value == "invalid")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func inspectJSONMatchesHostPortOnTheRequestedContainerPort() {
        let desired = [KubernetesProvisioner.PortPublish(host: 30500, container: 30500, proto: "tcp")]
        let crossed = """
        {"HostConfig":{"PortBindings":{
          "30500/tcp":[{"HostPort":"30501"}],
          "30501/tcp":[{"HostPort":"30500"}]
        }}}
        """
        let matching = """
        {"HostConfig":{"PortBindings":{
          "30500/tcp":[{"HostPort":"30500"}]
        }}}
        """

        #expect(!KubernetesProvisioner.inspectJSONCoversConfig(crossed, extraPorts: desired, registriesBind: nil))
        #expect(KubernetesProvisioner.inspectJSONCoversConfig(matching, extraPorts: desired, registriesBind: nil))
    }

    @Test func inspectJSONDetectsRemovedExtraPorts() {
        let desired = [KubernetesProvisioner.PortPublish(host: 30500, container: 30500, proto: "tcp")]
        let builtInOnly = """
        {"HostConfig":{"PortBindings":{
          "6443/tcp":[{"HostPort":"6443"}]
        }}}
        """
        let staleActual = """
        {"HostConfig":{"PortBindings":{
          "6443/tcp":[{"HostPort":"6443"}],
          "30500/tcp":[{"HostPort":"30500"}]
        }}}
        """

        #expect(!KubernetesProvisioner.inspectJSONCoversConfig(builtInOnly, extraPorts: desired, registriesBind: nil))
        #expect(!KubernetesProvisioner.inspectJSONCoversConfig(staleActual, extraPorts: [], registriesBind: nil))
        #expect(KubernetesProvisioner.inspectJSONCoversConfig(builtInOnly, extraPorts: [], registriesBind: nil))
    }

    @Test func inspectJSONIgnoresOnlyTheBuiltInAPIBinding() {
        let desired = [KubernetesProvisioner.PortPublish(host: 16443, container: 6443, proto: "tcp")]
        let matching = """
        {"HostConfig":{"PortBindings":{
          "6443/tcp":[{"HostPort":"6443"},{"HostPort":"16443"}]
        }}}
        """
        let removed = """
        {"HostConfig":{"PortBindings":{
          "6443/tcp":[{"HostPort":"6443"}]
        }}}
        """

        #expect(KubernetesProvisioner.inspectJSONCoversConfig(matching, extraPorts: desired, registriesBind: nil))
        #expect(!KubernetesProvisioner.inspectJSONCoversConfig(removed, extraPorts: desired, registriesBind: nil))
    }

    @Test func inspectJSONRequiresExactRegistriesBindSource() {
        let expected = "/Users/me/.dory/k8s/registries.yaml"
        let wrong = """
        {"HostConfig":{"Binds":[
          "/Users/me/.dory/k8s/registries.yaml.bak:/etc/rancher/k3s/registries.yaml:ro"
        ],"PortBindings":{}}}
        """
        let matching = """
        {"HostConfig":{"Binds":[
          "/Users/me/.dory/k8s/registries.yaml:/etc/rancher/k3s/registries.yaml:ro"
        ],"PortBindings":{}}}
        """

        #expect(!KubernetesProvisioner.inspectJSONCoversConfig(wrong, extraPorts: [], registriesBind: expected))
        #expect(KubernetesProvisioner.inspectJSONCoversConfig(matching, extraPorts: [], registriesBind: expected))
    }

    @Test func inspectJSONDetectsRemovedRegistriesBind() {
        let staleActual = """
        {"HostConfig":{"Binds":[
          "/Users/me/.dory/k8s/registries.yaml:/etc/rancher/k3s/registries.yaml:ro"
        ],"PortBindings":{}}}
        """
        let desired = "/Users/me/.dory/k8s/registries.yaml"
        let noActual = #"{"HostConfig":{"Binds":[],"PortBindings":{}}}"#

        #expect(!KubernetesProvisioner.inspectJSONCoversConfig(staleActual, extraPorts: [], registriesBind: nil))
        #expect(!KubernetesProvisioner.inspectJSONCoversConfig(noActual, extraPorts: [], registriesBind: desired))
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

    @Test func renameContextLeavesUnrelatedDefaultTextUntouched() {
        let k3sYaml = """
        apiVersion: v1
        users:
        - name: default
          user:
            username: default
            note: name: default
            comment: user: default
        current-context: default
        # user: default
        """
        let renamed = KubernetesProvisioner.renameContext(k3sYaml)
        #expect(renamed.contains("username: default"))
        #expect(renamed.contains("note: name: default"))
        #expect(renamed.contains("comment: user: default"))
        #expect(renamed.contains("# user: default"))
        #expect(renamed.contains("- name: dory"))
        #expect(renamed.contains("current-context: dory"))
    }

    private func decodeCreateBody(_ json: String) throws -> CreateBody {
        try JSONDecoder().decode(CreateBody.self, from: Data(json.utf8))
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-k8s-ports-\(UUID().uuidString)")
    }
}
