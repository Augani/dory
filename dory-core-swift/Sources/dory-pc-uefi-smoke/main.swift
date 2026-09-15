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
  case executionDeadlineExceeded
  case keyboardQueueFull

  var description: String {
    switch self {
    case .usage(let message): message
    case .invalidNumber(let value): "invalid unsigned integer: \(value)"
    case .executionDeadlineExceeded:
      "host execution deadline expired; incomplete boot remains censored"
    case .missingSerialMarker(let marker): "expected serial marker was not observed: \(marker)"
    case .keyboardQueueFull:
      "the virtual keyboard could not retain the requested scripted input"
    }
  }
}

/// Uses the machine's thread-safe power request so an active quantum or HLT wait
/// returns through normal teardown and can retain a censored result on timeout.
private final class SmokeDeadline: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false
  private var expired = false
  private var timer: DispatchSourceTimer?

  init(machine: DoryPCDirectKernelMachine, seconds: UInt64) {
    // asyncAfter permits timer coalescing; a 600-second diagnostic returned at
    // 630 seconds. Use a strict, zero-leeway timer to remove that allowance;
    // host scheduling can still delay delivery, so this is not a realtime claim.
    let timer = DispatchSource.makeTimerSource(
      flags: .strict, queue: DispatchQueue.global(qos: .userInitiated))
    timer.setEventHandler { [weak self, machine] in
      guard let self else { return }
      self.lock.withLock {
        guard !self.finished else { return }
        self.expired = true
        machine.powerController.request(.powerOff)
      }
    }
    self.timer = timer
    timer.schedule(deadline: .now() + Double(seconds), leeway: .nanoseconds(0))
    timer.resume()
  }

  @discardableResult func finish() -> Bool {
    let result = lock.withLock {
      finished = true
      return expired
    }
    timer?.cancel()
    timer = nil
    return result
  }
}

private struct FileIdentity {
  let byteCount: UInt64
  let sha256: String
}

private final class SmokeDisplaySink: DoryVirtioGPUDisplaySink, @unchecked Sendable {
  struct Snapshot: Sendable {
    let frameCount: UInt64
    let nonblankFrameCount: UInt64
    let lastFrame: DoryVirtioGPUFrame?
    let lastNonblankFrame: DoryVirtioGPUFrame?
  }

  private let lock = NSLock()
  private var frameCount: UInt64 = 0
  private var nonblankFrameCount: UInt64 = 0
  private var lastFrame: DoryVirtioGPUFrame?
  private var lastNonblankFrame: DoryVirtioGPUFrame?

  func present(_ frame: DoryVirtioGPUFrame) {
    lock.withLock {
      frameCount &+= 1
      lastFrame = frame
      if frame.pixels.contains(where: { $0 != 0 }) {
        nonblankFrameCount &+= 1
        lastNonblankFrame = frame
      }
    }
  }

  func snapshot() -> Snapshot {
    lock.withLock {
      Snapshot(
        frameCount: frameCount,
        nonblankFrameCount: nonblankFrameCount,
        lastFrame: lastFrame,
        lastNonblankFrame: lastNonblankFrame
      )
    }
  }
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
  enum KeyboardRoute: String {
    case all
    case virtio
    case usbHID = "usb-hid"
    case serial
  }

  let firmwareBundle: URL
  let maximumInstructions: UInt64
  let timeoutSeconds: UInt64
  let progressInstructions: UInt64
  let memoryBytes: Int
  let processorCount: Int
  let systemDisk: URL?
  let installerMedia: URL?
  let variableStoreDirectory: URL?
  let displayCaptureOutput: URL?
  let keyboardScript: [String]
  let keyboardEvents: [DoryVirtioInputEvent]
  let usbKeyboardReports: [[UInt8]]
  let serialInputBytes: [UInt8]
  let secondKeyboardScript: [String]
  let secondKeyboardEvents: [DoryVirtioInputEvent]
  let secondUSBKeyboardReports: [[UInt8]]
  let secondSerialInputBytes: [UInt8]
  let keyboardRoute: KeyboardRoute
  let keyboardAfterInstructions: UInt64?
  let secondKeyboardAfterInstructions: UInt64?
  let exceptionPolicy: DoryPCExceptionPolicy
  let executionTier: DoryPCExecutionTier
  let baselineJITTier1Enabled: Bool
  let expectedSerialMarker: String?
  let bootProbe: Bool
  let bootTimelineEnabled: Bool
  let instrumentationEnabled: Bool
  let clockSource: DoryPCClockSource
  let clockSourceDescription: String
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
          "--firmware-bundle", "--max-instructions", "--timeout-seconds", "--memory-bytes",
          "--processor-count",
          "--system-disk", "--installer-media", "--variable-store-directory", "--display-capture-output",
          "--keyboard-script", "--keyboard-route", "--keyboard-after-instructions",
          "--keyboard-second-script", "--keyboard-second-after-instructions",
          "--exception-policy", "--execution-tier", "--progress-instructions",
          "--baseline-tier1",
          "--expected-serial-marker",
          "--boot-probe", "--clock-source", "--boot-timeline",
          "--instrumentation",
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
          + "[--display-capture-output /absolute/new-frame.ppm] "
          + "[--keyboard-script named-key,...] "
          + "[--keyboard-route all|virtio|usb-hid|serial] "
          + "[--keyboard-after-instructions count] "
          + "[--keyboard-second-script named-key,...] "
          + "[--keyboard-second-after-instructions count] "
          + "[--processor-count count] [--exception-policy stop|deliver] "
          + "[--execution-tier interpreter|baseline-jit|optimizing-jit] "
          + "[--baseline-tier1 enabled|disabled] "
          + "[--expected-serial-marker text] "
          + "[--boot-probe enabled|disabled] [--clock-source host-monotonic|deterministic] "
          + "[--initial-rtc-unix-seconds seconds] [--boot-timeline enabled|disabled] "
          + "[--instrumentation enabled|disabled] "
          + "[--trace-after-instructions count] [--trace-capacity count] "
          + "[--trace-break-rip-below address] "
          + "[--timeout-seconds 1...7200] [--max-instructions count] [--progress-instructions count] [--memory-bytes count]"
      )
    }
    switch options["--boot-timeline"] ?? "enabled" {
    case "enabled": bootTimelineEnabled = true
    case "disabled": bootTimelineEnabled = false
    default: throw SmokeError.usage("--boot-timeline must be enabled or disabled")
    }
    switch options["--instrumentation"] ?? "enabled" {
    case "enabled": instrumentationEnabled = true
    case "disabled": instrumentationEnabled = false
    default: throw SmokeError.usage("--instrumentation must be enabled or disabled")
    }
    let timeoutText = options["--timeout-seconds"] ?? "900"
    guard let timeoutSeconds = UInt64(timeoutText), (1...7200).contains(timeoutSeconds) else {
      throw SmokeError.invalidNumber(timeoutText)
    }
    self.timeoutSeconds = timeoutSeconds
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
    switch options["--baseline-tier1"] ?? "enabled" {
    case "enabled": baselineJITTier1Enabled = true
    case "disabled": baselineJITTier1Enabled = false
    default: throw SmokeError.usage("--baseline-tier1 must be enabled or disabled")
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
    let clockSourceText = options["--clock-source"] ?? "host-monotonic"
    switch clockSourceText {
    case "host-monotonic":
      clockSource = .hostMonotonic
      clockSourceDescription = clockSourceText
    case "deterministic":
      clockSource = .deterministic
      clockSourceDescription = clockSourceText
    default:
      throw SmokeError.usage("invalid clock source: \(clockSourceText)")
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
    displayCaptureOutput = try options["--display-capture-output"].map { try Self.absoluteURL($0) }
    keyboardScript = try Self.keyboardScript(options["--keyboard-script"])
    keyboardEvents = Self.keyboardEvents(for: keyboardScript)
    usbKeyboardReports = Self.usbKeyboardReports(for: keyboardScript)
    serialInputBytes = Self.serialInputBytes(for: keyboardScript)
    secondKeyboardScript = try Self.keyboardScript(options["--keyboard-second-script"])
    secondKeyboardEvents = Self.keyboardEvents(for: secondKeyboardScript)
    secondUSBKeyboardReports = Self.usbKeyboardReports(for: secondKeyboardScript)
    secondSerialInputBytes = Self.serialInputBytes(for: secondKeyboardScript)
    guard let keyboardRoute = KeyboardRoute(rawValue: options["--keyboard-route"] ?? "all") else {
      throw SmokeError.usage("--keyboard-route must be all, virtio, usb-hid, or serial")
    }
    self.keyboardRoute = keyboardRoute
    if let text = options["--keyboard-after-instructions"] {
      guard let value = UInt64(text) else { throw SmokeError.invalidNumber(text) }
      guard !keyboardScript.isEmpty else {
        throw SmokeError.usage("--keyboard-after-instructions requires --keyboard-script")
      }
      keyboardAfterInstructions = value
    } else {
      keyboardAfterInstructions = keyboardScript.isEmpty ? nil : 0
    }
    if let text = options["--keyboard-second-after-instructions"] {
      guard let value = UInt64(text) else { throw SmokeError.invalidNumber(text) }
      guard !secondKeyboardScript.isEmpty else {
        throw SmokeError.usage("--keyboard-second-after-instructions requires --keyboard-second-script")
      }
      guard let firstAfter = keyboardAfterInstructions, value > firstAfter else {
        throw SmokeError.usage("--keyboard-second-after-instructions must follow the first keyboard injection")
      }
      secondKeyboardAfterInstructions = value
    } else {
      guard secondKeyboardScript.isEmpty else {
        throw SmokeError.usage("--keyboard-second-script requires --keyboard-second-after-instructions")
      }
      secondKeyboardAfterInstructions = nil
    }
  }

  private static func absoluteURL(_ path: String, isDirectory: Bool = false) throws -> URL {
    guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0) else {
      throw SmokeError.usage("path must be absolute and narrowly scoped: \(path)")
    }
    return URL(fileURLWithPath: path, isDirectory: isDirectory).standardizedFileURL
  }

  private struct KeyboardStroke {
    let linuxCode: UInt16
    let usbUsage: UInt8
    let serialBytes: [UInt8]
    let modifierLinuxCode: UInt16?
    let usbModifier: UInt8

    init(
      linuxCode: UInt16,
      usbUsage: UInt8,
      serialBytes: [UInt8],
      requiresShift: Bool
    ) {
      self.linuxCode = linuxCode
      self.usbUsage = usbUsage
      self.serialBytes = serialBytes
      modifierLinuxCode = requiresShift ? 42 : nil
      usbModifier = requiresShift ? 0x02 : 0
    }

    init(
      linuxCode: UInt16,
      usbUsage: UInt8,
      serialBytes: [UInt8],
      modifierLinuxCode: UInt16?,
      usbModifier: UInt8
    ) {
      self.linuxCode = linuxCode
      self.usbUsage = usbUsage
      self.serialBytes = serialBytes
      self.modifierLinuxCode = modifierLinuxCode
      self.usbModifier = usbModifier
    }
  }

  /// The smoke runner accepts a bounded sequence of physical keys, not an installer language.
  /// Every accepted key has an explicit Linux EV_KEY code, USB-HID usage, and serial equivalent.
  /// This lets qualification edit a boot command line or exercise non-navigation input without
  /// giving the runner filesystem, process, or guest-management authority.
  private static func keyboardScript(_ value: String?) throws -> [String] {
    guard let value else { return [] }
    let tokens = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard
      !tokens.isEmpty,
      tokens.count <= 512,
      tokens.allSatisfy({ keyStrokes[$0] != nil })
    else {
      throw SmokeError.usage(
        "--keyboard-script must be a comma-separated list of: "
          + keyStrokes.keys.sorted().joined(separator: ",")
      )
    }
    return tokens
  }

  private static let keyStrokes: [String: KeyboardStroke] = {
    var strokes: [String: KeyboardStroke] = [
      "enter": .init(linuxCode: 28, usbUsage: 0x28, serialBytes: [13], requiresShift: false),
      "esc": .init(linuxCode: 1, usbUsage: 0x29, serialBytes: [27], requiresShift: false),
      "up": .init(linuxCode: 103, usbUsage: 0x52, serialBytes: [27, 91, 65], requiresShift: false),
      "down": .init(linuxCode: 108, usbUsage: 0x51, serialBytes: [27, 91, 66], requiresShift: false),
      "left": .init(linuxCode: 105, usbUsage: 0x50, serialBytes: [27, 91, 68], requiresShift: false),
      "right": .init(linuxCode: 106, usbUsage: 0x4F, serialBytes: [27, 91, 67], requiresShift: false),
      "home": .init(linuxCode: 102, usbUsage: 0x4A, serialBytes: [27, 91, 72], requiresShift: false),
      "end": .init(linuxCode: 107, usbUsage: 0x4D, serialBytes: [27, 91, 70], requiresShift: false),
      "backspace": .init(linuxCode: 14, usbUsage: 0x2A, serialBytes: [127], requiresShift: false),
      // GRUB accepts the xterm F10 sequence as an alternative to Ctrl-X when booting an edited
      // entry. Keep the serial form explicit rather than treating host key labels as terminal
      // bytes.
      "f10": .init(linuxCode: 68, usbUsage: 0x43, serialBytes: [27, 91, 50, 49, 126], requiresShift: false),
      "tab": .init(linuxCode: 15, usbUsage: 0x2B, serialBytes: [9], requiresShift: false),
      "space": .init(linuxCode: 57, usbUsage: 0x2C, serialBytes: [32], requiresShift: false),
      "minus": .init(linuxCode: 12, usbUsage: 0x2D, serialBytes: [45], requiresShift: false),
      "equals": .init(linuxCode: 13, usbUsage: 0x2E, serialBytes: [61], requiresShift: false),
      "left-bracket": .init(linuxCode: 26, usbUsage: 0x2F, serialBytes: [91], requiresShift: false),
      "right-bracket": .init(linuxCode: 27, usbUsage: 0x30, serialBytes: [93], requiresShift: false),
      "backslash": .init(linuxCode: 43, usbUsage: 0x31, serialBytes: [92], requiresShift: false),
      "semicolon": .init(linuxCode: 39, usbUsage: 0x33, serialBytes: [59], requiresShift: false),
      "apostrophe": .init(linuxCode: 40, usbUsage: 0x34, serialBytes: [39], requiresShift: false),
      "grave": .init(linuxCode: 41, usbUsage: 0x35, serialBytes: [96], requiresShift: false),
      "comma": .init(linuxCode: 51, usbUsage: 0x36, serialBytes: [44], requiresShift: false),
      "period": .init(linuxCode: 52, usbUsage: 0x37, serialBytes: [46], requiresShift: false),
      "slash": .init(linuxCode: 53, usbUsage: 0x38, serialBytes: [47], requiresShift: false),
    ]
    let letters: [(UInt8, UInt16)] = [
      (97, 30), (98, 48), (99, 46), (100, 32), (101, 18), (102, 33), (103, 34),
      (104, 35), (105, 23), (106, 36), (107, 37), (108, 38), (109, 50), (110, 49),
      (111, 24), (112, 25), (113, 16), (114, 19), (115, 31), (116, 20), (117, 22),
      (118, 47), (119, 17), (120, 45), (121, 21), (122, 44),
    ]
    for (offset, entry) in letters.enumerated() {
      let (letter, linuxCode) = entry
      let lower = String(UnicodeScalar(letter))
      let usage = UInt8(0x04 + offset)
      strokes[lower] = .init(
        linuxCode: linuxCode, usbUsage: usage, serialBytes: [letter], requiresShift: false)
      strokes["shift-\(lower)"] = .init(
        linuxCode: linuxCode, usbUsage: usage, serialBytes: [letter - 32], requiresShift: true)
    }
    let digits: [(String, UInt16, UInt8)] = [
      ("1", 2, 0x1E), ("2", 3, 0x1F), ("3", 4, 0x20), ("4", 5, 0x21), ("5", 6, 0x22),
      ("6", 7, 0x23), ("7", 8, 0x24), ("8", 9, 0x25), ("9", 10, 0x26), ("0", 11, 0x27),
    ]
    for (name, linuxCode, usage) in digits {
      strokes[name] = .init(
        linuxCode: linuxCode, usbUsage: usage, serialBytes: Array(name.utf8), requiresShift: false)
    }
    guard let x = strokes["x"] else { preconditionFailure("x key must be present") }
    strokes["ctrl-x"] = .init(
      linuxCode: x.linuxCode, usbUsage: x.usbUsage, serialBytes: [24],
      modifierLinuxCode: 29, usbModifier: 0x01)
    return strokes
  }()

  private static func keyboardEvents(for script: [String]) -> [DoryVirtioInputEvent] {
    script.flatMap { key -> [DoryVirtioInputEvent] in
      guard let stroke = keyStrokes[key] else { return [] }
      var events: [DoryVirtioInputEvent] = []
      if let modifier = stroke.modifierLinuxCode {
        events += [.init(type: 1, code: modifier, value: 1), .synchronize]
      }
      events += [
        .init(type: 1, code: stroke.linuxCode, value: 1),
        .synchronize,
        .init(type: 1, code: stroke.linuxCode, value: 0),
        .synchronize,
      ]
      if let modifier = stroke.modifierLinuxCode {
        events += [.init(type: 1, code: modifier, value: 0), .synchronize]
      }
      return events
    }
  }

  private static func usbKeyboardReports(for script: [String]) -> [[UInt8]] {
    script.flatMap { key -> [[UInt8]] in
      guard let stroke = keyStrokes[key] else { return [] }
      return [
        [stroke.usbModifier, 0, stroke.usbUsage, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
      ]
    }
  }

  private static func serialInputBytes(for script: [String]) -> [UInt8] {
    script.flatMap { keyStrokes[$0]?.serialBytes ?? [] }
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
  let digits: [UInt8] = Array("0123456789abcdef".utf8)
  var encoded = [UInt8]()
  encoded.reserveCapacity(bytes.count * 2)
  for byte in bytes {
    encoded.append(digits[Int(byte >> 4)])
    encoded.append(digits[Int(byte & 0x0F)])
  }
  return String(decoding: encoded, as: UTF8.self)
}

private func sha256<T: Encodable>(of value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return SHA256.hash(data: try encoder.encode(value))
    .map { String(format: "%02x", $0) }
    .joined()
}

private func sha256(of bytes: [UInt8]) -> String {
  SHA256.hash(data: Data(bytes))
    .map { String(format: "%02x", $0) }
    .joined()
}

private func displayFrameMetadata(_ frame: DoryVirtioGPUFrame) -> [String: Any] {
  [
    "scanoutID": frame.scanoutID,
    "resourceID": frame.resourceID,
    "resourceWidth": frame.resourceWidth,
    "resourceHeight": frame.resourceHeight,
    "scanoutX": frame.scanoutRectangle.x,
    "scanoutY": frame.scanoutRectangle.y,
    "scanoutWidth": frame.scanoutRectangle.width,
    "scanoutHeight": frame.scanoutRectangle.height,
    "damagedX": frame.damagedRectangle.x,
    "damagedY": frame.damagedRectangle.y,
    "damagedWidth": frame.damagedRectangle.width,
    "damagedHeight": frame.damagedRectangle.height,
    "format": frame.format.rawValue,
    "pixelByteCount": frame.pixels.count,
    "nonzeroPixelByteCount": frame.pixels.reduce(into: 0) { count, byte in
      if byte != 0 { count += 1 }
    },
    "pixelSHA256": sha256(of: frame.pixels),
  ]
}

private func captureDisplayFrame(
  _ frame: DoryVirtioGPUFrame?,
  to output: URL?
) throws -> [String: Any] {
  guard let output else { return ["status": "not-requested"] }
  guard let frame else {
    return ["status": "no-nonblank-frame", "path": output.path]
  }
  guard output.pathExtension.lowercased() == "ppm" else {
    throw SmokeError.usage("--display-capture-output must end in .ppm")
  }
  let pixelCount = Int(exactly: frame.resourceWidth)
    .flatMap { width in Int(exactly: frame.resourceHeight).map { width * $0 } }
  guard let pixelCount, frame.pixels.count == pixelCount * 4 else {
    throw SmokeError.usage("display frame dimensions do not match its pixel payload")
  }

  var portablePixmap = Data("P6\n\(frame.resourceWidth) \(frame.resourceHeight)\n255\n".utf8)
  portablePixmap.reserveCapacity(portablePixmap.count + pixelCount * 3)
  for offset in stride(from: 0, to: frame.pixels.count, by: 4) {
    switch frame.format {
    case .b8g8r8a8UNorm, .b8g8r8x8UNorm, .a8r8g8b8UNorm, .x8r8g8b8UNorm:
      portablePixmap.append(frame.pixels[offset + 2])
      portablePixmap.append(frame.pixels[offset + 1])
      portablePixmap.append(frame.pixels[offset])
    case .r8g8b8a8UNorm, .x8b8g8r8UNorm, .a8b8g8r8UNorm, .r8g8b8x8UNorm:
      portablePixmap.append(frame.pixels[offset])
      portablePixmap.append(frame.pixels[offset + 1])
      portablePixmap.append(frame.pixels[offset + 2])
    }
  }
  try portablePixmap.write(to: output, options: [.withoutOverwriting])
  return [
    "status": "written",
    "path": output.path,
    "byteCount": portablePixmap.count,
    "sha256": sha256(of: [UInt8](portablePixmap)),
    "sourceFrame": displayFrameMetadata(frame),
  ]
}

private func jitDiagnostics(_ diagnostics: DoryPCJITCacheStatistics?) -> Any {
  guard let diagnostics else { return NSNull() }
  let negativeCacheHotSites: [[String: Any]] = diagnostics.negativeCacheHotSites.map { site in
    [
      "guestRIP": hexadecimal(site.guestRIP),
      "executionMode": site.executionMode.rawValue,
      "instructionBudget": site.instructionBudget,
      "addressSpaceID": site.addressSpaceID,
      "privilegeLevel": site.privilegeLevel,
      "pagingEnabled": site.pagingEnabled,
      "guestByteCount": site.guestByteCount,
      "instructionBytes": site.instructionBytes.map { String(format: "%02x", $0) }.joined(),
      "declineReason": site.declineReason.rawValue,
      "hitCount": site.hitCount,
    ]
  }
  return [
    "recentLookupHits": diagnostics.recentLookupHits,
    "blockCacheLookupHits": diagnostics.blockCacheLookupHits,
    "dictionaryLookupHits": diagnostics.dictionaryLookupHits,
    "lookupMisses": diagnostics.lookupMisses,
    "memoryGenerationHits": diagnostics.memoryGenerationHits,
    "byteValidationHits": diagnostics.byteValidationHits,
    "sharedCodeHits": diagnostics.sharedCodeHits,
    "compiledBlocks": diagnostics.compiledBlocks,
    "optimizingCompilationAttempts": diagnostics.optimizingCompilationAttempts,
    "lookupVisibleOptimizedBlocks": diagnostics.lookupVisibleOptimizedBlocks,
    "lookupVisibleChangedOptimizedBlocks": diagnostics.lookupVisibleChangedOptimizedBlocks,
    "publishedPropagatedConstants": diagnostics.publishedPropagatedConstants,
    "publishedEliminatedStatements": diagnostics.publishedEliminatedStatements,
    "tier1CompilationAttempts": diagnostics.tier1CompilationAttempts,
    "tier1CompilationDeclines": diagnostics.tier1CompilationDeclines,
    "tier1CompiledBlocks": diagnostics.tier1CompiledBlocks,
    "lazyFlagMaterializations": diagnostics.lazyFlagMaterializations,
    "declinedCompilations": diagnostics.declinedCompilations,
    "negativeCacheHits": diagnostics.negativeCacheHits,
    "negativeCacheMisses": diagnostics.negativeCacheMisses,
    "negativeGenerationMismatches": diagnostics.negativeGenerationMismatches,
    "negativeEntryCount": diagnostics.negativeEntryCount,
    "negativeCacheHotSites": negativeCacheHotSites,
    "codeCacheWraps": diagnostics.codeCacheWraps,
    "codeCacheEvictedBlocks": diagnostics.codeCacheEvictedBlocks,
    "nativeTraceAttempts": diagnostics.nativeTraceAttempts,
    "nativeTraceReplays": diagnostics.nativeTraceReplays,
    "codeGenerationChecks": diagnostics.codeGenerationChecks,
    "codeGenerationMismatches": diagnostics.codeGenerationMismatches,
    "chainedExecutionCalls": diagnostics.chainedExecutionCalls,
    "chainedRequestedInstructions": diagnostics.chainedRequestedInstructions,
    "chainedRetiredInstructions": diagnostics.chainedRetiredInstructions,
    "pendingWorkExits": diagnostics.pendingWorkExits,
    "pendingWorkMaximumRetiredInstructions": diagnostics.pendingWorkMaximumRetiredInstructions,
    "nativeDispatcherEntries": diagnostics.nativeDispatcherEntries,
    "directChainPatches": diagnostics.directChainPatches,
    "directChainUnlinks": diagnostics.directChainUnlinks,
    "directlyChainedBlocks": diagnostics.directlyChainedBlocks,
    "chainTargetAttempts": diagnostics.chainTargetAttempts,
    "chainTargetAccepts": diagnostics.chainTargetAccepts,
    "chainTargetSourceShapeRejections": diagnostics.chainTargetSourceShapeRejections,
    "chainTargetBoundaryRejections": diagnostics.chainTargetBoundaryRejections,
    "chainTargetRestartableWriterRejections": diagnostics.chainTargetRestartableWriterRejections,
    "chainTargetMissingMemoryRejections": diagnostics.chainTargetMissingMemoryRejections,
    "chainTargetInterpreterGuardRejections": diagnostics.chainTargetInterpreterGuardRejections,
    "chainTargetCompilerABIRejections": diagnostics.chainTargetCompilerABIRejections,
    "chainTargetPublicationRejections": diagnostics.chainTargetPublicationRejections,
    "indirectBranchTargetCacheHits": diagnostics.indirectBranchTargetCacheHits,
    "indirectBranchTargetCacheMisses": diagnostics.indirectBranchTargetCacheMisses,
    "indirectBranchTargetCacheFills": diagnostics.indirectBranchTargetCacheFills,
    "indirectBranchTargetCacheHitRate": diagnostics.indirectBranchTargetCacheHitRate,
    "shadowReturnStackHits": diagnostics.shadowReturnStackHits,
    "shadowReturnStackMisses": diagnostics.shadowReturnStackMisses,
    "shadowReturnStackPushes": diagnostics.shadowReturnStackPushes,
    "shadowReturnStackHitRate": diagnostics.shadowReturnStackHitRate,
    "translationCacheEntryCount": diagnostics.translationCacheEntryCount,
    "translationCacheAllocatedBytes": diagnostics.translationCacheAllocatedBytes,
    "translationCacheAddressSpaceGeneration": diagnostics.translationCacheAddressSpaceGeneration,
    "translationCacheInvalidations": diagnostics.translationCacheInvalidations,
    "translationCacheHits": diagnostics.translationCacheHits,
    "translationCacheMisses": diagnostics.translationCacheMisses,
    "translationCacheFills": diagnostics.translationCacheFills,
    "translationCachePageFaults": diagnostics.translationCachePageFaults,
    "translationCacheFallbacks": diagnostics.translationCacheFallbacks,
    "translationCacheHitRate": diagnostics.translationCacheHitRate,
  ] as [String: Any]
}

private func pagingDiagnostics(_ diagnostics: [DoryX86PagingDiagnostics]) -> [[String: Any]] {
  diagnostics.enumerated().map { index, value in
    [
      "processor": index,
      "translationRequests": value.translationRequests,
      "pagingDisabledBypasses": value.pagingDisabledBypasses,
      "recentTLBHits": value.recentTLBHits,
      "dictionaryTLBHits": value.dictionaryTLBHits,
      "pageWalks": value.pageWalks,
      "pageWalkFailures": value.pageWalkFailures,
      "linearInvalidations": value.linearInvalidations,
      "globalInvalidations": value.globalInvalidations,
      "capacityFlushes": value.capacityFlushes,
      "cachedTranslations": value.cachedTranslations,
    ]
  }
}

private func physicalMemoryDiagnostics(
  _ diagnostics: DoryPCPhysicalMemoryDiagnostics
) -> [String: Any] {
  [
    "instructionFetchHelperCalls": diagnostics.instructionFetchHelperCalls,
    "readHelperCalls": diagnostics.readHelperCalls,
    "writeHelperCalls": diagnostics.writeHelperCalls,
    "validationHelperCalls": diagnostics.validationHelperCalls,
    "codeGenerationHelperCalls": diagnostics.codeGenerationHelperCalls,
    "atomicHelperCalls": diagnostics.atomicHelperCalls,
    "bulkHelperCalls": diagnostics.bulkHelperCalls,
    "dmaValidationCalls": diagnostics.dmaValidationCalls,
    "totalMemoryHelperCalls": diagnostics.totalMemoryHelperCalls,
    "mmioInstructionFetchExits": diagnostics.mmioInstructionFetchExits,
    "mmioReadExits": diagnostics.mmioReadExits,
    "mmioWriteExits": diagnostics.mmioWriteExits,
    "totalMMIOExits": diagnostics.totalMMIOExits,
  ]
}

private func timerInterruptDiagnostics(
  _ diagnostics: DoryPCTimerInterruptDiagnostics
) -> [String: Any] {
  [
    "localAPICRequests": diagnostics.localAPICRequests,
    "pitRequests": diagnostics.pitRequests,
    "rtcRequests": diagnostics.rtcRequests,
    "hpetRequests": diagnostics.hpetRequests,
    "totalRequests": diagnostics.totalRequests,
  ]
}

private func hostTimeBreakdown(_ value: DoryPCHostTimeBreakdown) -> [String: Any] {
  [
    "totalNanoseconds": value.totalNanoseconds,
    "processorEventNanoseconds": value.processorEventNanoseconds,
    "clockAdvancementNanoseconds": value.clockAdvancementNanoseconds,
    "interruptDeliveryNanoseconds": value.interruptDeliveryNanoseconds,
    "processorExecutionNanoseconds": value.processorExecutionNanoseconds,
    "idleWaitNanoseconds": value.idleWaitNanoseconds,
    "attributedNanoseconds": value.attributedNanoseconds,
    "unattributedNanoseconds": value.unattributedNanoseconds,
    "attributedBasisPoints": value.attributedBasisPoints,
  ]
}

private func hostExecutionDiagnostics(
  _ diagnostics: DoryPCHostExecutionDiagnostics
) -> [String: Any] {
  [
    "enabled": diagnostics.enabled,
    "runCalls": diagnostics.runCalls,
    "wall": hostTimeBreakdown(diagnostics.wall),
    "threadCPU": hostTimeBreakdown(diagnostics.threadCPU),
  ]
}

private func completedInstructions(for stop: DoryPCMachineStop) -> UInt64 {
  switch stop {
  case .halted(let instructionCount), .exception(_, let instructionCount),
    .tripleFault(_, let instructionCount), .poweredOff(let instructionCount),
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
    let diagnostics = device.blockDevice.diagnostics
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
      "requestCount": diagnostics.requestCount,
      "successfulRequestCount": diagnostics.successfulRequestCount,
      "failedRequestCount": diagnostics.failedRequestCount,
      "unsupportedRequestCount": diagnostics.unsupportedRequestCount,
      "readRequestCount": diagnostics.readRequestCount,
      "readByteCount": diagnostics.readByteCount,
      "writeRequestCount": diagnostics.writeRequestCount,
      "writeByteCount": diagnostics.writeByteCount,
      "recentReadRanges": diagnostics.recentReadRanges.map {
        ["offset": $0.offset, "byteCount": $0.byteCount]
      },
    ]
  }
}

private func displayDeviceDiagnostics(
  _ device: DoryPCVirtioGPUPCIDevice,
  memory: any DoryX86Memory
) -> [String: Any] {
  let state = device.transport.deviceState.snapshot()
  let commandDiagnostics = device.gpuDevice.commandDiagnostics
  let registerDiagnostics = device.transport.registerDiagnostics
  let bar = try? device.configurationFunction.bar(at: 0)
  let queues: [[String: Any]] = (0..<device.transport.queueCount).map { index in
    let queueNumber = UInt16(index)
    let registers = try? device.transport.queueSnapshot(at: queueNumber)
    let queue = try? device.transport.queue(at: queueNumber).snapshot()
    return [
      "index": index,
      "enabled": registers?.enabled ?? false,
      "size": registers?.size ?? 0,
      "descriptorAddress": registers.map { hexadecimal($0.descriptorAddress) } ?? "unavailable",
      "driverAddress": registers.map { hexadecimal($0.driverAddress) } ?? "unavailable",
      "deviceAddress": registers.map { hexadecimal($0.deviceAddress) } ?? "unavailable",
      "guestAvailableIndex": registers.flatMap {
        queueIndex(memory: memory, address: $0.driverAddress &+ 2)
      } ?? "unavailable",
      "guestUsedIndex": registers.flatMap {
        queueIndex(memory: memory, address: $0.deviceAddress &+ 2)
      } ?? "unavailable",
      "availableIndex": queue?.lastAvailableIndex ?? 0,
      "usedIndex": queue?.lastUsedIndex ?? 0,
      "outstandingHeads": queue?.outstandingHeads.count ?? 0,
    ]
  }
  return [
    "pciAddress": String(
      format: "%04x:%02x:%02x.%x",
      device.pciAddress.segment,
      device.pciAddress.bus,
      device.pciAddress.device,
      device.pciAddress.function
    ),
    "pciCommand": device.configurationFunction.command,
    "bar0": bar.map { hexadecimal($0.address) } ?? "unavailable",
    "offeredFeatures": state.offeredFeatures.rawValue,
    "negotiatedFeatures": state.negotiatedFeatures.rawValue,
    "status": state.status.rawValue,
    "completedCommandCount": commandDiagnostics.completedCommandCount,
    "failedCommandCount": commandDiagnostics.failedCommandCount,
    "resetCount": commandDiagnostics.resetCount,
    "registerReadCount": registerDiagnostics.readCount,
    "registerWriteCount": registerDiagnostics.writeCount,
    "recentRegisterAccesses": registerDiagnostics.recentAccesses.map { access in
      [
        "sequenceNumber": access.sequenceNumber,
        "offset": hexadecimal(access.offset),
        "byteCount": access.byteCount,
        "write": access.write,
        "bytes": hexadecimalBytes(access.bytes),
      ] as [String: Any]
    },
    "recentCommands": commandDiagnostics.recentCommands.map { command in
      [
        "sequenceNumber": command.sequenceNumber,
        "queue": command.queue,
        "requestType": String(format: "0x%04x", command.requestType),
        "requestByteCount": command.requestByteCount,
        "responseType": command.responseType.map { String(format: "0x%04x", $0) }
          ?? "unavailable",
        "responseByteCount": command.responseByteCount.map { $0 as Any } ?? NSNull(),
      ] as [String: Any]
    },
    "queues": queues,
  ]
}

private func interruptControllerDiagnostics(_ machine: DoryPCDirectKernelMachine) -> [String: Any] {
  let pic = machine.legacyPIC.snapshot()
  let pit = machine.legacyPIT.snapshot()
  let hpet = machine.hpet.snapshot()
  return [
    "legacyPIC": [
      "masterVectorOffset": pic.masterVectorOffset,
      "slaveVectorOffset": pic.slaveVectorOffset,
      "masterMask": pic.masterMask,
      "slaveMask": pic.slaveMask,
      "masterRequest": pic.masterRequest,
      "slaveRequest": pic.slaveRequest,
      "masterInService": pic.masterInService,
      "slaveInService": pic.slaveInService,
      "masterLevelTriggered": pic.masterLevelTriggered,
      "slaveLevelTriggered": pic.slaveLevelTriggered,
      "masterAssertedLines": pic.masterAssertedLines,
      "slaveAssertedLines": pic.slaveAssertedLines,
    ],
    "legacyPIT": [
      "mode": String(describing: pit.mode),
      "reload": pit.reload,
      "current": pit.current,
      "armed": pit.armed,
    ],
    "localAPICs": machine.localAPICs.map(localAPICDiagnostics),
    "ioAPIC": machine.ioAPIC.snapshot().map(ioAPICPinDiagnostics),
    "hpet": [
      "enabled": hpet.enabled,
      "legacyReplacement": hpet.legacyReplacement,
      "mainCounter": hpet.mainCounter,
      "interruptStatus": hpet.interruptStatus,
      "timers": hpet.timers.enumerated().map { index, timer in
        [
          "index": index,
          "configuration": timer.configuration,
          "comparator": timer.comparator,
          "period": timer.period,
          "armed": timer.armed,
        ] as [String: Any]
      },
    ],
  ]
}

private func localAPICDiagnostics(_ apic: DoryPCLocalAPIC) -> [String: Any] {
  let snapshot = apic.snapshot()
  return [
    "apicID": snapshot.apicID,
    "softwareEnabled": snapshot.softwareEnabled,
    "spuriousVector": snapshot.spuriousVector,
    "taskPriority": snapshot.taskPriority,
    "interruptRequest": snapshot.interruptRequest.sorted(),
    "inService": snapshot.inService.sorted(),
    "levelTriggered": snapshot.levelTriggered.sorted(),
    "timer": [
      "vector": snapshot.timer.vector,
      "masked": snapshot.timer.masked,
      "mode": snapshot.timer.mode.rawValue,
      "initialCount": snapshot.timer.initialCount,
      "currentCount": snapshot.timer.currentCount,
    ],
  ]
}

private func ioAPICPinDiagnostics(_ pin: DoryPCIOAPICPinSnapshot) -> [String: Any] {
  [
    "pin": pin.pin,
    "vector": pin.route.vector,
    "destinationAPICID": pin.route.destinationAPICID,
    "masked": pin.route.masked,
    "levelTriggered": pin.route.levelTriggered,
    "activeLow": pin.route.activeLow,
    "asserted": pin.asserted,
    "remoteIRR": pin.remoteIRR,
  ]
}

private func queueIndex(memory: any DoryX86Memory, address: UInt64) -> String? {
  guard address > 2, let bytes = try? memory.read(at: address, byteCount: 2) else { return nil }
  let value = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
  return String(value)
}

private func powerControllerDiagnostics(_ controller: DoryPCPowerController) -> [String: Any] {
  let snapshot = controller.snapshot()
  let action: (DoryPCPowerAction) -> String = {
    switch $0 {
    case .powerOff: "power-off"
    case .reset: "reset"
    }
  }
  return [
    "pm1Control": String(format: "0x%04x", snapshot.pm1Control),
    "pendingAction": snapshot.pendingAction.map(action) ?? NSNull(),
    "lastRequestedAction": snapshot.lastRequestedAction.map(action) ?? NSNull(),
    "lastRequestSource": snapshot.lastRequestSource?.rawValue ?? NSNull(),
    "resetPortWriteCount": snapshot.resetPortWriteCount,
    "acceptedResetCount": snapshot.acceptedResetCount,
    "lastResetPortValue": snapshot.lastResetPortValue.map { String(format: "0x%02x", $0) }
      ?? NSNull(),
  ]
}

private func runWithProgress(
  machine: DoryPCDirectKernelMachine,
  blockDevices: [DoryPCVirtioBlockPCIDevice],
  maximumInstructions: UInt64,
  progressInstructions: UInt64,
  exceptionPolicy: DoryPCExceptionPolicy,
  traceAfterInstructions: UInt64?,
  traceCapacity: Int,
  traceBreakRIPBelow: UInt64?,
  bootTimeline: DoryPCBootTimeline?,
  inputBoundaryInstructions: [UInt64] = [],
  beforeInstructionBoundary: ((UInt64) throws -> Void)? = nil
) throws -> (stop: DoryPCMachineStop, trace: [[String: Any]], traceStopReason: String?) {
  var completed: UInt64 = 0
  var trace: [[String: Any]] = []
  while completed < maximumInstructions {
    try beforeInstructionBoundary?(completed)
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
    let distanceToInput = inputBoundaryInstructions.compactMap {
      $0 > completed ? $0 - completed : nil
    }.min() ?? 0
    let nextBoundary = min(
      distanceToTrace == 0 ? progressInstructions : distanceToTrace,
      distanceToInput == 0 ? progressInstructions : distanceToInput
    )
    let chunk = min(
      tracing
        ? 1
        : max(
          1,
          min(progressInstructions, nextBoundary)),
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
        "bootTimeline": try bootTimeline.map {
          try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.snapshot()))
        } ?? NSNull(),
        "completedInstructions": completed,
        "instructionPointer": state.map { hexadecimal($0.cs.base &+ $0.rip) } ?? "unavailable",
        "interpreterInstructions": statistics.interpreterInstructions,
        "baselineJITInstructions": statistics.baselineJITInstructions,
        "optimizingJITInstructions": statistics.optimizingJITInstructions,
        "pagingDiagnostics": pagingDiagnostics(machine.pagingDiagnostics),
        "physicalMemoryDiagnostics": physicalMemoryDiagnostics(machine.physicalMemory.diagnostics),
        "timerInterruptDiagnostics": timerInterruptDiagnostics(
          machine.timerInterruptDiagnostics),
        "hostExecutionDiagnostics": hostExecutionDiagnostics(
          machine.hostExecutionDiagnostics),
        "blockDevices": blockDeviceDiagnostics(blockDevices, memory: machine.physicalMemory),
      ]
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      FileHandle.standardError.write(data + Data("\n".utf8))
    case .halted(let count): return (.halted(instructionCount: completed &+ count), trace, nil)
    case .exception(let exception, let count):
      return (.exception(exception, instructionCount: completed &+ count), trace, nil)
    case .tripleFault(let source, let count):
      return (
        .tripleFault(source: source, instructionCount: completed &+ count),
        trace,
        nil
      )
    case .poweredOff(let count):
      return (.poweredOff(instructionCount: completed &+ count), trace, nil)
    case .reset(let count): return (.reset(instructionCount: completed &+ count), trace, nil)
    }
  }
  return (.instructionBudget(completed), trace, nil)
}

private func enqueueKeyboardInput(
  on composed: DoryPCUEFIMachine,
  route: Arguments.KeyboardRoute,
  script: [String],
  keyboardEvents: [DoryVirtioInputEvent],
  usbKeyboardReports: [[UInt8]],
  serialInputBytes: [UInt8]
) throws {
  switch route {
  case .all, .virtio:
    guard composed.keyboardDevice.enqueueSynchronized(keyboardEvents) else {
      throw SmokeError.keyboardQueueFull
    }
  case .usbHID, .serial:
    break
  }
  switch route {
  case .all, .usbHID:
    for report in usbKeyboardReports {
      try composed.usbKeyboardDevice.enqueue(report: report)
    }
  case .virtio, .serial:
    break
  }
  switch route {
  case .all, .serial:
    composed.machine.serial.enqueueReceivedBytes(serialInputBytes)
  case .virtio, .usbHID:
    break
  }
  if route == .all {
    guard composed.machine.ps2Keyboard.enqueueSet1ScanCodes(ps2Set2ScanCodes(for: script)) else {
      throw SmokeError.keyboardQueueFull
    }
  }
}

private func ps2Set2ScanCodes(for script: [String]) -> [UInt8] {
  let make: [String: UInt8] = [
    "enter": 0x5A, "space": 0x29, "end": 0x69, "e": 0x24, "c": 0x21,
    "o": 0x44, "n": 0x31, "s": 0x1B, "l": 0x4B, "equals": 0x55,
    "t": 0x2C, "y": 0x35, "shift-s": 0x1B, "0": 0x45, "comma": 0x41,
    "1": 0x16, "2": 0x1E, "5": 0x2E
  ]
  return script.flatMap { token -> [UInt8] in
    if token == "ctrl-x" { return [0x14, 0x22, 0xF0, 0x22, 0xF0, 0x14] }
    guard let code = make[token] else { return [] }
    if token == "shift-s" { return [0x12, code, 0xF0, code, 0xF0, 0x12] }
    return [code, 0xF0, code]
  }
}

private func pageTableTrace(
  memory: any DoryX86PhysicalRAM,
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
  let displaySink = SmokeDisplaySink()
  let composed = try DoryPCUEFIMachine(
    plan: plan,
    firmware: artifacts,
    variableStore: .init(file: variable.file),
    bootStorage: storages,
    memoryBytes: arguments.memoryBytes,
    processorCount: arguments.processorCount,
    initialRTCDate: Date(timeIntervalSince1970: TimeInterval(arguments.initialRTCUnixSeconds)),
    firmwareConfigurationFlags: arguments.bootProbe ? [.qualificationBootProbe] : [],
    displaySink: displaySink,
    executionTier: arguments.executionTier,
    baselineJITTier1Enabled: arguments.baselineJITTier1Enabled,
    clockSource: arguments.clockSource,
    instrumentationEnabled: arguments.instrumentationEnabled
  )
  let bootTimeline = arguments.bootTimelineEnabled ? DoryPCBootTimeline() : nil
  composed.machine.serial.observeBoot(with: bootTimeline)
  defer { bootTimeline?.finish(reason: "execution-error") }
  let deadline = SmokeDeadline(machine: composed.machine, seconds: arguments.timeoutSeconds)
  defer { deadline.finish() }
  let executionStarted = DispatchTime.now().uptimeNanoseconds
  var keyboardInjectionAtInstructions: UInt64?
  var secondKeyboardInjectionAtInstructions: UInt64?
  let execution = try runWithProgress(
    machine: composed.machine,
    blockDevices: composed.blockDevices,
    maximumInstructions: arguments.maximumInstructions,
    progressInstructions: arguments.progressInstructions,
    exceptionPolicy: arguments.exceptionPolicy,
    traceAfterInstructions: arguments.traceAfterInstructions,
    traceCapacity: arguments.traceCapacity,
    traceBreakRIPBelow: arguments.traceBreakRIPBelow,
    bootTimeline: bootTimeline,
    inputBoundaryInstructions: [
      arguments.keyboardAfterInstructions,
      arguments.secondKeyboardAfterInstructions,
    ].compactMap { $0 },
    beforeInstructionBoundary: { completed in
      if
        keyboardInjectionAtInstructions == nil,
        let after = arguments.keyboardAfterInstructions,
        completed >= after
      {
        try enqueueKeyboardInput(
          on: composed,
          route: arguments.keyboardRoute,
          script: arguments.keyboardScript,
          keyboardEvents: arguments.keyboardEvents,
          usbKeyboardReports: arguments.usbKeyboardReports,
          serialInputBytes: arguments.serialInputBytes
        )
        keyboardInjectionAtInstructions = completed
      }
      if
        secondKeyboardInjectionAtInstructions == nil,
        let after = arguments.secondKeyboardAfterInstructions,
        completed >= after
      {
        try enqueueKeyboardInput(
          on: composed,
          route: arguments.keyboardRoute,
          script: arguments.secondKeyboardScript,
          keyboardEvents: arguments.secondKeyboardEvents,
          usbKeyboardReports: arguments.secondUSBKeyboardReports,
          serialInputBytes: arguments.secondSerialInputBytes
        )
        secondKeyboardInjectionAtInstructions = completed
      }
    }
  )
  let executionElapsed = DispatchTime.now().uptimeNanoseconds - executionStarted
  let stop = execution.stop
  let timedOut = deadline.finish()
  bootTimeline?.finish(reason: timedOut ? "host-execution-deadline" : String(describing: stop))
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
  let processorStates: [[String: Any]] = composed.machine.processorExecutionSnapshots.map {
    snapshot in
    let processorState = snapshot.state
    let bytes =
      (try? composed.machine.instructionBytes(
        forProcessor: snapshot.index,
        maximumCount: 16
      )) ?? nil
    return [
      "index": snapshot.index,
      "lifecycle": snapshot.lifecycle.rawValue,
      "halted": snapshot.isHalted,
      "rip": processorState.map { hexadecimal($0.rip) } ?? "unavailable",
      "linearInstructionPointer":
        processorState.map { hexadecimal($0.cs.base &+ $0.rip) } ?? "unavailable",
      "instructionBytes": bytes.map(hexadecimalBytes) ?? "unmapped",
      "csSelector":
        processorState.map { String(format: "0x%04x", $0.cs.selector) } ?? "unavailable",
      "csBase": processorState.map { hexadecimal($0.cs.base) } ?? "unavailable",
      "csAttributes":
        processorState.map { String(format: "0x%04x", $0.cs.attributes) } ?? "unavailable",
      "cr0": processorState.map { hexadecimal($0.control.cr0) } ?? "unavailable",
      "cr3": processorState.map { hexadecimal($0.control.cr3) } ?? "unavailable",
      "cr4": processorState.map { hexadecimal($0.control.cr4) } ?? "unavailable",
      "efer": processorState.map { hexadecimal($0.control.efer) } ?? "unavailable",
      "rflags": processorState.map { hexadecimal($0.rflags.rawValue) } ?? "unavailable",
      "rsp": processorState.map { hexadecimal($0.registers.rsp) } ?? "unavailable",
    ]
  }
  let stackBytes =
    state.flatMap {
      (try? composed.machine.memoryBytes(atLinearAddress: $0.registers.rsp, maximumCount: 64))
        ?? nil
    }
  let sourceIndexBytes =
    state.flatMap {
      (try? composed.machine.memoryBytes(atLinearAddress: $0.registers.rsi, maximumCount: 64))
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
  let displayDevice = displayDeviceDiagnostics(
    composed.displayDevice,
    memory: composed.machine.physicalMemory
  )
  let display = displaySink.snapshot()
  let lastDisplayFrame: Any =
    display.lastFrame.map(displayFrameMetadata) ?? NSNull()
  let lastNonblankDisplayFrame: Any =
    display.lastNonblankFrame.map(displayFrameMetadata) ?? NSNull()
  let displayCapture = try captureDisplayFrame(
    display.lastNonblankFrame,
    to: arguments.displayCaptureOutput
  )
  let payload: [String: Any] = [
    "bootTimeline": try bootTimeline.map {
      try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.snapshot()))
    } ?? NSNull(),
    "cpuProfileIdentifier": composed.machine.interpreter.profile.identifier,
    "cpuIdentity": composed.machine.interpreter.profile.identity.rawValue,
    "virtualTSCFrequencyHz": composed.machine.interpreter.profile.virtualTSCFrequencyHz,
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
    "executionTimeoutSeconds": arguments.timeoutSeconds,
    "executionElapsedNanoseconds": executionElapsed,
    "baselineJITTier1Enabled": arguments.baselineJITTier1Enabled,
    "instrumentationEnabled": arguments.instrumentationEnabled,
    "timedOut": timedOut,
    "progressInstructions": arguments.progressInstructions,
    "traceAfterInstructions": arguments.traceAfterInstructions.map { $0 as Any } ?? NSNull(),
    "traceBreakRIPBelow": arguments.traceBreakRIPBelow.map { $0 as Any } ?? NSNull(),
    "traceStopReason": execution.traceStopReason.map { $0 as Any } ?? NSNull(),
    "instructionTrace": execution.trace,
    "processorCount": arguments.processorCount,
    "processorStates": processorStates,
    "bootOrder": bootOrder,
    "exceptionPolicy": arguments.exceptionPolicy == .stop ? "stop" : "deliver",
    "executionTier": arguments.executionTier.rawValue,
    "jitWriteCoherencePolicy": composed.machine.jitWriteCoherencePolicy.rawValue,
    "completedInstructions": completedInstructions(for: stop),
    "architecturalStateSHA256": architecturalStateSHA256.map { $0 as Any } ?? NSNull(),
    "interpreterInstructions": executionStatistics.interpreterInstructions,
    "baselineJITInstructions": executionStatistics.baselineJITInstructions,
    "baselineJITBlocks": executionStatistics.baselineJITBlocks,
    "baselineJITDiagnostics": jitDiagnostics(composed.machine.baselineJITDiagnostics),
    "optimizingJITInstructions": executionStatistics.optimizingJITInstructions,
    "optimizingJITBlocks": executionStatistics.optimizingJITBlocks,
    "optimizingJITDiagnostics": jitDiagnostics(composed.machine.optimizingJITDiagnostics),
    "pagingDiagnostics": pagingDiagnostics(composed.machine.pagingDiagnostics),
    "physicalMemoryDiagnostics": physicalMemoryDiagnostics(
      composed.machine.physicalMemory.diagnostics),
    "timerInterruptDiagnostics": timerInterruptDiagnostics(
      composed.machine.timerInterruptDiagnostics),
    "hostExecutionDiagnostics": hostExecutionDiagnostics(
      composed.machine.hostExecutionDiagnostics),
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
    "rsiBytes": sourceIndexBytes.map(hexadecimalBytes) ?? "unmapped",
    "serialOutput": serialOutput,
    "serialMarkerExpected": arguments.expectedSerialMarker.map { $0 as Any } ?? NSNull(),
    "serialMarkerMatched": serialMarkerMatched.map { $0 as Any } ?? NSNull(),
    "bootProbe": arguments.bootProbe,
    "serialDroppedBytes": serialDrops.transmitted,
    "blockDevices": blockDevices,
    "clockSource": arguments.clockSourceDescription,
    "displayDevice": displayDevice,
    "displayFrameCount": display.frameCount,
    "displayNonblankFrameCount": display.nonblankFrameCount,
    "lastDisplayFrame": lastDisplayFrame,
    "lastNonblankDisplayFrame": lastNonblankDisplayFrame,
    "displayCapture": displayCapture,
    "keyboardScript": arguments.keyboardScript,
    "keyboardRoute": arguments.keyboardRoute.rawValue,
    "keyboardEventCount": arguments.keyboardEvents.count,
    "keyboardInjectionRequestedAfterInstructions": arguments.keyboardAfterInstructions.map {
      $0 as Any
    } ?? NSNull(),
    "keyboardInjectionAtInstructions": keyboardInjectionAtInstructions.map { $0 as Any } ?? NSNull(),
    "keyboardSecondScript": arguments.secondKeyboardScript,
    "keyboardSecondEventCount": arguments.secondKeyboardEvents.count,
    "keyboardSecondInjectionRequestedAfterInstructions": arguments.secondKeyboardAfterInstructions.map {
      $0 as Any
    } ?? NSNull(),
    "keyboardSecondInjectionAtInstructions": secondKeyboardInjectionAtInstructions.map {
      $0 as Any
    } ?? NSNull(),
    "keyboardEventsPending": composed.keyboardDevice.inputDevice.hasPendingEvent,
    "usbKeyboardReportCount": arguments.usbKeyboardReports.count,
    "usbKeyboardSecondReportCount": arguments.secondUSBKeyboardReports.count,
    "usbKeyboardReportsPending": composed.usbKeyboardDevice.hasPendingReport,
    "serialInputByteCount": arguments.serialInputBytes.count,
    "serialSecondInputByteCount": arguments.secondSerialInputBytes.count,
    "serialInputBytesPending": composed.machine.serial.hasPendingReceivedBytes,
    "interruptControllers": interruptControllerDiagnostics(composed.machine),
    "powerController": powerControllerDiagnostics(composed.machine.powerController),
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
  if timedOut { throw SmokeError.executionDeadlineExceeded }
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
