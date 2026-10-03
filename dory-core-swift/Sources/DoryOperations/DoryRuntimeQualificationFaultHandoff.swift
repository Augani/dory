import Darwin
import Foundation
import Security

/// Keeps the authenticated peer alive while LaunchServices transfers the reader to the helper.
/// Half-closing the writer supplies EOF without losing Darwin's peer audit-token authority.
public final class DoryRuntimeQualificationFaultChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: Int32?
    private let peer: Int32

    fileprivate init(reader: Int32, peer: Int32) { self.reader = reader; self.peer = peer }

    public func takeDescriptor() throws -> Int32 {
        try lock.withLock {
            guard let reader else { throw DoryRuntimeQualificationFaultError.unauthorized }
            self.reader = nil
            return reader
        }
    }

    deinit {
        if let reader { close(reader) }
        close(peer)
    }
}

/// A private inherited socket, not a pathname or a Codable authority. The helper authenticates
/// the creator's kernel audit token against the production daemon requirement before reading.
/// LaunchServices may parent the helper, so a parent-PID check would be incorrect here.
public enum DoryRuntimeQualificationFaultHandoff {
    public static let descriptorName = "qualificationFaultAuthority"
    public static let childDescriptor: Int32 = 21
    public static let descriptorArgument = "--qualification-fault-authority-fd"
    public static let productionDaemonRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"864H636QW4\" and identifier \"doryd\""
    static let maximumBytes = 8_192

    private struct Wire: Codable {
        let schemaVersion: UInt16
        let machineID: String
        let operationID: UUID
        let resolvedPlanSHA256: String
        let campaignManifestSHA256: String
        let expiresAt: Date
        let policy: DoryCandidateCampaignFaultPolicy
    }

    /// The channel retains its peer; the caller transfers the reader exactly once. Only an
    /// already verified opaque grant can supply its contents. Unsigned senders are rejected.
    public static func makeChannel(
        authority: DoryRuntimeQualificationFaultAuthority
    ) throws -> DoryRuntimeQualificationFaultChannel {
        let bytes = try encoder().encode(Wire(
            schemaVersion: 1, machineID: authority.machineID, operationID: authority.operationID,
            resolvedPlanSHA256: authority.resolvedPlanSHA256,
            campaignManifestSHA256: authority.campaignManifestSHA256,
            expiresAt: authority.expiresAt, policy: authority.policy
        ))
        guard bytes.count <= maximumBytes else { throw DoryRuntimeQualificationFaultError.unauthorized }
        let pair = try connectedChannel()
        var transferred = false
        defer {
            if !transferred { close(pair[0]); close(pair[1]) }
        }
        for fd in pair {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                throw DoryRuntimeQualificationFaultError.unauthorized
            }
        }
        var noSignal: Int32 = 1
        guard setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw DoryRuntimeQualificationFaultError.unauthorized
        }
        var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(pair[1], SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw DoryRuntimeQualificationFaultError.unauthorized
        }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            var interruptions = 0
            while offset < raw.count {
                let count = Darwin.write(pair[1], raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR && interruptions < 8 {
                    interruptions += 1
                    continue
                }
                guard count > 0 else { throw DoryRuntimeQualificationFaultError.unauthorized }
                offset += count
            }
        }
        guard shutdown(pair[1], SHUT_WR) == 0 else { throw DoryRuntimeQualificationFaultError.unauthorized }
        transferred = true
        return DoryRuntimeQualificationFaultChannel(reader: pair[0], peer: pair[1])
    }

    /// Anonymous connected endpoints avoid any pathname. The peer must remain alive until the
    /// recipient authenticates: closing it discards Darwin's LOCAL_PEERTOKEN observation.
    private static func connectedChannel() throws -> [Int32] {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw DoryRuntimeQualificationFaultError.unauthorized
        }
        return pair
    }

    /// Consumes and closes the fixed child slot. Ordinary launches never call this method.
    public static func receive(envelope: RuntimeLaunchEnvelope) throws -> DoryRuntimeQualificationFaultAuthority {
        try receive(descriptor: childDescriptor, envelope: envelope, authenticate: authenticateDaemon)
    }

    public static func receive(envelope: DoryPCRuntimeLaunchEnvelope) throws -> DoryRuntimeQualificationFaultAuthority {
        try receive(descriptor: childDescriptor, envelope: envelope, authenticate: authenticateDaemon)
    }

    // Internal injection seam exists only for deterministic transport tests, never public API.
    static func receive(
        descriptor: Int32, envelope: RuntimeLaunchEnvelope, now: Date = Date(),
        authenticate: (Int32) throws -> Void
    ) throws -> DoryRuntimeQualificationFaultAuthority {
        defer { close(descriptor) }
        switch envelope.boot {
        case .linuxDirect: _ = try envelope.validatedResolvedARMVirtResources()
        case .uefi: _ = try envelope.validatedResolvedARMVirtUEFIResources()
        }
        return try receiveContents(descriptor: descriptor, machineID: envelope.machineID,
            operationID: envelope.operationID, resolvedPlanSHA256: envelope.resolvedPlanSHA256,
            rendererOnly: false, now: now, authenticate: authenticate)
    }

    static func receive(
        descriptor: Int32, envelope: DoryPCRuntimeLaunchEnvelope, now: Date = Date(),
        authenticate: (Int32) throws -> Void
    ) throws -> DoryRuntimeQualificationFaultAuthority {
        defer { close(descriptor) }
        let resources = try envelope.validatedResources()
        guard envelope.graphics == .hardwareAccelerated3D, resources.rendererBootstrap != nil else {
            throw DoryRuntimeQualificationFaultError.unauthorized
        }
        return try receiveContents(descriptor: descriptor, machineID: envelope.machineID,
            operationID: envelope.operationID, resolvedPlanSHA256: envelope.resolvedPlanSHA256,
            rendererOnly: true, now: now, authenticate: authenticate)
    }

    /// Both architectures share the exact peer-token, canonical bytes and bounded-read checks.
    /// The enclosing receiver owns/always closes the descriptor, including launch validation failure.
    private static func receiveContents(
        descriptor: Int32, machineID: String, operationID: UUID, resolvedPlanSHA256: String,
        rendererOnly: Bool, now: Date, authenticate: (Int32) throws -> Void
    ) throws -> DoryRuntimeQualificationFaultAuthority {
        try authenticate(descriptor)
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw DoryRuntimeQualificationFaultError.unauthorized
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        var interruptions = 0
        while true {
            let current = DispatchTime.now().uptimeNanoseconds
            guard current < deadline else { throw DoryRuntimeQualificationFaultError.unauthorized }
            let remainingMilliseconds = Int32(max(1, (deadline - current + 999_999) / 1_000_000))
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, remainingMilliseconds)
            if ready < 0 && errno == EINTR && interruptions < 8 {
                interruptions += 1
                continue
            }
            guard ready > 0, event.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                throw DoryRuntimeQualificationFaultError.unauthorized
            }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR && interruptions < 8 {
                interruptions += 1
                continue
            }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard count >= 0 else { throw DoryRuntimeQualificationFaultError.unauthorized }
            if count == 0 { break }
            guard bytes.count + count <= maximumBytes else { throw DoryRuntimeQualificationFaultError.unauthorized }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let wire = try decoder.decode(Wire.self, from: bytes)
        guard try encoder().encode(wire) == bytes, wire.schemaVersion == 1,
              wire.machineID == machineID, wire.operationID == operationID,
              wire.resolvedPlanSHA256 == resolvedPlanSHA256,
              wire.campaignManifestSHA256.wholeMatch(of: /[0-9a-f]{64}/) != nil,
              wire.policy.isValid, !rendererOnly || wire.policy.isRendererCrashOnly else {
            throw DoryRuntimeQualificationFaultError.unauthorized
        }
        guard now < wire.expiresAt,
              wire.expiresAt.timeIntervalSince(now)
                <= DoryVirtualMachineCandidateCampaignAuthorityResolver.maximumLifetime else {
            throw DoryRuntimeQualificationFaultError.expired
        }
        return DoryRuntimeQualificationFaultAuthority(
            machineID: wire.machineID, operationID: wire.operationID,
            resolvedPlanSHA256: wire.resolvedPlanSHA256,
            campaignManifestSHA256: wire.campaignManifestSHA256,
            expiresAt: wire.expiresAt, policy: wire.policy
        )
    }

    /// Also used for the fault-control socket: same-UID alone is deliberately insufficient.
    public static func authenticateDaemon(descriptor: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size else {
            throw DoryRuntimeQualificationFaultError.unauthorized
        }
        let tokenBytes = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: tokenBytes] as CFDictionary
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(productionDaemonRequirement as CFString,
                                             SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess else {
            throw DoryRuntimeQualificationFaultError.unauthorized
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}
