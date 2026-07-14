import Foundation

nonisolated struct ComposeProjectContext: Sendable, Equatable {
    let name: String
    let files: [URL]
    let workingDirectory: URL
    let environmentFiles: [URL]
}

nonisolated enum ComposeProjectOperation: String, Sendable, Equatable {
    case start
    case stop
    case restart
}

nonisolated enum ComposeCLIError: Error, LocalizedError, Sendable, Equatable {
    case helperUnavailable
    case socketUnavailable
    case missingFile(String)
    case invalidMetadata(String)
    case ambiguousMetadata(String)
    case outputTooLarge
    case commandFailed(action: String, status: Int32, reason: String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "Dory's signed Docker Compose helper is missing"
        case .socketUnavailable:
            "The active Docker engine does not expose a usable socket"
        case .missingFile(let path):
            "A required Compose file is missing: \(path)"
        case .invalidMetadata(let message), .ambiguousMetadata(let message):
            message
        case .outputTooLarge:
            "The resolved Compose model is larger than Dory's 32 MB validation limit"
        case .commandFailed(let action, let status, let reason):
            "Compose \(action) failed (exit \(status)): \(reason)"
        }
    }
}

nonisolated struct ComposeCLI {
    static let projectLabel = "com.docker.compose.project"
    static let workingDirectoryLabel = "com.docker.compose.project.working_dir"
    static let configFilesLabel = "com.docker.compose.project.config_files"
    static let environmentFileLabel = "com.docker.compose.project.environment_file"

    let executableURL: URL
    let socketPath: String
    let baseEnvironment: [String: String]
    let runner: any ToolCommandRunning

    func resolve(files: [URL]) async throws -> ComposeProjectContext {
        let files = try validatedFiles(files)
        let workingDirectory = files[0].deletingLastPathComponent().standardizedFileURL
        try validateExecutableAndSocket()
        let context = ComposeProjectContext(
            name: "",
            files: files,
            workingDirectory: workingDirectory,
            environmentFiles: []
        )
        let result = try await runner.run(request(
            context: context,
            arguments: ["config", "--format", "json"],
            timeout: 60,
            outputPolicy: .complete(maxBytes: 32 * 1024 * 1024),
            includeProjectName: false,
            allProfiles: false
        ))
        try check(result, action: "validation")
        guard !result.outputTruncated else { throw ComposeCLIError.outputTooLarge }
        struct Metadata: Decodable { let name: String }
        guard let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(result.stdout.utf8)),
              Self.isValidProjectName(metadata.name) else {
            throw ComposeCLIError.invalidMetadata("Docker Compose did not return a valid project name")
        }
        return ComposeProjectContext(
            name: metadata.name,
            files: files,
            workingDirectory: workingDirectory,
            environmentFiles: []
        )
    }

    func up(_ context: ComposeProjectContext) async throws {
        try validate(context)
        let result = try await runner.run(request(
            context: context,
            arguments: ["up", "--detach", "--remove-orphans", "--yes"],
            timeout: 2 * 60 * 60,
            outputPolicy: .tail(maxBytes: 512 * 1024),
            includeProjectName: true,
            allProfiles: false
        ))
        try check(result, action: "up")
    }

    func down(_ context: ComposeProjectContext) async throws {
        try validate(context)
        let result = try await runner.run(request(
            context: context,
            arguments: ["down", "--remove-orphans"],
            timeout: 10 * 60,
            outputPolicy: .tail(maxBytes: 512 * 1024),
            includeProjectName: true,
            allProfiles: true
        ))
        try check(result, action: "down")
    }

    func perform(
        _ operation: ComposeProjectOperation,
        context: ComposeProjectContext,
        services: [String] = []
    ) async throws {
        try validate(context)
        let result = try await runner.run(request(
            context: context,
            arguments: [operation.rawValue] + (services.isEmpty ? [] : ["--"] + services),
            timeout: 10 * 60,
            outputPolicy: .tail(maxBytes: 512 * 1024),
            includeProjectName: true,
            allProfiles: true
        ))
        try check(result, action: operation.rawValue)
    }

    static func context(projectName: String, containers: [Container]) throws -> ComposeProjectContext {
        guard isValidProjectName(projectName) else {
            throw ComposeCLIError.invalidMetadata("The Compose project label is invalid")
        }
        let members = containers.filter { $0.labels[projectLabel] == projectName }
        guard !members.isEmpty else {
            throw ComposeCLIError.invalidMetadata("No containers carry the exact Compose project label \(projectName)")
        }

        guard members.allSatisfy({ !($0.labels[workingDirectoryLabel] ?? "").isEmpty }) else {
            throw ComposeCLIError.invalidMetadata(
                "Compose project \(projectName) is missing its working-directory labels; no resources were changed"
            )
        }
        let directories = Set(members.compactMap { $0.labels[workingDirectoryLabel] })
        guard directories.count == 1, let directory = directories.first, directory.hasPrefix("/") else {
            throw ComposeCLIError.ambiguousMetadata(
                "Compose project \(projectName) has missing or conflicting working-directory labels; no resources were changed"
            )
        }
        guard members.allSatisfy({ !($0.labels[configFilesLabel] ?? "").isEmpty }) else {
            throw ComposeCLIError.invalidMetadata(
                "Compose project \(projectName) is missing its config-file labels; no resources were changed"
            )
        }

        let files = try uniqueLabelPaths(members.compactMap { $0.labels[configFilesLabel] })
        guard !files.isEmpty else {
            throw ComposeCLIError.invalidMetadata(
                "Compose project \(projectName) has no recoverable config files; no resources were changed"
            )
        }
        guard files.allSatisfy({ $0.hasPrefix("/") }) else {
            throw ComposeCLIError.invalidMetadata(
                "Compose project \(projectName) has non-absolute config-file labels; no resources were changed"
            )
        }
        let environmentFiles = try uniqueLabelPaths(members.compactMap { $0.labels[environmentFileLabel] })
        guard environmentFiles.allSatisfy({ $0.hasPrefix("/") }) else {
            throw ComposeCLIError.invalidMetadata(
                "Compose project \(projectName) has non-absolute environment-file labels; no resources were changed"
            )
        }
        return ComposeProjectContext(
            name: projectName,
            files: files.map { URL(fileURLWithPath: $0).standardizedFileURL },
            workingDirectory: URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL,
            environmentFiles: environmentFiles.map { URL(fileURLWithPath: $0).standardizedFileURL }
        )
    }

    private func request(
        context: ComposeProjectContext,
        arguments commandArguments: [String],
        timeout: TimeInterval,
        outputPolicy: ToolCommandRequest.OutputPolicy,
        includeProjectName: Bool,
        allProfiles: Bool
    ) -> ToolCommandRequest {
        var arguments = ["--ansi", "never", "--progress", "plain"]
        arguments += ["--project-directory", context.workingDirectory.path]
        for environmentFile in context.environmentFiles {
            arguments += ["--env-file", environmentFile.path]
        }
        for file in context.files { arguments += ["--file", file.path] }
        if includeProjectName { arguments += ["--project-name", context.name] }
        if allProfiles { arguments += ["--profile", "*"] }
        arguments += commandArguments
        return ToolCommandRequest(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectoryURL: context.workingDirectory,
            environment: childEnvironment,
            timeout: timeout,
            outputPolicy: outputPolicy
        )
    }

    private var childEnvironment: [String: String] {
        var environment = baseEnvironment
        environment["DOCKER_HOST"] = "unix://\(socketPath)"
        for key in Self.ambientControlEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment["COMPOSE_MENU"] = "0"
        let helpers = executableURL.deletingLastPathComponent().path
        let existing = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }
        environment["PATH"] = ([helpers, "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + (existing.map { [$0] } ?? []))
            .joined(separator: ":")
        return environment
    }

    /// GUI actions are derived from the selected project, not from control variables inherited
    /// when somebody launches Dory from a terminal. Variables loaded from the project's own .env
    /// file remain authoritative under normal Compose precedence.
    private static let ambientControlEnvironmentKeys = [
        "DOCKER_CONTEXT",
        "COMPOSE_FILE",
        "COMPOSE_PATH_SEPARATOR",
        "COMPOSE_PROJECT_NAME",
        "COMPOSE_PROFILES",
        "COMPOSE_ENV_FILES",
        "COMPOSE_DISABLE_ENV_FILE",
        "COMPOSE_IGNORE_ORPHANS",
        "COMPOSE_REMOVE_ORPHANS",
        "COMPOSE_ANSI",
        "COMPOSE_PROGRESS",
        "COMPOSE_STATUS_STDOUT",
        "COMPOSE_PARALLEL_LIMIT",
        "COMPOSE_BAKE",
        "COMPOSE_EXPERIMENTAL",
        "COMPOSE_MENU",
    ]

    private func validate(_ context: ComposeProjectContext) throws {
        try validateExecutableAndSocket()
        guard Self.isValidProjectName(context.name) else {
            throw ComposeCLIError.invalidMetadata("The Compose project name is invalid")
        }
        _ = try validatedFiles(context.files + context.environmentFiles)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: context.workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ComposeCLIError.missingFile(context.workingDirectory.path)
        }
    }

    private func validateExecutableAndSocket() throws {
        guard socketPath.hasPrefix("/"), !socketPath.isEmpty else { throw ComposeCLIError.socketUnavailable }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ComposeCLIError.helperUnavailable
        }
    }

    private func validatedFiles(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty else { throw ComposeCLIError.invalidMetadata("No Compose file was selected") }
        var seen = Set<String>()
        var result: [URL] = []
        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard url.path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw ComposeCLIError.missingFile(url.path)
            }
            if seen.insert(url.path).inserted { result.append(url) }
        }
        return result
    }

    private func check(_ result: ToolCommandResult, action: String) throws {
        guard result.terminationStatus != 0 else { return }
        throw ComposeCLIError.commandFailed(
            action: action,
            status: result.terminationStatus,
            reason: Self.failureReason(stderr: result.stderr, stdout: result.stdout)
        )
    }

    static func failureReason(stderr: String, stdout: String) -> String {
        let output = (stderr + "\n" + stdout).lowercased()
        if output.contains("port is already allocated") || output.contains("address already in use") {
            return "a requested host port is already in use"
        }
        if output.contains("unauthorized") || output.contains("authentication required")
            || output.contains("denied: requested access") || output.contains("pull access denied") {
            return "registry authentication failed"
        }
        if output.contains("no space left on device") { return "the Docker data drive is out of space" }
        if output.contains("no such file or directory") || output.contains("env file") && output.contains("not found") {
            return "a referenced file or bind-mount path is missing"
        }
        if output.contains("failed to solve") || output.contains("build failed") {
            return "an image build failed"
        }
        if output.contains("is invalid") || output.contains("validating ") || output.contains("undefined service") {
            return "the Compose model is invalid"
        }
        if output.contains("cannot connect") || output.contains("connection refused") {
            return "the Docker engine became unavailable"
        }
        return "Docker Compose reported an error; command output was withheld to avoid exposing environment or secret values"
    }

    private static func uniqueLabelPaths(_ labels: [String]) throws -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for label in labels {
            let components = label.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard components.allSatisfy({ !$0.isEmpty }) else {
                throw ComposeCLIError.invalidMetadata(
                    "Compose project metadata contains an empty file path; no resources were changed"
                )
            }
            for path in components where seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths
    }

    private static func isValidProjectName(_ name: String) -> Bool {
        guard let first = name.utf8.first,
              (first >= Character("a").asciiValue! && first <= Character("z").asciiValue!)
                || (first >= Character("0").asciiValue! && first <= Character("9").asciiValue!) else {
            return false
        }
        return name.utf8.allSatisfy {
            ($0 >= Character("a").asciiValue! && $0 <= Character("z").asciiValue!)
                || ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
                || $0 == Character("-").asciiValue! || $0 == Character("_").asciiValue!
        }
    }
}
