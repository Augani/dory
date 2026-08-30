import CryptoKit
import Darwin
import DoryARMVirtQualification
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
    var installerMedia: String?
    var consoleScript: String?
    var gvproxy: String?
    var systemDiskBytes: UInt64 = 64 << 20
    var memoryBytes: UInt64 = DoryARMVirtV1ABI.minimumMemoryBytes
    var timeoutSeconds: UInt64 = 15
    var expectedConsoleText = "UEFI Interactive Shell"
  }

  private struct InstallerMedia {
    let path: String
    let byteCount: UInt64
    let sha256: String
    let device: DoryARMVirtUEFIBootDevice
  }

  private struct AdmittedConsoleScript {
    let sha256: String
    let driver: DoryConsoleInteractionDriver
  }

  private struct AdmittedGVProxy {
    let path: String
    let sha256: String
  }

  private struct Receipt: Codable {
    let schemaVersion: UInt32
    let machineABIIdentity: String
    let firmwareABIIdentity: String
    let buildIdentifier: String
    let firmwareCodeSHA256: String
    let expectedConsoleText: String
    let installerMediaByteCount: UInt64?
    let installerMediaSHA256: String?
    let systemDiskByteCount: UInt64
    let memoryByteCount: UInt64
    let consoleScriptSHA256: String?
    let consoleScriptStepCount: Int?
    let completedConsoleScriptStepCount: Int?
    let installerMediaTransitionCount: Int
    let installerMediaAttachedForFinalBoot: Bool
    let gvproxySHA256: String?
    let consoleByteCount: Int
    let bootAttempts: Int
    let variableStoreGeneration: UInt64
    let stopReason: String
  }

  private final class ConsoleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: [UInt8]
    private var bytes: [UInt8] = []
    private var latestMatchEnd: Int?

    init(expected: String) {
      self.expected = Array(expected.utf8)
    }

    func append(_ byte: UInt8) {
      lock.lock()
      defer { lock.unlock() }
      guard bytes.count < 1 << 20 else { return }
      bytes.append(byte)
      FileHandle.standardError.write(Data([byte]))
      if bytes.count >= expected.count,
        bytes.suffix(expected.count).elementsEqual(expected)
      {
        latestMatchEnd = bytes.count
      }
    }

    func matched(afterByteOffset offset: Int) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return latestMatchEnd.map { $0 > offset } ?? false
    }

    var byteCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return bytes.count
    }

    func nextInput(using driver: DoryConsoleInteractionDriver) -> [UInt8]? {
      lock.lock()
      defer { lock.unlock() }
      return driver.nextInput(consoleBytes: bytes)
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
        guard let value = iterator.next() else {
          fail("--firmware-bundle requires a path")
        }
        options.firmwareBundle = value
      case "--installer-media":
        guard let value = iterator.next() else {
          fail("--installer-media requires a path")
        }
        options.installerMedia = value
      case "--console-script":
        guard let value = iterator.next() else {
          fail("--console-script requires a path")
        }
        options.consoleScript = value
      case "--gvproxy":
        guard let value = iterator.next() else {
          fail("--gvproxy requires a path")
        }
        options.gvproxy = value
      case "--system-disk-bytes":
        guard let value = iterator.next().flatMap(UInt64.init),
          ((UInt64(64) << 20)...(UInt64(64) << 30)).contains(value),
          value.isMultiple(of: 512)
        else {
          fail("--system-disk-bytes must be a 512-byte-aligned value within 64 MiB...64 GiB")
        }
        options.systemDiskBytes = value
      case "--memory-bytes":
        guard let value = iterator.next().flatMap(UInt64.init),
          (DoryARMVirtV1ABI.minimumMemoryBytes...(UInt64(16) << 30)).contains(value),
          value.isMultiple(of: 16 << 10)
        else {
          fail("--memory-bytes must be a 16-KiB-aligned value within 1...16 GiB")
        }
        options.memoryBytes = value
      case "--timeout-sec":
        guard let value = iterator.next().flatMap(UInt64.init), (1...900).contains(value) else {
          fail("--timeout-sec must be within 1...900")
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

  private func createSystemDisk(at path: String, byteCount: UInt64) throws {
    let descriptor = path.withCString {
      open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
    }
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
    }
    defer { close(descriptor) }
    guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
    }
  }

  private func attachVirtioDevice(
    _ backend: VirtioDeviceBackend,
    slot: Int,
    to machine: Machine
  ) throws {
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

  private func admitInstallerMedia(at suppliedPath: String) throws -> InstallerMedia {
    let path = URL(fileURLWithPath: suppliedPath).resolvingSymlinksInPath().path
    var fileStatus = stat()
    guard lstat(path, &fileStatus) == 0,
      fileStatus.st_mode & S_IFMT == S_IFREG,
      fileStatus.st_uid == geteuid(),
      fileStatus.st_mode & 0o077 == 0,
      fileStatus.st_size > 0,
      fileStatus.st_size % 512 == 0,
      UInt64(fileStatus.st_size) <= 32 * 1_024 * 1_024 * 1_024
    else {
      fail(
        "--installer-media must name a private, owned, non-empty, 512-byte-aligned regular file no larger than 32 GiB"
      )
    }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return InstallerMedia(
      path: path,
      byteCount: UInt64(fileStatus.st_size),
      sha256: digest,
      device: try DoryARMVirtUEFIBootDevice(
        logicalID: "installer",
        kind: .removableMedia,
        virtioSlot: 12,
        readOnly: true
      )
    )
  }

  private func admitConsoleScript(at suppliedPath: String) throws -> AdmittedConsoleScript {
    let path = URL(fileURLWithPath: suppliedPath).resolvingSymlinksInPath().path
    var fileStatus = stat()
    guard lstat(path, &fileStatus) == 0,
      fileStatus.st_mode & S_IFMT == S_IFREG,
      fileStatus.st_uid == geteuid(),
      fileStatus.st_mode & 0o077 == 0,
      fileStatus.st_size > 0,
      fileStatus.st_size <= 1 << 20
    else {
      fail("--console-script must name a private, owned regular file no larger than 1 MiB")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    let script = try JSONDecoder().decode(DoryConsoleInteractionScript.self, from: data)
    return AdmittedConsoleScript(
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      driver: try DoryConsoleInteractionDriver(script: script)
    )
  }

  private func admitGVProxy(at suppliedPath: String) throws -> AdmittedGVProxy {
    let path = URL(fileURLWithPath: suppliedPath).resolvingSymlinksInPath().path
    var fileStatus = stat()
    guard lstat(path, &fileStatus) == 0,
      fileStatus.st_mode & S_IFMT == S_IFREG,
      fileStatus.st_uid == geteuid(),
      fileStatus.st_mode & 0o022 == 0,
      fileStatus.st_mode & 0o111 != 0,
      fileStatus.st_size > 0,
      UInt64(fileStatus.st_size) <= 256 << 20
    else {
      fail("--gvproxy must name an owned, non-writable executable no larger than 256 MiB")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    return AdmittedGVProxy(
      path: path,
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    )
  }

  private func stopSidecar(_ process: Process) {
    if process.isRunning {
      process.terminate()
      let deadline = DispatchTime.now() + .seconds(2)
      while process.isRunning, DispatchTime.now() < deadline {
        usleep(10_000)
      }
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
  }

  private func runBoot(
    artifacts: DoryVerifiedFirmwareArtifacts,
    variableStore: DoryUEFIVariableStoreFile,
    systemDiskPath: String,
    systemDevice: DoryARMVirtUEFIBootDevice,
    installerMedia: InstallerMedia?,
    capture: ConsoleCapture,
    consoleScript: AdmittedConsoleScript?,
    gvproxy: AdmittedGVProxy?,
    memoryBytes: UInt64,
    appliedInstallerMediaTransitionCount: Int,
    timeoutSeconds: UInt64,
    attempt: Int
  ) throws -> BootResult {
    let generation = try variableStore.load().snapshot.generation
    let bootDevices = [systemDevice] + (installerMedia.map { [$0.device] } ?? [])
    let launchPlan = try DoryARMVirtUEFILaunchPlan(
      firmware: artifacts.manifest,
      variableStoreGeneration: generation,
      bootDevices: bootDevices,
      bootOrder: (installerMedia.map { [$0.device.logicalID] } ?? []) + [systemDevice.logicalID]
    )
    let machine = try Machine(
      configuration: MachineConfiguration(
        uefiLaunchPlan: launchPlan,
        artifacts: artifacts,
        variableStore: variableStore,
        memoryBytes: memoryBytes,
        cpuCount: 1
      )
    )
    let console = PL011(baseAddress: GuestLayout.uartBase, sink: capture.append) {
      [weak machine] asserted in
      machine?.setGSI(GuestLayout.uartIRQ, asserted: asserted)
    }
    machine.attachConsole(console)
    machine.bus.attach(PL031(baseAddress: GuestLayout.rtcBase))
    try attachVirtioDevice(
      VirtioBlk(path: systemDiskPath, identity: "dory-uefi-smoke-system"),
      slot: systemDevice.virtioSlot,
      to: machine
    )
    if let installerMedia {
      try attachVirtioDevice(
        VirtioBlk(
          path: installerMedia.path,
          identity: "dory-uefi-smoke-installer",
          readOnly: true,
          queueCount: 1,
          discard: false
        ),
        slot: installerMedia.device.virtioSlot,
        to: machine
      )
    }
    var networkSidecar: Process?
    var networkPaths: [String] = []
    var networkSocketRoot: URL?
    defer {
      if let networkSidecar {
        stopSidecar(networkSidecar)
      }
      networkPaths.forEach { unlink($0) }
      if let networkSocketRoot {
        try? FileManager.default.removeItem(at: networkSocketRoot)
      }
    }
    if let gvproxy {
      let socketRoot = URL(
        fileURLWithPath: "/tmp/dory-av-\(getpid())-\(attempt)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: socketRoot,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      networkSocketRoot = socketRoot
      let remotePath = socketRoot.appendingPathComponent("gv.sock").path
      let localPath = socketRoot.appendingPathComponent("vm.sock").path
      let apiPath = socketRoot.appendingPathComponent("api.sock").path
      networkPaths = [remotePath, localPath, apiPath]
      networkPaths.forEach { unlink($0) }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: gvproxy.path)
      process.arguments = [
        "-mtu", "1500",
        "-listen-vfkit", "unixgram://\(remotePath)",
        "-listen", "unix://\(apiPath)",
        "-ssh-port", "-1",
      ]
      process.standardOutput = FileHandle.standardError
      process.standardError = FileHandle.standardError
      try process.run()
      networkSidecar = process
      let readyDeadline = DispatchTime.now() + .seconds(5)
      while process.isRunning,
        !FileManager.default.fileExists(atPath: remotePath),
        DispatchTime.now() < readyDeadline
      {
        usleep(20_000)
      }
      guard process.isRunning, FileManager.default.fileExists(atPath: remotePath) else {
        throw CocoaError(.executableLoad)
      }
      guard let networkSlot = DoryARMVirtV1ABI.virtioSlots.first(where: { $0.role == .network })
      else {
        throw VMError.invalidConfiguration("\(DoryARMVirtV1ABI.identity) has no network slot")
      }
      try attachVirtioDevice(
        VirtioNet(socketPath: localPath, remotePath: remotePath, maximumTransmissionUnit: 1_500),
        slot: networkSlot.index,
        to: machine
      )
    }
    try machine.loadBootPayload()

    let completion = RunnerCompletion()
    let runner = RawHVMachineRunner(
      machine: machine,
      threadName: "dory-armvirt-uefi-smoke.vcpu0.boot\(attempt)"
    )
    let consoleStartOffset = capture.byteCount
    try runner.start(completion: completion.publish)
    let deadline = DispatchTime.now() + .seconds(Int(timeoutSeconds))
    while DispatchTime.now() < deadline {
      if let input = consoleScript.flatMap({ capture.nextInput(using: $0.driver) }),
        !console.receive(input)
      {
        throw CocoaError(.fileWriteOutOfSpace)
      }
      let matchedConsole =
        (consoleScript?.driver.installerMediaTransitionCount ?? 0)
        == appliedInstallerMediaTransitionCount
        && capture.matched(afterByteOffset: consoleStartOffset)
        && consoleScript?.driver.isComplete != false
      if matchedConsole {
        return BootResult(
          reason: try runner.stopAndWait(GuestStopReason.powerOff),
          matchedConsole: true
        )
      }
      if completion.wait(milliseconds: 25) {
        return BootResult(
          reason: try completion.value().get(),
          matchedConsole: (consoleScript?.driver.installerMediaTransitionCount ?? 0)
            == appliedInstallerMediaTransitionCount
            && capture.matched(afterByteOffset: consoleStartOffset)
            && consoleScript?.driver.isComplete != false
        )
      }
    }
    return BootResult(
      reason: try runner.stopAndWait(GuestStopReason.powerOff),
      matchedConsole: (consoleScript?.driver.installerMediaTransitionCount ?? 0)
        == appliedInstallerMediaTransitionCount
        && capture.matched(afterByteOffset: consoleStartOffset)
        && consoleScript?.driver.isComplete != false
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
    try createSystemDisk(at: systemDiskPath, byteCount: options.systemDiskBytes)
    let systemDevice = try DoryARMVirtUEFIBootDevice(
      logicalID: "system",
      kind: .systemDisk,
      virtioSlot: 0,
      readOnly: false
    )
    let installerMedia = try options.installerMedia.map(admitInstallerMedia)
    let consoleScript = try options.consoleScript.map(admitConsoleScript)
    let gvproxy = try options.gvproxy.map(admitGVProxy)
    if consoleScript?.driver.inputContains(options.expectedConsoleText) == true {
      fail("--expect must not occur in console-script input because guest echo could forge success")
    }
    if consoleScript?.driver.containsInstallerMediaTransition == true, installerMedia == nil {
      fail("a console script that transitions installer media requires --installer-media")
    }
    let capture = ConsoleCapture(expected: options.expectedConsoleText)
    let maximumBootAttempts = 4
    var finalResult: BootResult?
    var bootAttempts = 0
    var installerMediaAttachedForFinalBoot = installerMedia != nil
    while bootAttempts < maximumBootAttempts {
      bootAttempts += 1
      let attachedInstaller =
        consoleScript?.driver.installerMediaState == .detached
        ? nil : installerMedia
      installerMediaAttachedForFinalBoot = attachedInstaller != nil
      let appliedInstallerMediaTransitionCount =
        consoleScript?.driver.installerMediaTransitionCount ?? 0
      let result = try runBoot(
        artifacts: artifacts,
        variableStore: variableStore,
        systemDiskPath: systemDiskPath,
        systemDevice: systemDevice,
        installerMedia: attachedInstaller,
        capture: capture,
        consoleScript: consoleScript,
        gvproxy: gvproxy,
        memoryBytes: options.memoryBytes,
        appliedInstallerMediaTransitionCount: appliedInstallerMediaTransitionCount,
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
      schemaVersion: 3,
      machineABIIdentity: DoryARMVirtV1ABI.identity,
      firmwareABIIdentity: DoryARMVirtV1ABI.firmwareABIIdentity,
      buildIdentifier: artifacts.manifest.buildIdentifier,
      firmwareCodeSHA256: artifacts.manifest.firmwareCodeSHA256,
      expectedConsoleText: options.expectedConsoleText,
      installerMediaByteCount: installerMedia?.byteCount,
      installerMediaSHA256: installerMedia?.sha256,
      systemDiskByteCount: options.systemDiskBytes,
      memoryByteCount: options.memoryBytes,
      consoleScriptSHA256: consoleScript?.sha256,
      consoleScriptStepCount: consoleScript?.driver.stepCount,
      completedConsoleScriptStepCount: consoleScript?.driver.completedStepCount,
      installerMediaTransitionCount: consoleScript?.driver.installerMediaTransitionCount ?? 0,
      installerMediaAttachedForFinalBoot: installerMediaAttachedForFinalBoot,
      gvproxySHA256: gvproxy?.sha256,
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
