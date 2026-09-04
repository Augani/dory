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

    @Test func menuBarUsesSingleAppKitStatusItem() throws {
        let app = try repositoryFile("Dory/DoryApp.swift")
        let delegate = try repositoryFile("Dory/App/AppDelegate.swift")
        #expect(!app.contains("MenuBarExtra"))
        #expect(delegate.contains("DoryStatusItemController"))
        #expect(delegate.contains("NSStatusBar.system.statusItem"))
        #expect(delegate.contains("NSStatusBar.system.removeStatusItem"))
    }

    @Test func statusItemInstallationWaitsForApplicationDidFinishLaunching() throws {
        let delegate = try repositoryFile("Dory/App/AppDelegate.swift")
        let configureBody = try #require(
            delegate.components(separatedBy: "func configure(store: AppStore) {").last?
                .components(separatedBy: "\n    }").first
        )
        let didFinishBody = try #require(
            delegate.components(separatedBy: "func applicationDidFinishLaunching(_ notification: Notification) {").last?
                .components(separatedBy: "\n    }").first
        )

        #expect(!configureBody.contains("applyVisibility()"))
        #expect(didFinishBody.contains("Self.refreshMenuBarVisibility()"))
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

    @Test func debugBuildPackagesDoryPCQualificationFirmwareBeforeSigning() throws {
        let (target, objects) = try appProject()
        let configurationList = try #require(target["buildConfigurationList"] as? String)
        let references = try #require(objects[configurationList]?["buildConfigurations"] as? [String])
        let configurations = references.compactMap { objects[$0] }
        for (name, expected) in [("Debug", "1"), ("Release", "0")] {
            let configuration = try #require(configurations.first { $0["name"] as? String == name })
            let settings = try #require(configuration["buildSettings"] as? [String: Any])
            #expect(settings["DORY_VM_QUALIFICATION_BOOTSTRAP"] as? String == expected)
        }
        let phases = try #require(target["buildPhases"] as? [String]).compactMap { objects[$0] }
        let firmwarePhase = try #require(phases.firstIndex { $0["name"] as? String == "Package DoryPC Firmware" })
        let extensionPhase = try #require(phases.firstIndex { $0["name"] as? String == "Embed App Extensions" })
        #expect(firmwarePhase < extensionPhase)
        let builder = try repositoryFile("scripts/build-dory-armvirt-firmware.py")
        #expect(builder.contains("verify_packaged_pc_bundle"))
        #expect(builder.contains("package_pc_qualification_app"))
        #expect(builder.contains("--qualification-bootstrap"))
    }

    @Test func buildAndPublicTestRunnerScrubTransientXcodeProducts() throws {
        let build = try repositoryFile("scripts/build.sh")
        let test = try repositoryFile("scripts/test.sh")
        let clean = try repositoryFile("scripts/clean-xcode-products.sh")
        let uiScheme = try repositoryFile("Dory.xcodeproj/xcshareddata/xcschemes/Dory UI Tests.xcscheme")
        #expect(build.contains("scripts/clean-xcode-products.sh --strip-test-products"))
        #expect(test.contains("clean_test_products()"))
        #expect(test.components(separatedBy: "clean_test_products").count - 1 >= 5)
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
