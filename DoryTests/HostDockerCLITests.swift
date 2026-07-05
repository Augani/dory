import Testing
import Foundation
@testable import Dory

struct HostDockerCLITests {
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
}
