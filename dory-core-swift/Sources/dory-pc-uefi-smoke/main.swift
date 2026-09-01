import CryptoKit
import DoryDBTX86
import DoryFirmware
import DoryMachinePC
import DoryVirtio
import Foundation

private enum SmokeError: Error, CustomStringConvertible {
  case usage(String)
  case invalidNumber(String)
  case missingSerialMarker(String)

  var description: String {
    switch self {
    case .usage(let message): message
    case .invalidNumber(let value): "invalid unsigned integer: \(value)"
    case .missingSerialMarker(let marker): "expected serial marker was not observed: \(marker)"
    }
  }
}

private struct FileIdentity {
  let byteCount: UInt64
  let sha256: String
}

private func identity(of file: URL) throws -> FileIdentity {
  let handle = try FileHandle(forReadingFrom: file)
  defer { try? handle.close() }
  var hasher = SHA256()
  var byteCount: UInt64 = 0
  while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
    hasher.update(data: bytes)
    byteCount += UInt64(bytes.count)
  }
  let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
  return FileIdentity(byteCount: byteCount, sha256: digest)
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
  let expectedSerialMarker: String?
  let bootProbe: Bool
  let initialRTCUnixSeconds: UInt64
  let traceAfterInstructions: UInt64?
  let traceCapacity: Int
  let traceBreakRIPBelow: UInt64?

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
          "--expected-serial-marker",
          "--boot-probe",
          "--initial-rtc-unix-seconds",
          "--trace-after-instructions", "--trace-capacity", "--trace-break-rip-below",
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
          + "[--expected-serial-marker text] "
          + "[--boot-probe enabled|disabled] "
          + "[--initial-rtc-unix-seconds seconds] "
          + "[--trace-after-instructions count] [--trace-capacity count] "
          + "[--trace-break-rip-below address] "
          + "[--max-instructions count] [--progress-instructions count] [--memory-bytes count]"
      )
    }
    let instructionText = options["--max-instructions"] ?? "1000000"
    let progressText = options["--progress-instructions"] ?? "10000000"
    let memoryText =
      options["--memory-bytes"] ?? String(DoryPCV1ABI.minimumProductMemoryBytes)
    let processorText = options["--processor-count"] ?? "1"
    let rtcText = options["--initial-rtc-unix-seconds"] ?? "0"
    let traceCapacityText = options["--trace-capacity"] ?? "256"
    guard let maximumInstructions = UInt64(instructionText), maximumInstructions > 0 else {
      throw SmokeError.invalidNumber(instructionText)
    }
    guard let progressInstructions = UInt64(progressText), progressInstructions > 0 else {
      throw SmokeError.invalidNumber(progressText)
    }
    guard let parsedMemoryBytes = UInt64(memoryText), parsedMemoryBytes <= UInt64(Int.max),
      (try? DoryPCV1ABI.validateProductMemoryBytes(parsedMemoryBytes)) != nil
    else {
      throw SmokeError.invalidNumber(memoryText)
    }
    let memoryBytes = Int(parsedMemoryBytes)
    guard let processorCount = Int(processorText), (1...255).contains(processorCount) else {
      throw SmokeError.invalidNumber(processorText)
    }
    guard let initialRTCUnixSeconds = UInt64(rtcText) else {
      throw SmokeError.invalidNumber(rtcText)
    }
    guard let traceCapacity = Int(traceCapacityText), (1...4096).contains(traceCapacity) else {
      throw SmokeError.invalidNumber(traceCapacityText)
    }
    if let traceText = options["--trace-after-instructions"] {
      guard let traceAfterInstructions = UInt64(traceText) else {
        throw SmokeError.invalidNumber(traceText)
      }
      self.traceAfterInstructions = traceAfterInstructions
    } else {
      traceAfterInstructions = nil
    }
    self.traceCapacity = traceCapacity
    if let breakText = options["--trace-break-rip-below"] {
      guard let traceBreakRIPBelow = UInt64(breakText), traceBreakRIPBelow > 0 else {
        throw SmokeError.invalidNumber(breakText)
      }
      self.traceBreakRIPBelow = traceBreakRIPBelow
    } else {
      traceBreakRIPBelow = nil
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
    if let marker = options["--expected-serial-marker"], marker.isEmpty {
      throw SmokeError.usage("expected serial marker must not be empty")
    }
    expectedSerialMarker = options["--expected-serial-marker"]
    let bootProbeText = options["--boot-probe"] ?? "disabled"
    switch bootProbeText {
    case "enabled": bootProbe = true
    case "disabled": bootProbe = false
    default: throw SmokeError.usage("invalid boot probe policy: \(bootProbeText)")
    }
    self.initialRTCUnixSeconds = initialRTCUnixSeconds
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

private func sha256<T: Encodable>(of value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return SHA256.hash(data: try encoder.encode(value))
    .map { String(format: "%02x", $0) }
    .joined()
}

private func completedInstructions(for stop: DoryPCMachineStop) -> UInt64 {
  switch stop {
  case .halted(let instructionCount), .exception(_, let instructionCount),
    .tripleFault(let instructionCount), .poweredOff(let instructionCount),
    .reset(let instructionCount), .instructionBudget(let instructionCount):
    instructionCount
  }
}

private func blockDeviceDiagnostics(
  _ blockDevices: [DoryPCVirtioBlockPCIDevice],
  memory: any DoryX86Memory
) -> [[String: Any]] {
  blockDevices.map { device in
    let state = device.transport.deviceState.snapshot()
    let queue = try? device.transport.queue(at: 0).snapshot()
    let bar = try? device.configurationFunction.bar(at: 0)
    return [
      "identifier": String(decoding: device.blockDevice.identifier, as: UTF8.self),
      "pciAddress": String(
        format: "%04x:%02x:%02x.%x",
        device.pciAddress.segment,
        device.pciAddress.bus,
        device.pciAddress.device,
        device.pciAddress.function
      ),
      "offeredFeatures": state.offeredFeatures.rawValue,
      "negotiatedFeatures": state.negotiatedFeatures.rawValue,
      "status": state.status.rawValue,
      "pciCommand": device.configurationFunction.command,
      "bar0": bar.map { hexadecimal($0.address) } ?? "unavailable",
      "queueEnabled": queue?.enabled ?? false,
      "queueSize": queue?.size ?? 0,
      "queueDescriptorAddress": queue.map { hexadecimal($0.descriptorAddress) } ?? "unavailable",
      "queueDriverAddress": queue.map { hexadecimal($0.driverAddress) } ?? "unavailable",
      "queueDeviceAddress": queue.map { hexadecimal($0.deviceAddress) } ?? "unavailable",
      "guestAvailableIndex": queue.flatMap {
        queueIndex(memory: memory, address: $0.driverAddress &+ 2)
      } ?? "unavailable",
      "guestUsedIndex": queue.flatMap {
        queueIndex(memory: memory, address: $0.deviceAddress &+ 2)
      } ?? "unavailable",
      "queueAvailableIndex": queue?.lastAvailableIndex ?? 0,
      "queueUsedIndex": queue?.lastUsedIndex ?? 0,
      "queueOutstandingHeads": queue?.outstandingHeads.count ?? 0,
    ]
  }
}

private func queueIndex(memory: any DoryX86Memory, address: UInt64) -> String? {
  guard address > 2, let bytes = try? memory.read(at: address, byteCount: 2) else { return nil }
  let value = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
  return String(value)
}

private func runWithProgress(
  machine: DoryPCDirectKernelMachine,
  blockDevices: [DoryPCVirtioBlockPCIDevice],
  maximumInstructions: UInt64,
  progressInstructions: UInt64,
  exceptionPolicy: DoryPCExceptionPolicy,
  traceAfterInstructions: UInt64?,
  traceCapacity: Int,
  traceBreakRIPBelow: UInt64?
) throws -> (stop: DoryPCMachineStop, trace: [[String: Any]], traceStopReason: String?) {
  var completed: UInt64 = 0
  var trace: [[String: Any]] = []
  while completed < maximumInstructions {
    let tracing = traceAfterInstructions.map { completed >= $0 } ?? false
    if tracing, let state = machine.state {
      let bytes = (try? machine.instructionBytes(maximumCount: 16)) ?? nil
      let statistics = machine.executionStatistics
      trace.append([
        "instruction": completed,
        "rip": hexadecimal(state.cs.base &+ state.rip),
        "bytes": bytes.map(hexadecimalBytes) ?? "unmapped",
        "rax": hexadecimal(state.registers.rax),
        "rbx": hexadecimal(state.registers.rbx),
        "rcx": hexadecimal(state.registers.rcx),
        "rdx": hexadecimal(state.registers.rdx),
        "rbp": hexadecimal(state.registers.rbp),
        "rsi": hexadecimal(state.registers.rsi),
        "rdi": hexadecimal(state.registers.rdi),
        "rsp": hexadecimal(state.registers.rsp),
        "rflags": hexadecimal(state.rflags.rawValue),
        "interpreterInstructions": statistics.interpreterInstructions,
        "baselineJITInstructions": statistics.baselineJITInstructions,
        "optimizingJITInstructions": statistics.optimizingJITInstructions,
      ])
      if trace.count > traceCapacity { trace.removeFirst(trace.count - traceCapacity) }
      if let traceBreakRIPBelow, state.cs.base &+ state.rip < traceBreakRIPBelow {
        return (.instructionBudget(completed), trace, "instruction-pointer-below-threshold")
      }
    }
    let distanceToTrace = traceAfterInstructions.map { $0 > completed ? $0 - completed : 0 } ?? 0
    let chunk = min(
      tracing ? 1 : max(1, min(progressInstructions, distanceToTrace == 0 ? progressInstructions : distanceToTrace)),
      maximumInstructions - completed
    )
    let stop = try machine.run(maximumInstructions: chunk, exceptionPolicy: exceptionPolicy)
    switch stop {
    case .instructionBudget(let count):
      completed &+= count
      guard !tracing else { continue }
      let state = machine.state
      let statistics = machine.executionStatistics
      let payload: [String: Any] = [
        "completedInstructions": completed,
        "instructionPointer": state.map { hexadecimal($0.cs.base &+ $0.rip) } ?? "unavailable",
        "interpreterInstructions": statistics.interpreterInstructions,
        "baselineJITInstructions": statistics.baselineJITInstructions,
        "optimizingJITInstructions": statistics.optimizingJITInstructions,
        "blockDevices": blockDeviceDiagnostics(blockDevices, memory: machine.physicalMemory),
      ]
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      FileHandle.standardError.write(data + Data("\n".utf8))
    case .halted(let count): return (.halted(instructionCount: completed &+ count), trace, nil)
    case .exception(let exception, let count):
      return (.exception(exception, instructionCount: completed &+ count), trace, nil)
    case .tripleFault(let count):
      return (.tripleFault(instructionCount: completed &+ count), trace, nil)
    case .poweredOff(let count):
      return (.poweredOff(instructionCount: completed &+ count), trace, nil)
    case .reset(let count): return (.reset(instructionCount: completed &+ count), trace, nil)
    }
  }
  return (.instructionBudget(completed), trace, nil)
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
  let runnerIdentity = try identity(of: URL(fileURLWithPath: CommandLine.arguments[0]))
  let installerIdentity = try arguments.installerMedia.map { try identity(of: $0) }
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
    initialRTCDate: Date(timeIntervalSince1970: TimeInterval(arguments.initialRTCUnixSeconds)),
    firmwareConfigurationFlags: arguments.bootProbe ? [.qualificationBootProbe] : [],
    executionTier: arguments.executionTier
  )
  let execution = try runWithProgress(
    machine: composed.machine,
    blockDevices: composed.blockDevices,
    maximumInstructions: arguments.maximumInstructions,
    progressInstructions: arguments.progressInstructions,
    exceptionPolicy: arguments.exceptionPolicy,
    traceAfterInstructions: arguments.traceAfterInstructions,
    traceCapacity: arguments.traceCapacity,
    traceBreakRIPBelow: arguments.traceBreakRIPBelow
  )
  let stop = execution.stop
  let executionStatistics = composed.machine.executionStatistics
  let state = composed.machine.state
  let architecturalStateSHA256 = try state.map(sha256(of:))
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
      (try? composed.machine.memoryBytes(atLinearAddress: $0.registers.rsp, maximumCount: 64))
        ?? nil
    }
  let serialBytes = composed.machine.serial.drainTransmittedBytes()
  let serialOutput = String(decoding: serialBytes, as: UTF8.self)
  let serialMarkerMatched = arguments.expectedSerialMarker.map(serialOutput.contains)
  let serialDrops = composed.machine.serial.dropCounts
  let blockDevices = blockDeviceDiagnostics(
    composed.blockDevices,
    memory: composed.machine.physicalMemory
  )
  let payload: [String: Any] = [
    "cr0": state.map { hexadecimal($0.control.cr0) } ?? "unavailable",
    "cr3": state.map { hexadecimal($0.control.cr3) } ?? "unavailable",
    "cr4": state.map { hexadecimal($0.control.cr4) } ?? "unavailable",
    "csAttributes": state.map { String(format: "0x%04x", $0.cs.attributes) } ?? "unavailable",
    "csBase": state.map { hexadecimal($0.cs.base) } ?? "unavailable",
    "csSelector": state.map { String(format: "0x%04x", $0.cs.selector) } ?? "unavailable",
    "efer": state.map { hexadecimal($0.control.efer) } ?? "unavailable",
    "firmwareABIIdentity": artifacts.manifest.firmwareABIIdentity,
    "firmwareBuildIdentifier": artifacts.manifest.buildIdentifier,
    "firmwareCodeByteCount": artifacts.manifest.firmwareCodeByteCount,
    "firmwareCodeSHA256": artifacts.manifest.firmwareCodeSHA256,
    "gdtrBase": state.map { hexadecimal($0.gdtr.base) } ?? "unavailable",
    "gdtrLimit": state.map { String(format: "0x%04x", $0.gdtr.limit) } ?? "unavailable",
    "instructionPointer": rip,
    "initialRTCUnixSeconds": arguments.initialRTCUnixSeconds,
    "machineABIIdentity": artifacts.manifest.machineABIIdentity,
    "memoryBytes": arguments.memoryBytes,
    "maximumInstructions": arguments.maximumInstructions,
    "progressInstructions": arguments.progressInstructions,
    "traceAfterInstructions": arguments.traceAfterInstructions.map { $0 as Any } ?? NSNull(),
    "traceBreakRIPBelow": arguments.traceBreakRIPBelow.map { $0 as Any } ?? NSNull(),
    "traceStopReason": execution.traceStopReason.map { $0 as Any } ?? NSNull(),
    "instructionTrace": execution.trace,
    "processorCount": arguments.processorCount,
    "bootOrder": bootOrder,
    "exceptionPolicy": arguments.exceptionPolicy == .stop ? "stop" : "deliver",
    "executionTier": arguments.executionTier.rawValue,
    "completedInstructions": completedInstructions(for: stop),
    "architecturalStateSHA256": architecturalStateSHA256.map { $0 as Any } ?? NSNull(),
    "interpreterInstructions": executionStatistics.interpreterInstructions,
    "baselineJITInstructions": executionStatistics.baselineJITInstructions,
    "baselineJITBlocks": executionStatistics.baselineJITBlocks,
    "optimizingJITInstructions": executionStatistics.optimizingJITInstructions,
    "optimizingJITBlocks": executionStatistics.optimizingJITBlocks,
    "persistentSystemDisk": arguments.systemDisk?.path ?? "in-memory",
    "installerMedia": arguments.installerMedia?.path ?? "none",
    "installerMediaByteCount": installerIdentity.map { $0.byteCount as Any } ?? NSNull(),
    "installerMediaSHA256": installerIdentity.map { $0.sha256 as Any } ?? NSNull(),
    "runnerByteCount": runnerIdentity.byteCount,
    "runnerSHA256": runnerIdentity.sha256,
    "sbomSHA256": artifacts.manifest.sbomSHA256,
    "variableStoreTemplateByteCount": artifacts.manifest.variableStoreTemplateByteCount,
    "variableStoreTemplateSHA256": artifacts.manifest.variableStoreTemplateSHA256,
    "variableStoreDirectory": ownsVariableDirectory ? "temporary" : variableDirectory.path,
    "pageTableTrace": pageTrace,
    "instructionBytes": instructionBytes.map(hexadecimalBytes) ?? "unmapped",
    "stackBytes": stackBytes.map(hexadecimalBytes) ?? "unmapped",
    "serialOutput": serialOutput,
    "serialMarkerExpected": arguments.expectedSerialMarker.map { $0 as Any } ?? NSNull(),
    "serialMarkerMatched": serialMarkerMatched.map { $0 as Any } ?? NSNull(),
    "bootProbe": arguments.bootProbe,
    "serialDroppedBytes": serialDrops.transmitted,
    "blockDevices": blockDevices,
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
  if let marker = arguments.expectedSerialMarker, serialMarkerMatched != true {
    throw SmokeError.missingSerialMarker(marker)
  }
}

do {
  try run()
} catch {
  FileHandle.standardError.write(Data("dory-pc-uefi-smoke: \(error)\n".utf8))
  exit(2)
}
