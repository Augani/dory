@testable import DoryOperations
import Darwin
import Foundation
import XCTest

final class DoryVirtualMachineArtifactAuthorityTests: XCTestCase {
    func testImmutableArtifactIsContentAddressedAndRevalidated() throws {
        try withFixture("immutable") { fixture in
            let artifact = try fixture.file("installer.iso", data: Data("efi-image".utf8))
            let published = try fixture.authority.publishImmutable(
                reference: fixture.reference,
                path: artifact,
                kind: .installerISO,
                source: .userProvided
            )
            XCTAssertEqual(published.authorityRevision, 1)
            XCTAssertNotNil(published.media.artifactSHA256)
            XCTAssertEqual(
                try fixture.authority.resolve(
                    reference: fixture.reference,
                    kind: .installerISO,
                    source: .userProvided
                ).media,
                published.media
            )

            try Data("changed-image".utf8).write(to: URL(fileURLWithPath: artifact))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: artifact
            )
            XCTAssertThrowsError(try fixture.authority.resolve(
                reference: fixture.reference,
                kind: .installerISO,
                source: .userProvided
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineArtifactAuthorityError,
                    .artifactChanged
                )
            }
        }
    }

    func testReadOnlyVirtualDiskCanBePublishedAsImmutable() throws {
        try withFixture("immutable-read-only-disk") { fixture in
            let disk = try fixture.file(
                "tools.raw",
                data: Data(repeating: 0x5a, count: 4_096)
            )
            let published = try fixture.authority.publishImmutable(
                reference: fixture.reference,
                path: disk,
                kind: .virtualDisk,
                source: .bundledByDory
            )

            XCTAssertEqual(published.media.kind, .virtualDisk)
            XCTAssertNotNil(published.media.artifactSHA256)
            XCTAssertNil(published.media.mutableProvenance)
            XCTAssertEqual(
                try fixture.authority.resolve(
                    reference: fixture.reference,
                    kind: .virtualDisk,
                    source: .bundledByDory
                ).media,
                published.media
            )
        }
    }

    func testMutableArtifactRequiresExplicitRevisionPublication() throws {
        try withFixture("mutable") { fixture in
            let disk = try fixture.file("system.raw", data: Data(repeating: 0, count: 4_096))
            let first = try fixture.authority.publishMutable(
                reference: fixture.reference,
                path: disk,
                source: .userProvided
            )
            XCTAssertEqual(first.media.mutableProvenance?.revision, 1)
            XCTAssertNotNil(first.mutableProvenance)

            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: disk))
            try handle.seek(toOffset: 10)
            try handle.write(contentsOf: Data([1]))
            try handle.synchronize()
            try handle.close()
            XCTAssertThrowsError(try fixture.authority.resolve(
                reference: fixture.reference,
                kind: .virtualDisk,
                source: .userProvided
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineArtifactAuthorityError,
                    .artifactChanged
                )
            }

            let second = try fixture.authority.publishMutable(
                reference: fixture.reference,
                path: disk,
                source: .userProvided,
                expectedAuthorityRevision: 1
            )
            XCTAssertEqual(second.media.mutableProvenance?.revision, 2)
            XCTAssertEqual(
                try fixture.authority.resolve(
                    reference: fixture.reference,
                    kind: .virtualDisk,
                    source: .userProvided
                ).authorityRevision,
                2
            )
        }
    }

    func testMutableArtifactIdentityRejectsSameSizeMutationWithRestoredMtime() throws {
        try withFixture("mutable-adversarial") { fixture in
            let disk = try fixture.file(
                "system.raw",
                data: Data(repeating: 0x41, count: 4_096)
            )
            _ = try fixture.authority.publishMutable(
                reference: fixture.reference,
                path: disk,
                source: .userProvided
            )

            var publishedStatus = stat()
            XCTAssertEqual(lstat(disk, &publishedStatus), 0)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: disk))
            try handle.seek(toOffset: 2_048)
            try handle.write(contentsOf: Data([0x42]))
            try handle.synchronize()
            try handle.close()
            let timestamps = [publishedStatus.st_atimespec, publishedStatus.st_mtimespec]
            let restoreResult = timestamps.withUnsafeBufferPointer { buffer in
                utimensat(AT_FDCWD, disk, buffer.baseAddress, AT_SYMLINK_NOFOLLOW)
            }
            XCTAssertEqual(restoreResult, 0)

            var restoredStatus = stat()
            XCTAssertEqual(lstat(disk, &restoredStatus), 0)
            XCTAssertEqual(restoredStatus.st_size, publishedStatus.st_size)
            XCTAssertEqual(
                restoredStatus.st_mtimespec.tv_sec,
                publishedStatus.st_mtimespec.tv_sec
            )
            XCTAssertEqual(
                restoredStatus.st_mtimespec.tv_nsec,
                publishedStatus.st_mtimespec.tv_nsec
            )
            XCTAssertThrowsError(try fixture.authority.resolve(
                reference: fixture.reference,
                kind: .virtualDisk,
                source: .userProvided
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineArtifactAuthorityError,
                    .artifactChanged
                )
            }
        }
    }

    func testMutableSparseDiskIsNeverContentHashedWhileImmutableMediaStillIs() throws {
        try withFixture("mutable-no-content-hash") { fixture in
            let disk = fixture.root + "/system.raw"
            XCTAssertTrue(FileManager.default.createFile(atPath: disk, contents: nil))
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: disk))
            try handle.truncate(atOffset: 32 * 1_024 * 1_024 * 1_024)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: disk
            )
            let inspections = InspectionCounter()
            let authority = DoryVirtualMachineArtifactAuthority(
                root: fixture.authority.root
            ) { stage in
                guard case let .firstChunkHashed(path) = stage else { return }
                inspections.record(path)
            }

            _ = try authority.publishMutable(
                reference: fixture.reference,
                path: disk,
                source: .userProvided
            )
            _ = try authority.resolve(
                reference: fixture.reference,
                kind: .virtualDisk,
                source: .userProvided
            )
            XCTAssertEqual(inspections.paths, [])

            let installer = try fixture.file(
                "installer.iso",
                data: Data("immutable-efi-installer".utf8)
            )
            let installerReference = DoryVMResolverReference(
                namespace: "legacy-artifact",
                identifier: String(repeating: "b", count: 64)
            )
            _ = try authority.publishImmutable(
                reference: installerReference,
                path: installer,
                kind: .installerISO,
                source: .userProvided
            )
            _ = try authority.resolve(
                reference: installerReference,
                kind: .installerISO,
                source: .userProvided
            )
            XCTAssertEqual(inspections.paths, [installer, installer])
        }
    }

    func testOptimisticRevisionAndRecordTamperFailClosed() throws {
        try withFixture("revision") { fixture in
            let artifact = try fixture.file("bundle", data: Data("bundle".utf8))
            _ = try fixture.authority.publishImmutable(
                reference: fixture.reference,
                path: artifact,
                kind: .installedLinuxBootBundle,
                source: .bundledByDory
            )
            XCTAssertThrowsError(try fixture.authority.publishImmutable(
                reference: fixture.reference,
                path: artifact,
                kind: .installedLinuxBootBundle,
                source: .bundledByDory,
                expectedAuthorityRevision: 0
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineArtifactAuthorityError,
                    .staleRevision(expected: 0, actual: 1)
                )
            }

            let records = try FileManager.default.contentsOfDirectory(
                atPath: fixture.authority.root
            ).filter { $0.hasSuffix(".json") }
            let record = try XCTUnwrap(records.first)
            let path = fixture.authority.root + "/" + record
            var data = try Data(contentsOf: URL(fileURLWithPath: path))
            data.append(0x20)
            try data.write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
            XCTAssertThrowsError(try fixture.authority.resolve(
                reference: fixture.reference,
                kind: .installedLinuxBootBundle,
                source: .bundledByDory
            )) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineArtifactAuthorityError,
                    .invalidRecord
                )
            }
        }
    }

    func testSymlinksHardlinksAndWorldReadableArtifactsAreRejected() throws {
        try withFixture("unsafe") { fixture in
            let target = try fixture.file("target", data: Data("artifact".utf8))
            let symlink = fixture.root + "/link"
            try FileManager.default.createSymbolicLink(
                atPath: symlink,
                withDestinationPath: target
            )
            XCTAssertThrowsError(try fixture.authority.publishImmutable(
                reference: fixture.reference,
                path: symlink,
                kind: .installerISO,
                source: .userProvided
            ))

            let hardlink = fixture.root + "/hardlink"
            XCTAssertEqual(link(target, hardlink), 0)
            XCTAssertThrowsError(try fixture.authority.publishImmutable(
                reference: fixture.reference,
                path: target,
                kind: .installerISO,
                source: .userProvided
            ))
            try FileManager.default.removeItem(atPath: hardlink)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: target
            )
            XCTAssertThrowsError(try fixture.authority.publishImmutable(
                reference: fixture.reference,
                path: target,
                kind: .installerISO,
                source: .userProvided
            ))
        }
    }

    func testResolverReferencesUseTheWorkspacePersistenceContract() throws {
        try withFixture("hostile-reference") { fixture in
            let artifact = try fixture.file("image.iso", data: Data("image".utf8))
            let hostile = [
                DoryVMResolverReference(namespace: "artifact", identifier: "/tmp/image.iso"),
                DoryVMResolverReference(
                    namespace: "artifact",
                    identifier: "https://example.com/image.iso"
                ),
                DoryVMResolverReference(namespace: "artifact", identifier: "sk-secret"),
                DoryVMResolverReference(namespace: "Bad.Namespace", identifier: "image"),
                DoryVMResolverReference(
                    namespace: "artifact",
                    identifier: String(repeating: "a", count: 65)
                ),
            ]
            for reference in hostile {
                XCTAssertFalse(reference.isValidForPersistence)
                XCTAssertThrowsError(try fixture.authority.publishImmutable(
                    reference: reference,
                    path: artifact,
                    kind: .installerISO,
                    source: .userProvided
                )) { error in
                    XCTAssertEqual(
                        error as? DoryVirtualMachineArtifactAuthorityError,
                        .invalidReference
                    )
                }
            }
        }
    }

    func testTwoAuthorityInstancesSerializeOptimisticRevision() async throws {
        let fixture = try ArtifactFixture("cross-instance")
        defer { fixture.cleanup() }
        let disk = try fixture.file("system.raw", data: Data(repeating: 0, count: 4_096))
        _ = try fixture.authority.publishMutable(
            reference: fixture.reference,
            path: disk,
            source: .userProvided
        )
        let secondAuthority = DoryVirtualMachineArtifactAuthority(root: fixture.authority.root)
        let reference = fixture.reference

        let results = await withTaskGroup(
            of: Result<UInt64, DoryVirtualMachineArtifactAuthorityError>.self,
            returning: [Result<UInt64, DoryVirtualMachineArtifactAuthorityError>].self
        ) { group in
            for authority in [fixture.authority, secondAuthority] {
                group.addTask {
                    do {
                        let result = try authority.publishMutable(
                            reference: reference,
                            path: disk,
                            source: .userProvided,
                            expectedAuthorityRevision: 1
                        )
                        return .success(result.authorityRevision)
                    } catch let error as DoryVirtualMachineArtifactAuthorityError {
                        return .failure(error)
                    } catch {
                        return .failure(.filesystem("unexpected error"))
                    }
                }
            }
            var values: [Result<UInt64, DoryVirtualMachineArtifactAuthorityError>] = []
            for await result in group { values.append(result) }
            return values
        }

        XCTAssertEqual(results.compactMap { try? $0.get() }, [2])
        XCTAssertEqual(results.compactMap { result -> DoryVirtualMachineArtifactAuthorityError? in
            guard case let .failure(error) = result else { return nil }
            return error
        }, [.staleRevision(expected: 1, actual: 2)])
    }

    func testMutableRecordCannotBeSubstitutedIntoAnotherAuthorityRoot() throws {
        try withFixture("root-binding-source") { source in
            try withFixture("root-binding-destination") { destination in
                let disk = try source.file(
                    "system.raw",
                    data: Data(repeating: 0, count: 4_096)
                )
                _ = try source.authority.publishMutable(
                    reference: source.reference,
                    path: disk,
                    source: .userProvided
                )
                _ = try destination.authority.authorityRecord(reference: destination.reference)
                let recordName = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
                    atPath: source.authority.root
                ).first { $0.hasSuffix(".json") })
                let destinationRecord = destination.authority.root + "/" + recordName
                try FileManager.default.copyItem(
                    atPath: source.authority.root + "/" + recordName,
                    toPath: destinationRecord
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destinationRecord
                )

                XCTAssertThrowsError(try destination.authority.resolve(
                    reference: destination.reference,
                    kind: .virtualDisk,
                    source: .userProvided
                )) { error in
                    XCTAssertEqual(
                        error as? DoryVirtualMachineArtifactAuthorityError,
                        .invalidRecord
                    )
                }
            }
        }
    }

    func testInterruptedReplacementPreservesOldRecordAndCleansTemporaryFile() throws {
        try withFixture("interrupted-publication") { fixture in
            let artifact = try fixture.file("bundle", data: Data("bundle".utf8))
            _ = try fixture.authority.publishImmutable(
                reference: fixture.reference,
                path: artifact,
                kind: .installedLinuxBootBundle,
                source: .bundledByDory
            )
            let interrupted = DoryVirtualMachineArtifactAuthority(
                root: fixture.authority.root
            ) { stage in
                guard case .temporaryFileSynced = stage else { return }
                throw PublicationInterruption.injected
            }
            XCTAssertThrowsError(try interrupted.publishImmutable(
                reference: fixture.reference,
                path: artifact,
                kind: .installedLinuxBootBundle,
                source: .bundledByDory,
                expectedAuthorityRevision: 1
            )) { error in
                XCTAssertEqual(error as? PublicationInterruption, .injected)
            }
            XCTAssertEqual(
                try fixture.authority.resolve(
                    reference: fixture.reference,
                    kind: .installedLinuxBootBundle,
                    source: .bundledByDory
                ).authorityRevision,
                1
            )
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(
                atPath: fixture.authority.root
            ).contains { $0.hasPrefix(".artifact-authority.") && $0 != ".artifact-authority.lock" })
        }
    }

    private func withFixture(
        _ name: String,
        body: (ArtifactFixture) throws -> Void
    ) throws {
        let fixture = try ArtifactFixture(name)
        defer { fixture.cleanup() }
        try body(fixture)
    }
}

private enum PublicationInterruption: Error, Equatable {
    case injected
}

private final class InspectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var paths: [String] { lock.withLock { stored } }

    func record(_ path: String) { lock.withLock { stored.append(path) } }
}

private final class ArtifactFixture {
    let root: String
    let authority: DoryVirtualMachineArtifactAuthority
    let reference = DoryVMResolverReference(
        namespace: "legacy-artifact",
        identifier: String(repeating: "a", count: 64)
    )

    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-artifact-authority-\(name)-\(UUID().uuidString)",
            isDirectory: true
        ).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root
        )
        authority = DoryVirtualMachineArtifactAuthority(root: root + "/records")
    }

    func file(_ name: String, data: Data) throws -> String {
        let path = root + "/" + name
        try data.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
        return path
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}
