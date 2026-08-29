import Foundation
import Testing
@testable import Dory

struct KubernetesProvisionerImageTests {
    @Test func defaultImageIsCatalogLatest() {
        #expect(KubernetesProvisioner.defaultImage == KubeVersionCatalog.latest.image)
    }

    @Test func nativeCreateRequestUsesTheUnmodifiedK3sEntrypoint() throws {
        let image = KubeVersionCatalog.all[2].image
        let root = try jsonObject(image: image, amd64Emulation: false)
        let host = try #require(root["HostConfig"] as? [String: Any])
        let labels = try #require(root["Labels"] as? [String: String])
        let command = try #require(root["Cmd"] as? [String])

        #expect(root["Image"] as? String == image)
        #expect(root["Entrypoint"] == nil)
        #expect(host["Binds"] == nil)
        #expect(command.first == "server")
        #expect(command.contains("--disable=traefik"))
        #expect(labels[KubernetesProvisioner.contractLabel] == KubernetesProvisioner.runtimeContract)
        #expect(labels[KubernetesProvisioner.emulationLabel] == "disabled")
        #expect(labels[KubernetesProvisioner.imageLabel] == image)
    }

    @Test func fexCreateRequestDelegatesNestedRuntimeMountsToEngineAdmission() throws {
        let image = KubeVersionCatalog.latest.image
        let root = try jsonObject(image: image, amd64Emulation: true)
        let host = try #require(root["HostConfig"] as? [String: Any])
        let labels = try #require(root["Labels"] as? [String: String])
        let entrypoint = try #require(root["Entrypoint"] as? [String])

        #expect(entrypoint == ["/bin/sh", "-ec"])
        #expect(host["Binds"] == nil)
        #expect(labels[KubernetesProvisioner.emulationLabel] == "fex")
    }

    @Test func fexStartupPreservesK3sRuncAndWritesAnAtomicDropIn() throws {
        let root = try jsonObject(image: KubernetesProvisioner.defaultImage, amd64Emulation: true)
        let command = try #require(root["Cmd"] as? [String])
        let script = try #require(command.first)

        #expect(script.contains("test -x /usr/lib/dory/fex/FEX"))
        #expect(script.contains("test -x /usr/lib/dory/fex/FEXServer"))
        #expect(script.contains("test -x /usr/local/bin/runc.real"))
        #expect(!script.contains("install -m 0755 /bin/runc"))
        #expect(script.contains("BinaryName = \"/usr/local/bin/dory-runc\""))
        #expect(!script.contains("platforms = ["))
        #expect(script.contains("runtime_config_tmp="))
        #expect(script.contains("mv -f \"${runtime_config_tmp}\" \"${runtime_config}\""))
        #expect(script.contains("failed to pull and unpack image"))
        #expect(script.contains("images pull --platform linux/amd64"))
        #expect(script.contains("/usr/local/bin/crictl pull \"${direct}\""))
        #expect(script.contains("images tag --force --local"))
        #expect(script.contains("io.cri-containerd.image=managed"))
        #expect(script.contains("[ \"${attempt_count}\" -lt 3 ]"))
        #expect(script.contains("KUBERNETES_SERVICE_HOST"))
        #expect(script.contains("resolver.ready"))
        #expect(script.contains("readinessProbe:"))
        #expect(script.contains("path: /bin/kubectl"))
        #expect(script.contains("path: /bin/ctr"))
        #expect(script.contains("path: /bin/crictl"))
        #expect(script.contains("app.kubernetes.io/managed-by: dory"))
        #expect(script.contains("readOnlyRootFilesystem: true"))
        #expect(script.contains("capabilities:\n              drop: [\"ALL\"]"))
        #expect(script.contains("exec /bin/k3s server"))
    }

    @Test func readinessProbeCannotMistakeNotReadyForReady() {
        #expect(KubernetesProvisioner.nodeProbeIsReady(output: "True", exitCode: 0))
        #expect(KubernetesProvisioner.nodeProbeIsReady(output: "True\n", exitCode: 0))
        #expect(!KubernetesProvisioner.nodeProbeIsReady(output: "False", exitCode: 0))
        #expect(!KubernetesProvisioner.nodeProbeIsReady(output: "NotReady", exitCode: 0))
        #expect(!KubernetesProvisioner.nodeProbeIsReady(output: "True", exitCode: 1))
    }

    @Test func imageNameCannotChangeTheJSONRequestShape() throws {
        let image = #"registry.example/dory\"},\"HostConfig\":{\"Privileged\":false}}:test"#
        let root = try jsonObject(image: image, amd64Emulation: true)
        let host = try #require(root["HostConfig"] as? [String: Any])

        #expect(root["Image"] as? String == image)
        #expect(host["Privileged"] as? Bool == true)
        #expect(root.count == 6)
    }

    @Test func incompatibleContractMessagePromisesNotToDestroyState() {
        let error = KubernetesProvisioner.K8sError.recreationRequired("runtime update required")
        #expect(error.description.contains("Dory did not modify or remove the existing cluster"))
        #expect(error.description.contains("Export any cluster-only workloads"))
    }

    private func jsonObject(image: String, amd64Emulation: Bool) throws -> [String: Any] {
        let json = KubernetesProvisioner.createJSON(image: image, amd64Emulation: amd64Emulation)
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(value as? [String: Any])
    }

}
