import Darwin
@testable import DoryOperations
import Foundation
import XCTest

final class DoryTrustedDirectoryRootTests: XCTestCase {
    func testAcquisitionRejectsNonCanonicalAbsolutePaths() {
        for invalid in [
            "relative/managed",
            "/",
            "/private/tmp/",
            "/private//tmp/managed",
            "/private/./tmp/managed",
            "/private/../tmp/managed",
            "/private/\0tmp/managed",
        ] {
            XCTAssertThrowsError(try DoryTrustedDirectoryRoot(
                canonicalAbsolutePath: invalid
            )) { error in
                XCTAssertEqual(
                    error as? DoryTrustedDirectoryRootError,
                    .invalidAbsolutePath(invalid)
                )
            }
        }
    }

    func testAcquiresCanonicalPrivateRootAndPrivateChild() throws {
        let fixture = try makeFixture("happy")
        let childPath = fixture.root + "/machine"
        try makePrivateDirectory(childPath)

        let root = try DoryTrustedDirectoryRoot(
            canonicalAbsolutePath: fixture.root
        )
        XCTAssertEqual(root.health, .healthy)
        XCTAssertEqual(try root.revalidateRootPathname(), root.identity)

        let child = try root.openPrivateChildDirectory(
            DoryTrustedPathComponent(validating: "machine")
        )
        var expected = stat()
        XCTAssertEqual(lstat(childPath, &expected), 0)
        XCTAssertEqual(
            child.identity,
            DoryTrustedDirectoryIdentity(expected)
        )
    }

    func testAcquisitionRejectsRootSymlink() throws {
        let fixture = try makeFixture("root-link", createRoot: false)
        let physical = fixture.container + "/physical"
        try makePrivateDirectory(physical)
        XCTAssertEqual(symlink(physical, fixture.root), 0)

        XCTAssertThrowsError(try DoryTrustedDirectoryRoot(
            canonicalAbsolutePath: fixture.root
        )) { error in
            guard case let DoryTrustedDirectoryRootError.cannotOpenDirectory(path, _) = error else {
                return XCTFail("expected a no-follow open failure, got \(error)")
            }
            XCTAssertEqual(path, fixture.root)
        }
    }

    func testAcquisitionRejectsIntermediateSymlink() throws {
        let fixture = try makeFixture("ancestor-link", createRoot: false)
        let physicalParent = fixture.container + "/physical-parent"
        let physicalRoot = physicalParent + "/managed"
        try makePrivateDirectory(physicalParent)
        try makePrivateDirectory(physicalRoot)
        let alias = fixture.container + "/alias"
        XCTAssertEqual(symlink(physicalParent, alias), 0)

        XCTAssertThrowsError(try DoryTrustedDirectoryRoot(
            canonicalAbsolutePath: alias + "/managed"
        )) { error in
            guard case let DoryTrustedDirectoryRootError.cannotOpenDirectory(path, _) = error else {
                return XCTFail("expected an intermediate no-follow failure, got \(error)")
            }
            XCTAssertEqual(path, alias)
        }
    }

    func testAcquisitionRejectsReplaceableAncestor() throws {
        let fixture = try makeFixture("ancestor-mode")
        XCTAssertEqual(chmod(fixture.container, mode_t(0o777)), 0)

        XCTAssertThrowsError(try DoryTrustedDirectoryRoot(
            canonicalAbsolutePath: fixture.root
        )) { error in
            XCTAssertEqual(
                error as? DoryTrustedDirectoryRootError,
                .unsafeAncestor(path: fixture.container)
            )
        }
    }

    func testAcquisitionRejectsWrongManagedRootMode() throws {
        let fixture = try makeFixture("root-mode")
        XCTAssertEqual(chmod(fixture.root, mode_t(0o755)), 0)

        XCTAssertThrowsError(try DoryTrustedDirectoryRoot(
            canonicalAbsolutePath: fixture.root
        )) { error in
            XCTAssertEqual(
                error as? DoryTrustedDirectoryRootError,
                .unsafeManagedRoot(path: fixture.root)
            )
        }
    }

    func testSingleComponentValidationRejectsTraversalAndOversizedNames() throws {
        for invalid in [
            "",
            ".",
            "..",
            "nested/child",
            "nul\0suffix",
            String(repeating: "a", count: Int(NAME_MAX) + 1),
        ] {
            XCTAssertThrowsError(try DoryTrustedPathComponent(validating: invalid)) { error in
                XCTAssertEqual(
                    error as? DoryTrustedDirectoryRootError,
                    .invalidComponent(invalid)
                )
            }
        }
        XCTAssertEqual(
            try DoryTrustedPathComponent(validating: "machine-01").value,
            "machine-01"
        )
    }

    func testChildOpenRejectsSymlink() throws {
        let fixture = try makeFixture("child-link")
        let target = fixture.root + "/target"
        try makePrivateDirectory(target)
        XCTAssertEqual(symlink(target, fixture.root + "/machine"), 0)
        let root = try DoryTrustedDirectoryRoot(canonicalAbsolutePath: fixture.root)

        XCTAssertThrowsError(try root.openPrivateChildDirectory(
            DoryTrustedPathComponent(validating: "machine")
        )) { error in
            guard case let DoryTrustedDirectoryRootError.cannotOpenChild(component, _) = error else {
                return XCTFail("expected child no-follow failure, got \(error)")
            }
            XCTAssertEqual(component, "machine")
        }
        XCTAssertEqual(root.health, .healthy)
    }

    func testChildOpenRejectsWrongMode() throws {
        let fixture = try makeFixture("child-mode")
        let child = fixture.root + "/machine"
        try makePrivateDirectory(child)
        XCTAssertEqual(chmod(child, mode_t(0o755)), 0)
        let root = try DoryTrustedDirectoryRoot(canonicalAbsolutePath: fixture.root)

        XCTAssertThrowsError(try root.openPrivateChildDirectory(
            DoryTrustedPathComponent(validating: "machine")
        )) { error in
            XCTAssertEqual(
                error as? DoryTrustedDirectoryRootError,
                .unsafeChildDirectory(component: "machine")
            )
        }
        XCTAssertEqual(root.health, .healthy)
    }

    func testRootReplacementQuarantinesPermanently() throws {
        let fixture = try makeFixture("root-replacement")
        let root = try DoryTrustedDirectoryRoot(canonicalAbsolutePath: fixture.root)
        let displaced = fixture.container + "/displaced"
        try FileManager.default.moveItem(atPath: fixture.root, toPath: displaced)
        try makePrivateDirectory(fixture.root)

        assertQuarantined(root, reason: .rootIdentityChanged)

        try FileManager.default.removeItem(atPath: fixture.root)
        try FileManager.default.moveItem(atPath: displaced, toPath: fixture.root)
        assertQuarantined(root, reason: .rootIdentityChanged)
    }

    func testRootDisappearanceQuarantinesPermanently() throws {
        let fixture = try makeFixture("root-missing")
        let root = try DoryTrustedDirectoryRoot(canonicalAbsolutePath: fixture.root)
        let displaced = fixture.container + "/displaced"
        try FileManager.default.moveItem(atPath: fixture.root, toPath: displaced)

        XCTAssertThrowsError(try root.revalidateRootPathname()) { error in
            guard case let DoryTrustedDirectoryRootError.quarantined(reason) = error,
                  case let .pathnameUnavailable(code) = reason else {
                return XCTFail("expected unavailable-path quarantine, got \(error)")
            }
            XCTAssertEqual(code, ENOENT)
        }

        try FileManager.default.moveItem(atPath: displaced, toPath: fixture.root)
        guard case let .quarantined(stored) = root.health,
              case .pathnameUnavailable = stored else {
            return XCTFail("the first unavailable-path reason must remain latched")
        }
        XCTAssertThrowsError(try root.revalidateRootPathname())
    }

    func testRootSymlinkSubstitutionQuarantines() throws {
        let fixture = try makeFixture("root-symlink-drift")
        let root = try DoryTrustedDirectoryRoot(canonicalAbsolutePath: fixture.root)
        let displaced = fixture.container + "/displaced"
        try FileManager.default.moveItem(atPath: fixture.root, toPath: displaced)
        XCTAssertEqual(symlink(displaced, fixture.root), 0)

        XCTAssertThrowsError(try root.revalidateRootPathname()) { error in
            guard case let DoryTrustedDirectoryRootError.quarantined(reason) = error,
                  case .pathnameUnavailable = reason else {
                return XCTFail("expected symlink-path quarantine, got \(error)")
            }
        }
    }

    func testRootModeDriftQuarantinesPermanently() throws {
        let fixture = try makeFixture("root-mode-drift")
        let root = try DoryTrustedDirectoryRoot(canonicalAbsolutePath: fixture.root)
        XCTAssertEqual(chmod(fixture.root, mode_t(0o755)), 0)

        assertQuarantined(root, reason: .rootMetadataChanged)

        XCTAssertEqual(chmod(fixture.root, mode_t(0o700)), 0)
        assertQuarantined(root, reason: .rootMetadataChanged)
    }

    func testAncestorModeDriftQuarantinesPermanently() throws {
        let fixture = try makeFixture("ancestor-mode-drift")
        let root = try DoryTrustedDirectoryRoot(canonicalAbsolutePath: fixture.root)
        XCTAssertEqual(chmod(fixture.container, mode_t(0o777)), 0)

        assertQuarantined(
            root,
            reason: .ancestorPolicyViolated(path: fixture.container)
        )

        XCTAssertEqual(chmod(fixture.container, mode_t(0o700)), 0)
        assertQuarantined(
            root,
            reason: .ancestorPolicyViolated(path: fixture.container)
        )
    }

    func testOpenedChildDescriptorRemainsPinnedAfterRootReplacement() throws {
        let fixture = try makeFixture("pinned-child")
        let childPath = fixture.root + "/machine"
        try makePrivateDirectory(childPath)
        let expected = Data("original-generation".utf8)
        try writePrivateFile(expected, path: childPath + "/sentinel")

        let root = try DoryTrustedDirectoryRoot(canonicalAbsolutePath: fixture.root)
        let child = try root.openPrivateChildDirectory(
            DoryTrustedPathComponent(validating: "machine")
        )

        let displaced = fixture.container + "/displaced"
        try FileManager.default.moveItem(atPath: fixture.root, toPath: displaced)
        try makePrivateDirectory(fixture.root)
        let replacementChild = fixture.root + "/machine"
        try makePrivateDirectory(replacementChild)
        try writePrivateFile(
            Data("replacement-generation".utf8),
            path: replacementChild + "/sentinel"
        )

        XCTAssertEqual(try readFile(named: "sentinel", from: child), expected)
        assertQuarantined(root, reason: .rootIdentityChanged)
        XCTAssertEqual(try readFile(named: "sentinel", from: child), expected)
    }

    private func assertQuarantined(
        _ root: DoryTrustedDirectoryRoot,
        reason expected: DoryTrustedDirectoryRootQuarantineReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try root.revalidateRootPathname(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? DoryTrustedDirectoryRootError,
                .quarantined(expected),
                file: file,
                line: line
            )
        }
        XCTAssertEqual(root.health, .quarantined(expected), file: file, line: line)
    }

    private func makeFixture(
        _ label: String,
        createRoot: Bool = true
    ) throws -> (container: String, root: String) {
        let container = "/private/tmp/dory-trusted-root-\(label)-\(getpid())-\(UUID().uuidString)"
        try makePrivateDirectory(container)
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: container)
        }
        let root = container + "/managed"
        if createRoot { try makePrivateDirectory(root) }
        return (container, root)
    }

    private func makePrivateDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(path, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writePrivateFile(_ data: Data, path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }

    private func readFile(
        named name: String,
        from directory: DoryTrustedDirectoryHandle
    ) throws -> Data {
        try directory.withBorrowedDescriptor { parentDescriptor in
            let descriptor = openat(
                parentDescriptor,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size >= 0 else {
                throw POSIXError(.EIO)
            }
            var result = Data(count: Int(info.st_size))
            let count = result.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress, buffer.count, 0)
            }
            guard count == result.count else { throw POSIXError(.EIO) }
            return result
        }
    }
}
