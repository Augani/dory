import CryptoKit
import Foundation
import Testing

@testable import dory_pc_linux_boot_runner

@Suite struct PVHBootRunnerTests {
  private let runID = "fe154770-27f1-4d31-93b5-790932bdf83c"
  private let workloads = ["exec-fork", "file-io"]

  @Test func configurationRequiresExplicitPinnedInputsAndUniqueCampaign() throws {
    let configuration = try PVHRunnerConfiguration(arguments: arguments())
    #expect(configuration.commandLine.hasSuffix("dory.pvh_run_id=" + runID))
    #expect(configuration.workloads == workloads)
    #expect(configuration.memoryMiB == 512)
    #expect(configuration.maximumInstructions == 10000)
    #expect(configuration.diagnostics == nil)
    #expect(throws: PVHRunnerError.self) { _ = try PVHRunnerConfiguration(arguments: []) }
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHRunnerConfiguration(arguments: arguments() + ["--tier", "interpreter"])
    }
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHRunnerConfiguration(arguments: arguments() + ["--unknown", "value"])
    }
  }

  @Test func configurationRejectsAmbiguousOrUnboundedInputs() {
    for (option, value) in [
      ("--kernel", "relative/vmlinux"), ("--kernel-sha256", String(repeating: "A", count: 64)),
      ("--initrd-sha256", "missing"), ("--memory-mib", "0"), ("--memory-mib", "524289"),
      ("--max-instructions", "0"), ("--max-instructions", "18446744073709551615"),
      ("--wall-seconds", "0"), ("--wall-seconds", "3601"), ("--wall-seconds", "nan"),
      ("--run-id", "reused-name"), ("--tier", "unknown"), ("--command-line", "x\0y"),
      ("--command-line", "dory.pvh_run_id=already-present"),
    ] {
      #expect(throws: PVHRunnerError.self) {
        _ = try PVHRunnerConfiguration(arguments: arguments(replacing: option, with: value))
      }
    }
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHRunnerConfiguration(arguments: arguments() + ["--workload", "exec-fork"])
    }
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHRunnerConfiguration(arguments: arguments() + ["--symbols", "/System.map"])
    }
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHRunnerConfiguration(arguments: arguments() + ["--diagnostics", "/kernel"])
    }
  }

  @Test func pinnedFilesFailClosedOnMissingChangedOversizedAndSpecialFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("kernel")
    let bytes = Data([1, 2, 3, 4])
    try bytes.write(to: file)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    #expect(try PVHPinnedInput.read(path: file.path, sha256: hash).data == bytes)
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHPinnedInput.read(path: file.path, sha256: String(repeating: "0", count: 64))
    }
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHPinnedInput.read(path: file.path, sha256: hash, maximumBytes: 3)
    }
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHPinnedInput.read(path: directory.appendingPathComponent("missing").path, sha256: hash)
    }
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHPinnedInput.read(path: directory.path, sha256: hash)
    }
    let symlink = directory.appendingPathComponent("symlink")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
    #expect(throws: PVHRunnerError.self) {
      _ = try PVHPinnedInput.read(path: symlink.path, sha256: hash)
    }
    try Data([4, 3, 2, 1]).write(to: file)
    #expect(throws: PVHRunnerError.self) { _ = try PVHPinnedInput.read(path: file.path, sha256: hash) }
  }

  @Test func receiptMustMatchRunIDAndExactSuccessfulWorkloads() throws {
    var capture = PVHConsoleCapture()
    for receipt in [
      PVHGuestReceipt(schemaVersion: 1, doryPVHBoot: "userspace-ready", runID: UUID().uuidString, workloadsPassed: true, workloads: workloads),
      PVHGuestReceipt(schemaVersion: 1, doryPVHBoot: "userspace-ready", runID: runID, workloadsPassed: false, workloads: workloads),
      PVHGuestReceipt(schemaVersion: 1, doryPVHBoot: "userspace-ready", runID: runID, workloadsPassed: true, workloads: ["exec-fork"]),
      PVHGuestReceipt(schemaVersion: 2, doryPVHBoot: "userspace-ready", runID: runID, workloadsPassed: true, workloads: workloads),
    ] {
      capture.consume(try line(receipt), runID: runID, workloads: workloads)
      #expect(capture.receipt == nil)
    }
    let valid = try validLine()
    capture.consume(Array(valid.dropLast()), runID: runID, workloads: workloads)
    #expect(capture.receipt == nil)  // An unterminated partial marker is not success.
    capture.consume([10], runID: runID, workloads: workloads)
    #expect(capture.receipt?.runID == runID)
  }

  @Test func consoleNoiseAndTruncationCannotManufactureReceipt() throws {
    let valid = try validLine()
    var capture = PVHConsoleCapture()
    capture.consume(Array("Kernel command line: ".utf8) + valid, runID: runID, workloads: workloads)
    #expect(capture.receipt == nil)
    capture.consume([UInt8](repeating: 65, count: 100_000), runID: runID, workloads: workloads)
    capture.consume(valid, runID: runID, workloads: workloads)
    #expect(capture.receipt == nil)  // The discarded long line includes this apparent suffix.
    #expect(capture.tail.count == PVHConsoleCapture.maximumTailBytes)
    #expect(capture.totalBytes > 100_000)
    for byte in valid { capture.consume([byte], runID: runID, workloads: workloads) }
    #expect(capture.receipt?.workloadsPassed == true)
  }

  @Test func successRequiresBothReceiptAndCleanPoweroff() throws {
    let withoutReceipt = try #require(PVHRunOutcome.terminal(stop: .poweredOff(instructionCount: 9), receiptSeen: false))
    #expect(!withoutReceipt.passed)
    #expect(withoutReceipt.exitCode != 0)
    let success = try #require(PVHRunOutcome.terminal(stop: .poweredOff(instructionCount: 9), receiptSeen: true))
    #expect(success.passed)
    #expect(success.exitCode == 0)
    #expect(PVHRunOutcome.terminal(stop: .instructionBudget(1000), receiptSeen: true) == nil)
    #expect(PVHRunOutcome.terminal(stop: .halted(instructionCount: 9), receiptSeen: true)?.passed == false)
    #expect(PVHRunOutcome.terminal(stop: .reset(instructionCount: 9), receiptSeen: true)?.passed == false)
    #expect(PVHRunOutcome.wallBudget.exitCode == 124)
    #expect(!PVHRunOutcome.instructionBudget.passed)
  }

  @Test func terminalInstructionAccountingIncludesTheFinalSlice() {
    #expect(PVHStopSnapshot.instructionCount(.instructionBudget(1000)) == 1000)
    #expect(PVHStopSnapshot.instructionCount(.poweredOff(instructionCount: 7)) == 7)
    #expect(PVHStopSnapshot.instructionCount(.halted(instructionCount: 5)) == 5)
    #expect(PVHStopSnapshot.instructionCount(.exception(
      .init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x100000), instructionCount: 3)) == 3)
  }

  @Test func faultEvidenceAndBuildIDComeFromTheActualImageAndStop() throws {
    let fault = PVHStopSnapshot(
      stop: .exception(.init(kind: .pageFault, vector: 14, errorCode: 2,
        instructionPointer: 0x100002, linearAddress: 0x300000), instructionCount: 3),
      totalInstructions: 1003, elapsedNanoseconds: 50, state: nil, nearestSymbol: nil)
    #expect(fault.fault?.linearAddress == 0x300000)
    #expect(fault.instructionCount == 3)
    #expect(fault.totalInstructions == 1003)
    var data = Data(repeating: 0, count: 0x204)
    func write(_ value: UInt64, _ offset: Int, _ count: Int) {
      for index in 0..<count { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    data.replaceSubrange(0..<7, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1])
    write(2, 16, 2); write(0x3E, 18, 2); write(1, 20, 4)
    write(64, 32, 8); write(64, 52, 2); write(56, 54, 2); write(2, 56, 2)
    write(1, 0x40, 4); write(5, 0x44, 4); write(0x200, 0x48, 8)
    write(0xFFFF_FFFF_8100_0000, 0x50, 8); write(0x100000, 0x58, 8)
    write(4, 0x60, 8); write(4, 0x68, 8)
    write(4, 0x78, 4); write(0x180, 0x80, 8); write(40, 0x98, 8)
    write(4, 0x180, 4); write(4, 0x184, 4); write(0x12, 0x188, 4)
    data.replaceSubrange(0x18C..<0x190, with: [0x58, 0x65, 0x6E, 0])
    write(0x100000, 0x190, 4)
    write(4, 0x194, 4); write(4, 0x198, 4); write(3, 0x19C, 4)
    data.replaceSubrange(0x1A0..<0x1A8, with: [0x47, 0x4E, 0x55, 0, 0xAA, 0xBB, 0xCC, 0xDD])
    let metadata = try PVHELFMetadata(validatedImage: .init(data: data))
    #expect(metadata.buildID == "aabbccdd")
    #expect(try metadata.symbolAddress(state: .init(
      rip: 0x100002, cs: .init(base: 0), control: .init(cr0: 0x11))) == 0xFFFF_FFFF_8100_0002)
  }

  @Test func symbolLookupIsBoundedOptionalAndNeverInventsAddressMasks() throws {
    let symbols = try PVHSymbolMap(data: Data("ffffffff81000000 T startup\nffffffff81000100 t second\nffffffff81000200 D data\n".utf8))
    #expect(symbols.nearest(to: 0x100000) == nil)
    #expect(symbols.nearest(to: 0xFFFF_FFFF_8100_0104)?.name == "second")
    #expect(symbols.nearest(to: 0xFFFF_FFFF_8100_0104)?.offset == 4)
    #expect(throws: PVHRunnerError.self) { _ = try PVHSymbolMap(data: Data("not a map at all".utf8)) }
    #expect(throws: PVHRunnerError.self) { _ = try PVHSymbolMap(data: Data("1000 D data\n".utf8)) }
  }

  private func arguments(replacing option: String? = nil, with replacement: String = "") -> [String] {
    var values = [
      "--kernel", "/kernel", "--kernel-sha256", String(repeating: "a", count: 64),
      "--initrd", "/initrd", "--initrd-sha256", String(repeating: "b", count: 64),
      "--command-line", "console=ttyS0 rdinit=/init", "--tier", "interpreter",
      "--memory-mib", "512", "--max-instructions", "10000", "--wall-seconds", "10",
      "--run-id", runID, "--workload", "exec-fork", "--workload", "file-io",
    ]
    if let option, let index = values.firstIndex(of: option) { values[index + 1] = replacement }
    return values
  }

  private func validLine() throws -> [UInt8] {
    try line(.init(schemaVersion: 1, doryPVHBoot: "userspace-ready", runID: runID, workloadsPassed: true, workloads: workloads))
  }

  private func line(_ receipt: PVHGuestReceipt) throws -> [UInt8] {
    Array(try JSONEncoder().encode(receipt)) + [10]
  }
}
