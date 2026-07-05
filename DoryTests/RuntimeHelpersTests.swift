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

    @Test func dockerHubRegistryAliasesUseCanonicalAuthKey() throws {
        #expect(DockerRegistry.registryServer(for: "alpine") == "https://index.docker.io/v1/")
        #expect(DockerRegistry.registryServer(for: "docker.io/library/alpine") == "https://index.docker.io/v1/")
        #expect(DockerRegistry.registryServer(for: "index.docker.io/library/alpine") == "https://index.docker.io/v1/")
        #expect(DockerRegistry.registryServer(for: "registry-1.docker.io/library/alpine") == "https://index.docker.io/v1/")

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-docker-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try DockerRegistry.persistDockerAuth(server: "docker.io", username: "octo", password: "secret", home: home.path)

        let configData = try Data(contentsOf: home.appendingPathComponent(".docker/config.json"))
        let config = try #require(try JSONSerialization.jsonObject(with: configData) as? [String: Any])
        let auths = try #require(config["auths"] as? [String: Any])
        #expect(auths["https://index.docker.io/v1/"] != nil)
        #expect(auths["docker.io"] == nil)

        let header = try #require(DockerRegistry.registryAuthHeader(for: "docker.io/library/private-app", home: home.path))
        let data = try #require(Data(base64Encoded: header))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["username"] == "octo")
        #expect(json["password"] == "secret")
        #expect(json["serveraddress"] == "https://index.docker.io/v1/")

        let legacyHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-docker-legacy-auth-\(UUID().uuidString)", isDirectory: true)
        let legacyDockerDir = legacyHome.appendingPathComponent(".docker", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDockerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyHome) }
        let legacyConfig = [
            "auths": ["docker.io": ["auth": Data("legacy:token".utf8).base64EncodedString()]]
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyConfig)
        try legacyData.write(to: legacyDockerDir.appendingPathComponent("config.json"))

        let legacyHeader = try #require(DockerRegistry.registryAuthHeader(
            for: "registry-1.docker.io/library/private-app",
            home: legacyHome.path
        ))
        let legacyHeaderData = try #require(Data(base64Encoded: legacyHeader))
        let legacyJSON = try #require(try JSONSerialization.jsonObject(with: legacyHeaderData) as? [String: String])
        #expect(legacyJSON["username"] == "legacy")
        #expect(legacyJSON["password"] == "token")
        #expect(legacyJSON["serveraddress"] == "https://index.docker.io/v1/")
    }

    @Test func parsesPortMappings() {
        #expect(DockerCreateBody.parsePort("8080:80").key == "80/tcp")
        #expect(DockerCreateBody.parsePort("8080:80").hostPort == "8080")
        #expect(DockerCreateBody.parsePort("80").key == "80/tcp")
        #expect(DockerCreateBody.parsePort("80").hostPort == nil)
        #expect(DockerCreateBody.parsePort("8080:80/udp").key == "80/udp")
        #expect(DockerCreateBody.parsePort("[::1]:8443:443").key == "443/tcp")
        #expect(DockerCreateBody.parsePort("[::1]:8443:443").hostPort == "8443")
        #expect(DockerCreateBody.parsePort("[::1]:8443:443").hostIP == "::1")
        #expect(DockerCreateBody.parsePort("2001:db8::1:9443:443").hostIP == "2001:db8::1")
    }

    @Test func formatsDockerPortsWithProtocolAndHostIP() {
        let display = DockerFormat.ports([
            DockerPort(privatePort: 53, publicPort: 5353, type: "udp", ip: "127.0.0.1"),
            DockerPort(privatePort: 443, publicPort: nil, type: "tcp", ip: nil),
        ])
        #expect(display == "127.0.0.1:5353->53/udp, 443/tcp")
        #expect(parsePublishedPorts(display) == [PublishedPort(hostPort: 5353, containerPort: 53, proto: "udp")])
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
