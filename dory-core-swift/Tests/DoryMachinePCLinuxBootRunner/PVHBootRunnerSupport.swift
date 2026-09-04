import CryptoKit
import Darwin
import DoryDBTX86
import DoryMachinePC
import Foundation

struct PVHRunnerError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

struct PVHRunnerConfiguration: Codable, Sendable {
  let kernel: String
  let kernelSHA256: String
  let initrd: String
  let initrdSHA256: String
  let commandLine: String
  let tier: DoryPCExecutionTier
  let memoryMiB: Int
  let maximumInstructions: UInt64
  let wallSeconds: UInt64
  let runID: String
  let workloads: [String]
  let diagnostics: String?
  let symbols: String?
  let symbolsSHA256: String?

  static let usage = """
    Usage: dory-pc-linux-boot-runner \
      --kernel /absolute/vmlinux --kernel-sha256 HEX \
      --initrd /absolute/initramfs --initrd-sha256 HEX \
      --command-line 'console=ttyS0 rdinit=/init panic=-1' \
      --tier interpreter|baseline-jit|optimizing-jit --memory-mib N \
      --max-instructions N --wall-seconds N --run-id UUID --workload NAME [--workload NAME ...] \
      [--diagnostics /absolute/result.json] [--symbols /absolute/System.map --symbols-sha256 HEX]

    Every input is explicit; no fixture search or download occurs. Limits: 2..524288 MiB,
    1..1000000000000 instructions, 1..3600 wall seconds. The wall budget includes file checks
    and VM initialization. --diagnostics opts into a bounded state/exit/console-tail receipt.
    --symbols annotates sampled PCs only; it never changes guest execution or loads memory.

    The runner appends dory.pvh_run_id=UUID to the command line. The init process must emit
    one complete JSON line with schemaVersion=1, doryPVHBoot="userspace-ready", runID=UUID,
    workloadsPassed=true, and workloads containing exactly the requested names, then power off
    through ACPI. A marker without clean poweroff, a fault, reset, or exhausted budget fails.
    Exit codes: 0 passed; 1 boot/fixture/receipt failure; 2 invalid arguments; 124 wall budget.
    This diagnostic runner does not qualify a product release.
    """

  init(arguments: [String]) throws {
    let names: Set<String> = [
      "kernel", "kernel-sha256", "initrd", "initrd-sha256", "command-line", "tier",
      "memory-mib", "max-instructions", "wall-seconds", "run-id", "workload", "diagnostics",
      "symbols", "symbols-sha256",
    ]
    var values: [String: String] = [:]
    var requestedWorkloads: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      guard argument.hasPrefix("--"), names.contains(String(argument.dropFirst(2))),
        index + 1 < arguments.count
      else { throw PVHRunnerError("Unknown option or missing value: \(argument.prefix(80))") }
      let name = String(argument.dropFirst(2))
      let value = arguments[index + 1]
      guard value.utf8.count <= 8192 else { throw PVHRunnerError("Option value too long: --\(name)") }
      if name == "workload" {
        requestedWorkloads.append(value)
      } else {
        guard values[name] == nil else { throw PVHRunnerError("Duplicate option: --\(name)") }
        values[name] = value
      }
      index += 2
    }
    func required(_ name: String) throws -> String {
      guard let value = values[name], !value.isEmpty else {
        throw PVHRunnerError("Required option: --\(name)")
      }
      return value
    }
    func absolutePath(_ name: String) throws -> String {
      let value = try required(name)
      guard value.hasPrefix("/"), !value.utf8.contains(0), value.utf8.count < Int(PATH_MAX) else {
        throw PVHRunnerError("--\(name) requires an absolute file path")
      }
      return value
    }
    func digest(_ name: String) throws -> String {
      let value = try required(name)
      guard value.utf8.count == 64,
        value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw PVHRunnerError("--\(name) requires lowercase SHA-256") }
      return value
    }
    kernel = try absolutePath("kernel")
    kernelSHA256 = try digest("kernel-sha256")
    initrd = try absolutePath("initrd")
    initrdSHA256 = try digest("initrd-sha256")
    switch try required("tier") {
    case "interpreter": tier = .interpreter
    case "baseline-jit": tier = .baselineJIT
    case "optimizing-jit": tier = .optimizingJIT
    default: throw PVHRunnerError("Unsupported --tier")
    }
    guard let memory = Int(try required("memory-mib")), (2...524288).contains(memory) else {
      throw PVHRunnerError("--memory-mib must be 2...524288")
    }
    memoryMiB = memory
    guard let instructions = UInt64(try required("max-instructions")),
      (1...1_000_000_000_000).contains(instructions)
    else { throw PVHRunnerError("--max-instructions must be 1...1000000000000") }
    maximumInstructions = instructions
    guard let seconds = UInt64(try required("wall-seconds")), (1...3600).contains(seconds) else {
      throw PVHRunnerError("--wall-seconds must be 1...3600")
    }
    wallSeconds = seconds
    guard let id = UUID(uuidString: try required("run-id")) else {
      throw PVHRunnerError("--run-id requires a UUID generated for this campaign")
    }
    runID = id.uuidString.lowercased()
    guard !requestedWorkloads.isEmpty, requestedWorkloads.count <= 32,
      Set(requestedWorkloads).count == requestedWorkloads.count,
      requestedWorkloads.allSatisfy({ name in
        (1...64).contains(name.utf8.count)
          && name.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
              || [45, 46, 95].contains($0)
          })
      })
    else { throw PVHRunnerError("Supply 1...32 distinct --workload names using ASCII letters, digits, ._- ") }
    workloads = requestedWorkloads.sorted()
    let baseCommandLine = try required("command-line")
    guard !baseCommandLine.utf8.contains(0), !baseCommandLine.contains("dory.pvh_run_id=") else {
      throw PVHRunnerError("Command line must not contain NUL or a preexisting dory.pvh_run_id")
    }
    commandLine = baseCommandLine + " dory.pvh_run_id=" + runID
    guard commandLine.utf8.count < DoryPCPVHBootBuilder.maximumCommandLineBytes else {
      throw PVHRunnerError("Command line plus run ID exceeds the PVH limit")
    }
    diagnostics = values["diagnostics"] == nil ? nil : try absolutePath("diagnostics")
    if values["symbols"] != nil || values["symbols-sha256"] != nil {
      symbols = try absolutePath("symbols")
      symbolsSHA256 = try digest("symbols-sha256")
    } else {
      symbols = nil
      symbolsSHA256 = nil
    }
    // A diagnostic output must never replace one of the pinned inputs.
    if let diagnostics,
      [kernel, initrd, symbols].compactMap({ $0 }).contains(where: {
        URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()
          == URL(fileURLWithPath: diagnostics).standardizedFileURL.resolvingSymlinksInPath()
      })
    { throw PVHRunnerError("Diagnostic output aliases an input") }
  }
}

struct PVHArtifactIdentity: Codable, Sendable {
  let path: String
  let sha256: String
  let byteCount: Int
  let elfBuildID: String?
}

struct PVHPinnedInput {
  let data: Data
  let identity: PVHArtifactIdentity

  static func read(path: String, sha256: String, maximumBytes: Int = 512 << 20) throws -> Self {
    let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
    guard descriptor >= 0 else { throw PVHRunnerError("Cannot open required input: \(path)") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var initial = stat()
    guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
      initial.st_size > 0, initial.st_size <= maximumBytes
    else { throw PVHRunnerError("Input must be a nonempty regular file within \(maximumBytes) bytes: \(path)") }
    var data = Data()
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
      guard chunk.count <= maximumBytes - data.count else {
        throw PVHRunnerError("Input grew beyond its bound: \(path)")
      }
      data.append(chunk)
      hasher.update(data: chunk)
    }
    var final = stat()
    guard fstat(descriptor, &final) == 0, initial.st_size == final.st_size,
      final.st_size == data.count,
      initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
      initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
      initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
      initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
    else { throw PVHRunnerError("Input changed during verification: \(path)") }
    let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard actual == sha256 else { throw PVHRunnerError("SHA-256 mismatch for required input: \(path)") }
    return .init(
      data: data,
      identity: .init(path: path, sha256: actual, byteCount: data.count, elfBuildID: nil))
  }
}

/// Diagnostic metadata only. The strict kernel loader owns executable validation.
struct PVHELFMetadata {
  let buildID: String?
  private let mappings: [(physical: UInt64, virtual: UInt64, count: UInt64)]

  init(validatedImage image: DoryPCPVHKernelImage) {
    let data = image.data
    func read(_ offset: Int, _ count: Int) -> UInt64 {
      (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }
    let headers = Int(read(32, 8))
    let size = Int(read(54, 2))
    let count = Int(read(56, 2))
    var foundBuildID: String?
    var foundMappings: [(UInt64, UInt64, UInt64)] = []
    for index in 0..<count {
      let header = headers + index * size
      let type = read(header, 4)
      if type == 1 {
        foundMappings.append((read(header + 24, 8), read(header + 16, 8), read(header + 40, 8)))
      } else if type == 4 {
        var cursor = Int(read(header + 8, 8))
        let end = cursor + Int(read(header + 32, 8))
        while cursor < end {
          let nameSize = Int(read(cursor, 4))
          let descriptorSize = Int(read(cursor + 4, 4))
          let descriptor = (cursor + 12 + nameSize + 3) & ~3
          if read(cursor + 8, 4) == 3,
            data[(cursor + 12)..<(cursor + 12 + nameSize)].elementsEqual([0x47, 0x4E, 0x55, 0]),
            (1...64).contains(descriptorSize)
          {
            foundBuildID = data[descriptor..<(descriptor + descriptorSize)]
              .map { String(format: "%02x", $0) }.joined()
          }
          cursor = (descriptor + descriptorSize + 3) & ~3
        }
      }
    }
    buildID = foundBuildID
    mappings = foundMappings
  }

  func symbolAddress(state: DoryX86ArchitecturalState) -> UInt64? {
    let linear = state.cs.base.addingReportingOverflow(state.rip)
    guard !linear.overflow else { return nil }
    if state.control.cr0 & (1 << 31) != 0 { return linear.partialValue }
    for mapping in mappings where linear.partialValue >= mapping.physical {
      let offset = linear.partialValue - mapping.physical
      if offset < mapping.count { return mapping.virtual + offset }
    }
    return nil
  }
}

struct PVHSymbolMap {
  struct Match: Codable, Sendable {
    let name: String
    let symbolAddress: UInt64
    let offset: UInt64
  }
  private let entries: [(UInt64, String)]

  init(data: Data) throws {
    guard data.count <= 32 << 20, let text = String(data: data, encoding: .utf8) else {
      throw PVHRunnerError("System.map must be UTF-8 and at most 32 MiB")
    }
    var parsed: [(UInt64, String)] = []
    for line in text.split(separator: "\n") {
      let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard parts.count == 3, parts[0].count <= 16,
        let address = UInt64(parts[0], radix: 16), parts[1].count == 1,
        parts[2].utf8.count <= 256, !parts[2].contains("\0")
      else { throw PVHRunnerError("Malformed System.map line") }
      // Text symbols annotate PCs; data addresses are never dereferenced by this runner.
      if parts[1] == "T" || parts[1] == "t" || parts[1] == "W" || parts[1] == "w" {
        guard parsed.count < 500_000 else { throw PVHRunnerError("Too many System.map text symbols") }
        parsed.append((address, String(parts[2])))
      }
    }
    guard !parsed.isEmpty else { throw PVHRunnerError("System.map contains no text symbols") }
    entries = parsed.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
  }

  func nearest(to address: UInt64) -> Match? {
    var low = 0
    var high = entries.count
    while low < high {
      let middle = low + (high - low) / 2
      if entries[middle].0 <= address { low = middle + 1 } else { high = middle }
    }
    guard low > 0 else { return nil }
    let (base, name) = entries[low - 1]
    return .init(name: name, symbolAddress: base, offset: address - base)
  }
}

struct PVHGuestReceipt: Codable, Sendable {
  let schemaVersion: Int
  let doryPVHBoot: String
  let runID: String
  let workloadsPassed: Bool
  let workloads: [String]
}

/// Parses whole bounded lines; neither boot-command echoes nor tail truncation can create a marker.
struct PVHConsoleCapture: Sendable {
  static let maximumTailBytes = 65536
  static let maximumLineBytes = 4096
  private(set) var tail: [UInt8] = []
  private(set) var totalBytes: UInt64 = 0
  private(set) var receipt: PVHGuestReceipt?
  private var line: [UInt8] = []
  private var discardingLine = false

  mutating func consume(_ bytes: [UInt8], runID: String, workloads: [String]) {
    totalBytes += UInt64(bytes.count)
    tail.append(contentsOf: bytes.suffix(Self.maximumTailBytes))
    if tail.count > Self.maximumTailBytes { tail.removeFirst(tail.count - Self.maximumTailBytes) }
    for byte in bytes {
      if byte == 10 {
        if !discardingLine {
          if line.last == 13 { line.removeLast() }
          if let found = try? JSONDecoder().decode(PVHGuestReceipt.self, from: Data(line)),
            found.schemaVersion == 1, found.doryPVHBoot == "userspace-ready",
            found.runID == runID, found.workloadsPassed,
            found.workloads.count == workloads.count, found.workloads.sorted() == workloads.sorted()
          { receipt = found }
        }
        line.removeAll(keepingCapacity: true)
        discardingLine = false
      } else if !discardingLine {
        if line.count < Self.maximumLineBytes { line.append(byte) } else {
          line.removeAll(keepingCapacity: true)
          discardingLine = true
        }
      }
    }
  }
}

struct PVHStopSnapshot: Codable, Sendable {
  let reason: String
  let instructionCount: UInt64
  let totalInstructions: UInt64
  let elapsedNanoseconds: UInt64
  let rip: UInt64?
  let fault: DoryX86Exception?
  let faultProcessor: Int?
  let faultInstructionBytes: [UInt8]?
  let interruptVector: UInt8?
  let nearestSymbol: PVHSymbolMap.Match?

  init(
    stop: DoryPCMachineStop, totalInstructions: UInt64, elapsedNanoseconds: UInt64,
    state: DoryX86ArchitecturalState?, nearestSymbol: PVHSymbolMap.Match?
  ) {
    var exception: DoryX86Exception?
    var processor: Int?
    var bytes: [UInt8]?
    var interrupt: UInt8?
    switch stop {
    case .instructionBudget(let count): reason = "instruction-quantum"; instructionCount = count
    case .halted(let count): reason = "halted"; instructionCount = count
    case .poweredOff(let count): reason = "powered-off"; instructionCount = count
    case .reset(let count): reason = "reset"; instructionCount = count
    case .exception(let value, let count):
      reason = "exception"; instructionCount = count; exception = value
    case .tripleFault(let source, let count):
      reason = "triple-fault"; instructionCount = count
      switch source {
      case .exception(let evidence):
        exception = evidence.exception; processor = evidence.processor
        bytes = Array(evidence.instructionBytes.prefix(15))
      case .interrupt(let vector, _, let index): interrupt = vector; processor = index
      }
    }
    self.totalInstructions = totalInstructions
    self.elapsedNanoseconds = elapsedNanoseconds
    rip = state?.rip
    fault = exception
    faultProcessor = processor
    faultInstructionBytes = bytes
    interruptVector = interrupt
    self.nearestSymbol = nearestSymbol
  }

  static func instructionCount(_ stop: DoryPCMachineStop) -> UInt64 {
    switch stop {
    case .instructionBudget(let count), .halted(let count), .poweredOff(let count), .reset(let count),
      .exception(_, let count), .tripleFault(_, let count): count
    }
  }
}

struct PVHRunOutcome: Codable, Sendable {
  let passed: Bool
  let reason: String
  let exitCode: Int32

  static let wallBudget = Self(passed: false, reason: "wall-budget", exitCode: 124)
  static let instructionBudget = Self(passed: false, reason: "instruction-budget", exitCode: 1)

  static func terminal(stop: DoryPCMachineStop, receiptSeen: Bool) -> Self? {
    switch stop {
    case .instructionBudget: return nil
    case .poweredOff:
      return .init(passed: receiptSeen, reason: receiptSeen ? "userspace-workloads-powered-off" : "missing-guest-receipt", exitCode: receiptSeen ? 0 : 1)
    case .halted: return .init(passed: false, reason: "halted-without-poweroff", exitCode: 1)
    case .reset: return .init(passed: false, reason: "guest-reset", exitCode: 1)
    case .exception: return .init(passed: false, reason: "guest-exception", exitCode: 1)
    case .tripleFault: return .init(passed: false, reason: "guest-triple-fault", exitCode: 1)
    }
  }
}

struct PVHDiagnosticRecord: Codable, Sendable {
  let schemaVersion = 1
  let kind = "dev.dory.pvh-boot-diagnostic"
  let releaseQualified = false
  let configuration: PVHRunnerConfiguration
  let hostOS = ProcessInfo.processInfo.operatingSystemVersionString
  let guestClock = "deterministic"
  let observationScope = "Last runner slice exits; guest-handled exceptions are not sampled. Timeout state is the last completed slice."
  var stage = "verifying-inputs"
  var kernel: PVHArtifactIdentity?
  var initrd: PVHArtifactIdentity?
  var symbols: PVHArtifactIdentity?
  var retiredInstructions: UInt64 = 0
  var elapsedNanoseconds: UInt64 = 0
  var lastExits: [PVHStopSnapshot] = []
  var state: DoryX86ArchitecturalState?
  var executionStatistics: DoryPCExecutionStatistics?
  var consoleTail = ""
  var consoleBytes: UInt64 = 0
  var guestReceipt: PVHGuestReceipt?
  var outcome: PVHRunOutcome?
  var error: String?
}
