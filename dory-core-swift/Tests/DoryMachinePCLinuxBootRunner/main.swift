import Darwin
import Dispatch
import DoryMachinePC
import Foundation

/// The watchdog uses a cached record, never the VM lock. A stalled machine.run() cannot
/// suppress the wall budget or force the watchdog to wait for architectural-state access.
private final class PVHRunnerSession: @unchecked Sendable {
  private let lock = NSLock()
  private let started = DispatchTime.now().uptimeNanoseconds
  private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
  private var record: PVHDiagnosticRecord

  init(configuration: PVHRunnerConfiguration) {
    record = .init(configuration: configuration)
    timer.schedule(deadline: .now() + .seconds(Int(configuration.wallSeconds)), leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.finish(.wallBudget) }
    timer.resume()
  }

  var elapsedNanoseconds: UInt64 { DispatchTime.now().uptimeNanoseconds - started }

  func publish(_ value: PVHDiagnosticRecord) {
    lock.lock()
    record = value
    lock.unlock()
  }

  func finish(_ requestedOutcome: PVHRunOutcome, error: Error? = nil) -> Never {
    // Hold this short-lived cache lock through publication/exit so the normal and timeout
    // paths cannot race to emit contradictory outcomes. No VM method is called here.
    lock.lock()
    record.elapsedNanoseconds = elapsedNanoseconds
    let outcome = record.elapsedNanoseconds >= record.configuration.wallSeconds * 1_000_000_000
      ? PVHRunOutcome.wallBudget : requestedOutcome
    record.outcome = outcome
    record.stage = "finished"
    if let error { record.error = String(String(describing: error).prefix(1024)) }
    var code = outcome.exitCode
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let path = record.configuration.diagnostics {
      do {
        let data = try encoder.encode(record)
        // Every retained collection/string has its own limit; keep an independent output ceiling.
        guard data.count <= 1 << 20 else { throw PVHRunnerError("Diagnostic record exceeds 1 MiB") }
        try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
      } catch {
        code = code == 124 ? 124 : 1
        let message = "Cannot publish diagnostic receipt: " + String(String(describing: error).prefix(512)) + "\n"
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
      }
    }
    struct Summary: Encodable {
      let kind = "dev.dory.pvh-boot-result"
      let runID: String
      let passed: Bool
      let reason: String
      let exitCode: Int32
      let retiredInstructions: UInt64
      let elapsedNanoseconds: UInt64
      let guestReceiptSeen: Bool
      let kernelSHA256: String
      let kernelBuildID: String?
      let initrdSHA256: String
      let error: String?
    }
    let summary = Summary(
      runID: record.configuration.runID, passed: outcome.passed && code == 0,
      reason: outcome.reason, exitCode: code, retiredInstructions: record.retiredInstructions,
      elapsedNanoseconds: record.elapsedNanoseconds, guestReceiptSeen: record.guestReceipt != nil,
      kernelSHA256: record.configuration.kernelSHA256, kernelBuildID: record.kernel?.elfBuildID,
      initrdSHA256: record.configuration.initrdSHA256, error: record.error
    )
    if var output = try? encoder.encode(summary) {
      output.append(10)
      try? FileHandle.standardOutput.write(contentsOf: output)
    }
    Darwin.exit(code)
  }
}

private func run(_ configuration: PVHRunnerConfiguration) -> Never {
  let session = PVHRunnerSession(configuration: configuration)
  var record = PVHDiagnosticRecord(configuration: configuration)
  do {
    if let path = configuration.diagnostics, FileManager.default.fileExists(atPath: path) {
      throw PVHRunnerError("Diagnostic output already exists; use a new file for this run")
    }
    let kernel = try PVHPinnedInput.read(path: configuration.kernel, sha256: configuration.kernelSHA256)
    let kernelImage = try DoryPCPVHKernelImage(data: kernel.data)
    let metadata = PVHELFMetadata(validatedImage: kernelImage)
    record.kernel = .init(
      path: kernel.identity.path, sha256: kernel.identity.sha256,
      byteCount: kernel.identity.byteCount, elfBuildID: metadata.buildID)
    session.publish(record)
    let initrd = try PVHPinnedInput.read(path: configuration.initrd, sha256: configuration.initrdSHA256)
    record.initrd = initrd.identity
    session.publish(record)
    var symbols: PVHSymbolMap?
    if let path = configuration.symbols, let hash = configuration.symbolsSHA256 {
      let input = try PVHPinnedInput.read(path: path, sha256: hash, maximumBytes: 32 << 20)
      symbols = try PVHSymbolMap(data: input.data)
      record.symbols = input.identity
    }
    record.stage = "loading-machine"
    session.publish(record)
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: configuration.memoryMiB * 1024 * 1024,
      initialRTCDate: Date(timeIntervalSince1970: 0), executionTier: configuration.tier,
      clockSource: .deterministic)
    try machine.load(kernel: kernel.data, initrd: Array(initrd.data), commandLine: configuration.commandLine)
    record.stage = "running"
    record.state = machine.state
    session.publish(record)
    var console = PVHConsoleCapture()
    while record.retiredInstructions < configuration.maximumInstructions {
      if session.elapsedNanoseconds >= configuration.wallSeconds * 1_000_000_000 {
        session.finish(.wallBudget)
      }
      let quantum = min(1000, configuration.maximumInstructions - record.retiredInstructions)
      let stop = try machine.run(maximumInstructions: quantum, exceptionPolicy: .deliver)
      let retired = PVHStopSnapshot.instructionCount(stop)
      guard retired <= quantum else { throw PVHRunnerError("Machine returned more instructions than requested") }
      record.retiredInstructions += retired
      console.consume(
        machine.serial.drainTransmittedBytes(), runID: configuration.runID, workloads: configuration.workloads)
      record.guestReceipt = console.receipt
      record.consoleBytes = console.totalBytes
      record.consoleTail = String(decoding: console.tail, as: UTF8.self)
      let state = machine.state
      let symbol = state.flatMap { metadata.symbolAddress(state: $0) }.flatMap { symbols?.nearest(to: $0) }
      record.lastExits.append(.init(
        stop: stop, totalInstructions: record.retiredInstructions,
        elapsedNanoseconds: session.elapsedNanoseconds, state: state, nearestSymbol: symbol))
      if record.lastExits.count > 16 { record.lastExits.removeFirst(record.lastExits.count - 16) }
      record.state = state
      record.executionStatistics = machine.executionStatistics
      if configuration.diagnostics != nil {
        record.timerInterruptState = try PVHTimerInterruptSnapshot(machine: machine)
      }
      record.elapsedNanoseconds = session.elapsedNanoseconds
      session.publish(record)
      if let outcome = PVHRunOutcome.terminal(stop: stop, receiptSeen: console.receipt != nil) {
        session.finish(outcome)
      }
      guard retired > 0 else { throw PVHRunnerError("Machine made no progress within an instruction quantum") }
    }
    session.finish(.instructionBudget)
  } catch {
    session.finish(.init(passed: false, reason: "fixture-or-runner-error", exitCode: 1), error: error)
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
  print(PVHRunnerConfiguration.usage)
  Darwin.exit(0)
}
do {
  run(try PVHRunnerConfiguration(arguments: arguments))
} catch {
  let message = String(String(describing: error).prefix(1024)) + "\nUse --help for required options.\n"
  try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
  Darwin.exit(2)
}
