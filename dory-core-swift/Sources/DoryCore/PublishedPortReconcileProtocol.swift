import Foundation

/// File-backed request/receipt protocol used by doryd to make SIGUSR2 port repair synchronous.
/// The random request ID is the generation token: an old receipt can never satisfy a new repair.
public enum PublishedPortReconcileProtocol {
    public static let schema = "dev.dory.gvproxy-port-reconcile"
    public static let version = 1
    public static let requestFilename = "gvproxy-port-reconcile-request.json"
    public static let receiptFilename = "gvproxy-port-reconcile-receipt.json"
}

public struct PublishedPortReconcileRequest: Codable, Sendable, Equatable {
    public var schema: String
    public var version: Int
    public var requestID: String
    public var enginePID: Int32
    public var requestedAt: Date

    public init(
        requestID: String = UUID().uuidString.lowercased(),
        enginePID: Int32,
        requestedAt: Date = Date()
    ) {
        self.schema = PublishedPortReconcileProtocol.schema
        self.version = PublishedPortReconcileProtocol.version
        self.requestID = requestID
        self.enginePID = enginePID
        self.requestedAt = requestedAt
    }

    public var isSupported: Bool {
        schema == PublishedPortReconcileProtocol.schema
            && version == PublishedPortReconcileProtocol.version
            && !requestID.isEmpty
            && enginePID > 0
    }
}

public struct PublishedPortReconcileReceipt: Codable, Sendable, Equatable {
    public var schema: String
    public var version: Int
    public var requestID: String
    public var enginePID: Int32
    public var startedAt: Date
    public var finishedAt: Date
    public var publishedPortCount: Int
    public var desiredForwardCount: Int
    public var observedForwardCount: Int
    public var addedForwardCount: Int
    public var removedForwardCount: Int
    public var missingForwardCount: Int
    public var unexpectedForwardCount: Int
    public var error: String?

    public init(
        requestID: String,
        enginePID: Int32,
        startedAt: Date,
        finishedAt: Date = Date(),
        publishedPortCount: Int,
        desiredForwardCount: Int,
        observedForwardCount: Int,
        addedForwardCount: Int,
        removedForwardCount: Int,
        missingForwardCount: Int,
        unexpectedForwardCount: Int,
        error: String? = nil
    ) {
        self.schema = PublishedPortReconcileProtocol.schema
        self.version = PublishedPortReconcileProtocol.version
        self.requestID = requestID
        self.enginePID = enginePID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.publishedPortCount = publishedPortCount
        self.desiredForwardCount = desiredForwardCount
        self.observedForwardCount = observedForwardCount
        self.addedForwardCount = addedForwardCount
        self.removedForwardCount = removedForwardCount
        self.missingForwardCount = missingForwardCount
        self.unexpectedForwardCount = unexpectedForwardCount
        self.error = error
    }

    public var isSupported: Bool {
        schema == PublishedPortReconcileProtocol.schema
            && version == PublishedPortReconcileProtocol.version
            && !requestID.isEmpty
            && enginePID > 0
    }

    public var succeeded: Bool {
        isSupported
            && error == nil
            && missingForwardCount == 0
            && unexpectedForwardCount == 0
    }
}
