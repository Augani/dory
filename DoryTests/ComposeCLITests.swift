import Foundation
import Testing
@testable import Dory

@Suite(.serialized)
struct ComposeCLITests {
    @Test func resolveUsesOfficialCLIAndPinsTheExactEngine() async throws {
        let fixture = try ComposeFixture()
        defer { fixture.remove() }
        let runner = ScriptedComposeRunner([
            .success(ToolCommandResult(
                terminationStatus: 0,
                stdout: #"{"name":"demo","services":{}}"#,
                stderr: "",
                outputTruncated: false
            )),
        ])
        let cli = ComposeCLI(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketPath: "/tmp/dory exact.sock",
            baseEnvironment: [
                "PATH": "/custom/bin",
                "DOCKER_HOST": "tcp://wrong:2375",
                "DOCKER_CONTEXT": "competitor",
                "COMPOSE_FILE": "wrong.yaml",
                "COMPOSE_PATH_SEPARATOR": ";",
                "COMPOSE_PROJECT_NAME": "demo",
                "COMPOSE_PROFILES": "debug",
                "COMPOSE_ENV_FILES": "wrong.env",
                "COMPOSE_IGNORE_ORPHANS": "1",
                "COMPOSE_BAKE": "1",
            ],
            runner: runner
        )

        let context = try await cli.resolve(files: [fixture.base, fixture.override])

        #expect(context.name == "demo")
        #expect(context.files == [fixture.base, fixture.override])
        let request = try #require(runner.requests.first)
        #expect(request.executableURL.path == "/usr/bin/true")
        #expect(request.arguments == [
            "--ansi", "never", "--progress", "plain",
            "--project-directory", fixture.directory.path,
            "--file", fixture.base.path,
            "--file", fixture.override.path,
            "config", "--format", "json",
        ])
        #expect(request.workingDirectoryURL == fixture.directory)
        #expect(request.environment["DOCKER_HOST"] == "unix:///tmp/dory exact.sock")
        #expect(request.environment["DOCKER_CONTEXT"] == nil)
        #expect(request.environment["COMPOSE_FILE"] == nil)
        #expect(request.environment["COMPOSE_PATH_SEPARATOR"] == nil)
        #expect(request.environment["COMPOSE_PROJECT_NAME"] == nil)
        #expect(request.environment["COMPOSE_PROFILES"] == nil)
        #expect(request.environment["COMPOSE_ENV_FILES"] == nil)
        #expect(request.environment["COMPOSE_IGNORE_ORPHANS"] == nil)
        #expect(request.environment["COMPOSE_BAKE"] == nil)
        #expect(request.environment["COMPOSE_MENU"] == "0")
        #expect(request.environment["PATH"]?.hasPrefix("/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:") == true)
        #expect(request.timeout == 60)
        #expect(request.outputPolicy == .complete(maxBytes: 32 * 1024 * 1024))
    }

    @Test func upAndDownAreNoninteractiveBoundedAndProfileComplete() async throws {
        let fixture = try ComposeFixture()
        defer { fixture.remove() }
        let environmentFile = fixture.directory.appendingPathComponent("release.env")
        try Data("MODE=release\n".utf8).write(to: environmentFile)
        let runner = ScriptedComposeRunner([
            .success(.init(terminationStatus: 0, stdout: "", stderr: "", outputTruncated: false)),
            .success(.init(terminationStatus: 0, stdout: "", stderr: "", outputTruncated: false)),
        ])
        let cli = ComposeCLI(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketPath: "/tmp/dory.sock",
            baseEnvironment: [:],
            runner: runner
        )
        let context = ComposeProjectContext(
            name: "demo",
            files: [fixture.base, fixture.override],
            workingDirectory: fixture.directory,
            environmentFiles: [environmentFile]
        )

        try await cli.up(context)
        try await cli.down(context)

        #expect(runner.requests.count == 2)
        let up = runner.requests[0]
        #expect(up.arguments.suffix(4) == ["up", "--detach", "--remove-orphans", "--yes"][...])
        #expect(up.arguments.containsSubsequence(["--project-name", "demo"]))
        #expect(up.arguments.containsSubsequence(["--env-file", environmentFile.path]))
        #expect(!up.arguments.contains("*"))
        #expect(up.timeout == 2 * 60 * 60)
        #expect(up.outputPolicy == .tail(maxBytes: 512 * 1024))

        let down = runner.requests[1]
        #expect(down.arguments.containsSubsequence(["--project-name", "demo"]))
        #expect(down.arguments.containsSubsequence(["--profile", "*"]))
        #expect(down.arguments.suffix(2) == ["down", "--remove-orphans"][...])
        #expect(down.timeout == 10 * 60)
        #expect(down.outputPolicy == .tail(maxBytes: 512 * 1024))
    }

    @Test func projectLifecycleOperationsUseComposeAndProtectServiceArguments() async throws {
        let fixture = try ComposeFixture()
        defer { fixture.remove() }
        let runner = ScriptedComposeRunner([
            .success(.init(terminationStatus: 0, stdout: "", stderr: "", outputTruncated: false)),
            .success(.init(terminationStatus: 0, stdout: "", stderr: "", outputTruncated: false)),
            .success(.init(terminationStatus: 0, stdout: "", stderr: "", outputTruncated: false)),
        ])
        let cli = testCLI(runner: runner)
        let context = ComposeProjectContext(
            name: "demo",
            files: [fixture.base],
            workingDirectory: fixture.directory,
            environmentFiles: []
        )

        try await cli.perform(.start, context: context)
        try await cli.perform(.stop, context: context)
        try await cli.perform(.restart, context: context, services: ["--debug", "web"])

        #expect(runner.requests[0].arguments.suffix(1) == ["start"][...])
        #expect(runner.requests[1].arguments.suffix(1) == ["stop"][...])
        #expect(runner.requests[2].arguments.suffix(4) == ["restart", "--", "--debug", "web"][...])
        for request in runner.requests {
            #expect(request.arguments.containsSubsequence(["--profile", "*"]))
            #expect(request.timeout == 10 * 60)
            #expect(request.outputPolicy == .tail(maxBytes: 512 * 1024))
        }
    }

    @Test func recoversRestartSafeContextFromExactComposeLabels() throws {
        let first = composeContainer(
            id: "1",
            name: "demo-web-1",
            labels: [
                ComposeCLI.projectLabel: "demo",
                ComposeCLI.workingDirectoryLabel: "/Users/test/project",
                ComposeCLI.configFilesLabel: "/Users/test/project/compose.yaml,/Users/test/project/compose.override.yaml",
                ComposeCLI.environmentFileLabel: "/Users/test/project/release.env",
            ]
        )
        let second = composeContainer(
            id: "2",
            name: "demo-db-1",
            labels: [
                ComposeCLI.projectLabel: "demo",
                ComposeCLI.workingDirectoryLabel: "/Users/test/project",
                ComposeCLI.configFilesLabel: "/Users/test/project/compose.yaml",
                ComposeCLI.environmentFileLabel: "/Users/test/project/release.env",
            ]
        )
        let unrelatedPrefix = composeContainer(id: "3", name: "demo-unrelated-1", labels: [:])

        let context = try ComposeCLI.context(
            projectName: "demo",
            containers: [first, second, unrelatedPrefix]
        )

        #expect(context.name == "demo")
        #expect(context.workingDirectory.path == "/Users/test/project")
        #expect(context.files.map(\.path) == [
            "/Users/test/project/compose.yaml",
            "/Users/test/project/compose.override.yaml",
        ])
        #expect(context.environmentFiles.map(\.path) == ["/Users/test/project/release.env"])
    }

    @Test func metadataRecoveryFailsClosedInsteadOfUsingNamePrefixes() {
        let prefixOnly = composeContainer(id: "1", name: "demo-web-1", labels: [:])
        #expect(throws: ComposeCLIError.self) {
            try ComposeCLI.context(projectName: "demo", containers: [prefixOnly])
        }
    }

    @Test func metadataRecoveryRejectsMissingConflictingOrRelativeOwnership() {
        let missingWorkingDirectory = composeContainer(id: "1", name: "web", labels: [
            ComposeCLI.projectLabel: "demo",
            ComposeCLI.configFilesLabel: "/a/compose.yaml",
        ])
        #expect(throws: ComposeCLIError.self) {
            try ComposeCLI.context(projectName: "demo", containers: [missingWorkingDirectory])
        }

        let first = composeContainer(id: "1", name: "web", labels: [
            ComposeCLI.projectLabel: "demo",
            ComposeCLI.workingDirectoryLabel: "/a",
            ComposeCLI.configFilesLabel: "/a/compose.yaml",
        ])
        let second = composeContainer(id: "2", name: "db", labels: [
            ComposeCLI.projectLabel: "demo",
            ComposeCLI.workingDirectoryLabel: "/b",
            ComposeCLI.configFilesLabel: "/b/compose.yaml",
        ])
        #expect(throws: ComposeCLIError.self) {
            try ComposeCLI.context(projectName: "demo", containers: [first, second])
        }

        let relative = composeContainer(id: "3", name: "api", labels: [
            ComposeCLI.projectLabel: "demo",
            ComposeCLI.workingDirectoryLabel: "/a",
            ComposeCLI.configFilesLabel: "compose.yaml",
        ])
        #expect(throws: ComposeCLIError.self) {
            try ComposeCLI.context(projectName: "demo", containers: [relative])
        }
    }

    @Test func projectNamesAreRestrictedToComposeASCIIContract() {
        for name in ["Demo", "-demo", "démo", "demo.stack", ""] {
            #expect(throws: ComposeCLIError.self) {
                try ComposeCLI.context(projectName: name, containers: [])
            }
        }
    }

    @Test func selectedFileOverridesHostComposeFileAndAddsOnlyCanonicalOverride() throws {
        let fixture = try ComposeFixture()
        defer { fixture.remove() }
        let prod = fixture.directory.appendingPathComponent("compose.prod.yaml")
        try Data("services: {}\n".utf8).write(to: prod)

        #expect(AppStore.composeFileURLs(for: fixture.base) == [fixture.base, fixture.override])
        #expect(!AppStore.composeFileURLs(for: fixture.base).contains(prod))
    }

    @MainActor
    @Test func appStoreRejectsOverlappingComposeMutations() async {
        let runner = ScriptedComposeRunner([])
        let store = AppStore(
            runtime: DockerEngineRuntime(socketPath: "/tmp/dory-compose-busy.sock"),
            environment: ["XCTestConfigurationFilePath": "DoryTests"],
            composeCommandRunner: runner
        )
        store.composeBusy = true

        await store.composeUp(fileURL: URL(fileURLWithPath: "/tmp/compose.yaml"))
        #expect(store.actionError == "Another Compose operation is already running")

        store.actionError = nil
        await store.composeDown("demo")
        #expect(store.actionError == "Another Compose operation is already running")
        #expect(runner.requests.isEmpty)
    }

    @Test func failuresAreCategorizedWithoutEchoingCommandOutputOrSecrets() {
        #expect(ComposeCLI.failureReason(stderr: "Bind for 0.0.0.0 failed: port is already allocated", stdout: "")
            == "a requested host port is already in use")
        #expect(ComposeCLI.failureReason(stderr: "pull access denied", stdout: "")
            == "registry authentication failed")
        #expect(ComposeCLI.failureReason(stderr: "no space left on device", stdout: "")
            == "the Docker data drive is out of space")
        #expect(ComposeCLI.failureReason(stderr: "failed to solve: command failed", stdout: "")
            == "an image build failed")
        #expect(ComposeCLI.failureReason(stderr: "Cannot connect to the Docker daemon", stdout: "")
            == "the Docker engine became unavailable")

        let secret = "super-secret-value"
        let generic = ComposeCLI.failureReason(
            stderr: "unexpected failure password=\(secret)",
            stdout: "token=\(secret)"
        )
        #expect(!generic.contains(secret))
        #expect(!generic.contains("password"))
        #expect(!generic.contains("token"))
    }

    @Test func resolveRejectsMissingFilesInvalidMetadataAndTruncation() async throws {
        let fixture = try ComposeFixture()
        defer { fixture.remove() }

        let missingRunner = ScriptedComposeRunner([])
        let missingCLI = testCLI(runner: missingRunner)
        await #expect(throws: ComposeCLIError.self) {
            try await missingCLI.resolve(files: [fixture.directory.appendingPathComponent("missing.yaml")])
        }
        #expect(missingRunner.requests.isEmpty)

        let invalidRunner = ScriptedComposeRunner([
            .success(.init(terminationStatus: 0, stdout: "not-json", stderr: "", outputTruncated: false)),
        ])
        await #expect(throws: ComposeCLIError.self) {
            try await testCLI(runner: invalidRunner).resolve(files: [fixture.base])
        }

        let truncatedRunner = ScriptedComposeRunner([
            .success(.init(terminationStatus: 0, stdout: #"{"name":"demo"}"#, stderr: "", outputTruncated: true)),
        ])
        await #expect(throws: ComposeCLIError.self) {
            try await testCLI(runner: truncatedRunner).resolve(files: [fixture.base])
        }
    }

    @Test func processRunnerDrainsLargeConcurrentStreamsAndKeepsBoundedTails() async throws {
        let script = """
        i=0
        while [ "$i" -lt 12000 ]; do
          printf 'stdout-%05d-xxxxxxxxxxxxxxxx\\n' "$i"
          printf 'stderr-%05d-yyyyyyyyyyyyyyyy\\n' "$i" >&2
          i=$((i + 1))
        done
        """
        let result = try await BoundedToolProcessRunner().run(processRequest(
            executable: "/bin/sh",
            arguments: ["-c", script],
            timeout: 15,
            policy: .tail(maxBytes: 4096)
        ))

        #expect(result.terminationStatus == 0)
        #expect(result.outputTruncated)
        #expect(result.stdout.utf8.count <= 4096)
        #expect(result.stderr.utf8.count <= 4096)
        #expect(result.stdout.contains("stdout-11999"))
        #expect(result.stderr.contains("stderr-11999"))
    }

    @Test func processRunnerTimesOutAndCancellationStopsTheChild() async throws {
        await #expect(throws: ToolProcessError.self) {
            try await BoundedToolProcessRunner().run(processRequest(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
                timeout: 0.1,
                policy: .tail(maxBytes: 1024)
            ))
        }

        let task = Task {
            try await BoundedToolProcessRunner().run(processRequest(
                executable: "/bin/sleep",
                arguments: ["30"],
                timeout: 60,
                policy: .tail(maxBytes: 1024)
            ))
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        for _ in 0..<20 {
            let launchWindowTask = Task {
                try await BoundedToolProcessRunner().run(processRequest(
                    executable: "/bin/sleep",
                    arguments: ["30"],
                    timeout: 5,
                    policy: .tail(maxBytes: 1024)
                ))
            }
            await Task.yield()
            launchWindowTask.cancel()
            await #expect(throws: CancellationError.self) { try await launchWindowTask.value }
        }
    }

    @Test func processRunnerNeverInterpretsArgumentsThroughAShell() async throws {
        let literal = "$(touch /tmp/dory-compose-must-not-exist);$HOME;*"
        try? FileManager.default.removeItem(atPath: "/tmp/dory-compose-must-not-exist")
        let result = try await BoundedToolProcessRunner().run(processRequest(
            executable: "/usr/bin/printf",
            arguments: ["%s", literal],
            timeout: 5,
            policy: .complete(maxBytes: 4096)
        ))
        defer { try? FileManager.default.removeItem(atPath: "/tmp/dory-compose-must-not-exist") }

        #expect(result.terminationStatus == 0)
        #expect(result.stdout == literal)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/dory-compose-must-not-exist"))
    }

    @Test func processRunnerStreamsBothPipesBeforeReturningTheBoundedResult() async throws {
        let streamed = LockedToolStreams()
        var request = processRequest(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'out-one\\nout-two\\n'; printf 'err-one\\n' >&2"],
            timeout: 5,
            policy: .tail(maxBytes: 4096)
        )
        request.outputHandler = { stream, data in streamed.append(data, to: stream) }

        let result = try await BoundedToolProcessRunner().run(request)

        #expect(result.terminationStatus == 0)
        #expect(streamed.stdout == "out-one\nout-two\n")
        #expect(streamed.stderr == "err-one\n")
    }

    private func testCLI(runner: any ToolCommandRunning) -> ComposeCLI {
        ComposeCLI(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketPath: "/tmp/dory.sock",
            baseEnvironment: [:],
            runner: runner
        )
    }

    private func processRequest(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        policy: ToolCommandRequest.OutputPolicy
    ) -> ToolCommandRequest {
        ToolCommandRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: timeout,
            outputPolicy: policy
        )
    }
}

nonisolated private final class LockedToolStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    func append(_ data: Data, to stream: ToolProcessStream) {
        lock.lock()
        switch stream {
        case .stdout: stdoutData.append(data)
        case .stderr: stderrData.append(data)
        }
        lock.unlock()
    }

    var stdout: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stdoutData, as: UTF8.self)
    }

    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }
}

nonisolated private final class ScriptedComposeRunner: ToolCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<ToolCommandResult, Error>]
    private var recorded: [ToolCommandRequest] = []

    init(_ results: [Result<ToolCommandResult, Error>]) {
        self.results = results
    }

    var requests: [ToolCommandRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ request: ToolCommandRequest) async throws -> ToolCommandResult {
        try nextResult(for: request).get()
    }

    private func nextResult(for request: ToolCommandRequest) -> Result<ToolCommandResult, Error> {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        return results.isEmpty
            ? .failure(ToolProcessError.launch("unexpected invocation"))
            : results.removeFirst()
    }
}

nonisolated private struct ComposeFixture {
    let directory: URL
    let base: URL
    let override: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-compose-cli-\(UUID().uuidString)", isDirectory: true)
        base = directory.appendingPathComponent("compose.yaml")
        override = directory.appendingPathComponent("compose.override.yaml")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("services: {}\n".utf8).write(to: base)
        try Data("services: {}\n".utf8).write(to: override)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

nonisolated private func composeContainer(id: String, name: String, labels: [String: String]) -> Container {
    Container(
        id: id,
        name: name,
        image: "busybox:latest",
        status: .running,
        cpuPercent: 0,
        memoryDisplay: "0 MB",
        memoryLimitDisplay: "—",
        memoryFraction: 0,
        ports: "—",
        uptime: "now",
        created: "now",
        ipAddress: "",
        domain: "",
        command: "true",
        restartPolicy: "no",
        labels: labels
    )
}

nonisolated private extension Array where Element == String {
    func containsSubsequence(_ values: [String]) -> Bool {
        guard !values.isEmpty, values.count <= count else { return false }
        return indices.dropLast(values.count - 1).contains { index in
            Array(self[index..<(index + values.count)]) == values
        }
    }
}
