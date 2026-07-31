import Darwin
import DoryCore
import Foundation

/// Correlates doryd's SIGUSR2 request with a post-validation receipt from the current dory-hv.
/// A lock is required because standard signals coalesce and the protocol intentionally uses one
/// request/receipt path per engine state directory.
public final class PublishedPortRepairClient: @unchecked Sendable {
    enum RepairError: Error, CustomStringConvertible {
        case signalFailed(Int32, String)
        case helperChanged
        case timeout(TimeInterval)
        case invalidReceipt(String)
        case reconciliationFailed(String)

        var description: String {
            switch self {
            case let .signalFailed(pid, detail):
                return "could not signal dory-hv pid \(pid): \(detail)"
            case .helperChanged:
                return "dory-hv changed while port reconciliation was in progress"
            case let .timeout(seconds):
                return "dory-hv did not confirm gvproxy reconciliation within \(seconds)s"
            case let .invalidReceipt(detail):
                return "dory-hv returned an invalid gvproxy reconciliation receipt: \(detail)"
            case let .reconciliationFailed(detail):
                return detail
            }
        }
    }

    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let sendSignal: @Sendable (Int32) -> String?
    private let lock = NSLock()

    public convenience init(timeout: TimeInterval = 8, pollInterval: TimeInterval = 0.025) {
        self.init(timeout: timeout, pollInterval: pollInterval) { pid in
            kill(pid, SIGUSR2) == 0 ? nil : String(cString: strerror(errno))
        }
    }

    init(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        sendSignal: @escaping @Sendable (Int32) -> String?
    ) {
        self.timeout = max(0.05, timeout)
        self.pollInterval = max(0.001, pollInterval)
        self.sendSignal = sendSignal
    }

    func reconcile(
        stateDirectory: String,
        enginePID: Int32,
        helperIsCurrent: @escaping @Sendable () -> Bool
    ) throws -> PublishedPortReconcileReceipt {
        lock.lock()
        defer { lock.unlock() }

        guard helperIsCurrent() else { throw RepairError.helperChanged }
        let request = PublishedPortReconcileRequest(enginePID: enginePID)
        let directory = URL(fileURLWithPath: stateDirectory, isDirectory: true)
        let requestURL = directory.appendingPathComponent(PublishedPortReconcileProtocol.requestFilename)
        let receiptURL = directory.appendingPathComponent(PublishedPortReconcileProtocol.receiptFilename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(request).write(to: requestURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: requestURL.path
        )
        defer { removeRequest(requestID: request.requestID, at: requestURL) }

        if let signalError = sendSignal(enginePID) {
            throw RepairError.signalFailed(enginePID, signalError)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard helperIsCurrent() else { throw RepairError.helperChanged }
            if let receipt = readReceipt(at: receiptURL), receipt.requestID == request.requestID {
                guard receipt.isSupported else {
                    throw RepairError.invalidReceipt("unsupported schema or version")
                }
                guard receipt.enginePID == enginePID else {
                    throw RepairError.invalidReceipt(
                        "engine pid \(receipt.enginePID) does not match \(enginePID)"
                    )
                }
                guard receipt.startedAt >= request.requestedAt,
                      receipt.finishedAt >= receipt.startedAt else {
                    throw RepairError.invalidReceipt("completion timestamp predates its request")
                }
                guard helperIsCurrent() else { throw RepairError.helperChanged }
                guard receipt.succeeded else {
                    let mismatch = "missing \(receipt.missingForwardCount), unexpected \(receipt.unexpectedForwardCount)"
                    throw RepairError.reconciliationFailed(
                        receipt.error.map { "gvproxy reconciliation failed: \($0) (\(mismatch))" }
                            ?? "gvproxy reconciliation failed validation (\(mismatch))"
                    )
                }
                return receipt
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        throw RepairError.timeout(timeout)
    }

    private func readReceipt(at url: URL) -> PublishedPortReconcileReceipt? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return try? JSONDecoder().decode(PublishedPortReconcileReceipt.self, from: data)
    }

    private func removeRequest(requestID: String, at url: URL) {
        guard let data = try? Data(contentsOf: url),
              let current = try? JSONDecoder().decode(PublishedPortReconcileRequest.self, from: data),
              current.requestID == requestID else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }
}
