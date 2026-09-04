import Foundation
import Testing

@Suite("Control-plane module dependency graph")
struct DoryControlPlaneArchitectureTests {
    @Test("resolved SwiftPM graph preserves control-plane dependency direction")
    func packageGraphForbidsUpwardControlPlaneDependencies() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "package", "--package-path", packageRoot.path, "dump-package"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let targets = try #require(manifest["targets"] as? [[String: Any]])
        var graph: [String: Set<String>] = [:]
        for target in targets {
            let name = try #require(target["name"] as? String)
            let dependencies = try #require(target["dependencies"] as? [[String: Any]])
            graph[name] = Set(try dependencies.map { dependency in
                let reference = try #require(
                    (dependency["byName"] ?? dependency["target"] ?? dependency["product"]) as? [Any]
                )
                return try #require(reference.first as? String)
            })
        }
        func reachableDependencies(_ name: String) throws -> Set<String> {
            var pending = Array(try #require(graph[name]))
            var visited: Set<String> = []
            while let dependency = pending.popLast() {
                guard visited.insert(dependency).inserted else { continue }
                pending.append(contentsOf: graph[dependency] ?? [])
            }
            return visited
        }
        // These modules may supply intent, artifacts or FFI values to daemon composition, but
        // cannot acquire that higher authority indirectly through a new intermediate target.
        for lowerLayer in ["DoryVMContracts", "DoryExecutionContracts", "DoryFirmware",
                           "DoryOperations", "DoryCore"] {
            let reachable = try reachableDependencies(lowerLayer)
            #expect(!reachable.contains("DorydKit"), "Upward daemon dependency from \(lowerLayer)")
            #expect(!reachable.contains("DoryVMMKit"), "Runner dependency from \(lowerLayer)")
        }
        // CLI and daemon entrypoints consume daemon authority; only the helper owns execution.
        for controlPlane in ["DorydKit", "doryd", "dorydctl"] {
            #expect(try !reachableDependencies(controlPlane).contains("DoryVMMKit"),
                    "Control-plane entrypoint imports runner composition: \(controlPlane)")
        }
        let daemon = try #require(graph["DorydKit"])
        let runner = try #require(graph["DoryVMMKit"])
        #expect(daemon.contains("DoryOperations"))
        #expect(runner.contains("DorydKit"))
        #expect(runner.contains("DoryOperations"))
        #expect(try #require(graph["doryd"]).contains("DorydKit"))
        #expect(try #require(graph["dorydctl"]).contains("DorydKit"))
        #expect(try #require(graph["dory-vmm"]).contains("DoryVMMKit"))
    }
}
