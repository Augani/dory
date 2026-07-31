import DoryCore
@testable import DorydKit
import Foundation
import XCTest

final class PublishedPortRepairClientTests: XCTestCase {
    func testWaitsForMatchingFreshReceiptAndIgnoresStaleGeneration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptURL = directory.appendingPathComponent(PublishedPortReconcileProtocol.receiptFilename)
        try Self.writeReceipt(
            for: PublishedPortReconcileRequest(requestID: "stale", enginePID: 41),
            enginePID: 41,
            to: receiptURL
        )
        let client = PublishedPortRepairClient(timeout: 0.25, pollInterval: 0.002) { pid in
            do {
                let request = try Self.readRequest(in: directory)
                try Self.writeReceipt(for: request, enginePID: pid, to: receiptURL)
                return nil
            } catch {
                return "\(error)"
            }
        }

        let receipt = try client.reconcile(
            stateDirectory: directory.path,
            enginePID: 42,
            helperIsCurrent: { true }
        )

        XCTAssertNotEqual(receipt.requestID, "stale")
        XCTAssertEqual(receipt.enginePID, 42)
        XCTAssertTrue(receipt.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(PublishedPortReconcileProtocol.requestFilename).path
        ))
    }

    func testWrongRequestIDCannotSatisfyRepair() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptURL = directory.appendingPathComponent(PublishedPortReconcileProtocol.receiptFilename)
        let client = PublishedPortRepairClient(timeout: 0.06, pollInterval: 0.002) { pid in
            do {
                let request = PublishedPortReconcileRequest(requestID: "wrong", enginePID: pid)
                try Self.writeReceipt(for: request, enginePID: pid, to: receiptURL)
                return nil
            } catch {
                return "\(error)"
            }
        }

        XCTAssertThrowsError(try client.reconcile(
            stateDirectory: directory.path,
            enginePID: 51,
            helperIsCurrent: { true }
        )) { error in
            XCTAssertTrue("\(error)".contains("did not confirm"), "\(error)")
        }
    }

    func testMatchingReceiptFromWrongPIDFailsClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptURL = directory.appendingPathComponent(PublishedPortReconcileProtocol.receiptFilename)
        let client = PublishedPortRepairClient(timeout: 0.25, pollInterval: 0.002) { pid in
            do {
                let request = try Self.readRequest(in: directory)
                try Self.writeReceipt(for: request, enginePID: pid + 1, to: receiptURL)
                return nil
            } catch {
                return "\(error)"
            }
        }

        XCTAssertThrowsError(try client.reconcile(
            stateDirectory: directory.path,
            enginePID: 61,
            helperIsCurrent: { true }
        )) { error in
            XCTAssertTrue("\(error)".contains("does not match"), "\(error)")
        }
    }

    func testRegistryMismatchReceiptCannotReportSuccess() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptURL = directory.appendingPathComponent(PublishedPortReconcileProtocol.receiptFilename)
        let client = PublishedPortRepairClient(timeout: 0.25, pollInterval: 0.002) { pid in
            do {
                let request = try Self.readRequest(in: directory)
                try Self.writeReceipt(
                    for: request,
                    enginePID: pid,
                    missing: 1,
                    unexpected: 2,
                    error: "registry mismatch",
                    to: receiptURL
                )
                return nil
            } catch {
                return "\(error)"
            }
        }

        XCTAssertThrowsError(try client.reconcile(
            stateDirectory: directory.path,
            enginePID: 71,
            helperIsCurrent: { true }
        )) { error in
            XCTAssertTrue("\(error)".contains("missing 1, unexpected 2"), "\(error)")
        }
    }

    func testHelperGenerationChangeAbortsWait() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = LockedBool(true)
        let client = PublishedPortRepairClient(timeout: 0.25, pollInterval: 0.002) { _ in
            current.value = false
            return nil
        }

        XCTAssertThrowsError(try client.reconcile(
            stateDirectory: directory.path,
            enginePID: 81,
            helperIsCurrent: { current.value }
        )) { error in
            XCTAssertTrue("\(error)".contains("changed while"), "\(error)")
        }
    }

    func testConcurrentRepairsAreSerializedAcrossSingleSlotProtocol() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptURL = directory.appendingPathComponent(PublishedPortReconcileProtocol.receiptFilename)
        let counter = ConcurrentCounter()
        let client = PublishedPortRepairClient(timeout: 1, pollInterval: 0.002) { pid in
            counter.enter()
            defer { counter.leave() }
            do {
                let request = try Self.readRequest(in: directory)
                Thread.sleep(forTimeInterval: 0.03)
                try Self.writeReceipt(for: request, enginePID: pid, to: receiptURL)
                return nil
            } catch {
                return "\(error)"
            }
        }
        let results = ReceiptResults()
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    results.append(try client.reconcile(
                        stateDirectory: directory.path,
                        enginePID: 91,
                        helperIsCurrent: { true }
                    ))
                } catch {
                    results.append(error: "\(error)")
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(results.errors, [])
        XCTAssertEqual(results.receipts.count, 2)
        XCTAssertEqual(Set(results.receipts.map(\.requestID)).count, 2)
        XCTAssertEqual(counter.maximumActive, 1)
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-port-repair-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func readRequest(in directory: URL) throws -> PublishedPortReconcileRequest {
        let url = directory.appendingPathComponent(PublishedPortReconcileProtocol.requestFilename)
        return try JSONDecoder().decode(PublishedPortReconcileRequest.self, from: Data(contentsOf: url))
    }

    private static func writeReceipt(
        for request: PublishedPortReconcileRequest,
        enginePID: Int32,
        missing: Int = 0,
        unexpected: Int = 0,
        error: String? = nil,
        to url: URL
    ) throws {
        let startedAt = request.requestedAt.addingTimeInterval(0.001)
        let receipt = PublishedPortReconcileReceipt(
            requestID: request.requestID,
            enginePID: enginePID,
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(0.001),
            publishedPortCount: 1,
            desiredForwardCount: 2,
            observedForwardCount: 2 - missing + unexpected,
            addedForwardCount: 1,
            removedForwardCount: 1,
            missingForwardCount: missing,
            unexpectedForwardCount: unexpected,
            error: error
        )
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class ConcurrentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var maximumActive: Int { lock.withLock { maximum } }

    func enter() {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
        }
    }

    func leave() {
        lock.withLock { active -= 1 }
    }
}

private final class ReceiptResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReceipts: [PublishedPortReconcileReceipt] = []
    private var storedErrors: [String] = []

    var receipts: [PublishedPortReconcileReceipt] { lock.withLock { storedReceipts } }
    var errors: [String] { lock.withLock { storedErrors } }

    func append(_ receipt: PublishedPortReconcileReceipt) {
        lock.withLock { storedReceipts.append(receipt) }
    }

    func append(error: String) {
        lock.withLock { storedErrors.append(error) }
    }
}
