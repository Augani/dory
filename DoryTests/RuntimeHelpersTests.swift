import Testing
import Foundation
@testable import Dory

struct RuntimeHelpersTests {
    @Test func splitsImageReferences() {
        #expect(DockerRegistry.splitImageRef("postgres:16-alpine").repo == "postgres")
        #expect(DockerRegistry.splitImageRef("postgres:16-alpine").tag == "16-alpine")
        #expect(DockerRegistry.splitImageRef("nginx").tag == "latest")
        #expect(DockerRegistry.splitImageRef("docker.io/library/alpine:3.22").repo == "docker.io/library/alpine")
        #expect(DockerRegistry.splitImageRef("docker.io/library/alpine:3.22").tag == "3.22")
        // A registry port colon must not be treated as a tag.
        #expect(DockerRegistry.splitImageRef("registry:5000/app").tag == "latest")
    }

    @Test func parsesPortMappings() {
        #expect(DockerCreateBody.parsePort("8080:80").key == "80/tcp")
        #expect(DockerCreateBody.parsePort("8080:80").hostPort == "8080")
        #expect(DockerCreateBody.parsePort("80").key == "80/tcp")
        #expect(DockerCreateBody.parsePort("80").hostPort == nil)
        #expect(DockerCreateBody.parsePort("8080:80/udp").key == "80/udp")
    }

    @Test func mapsDistroInfo() {
        #expect(AppleContainerRuntime.distroInfo("ubuntu-dev").distro == "Ubuntu")
        #expect(AppleContainerRuntime.distroInfo("ubuntu-dev").letter == "U")
        #expect(AppleContainerRuntime.distroInfo("my-alpine").distro == "Alpine")
        #expect(AppleContainerRuntime.distroInfo("dory-mach").distro == "Linux")
        #expect(AppleContainerRuntime.distroInfo("dory-mach").letter == "D")
    }

    @Test func mapsKubernetesPhase() {
        #expect(KubeRowMapper.podPhase("Running", statuses: []) == .running)
        #expect(KubeRowMapper.podPhase("Pending", statuses: []) == .pending)
        #expect(KubeRowMapper.podPhase("Succeeded", statuses: []) == .completed)
        #expect(KubeRowMapper.podPhase("Failed", statuses: []) == .crashLoopBackOff)
    }

    @Test func formatsBytes() {
        #expect(DockerFormat.bytes(0) == "0 MB")
        #expect(DockerFormat.bytes(8_589_934_592) == "8.0 GB")
        #expect(DockerFormat.bytes(128 * 1024 * 1024) == "128 MB")
    }
}
