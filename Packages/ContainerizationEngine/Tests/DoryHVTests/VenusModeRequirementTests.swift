@testable import DoryHV
import Testing

struct VenusModeRequirementTests {
    private struct RendererUnavailable: Error {}

    @Test func requestedVenusNeverTurnsRendererFailureIntoHeadlessSuccess() {
        do {
            let _: String = try VenusModeRequirement.require {
                throw RendererUnavailable()
            }
            Issue.record("Venus renderer failure unexpectedly succeeded")
        } catch let VMError.invalidConfiguration(reason) {
            #expect(reason.contains("gpu=venus"))
            #expect(reason.contains("refusing a headless fallback"))
        } catch {
            Issue.record("unexpected Venus failure: \(error)")
        }
    }

    @Test func requestedVenusReturnsAttachedRendererValue() throws {
        let value = try VenusModeRequirement.require { "renderer" }
        #expect(value == "renderer")
    }

    @Test func requestedVenusAsyncNeverTurnsRendererFailureIntoHeadlessSuccess() async {
        do {
            let _: String = try await VenusModeRequirement.require {
                throw RendererUnavailable()
            }
            Issue.record("Venus renderer failure unexpectedly succeeded")
        } catch let VMError.invalidConfiguration(reason) {
            #expect(reason.contains("gpu=venus"))
            #expect(reason.contains("refusing a headless fallback"))
        } catch {
            Issue.record("unexpected Venus failure: \(error)")
        }
    }
}
