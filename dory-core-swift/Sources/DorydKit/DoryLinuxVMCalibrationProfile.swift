import Darwin
import DoryCore
import Foundation

/// Explicit inputs for the calibration-only Linux guest latency profiler.
public struct DoryLinuxVMCalibrationProfileConfiguration: Sendable, Equatable {
  public static let defaultSamples = 5
  public static let maximumSamples = 25
  public static let defaultSerialTimeoutMs: UInt64 = 30_000
  public static let maximumSerialTimeoutMs: UInt64 = 120_000

  public var agentSocketPath: String
  public var machineID: String
  public var machineDirectory: String
  public var consoleSocketPath: String
  public var samples: Int
  public var serialTimeoutMs: UInt64
  public var execTimeoutMs: UInt64
  public var outputLimitBytes: UInt64
  public var argv: [String]

  public init(
    agentSocketPath: String,
    machineID: String,
    machineDirectory: String,
    consoleSocketPath: String,
    samples: Int = Self.defaultSamples,
    serialTimeoutMs: UInt64 = Self.defaultSerialTimeoutMs,
    execTimeoutMs: UInt64 = DoryLinuxVMCalibrationExecConfiguration.defaultTimeoutMs,
    outputLimitBytes: UInt64 = DoryLinuxVMCalibrationExecConfiguration.defaultOutputLimitBytes,
    argv: [String]
  ) {
    self.agentSocketPath = agentSocketPath
    self.machineID = machineID
    self.machineDirectory = machineDirectory
    self.consoleSocketPath = consoleSocketPath
    self.samples = samples
    self.serialTimeoutMs = serialTimeoutMs
    self.execTimeoutMs = execTimeoutMs
    self.outputLimitBytes = outputLimitBytes
    self.argv = argv
  }
}

public struct DoryLinuxVMCalibrationLatencyDistribution: Codable, Sendable, Equatable {
  public var count: Int
  public var minimumNanoseconds: UInt64
  public var p50Nanoseconds: UInt64
  public var p95Nanoseconds: UInt64
  public var maximumNanoseconds: UInt64

  init(values: [UInt64]) {
    precondition(!values.isEmpty)
    let sorted = values.sorted()
    count = sorted.count
    minimumNanoseconds = sorted[0]
    p50Nanoseconds = Self.nearestRank(50, sorted: sorted)
    p95Nanoseconds = Self.nearestRank(95, sorted: sorted)
    maximumNanoseconds = sorted[sorted.count - 1]
  }

  private static func nearestRank(_ percentile: Int, sorted: [UInt64]) -> UInt64 {
    let rank = (percentile * sorted.count + 99) / 100
    return sorted[max(0, min(sorted.count - 1, rank - 1))]
  }
}

public struct DoryLinuxVMCalibrationProfileSample: Codable, Sendable, Equatable {
  public var index: Int
  public var serialRoundTripNanoseconds: UInt64
  public var connectHandshakeNanoseconds: UInt64
  public var protocolInfoRPCNanoseconds: UInt64
  public var commandRPCNanoseconds: UInt64
  public var agentTiming: DoryExecTiming?
  public var agentInternalUnattributedNanoseconds: UInt64?
  public var transportAndHostResidualNanoseconds: UInt64?
  public var exitCode: Int32
  public var timedOut: Bool
  public var stdoutTruncated: Bool
  public var stderrTruncated: Bool

  public init(
    index: Int,
    serialRoundTripNanoseconds: UInt64,
    connectHandshakeNanoseconds: UInt64,
    protocolInfoRPCNanoseconds: UInt64,
    commandRPCNanoseconds: UInt64,
    agentTiming: DoryExecTiming?,
    exitCode: Int32,
    timedOut: Bool,
    stdoutTruncated: Bool,
    stderrTruncated: Bool
  ) {
    self.index = index
    self.serialRoundTripNanoseconds = serialRoundTripNanoseconds
    self.connectHandshakeNanoseconds = connectHandshakeNanoseconds
    self.protocolInfoRPCNanoseconds = protocolInfoRPCNanoseconds
    self.commandRPCNanoseconds = commandRPCNanoseconds
    self.agentTiming = agentTiming
    if let agentTiming {
      let attributed = agentTiming.agentQueueNanoseconds
        .addingSaturating(agentTiming.processSpawnNanoseconds)
        .addingSaturating(agentTiming.processWaitNanoseconds)
        .addingSaturating(agentTiming.outputDrainNanoseconds)
      agentInternalUnattributedNanoseconds = agentTiming.agentTotalNanoseconds
        .subtractingSaturating(attributed)
      transportAndHostResidualNanoseconds =
        commandRPCNanoseconds
        .subtractingSaturating(agentTiming.agentTotalNanoseconds)
    } else {
      agentInternalUnattributedNanoseconds = nil
      transportAndHostResidualNanoseconds = nil
    }
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.stdoutTruncated = stdoutTruncated
    self.stderrTruncated = stderrTruncated
  }
}

public struct DoryLinuxVMCalibrationProfileSummary: Codable, Sendable, Equatable {
  public var serialRoundTrip: DoryLinuxVMCalibrationLatencyDistribution
  public var connectHandshake: DoryLinuxVMCalibrationLatencyDistribution
  public var protocolInfoRPC: DoryLinuxVMCalibrationLatencyDistribution
  public var commandRPC: DoryLinuxVMCalibrationLatencyDistribution
  public var agentQueue: DoryLinuxVMCalibrationLatencyDistribution?
  public var processSpawn: DoryLinuxVMCalibrationLatencyDistribution?
  public var processWait: DoryLinuxVMCalibrationLatencyDistribution?
  public var outputDrain: DoryLinuxVMCalibrationLatencyDistribution?
  public var agentTotal: DoryLinuxVMCalibrationLatencyDistribution?
  public var agentInternalUnattributed: DoryLinuxVMCalibrationLatencyDistribution?
  public var transportAndHostResidual: DoryLinuxVMCalibrationLatencyDistribution?
  public var guestTimingSamples: Int
  public var guestTimingComplete: Bool
  public var dominantCommandComponent: String?
  public var dominantCommandComponentP50Nanoseconds: UInt64?
}

public struct DoryLinuxVMCalibrationProfileReceipt: Codable, Sendable, Equatable {
  public static let currentSchemaVersion: UInt16 = 1

  public var schemaVersion: UInt16
  public var measurementClock: String
  public var percentileMethod: String
  public var residualDefinition: String
  public var agentProtocolVersion: UInt32
  public var agentBuild: String
  public var guestKernel: String
  public var argv: [String]
  public var samples: [DoryLinuxVMCalibrationProfileSample]
  public var summary: DoryLinuxVMCalibrationProfileSummary

  init(
    agentProtocolVersion: UInt32,
    agentBuild: String,
    guestKernel: String,
    argv: [String],
    samples: [DoryLinuxVMCalibrationProfileSample]
  ) {
    schemaVersion = Self.currentSchemaVersion
    measurementClock = "host DispatchTime.uptimeNanoseconds; guest std::time::Instant"
    percentileMethod = "nearest-rank"
    residualDefinition =
      "host command RPC round trip minus guest agent total; includes transport, framing, and host scheduling"
    self.agentProtocolVersion = agentProtocolVersion
    self.agentBuild = agentBuild
    self.guestKernel = guestKernel
    self.argv = argv
    self.samples = samples
    summary = DoryLinuxVMCalibrationProfile.summarize(samples)
  }
}

public enum DoryLinuxVMCalibrationProfileError: Error, Sendable, Equatable,
  CustomStringConvertible
{
  case invalidArguments(String)
  case serialRoundTripTimedOut(UInt64)
  case incompatibleAgentProtocol(expected: UInt32, actual: UInt32)
  case missingExecCapability
  case inconsistentAgentIdentity

  public var description: String {
    switch self {
    case .invalidArguments(let detail):
      "invalid Linux calibration profile arguments: \(detail)"
    case .serialRoundTripTimedOut(let timeoutMs):
      "Linux calibration serial round trip exceeded \(timeoutMs) ms"
    case .incompatibleAgentProtocol(let expected, let actual):
      "Linux calibration agent protocol mismatch: expected \(expected), received \(actual)"
    case .missingExecCapability:
      "Linux calibration agent does not advertise exec capability"
    case .inconsistentAgentIdentity:
      "Linux calibration samples reached different guest-agent identities"
    }
  }
}

/// Produces a latency decomposition from explicitly supplied calibration endpoints.
public enum DoryLinuxVMCalibrationProfile {
  public static func parse(
    arguments: [String]
  ) throws -> DoryLinuxVMCalibrationProfileConfiguration {
    guard let separator = arguments.firstIndex(of: "--") else {
      throw DoryLinuxVMCalibrationProfileError.invalidArguments(
        "missing -- before the guest command"
      )
    }
    let optionTokens = Array(arguments[..<separator])
    let argv = Array(arguments[arguments.index(after: separator)...])
    guard !argv.isEmpty else {
      throw DoryLinuxVMCalibrationProfileError.invalidArguments("the guest command is empty")
    }
    guard optionTokens.count.isMultiple(of: 2) else {
      throw DoryLinuxVMCalibrationProfileError.invalidArguments(
        "every profile option requires one value"
      )
    }

    let allowedOptions: Set<String> = [
      "--agent-socket", "--machine-id", "--machine-directory", "--console-socket",
      "--samples", "--serial-timeout-ms", "--exec-timeout-ms", "--output-limit-bytes",
    ]
    var values: [String: String] = [:]
    var index = 0
    while index < optionTokens.count {
      let option = optionTokens[index]
      guard allowedOptions.contains(option) else {
        throw DoryLinuxVMCalibrationProfileError.invalidArguments(
          "unknown option \(option)"
        )
      }
      guard values[option] == nil else {
        throw DoryLinuxVMCalibrationProfileError.invalidArguments(
          "duplicate option \(option)"
        )
      }
      values[option] = optionTokens[index + 1]
      index += 2
    }

    func required(_ option: String) throws -> String {
      guard let value = values[option], !value.isEmpty else {
        throw DoryLinuxVMCalibrationProfileError.invalidArguments("missing \(option)")
      }
      return value
    }
    func bounded(
      _ option: String, fallback: UInt64, maximum: UInt64
    ) throws -> UInt64 {
      guard let raw = values[option] else { return fallback }
      guard let value = UInt64(raw), value > 0, value <= maximum else {
        throw DoryLinuxVMCalibrationProfileError.invalidArguments(
          "\(option) requires an integer in 1...\(maximum)"
        )
      }
      return value
    }

    let rawSamples = try bounded(
      "--samples",
      fallback: UInt64(DoryLinuxVMCalibrationProfileConfiguration.defaultSamples),
      maximum: UInt64(DoryLinuxVMCalibrationProfileConfiguration.maximumSamples)
    )
    let configuration = DoryLinuxVMCalibrationProfileConfiguration(
      agentSocketPath: try required("--agent-socket"),
      machineID: try required("--machine-id"),
      machineDirectory: try required("--machine-directory"),
      consoleSocketPath: try required("--console-socket"),
      samples: Int(rawSamples),
      serialTimeoutMs: try bounded(
        "--serial-timeout-ms",
        fallback: DoryLinuxVMCalibrationProfileConfiguration.defaultSerialTimeoutMs,
        maximum: DoryLinuxVMCalibrationProfileConfiguration.maximumSerialTimeoutMs
      ),
      execTimeoutMs: try bounded(
        "--exec-timeout-ms",
        fallback: DoryLinuxVMCalibrationExecConfiguration.defaultTimeoutMs,
        maximum: DoryLinuxVMCalibrationExecConfiguration.maximumTimeoutMs
      ),
      outputLimitBytes: try bounded(
        "--output-limit-bytes",
        fallback: DoryLinuxVMCalibrationExecConfiguration.defaultOutputLimitBytes,
        maximum: DoryLinuxVMCalibrationExecConfiguration.maximumOutputLimitBytes
      ),
      argv: argv
    )
    try validate(configuration, requireEndpoints: false)
    return configuration
  }

  public static func run(
    _ configuration: DoryLinuxVMCalibrationProfileConfiguration
  ) throws -> DoryLinuxVMCalibrationProfileReceipt {
    try validate(configuration, requireEndpoints: true)
    var measurements: [DoryLinuxVMCalibrationProfileSample] = []
    var identity: DoryAgentInfo?

    for index in 1...configuration.samples {
      let serialNanoseconds = try measureSerialRoundTrip(configuration)

      let connectStarted = DispatchTime.now().uptimeNanoseconds
      let handle = try LocalAgentControl.connect(socketPath: configuration.agentSocketPath)
      let connectNanoseconds = elapsed(since: connectStarted)
      defer { handle.close() }

      let infoStarted = DispatchTime.now().uptimeNanoseconds
      let info = try handle.info()
      let infoNanoseconds = elapsed(since: infoStarted)
      try validate(info)
      if let identity, !sameAgentIdentity(identity, info) {
        throw DoryLinuxVMCalibrationProfileError.inconsistentAgentIdentity
      }
      identity = info

      let execStarted = DispatchTime.now().uptimeNanoseconds
      let result = try handle.exec(
        argv: configuration.argv,
        timeoutMs: configuration.execTimeoutMs,
        outputLimitBytes: configuration.outputLimitBytes
      )
      let execNanoseconds = elapsed(since: execStarted)
      measurements.append(
        DoryLinuxVMCalibrationProfileSample(
          index: index,
          serialRoundTripNanoseconds: serialNanoseconds,
          connectHandshakeNanoseconds: connectNanoseconds,
          protocolInfoRPCNanoseconds: infoNanoseconds,
          commandRPCNanoseconds: execNanoseconds,
          agentTiming: result.timing,
          exitCode: result.exitCode,
          timedOut: result.timedOut,
          stdoutTruncated: result.stdoutTruncated,
          stderrTruncated: result.stderrTruncated
        ))
      handle.close()
    }

    guard let identity else {
      throw DoryLinuxVMCalibrationProfileError.invalidArguments("no samples requested")
    }
    return DoryLinuxVMCalibrationProfileReceipt(
      agentProtocolVersion: identity.protocolVersion,
      agentBuild: identity.agentBuild,
      guestKernel: identity.kernel,
      argv: configuration.argv,
      samples: measurements
    )
  }

  public static func canonicalJSON(
    for receipt: DoryLinuxVMCalibrationProfileReceipt
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(receipt)
  }

  static func summarize(
    _ samples: [DoryLinuxVMCalibrationProfileSample]
  ) -> DoryLinuxVMCalibrationProfileSummary {
    precondition(!samples.isEmpty)
    func distribution(_ values: [UInt64]) -> DoryLinuxVMCalibrationLatencyDistribution {
      DoryLinuxVMCalibrationLatencyDistribution(values: values)
    }
    func optionalDistribution(
      _ values: [UInt64]
    ) -> DoryLinuxVMCalibrationLatencyDistribution? {
      values.isEmpty ? nil : distribution(values)
    }

    let timed = samples.compactMap(\.agentTiming)
    let commandComponents: [(String, DoryLinuxVMCalibrationLatencyDistribution?)] = [
      ("agentQueue", optionalDistribution(timed.map(\.agentQueueNanoseconds))),
      ("processSpawn", optionalDistribution(timed.map(\.processSpawnNanoseconds))),
      ("processWait", optionalDistribution(timed.map(\.processWaitNanoseconds))),
      ("outputDrain", optionalDistribution(timed.map(\.outputDrainNanoseconds))),
      (
        "agentInternalUnattributed",
        optionalDistribution(samples.compactMap(\.agentInternalUnattributedNanoseconds))
      ),
      (
        "transportAndHostResidual",
        optionalDistribution(samples.compactMap(\.transportAndHostResidualNanoseconds))
      ),
    ]
    let dominant = commandComponents.compactMap { name, value in
      value.map { (name, $0.p50Nanoseconds) }
    }.max { lhs, rhs in
      if lhs.1 == rhs.1 { return lhs.0 > rhs.0 }
      return lhs.1 < rhs.1
    }

    return DoryLinuxVMCalibrationProfileSummary(
      serialRoundTrip: distribution(samples.map(\.serialRoundTripNanoseconds)),
      connectHandshake: distribution(samples.map(\.connectHandshakeNanoseconds)),
      protocolInfoRPC: distribution(samples.map(\.protocolInfoRPCNanoseconds)),
      commandRPC: distribution(samples.map(\.commandRPCNanoseconds)),
      agentQueue: commandComponents[0].1,
      processSpawn: commandComponents[1].1,
      processWait: commandComponents[2].1,
      outputDrain: commandComponents[3].1,
      agentTotal: optionalDistribution(timed.map(\.agentTotalNanoseconds)),
      agentInternalUnattributed: commandComponents[4].1,
      transportAndHostResidual: commandComponents[5].1,
      guestTimingSamples: timed.count,
      guestTimingComplete: timed.count == samples.count,
      dominantCommandComponent: dominant?.0,
      dominantCommandComponentP50Nanoseconds: dominant?.1
    )
  }

  private static func measureSerialRoundTrip(
    _ configuration: DoryLinuxVMCalibrationProfileConfiguration
  ) throws -> UInt64 {
    let initial = try DoryMachineSerialConsoleAuthority.read(
      machineID: configuration.machineID,
      machineDirectory: configuration.machineDirectory,
      consoleSocketPath: configuration.consoleSocketPath,
      cursor: DoryMachineSerialConsoleCursor(),
      limit: DoryMachineSerialConsoleAuthority.maximumReadBytes
    )
    var cursor = initial.cursor
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let marker = Data("DORY_CALIBRATION_\(nonce)".utf8)
    // The complete marker is deliberately absent from the input, so terminal echo cannot
    // satisfy the probe before the guest shell actually executes it.
    let command = "printf '%s%s\\n' 'DORY_CALIBRATION_' '\(nonce)'\n"
    let started = DispatchTime.now().uptimeNanoseconds
    try DoryMachineSerialConsoleAuthority.write(
      Data(command.utf8),
      consoleSocketPath: configuration.consoleSocketPath
    )
    let deadline = started.addingSaturating(configuration.serialTimeoutMs * 1_000_000)
    var suffix = Data()

    while DispatchTime.now().uptimeNanoseconds <= deadline {
      let batch = try DoryMachineSerialConsoleAuthority.read(
        machineID: configuration.machineID,
        machineDirectory: configuration.machineDirectory,
        consoleSocketPath: configuration.consoleSocketPath,
        cursor: cursor,
        limit: DoryMachineSerialConsoleAuthority.maximumReadBytes
      )
      cursor = batch.cursor
      if batch.snapshotRequired { suffix.removeAll(keepingCapacity: true) }
      suffix.append(batch.bytes)
      if suffix.range(of: marker) != nil {
        return elapsed(since: started)
      }
      let retained = max(0, marker.count - 1)
      if suffix.count > retained {
        suffix.removeFirst(suffix.count - retained)
      }
      usleep(1_000)
    }
    throw DoryLinuxVMCalibrationProfileError.serialRoundTripTimedOut(
      configuration.serialTimeoutMs
    )
  }

  private static func validate(_ info: DoryAgentInfo) throws {
    let expected = DoryCore.protocolVersion()
    guard info.protocolVersion == expected else {
      throw DoryLinuxVMCalibrationProfileError.incompatibleAgentProtocol(
        expected: expected,
        actual: info.protocolVersion
      )
    }
    guard info.capabilitiesAreCanonical, info.supports("exec") else {
      throw DoryLinuxVMCalibrationProfileError.missingExecCapability
    }
  }

  private static func sameAgentIdentity(_ lhs: DoryAgentInfo, _ rhs: DoryAgentInfo) -> Bool {
    lhs.protocolVersion == rhs.protocolVersion
      && lhs.kernel == rhs.kernel
      && lhs.agentBuild == rhs.agentBuild
      && lhs.capabilities == rhs.capabilities
  }

  private static func validate(
    _ configuration: DoryLinuxVMCalibrationProfileConfiguration,
    requireEndpoints: Bool
  ) throws {
    guard configuration.machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil,
      !configuration.machineID.hasPrefix(".")
    else {
      throw DoryLinuxVMCalibrationProfileError.invalidArguments("invalid --machine-id")
    }
    for (option, path) in [
      ("--agent-socket", configuration.agentSocketPath),
      ("--machine-directory", configuration.machineDirectory),
      ("--console-socket", configuration.consoleSocketPath),
    ] {
      guard path.hasPrefix("/"), path != "/", !path.contains("\0"),
        URL(fileURLWithPath: path).standardizedFileURL.path == path
      else {
        throw DoryLinuxVMCalibrationProfileError.invalidArguments(
          "\(option) requires a standardized absolute path"
        )
      }
    }
    let unixPathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    guard configuration.agentSocketPath.utf8.count < unixPathLimit,
      configuration.consoleSocketPath.utf8CString.count <= unixPathLimit
    else {
      throw DoryLinuxVMCalibrationProfileError.invalidArguments(
        "a Unix-socket path exceeds the platform limit"
      )
    }
    guard
      (1...DoryLinuxVMCalibrationProfileConfiguration.maximumSamples)
        .contains(configuration.samples)
    else {
      throw DoryLinuxVMCalibrationProfileError.invalidArguments("--samples is out of range")
    }
    guard
      (1...DoryLinuxVMCalibrationProfileConfiguration.maximumSerialTimeoutMs)
        .contains(configuration.serialTimeoutMs)
    else {
      throw DoryLinuxVMCalibrationProfileError.invalidArguments(
        "--serial-timeout-ms is out of range"
      )
    }
    let execConfiguration = DoryLinuxVMCalibrationExecConfiguration(
      agentSocketPath: configuration.agentSocketPath,
      timeoutMs: configuration.execTimeoutMs,
      outputLimitBytes: configuration.outputLimitBytes,
      argv: configuration.argv
    )
    // Reuse the exec parser's command and limit validation without connecting.
    _ = try DoryLinuxVMCalibrationExec.parse(
      arguments: [
        "--agent-socket", execConfiguration.agentSocketPath,
        "--timeout-ms", String(execConfiguration.timeoutMs),
        "--output-limit-bytes", String(execConfiguration.outputLimitBytes),
        "--",
      ] + execConfiguration.argv)

    guard requireEndpoints else { return }
    var socketInfo = stat()
    guard lstat(configuration.agentSocketPath, &socketInfo) == 0,
      socketInfo.st_mode & S_IFMT == S_IFSOCK,
      socketInfo.st_uid == geteuid()
    else {
      throw DoryLinuxVMCalibrationProfileError.invalidArguments(
        "--agent-socket is not a caller-owned Unix socket"
      )
    }
  }

  private static func elapsed(since start: UInt64) -> UInt64 {
    DispatchTime.now().uptimeNanoseconds.subtractingSaturating(start)
  }
}

extension UInt64 {
  fileprivate func addingSaturating(_ other: UInt64) -> UInt64 {
    let (value, overflow) = addingReportingOverflow(other)
    return overflow ? .max : value
  }

  fileprivate func subtractingSaturating(_ other: UInt64) -> UInt64 {
    self >= other ? self - other : 0
  }
}
