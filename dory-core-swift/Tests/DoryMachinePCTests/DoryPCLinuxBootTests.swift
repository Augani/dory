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
        try machine.load(
            kernel: kernel,
            initrd: Array(initrd),
            commandLine: "console=ttyS0 earlycon=uart,io,0x3f8,115200 panic=-1 rdinit=/init"
        )
        let maximumInstructions: UInt64 = 120_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds + 120_000_000_000
        var executed: UInt64 = 0
        var serial: [UInt8] = []
        var receiptSeen = false
        var stop: DoryPCMachineStop = .instructionBudget(0)
        while executed < maximumInstructions, DispatchTime.now().uptimeNanoseconds < deadline {
            let quantum = min(10_000, maximumInstructions - executed)
            stop = try machine.runOnDedicatedStack(maximumInstructions: quantum, exceptionPolicy: .deliver)
            serial += machine.serial.drainTransmittedBytes()
            // Bound retained diagnostics even when a guest floods its serial console.
            if serial.count > 65_536 { serial.removeFirst(serial.count - 65_536) }
            let console = String(decoding: serial, as: UTF8.self)
            receiptSeen = receiptSeen || console.split(separator: "\n").contains { line in
                guard let data = String(line).data(using: .utf8),
                      let receipt = try? JSONDecoder().decode(BootReceipt.self, from: data) else {
                    return false
                }
                return receipt.schemaVersion == 1 && receipt.doryPVHBoot == "userspace-ready"
                    && receipt.workloadsPassed
            }
            if case .instructionBudget(let count) = stop {
                executed += count
                continue
            }
            break
        }
        let diagnostic = "tier=\(tier), instructions=\(executed), stop=\(stop); console tail: "
            + String(decoding: serial.suffix(4_096), as: UTF8.self)
        XCTAssertTrue(receiptSeen, "Guest did not publish its userspace/workload receipt; " + diagnostic)
        guard case .poweredOff = stop else {
            XCTFail("Guest did not power off cleanly; " + diagnostic)
            return
        }
    }

    private struct BootReceipt: Decodable {
        let schemaVersion: Int
        let doryPVHBoot: String
        let workloadsPassed: Bool
    }

    private enum FixtureError: Error {
        case invalidArtifactIdentity(String)
        case digestMismatch(String)
        case invalidExecutionTier
    }
}
