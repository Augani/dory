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
  let memoryBytes: Int

  init(_ values: [String]) throws {
    var options: [String: String] = [:]
    var index = 1
    while index < values.count {
      guard index + 1 < values.count else {
        throw SmokeError.usage("missing value for \(values[index])")
      }
      let name = values[index]
      guard ["--firmware-bundle", "--max-instructions", "--memory-bytes"].contains(name)
      else { throw SmokeError.usage("unknown option: \(name)") }
      guard options.updateValue(values[index + 1], forKey: name) == nil else {
        throw SmokeError.usage("duplicate option: \(name)")
      }
      index += 2
    }
    guard let bundle = options["--firmware-bundle"], bundle.hasPrefix("/") else {
      throw SmokeError.usage(
        "usage: dory-pc-uefi-smoke --firmware-bundle /absolute/bundle "
          + "[--max-instructions count] [--memory-bytes count]"
      )
    }
    let instructionText = options["--max-instructions"] ?? "1000000"
    let memoryText = options["--memory-bytes"] ?? "268435456"
    guard let maximumInstructions = UInt64(instructionText), maximumInstructions > 0 else {
      throw SmokeError.invalidNumber(instructionText)
    }
    guard let memoryBytes = Int(memoryText), memoryBytes >= 128 * 1024 * 1024 else {
      throw SmokeError.invalidNumber(memoryText)
    }
    firmwareBundle = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
    self.maximumInstructions = maximumInstructions
    self.memoryBytes = memoryBytes
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

private func run() throws {
  let arguments = try Arguments(CommandLine.arguments)
  let artifacts = try loadArtifacts(from: arguments.firmwareBundle)
  guard artifacts.manifest.platform == .pcV1 else {
    throw SmokeError.usage("firmware bundle is not DoryPC-v1")
  }

  let variableDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "dory-pc-uefi-smoke-\(UUID().uuidString)",
    isDirectory: true
  )
  defer { try? FileManager.default.removeItem(at: variableDirectory) }
  let variableFile = try DoryUEFIVariableStoreFile(directory: variableDirectory.path)
  try variableFile.initialize(artifacts.initialVariableStore)

  let systemDevice = try DoryPCUEFIBootDevice(
    logicalID: "system-disk",
    kind: .systemDisk,
    pciAddress: DoryPCUEFIBootDevice.systemDiskAddress,
    readOnly: false
  )
  let plan = try DoryPCUEFILaunchPlan(
    firmware: artifacts.manifest,
    variableStoreGeneration: artifacts.initialVariableStore.generation,
    bootDevices: [systemDevice],
    bootOrder: [systemDevice.logicalID]
  )
  let storage = DoryVirtioInMemoryBlockStorage(byteCount: 64 * 1024 * 1024)
  let composed = try DoryPCUEFIMachine(
    plan: plan,
    firmware: artifacts,
    variableStore: .init(file: variableFile),
    bootStorage: [.init(logicalID: systemDevice.logicalID, storage: storage)],
    memoryBytes: arguments.memoryBytes
  )
  let stop = try composed.machine.run(maximumInstructions: arguments.maximumInstructions)
  let state = composed.machine.state
  let rip = state.map { hexadecimal($0.cs.base &+ $0.rip) } ?? "unavailable"
  let pageTrace = state.map {
    pageTableTrace(
      memory: composed.machine.memory,
      cr3: $0.control.cr3,
      linearAddress: $0.cs.base &+ $0.rip
    )
  } ?? []
  let physicalInstructionBytes: String = state.flatMap {
    try? composed.machine.memory.read(at: $0.cs.base &+ $0.rip, byteCount: 16)
  }.map(hexadecimalBytes) ?? "unmapped"
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
    "pageTableTrace": pageTrace,
    "physicalInstructionBytes": physicalInstructionBytes,
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
