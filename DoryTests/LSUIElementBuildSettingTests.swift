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

    private func repositoryFile(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent(relativePath)
        return try String(contentsOf: path, encoding: .utf8)
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
        let text = try pbxproj()
        #expect(text.contains("Prune Stale Bundled Helpers"))
        #expect(text.contains("for helper in container docker docker-compose"))
        #expect(text.contains("rm -f \\\"$HELPERS/$helper\\\""))
        #expect(text.contains("$(TARGET_BUILD_DIR)/$(WRAPPER_NAME)/Contents/Helpers"))
        #expect(text.contains("$(TARGET_BUILD_DIR)/$(WRAPPER_NAME)/Contents/Helpers/dory-idle-proxy"))
    }

    @Test func buildAndTestScriptsScrubTransientXcodeProducts() throws {
        let build = try repositoryFile("scripts/build.sh")
        let test = try repositoryFile("scripts/test.sh")
        let clean = try repositoryFile("scripts/clean-xcode-products.sh")
        #expect(build.contains("scripts/clean-xcode-products.sh --strip-test-products"))
        #expect(test.components(separatedBy: "scripts/clean-xcode-products.sh").count - 1 >= 2)
        #expect(clean.contains("DoryUITests-Runner.app"))
        #expect(clean.contains("DoryTests.xctest"))
        #expect(clean.contains("com.apple.provenance"))
        #expect(clean.contains("com.apple.quarantine"))
    }

    @Test func mainSchemeDoesNotRunUITestRunner() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Dory.xcodeproj/xcshareddata/xcschemes/Dory.xcscheme")
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.contains("DoryTests.xctest"))
        #expect(!text.contains("DoryUITests.xctest"))
    }
}
