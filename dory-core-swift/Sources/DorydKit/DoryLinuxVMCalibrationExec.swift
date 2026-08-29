import Darwin
import DoryCore
import Foundation

/// A bounded, calibration-only command sent directly to the isolated VM's guest-agent socket.
///
/// This is intentionally separate from machine management and production launch authority. It
/// cannot discover a VM, start doryd, or select a socket from Dory's production state.
public struct DoryLinuxVMCalibrationExecConfiguration: Sendable, Equatable {
    public static let defaultTimeoutMs: UInt64 = 30_000
    public static let maximumTimeoutMs: UInt64 = 10 * 60_000
    public static let defaultOutputLimitBytes: UInt64 = 1_024 * 1_024
    public static let maximumOutputLimitBytes: UInt64 = 16 * 1_024 * 1_024

    public var agentSocketPath: String
    public var timeoutMs: UInt64
    public var outputLimitBytes: UInt64
    public var argv: [String]

    public init(
        agentSocketPath: String,
        timeoutMs: UInt64 = Self.defaultTimeoutMs,
        outputLimitBytes: UInt64 = Self.defaultOutputLimitBytes,
        argv: [String]
    ) {
        self.agentSocketPath = agentSocketPath
        self.timeoutMs = timeoutMs
        self.outputLimitBytes = outputLimitBytes
        self.argv = argv
    }
}

public enum DoryLinuxVMCalibrationExecError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidArguments(String)
    case unsafeSocketPath(String)
    case socketUnavailable(String)

    public var description: String {
        switch self {
        case .invalidArguments(let detail):
            "invalid Linux calibration exec arguments: \(detail)"
        case .unsafeSocketPath(let detail):
            "unsafe Linux calibration agent socket path: \(detail)"
        case .socketUnavailable(let detail):
            "Linux calibration agent socket is unavailable: \(detail)"
        }
    }
}

/// Parser and direct guest-agent transport for `dory-linux-calibration exec`.
public enum DoryLinuxVMCalibrationExec {
    private static let maximumArgumentCount = 256
    private static let maximumArgumentBytes = 64 * 1_024

    private struct Receipt: Encodable {
        let exitCode: Int32
        let stderr: String
        let stderrTruncated: Bool
        let stdout: String
        let stdoutTruncated: Bool
        let timedOut: Bool

        init(_ result: DoryExecResult) {
            exitCode = result.exitCode
            stderr = String(decoding: result.stderr, as: UTF8.self)
            stderrTruncated = result.stderrTruncated
            stdout = String(decoding: result.stdout, as: UTF8.self)
            stdoutTruncated = result.stdoutTruncated
            timedOut = result.timedOut
        }
    }

    /// Parses the tokens following the `exec` command. A literal `--` is mandatory so command
    /// arguments can never be mistaken for calibration control options.
    public static func parse(
        arguments: [String]
    ) throws -> DoryLinuxVMCalibrationExecConfiguration {
        guard let separator = arguments.firstIndex(of: "--") else {
            throw DoryLinuxVMCalibrationExecError.invalidArguments(
                "missing -- before the guest command"
            )
        }

        let optionTokens = Array(arguments[..<separator])
        let argv = Array(arguments[arguments.index(after: separator)...])
        guard !argv.isEmpty else {
            throw DoryLinuxVMCalibrationExecError.invalidArguments(
                "the guest command is empty"
            )
        }
        guard optionTokens.count.isMultiple(of: 2) else {
            throw DoryLinuxVMCalibrationExecError.invalidArguments(
                "every exec option requires one value"
            )
        }

        let allowedOptions: Set<String> = [
            "--agent-socket",
            "--timeout-ms",
            "--output-limit-bytes",
        ]
        var values: [String: String] = [:]
        var index = 0
        while index < optionTokens.count {
            let option = optionTokens[index]
            guard allowedOptions.contains(option) else {
                throw DoryLinuxVMCalibrationExecError.invalidArguments(
                    "unknown option \(option)"
                )
            }
            guard values[option] == nil else {
                throw DoryLinuxVMCalibrationExecError.invalidArguments(
                    "duplicate option \(option)"
                )
            }
            values[option] = optionTokens[index + 1]
            index += 2
        }

        guard let agentSocketPath = values["--agent-socket"], !agentSocketPath.isEmpty else {
            throw DoryLinuxVMCalibrationExecError.invalidArguments(
                "missing --agent-socket"
            )
        }
        let timeoutMs = try positiveBoundedInteger(
            values["--timeout-ms"],
            option: "--timeout-ms",
            fallback: DoryLinuxVMCalibrationExecConfiguration.defaultTimeoutMs,
            maximum: DoryLinuxVMCalibrationExecConfiguration.maximumTimeoutMs
        )
        let outputLimitBytes = try positiveBoundedInteger(
            values["--output-limit-bytes"],
            option: "--output-limit-bytes",
            fallback: DoryLinuxVMCalibrationExecConfiguration.defaultOutputLimitBytes,
            maximum: DoryLinuxVMCalibrationExecConfiguration.maximumOutputLimitBytes
        )
        let configuration = DoryLinuxVMCalibrationExecConfiguration(
            agentSocketPath: agentSocketPath,
            timeoutMs: timeoutMs,
            outputLimitBytes: outputLimitBytes,
            argv: argv
        )
        try validate(configuration, requireExistingSocket: false)
        return configuration
    }

    /// Connects only to the caller-supplied local socket and executes one bounded guest command.
    public static func execute(
        _ configuration: DoryLinuxVMCalibrationExecConfiguration
    ) throws -> DoryExecResult {
        try validate(configuration, requireExistingSocket: true)
        let control = AgentControl(configuration: AgentControlConfiguration(
            directSocketPath: configuration.agentSocketPath
        ))
        defer { control.disconnect() }
        return try control.exec(
            argv: configuration.argv,
            timeoutMs: configuration.timeoutMs,
            outputLimitBytes: configuration.outputLimitBytes
        )
    }

    /// Stable compact JSON for scripts that collect physical calibration evidence.
    public static func canonicalJSON(for result: DoryExecResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Receipt(result))
    }

    /// Mirrors conventional command execution after the JSON receipt has been emitted.
    public static func processExitStatus(for result: DoryExecResult) -> Int32 {
        if result.timedOut {
            return 124
        }
        guard (0...255).contains(result.exitCode) else {
            return 1
        }
        return result.exitCode
    }

    private static func positiveBoundedInteger(
        _ raw: String?,
        option: String,
        fallback: UInt64,
        maximum: UInt64
    ) throws -> UInt64 {
        guard let raw else { return fallback }
        guard let value = UInt64(raw), value > 0, value <= maximum else {
            throw DoryLinuxVMCalibrationExecError.invalidArguments(
                "\(option) requires an integer in 1...\(maximum)"
            )
        }
        return value
    }

    private static func validate(
        _ configuration: DoryLinuxVMCalibrationExecConfiguration,
        requireExistingSocket: Bool
    ) throws {
        let path = configuration.agentSocketPath
        guard path.hasPrefix("/"), path != "/", !path.contains("\0"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw DoryLinuxVMCalibrationExecError.unsafeSocketPath(path)
        }
        let pathBytes = Array(path.utf8)
        let address = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw DoryLinuxVMCalibrationExecError.unsafeSocketPath(
                "path exceeds the local Unix-socket limit"
            )
        }
        guard configuration.timeoutMs > 0,
              configuration.timeoutMs
                <= DoryLinuxVMCalibrationExecConfiguration.maximumTimeoutMs else {
            throw DoryLinuxVMCalibrationExecError.invalidArguments(
                "--timeout-ms is outside the supported range"
            )
        }
        guard configuration.outputLimitBytes > 0,
              configuration.outputLimitBytes
                <= DoryLinuxVMCalibrationExecConfiguration.maximumOutputLimitBytes else {
            throw DoryLinuxVMCalibrationExecError.invalidArguments(
                "--output-limit-bytes is outside the supported range"
            )
        }
        guard !configuration.argv.isEmpty, configuration.argv[0].isEmpty == false else {
            throw DoryLinuxVMCalibrationExecError.invalidArguments(
                "the guest command is empty"
            )
        }
        guard configuration.argv.count <= maximumArgumentCount else {
            throw DoryLinuxVMCalibrationExecError.invalidArguments(
                "the guest command exceeds \(maximumArgumentCount) arguments"
            )
        }
        var argumentBytes = 0
        for argument in configuration.argv {
            guard !argument.contains("\0") else {
                throw DoryLinuxVMCalibrationExecError.invalidArguments(
                    "guest command arguments cannot contain NUL bytes"
                )
            }
            let (next, overflow) = argumentBytes.addingReportingOverflow(argument.utf8.count + 1)
            guard !overflow, next <= maximumArgumentBytes else {
                throw DoryLinuxVMCalibrationExecError.invalidArguments(
                    "the guest command exceeds \(maximumArgumentBytes) UTF-8 bytes"
                )
            }
            argumentBytes = next
        }

        guard requireExistingSocket else { return }
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw DoryLinuxVMCalibrationExecError.socketUnavailable(
                "\(path): \(String(cString: strerror(errno)))"
            )
        }
        guard status.st_mode & S_IFMT == S_IFSOCK, status.st_uid == geteuid() else {
            throw DoryLinuxVMCalibrationExecError.unsafeSocketPath(
                "\(path) is not a caller-owned Unix socket"
            )
        }
    }
}
