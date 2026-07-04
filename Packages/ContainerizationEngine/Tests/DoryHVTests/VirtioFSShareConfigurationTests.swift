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
    }

    @Test func defaultsToDaxDisabled() throws {
        let share = try VirtioFSShareConfiguration(argument: "src=/Users/example/project")
        #expect(!share.dax)
    }

    @Test func parsesDaxSuffix() throws {
        let share = try VirtioFSShareConfiguration(argument: "src=/Users/example/project:dax")
        #expect(share.path == "/Users/example/project")
        #expect(share.dax)
        #expect(!share.readOnly)
    }

    @Test func parsesCombinedReadOnlyAndDaxSuffixesInAnyOrder() throws {
        let a = try VirtioFSShareConfiguration(argument: "cache=/tmp/cache:ro:dax")
        let b = try VirtioFSShareConfiguration(argument: "cache=/tmp/cache:dax:ro")
        for share in [a, b] {
            #expect(share.path == "/tmp/cache")
            #expect(share.readOnly)
            #expect(share.dax)
        }
    }

    @Test func makeBackendWithoutDaxHasNoDaxConfiguration() throws {
        let dir = FileManager.default.temporaryDirectory.path
        let share = try VirtioFSShareConfiguration(argument: "t=\(dir)")
        let device = try share.makeBackend(daxGuestBase: GuestLayout.daxWindowBase)
        #expect(device.daxConfiguration == nil)
    }

    @Test func makeBackendWithDaxUsesProvidedGuestBase() throws {
        let dir = FileManager.default.temporaryDirectory.path
        let share = try VirtioFSShareConfiguration(argument: "t=\(dir):dax")
        let device = try share.makeBackend(daxGuestBase: GuestLayout.daxWindowBase)
        #expect(device.daxConfiguration?.guestBase == GuestLayout.daxWindowBase)
        #expect(device.sharedMemoryRegions.count == 1)
    }

    @Test func makeBackendWithDaxButNoBaseThrows() {
        let dir = FileManager.default.temporaryDirectory.path
        #expect(throws: (any Error).self) {
            let share = try VirtioFSShareConfiguration(argument: "t=\(dir):dax")
            _ = try share.makeBackend(daxGuestBase: nil)
        }
    }
}
