import Testing
import Foundation

struct LSUIElementBuildSettingTests {
    private func infoPlist() throws -> [String: Any] {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Config/Dory-Info.plist")
        let data = try Data(contentsOf: path)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func pbxproj() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Dory.xcodeproj/project.pbxproj")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func appProject() throws -> (target: [String: Any], objects: [String: [String: Any]]) {
        let project = try #require(PropertyListSerialization.propertyList(
            from: Data(try pbxproj().utf8), format: nil
        ) as? [String: Any])
        let objects = try #require(project["objects"] as? [String: [String: Any]])
        let target = try #require(objects.values.first {
            $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "Dory"
        })
        return (target, objects)
    }

    @Test func appTargetConfigsSetLSUIElement() throws {
        let text = try pbxproj()
        let occurrences = text.components(separatedBy: "INFOPLIST_KEY_LSUIElement = YES;").count - 1
        #expect(occurrences >= 2)
    }

    @Test func appInfoPlistProhibitsMultipleLaunchServicesInstances() throws {
        let plist = try infoPlist()
        #expect(plist["LSMultipleInstancesProhibited"] as? Bool == true)
    }

    @Test func appBuildPrunesStaleBundledHelpersBeforeSigning() throws {
        let (target, objects) = try appProject()
        let phases = try #require(target["buildPhases"] as? [String]).compactMap { objects[$0] }
        let phase = try #require(phases.first { $0["name"] as? String == "Prune Stale Bundled Helpers" })
        let script = try #require(phase["shellScript"] as? String)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dory-prune-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let neighbor = root.appendingPathComponent("preserved.txt")
        try Data("preserved".utf8).write(to: neighbor)
        for (wrapper, accepted) in [("Dory.app", true), ("not-an-app", false)] {
            let helpers = root.appendingPathComponent(wrapper + "/Contents/Helpers")
            let nested = helpers.appendingPathComponent("stale/subdirectory")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let stale = nested.appendingPathComponent("obsolete-helper")
            try Data("stale".utf8).write(to: stale)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["PATH": "/usr/bin:/bin", "TARGET_BUILD_DIR": root.path, "WRAPPER_NAME": wrapper]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect((process.terminationStatus == 0) == accepted)
            #expect(FileManager.default.fileExists(atPath: stale.path) == !accepted)
            #expect(try Data(contentsOf: neighbor) == Data("preserved".utf8))
        }
    }

}
