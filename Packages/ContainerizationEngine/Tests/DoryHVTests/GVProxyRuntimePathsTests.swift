import DoryHV
import Testing

struct GVProxyRuntimePathsTests {
    @Test func pathsAreProcessScopedAndUseShortSocketNames() throws {
        let first = try GVProxyRuntimePaths(stateDirectory: "/tmp/dory/hv", processIdentifier: 41)
        let second = try GVProxyRuntimePaths(stateDirectory: "/tmp/dory/hv", processIdentifier: 42)

        #expect(first.directory == "/tmp/dory/hv/n41")
        #expect(first.socketPaths.count == 7)
        #expect(Set(first.socketPaths).count == first.socketPaths.count)
        #expect(Set(first.socketPaths).isDisjoint(with: second.socketPaths))
        #expect(first.socketPaths.allSatisfy { $0.hasPrefix(first.directory + "/") })
    }

    @Test func rejectsInvalidProcessIdentifier() {
        #expect(throws: (any Error).self) {
            _ = try GVProxyRuntimePaths(stateDirectory: "/tmp/dory/hv", processIdentifier: 0)
        }
    }

    @Test func rejectsStateDirectoryThatWouldOverflowDarwinSocketPaths() {
        let state = "/" + String(repeating: "x", count: 100)
        #expect(throws: (any Error).self) {
            _ = try GVProxyRuntimePaths(stateDirectory: state, processIdentifier: 99)
        }
    }
}
