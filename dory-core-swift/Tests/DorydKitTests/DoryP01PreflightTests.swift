import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("P01 public-operation preflight")
struct DoryP01PreflightTests {
    @Test("unsupported guests cannot create machine state", arguments: [
        DoryGuestPlatform(family: .macOS, architecture: .x86_64),
        DoryGuestPlatform(family: .windows, architecture: .arm64),
        DoryGuestPlatform(family: .windows, architecture: .x86_64),
    ])
    func unsupportedCreateDoesNotMutate(guest: DoryGuestPlatform) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-p01-preflight-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = MachineManager(diagnosticConfiguration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/true", stateDirectory: root.path + "/machines"
        ))
        func tree() -> [String] {
            (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
        }
        let before = tree()
        var machine = DoryMachineConfiguration(id: "rejected", kernelPath: "/missing", rootfsPath: "/missing")
        machine.guestFamily = guest.family
        machine.guestArchitecture = guest.architecture
        do {
            _ = try manager.create(machine)
            Issue.record("Unsupported create succeeded")
        } catch {
            #expect(String(describing: error).contains("unsupported virtual machine"))
        }
        #expect(tree() == before)
        #expect(manager.status(id: "rejected") == nil)
    }
}
