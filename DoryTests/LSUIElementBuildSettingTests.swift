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

    @Test func menuBarUsesSingleAppKitStatusItem() throws {
        let app = try repositoryFile("Dory/DoryApp.swift")
        let delegate = try repositoryFile("Dory/App/AppDelegate.swift")
        #expect(!app.contains("MenuBarExtra"))
        #expect(delegate.contains("DoryStatusItemController"))
        #expect(delegate.contains("NSStatusBar.system.statusItem"))
        #expect(delegate.contains("NSStatusBar.system.removeStatusItem"))
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
        let uiScheme = try repositoryFile("Dory.xcodeproj/xcshareddata/xcschemes/Dory UI Tests.xcscheme")
        #expect(build.contains("scripts/clean-xcode-products.sh --strip-test-products"))
        #expect(test.components(separatedBy: "scripts/clean-xcode-products.sh").count - 1 >= 2)
        #expect(uiScheme.components(separatedBy: "scripts/clean-xcode-products.sh").count - 1 >= 2)
        #expect(clean.contains("DoryUITests-Runner.app"))
        #expect(clean.contains("lsregister"))
        #expect(clean.contains("com\\.pythonxi\\.DoryUITests\\.xctrunner"))
        #expect(clean.contains("purge_registered_test_runners"))
        #expect(clean.contains("DoryTests.xctest"))
        #expect(clean.contains("com.apple.provenance"))
        #expect(clean.contains("com.apple.quarantine"))
        #expect(!clean.contains("rm -rf \"$app\""))
    }

    @Test func buildScriptCanBundleHostCLIsOnCleanMacs() throws {
        let build = try repositoryFile("scripts/build.sh")
        #expect(build.contains("download_docker_cli()"))
        #expect(build.contains("DORY_DOCKER_CLI_VERSION:-29.0.1"))
        #expect(build.contains("download.docker.com/mac/static/stable"))
        #expect(build.contains("download_docker_compose()"))
        #expect(build.contains("DORY_DOCKER_COMPOSE_VERSION:-v2.39.2"))
        #expect(build.contains("github.com/docker/compose/releases/download"))
        #expect(build.contains("download_kubectl()"))
        #expect(build.contains("DORY_KUBECTL_VERSION:-v1.36.1"))
        #expect(build.contains("dl.k8s.io/release"))
        #expect(build.contains("DORY_BUNDLE_HOST_CLI_DOWNLOADS:-1"))
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
