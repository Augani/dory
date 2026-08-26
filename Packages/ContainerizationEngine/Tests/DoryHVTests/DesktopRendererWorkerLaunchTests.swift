import CryptoKit
import Darwin
import DoryOperations
import DoryRendererWorkerContracts
import DorydKit
import Foundation
import Testing
@testable import dory_hv

@Suite(.serialized)
struct DesktopRendererWorkerLaunchTests {
    @Test func exactAnonymousBootstrapReaderConsumesAndClosesDescriptor() throws {
        let bytes = DoryRendererWorkerBootstrapCodec.encode(
            try rendererLaunchBootstrap(workerGeneration: 17)
        )
        let fixture = try rendererLaunchBlob(bytes: bytes, unlinkBeforeRead: true)
        let fixtureIdentity = try rendererLaunchDescriptorIdentity(fixture.descriptor)
        let slot = rendererLaunchSlot(
            descriptor: fixture.descriptor,
            bytes: bytes
        )

        #expect(try DesktopRendererWorkerLaunch.readAndConsumeBootstrap(
            slot,
            requiredDescriptor: fixture.descriptor
        ) == bytes)
        #expect(rendererLaunchDescriptorNoLongerReferences(
            fixture.descriptor,
            identity: fixtureIdentity
        ))
    }

    @Test func exactBootstrapReaderRejectsDigestTamperAndLinkedObject() throws {
        let bytes = DoryRendererWorkerBootstrapCodec.encode(
            try rendererLaunchBootstrap(workerGeneration: 18)
        )
        let tampered = try rendererLaunchBlob(bytes: bytes, unlinkBeforeRead: true)
        let tamperedIdentity = try rendererLaunchDescriptorIdentity(tampered.descriptor)
        let tamperedSlot = RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
            name: RuntimeLaunchEnvelope.rendererBootstrapSlotName,
            descriptor: tampered.descriptor,
            access: .readOnly,
            byteCount: UInt64(bytes.count),
            contentSHA256: String(repeating: "f", count: 64)
        )
        #expect(throws: DesktopRendererWorkerLaunchError.bootstrapDigestMismatch) {
            _ = try DesktopRendererWorkerLaunch.readAndConsumeBootstrap(
                tamperedSlot,
                requiredDescriptor: tampered.descriptor
            )
        }
        #expect(rendererLaunchDescriptorNoLongerReferences(
            tampered.descriptor,
            identity: tamperedIdentity
        ))

        let linked = try rendererLaunchBlob(bytes: bytes, unlinkBeforeRead: false)
        defer { _ = unlink(linked.path) }
        let linkedIdentity = try rendererLaunchDescriptorIdentity(linked.descriptor)
        #expect(throws: DesktopRendererWorkerLaunchError.invalidBootstrapObject) {
            _ = try DesktopRendererWorkerLaunch.readAndConsumeBootstrap(
                rendererLaunchSlot(descriptor: linked.descriptor, bytes: bytes),
                requiredDescriptor: linked.descriptor
            )
        }
        #expect(rendererLaunchDescriptorNoLongerReferences(
            linked.descriptor,
            identity: linkedIdentity
        ))
    }

    @Test func nonHardwareGraphicsNeverInvokesWorkerConnector() async throws {
        for graphics in [
            DoryGraphicsAccelerationLevel.software,
            .hostAcceleratedDisplay,
            .none,
        ] {
            let calls = RendererLaunchConnectorCalls()
            let launch = try await DesktopRendererWorkerLaunch.prepare(
                resolvedGraphics: graphics,
                rendererBootstrapAuthority: nil,
                exactManagedKernelSHA256: nil,
                connector: { _ in
                    calls.record()
                    throw RendererLaunchTestError.connectorMustNotRun
                }
            )
            #expect(launch == nil)
            #expect(calls.count == 0)
        }
    }

    @Test func hardwareGraphicsRequiresFixedBootstrapAuthorityBeforeConnect() async {
        let calls = RendererLaunchConnectorCalls()
        await #expect(throws: DesktopRendererWorkerLaunchError.missingBootstrapAuthority) {
            _ = try await DesktopRendererWorkerLaunch.prepare(
                resolvedGraphics: .hardwareAccelerated3D,
                rendererBootstrapAuthority: nil,
                exactManagedKernelSHA256: nil,
                connector: { _ in
                    calls.record()
                    throw RendererLaunchTestError.connectorMustNotRun
                }
            )
        }
        #expect(calls.count == 0)
    }

    @Test func nonHardwareGraphicsRejectsEvenAnUnexpectedSlotWithoutConnect() async {
        let calls = RendererLaunchConnectorCalls()
        let unexpected = RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
            name: RuntimeLaunchEnvelope.rendererBootstrapSlotName,
            descriptor: -1,
            access: .readOnly,
            byteCount: UInt64(DoryRendererWorkerBootstrapCodec.fixedByteCount),
            contentSHA256: String(repeating: "a", count: 64)
        )
        await #expect(throws: DesktopRendererWorkerLaunchError.unexpectedBootstrapAuthority) {
            _ = try await DesktopRendererWorkerLaunch.prepare(
                resolvedGraphics: .software,
                rendererBootstrapAuthority: unexpected,
                exactManagedKernelSHA256: nil,
                connector: { _ in
                    calls.record()
                    throw RendererLaunchTestError.connectorMustNotRun
                }
            )
        }
        #expect(calls.count == 0)
    }

    @Test func qualifiedFenceAuthorityDigestIsDeterministicAndDomainSeparated() throws {
        let bootstrap = try rendererLaunchBootstrap(workerGeneration: 7)
        let successor = try rendererLaunchBootstrap(workerGeneration: 8)
        let first = DesktopRendererWorkerLaunch
            .qualifiedProducerFenceAuthoritySHA256(for: bootstrap)
        let repeated = DesktopRendererWorkerLaunch
            .qualifiedProducerFenceAuthoritySHA256(for: bootstrap)
        let successorDigest = DesktopRendererWorkerLaunch
            .qualifiedProducerFenceAuthoritySHA256(for: successor)

        #expect(first.count == 64)
        #expect(first == repeated)
        // Worker generation is intentionally not part of durable guest-fence authority. A
        // process restart must not manufacture a different kernel/contract qualification proof.
        #expect(first == successorDigest)
        #expect(first != rendererLaunchHex(bootstrap.artifacts.managedGuestKernel.bytes))
    }

    @Test func liveQualificationRequiresExactRealDualCapsetFacts() throws {
        let bootstrap = try rendererLaunchBootstrap(workerGeneration: 29)
        let receipt = try rendererLaunchCapabilityReceipt(
            accepting: bootstrap,
            virgl2: Data("virgl2-real-capset".utf8)
        )
        let now = Date()
        let candidate = try DoryVerifiedRendererBootstrapQualification
            .makeCandidateReceipt(
                bootstrap: bootstrap,
                liveReceipt: receipt,
                issuedAt: now.addingTimeInterval(-60),
                expiresAt: now.addingTimeInterval(24 * 60 * 60)
            )
        let qualification = try DoryVerifiedRendererBootstrapQualification
            .decodeDeveloperIDSignedCandidateForTesting(receiptData: candidate, now: now)
        try DesktopRendererWorkerLaunch.verifyLiveQualification(
            bootstrap: bootstrap,
            receipt: receipt,
            qualification: qualification
        )

        let drifted = try rendererLaunchCapabilityReceipt(
            accepting: bootstrap,
            virgl2: Data("virgl2-drifted-capset".utf8)
        )
        #expect(throws: DesktopRendererWorkerLaunchError.bootstrapQualificationMismatch) {
            try DesktopRendererWorkerLaunch.verifyLiveQualification(
                bootstrap: bootstrap,
                receipt: drifted,
                qualification: qualification
            )
        }
    }

    @Test func liveReadinessAcceptsOnlyExactWorkerGeneration() throws {
        let accepted = DesktopRendererWorkerLiveReadinessGate(expectedWorkerGeneration: 41)
        accepted.record(workerGeneration: 41)
        try accepted.wait(timeout: 0)

        let drifted = DesktopRendererWorkerLiveReadinessGate(expectedWorkerGeneration: 41)
        drifted.record(workerGeneration: 42)
        #expect(throws: DesktopRendererWorkerLaunchError.synchronizedPresentationFailed(
            "worker generation drift (expected 41, got 42)"
        )) {
            try drifted.wait(timeout: 0)
        }
    }

    @Test func liveReadinessTimeoutAndFailureAreTerminal() {
        let timedOut = DesktopRendererWorkerLiveReadinessGate(expectedWorkerGeneration: 9)
        #expect(throws: DesktopRendererWorkerLaunchError.synchronizedPresentationTimedOut) {
            try timedOut.wait(timeout: 0)
        }
        timedOut.record(workerGeneration: 9)
        #expect(throws: DesktopRendererWorkerLaunchError.synchronizedPresentationFailed(
            "presentation deadline expired"
        )) {
            try timedOut.wait(timeout: 0)
        }

        let failed = DesktopRendererWorkerLiveReadinessGate(expectedWorkerGeneration: 9)
        failed.fail("worker interrupted")
        failed.record(workerGeneration: 9)
        #expect(throws: DesktopRendererWorkerLaunchError.synchronizedPresentationFailed(
            "worker interrupted"
        )) {
            try failed.wait(timeout: 0)
        }
    }

    @Test func handoffClaimLinearizesAgainstWorkerFailure() throws {
        let failureWon = DesktopRendererWorkerLiveReadinessGate(
            expectedWorkerGeneration: 15
        )
        failureWon.record(workerGeneration: 15)
        failureWon.fail("worker interrupted before handoff")
        #expect(throws: DesktopRendererWorkerLaunchError.synchronizedPresentationFailed(
            "worker interrupted before handoff"
        )) {
            try failureWon.claimForPublication()
        }

        let publicationWon = DesktopRendererWorkerLiveReadinessGate(
            expectedWorkerGeneration: 15
        )
        publicationWon.record(workerGeneration: 15)
        try publicationWon.claimForPublication()
        publicationWon.fail("worker interrupted after handoff boundary")
        try publicationWon.claimForPublication()
    }
}

private enum RendererLaunchTestError: Error {
    case connectorMustNotRun
    case fixtureCreationFailed
}

private final class RendererLaunchConnectorCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int { lock.withLock { recordedCount } }

    func record() {
        lock.withLock { recordedCount += 1 }
    }
}

private func rendererLaunchBootstrap(
    workerGeneration: UInt64
) throws -> DoryRendererWorkerBootstrap {
    try DoryRendererWorkerBootstrap(
        workspaceID: DoryRendererWorkspaceID(
            rawValue: #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        ),
        generation: DoryRendererWorkerGeneration(rawValue: workerGeneration),
        sourceTuple: .productionCandidate,
        producerFenceContract: .managedLinux61230PrepareFBV1,
        requestedCapabilities: .productionAcceleration,
        artifacts: DoryRendererArtifactManifest(
            candidateInventory: try rendererLaunchDigest(1),
            managedGuestKernel: try rendererLaunchDigest(2),
            guestMesa: try DoryRendererArtifactDigest(
                lowercaseSHA256: DoryRendererSourceTuple.guestMesaRuntimeSHA256
            ),
            rendererWorkerExecutable: try rendererLaunchDigest(4),
            rendererWorkerCodeDirectoryHash: try DoryCodeDirectoryHash(
                bytes: Data(repeating: 5, count: DoryCodeDirectoryHash.byteCount)
            )
        )
    )
}

private func rendererLaunchCapabilityReceipt(
    accepting bootstrap: DoryRendererWorkerBootstrap,
    virgl2: Data
) throws -> DoryRendererCapabilityReceipt {
    try DoryRendererCapabilityReceipt(
        accepting: bootstrap,
        features: .productionAcceleration,
        capsets: [
            try DoryRendererCapsetAttestation(
                id: 2,
                maximumVersion: 2,
                data: virgl2
            ),
            try DoryRendererCapsetAttestation(
                id: 4,
                maximumVersion: 0,
                data: Data("venus-real-capset".utf8)
            ),
        ]
    )
}

private func rendererLaunchDigest(_ value: UInt8) throws -> DoryRendererArtifactDigest {
    try DoryRendererArtifactDigest(bytes: Data(repeating: value, count: 32))
}

private func rendererLaunchHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func rendererLaunchSlot(
    descriptor: Int32,
    bytes: Data
) -> RuntimeLaunchEnvelope.InheritedFileDescriptorSlot {
    RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
        name: RuntimeLaunchEnvelope.rendererBootstrapSlotName,
        descriptor: descriptor,
        access: .readOnly,
        byteCount: UInt64(bytes.count),
        contentSHA256: SHA256.hash(data: bytes).map {
            String(format: "%02x", $0)
        }.joined()
    )
}

private func rendererLaunchBlob(
    bytes: Data,
    unlinkBeforeRead: Bool
) throws -> (descriptor: Int32, path: String) {
    var template = Array("/tmp/dory-renderer-launch-test.XXXXXX".utf8CString)
    let writer = template.withUnsafeMutableBufferPointer { buffer in
        mkstemp(buffer.baseAddress!)
    }
    guard writer >= 0 else { throw RendererLaunchTestError.fixtureCreationFailed }
    let path = template.withUnsafeBufferPointer {
        String(cString: $0.baseAddress!)
    }
    var writerIsOpen = true
    defer {
        if writerIsOpen { close(writer) }
        if unlinkBeforeRead { _ = unlink(path) }
    }
    guard fchmod(writer, 0o600) == 0 else {
        throw RendererLaunchTestError.fixtureCreationFailed
    }
    try bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else {
            throw RendererLaunchTestError.fixtureCreationFailed
        }
        var offset = 0
        while offset < raw.count {
            let result = write(writer, base.advanced(by: offset), raw.count - offset)
            if result > 0 {
                offset += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw RendererLaunchTestError.fixtureCreationFailed
            }
        }
    }
    guard fsync(writer) == 0 else {
        throw RendererLaunchTestError.fixtureCreationFailed
    }
    let reader = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard reader >= 0 else { throw RendererLaunchTestError.fixtureCreationFailed }
    if unlinkBeforeRead, unlink(path) != 0 {
        close(reader)
        throw RendererLaunchTestError.fixtureCreationFailed
    }
    close(writer)
    writerIsOpen = false
    return (reader, path)
}

private func rendererLaunchDescriptorIdentity(_ descriptor: Int32) throws -> stat {
    var identity = stat()
    guard fstat(descriptor, &identity) == 0 else {
        throw RendererLaunchTestError.fixtureCreationFailed
    }
    return identity
}

/// A descriptor number is process-global and may be reused immediately by another concurrently
/// running suite. Prove capability consumption against the original kernel object identity instead
/// of assuming the numeric slot must remain EBADF after close.
private func rendererLaunchDescriptorNoLongerReferences(
    _ descriptor: Int32,
    identity: stat
) -> Bool {
    var current = stat()
    guard fstat(descriptor, &current) == 0 else {
        return errno == EBADF
    }
    return current.st_dev != identity.st_dev || current.st_ino != identity.st_ino
}
