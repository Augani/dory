import Testing
@testable import DoryOperations

@Suite("Desktop helper exit status")
struct DoryDesktopHelperExitStatusTests {
    @Test("renderer candidate failures have one stable non-generic status")
    func stableRendererCandidateFailureStatus() {
        #expect(DoryDesktopHelperExitStatus.generalFailure.rawValue == 1)
        #expect(DoryDesktopHelperExitStatus.rendererCandidateFailure.rawValue == 86)
    }
}
