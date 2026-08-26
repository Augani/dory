import Testing
@testable import Dory

struct DoryProcessMemoryTests {
    @Test func classifiesKnownDoryProcesses() {
        #expect(DoryProcessMemorySampler.classify(
            pid: 10,
            name: "Dory",
            path: "/Applications/Dory.app/Contents/MacOS/Dory",
            currentPID: 1
        ) == .app)
        #expect(DoryProcessMemorySampler.classify(pid: 11, name: "doryd", path: "/Applications/Dory.app/Contents/Helpers/doryd", currentPID: 1) == .daemon)
        #expect(DoryProcessMemorySampler.classify(pid: 12, name: "dory-hv", path: "/Applications/Dory.app/Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv", currentPID: 1) == .dockerVM)
        #expect(DoryProcessMemorySampler.classify(pid: 13, name: "dory-vmm", path: "/Applications/Dory.app/Contents/Helpers/dory-vmm", currentPID: 1) == .machineVM)
        #expect(DoryProcessMemorySampler.classify(pid: 14, name: "gvproxy", path: "/Applications/Dory.app/Contents/Helpers/gvproxy", currentPID: 1) == .networking)
        #expect(DoryProcessMemorySampler.classify(pid: 15, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", currentPID: 1) == nil)
    }

    @Test func aggregatesRowsByRoleAndCountsDuplicateApps() {
        let rows = [
            Self.row(.app, pid: 10, bytes: 100),
            Self.row(.app, pid: 11, bytes: 200),
            Self.row(.daemon, pid: 12, bytes: 300),
            Self.row(.machineVM, pid: 13, bytes: 400),
            Self.row(.machineVM, pid: 14, bytes: 500),
        ]

        let snapshot = DoryProcessMemorySampler.snapshot(rows: rows)
        let grouped = snapshot.groupedRows

        #expect(snapshot.totalResidentBytes == 1_500)
        #expect(snapshot.appInstanceCount == 2)
        #expect(snapshot.duplicateAppInstanceCount == 1)
        #expect(grouped.first { $0.role == .app }?.residentBytes == 300)
        #expect(grouped.first { $0.role == .machineVM }?.residentBytes == 900)
        #expect(grouped.first { $0.role == .machineVM }?.name == "2 processes")
    }

    private static func row(_ role: DoryProcessRole, pid: Int32, bytes: UInt64) -> DoryProcessMemoryRow {
        DoryProcessMemoryRow(
            role: role,
            pid: pid,
            name: role.title,
            residentBytes: bytes,
            virtualBytes: bytes * 2,
            path: "/tmp/\(role.rawValue)"
        )
    }
}
