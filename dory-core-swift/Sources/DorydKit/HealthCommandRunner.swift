import Darwin
import Foundation

public struct HealthCommandOutput: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var launchError: String?

    public init(exitCode: Int32, stdout: String, stderr: String, launchError: String? = nil) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.launchError = launchError
    }
}

public protocol HealthCommandRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> HealthCommandOutput
}

public final class ProcessHealthCommandRunner: HealthCommandRunning, @unchecked Sendable {
    public init() {}

    public func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> HealthCommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let stdoutURL = temporaryDirectory.appendingPathComponent("dory-health-stdout-\(UUID().uuidString).log")
        let stderrURL = temporaryDirectory.appendingPathComponent("dory-health-stderr-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
              let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            return HealthCommandOutput(exitCode: 127, stdout: "", stderr: "", launchError: "could not create command output files")
        }
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            return HealthCommandOutput(exitCode: 127, stdout: "", stderr: "", launchError: "\(error)")
        }

        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()
        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        var stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        if process.terminationReason == .uncaughtSignal, stderr.isEmpty {
            stderr = "command timed out after \(Int(timeout))s"
        }

        return HealthCommandOutput(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}
