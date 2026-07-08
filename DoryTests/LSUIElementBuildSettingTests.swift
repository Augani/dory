import Testing
import Foundation

struct LSUIElementBuildSettingTests {
    private func pbxproj() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Dory.xcodeproj/project.pbxproj")
        return try String(contentsOf: path, encoding: .utf8)
    }

    @Test func appTargetConfigsSetLSUIElement() throws {
        let text = try pbxproj()
        let occurrences = text.components(separatedBy: "INFOPLIST_KEY_LSUIElement = YES;").count - 1
        #expect(occurrences >= 2)
    }

    @Test func appBuildPrunesStaleBundledHelpersBeforeSigning() throws {
        let text = try pbxproj()
        #expect(text.contains("Prune Stale Bundled Helpers"))
        #expect(text.contains("for helper in container docker docker-compose"))
        #expect(text.contains("rm -f \\\"$HELPERS/$helper\\\""))
        #expect(text.contains("$(TARGET_BUILD_DIR)/$(WRAPPER_NAME)/Contents/Helpers"))
        #expect(text.contains("$(TARGET_BUILD_DIR)/$(WRAPPER_NAME)/Contents/Helpers/dory-idle-proxy"))
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
