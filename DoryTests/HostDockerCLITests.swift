import Testing
import Foundation
@testable import Dory

struct HostDockerCLITests {
    @Test func linkedToolsIncludeSupportCommands() {
        #expect(HostDockerCLI.linkedTools.contains("dory-doctor"))
        #expect(HostDockerCLI.linkedTools.contains("dorydctl"))
        #expect(HostDockerCLI.linkedTools.contains("docker-buildx"))
        #expect(!HostDockerCLI.linkedTools.contains("dory-idle-proxy"))
    }

    @Test func appendsPathBlockToEmptyProfile() throws {
        let updated = try #require(HostDockerCLI.appendingPathBlock(to: "", binDir: "/Users/x/.dory/bin"))
        #expect(updated.contains("export PATH=\"/Users/x/.dory/bin:$PATH\""))
        #expect(updated.contains("# >>> dory cli >>>"))
        #expect(updated.contains("# <<< dory cli <<<"))
    }

    @Test func appendPreservesExistingContentAndSpacing() throws {
        let original = "export FOO=1\nalias ll='ls -la'"
        let updated = try #require(HostDockerCLI.appendingPathBlock(to: original, binDir: "/b"))
        #expect(updated.hasPrefix(original))
        #expect(updated.contains("/b:$PATH"))
    }

    @Test func appendIsIdempotent() {
        let once = HostDockerCLI.appendingPathBlock(to: "x\n", binDir: "/b")
        let content = try! #require(once)
        #expect(HostDockerCLI.appendingPathBlock(to: content, binDir: "/b") == nil)
    }

    @Test func removeStripsOnlyTheDoryBlock() throws {
        let original = "export FOO=1\nexport BAR=2\n"
        let withBlock = try #require(HostDockerCLI.appendingPathBlock(to: original, binDir: "/b"))
        let stripped = HostDockerCLI.removingPathBlock(from: withBlock)
        #expect(!stripped.contains("dory cli"))
        #expect(stripped.contains("export FOO=1"))
        #expect(stripped.contains("export BAR=2"))
    }

    @Test func removeIsNoOpWhenBlockAbsent() {
        let original = "export FOO=1\n"
        #expect(HostDockerCLI.removingPathBlock(from: original) == original)
    }

    @Test func composeOwnershipRecognizesOnlyDoryControlledTargets() {
        #expect(HostDockerCLI.isDoryOwnedComposeTarget(
            "/Applications/Dory.app/Contents/Helpers/docker-compose",
            desiredSource: "/Applications/Dory.app/Contents/Helpers/docker-compose",
            home: "/Users/x",
            bundleRoot: "/Applications/Dory.app"
        ))
        #expect(HostDockerCLI.isDoryOwnedComposeTarget(
            "/Users/x/.dory/bin/docker-compose",
            desiredSource: nil,
            home: "/Users/x",
            bundleRoot: "/Applications/Dory.app"
        ))
        #expect(!HostDockerCLI.isDoryOwnedComposeTarget(
            "/opt/homebrew/bin/docker-compose",
            desiredSource: nil,
            home: "/Users/x",
            bundleRoot: "/Applications/Dory.app"
        ))
    }

    @Test func composeInstallAndRemovalNeverTouchUnownedDestinations() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dory-compose-ownership-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bundle = root.appendingPathComponent("Dory.app")
        let helper = bundle.appendingPathComponent("Contents/Helpers/docker-compose")
        let destination = home.appendingPathComponent(".docker/cli-plugins/docker-compose")
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("dory".utf8).write(to: helper)
        defer { try? fm.removeItem(at: root) }

        try Data("user-compose".utf8).write(to: destination)
        #expect(!HostDockerCLI.installOwnedComposeSymlink(
            helper.path, to: destination.path, home: home.path, bundleRoot: bundle.path, fileManager: fm
        ))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "user-compose")
        HostDockerCLI.removeOwnedComposeSymlink(
            at: destination.path, home: home.path, bundleRoot: bundle.path, fileManager: fm
        )
        #expect(try String(contentsOf: destination, encoding: .utf8) == "user-compose")

        try fm.removeItem(at: destination)
        try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: "/opt/homebrew/bin/docker-compose")
        #expect(!HostDockerCLI.installOwnedComposeSymlink(
            helper.path, to: destination.path, home: home.path, bundleRoot: bundle.path, fileManager: fm
        ))
        HostDockerCLI.removeOwnedComposeSymlink(
            at: destination.path, home: home.path, bundleRoot: bundle.path, fileManager: fm
        )
        #expect((try? fm.destinationOfSymbolicLink(atPath: destination.path)) == "/opt/homebrew/bin/docker-compose")

        try fm.removeItem(at: destination)
        #expect(HostDockerCLI.installOwnedComposeSymlink(
            helper.path, to: destination.path, home: home.path, bundleRoot: bundle.path, fileManager: fm
        ))
        HostDockerCLI.removeOwnedComposeSymlink(
            at: destination.path, home: home.path, bundleRoot: bundle.path, fileManager: fm
        )
        #expect(!fm.fileExists(atPath: destination.path))
    }
}
