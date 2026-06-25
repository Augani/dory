import Testing
import Foundation
@testable import Dory

@MainActor
struct ComposeVolumeWiringTests {
    private func project(_ yaml: String, name: String = "demo") throws -> ComposeProject {
        try ComposeParser.parse([yaml], projectName: name)
    }

    @Test func upCreatesPrefixedProjectVolumesWithLabels() async throws {
        let runtime = RecordingRuntime()
        let engine = ComposeEngine(runtime: runtime)
        let project = try project("""
        services:
          web:
            image: nginx:alpine
        volumes:
          data: {}
          cache: {}
        """)

        _ = try await engine.up(project)

        #expect(runtime.volumesCreated.sorted() == ["demo_cache", "demo_data"])
        let dataRequest = try #require(runtime.volumeCreateRequests.first { $0.name == "demo_data" })
        #expect(dataRequest.labels["com.docker.compose.project"] == "demo")
        #expect(dataRequest.labels["com.docker.compose.volume"] == "data")
    }

    @Test func serviceNamedVolumeReferencesArePrefixed() async throws {
        let runtime = RecordingRuntime()
        let engine = ComposeEngine(runtime: runtime)
        let project = try project("""
        services:
          web:
            image: nginx:alpine
            volumes:
              - data:/var/lib/data
              - ./html:/usr/share/nginx/html
              - /cache
              - other:/mnt/other
        volumes:
          data: {}
        """)

        _ = try await engine.up(project)

        let web = try #require(runtime.createdSpecs.first { $0.name == "demo-web-1" })
        #expect(web.volumes == [
            "demo_data:/var/lib/data",
            "./html:/usr/share/nginx/html",
            "/cache",
            "other:/mnt/other",
        ])
    }

    @Test func upSwallowsAlreadyExistingVolume() async throws {
        let runtime = RecordingRuntime()
        runtime.preexistingVolumes = ["demo_data"]
        let engine = ComposeEngine(runtime: runtime)
        let project = try project("""
        services:
          web:
            image: nginx:alpine
        volumes:
          data: {}
        """)

        _ = try await engine.up(project)

        #expect(runtime.startedIDs.count == 1)
    }

    @Test func downWithRemoveVolumesRemovesProjectVolumes() async throws {
        let runtime = RecordingRuntime()
        let engine = ComposeEngine(runtime: runtime)
        let project = try project("""
        services:
          web:
            image: nginx:alpine
        volumes:
          data: {}
          cache: {}
        """)

        _ = try await engine.up(project)
        try await engine.down(project, removeVolumes: true)

        #expect(runtime.volumesRemoved.sorted() == ["demo_cache", "demo_data"])
    }

    @Test func downByDefaultKeepsProjectVolumes() async throws {
        let runtime = RecordingRuntime()
        let engine = ComposeEngine(runtime: runtime)
        let project = try project("""
        services:
          web:
            image: nginx:alpine
        volumes:
          data: {}
        """)

        _ = try await engine.up(project)
        try await engine.down(project)

        #expect(runtime.volumesRemoved.isEmpty)
    }
}
