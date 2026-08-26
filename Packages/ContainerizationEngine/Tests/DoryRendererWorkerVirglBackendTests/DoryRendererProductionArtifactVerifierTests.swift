import CryptoKit
import Darwin
import DoryRendererWorkerContracts
import DoryRendererWorkerVirglBackend
import Foundation
import Testing

@Suite struct DoryRendererProductionArtifactVerifierTests {
    @Test func definitionPinIsCanonicalLowercaseSHA256() {
        let pin = DoryRendererSourceTuple.productionDefinitionSHA256
        #expect(pin.utf8.count == 64)
        #expect(pin.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        })
    }

    @Test func exactBootstrapAndFinalWorkerBytesProducePathFreeAttestation() throws {
        let fixture = try RendererArtifactFixture()
        let attestation = try fixture.verifier.verify(bootstrap: fixture.bootstrap)

        #expect(attestation.candidateInventory
            == fixture.bootstrap.artifacts.candidateInventory)
        #expect(attestation.rendererWorkerExecutable
            == fixture.bootstrap.artifacts.rendererWorkerExecutable)
    }

    @Test func finalWorkerByteTamperingIsRejected() throws {
        let fixture = try RendererArtifactFixture()
        try Data("tampered".utf8).write(to: fixture.workerURL)

        #expect(throws: DoryRendererProductionArtifactError.executableDigestMismatch) {
            _ = try fixture.verifier.verify(bootstrap: fixture.bootstrap)
        }
    }

    @Test func symlinkedFinalWorkerIsRejectedEvenWhenTargetBytesMatch() throws {
        let fixture = try RendererArtifactFixture()
        let relocated = fixture.workerURL.deletingLastPathComponent()
            .appendingPathComponent("RelocatedRendererWorker")
        try FileManager.default.moveItem(at: fixture.workerURL, to: relocated)
        try FileManager.default.createSymbolicLink(
            at: fixture.workerURL,
            withDestinationURL: relocated
        )

        #expect(throws: DoryRendererProductionArtifactError.artifactUnavailable(
            "renderer worker executable"
        )) {
            _ = try fixture.verifier.verify(bootstrap: fixture.bootstrap)
        }
    }

    @Test func hardLinkedFinalWorkerIsRejectedEvenWhenBytesMatch() throws {
        let fixture = try RendererArtifactFixture()
        let secondName = fixture.workerURL.deletingLastPathComponent()
            .appendingPathComponent("SecondRendererWorkerLink")
        #expect(link(fixture.workerURL.path, secondName.path) == 0)

        #expect(throws: DoryRendererProductionArtifactError.artifactUnavailable(
            "renderer worker executable"
        )) {
            _ = try fixture.verifier.verify(bootstrap: fixture.bootstrap)
        }
    }

    @Test func groupWritableFinalWorkerIsRejectedEvenWhenBytesMatch() throws {
        let fixture = try RendererArtifactFixture()
        #expect(chmod(
            fixture.workerURL.path,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP
        ) == 0)

        #expect(throws: DoryRendererProductionArtifactError.artifactUnavailable(
            "renderer worker executable"
        )) {
            _ = try fixture.verifier.verify(bootstrap: fixture.bootstrap)
        }
    }

    @Test func verifierCannotRedirectAuthorityToAnotherBundleFile() throws {
        let fixture = try RendererArtifactFixture()
        let verifier = try DoryRendererProductionArtifactVerifier(
            contentsRoot: fixture.contentsRoot,
            executableRelativePath: "XPCServices/Other.xpc/Contents/MacOS/Other"
        )

        #expect(throws: DoryRendererProductionArtifactError.invalidBundleLayout) {
            _ = try verifier.verify(bootstrap: fixture.bootstrap)
        }
    }

    /// Release-pipeline hook for checking a newly signed runner with the exact Swift verifier used
    /// by the worker. Ordinary test runs leave the environment unset and do not touch host apps.
    @Test func signedRunnerFromEnvironmentUsesRuntimeVerifier() throws {
        guard let appPath = ProcessInfo.processInfo.environment["DORY_SIGNED_RUNNER_APP"] else {
            return
        }
        let runnerContents = URL(fileURLWithPath: appPath, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        let contentsRoot = runnerContents
            .appendingPathComponent("XPCServices/DoryRendererWorker.xpc/Contents", isDirectory: true)
        let inventoryBytes = try Data(contentsOf: runnerContents.appendingPathComponent(
            DoryRendererProductionInventory.relativePath
        ))
        let workerBytes = try Data(contentsOf: contentsRoot.appendingPathComponent(
            DoryRendererProductionArtifactVerifier.workerBundleExecutableRelativePath
        ))
        let bootstrap = try DoryRendererWorkerBootstrap(
            workspaceID: .random(),
            generation: DoryRendererWorkerGeneration(rawValue: 1),
            sourceTuple: .productionCandidate,
            producerFenceContract: .managedLinux61230PrepareFBV1,
            requestedCapabilities: .productionAcceleration,
            artifacts: DoryRendererArtifactManifest(
                candidateInventory: try Self.artifactDigest(inventoryBytes),
                managedGuestKernel: try Self.artifactDigest(Data("kernel".utf8)),
                guestMesa: try Self.artifactDigest(Data("guest-mesa".utf8)),
                rendererWorkerExecutable: try Self.artifactDigest(workerBytes),
                rendererWorkerCodeDirectoryHash: try DoryCodeDirectoryHash(
                    bytes: Data(repeating: 0x5a, count: DoryCodeDirectoryHash.byteCount)
                )
            )
        )
        let verifier = try DoryRendererProductionArtifactVerifier(
            contentsRoot: contentsRoot,
            executableRelativePath:
                DoryRendererProductionArtifactVerifier.workerBundleExecutableRelativePath
        )

        _ = try verifier.verify(bootstrap: bootstrap)
    }

    private static func artifactDigest(_ data: Data) throws -> DoryRendererArtifactDigest {
        try DoryRendererArtifactDigest(bytes: Data(SHA256.hash(data: data)))
    }
}

private final class RendererArtifactFixture {
    let contentsRoot: URL
    let workerURL: URL
    let verifier: DoryRendererProductionArtifactVerifier
    let bootstrap: DoryRendererWorkerBootstrap

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-renderer-artifact-tests-\(UUID().uuidString)")
            .appendingPathComponent("DoryRendererWorker.xpc/Contents")
        contentsRoot = root

        let workerRelativePath =
            DoryRendererProductionArtifactVerifier.workerBundleExecutableRelativePath
        let workerBytes = Data("signed-static-renderer-worker-fixture".utf8)
        try Self.write(workerBytes, relativePath: workerRelativePath, below: root)
        workerURL = root.appendingPathComponent(workerRelativePath)

        let manifest = DoryRendererArtifactManifest(
            candidateInventory: try Self.artifactDigest(
                Data("candidate-inventory".utf8),
                field: "inventory"
            ),
            managedGuestKernel: try Self.artifactDigest(Data("kernel".utf8), field: "kernel"),
            guestMesa: try Self.artifactDigest(Data("guest-mesa".utf8), field: "guestMesa"),
            rendererWorkerExecutable: try Self.artifactDigest(workerBytes, field: "worker"),
            rendererWorkerCodeDirectoryHash: try DoryCodeDirectoryHash(
                bytes: Data(repeating: 0x5a, count: DoryCodeDirectoryHash.byteCount)
            )
        )
        bootstrap = try DoryRendererWorkerBootstrap(
            workspaceID: .random(),
            generation: DoryRendererWorkerGeneration(rawValue: 1),
            sourceTuple: .productionCandidate,
            producerFenceContract: .managedLinux61230PrepareFBV1,
            requestedCapabilities: .productionAcceleration,
            artifacts: manifest
        )
        verifier = try DoryRendererProductionArtifactVerifier(
            contentsRoot: root,
            executableRelativePath: workerRelativePath
        )
    }

    deinit {
        try? FileManager.default.removeItem(
            at: contentsRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        )
    }

    private static func write(
        _ data: Data,
        relativePath: String,
        below root: URL
    ) throws {
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .withoutOverwriting)
    }

    private static func artifactDigest(
        _ data: Data,
        field: String
    ) throws -> DoryRendererArtifactDigest {
        try DoryRendererArtifactDigest(bytes: digest(data), field: field)
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

}
