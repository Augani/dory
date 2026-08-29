import Foundation
import Testing

struct ReleaseGuestKernelGateContractTests {
    @Test func releasePackagingGateRejectsUnqualifiedKernelSets() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let testScript = repositoryRoot
            .appendingPathComponent("guest/kernel/test-release-package-gate.sh")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [testScript.path]
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let result = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        #expect(process.terminationStatus == 0, "\(result)")
        #expect(result.contains("release guest-kernel gate tests passed"))
    }
}
