import Foundation
import Testing
@testable import DoryHV

struct VirtioFSShareConfigurationTests {
    @Test func parsesReadWriteShareArgument() throws {
        let share = try VirtioFSShareConfiguration(argument: "src=/Users/example/project")

        #expect(share.tag == "src")
        #expect(share.path == "/Users/example/project")
        #expect(!share.readOnly)
    }

    @Test func parsesReadOnlyAndExplicitReadWriteSuffixes() throws {
        let readOnly = try VirtioFSShareConfiguration(argument: "cache=/tmp/cache:ro")
        let readWrite = try VirtioFSShareConfiguration(argument: "work=/tmp/work:rw")

        #expect(readOnly.path == "/tmp/cache")
        #expect(readOnly.readOnly)
        #expect(readWrite.path == "/tmp/work")
        #expect(!readWrite.readOnly)
    }

    @Test func rejectsInvalidShareArguments() {
        #expect(throws: (any Error).self) {
            _ = try VirtioFSShareConfiguration(argument: "missing-equals")
        }
        #expect(throws: (any Error).self) {
            _ = try VirtioFSShareConfiguration(argument: "bad/tag=/tmp")
        }
        #expect(throws: (any Error).self) {
            _ = try VirtioFSShareConfiguration(argument: "empty=")
        }
        for argument in [
            "relative=project",
            "root=/",
            "traversal=/Users/example/../outside",
            "trailing=/Users/example/",
            "double=/Users//example",
            "nul=/Users/example\0outside",
        ] {
            #expect(throws: (any Error).self) {
                _ = try VirtioFSShareConfiguration(argument: argument)
            }
        }
    }

    @Test func defaultsToDaxDisabled() throws {
        let share = try VirtioFSShareConfiguration(argument: "src=/Users/example/project")
        #expect(!share.dax)
    }

    @Test func rejectsDaxForReadWriteAndReadOnlyHostSharesWithSafetyReason() {
        for argument in [
            "src=/Users/example/project:dax",
            "cache=/tmp/cache:ro:dax",
            "cache=/tmp/cache:dax:ro",
        ] {
            do {
                _ = try VirtioFSShareConfiguration(argument: argument)
                Issue.record("production host share unexpectedly accepted DAX: \(argument)")
            } catch {
                #expect(String(describing: error).contains("DAX host shares are disabled"))
                #expect(String(describing: error).contains("fail-stop boundary"))
            }
        }
    }

    @Test func parsesGuestMountPointFromAtOption() throws {
        let share = try VirtioFSShareConfiguration(argument: "home=/Users/example:rw:at=/Users/example")
        #expect(share.path == "/Users/example")
        #expect(share.guestMountPoint == "/Users/example")
        #expect(!share.readOnly)
    }

    @Test func defaultsGuestMountPointToNil() throws {
        let share = try VirtioFSShareConfiguration(argument: "src=/Users/example/project")
        #expect(share.guestMountPoint == nil)
    }

    @Test func safeOptionAppliesSensitiveNameDenylist() throws {
        let share = try VirtioFSShareConfiguration(argument: "home=/Users/example:rw:at=/Users/example:safe")
        #expect(share.hiddenNames.isEmpty)
        #expect(share.rootHiddenNames == VirtioFSShareConfiguration.sensitiveNames)
        #expect(share.rootHiddenNames.contains(".ssh"))
        #expect(share.rootHiddenNames.contains(".aws"))
        #expect(share.rootHiddenNames.contains(".dory"))
        #expect(share.rootHiddenNames.contains(".zsh_history"))
        #expect(share.rootHiddenNames.contains(".bash_history"))
        #expect(share.rootHiddenNames.contains(".codex"))
        #expect(share.rootHiddenNames.contains(".orbstack"))
        #expect(share.rootHiddenNames.contains(".colima"))
        #expect(share.rootHiddenNames.contains("Library"))
    }

    @Test func hideOptionAddsExplicitNames() throws {
        let share = try VirtioFSShareConfiguration(argument: "src=/tmp/x:hide=secrets,.env")
        #expect(share.hiddenNames == ["secrets", ".env"])
    }

    @Test func defaultsToNoHiddenNames() throws {
        let share = try VirtioFSShareConfiguration(argument: "src=/tmp/x")
        #expect(share.hiddenNames.isEmpty)
        #expect(share.rootHiddenNames.isEmpty)
    }

    @Test func rejectsRelativeGuestMountPoint() {
        for mountPoint in [
            "relative/path",
            "/",
            "/workspace/../etc",
            "/workspace/",
            "/workspace//src",
            "/workspace\0outside",
        ] {
            #expect(throws: (any Error).self) {
                _ = try VirtioFSShareConfiguration(
                    argument: "home=/Users/example:at=\(mountPoint)"
                )
            }
        }
    }

    @Test func rejectsInvalidHiddenNameComponents() {
        for hiddenName in ["", ".", "..", "parent/child", "secret\0outside"] {
            #expect(throws: (any Error).self) {
                _ = try VirtioFSShareConfiguration(
                    tag: "home",
                    path: "/Users/example",
                    hiddenNames: [hiddenName]
                )
            }
        }

        for option in ["hide=", "hide=.env,", "hide=,.env"] {
            #expect(throws: (any Error).self) {
                _ = try VirtioFSShareConfiguration(
                    argument: "home=/Users/example:\(option)"
                )
            }
        }
    }

    @Test func makeBackendWithoutDaxHasNoDaxConfiguration() throws {
        let dir = FileManager.default.temporaryDirectory.path
        let share = try VirtioFSShareConfiguration(argument: "t=\(dir)")
        let device = try share.makeBackend(daxGuestBase: GuestLayout.daxWindowBase, requestQueueCount: 3)
        #expect(device.daxConfiguration == nil)
        #expect(device.requestQueueCount == 3)
    }

    @Test func makeBackendRechecksMutatedDaxFlag() throws {
        let dir = FileManager.default.temporaryDirectory.path
        var share = try VirtioFSShareConfiguration(argument: "t=\(dir)")
        share.dax = true
        do {
            _ = try share.makeBackend(daxGuestBase: GuestLayout.daxWindowBase)
            Issue.record("mutating a validated configuration unexpectedly enabled DAX")
        } catch {
            #expect(String(describing: error).contains("DAX host shares are disabled"))
        }
    }

    @Test func writableShareTopologyRejectsAliasesAndNestedRoots() throws {
        let home = try VirtioFSShareConfiguration(
            tag: "home",
            path: "/Users/example",
            guestMountPoint: "/Users/example"
        )
        let nested = try VirtioFSShareConfiguration(
            tag: "project",
            path: "/Users/example/project",
            guestMountPoint: "/workspace"
        )
        let alias = try VirtioFSShareConfiguration(
            tag: "alias",
            path: "/Users/example",
            guestMountPoint: "/second"
        )

        #expect(throws: (any Error).self) {
            try VirtioFSShareConfiguration.validateWritableTopology([home, nested])
        }
        #expect(throws: (any Error).self) {
            try VirtioFSShareConfiguration.validateWritableTopology([home, alias])
        }
    }

    @Test func topologyAllowsDisjointOrReadOnlyOnlyNestedShares() throws {
        let first = try VirtioFSShareConfiguration(tag: "first", path: "/tmp/first")
        let second = try VirtioFSShareConfiguration(tag: "second", path: "/tmp/second")
        let readOnlyRoot = try VirtioFSShareConfiguration(
            tag: "reference-root",
            path: "/tmp/reference",
            readOnly: true
        )
        let nestedReadOnly = try VirtioFSShareConfiguration(
            tag: "reference",
            path: "/tmp/reference/nested",
            readOnly: true
        )

        try VirtioFSShareConfiguration.validateWritableTopology([
            first, second, readOnlyRoot, nestedReadOnly,
        ])

        let nestedUnderWritable = try VirtioFSShareConfiguration(
            tag: "read-only-alias",
            path: "/tmp/first/reference",
            readOnly: true
        )
        #expect(throws: (any Error).self) {
            try VirtioFSShareConfiguration.validateWritableTopology([first, nestedUnderWritable])
        }
    }
}
