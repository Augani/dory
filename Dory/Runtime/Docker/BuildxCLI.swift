import Foundation

nonisolated enum BuildxCLIError: Error, LocalizedError, Sendable, Equatable {
    case helperUnavailable
    case socketUnavailable
    case missingContext(String)
    case missingDockerfile(String)
    case commandFailed(Int32)
    case activityQueryFailed(Int32)
    case malformedActivity
    case activityOutputTooLarge

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "Dory's signed Docker Buildx helper is missing"
        case .socketUnavailable:
            "The active Docker engine does not expose a usable socket"
        case .missingContext(let path):
            "The build context is not a readable folder: \(path)"
        case .missingDockerfile(let path):
            "No Dockerfile was found at \(path)"
        case .commandFailed(let status):
            "Image build failed (exit \(status)); review the build output above"
        case .activityQueryFailed(let status):
            "Build activity is unavailable (Buildx exit \(status))"
        case .malformedActivity:
            "Buildx returned an invalid activity record"
        case .activityOutputTooLarge:
            "Build activity exceeded Dory's bounded local display limit"
        }
    }
}

/// Runs Dory's bundled Buildx against Dory's exact engine socket. Build contexts stream directly
/// from disk through BuildKit, so `.dockerignore` is honored without packaging the folder in RAM.
nonisolated struct BuildxCLI {
    let executableURL: URL
    let socketPath: String
    let baseEnvironment: [String: String]
    let runner: any ToolCommandRunning

    func build(
        contextDirectory rawContext: URL,
        tag rawTag: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let context = rawContext.standardizedFileURL
        try validate(context: context)

        var arguments = [
            "--builder", "default",
            "build",
            "--progress", "plain",
            "--load",
        ]
        let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tag.isEmpty { arguments += ["--tag", tag] }
        arguments += ["--", context.path]

        let output = BuildxOutputForwarder(onLine: onOutput)
        defer { output.flush() }
        let result = try await runner.run(ToolCommandRequest(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectoryURL: context,
            environment: childEnvironment,
            timeout: 2 * 60 * 60,
            outputPolicy: .tail(maxBytes: 512 * 1024),
            outputHandler: { stream, data in output.receive(data, from: stream) }
        ))
        guard result.terminationStatus == 0 else {
            throw BuildxCLIError.commandFailed(result.terminationStatus)
        }
    }

    func history() async throws -> [BuildActivityRecord] {
        let result = try await query(
            arguments: ["--builder", "default", "history", "ls", "--format", "json", "--no-trunc"],
            timeout: 20,
            maximumBytes: 4 * 1024 * 1024
        )
        do { return try BuildActivityParser.history(result.stdout) }
        catch { throw BuildxCLIError.malformedActivity }
    }

    func logs(ref: String) async throws -> String {
        guard !ref.isEmpty, !ref.hasPrefix("-") else { throw BuildxCLIError.malformedActivity }
        let result = try await query(
            arguments: ["--builder", "default", "history", "logs", ref],
            timeout: 30,
            maximumBytes: 2 * 1024 * 1024
        )
        let combined = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return combined.isEmpty ? "No retained log is available for this build." : combined
    }

    func cacheUsage() async throws -> BuildCacheUsage {
        let result = try await query(
            arguments: ["--builder", "default", "du", "--format", "json", "--timeout", "20s"],
            timeout: 30,
            maximumBytes: 16 * 1024 * 1024
        )
        do { return try BuildActivityParser.cache(result.stdout) }
        catch { throw BuildxCLIError.malformedActivity }
    }

    private func query(arguments: [String], timeout: TimeInterval, maximumBytes: Int) async throws -> ToolCommandResult {
        guard socketPath.hasPrefix("/"), !socketPath.isEmpty else { throw BuildxCLIError.socketUnavailable }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw BuildxCLIError.helperUnavailable }
        let result = try await runner.run(ToolCommandRequest(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            environment: childEnvironment,
            timeout: timeout,
            outputPolicy: .complete(maxBytes: maximumBytes)
        ))
        guard !result.outputTruncated else { throw BuildxCLIError.activityOutputTooLarge }
        guard result.terminationStatus == 0 else { throw BuildxCLIError.activityQueryFailed(result.terminationStatus) }
        return result
    }

    private func validate(context: URL) throws {
        guard socketPath.hasPrefix("/"), !socketPath.isEmpty else {
            throw BuildxCLIError.socketUnavailable
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw BuildxCLIError.helperUnavailable
        }
        var isDirectory: ObjCBool = false
        guard context.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: context.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BuildxCLIError.missingContext(context.path)
        }
        let dockerfile = context.appendingPathComponent("Dockerfile", isDirectory: false)
        var dockerfileIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dockerfile.path, isDirectory: &dockerfileIsDirectory),
              !dockerfileIsDirectory.boolValue else {
            throw BuildxCLIError.missingDockerfile(dockerfile.path)
        }
    }

    private var childEnvironment: [String: String] {
        var environment = baseEnvironment
        for key in Self.ambientControlEnvironmentKeys { environment.removeValue(forKey: key) }
        environment["DOCKER_HOST"] = "unix://\(socketPath)"
        environment["BUILDKIT_PROGRESS"] = "plain"
        environment["NO_COLOR"] = "1"
        let helpers = executableURL.deletingLastPathComponent().path
        let existing = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }
        environment["PATH"] = ([helpers, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            + (existing.map { [$0] } ?? []))
            .joined(separator: ":")
        return environment
    }

    /// A GUI build is bound to the selected context, Dory's default builder, and the explicit
    /// progress policy above. Registry credentials in `DOCKER_CONFIG` remain available.
    private static let ambientControlEnvironmentKeys = [
        "DOCKER_API_VERSION",
        "DOCKER_AUTH_CONFIG",
        "DOCKER_CERT_PATH",
        "DOCKER_CONTEXT",
        "DOCKER_CUSTOM_HEADERS",
        "DOCKER_DEFAULT_PLATFORM",
        "DOCKER_HOST",
        "DOCKER_TLS",
        "DOCKER_TLS_VERIFY",
        "BUILDKIT_COLORS",
        "BUILDKIT_HOST",
        "BUILDKIT_PROGRESS",
        "BUILDX_BUILDER",
        "BUILDX_CONFIG",
        "BUILDX_CPU_PROFILE",
        "BUILDX_EXPERIMENTAL",
        "BUILDX_GIT_CHECK_DIRTY",
        "BUILDX_GIT_INFO",
        "BUILDX_GIT_LABELS",
        "BUILDX_MEM_PROFILE",
        "BUILDX_METADATA_PROVENANCE",
        "BUILDX_METADATA_WARNINGS",
        "BUILDX_NO_DEFAULT_ATTESTATIONS",
        "BUILDX_NO_DEFAULT_LOAD",
        "EXPERIMENTAL_BUILDKIT_SOURCE_POLICY",
    ]
}

nonisolated private final class BuildxOutputForwarder: @unchecked Sendable {
    private static let maximumPartialLineBytes = 32 * 1024

    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void
    private var stdout = Data()
    private var stderr = Data()

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func receive(_ data: Data, from stream: ToolProcessStream) {
        let lines: [String]
        lock.lock()
        switch stream {
        case .stdout:
            stdout.append(data)
            lines = Self.takeCompleteLines(from: &stdout)
        case .stderr:
            stderr.append(data)
            lines = Self.takeCompleteLines(from: &stderr)
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        let lines: [String]
        lock.lock()
        lines = Self.takeCompleteLines(from: &stdout, flush: true)
            + Self.takeCompleteLines(from: &stderr, flush: true)
        lock.unlock()
        lines.forEach(onLine)
    }

    private static func takeCompleteLines(from buffer: inout Data, flush: Bool = false) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            lines.append(decode(line))
        }
        while buffer.count > maximumPartialLineBytes {
            let line = Data(buffer.prefix(maximumPartialLineBytes))
            buffer.removeFirst(maximumPartialLineBytes)
            lines.append(decode(line) + "…")
        }
        if flush, !buffer.isEmpty {
            lines.append(decode(buffer))
            buffer.removeAll(keepingCapacity: false)
        }
        return lines
    }

    private static func decode(_ data: Data) -> String {
        var data = data
        if data.last == 0x0D { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }
}
