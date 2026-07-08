@testable import DorydKit
import XCTest

final class HostCLIInstallerTests: XCTestCase {
    func testDorydStartupInstallerLinksBundledToolsAndComposePlugin() throws {
        let directory = "/tmp/doryd-cli-install-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        for tool in ["docker", "docker-compose", "kubectl", "dory", "dory-doctor", "dory-idle-proxy", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }

        let result = HostCLIInstaller(home: home, helpersDirectory: helpers).install()

        XCTAssertTrue(result.dockerLinked)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertTrue(result.composePluginInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.dory/bin/docker"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.dory/bin/docker"), helpers + "/docker")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.docker/cli-plugins/docker-compose"), helpers + "/docker-compose")
        let profile = try String(contentsOfFile: home + "/.zprofile", encoding: .utf8)
        XCTAssertTrue(profile.contains("export PATH=\"\(home)/.dory/bin:$PATH\""))
    }

    func testInstallerIsIdempotent() throws {
        let directory = "/tmp/doryd-cli-idempotent-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        for tool in ["docker", "docker-compose", "kubectl", "dory", "dory-doctor", "dory-idle-proxy", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }

        let installer = HostCLIInstaller(home: home, helpersDirectory: helpers)
        XCTAssertTrue(installer.install().pathProfileChanged)
        XCTAssertFalse(installer.install().pathProfileChanged)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.dory/bin/docker"), helpers + "/docker")
    }

    func testInstallerFindsBundleHelpersFromDorydExecutable() throws {
        let directory = "/tmp/doryd-cli-env-\(getpid())-\(UUID().uuidString)"
        let home = directory + "/home"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let doryd = try executableFixture(at: helpers + "/doryd")
        for tool in ["docker", "docker-compose", "kubectl", "dory", "dory-doctor", "dory-idle-proxy", "dorydctl"] {
            _ = try executableFixture(at: helpers + "/\(tool)")
        }

        let environment = DorydEnvironment(values: ["DORYD_HOME": home], cwd: directory, executablePath: doryd)
        let result = HostCLIInstaller(environment: environment).install()

        XCTAssertTrue(result.dockerLinked)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.dory/bin/dorydctl"), helpers + "/dorydctl")
    }

    func testPathBlockAppendIsIdempotent() throws {
        let once = try XCTUnwrap(HostCLIInstaller.appendingPathBlock(to: "export FOO=1\n", binDir: "/home/u/.dory/bin"))
        XCTAssertNil(HostCLIInstaller.appendingPathBlock(to: once, binDir: "/home/u/.dory/bin"))
    }

    private func executableFixture(at path: String) throws -> String {
        try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}
