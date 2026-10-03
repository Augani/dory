import CryptoKit
import DoryDBTX86
import Foundation
import XCTest
@testable import DoryMachinePC

/// Physical-kernel acceptance is opt-in locally and mandatory in a fixture-provisioned gate.
/// The fixture's init process must publish the JSON receipt below, then power off through ACPI.
final class DoryPCLinuxBootTests: XCTestCase {
    func testPinnedLinuxReachesUserspaceAndPowersOff() throws {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["DORY_TEST_X86_PVH_KERNEL", "DORY_TEST_X86_PVH_KERNEL_SHA256",
                    "DORY_TEST_X86_PVH_INITRD", "DORY_TEST_X86_PVH_INITRD_SHA256"]
        let missing = keys.filter { environment[$0]?.isEmpty != false }
        if !missing.isEmpty {
            let detail = "Pinned x86 PVH boot inputs are missing: " + missing.joined(separator: ", ")
            if environment["DORY_REQUIRE_X86_PVH_BOOT"] == "1" {
                XCTFail(detail)
                return
            }
            throw XCTSkip(detail)
        }
        func artifact(pathKey: String, digestKey: String) throws -> Data {
            let path = try XCTUnwrap(environment[pathKey])
            let digest = try XCTUnwrap(environment[digestKey])
            guard path.hasPrefix("/"), digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw FixtureError.invalidArtifactIdentity(pathKey)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == digest else { throw FixtureError.digestMismatch(pathKey) }
            return data
        }
        let kernel = try artifact(pathKey: keys[0], digestKey: keys[1])
        let initrd = try artifact(pathKey: keys[2], digestKey: keys[3])
        let tier: DoryPCExecutionTier
        switch environment["DORY_TEST_X86_PVH_TIER"] ?? "baseline-jit" {
        case "interpreter": tier = .interpreter
        case "baseline-jit": tier = .baselineJIT
        default: throw FixtureError.invalidExecutionTier
        }
        let machine = try DoryPCDirectKernelMachine(
            memoryBytes: 1 << 30,
            executionTier: tier
        )
        let runID = UUID().uuidString.lowercased()
        try machine.load(
            kernel: kernel,
            initrd: Array(initrd),
            commandLine: "console=ttyS0 earlycon=uart,io,0x3f8,115200 panic=-1 rdinit=/init"
                + " dory.pvh_run_id=" + runID
        )
        let maximumInstructions: UInt64 = 120_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds + 120_000_000_000
        var executed: UInt64 = 0
        var serial: [UInt8] = []
        var capture = BootReceiptCapture(runID: runID)
        var stop: DoryPCMachineStop = .instructionBudget(0)
        while executed < maximumInstructions, DispatchTime.now().uptimeNanoseconds < deadline {
            let quantum = min(10_000, maximumInstructions - executed)
            stop = try machine.runOnDedicatedStack(maximumInstructions: quantum, exceptionPolicy: .deliver)
            let received = machine.serial.drainTransmittedBytes()
            serial += received
            capture.consume(received)
            // Bound retained diagnostics even when a guest floods its serial console.
            if serial.count > 65_536 { serial.removeFirst(serial.count - 65_536) }
            if case .instructionBudget(let count) = stop {
                executed += count
                continue
            }
            break
        }
        let diagnostic = "tier=\(tier), instructions=\(executed), stop=\(stop); console tail: "
            + String(decoding: serial.suffix(4_096), as: UTF8.self)
        XCTAssertEqual(capture.matchingReceiptCount, 1,
                       "Guest must publish one fresh, complete userspace/workload receipt; " + diagnostic)
        guard case .poweredOff = stop else {
            XCTFail("Guest did not power off cleanly; " + diagnostic)
            return
        }
    }

    func testBootReceiptRequiresExactRunAndAllSevenDistinctWorkloads() throws {
        let runID = "3e5f0470-52a4-4f44-8eab-d5a7c1927ce4"
        var capture = BootReceiptCapture(runID: runID)
        let expected = BootReceiptCapture.workloads
        for bytes in [
            try receiptLine(runID: UUID().uuidString.lowercased()),
            try receiptLine(runID: runID.uppercased()),
            try receiptLine(runID: runID, passed: false),
            try receiptLine(runID: runID, schemaVersion: 2),
            try receiptLine(runID: runID, workloads: Array(expected.dropLast())),
            try receiptLine(runID: runID, workloads: expected + ["shutdown.request"]),
            try receiptLine(runID: runID, workloads: Array(expected.dropLast()) + [expected[0]]),
            Array("{\"schemaVersion\":1,\"doryPVHBoot\":\"userspace-ready\",\"workloadsPassed\":true}\n".utf8),
        ] {
            capture.consume(bytes)
            XCTAssertEqual(capture.matchingReceiptCount, 0)
        }
        capture.consume(try receiptLine(runID: runID, workloads: Array(expected.reversed())))
        XCTAssertEqual(capture.matchingReceiptCount, 1)
        // A duplicate matching receipt is ambiguous, not another successful boot.
        capture.consume(try receiptLine(runID: runID))
        XCTAssertEqual(capture.matchingReceiptCount, 2)
    }

    func testBootReceiptRequiresWholeBoundedUnprefixedLine() throws {
        let runID = "3e5f0470-52a4-4f44-8eab-d5a7c1927ce4"
        let valid = try receiptLine(runID: runID)
        var capture = BootReceiptCapture(runID: runID)
        capture.consume(Array("boot command echoed: ".utf8) + valid)
        XCTAssertEqual(capture.matchingReceiptCount, 0)
        // Truncating a diagnostic tail must not remove an oversized line's prefix and turn its
        // valid JSON suffix into a receipt. Capture parses new bytes independently of that tail.
        capture.consume(Array(repeating: UInt8(ascii: "x"), count: 65_536))
        capture.consume(valid)
        XCTAssertEqual(capture.matchingReceiptCount, 0)
        capture.consume(Array(valid.dropLast()))
        XCTAssertEqual(capture.matchingReceiptCount, 0)
        capture.consume([13, 10])
        XCTAssertEqual(capture.matchingReceiptCount, 1)
    }

    private func receiptLine(
        runID: String,
        workloads: [String] = BootReceiptCapture.workloads,
        passed: Bool = true,
        schemaVersion: Int = 1
    ) throws -> [UInt8] {
        Array(try JSONEncoder().encode(BootReceipt(
            schemaVersion: schemaVersion, doryPVHBoot: "userspace-ready", runID: runID,
            workloadsPassed: passed, workloads: workloads))) + [10]
    }

    private struct BootReceipt: Codable {
        let schemaVersion: Int
        let doryPVHBoot: String
        let runID: String
        let workloadsPassed: Bool
        let workloads: [String]
    }

    private struct BootReceiptCapture {
        // Qualification/X86_64/Fixtures/p02-minimal-userspace/init emits these exact seven names.
        // shutdown.request is deliberately excluded: the host must independently observe S5.
        static let workloads = [
            "bootstrap.filesystems", "syscall.identity", "process.creation_exec_wait",
            "memory.allocation_copy", "signal.handler_return", "timer.sleep_elapsed",
            "filesystem.write_read_sync",
        ]
        let runID: String
        private(set) var matchingReceiptCount = 0
        private var line: [UInt8] = []
        private var discardingLine = false

        mutating func consume(_ bytes: [UInt8]) {
            for byte in bytes {
                if byte == 10 {
                    if !discardingLine {
                        if line.last == 13 { line.removeLast() }
                        if let receipt = try? JSONDecoder().decode(BootReceipt.self, from: Data(line)),
                           receipt.schemaVersion == 1, receipt.doryPVHBoot == "userspace-ready",
                           receipt.runID == runID, receipt.workloadsPassed,
                           receipt.workloads.count == Self.workloads.count,
                           receipt.workloads.sorted() == Self.workloads.sorted() {
                            matchingReceiptCount = min(2, matchingReceiptCount + 1)
                        }
                    }
                    line.removeAll(keepingCapacity: true)
                    discardingLine = false
                } else if !discardingLine {
                    if line.count < 4_096 {
                        line.append(byte)
                    } else {
                        line.removeAll(keepingCapacity: true)
                        discardingLine = true
                    }
                }
            }
        }
    }

    private enum FixtureError: Error {
        case invalidArtifactIdentity(String)
        case digestMismatch(String)
        case invalidExecutionTier
    }
}
