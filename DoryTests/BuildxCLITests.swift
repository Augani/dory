import Foundation
import Testing
@testable import Dory

@Suite(.serialized)
struct BuildxCLITests {
    @Test func buildPinsBundledBuildxToDoryAndStreamsBoundedPlainProgress() async throws {
        let fixture = try BuildxFixture(name: "dory build $(touch must-not-run); *")
        defer { fixture.remove() }
        let output = LockedLines()
        let runner = RecordingBuildRunner { request in
            request.outputHandler?(.stdout, Data("#1 first step\npartial".utf8))
            request.outputHandler?(.stderr, Data("warning\r\n".utf8))
            request.outputHandler?(.stdout, Data(" line\n".utf8))
            return ToolCommandResult(terminationStatus: 0, stdout: "", stderr: "", outputTruncated: false)
        }
        let cli = BuildxCLI(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketPath: "/tmp/dory exact.sock",
            baseEnvironment: [
                "PATH": "/custom/bin",
                "DOCKER_CONFIG": "/tmp/credentials",
                "DOCKER_HOST": "tcp://wrong:2375",
                "DOCKER_AUTH_CONFIG": #"{"auths":{"wrong.invalid":{"auth":"secret"}}}"#,
                "DOCKER_CONTEXT": "competitor",
                "DOCKER_CUSTOM_HEADERS": "X-Wrong=secret",
                "DOCKER_DEFAULT_PLATFORM": "linux/amd64",
                "DOCKER_TLS": "1",
                "DOCKER_TLS_VERIFY": "1",
                "BUILDKIT_HOST": "tcp://wrong:1234",
                "BUILDKIT_PROGRESS": "tty",
                "BUILDX_BUILDER": "remote",
                "BUILDX_CONFIG": "/tmp/wrong-buildx",
                "BUILDX_EXPERIMENTAL": "1",
                "BUILDX_NO_DEFAULT_LOAD": "1",
                "EXPERIMENTAL_BUILDKIT_SOURCE_POLICY": "/tmp/policy.json",
            ],
            runner: runner
        )

        try await cli.build(contextDirectory: fixture.directory, tag: " demo/app:latest ") {
            output.append($0)
        }

        let request = try #require(runner.requests.first)
        #expect(request.executableURL.path == "/usr/bin/true")
        #expect(request.arguments == [
            "--builder", "default",
            "build",
            "--progress", "plain",
            "--load",
            "--tag", "demo/app:latest",
            "--", fixture.directory.path,
        ])
        #expect(request.workingDirectoryURL == fixture.directory)
        #expect(request.timeout == 2 * 60 * 60)
        #expect(request.outputPolicy == .tail(maxBytes: 512 * 1024))
        #expect(request.environment["DOCKER_HOST"] == "unix:///tmp/dory exact.sock")
        #expect(request.environment["DOCKER_CONFIG"] == "/tmp/credentials")
        #expect(request.environment["BUILDKIT_PROGRESS"] == "plain")
        #expect(request.environment["NO_COLOR"] == "1")
        #expect(request.environment["PATH"]?.hasPrefix("/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:") == true)
        for key in [
            "DOCKER_AUTH_CONFIG", "DOCKER_CONTEXT", "DOCKER_CUSTOM_HEADERS",
            "DOCKER_DEFAULT_PLATFORM", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "BUILDKIT_HOST",
            "BUILDX_BUILDER", "BUILDX_CONFIG", "BUILDX_EXPERIMENTAL", "BUILDX_NO_DEFAULT_LOAD",
            "EXPERIMENTAL_BUILDKIT_SOURCE_POLICY",
        ] {
            #expect(request.environment[key] == nil)
        }
        #expect(output.values == ["#1 first step", "warning", "partial line"])
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("must-not-run").path))
    }

    @Test func emptyTagIsOmittedWithoutChangingTheLiteralContextArgument() async throws {
        let fixture = try BuildxFixture(name: "--literal context")
        defer { fixture.remove() }
        let runner = RecordingBuildRunner.succeeding()
        let cli = testCLI(runner: runner)

        try await cli.build(contextDirectory: fixture.directory, tag: " \n ") { _ in }

        let request = try #require(runner.requests.first)
        #expect(!request.arguments.contains("--tag"))
        #expect(request.arguments.suffix(2) == ["--", fixture.directory.path][...])
    }

    @Test func validatesTheHelperSocketContextAndDockerfileBeforeLaunching() async throws {
        let fixture = try BuildxFixture(name: "validation")
        defer { fixture.remove() }
        let runner = RecordingBuildRunner.succeeding()

        await #expect(throws: BuildxCLIError.self) {
            try await BuildxCLI(
                executableURL: URL(fileURLWithPath: "/missing/docker-buildx"),
                socketPath: "/tmp/dory.sock",
                baseEnvironment: [:],
                runner: runner
            ).build(contextDirectory: fixture.directory, tag: "") { _ in }
        }
        await #expect(throws: BuildxCLIError.self) {
            try await BuildxCLI(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                socketPath: "relative.sock",
                baseEnvironment: [:],
                runner: runner
            ).build(contextDirectory: fixture.directory, tag: "") { _ in }
        }
        await #expect(throws: BuildxCLIError.self) {
            try await testCLI(runner: runner).build(
                contextDirectory: fixture.directory.appendingPathComponent("missing"),
                tag: ""
            ) { _ in }
        }
        try FileManager.default.removeItem(at: fixture.dockerfile)
        await #expect(throws: BuildxCLIError.self) {
            try await testCLI(runner: runner).build(contextDirectory: fixture.directory, tag: "") { _ in }
        }
        #expect(runner.requests.isEmpty)
    }

    @Test func commandFailureDoesNotRepeatBuildOutputOrSecretsInTheError() async throws {
        let fixture = try BuildxFixture(name: "failure")
        defer { fixture.remove() }
        let secret = "registry-password-value"
        let runner = RecordingBuildRunner { request in
            request.outputHandler?(.stderr, Data("unauthorized password=\(secret)\n".utf8))
            return ToolCommandResult(
                terminationStatus: 1,
                stdout: "token=\(secret)",
                stderr: "password=\(secret)",
                outputTruncated: false
            )
        }

        do {
            try await testCLI(runner: runner).build(contextDirectory: fixture.directory, tag: "demo") { _ in }
            Issue.record("Expected Buildx to fail")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
            #expect(!error.localizedDescription.contains("password="))
            #expect(error.localizedDescription.contains("exit 1"))
        }
    }

    private func testCLI(runner: any ToolCommandRunning) -> BuildxCLI {
        BuildxCLI(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketPath: "/tmp/dory.sock",
            baseEnvironment: [:],
            runner: runner
        )
    }
}

nonisolated private final class RecordingBuildRunner: ToolCommandRunning, @unchecked Sendable {
    typealias Handler = @Sendable (ToolCommandRequest) throws -> ToolCommandResult

    private let lock = NSLock()
    private let handler: Handler
    private var recorded: [ToolCommandRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    static func succeeding() -> RecordingBuildRunner {
        RecordingBuildRunner { _ in
            ToolCommandResult(terminationStatus: 0, stdout: "", stderr: "", outputTruncated: false)
        }
    }

    var requests: [ToolCommandRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ request: ToolCommandRequest) async throws -> ToolCommandResult {
        record(request)
        return try handler(request)
    }

    private func record(_ request: ToolCommandRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }
}

nonisolated private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

nonisolated private struct BuildxFixture {
    let directory: URL
    let dockerfile: URL

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        dockerfile = directory.appendingPathComponent("Dockerfile")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("FROM scratch\n".utf8).write(to: dockerfile)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
