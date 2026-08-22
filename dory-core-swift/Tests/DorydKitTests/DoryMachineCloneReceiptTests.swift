import Foundation
import Testing
@testable import DorydKit

@Suite("Machine clone receipt")
struct DoryMachineCloneReceiptTests {
    @Test("receipt round trips exact APFS clone evidence")
    func roundTrip() throws {
        let receipt = DoryMachineCloneReceipt(
            sourceMachineID: "desktop",
            sourceSnapshotID: "before-upgrade",
            sourceRootfsSHA256: String(repeating: "a", count: 64),
            sourceRootfsByteCount: 8 * 1_024 * 1_024 * 1_024,
            createdAtUnixMilliseconds: 1_787_300_000_000
        )
        #expect(receipt.isValid)
        let data = try JSONEncoder().encode(receipt)
        #expect(try JSONDecoder().decode(DoryMachineCloneReceipt.self, from: data) == receipt)
    }

    @Test("receipt rejects unbounded or fabricated authority")
    func invalidShapes() {
        let valid = DoryMachineCloneReceipt(
            sourceMachineID: "desktop",
            sourceSnapshotID: "base",
            sourceRootfsSHA256: String(repeating: "b", count: 64),
            sourceRootfsByteCount: 4_096,
            createdAtUnixMilliseconds: 1
        )
        var receipt = valid
        receipt.schemaVersion = 2
        #expect(!receipt.isValid)
        receipt = valid
        receipt.sourceMachineID = "../desktop"
        #expect(!receipt.isValid)
        receipt = valid
        receipt.sourceRootfsSHA256 = String(repeating: "A", count: 64)
        #expect(!receipt.isValid)
        receipt = valid
        receipt.sourceRootfsByteCount = 0
        #expect(!receipt.isValid)
        receipt = valid
        receipt.createdAtUnixMilliseconds = 0
        #expect(!receipt.isValid)
    }
}
