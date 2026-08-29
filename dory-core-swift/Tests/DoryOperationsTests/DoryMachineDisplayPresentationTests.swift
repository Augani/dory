import Foundation
import Testing
@testable import DoryOperations

@Suite("Host display presentation")
struct DoryMachineDisplayPresentationTests {
    @Test("dedicated assignments are exact and canonical")
    func canonicalAssignment() {
        let first = "00000000-0000-0000-0000-000000000001"
        let second = "00000000-0000-0000-0000-000000000002"
        let presentation = DoryMachineDisplayPresentation(assignments: [
            .init(guestDisplayID: "display-1", mode: .dedicatedFullscreen, hostDisplayUUID: second),
            .init(guestDisplayID: "display-0", mode: .dedicatedFullscreen, hostDisplayUUID: first),
        ])
        #expect(presentation.isValid)
        #expect(presentation.canonicalized.assignments.map(\.guestDisplayID)
            == ["display-0", "display-1"])
    }

    @Test("one physical monitor cannot be owned by two guest displays")
    func rejectsDuplicateMonitor() {
        let uuid = "00000000-0000-0000-0000-000000000001"
        let presentation = DoryMachineDisplayPresentation(assignments: [
            .init(guestDisplayID: "display-0", mode: .dedicatedFullscreen, hostDisplayUUID: uuid),
            .init(guestDisplayID: "display-1", mode: .dedicatedFullscreen, hostDisplayUUID: uuid),
        ])
        #expect(!presentation.isValid)
    }

    @Test("windowed mode cannot smuggle a host monitor identity")
    func rejectsWindowedMonitor() {
        #expect(!DoryMachineDisplayPresentation(assignments: [
            .init(
                guestDisplayID: "display-0",
                mode: .windowed,
                hostDisplayUUID: "00000000-0000-0000-0000-000000000001"
            ),
        ]).isValid)
    }
}
