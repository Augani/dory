import DoryDBTX86
import DoryFirmware
import DoryMachinePC
import DoryVirtio
import Foundation

private enum SmokeError: Error, CustomStringConvertible {
  case usage(String)
  case invalidNumber(String)

  var description: String {
    switch self {
    case .usage(let message): message
    case .invalidNumber(let value): "invalid unsigned integer: \(value)"
    }
  }
}

private struct Arguments {
  let firmwareBundle: URL
  let maximumInstructions: UInt64
  let progressInstructions: UInt64
  let memoryBytes: Int
  let processorCount: Int
  let systemDisk: URL?
  let installerMedia: URL?
  let variableStoreDirectory: URL?
  let exceptionPolicy: DoryPCExceptionPolicy
  let executionTier: DoryPCExecutionTier

  init(_ values: [String]) throws {
    var options: [String: String] = [:]
    var index = 1
    while index < values.count {
      guard index + 1 < values.count else {
        throw SmokeError.usage("missing value for \(values[index])")
      }
      let name = values[index]
      guard
        [
          "--firmware-bundle", "--max-instructions", "--memory-bytes", "--processor-count",
          "--system-disk", "--installer-media", "--variable-store-directory",
          "--exception-policy", "--execution-tier", "--progress-instructions",
        ].contains(name)
      else { throw SmokeError.usage("unknown option: \(name)") }
      guard options.updateValue(values[index + 1], forKey: name) == nil else {
        throw SmokeError.usage("duplicate option: \(name)")
      }
      index += 2
    }
    guard let bundle = options["--firmware-bundle"], bundle.hasPrefix("/") else {
      throw SmokeError.usage(
        "usage: dory-pc-uefi-smoke --firmware-bundle /absolute/bundle "
          + "[--system-disk /absolute/disk] [--installer-media /absolute/iso] "
          + "[--variable-store-directory /absolute/directory] "
          + "[--processor-count count] [--exception-policy stop|deliver] "
          + "[--execution-tier interpreter|baseline-jit|optimizing-jit] "
          + "[--max-instructions count] [--progress-instructions count] [--memory-bytes count]"
      )
    }
    let instructionText = options["--max-instructions"] ?? "1000000"
    let progressText = options["--progress-instructions"] ?? "10000000"
    let memoryText = options["--memory-bytes"] ?? "268435456"
    let processorText = options["--processor-count"] ?? "1"
    guard let maximumInstructions = UInt64(instructionText), maximumInstructions > 0 else {
      throw SmokeError.invalidNumber(instructionText)
    }
    guard let progressInstructions = UInt64(progressText), progressInstructions > 0 else {
      throw SmokeError.invalidNumber(progressText)
    }
    guard let memoryBytes = Int(memoryText), memoryBytes >= 128 * 1024 * 1024 else {
      throw SmokeError.invalidNumber(memoryText)
    }
    guard let processorCount = Int(processorText), (1...255).contains(processorCount) else {
      throw SmokeError.invalidNumber(processorText)
    }
    let policyText = options["--exception-policy"] ?? "stop"
    switch policyText {
    case "stop": exceptionPolicy = .stop
    case "deliver": exceptionPolicy = .deliver
    default: throw SmokeError.usage("invalid exception policy: \(policyText)")
    }
    let tierText = options["--execution-tier"] ?? "interpreter"
    switch tierText {
    case "interpreter": executionTier = .interpreter
    case "baseline-jit": executionTier = .baselineJIT
    case "optimizing-jit": executionTier = .optimizingJIT
    default: throw SmokeError.usage("invalid execution tier: \(tierText)")
    }
    firmwareBundle = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
    self.maximumInstructions = maximumInstructions
    self.progressInstructions = progressInstructions
    self.memoryBytes = memoryBytes
    self.processorCount = processorCount
    systemDisk = try options["--system-disk"].map { try Self.absoluteURL($0) }
    installerMedia = try options["--installer-media"].map { try Self.absoluteURL($0) }
    variableStoreDirectory = try options["--variable-store-directory"].map {
      try Self.absoluteURL($0, isDirectory: true)
    }
  }

  private static func absoluteURL(_ path: String, isDirectory: Bool = false) throws -> URL {
    guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0) else {
      throw SmokeError.usage("path must be absolute and narrowly scoped: \(path)")
    }
    return URL(fileURLWithPath: path, isDirectory: isDirectory).standardizedFileURL
  }
}

private func loadArtifacts(from bundle: URL) throws -> DoryVerifiedFirmwareArtifacts {
  let manifest = try JSONDecoder().decode(
    DoryFirmwareArtifactManifest.self,
    from: Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
  )
  return try DoryVerifiedFirmwareArtifacts(
    manifest: manifest,
    firmwareCode: Data(contentsOf: bundle.appendingPathComponent("firmware-code.fd")),
    variableStoreTemplate: Data(
      contentsOf: bundle.appendingPathComponent("variable-store-template.json")
    ),
    sbom: Data(contentsOf: bundle.appendingPathComponent("sbom.json"))
  )
}

private func hexadecimal(_ value: UInt64) -> String { String(format: "0x%016llx", value) }

private func hexadecimalBytes(_ bytes: [UInt8]) -> String {
  bytes.map { String(format: "%02x", $0) }.joined()
}

private func runWithProgress(
  machine: DoryPCDirectKernelMachine,
  maximumInstructions: UInt64,
  progressInstructions: UInt64,
  exceptionPolicy: DoryPCExceptionPolicy
) throws -> DoryPCMachineStop {
  var completed: UInt64 = 0
  while completed < maximumInstructions {
    let chunk = min(progressInstructions, maximumInstructions - completed)
    let stop = try machine.run(maximumInstructions: chunk, exceptionPolicy: exceptionPolicy)
    switch stop {
    case .instructionBudget(let count):
      completed &+= count
      let state = machine.state
      let statistics = machine.executionStatistics
      let payload: [String: Any] = [
        "completedInstructions": completed,
        "instructionPointer": state.map { hexadecimal($0.cs.base &+ $0.rip) } ?? "unavailable",
        "interpreterInstructions": statistics.interpreterInstructions,
        "baselineJITInstructions": statistics.baselineJITInstructions,
        "optimizingJITInstructions": statistics.optimizingJITInstructions,
      ]
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      FileHandle.standardError.write(data + Data("\n".utf8))
    case .halted(let count): return .halted(instructionCount: completed &+ count)
    case .exception(let exception, let count):
      return .exception(exception, instructionCount: completed &+ count)
    case .tripleFault(let count): return .tripleFault(instructionCount: completed &+ count)
    case .poweredOff(let count): return .poweredOff(instructionCount: completed &+ count)
    case .reset(let count): return .reset(instructionCount: completed &+ count)
    }
  }
  return .instructionBudget(completed)
}

private func pageTableTrace(
  memory: DoryX86ByteArrayMemory,
  cr3: UInt64,
  linearAddress: UInt64
) -> [String] {
  var table = cr3 & 0x000F_FFFF_FFFF_F000
  var trace: [String] = []
  for shift in [39, 30, 21, 12] {
    let index = (linearAddress >> UInt64(shift)) & 0x1FF
    let entryAddress = table &+ index * 8
    guard let bytes = try? memory.read(at: entryAddress, byteCount: 8) else {
      trace.append("\(hexadecimal(entryAddress)):unmapped")
      break
    }
    let entry = bytes.enumerated().reduce(UInt64(0)) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
    trace.append("\(hexadecimal(entryAddress)):\(hexadecimal(entry))")
    guard entry & 1 != 0 else { break }
    if shift > 12, entry & (1 << 7) != 0 { break }
    table = entry & 0x000F_FFFF_FFFF_F000
  }
  return trace
}

private func prepareVariableStore(
  directory: URL,
  initial: DoryUEFIVariableStoreSnapshot
) throws -> (file: DoryUEFIVariableStoreFile, generation: UInt64) {
  let file = try DoryUEFIVariableStoreFile(directory: directory.path)
  do {
    let loaded = try file.load()
    return (file, loaded.snapshot.generation)
  } catch DoryUEFIVariableStoreFileError.storeNotInitialized,
    DoryUEFIVariableStoreFileError.unsafePath
  {
    try file.initialize(initial)
    return (file, initial.generation)
  }
}

private func run() throws {
  let arguments = try Arguments(CommandLine.arguments)
  let artifacts = try loadArtifacts(from: arguments.firmwareBundle)
  guard artifacts.manifest.platform == .pcV1 else {
    throw SmokeError.usage("firmware bundle is not DoryPC-v1")
  }

  let ownsVariableDirectory = arguments.variableStoreDirectory == nil
  let variableDirectory =
    arguments.variableStoreDirectory
    ?? FileManager.default.temporaryDirectory.appendingPathComponent(
      "dory-pc-uefi-smoke-\(UUID().uuidString)",
      isDirectory: true
    )
  defer {
    if ownsVariableDirectory { try? FileManager.default.removeItem(at: variableDirectory) }
  }
  let variable = try prepareVariableStore(
    directory: variableDirectory,
    initial: artifacts.initialVariableStore
  )

  let systemDevice = try DoryPCUEFIBootDevice(
    logicalID: "system-disk",
    kind: .systemDisk,
    pciAddress: DoryPCUEFIBootDevice.systemDiskAddress,
    readOnly: false
  )
  var devices = [systemDevice]
  var storages: [DoryPCUEFIBootStorage] = []
  if let disk = arguments.systemDisk {
    storages.append(
      .init(
        logicalID: systemDevice.logicalID,
        storage: try DoryVirtioFileBlockStorage(existingFileURL: disk)
      ))
  } else {
    storages.append(
      .init(
        logicalID: systemDevice.logicalID,
        storage: DoryVirtioInMemoryBlockStorage(byteCount: 64 * 1024 * 1024)
      ))
  }
  var bootOrder = [systemDevice.logicalID]
  if let installer = arguments.installerMedia {
    let installerDevice = try DoryPCUEFIBootDevice(
      logicalID: "installer-media",
      kind: .removableMedia,
      pciAddress: DoryPCUEFIBootDevice.removableMediaAddress,
      readOnly: true
    )
    devices.append(installerDevice)
    storages.append(
      .init(
        logicalID: installerDevice.logicalID,
        storage: try DoryVirtioFileBlockStorage(existingFileURL: installer, readOnly: true)
      ))
    bootOrder = [installerDevice.logicalID, systemDevice.logicalID]
  }
  devices.sort()
  let plan = try DoryPCUEFILaunchPlan(
    firmware: artifacts.manifest,
    variableStoreGeneration: variable.generation,
    bootDevices: devices,
    bootOrder: bootOrder
  )
  let composed = try DoryPCUEFIMachine(
    plan: plan,
    firmware: artifacts,
    variableStore: .init(file: variable.file),
    bootStorage: storages,
    memoryBytes: arguments.memoryBytes,
    processorCount: arguments.processorCount,
    executionTier: arguments.executionTier
  )
  let stop = try runWithProgress(
    machine: composed.machine,
    maximumInstructions: arguments.maximumInstructions,
    progressInstructions: arguments.progressInstructions,
    exceptionPolicy: arguments.exceptionPolicy
  )
  let executionStatistics = composed.machine.executionStatistics
  let state = composed.machine.state
  let rip = state.map { hexadecimal($0.cs.base &+ $0.rip) } ?? "unavailable"
  let pageTrace =
    state.map {
      pageTableTrace(
        memory: composed.machine.memory,
        cr3: $0.control.cr3,
        linearAddress: $0.cs.base &+ $0.rip
      )
    } ?? []
  let instructionBytes = (try? composed.machine.instructionBytes(maximumCount: 16)) ?? nil
  let stackBytes =
    state.flatMap {
      (try? composed.machine.memoryBytes(atLinearAddress: $0.registers.rsp, maximumCount: 64)) ?? nil
    }
  let payload: [String: Any] = [
    "cr0": state.map { hexadecimal($0.control.cr0) } ?? "unavailable",
    "cr3": state.map { hexadecimal($0.control.cr3) } ?? "unavailable",
    "cr4": state.map { hexadecimal($0.control.cr4) } ?? "unavailable",
    "csAttributes": state.map { String(format: "0x%04x", $0.cs.attributes) } ?? "unavailable",
    "csBase": state.map { hexadecimal($0.cs.base) } ?? "unavailable",
    "csSelector": state.map { String(format: "0x%04x", $0.cs.selector) } ?? "unavailable",
    "efer": state.map { hexadecimal($0.control.efer) } ?? "unavailable",
    "firmwareBuildIdentifier": artifacts.manifest.buildIdentifier,
    "gdtrBase": state.map { hexadecimal($0.gdtr.base) } ?? "unavailable",
    "gdtrLimit": state.map { String(format: "0x%04x", $0.gdtr.limit) } ?? "unavailable",
    "instructionPointer": rip,
    "machineABIIdentity": artifacts.manifest.machineABIIdentity,
    "maximumInstructions": arguments.maximumInstructions,
    "progressInstructions": arguments.progressInstructions,
    "processorCount": arguments.processorCount,
    "bootOrder": bootOrder,
    "exceptionPolicy": arguments.exceptionPolicy == .stop ? "stop" : "deliver",
    "executionTier": arguments.executionTier.rawValue,
    "interpreterInstructions": executionStatistics.interpreterInstructions,
    "baselineJITInstructions": executionStatistics.baselineJITInstructions,
    "baselineJITBlocks": executionStatistics.baselineJITBlocks,
    "optimizingJITInstructions": executionStatistics.optimizingJITInstructions,
    "optimizingJITBlocks": executionStatistics.optimizingJITBlocks,
    "persistentSystemDisk": arguments.systemDisk?.path ?? "in-memory",
    "installerMedia": arguments.installerMedia?.path ?? "none",
    "variableStoreDirectory": ownsVariableDirectory ? "temporary" : variableDirectory.path,
    "pageTableTrace": pageTrace,
    "instructionBytes": instructionBytes.map(hexadecimalBytes) ?? "unmapped",
    "stackBytes": stackBytes.map(hexadecimalBytes) ?? "unmapped",
    "rax": state.map { hexadecimal($0.registers.rax) } ?? "unavailable",
    "rbx": state.map { hexadecimal($0.registers.rbx) } ?? "unavailable",
    "rcx": state.map { hexadecimal($0.registers.rcx) } ?? "unavailable",
    "rdx": state.map { hexadecimal($0.registers.rdx) } ?? "unavailable",
    "rbp": state.map { hexadecimal($0.registers.rbp) } ?? "unavailable",
    "rsi": state.map { hexadecimal($0.registers.rsi) } ?? "unavailable",
    "rdi": state.map { hexadecimal($0.registers.rdi) } ?? "unavailable",
    "r8": state.map { hexadecimal($0.registers.r8) } ?? "unavailable",
    "r9": state.map { hexadecimal($0.registers.r9) } ?? "unavailable",
    "r10": state.map { hexadecimal($0.registers.r10) } ?? "unavailable",
    "r11": state.map { hexadecimal($0.registers.r11) } ?? "unavailable",
    "r12": state.map { hexadecimal($0.registers.r12) } ?? "unavailable",
    "r13": state.map { hexadecimal($0.registers.r13) } ?? "unavailable",
    "r14": state.map { hexadecimal($0.registers.r14) } ?? "unavailable",
    "r15": state.map { hexadecimal($0.registers.r15) } ?? "unavailable",
    "rsp": state.map { hexadecimal($0.registers.rsp) } ?? "unavailable",
    "stop": String(describing: stop),
  ]
  let output = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  FileHandle.standardOutput.write(output + Data("\n".utf8))
}

do {
  try run()
} catch {
  FileHandle.standardError.write(Data("dory-pc-uefi-smoke: \(error)\n".utf8))
  exit(2)
}
