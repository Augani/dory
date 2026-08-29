import Foundation
import Testing
@testable import dory_hv

@Suite("Desktop signal event relay")
struct DesktopSignalEventRelayTests {
    @Test("signal callbacks hop from their dispatch queue to the main actor")
    func signalCallbackDoesNotAssumeTheMainExecutor() async {
        await withCheckedContinuation { continuation in
            let handler = DesktopSignalEventRelay.makeHandler {
                #expect(Thread.isMainThread)
                continuation.resume()
            }
            DispatchQueue(label: "dev.dory.tests.desktop-signal-relay").async {
                handler()
            }
        }
    }
}
