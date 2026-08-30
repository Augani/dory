import Darwin
import DoryFirmware
import DoryHV
import DoryMachineARMVirt
import DorydKit
import Foundation

#if !arch(arm64)
  FileHandle.standardError.write(
    Data("dory-armvirt-uefi-smoke requires Apple silicon\n".utf8)
  )
  exit(2)
#else
  private struct Options {
    var firmwareBundle: String?
    var timeoutSeconds: UInt64 = 15
    var expectedConsoleText = "UEFI Interactive Shell"
  }

  private struct Receipt: Codable {
    let schemaVersion: UInt32
    let machineABIIdentity: String
    let firmwareABIIdentity: String
    let buildIdentifier: String
    let firmwareCodeSHA256: String
    let expectedConsoleText: String
    let consoleByteCount: Int
    let bootAttempts: Int
    let variableStoreGeneration: UInt64
    let stopReason: String
  }

  private final class ConsoleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: [UInt8]
    private var bytes: [UInt8] = []
    private var didMatch = false

    init(expected: String) {
      self.expected = Array(expected.utf8)
    }

    func append(_ byte: UInt8) {
      lock.lock()
      defer { lock.unlock() }
      guard bytes.count < 1 << 20 else { return }
      bytes.append(byte)
      FileHandle.standardError.write(Data([byte]))
      if !didMatch, bytes.count >= expected.count,
        bytes.suffix(expected.count).elementsEqual(expected)
      {
        didMatch = true
      }
    }

    var matched: Bool {
      lock.lock()
      defer { lock.unlock() }
      return didMatch
    }

    var byteCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return bytes.count
    }
  }

  private final class RunnerCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var result: Result<GuestStopReason, any Error>?

    func publish(_ result: Result<GuestStopReason, any Error>) {
      lock.lock()
      self.result = result
      lock.unlock()
      signal.signal()
    }

    func wait(milliseconds: Int) -> Bool {
      signal.wait(timeout: .now() + .milliseconds(milliseconds)) == .success
    }

    func value() -> Result<GuestStopReason, any Error> {
      lock.lock()
      defer { lock.unlock() }
      return result!
    }
  }

  private struct BootResult {
    let reason: GuestStopReason
    let matchedConsole: Bool
  }

  private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dory-armvirt-uefi-smoke: \(message)\n".utf8))
    exit(1)
  }

  private func parseOptions(_ arguments: ArraySlice<String>) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--firmware-bundle":
        options.firmwareBundle = iterator.next()
      case "--timeout-sec":
        guard let value = iterator.next().flatMap(UInt64.init), (1...120).contains(value) else {
          fail("--timeout-sec must be within 1...120")
        }
        options.timeoutSeconds = value
      case "--expect":
        guard let value = iterator.next(), !value.isEmpty, value.utf8.count <= 1_024 else {
          fail("--expect must be a non-empty string no longer than 1024 bytes")
        }
        options.expectedConsoleText = value
      default:
        fail("unknown option \(argument)")
      }
    }
    return options
  }

  private func createSystemDisk(at path: String) throws {
    let descriptor = path.withCString {
      open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
    }
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
    }
    defer { close(descriptor) }
    guard ftruncate(descriptor, 64 << 20) == 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
    }
  }

  private func attachSystemDisk(_ backend: VirtioBlk, to machine: Machine) throws {
    let slot = 0
    let spi = GuestLayout.virtioFirstIRQ + UInt32(slot)
    let transport = VirtioMMIOTransport(
      baseAddress: GuestLayout.virtioBase + UInt64(slot) * GuestLayout.virtioSlotSize,
      backend: backend,
      memory: machine.memory
    ) { [weak machine] in
      machine?.raiseGSI(spi)
    }
    try machine.attachVirtioSlot(transport, at: slot)
  }

  private func runBoot(
    artifacts: DoryVerifiedFirmwareArtifacts,
    variableStore: DoryUEFIVariableStoreFile,
    systemDiskPath: String,
    systemDevice: DoryARMVirtUEFIBootDevice,
    capture: ConsoleCapture,
    timeoutSeconds: UInt64,
    attempt: Int
  ) throws -> BootResult {
    let generation = try variableStore.load().snapshot.generation
    let launchPlan = try DoryARMVirtUEFILaunchPlan(
      firmware: artifacts.manifest,
      variableStoreGeneration: generation,
      bootDevices: [systemDevice],
      bootOrder: [systemDevice.logicalID]
    )
    let machine = try Machine(
      configuration: MachineConfiguration(
        uefiLaunchPlan: launchPlan,
        artifacts: artifacts,
        variableStore: variableStore,
        memoryBytes: DoryARMVirtV1ABI.minimumMemoryBytes,
        cpuCount: 1
      )
    )
    machine.attachConsole(
      PL011(baseAddress: GuestLayout.uartBase, sink: capture.append) { [weak machine] asserted in
        machine?.setGSI(GuestLayout.uartIRQ, asserted: asserted)
      }
    )
    machine.bus.attach(PL031(baseAddress: GuestLayout.rtcBase))
    try attachSystemDisk(
      VirtioBlk(path: systemDiskPath, identity: "dory-uefi-smoke-system"),
      to: machine
    )
    try machine.loadBootPayload()

    let completion = RunnerCompletion()
    let runner = RawHVMachineRunner(
      machine: machine,
      threadName: "dory-armvirt-uefi-smoke.vcpu0.boot\(attempt)"
    )
    try runner.start(completion: completion.publish)
    let deadline = DispatchTime.now() + .seconds(Int(timeoutSeconds))
    while DispatchTime.now() < deadline {
      if capture.matched {
        return BootResult(
          reason: try runner.stopAndWait(GuestStopReason.powerOff),
          matchedConsole: true
        )
      }
      if completion.wait(milliseconds: 25) {
        return BootResult(reason: try completion.value().get(), matchedConsole: capture.matched)
      }
    }
    return BootResult(
      reason: try runner.stopAndWait(GuestStopReason.powerOff),
      matchedConsole: capture.matched
    )
  }

  private func describe(_ reason: GuestStopReason) -> String {
    switch reason {
    case .powerOff: return "power-off"
    case .reset: return "reset"
    case .crash(let message): return "crash: \(message)"
    }
  }

  private let options = parseOptions(CommandLine.arguments.dropFirst())
  guard let firmwareBundle = options.firmwareBundle else {
    fail("--firmware-bundle is required")
  }

  do {
    let canonicalBundle = URL(fileURLWithPath: firmwareBundle).standardizedFileURL.path
    let artifacts = try DoryARMVirtFirmwareBundle(directory: canonicalBundle).loadVerified()
    let template = try DoryUEFIVariableStoreSnapshot.decodeCanonicalTemplate(
      artifacts.variableStoreTemplate
    )
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("dory-armvirt-uefi-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryRoot,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let variableStore = try DoryUEFIVariableStoreFile(
      directory: temporaryRoot.appendingPathComponent("variables", isDirectory: true).path
    )
    try variableStore.initialize(template)
    let systemDiskPath = temporaryRoot.appendingPathComponent("system.raw").path
    try createSystemDisk(at: systemDiskPath)
    let systemDevice = try DoryARMVirtUEFIBootDevice(
      logicalID: "system",
      kind: .systemDisk,
      virtioSlot: 0,
      readOnly: false
    )
    let capture = ConsoleCapture(expected: options.expectedConsoleText)
    let maximumBootAttempts = 4
    var finalResult: BootResult?
    var bootAttempts = 0
    while bootAttempts < maximumBootAttempts {
      bootAttempts += 1
      let result = try runBoot(
        artifacts: artifacts,
        variableStore: variableStore,
        systemDiskPath: systemDiskPath,
        systemDevice: systemDevice,
        capture: capture,
        timeoutSeconds: options.timeoutSeconds,
        attempt: bootAttempts
      )
      if result.matchedConsole {
        finalResult = result
        break
      }
      guard case .reset = result.reason else {
        fail(
          "console did not emit \(String(reflecting: options.expectedConsoleText)); boot stopped with \(describe(result.reason))"
        )
      }
    }
    guard let finalResult else {
      fail(
        "console did not emit \(String(reflecting: options.expectedConsoleText)) after \(maximumBootAttempts) boot attempts"
      )
    }
    let generation = try variableStore.load().snapshot.generation
    let receipt = Receipt(
      schemaVersion: 1,
      machineABIIdentity: DoryARMVirtV1ABI.identity,
      firmwareABIIdentity: DoryARMVirtV1ABI.firmwareABIIdentity,
      buildIdentifier: artifacts.manifest.buildIdentifier,
      firmwareCodeSHA256: artifacts.manifest.firmwareCodeSHA256,
      expectedConsoleText: options.expectedConsoleText,
      consoleByteCount: capture.byteCount,
      bootAttempts: bootAttempts,
      variableStoreGeneration: generation,
      stopReason: describe(finalResult.reason)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(receipt))
    FileHandle.standardOutput.write(Data("\n".utf8))
  } catch {
    fail(String(describing: error))
  }
#endif
