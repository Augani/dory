import CryptoKit
import Darwin
import DoryARMVirtQualification
import DoryFirmware
import DoryHV
import DoryMachineARMVirt
import DoryOperations
import DorydKit
import Foundation
import IOKit.ps

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
    var compatibilityMatrix: String?
    var qualificationGate: String?
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

  private struct AdmittedQualificationGate {
    let matrixData: Data
    let matrixSHA256: String
    let gate: DoryARMVirtCompatibilityGate
    let media: DoryARMVirtCompatibilityMedia
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

  private struct DisplayQualificationSnapshot {
    let scanoutCount: Int
    let contentFrameCount: UInt64
    let contentFrameWidthPixels: UInt32
    let contentFrameHeightPixels: UInt32
    let contentFrameByteCount: Int
    let contentFrameNonZeroByteCount: Int
    let contentFrameSHA256: String
  }

  private final class DisplayQualificationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var observedScanouts = Set<UInt32>()
    private var contentFrameCount: UInt64 = 0
    private var latestContentFrame: DisplayQualificationSnapshot?

    func append(_ frame: VirtioGPUScanoutFrame) {
      let nonZeroByteCount = frame.bytes.reduce(into: 0) { count, byte in
        if byte != 0 { count += 1 }
      }
      guard nonZeroByteCount > 0 else { return }
      let digest = SHA256.hash(data: frame.bytes)
        .map { String(format: "%02x", $0) }.joined()
      lock.lock()
      defer { lock.unlock() }
      observedScanouts.insert(frame.scanoutID)
      contentFrameCount &+= 1
      latestContentFrame = DisplayQualificationSnapshot(
        scanoutCount: 0,
        contentFrameCount: 0,
        contentFrameWidthPixels: frame.width,
        contentFrameHeightPixels: frame.height,
        contentFrameByteCount: frame.bytes.count,
        contentFrameNonZeroByteCount: nonZeroByteCount,
        contentFrameSHA256: digest
      )
    }

    func satisfies(_ expectation: DoryARMVirtDisplayExpectation) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard let latestContentFrame else { return false }
      return observedScanouts.count == expectation.scanoutCount
        && contentFrameCount >= expectation.minimumContentFrameCount
        && latestContentFrame.contentFrameWidthPixels == expectation.widthPixels
        && latestContentFrame.contentFrameHeightPixels == expectation.heightPixels
    }

    var snapshot: DisplayQualificationSnapshot? {
      lock.lock()
      defer { lock.unlock() }
      guard let latestContentFrame else { return nil }
      return DisplayQualificationSnapshot(
        scanoutCount: observedScanouts.count,
        contentFrameCount: contentFrameCount,
        contentFrameWidthPixels: latestContentFrame.contentFrameWidthPixels,
        contentFrameHeightPixels: latestContentFrame.contentFrameHeightPixels,
        contentFrameByteCount: latestContentFrame.contentFrameByteCount,
        contentFrameNonZeroByteCount: latestContentFrame.contentFrameNonZeroByteCount,
        contentFrameSHA256: latestContentFrame.contentFrameSHA256
      )
    }
  }

  private struct InputQualificationSnapshot {
    let keyboard: VirtioInputStatistics
    let pointer: VirtioInputStatistics
  }

  private final class InputQualificationCapture: @unchecked Sendable {
    let keyboard = VirtioInput(profile: .keyboard)
    let pointer = VirtioInput(profile: .absolutePointer)

    private let lock = NSLock()
    private var submitted = false

    func submitOnce() {
      lock.lock()
      guard !submitted else {
        lock.unlock()
        return
      }
      submitted = true
      lock.unlock()
      keyboard.send(frame: [
        VirtioInputEvent(type: 1, code: 1, value: 1),
        VirtioInputEvent(type: 1, code: 1, value: 0),
      ])
      pointer.send(frame: [
        VirtioInputEvent(type: 3, code: 0, value: 16_384),
        VirtioInputEvent(type: 3, code: 1, value: 16_384),
      ])
    }

    func satisfies(_ expectation: DoryARMVirtInputExpectation) -> Bool {
      let snapshot = self.snapshot
      return snapshot.keyboard.publishedFrames
        >= expectation.keyboardMinimumPublishedFrameCount
        && snapshot.keyboard.publishedEvents
          >= expectation.keyboardMinimumPublishedEventCount
        && snapshot.pointer.publishedFrames
          >= expectation.pointerMinimumPublishedFrameCount
        && snapshot.pointer.publishedEvents
          >= expectation.pointerMinimumPublishedEventCount
        && snapshot.keyboard.droppedFrames == 0
        && snapshot.keyboard.rejectedFrames == 0
        && snapshot.pointer.droppedFrames == 0
        && snapshot.pointer.rejectedFrames == 0
    }

    var snapshot: InputQualificationSnapshot {
      InputQualificationSnapshot(
        keyboard: keyboard.statistics,
        pointer: pointer.statistics
      )
    }
  }

  private struct AudioQualificationHostSnapshot {
    let configuredPlaybackStreamCount: UInt64
    let configuredCaptureStreamCount: UInt64
    let startedPlaybackStreamCount: UInt64
    let startedCaptureStreamCount: UInt64
    let playbackByteCount: UInt64
    let captureByteCount: UInt64
  }

  private final class AudioQualificationHost: VirtioSoundHost, @unchecked Sendable {
    private let lock = NSLock()
    private let completionQueue = DispatchQueue(
      label: "com.dory.armvirt-qualification.audio",
      qos: .userInitiated
    )
    private var configuredPlaybackStreamCount: UInt64 = 0
    private var configuredCaptureStreamCount: UInt64 = 0
    private var startedPlaybackStreamCount: UInt64 = 0
    private var startedCaptureStreamCount: UInt64 = 0
    private var playbackByteCount: UInt64 = 0
    private var captureByteCount: UInt64 = 0
    private var nextPlaybackCompletionNanoseconds: UInt64 = 0
    private var nextCaptureCompletionNanoseconds: UInt64 = 0
    private var playbackGeneration: UInt64 = 0
    private var captureGeneration: UInt64 = 0

    func configure(
      streamID _: Int,
      direction: VirtioSoundDirection,
      parameters _: VirtioSoundPCMParameters
    ) -> Bool {
      lock.lock()
      if direction == .output {
        configuredPlaybackStreamCount &+= 1
        playbackGeneration &+= 1
        nextPlaybackCompletionNanoseconds = DispatchTime.now().uptimeNanoseconds
      } else {
        configuredCaptureStreamCount &+= 1
        captureGeneration &+= 1
        nextCaptureCompletionNanoseconds = DispatchTime.now().uptimeNanoseconds
      }
      lock.unlock()
      return true
    }

    func prepare(streamID _: Int, direction _: VirtioSoundDirection) -> Bool { true }

    func start(streamID _: Int, direction: VirtioSoundDirection) -> Bool {
      lock.lock()
      if direction == .output {
        startedPlaybackStreamCount &+= 1
      } else {
        startedCaptureStreamCount &+= 1
      }
      lock.unlock()
      return true
    }

    func stop(streamID _: Int, direction _: VirtioSoundDirection) -> Bool { true }

    func release(streamID _: Int, direction: VirtioSoundDirection) {
      cancelScheduledCompletions(direction: direction)
    }

    func enqueuePlayback(
      _ data: Data,
      parameters: VirtioSoundPCMParameters,
      completion: @escaping @Sendable (Bool, UInt32) -> Void
    ) -> Bool {
      lock.lock()
      playbackByteCount &+= UInt64(data.count)
      let playbackDeadline =
        max(
          DispatchTime.now().uptimeNanoseconds,
          nextPlaybackCompletionNanoseconds
        ) &+ Self.durationNanoseconds(byteCount: data.count, parameters: parameters)
      nextPlaybackCompletionNanoseconds = playbackDeadline
      let generation = playbackGeneration
      lock.unlock()
      completionQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: playbackDeadline)) {
        [weak self] in
        guard self?.isCurrentGeneration(generation, direction: .output) == true else { return }
        completion(true, 0)
      }
      return true
    }

    func requestCapture(
      byteCount: Int,
      parameters: VirtioSoundPCMParameters,
      completion: @escaping @Sendable (Data?, UInt32) -> Void
    ) -> Bool {
      lock.lock()
      captureByteCount &+= UInt64(byteCount)
      let captureDeadline =
        max(
          DispatchTime.now().uptimeNanoseconds,
          nextCaptureCompletionNanoseconds
        ) &+ Self.durationNanoseconds(byteCount: byteCount, parameters: parameters)
      nextCaptureCompletionNanoseconds = captureDeadline
      let generation = captureGeneration
      lock.unlock()
      completionQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: captureDeadline)) {
        [weak self] in
        guard self?.isCurrentGeneration(generation, direction: .input) == true else { return }
        completion(Data(repeating: 0x5a, count: byteCount), 0)
      }
      return true
    }

    func reset() {
      lock.lock()
      playbackGeneration &+= 1
      captureGeneration &+= 1
      nextPlaybackCompletionNanoseconds = 0
      nextCaptureCompletionNanoseconds = 0
      lock.unlock()
    }

    private func cancelScheduledCompletions(direction: VirtioSoundDirection) {
      lock.lock()
      if direction == .output {
        playbackGeneration &+= 1
        nextPlaybackCompletionNanoseconds = 0
      } else {
        captureGeneration &+= 1
        nextCaptureCompletionNanoseconds = 0
      }
      lock.unlock()
    }

    private func isCurrentGeneration(
      _ generation: UInt64,
      direction: VirtioSoundDirection
    ) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return direction == .output
        ? generation == playbackGeneration
        : generation == captureGeneration
    }

    private static func durationNanoseconds(
      byteCount: Int,
      parameters: VirtioSoundPCMParameters
    ) -> UInt64 {
      let frames = Double(byteCount) / Double(parameters.bytesPerFrame)
      return UInt64(
        max(
          1_000_000,
          min(250_000_000, Int((frames / parameters.sampleRate) * 1_000_000_000))
        ))
    }

    var snapshot: AudioQualificationHostSnapshot {
      lock.lock()
      defer { lock.unlock() }
      return AudioQualificationHostSnapshot(
        configuredPlaybackStreamCount: configuredPlaybackStreamCount,
        configuredCaptureStreamCount: configuredCaptureStreamCount,
        startedPlaybackStreamCount: startedPlaybackStreamCount,
        startedCaptureStreamCount: startedCaptureStreamCount,
        playbackByteCount: playbackByteCount,
        captureByteCount: captureByteCount
      )
    }
  }

  private struct AudioQualificationSnapshot {
    let host: AudioQualificationHostSnapshot
    let device: VirtioSoundStatistics
  }

  private final class AudioQualificationCapture: @unchecked Sendable {
    let host: AudioQualificationHost
    let sound: VirtioSound
    private let diagnosticLock = NSLock()
    private var emittedDiagnostic = false

    init() {
      let host = AudioQualificationHost()
      self.host = host
      sound = VirtioSound(host: host, enabledDirections: [.output, .input])
    }

    func satisfies(_ expectation: DoryARMVirtAudioExpectation) -> Bool {
      let snapshot = self.snapshot
      return snapshot.host.configuredPlaybackStreamCount >= 1
        && snapshot.host.configuredCaptureStreamCount >= 1
        && snapshot.host.startedPlaybackStreamCount >= 1
        && snapshot.host.startedCaptureStreamCount >= 1
        && snapshot.host.playbackByteCount >= expectation.minimumPlaybackByteCount
        && snapshot.host.captureByteCount >= expectation.minimumCaptureByteCount
        && snapshot.device.completedPlaybackPeriods
          >= expectation.minimumCompletedPlaybackPeriodCount
        && snapshot.device.completedCapturePeriods
          >= expectation.minimumCompletedCapturePeriodCount
        && Self.faultCount(snapshot.device) == 0
    }

    var snapshot: AudioQualificationSnapshot {
      AudioQualificationSnapshot(host: host.snapshot, device: sound.statistics)
    }

    func emitDiagnosticOnce() {
      diagnosticLock.lock()
      guard !emittedDiagnostic else {
        diagnosticLock.unlock()
        return
      }
      emittedDiagnostic = true
      diagnosticLock.unlock()
      let snapshot = self.snapshot
      let message = """
        dory-armvirt-uefi-smoke: audio qualification configured=\(snapshot.host.configuredPlaybackStreamCount)/\(snapshot.host.configuredCaptureStreamCount) started=\(snapshot.host.startedPlaybackStreamCount)/\(snapshot.host.startedCaptureStreamCount) bytes=\(snapshot.host.playbackByteCount)/\(snapshot.host.captureByteCount) periods=\(snapshot.device.completedPlaybackPeriods)/\(snapshot.device.completedCapturePeriods) faults=\(Self.faultCount(snapshot.device)) invalid=\(snapshot.device.invalidControlChains)/\(snapshot.device.invalidEventChains)/\(snapshot.device.invalidPlaybackChains)/\(snapshot.device.invalidCaptureChains) timeout=\(snapshot.device.timedOutPeriods) late=\(snapshot.device.lateHostCompletions) backpressure=\(snapshot.device.backpressuredPeriods) queue=\(snapshot.device.queueFaults) publication=\(snapshot.device.publicationFaults) bounded=\(snapshot.device.boundedDrainStops)\n
        """
      FileHandle.standardError.write(Data(message.utf8))
    }

    static func faultCount(_ statistics: VirtioSoundStatistics) -> UInt64 {
      statistics.invalidControlChains
        &+ statistics.invalidEventChains
        &+ statistics.invalidPlaybackChains
        &+ statistics.invalidCaptureChains
        &+ statistics.timedOutPeriods
        &+ statistics.lateHostCompletions
        &+ statistics.backpressuredPeriods
        &+ statistics.queueFaults
        &+ statistics.publicationFaults
        &+ statistics.boundedDrainStops
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
    let elapsedNanoseconds: UInt64
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
      case "--compatibility-matrix":
        guard let value = iterator.next() else {
          fail("--compatibility-matrix requires a path")
        }
        options.compatibilityMatrix = value
      case "--qualification-gate":
        guard let value = iterator.next(), !value.isEmpty else {
          fail("--qualification-gate requires an identifier")
        }
        options.qualificationGate = value
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

  private func admitConsoleScript(
    at suppliedPath: String,
    matrixOwned: Bool = false
  ) throws -> AdmittedConsoleScript {
    let path = URL(fileURLWithPath: suppliedPath).resolvingSymlinksInPath().path
    var fileStatus = stat()
    guard lstat(path, &fileStatus) == 0,
      fileStatus.st_mode & S_IFMT == S_IFREG,
      fileStatus.st_uid == geteuid(),
      fileStatus.st_mode & (matrixOwned ? 0o022 : 0o077) == 0,
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

  private func admitQualificationGate(options: inout Options) throws
    -> AdmittedQualificationGate?
  {
    guard options.compatibilityMatrix != nil || options.qualificationGate != nil else {
      return nil
    }
    guard let suppliedPath = options.compatibilityMatrix,
      let gateID = options.qualificationGate,
      options.consoleScript == nil
    else {
      fail(
        "--compatibility-matrix and --qualification-gate are required together and own --console-script"
      )
    }
    let path = URL(fileURLWithPath: suppliedPath).standardizedFileURL.path
    var status = stat()
    guard suppliedPath == path, lstat(path, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(),
      status.st_mode & 0o022 == 0, status.st_size > 0, status.st_size <= 1 << 20
    else {
      fail("--compatibility-matrix must name an owned, non-writable regular file")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    let matrix = try JSONDecoder().decode(DoryARMVirtCompatibilityMatrix.self, from: data)
      .validated()
    let gate = try matrix.gate(id: gateID)
    guard let media = matrix.media[gate.mediaID] else {
      fail("qualification gate references unavailable media")
    }
    let matrixRoot = URL(fileURLWithPath: path).deletingLastPathComponent()
    let fixtureURL = matrixRoot.appendingPathComponent(gate.consoleScriptPath).standardizedFileURL
    guard fixtureURL.path.hasPrefix(matrixRoot.path + "/") else {
      fail("qualification gate fixture escapes the matrix directory")
    }
    options.consoleScript = fixtureURL.path
    options.memoryBytes = gate.memoryByteCount
    options.systemDiskBytes = gate.systemDiskByteCount
    options.timeoutSeconds = gate.timeoutSeconds
    options.expectedConsoleText = gate.expectedConsoleText
    return AdmittedQualificationGate(
      matrixData: data,
      matrixSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      gate: gate,
      media: media
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

  private func systemString(_ name: String) -> String {
    var byteCount = 0
    guard sysctlbyname(name, nil, &byteCount, nil, 0) == 0, byteCount > 1 else {
      return "unknown"
    }
    var bytes = [CChar](repeating: 0, count: byteCount)
    guard sysctlbyname(name, &bytes, &byteCount, nil, 0) == 0 else { return "unknown" }
    return String(
      decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
  }

  private func hostPowerSource() -> String {
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
          as? [String: Any],
        let state = description[kIOPSPowerSourceStateKey] as? String
      else { continue }
      if state == kIOPSACPowerValue { return "ac-power" }
      if state == kIOPSBatteryPowerValue { return "battery-power" }
    }
    return "unknown"
  }

  private func thermalState(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "critical"
    }
  }

  private func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func runnerSHA256() throws -> String {
    let path = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func runBoot(
    artifacts: DoryVerifiedFirmwareArtifacts,
    variableStore: DoryUEFIVariableStoreFile,
    systemDiskPath: String,
    systemDevice: DoryARMVirtUEFIBootDevice,
    installerMedia: InstallerMedia?,
    capture: ConsoleCapture,
    consoleScript: AdmittedConsoleScript?,
    displayExpectation: DoryARMVirtDisplayExpectation?,
    displayCapture: DisplayQualificationCapture?,
    inputExpectation: DoryARMVirtInputExpectation?,
    inputCapture: InputQualificationCapture?,
    audioExpectation: DoryARMVirtAudioExpectation?,
    audioCapture: AudioQualificationCapture?,
    gvproxy: AdmittedGVProxy?,
    memoryBytes: UInt64,
    appliedInstallerMediaTransitionCount: Int,
    timeoutSeconds: UInt64,
    attempt: Int
  ) throws -> BootResult {
    let bootStarted = DispatchTime.now().uptimeNanoseconds
    func result(reason: GuestStopReason, matchedConsole: Bool) -> BootResult {
      BootResult(
        reason: reason,
        matchedConsole: matchedConsole,
        elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds &- bootStarted
      )
    }

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
    guard let entropySlot = DoryARMVirtV1ABI.virtioSlots.first(where: { $0.role == .entropy })
    else {
      throw VMError.invalidConfiguration("\(DoryARMVirtV1ABI.identity) has no entropy slot")
    }
    try attachVirtioDevice(
      VirtioRng(),
      slot: entropySlot.index,
      to: machine
    )
    if let displayExpectation, let displayCapture {
      guard
        let graphicsSlot = DoryARMVirtV1ABI.virtioSlots.first(where: {
          $0.role == .graphics
        })
      else {
        throw VMError.invalidConfiguration("\(DoryARMVirtV1ABI.identity) has no graphics slot")
      }
      let scanoutSize = VirtioGPUScanoutSize(
        width: displayExpectation.widthPixels,
        height: displayExpectation.heightPixels
      )
      try attachVirtioDevice(
        VirtioGPU(
          hostMemoryBase: GuestLayout.daxWindowBase,
          scanoutSizes: Array(repeating: scanoutSize, count: displayExpectation.scanoutCount),
          onScanoutFrame: displayCapture.append
        ),
        slot: graphicsSlot.index,
        to: machine
      )
    }
    if inputExpectation != nil, let inputCapture {
      guard
        let keyboardSlot = DoryARMVirtV1ABI.virtioSlots.first(where: {
          $0.role == .keyboard
        }),
        let pointerSlot = DoryARMVirtV1ABI.virtioSlots.first(where: {
          $0.role == .pointer
        })
      else {
        throw VMError.invalidConfiguration("\(DoryARMVirtV1ABI.identity) has no input slots")
      }
      try attachVirtioDevice(inputCapture.keyboard, slot: keyboardSlot.index, to: machine)
      try attachVirtioDevice(inputCapture.pointer, slot: pointerSlot.index, to: machine)
    }
    if audioExpectation != nil, let audioCapture {
      guard
        let audioSlot = DoryARMVirtV1ABI.virtioSlots.first(where: {
          $0.role == .audio
        })
      else {
        throw VMError.invalidConfiguration("\(DoryARMVirtV1ABI.identity) has no audio slot")
      }
      try attachVirtioDevice(audioCapture.sound, slot: audioSlot.index, to: machine)
    }
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
      for path in networkPaths {
        unlink(path)
      }
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
      for path in networkPaths {
        unlink(path)
      }
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
      let consoleMilestoneReached =
        (consoleScript?.driver.installerMediaTransitionCount ?? 0)
        == appliedInstallerMediaTransitionCount
        && capture.matched(afterByteOffset: consoleStartOffset)
        && consoleScript?.driver.isComplete != false
        && consoleScript?.driver.pendingHostAction == nil
      if consoleMilestoneReached {
        inputCapture?.submitOnce()
        audioCapture?.emitDiagnosticOnce()
      }
      let matchedConsole =
        consoleMilestoneReached
        && displayExpectation.map { displayCapture?.satisfies($0) == true } != false
        && inputExpectation.map { inputCapture?.satisfies($0) == true } != false
        && audioExpectation.map { audioCapture?.satisfies($0) == true } != false
      if matchedConsole {
        return result(
          reason: try runner.stopAndWait(GuestStopReason.powerOff),
          matchedConsole: true
        )
      }
      if completion.wait(milliseconds: 25) {
        return result(
          reason: try completion.value().get(),
          matchedConsole: (consoleScript?.driver.installerMediaTransitionCount ?? 0)
            == appliedInstallerMediaTransitionCount
            && capture.matched(afterByteOffset: consoleStartOffset)
            && consoleScript?.driver.isComplete != false
            && consoleScript?.driver.pendingHostAction == nil
            && displayExpectation.map { displayCapture?.satisfies($0) == true } != false
            && inputExpectation.map { inputCapture?.satisfies($0) == true } != false
            && audioExpectation.map { audioCapture?.satisfies($0) == true } != false
        )
      }
    }
    return result(
      reason: try runner.stopAndWait(GuestStopReason.powerOff),
      matchedConsole: (consoleScript?.driver.installerMediaTransitionCount ?? 0)
        == appliedInstallerMediaTransitionCount
        && capture.matched(afterByteOffset: consoleStartOffset)
        && consoleScript?.driver.isComplete != false
        && consoleScript?.driver.pendingHostAction == nil
        && displayExpectation.map { displayCapture?.satisfies($0) == true } != false
        && inputExpectation.map { inputCapture?.satisfies($0) == true } != false
        && audioExpectation.map { audioCapture?.satisfies($0) == true } != false
    )
  }

  private func describe(_ reason: GuestStopReason) -> String {
    switch reason {
    case .powerOff: return "power-off"
    case .reset: return "reset"
    case .crash(let message): return "crash: \(message)"
    }
  }

  private var options = parseOptions(CommandLine.arguments.dropFirst())
  guard let firmwareBundle = options.firmwareBundle else {
    fail("--firmware-bundle is required")
  }

  do {
    let qualification = try admitQualificationGate(options: &options)
    let qualificationStartedAt = timestamp(Date())
    let qualificationStarted = DispatchTime.now().uptimeNanoseconds
    let processInfo = ProcessInfo.processInfo
    let hostPowerSourceAtStart = hostPowerSource()
    let hostLowPowerModeEnabledAtStart = processInfo.isLowPowerModeEnabled
    let hostThermalStateAtStart = thermalState(processInfo.thermalState)
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

    var variableStore = try DoryUEFIVariableStoreFile(
      directory: temporaryRoot.appendingPathComponent("variables", isDirectory: true).path
    )
    try variableStore.initialize(template)
    var systemDiskPath = temporaryRoot.appendingPathComponent("system.raw").path
    try createSystemDisk(at: systemDiskPath, byteCount: options.systemDiskBytes)
    let systemDevice = try DoryARMVirtUEFIBootDevice(
      logicalID: "system",
      kind: .systemDisk,
      virtioSlot: 0,
      readOnly: false
    )
    let installerMedia = try options.installerMedia.map(admitInstallerMedia)
    let consoleScript = try options.consoleScript.map {
      try admitConsoleScript(at: $0, matrixOwned: qualification != nil)
    }
    let gvproxy = try options.gvproxy.map(admitGVProxy)
    if let qualification {
      guard let installerMedia,
        installerMedia.byteCount == qualification.media.byteCount,
        installerMedia.sha256 == qualification.media.sha256,
        consoleScript?.sha256 == qualification.gate.consoleScriptSHA256,
        consoleScript?.driver.stepCount
          == qualification.gate.receipt.consoleScriptStepCount,
        consoleScript?.driver.qualificationTarget?.guestFamily
          == qualification.media.guestFamily,
        consoleScript?.driver.qualificationTarget?.guestVersion
          == qualification.media.guestVersion,
        consoleScript?.driver.qualificationTarget?.guestBuild
          == qualification.media.guestBuild,
        consoleScript?.driver.qualificationTarget?.guestArchitecture
          == qualification.media.guestArchitecture,
        gvproxy?.sha256 == qualification.gate.gvproxySHA256
      else {
        fail("qualification gate media, fixture, sidecar, or guest tuple does not match the matrix")
      }
    }
    if consoleScript?.driver.inputContains(options.expectedConsoleText) == true {
      fail("--expect must not occur in console-script input because guest echo could forge success")
    }
    if consoleScript?.driver.containsInstallerMediaTransition == true, installerMedia == nil {
      fail("a console script that transitions installer media requires --installer-media")
    }
    let capture = ConsoleCapture(expected: options.expectedConsoleText)
    let displayCapture = qualification?.gate.display.map { _ in
      DisplayQualificationCapture()
    }
    let inputCapture = qualification?.gate.input.map { _ in InputQualificationCapture() }
    let audioCapture = qualification?.gate.audio.map { _ in AudioQualificationCapture() }
    let maximumBootAttempts = 4
    var finalResult: BootResult?
    var bootAttempts = 0
    var bootDurationNanoseconds: [UInt64] = []
    var installerMediaAttachedForFinalBoot = installerMedia != nil
    var coldSnapshotManifest: DoryARMVirtColdSnapshotManifest?
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
        displayExpectation: qualification?.gate.display,
        displayCapture: displayCapture,
        inputExpectation: qualification?.gate.input,
        inputCapture: inputCapture,
        audioExpectation: qualification?.gate.audio,
        audioCapture: audioCapture,
        gvproxy: gvproxy,
        memoryBytes: options.memoryBytes,
        appliedInstallerMediaTransitionCount: appliedInstallerMediaTransitionCount,
        timeoutSeconds: options.timeoutSeconds,
        attempt: bootAttempts
      )
      bootDurationNanoseconds.append(result.elapsedNanoseconds)
      if result.matchedConsole {
        finalResult = result
        break
      }
      if let hostAction = consoleScript?.driver.pendingHostAction {
        guard case .powerOff = result.reason else {
          fail("console host action \(hostAction.rawValue) requires a guest power-off boundary")
        }
        switch hostAction {
        case .captureColdSnapshot:
          coldSnapshotManifest = try DoryARMVirtColdSnapshotStore.capture(
            firmware: artifacts.manifest,
            systemDiskPath: systemDiskPath,
            variableStore: variableStore,
            destinationDirectory: temporaryRoot.appendingPathComponent(
              "cold-snapshot",
              isDirectory: true
            ).path
          )
        case .restoreColdSnapshot:
          guard coldSnapshotManifest != nil else {
            fail("cold snapshot restore requires an earlier captured snapshot")
          }
          let restore = try DoryARMVirtColdSnapshotStore.restore(
            bundleDirectory: temporaryRoot.appendingPathComponent(
              "cold-snapshot",
              isDirectory: true
            ).path,
            expectedFirmware: artifacts.manifest,
            destinationDirectory: temporaryRoot.appendingPathComponent(
              "cold-restore",
              isDirectory: true
            ).path
          )
          systemDiskPath = restore.systemDiskPath
          variableStore = restore.variableStore
        }
        try consoleScript?.driver.completeHostAction(hostAction)
        continue
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
    if let expectation = qualification?.gate.receipt {
      guard bootAttempts == expectation.bootAttempts,
        consoleScript?.driver.completedStepCount == expectation.consoleScriptStepCount,
        consoleScript?.driver.installerMediaTransitionCount
          == expectation.installerMediaTransitionCount,
        installerMediaAttachedForFinalBoot == expectation.installerMediaAttachedForFinalBoot,
        consoleScript?.driver.completedHostActionCount == expectation.coldSnapshotActionCount
      else {
        fail("observed lifecycle receipt does not match the qualification gate")
      }
    }
    let generation = try variableStore.load().snapshot.generation
    let qualificationDurationNanoseconds =
      DispatchTime.now().uptimeNanoseconds &- qualificationStarted
    let qualificationCompletedAt = timestamp(Date())
    let hostPowerSourceAtEnd = hostPowerSource()
    let hostLowPowerModeEnabledAtEnd = processInfo.isLowPowerModeEnabled
    let hostThermalStateAtEnd = thermalState(processInfo.thermalState)
    let displaySnapshot = displayCapture?.snapshot
    let inputSnapshot = inputCapture?.snapshot
    let audioSnapshot = audioCapture?.snapshot
    let receipt = DoryARMVirtQualificationReceipt(
      machineABIIdentity: DoryARMVirtV1ABI.identity,
      firmwareABIIdentity: DoryARMVirtV1ABI.firmwareABIIdentity,
      executionEngineIdentity: DoryExecutionEngineIdentity.nativeARM64.rawValue,
      cpuProfileIdentity: DoryCPUProfileIdentity.genericARM64V1.rawValue,
      deviceABIIdentity: DoryDeviceABIIdentity.virtioV1.rawValue,
      hostArchitecture: DoryHostArchitecture.arm64.rawValue,
      hostHardwareModel: systemString("hw.model"),
      hostOperatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      hostOperatingSystemBuild: systemString("kern.osversion"),
      hostBootSessionUUID: systemString("kern.bootsessionuuid"),
      hostPhysicalMemoryByteCount: processInfo.physicalMemory,
      hostPowerSourceAtStart: hostPowerSourceAtStart,
      hostPowerSourceAtEnd: hostPowerSourceAtEnd,
      hostLowPowerModeEnabledAtStart: hostLowPowerModeEnabledAtStart,
      hostLowPowerModeEnabledAtEnd: hostLowPowerModeEnabledAtEnd,
      hostThermalStateAtStart: hostThermalStateAtStart,
      hostThermalStateAtEnd: hostThermalStateAtEnd,
      qualificationStartedAt: qualificationStartedAt,
      qualificationCompletedAt: qualificationCompletedAt,
      guestFamily: consoleScript?.driver.qualificationTarget?.guestFamily,
      guestVersion: consoleScript?.driver.qualificationTarget?.guestVersion,
      guestBuild: consoleScript?.driver.qualificationTarget?.guestBuild,
      guestArchitecture: consoleScript?.driver.qualificationTarget?.guestArchitecture,
      guestVCPUCount: 1,
      runnerSHA256: try runnerSHA256(),
      compatibilityMatrixSHA256: qualification?.matrixSHA256,
      qualificationGateID: qualification?.gate.gateID,
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
      coldSnapshotActionCount: consoleScript?.driver.hostActionCount ?? 0,
      completedColdSnapshotActionCount: consoleScript?.driver.completedHostActionCount ?? 0,
      coldSnapshotABIIdentity: coldSnapshotManifest?.snapshotABIIdentity,
      coldSnapshotSystemDiskSHA256: coldSnapshotManifest?.systemDiskSHA256,
      coldSnapshotVariableStoreGeneration: coldSnapshotManifest?.variableStoreGeneration,
      gvproxySHA256: gvproxy?.sha256,
      displayScanoutCount: displaySnapshot?.scanoutCount,
      displayContentFrameCount: displaySnapshot?.contentFrameCount,
      displayContentFrameWidthPixels: displaySnapshot?.contentFrameWidthPixels,
      displayContentFrameHeightPixels: displaySnapshot?.contentFrameHeightPixels,
      displayContentFrameByteCount: displaySnapshot?.contentFrameByteCount,
      displayContentFrameNonZeroByteCount: displaySnapshot?.contentFrameNonZeroByteCount,
      displayContentFrameSHA256: displaySnapshot?.contentFrameSHA256,
      keyboardInputSubmittedFrameCount: inputSnapshot?.keyboard.submittedFrames,
      keyboardInputPublishedFrameCount: inputSnapshot?.keyboard.publishedFrames,
      keyboardInputPublishedEventCount: inputSnapshot?.keyboard.publishedEvents,
      keyboardInputDroppedFrameCount: inputSnapshot?.keyboard.droppedFrames,
      keyboardInputRejectedFrameCount: inputSnapshot?.keyboard.rejectedFrames,
      pointerInputSubmittedFrameCount: inputSnapshot?.pointer.submittedFrames,
      pointerInputPublishedFrameCount: inputSnapshot?.pointer.publishedFrames,
      pointerInputPublishedEventCount: inputSnapshot?.pointer.publishedEvents,
      pointerInputDroppedFrameCount: inputSnapshot?.pointer.droppedFrames,
      pointerInputRejectedFrameCount: inputSnapshot?.pointer.rejectedFrames,
      audioConfiguredPlaybackStreamCount: audioSnapshot?.host.configuredPlaybackStreamCount,
      audioConfiguredCaptureStreamCount: audioSnapshot?.host.configuredCaptureStreamCount,
      audioStartedPlaybackStreamCount: audioSnapshot?.host.startedPlaybackStreamCount,
      audioStartedCaptureStreamCount: audioSnapshot?.host.startedCaptureStreamCount,
      audioPlaybackByteCount: audioSnapshot?.host.playbackByteCount,
      audioCaptureByteCount: audioSnapshot?.host.captureByteCount,
      audioCompletedPlaybackPeriodCount: audioSnapshot?.device.completedPlaybackPeriods,
      audioCompletedCapturePeriodCount: audioSnapshot?.device.completedCapturePeriods,
      audioDeviceFaultCount: audioSnapshot.map { AudioQualificationCapture.faultCount($0.device) },
      consoleByteCount: capture.byteCount,
      bootAttempts: bootAttempts,
      timingClockIdentity: "dispatch-uptime-nanoseconds",
      bootDurationNanoseconds: bootDurationNanoseconds,
      qualificationDurationNanoseconds: qualificationDurationNanoseconds,
      variableStoreGeneration: generation,
      stopReason: describe(finalResult.reason)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let receiptData = try encoder.encode(receipt)
    if let qualification {
      _ = try DoryARMVirtQualificationReceiptVerifier.verify(
        receiptData: receiptData,
        matrixData: qualification.matrixData,
        gateID: qualification.gate.gateID
      )
    }
    FileHandle.standardOutput.write(receiptData)
    FileHandle.standardOutput.write(Data("\n".utf8))
  } catch {
    fail(String(describing: error))
  }
#endif
