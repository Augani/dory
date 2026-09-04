import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Production manager construction")
struct MachineManagerProductionConstructionTests {
    @Test("ordinary construction cannot launch or derive boot artifacts from historical identity")
    func publicConstructionRequiresPlanning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-strict-manager-\(UUID())").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = MachineManagerConfiguration(
            vmmExecutablePath: "/bin/false", stateDirectory: root.path,
            passMachineArguments: false, requiresReadyHandoff: false
        )
        let diagnostic = MachineManager(diagnosticConfiguration: configuration)
        _ = try diagnostic.stageMachineForBootstrap(.init(
            id: "historical", kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath, displayMode: .headless
        ))
        let manager = MachineManager(configuration: configuration)
        #expect(manager.configuredLaunchPolicy == .perWorkspaceAuthority)
        let status = try #require(manager.status(id: "historical"))
        #expect(status.runtimeIdentity.mode != .resolvedPlan)
        let directory = root.appendingPathComponent("historical")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let authorityFiles = names.filter { $0.hasSuffix(".json") || $0 == "kernel" }
        let original = try authorityFiles.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
        #expect(throws: MachineManagerError.self) { try manager.start(id: "historical") }
        for (name, data) in zip(authorityFiles, original) {
            #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == data)
        }
        #expect(manager.status(id: "historical")?.pid == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == names)
    }
}
