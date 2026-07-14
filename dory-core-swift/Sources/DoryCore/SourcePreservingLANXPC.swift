import Foundation

@objc public protocol DoryPrivilegedNetworkControl {
    func applySourcePreservingLAN(
        _ request: NSData,
        withReply reply: @escaping (NSData?, NSString?) -> Void
    )

    func reconcileAuthorizedNetworking(
        _ request: NSData,
        withReply reply: @escaping (Bool, NSString?) -> Void
    )
}

public enum DoryPrivilegedNetworkXPC {
    public static let serviceName = "dev.dory.network-helper"
    public static let teamID = "864H636QW4"
    private static let teamRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    public static let productionClientRequirement =
        "\(teamRequirement) and (identifier \"doryd\" or identifier \"dory-vmm\" or identifier \"dory-hv\")"
    public static let productionHelperRequirement =
        "\(teamRequirement) and identifier \"dory-network-helper\""
}

public enum SourcePreservingLANClientError: Error, Sendable, CustomStringConvertible {
    case timeout
    case remote(String)
    case invalidResponse

    public var description: String {
        switch self {
        case .timeout: "privileged networking helper timed out"
        case .remote(let message): "privileged networking helper: \(message)"
        case .invalidResponse: "privileged networking helper returned an invalid response"
        }
    }
}

public protocol SourcePreservingLANApplying: Sendable {
    func apply(_ request: SourcePreservingLANRequest) throws -> SourcePreservingLANResponse
}

public final class SourcePreservingLANPrivilegedClient: SourcePreservingLANApplying, @unchecked Sendable {
    private let timeout: TimeInterval
    private let connectionFactory: @Sendable () -> NSXPCConnection

    public init(
        timeout: TimeInterval = 15,
        connectionFactory: (@Sendable () -> NSXPCConnection)? = nil
    ) {
        self.timeout = timeout
        self.connectionFactory = connectionFactory ?? {
            NSXPCConnection(
                machServiceName: DoryPrivilegedNetworkXPC.serviceName,
                options: .privileged
            )
        }
    }

    public func apply(_ request: SourcePreservingLANRequest) throws -> SourcePreservingLANResponse {
        let connection = connectionFactory()
        connection.remoteObjectInterface = NSXPCInterface(with: DoryPrivilegedNetworkControl.self)
        connection.setCodeSigningRequirement(DoryPrivilegedNetworkXPC.productionHelperRequirement)
        connection.resume()
        defer { connection.invalidate() }

        let requestData = try JSONEncoder().encode(request) as NSData
        let completion = ReplyBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion.finish(data: nil, error: "\(error)")
        }) as? DoryPrivilegedNetworkControl else {
            throw SourcePreservingLANClientError.invalidResponse
        }
        proxy.applySourcePreservingLAN(requestData) { data, error in
            completion.finish(data: data as Data?, error: error as String?)
        }
        guard completion.wait(timeout: timeout) else {
            throw SourcePreservingLANClientError.timeout
        }
        if let error = completion.error {
            throw SourcePreservingLANClientError.remote(error)
        }
        guard let data = completion.data,
              let response = try? JSONDecoder().decode(SourcePreservingLANResponse.self, from: data) else {
            throw SourcePreservingLANClientError.invalidResponse
        }
        return response
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var finished = false
    private(set) var data: Data?
    private(set) var error: String?

    func finish(data: Data?, error: String?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        self.data = data
        self.error = error
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}
