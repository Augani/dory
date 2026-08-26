import Testing
@testable import dory_hv

@Suite
struct DesktopGuestReadinessBoundaryTests {
    private enum Step: Equatable {
        case prepare
        case wait
        case publish
    }

    private enum BoundaryFailure: Error, Equatable {
        case rendererReadiness
    }

    @Test func managedGuestPreparesBeforeWaitingAndPublishing() {
        var steps = [Step]()
        let expected = 37

        DesktopGuestReadinessBoundary.complete(
            genericGuest: false,
            prepare: {
                steps.append(.prepare)
                return expected
            },
            waitForSynchronizedPresentation: {
                #expect(steps == [.prepare])
                steps.append(.wait)
            },
            publish: { prepared in
                #expect(prepared == expected)
                steps.append(.publish)
            }
        )

        #expect(steps == [.prepare, .wait, .publish])
    }

    @Test func genericGuestRetainsRendererFirstOrdering() {
        var steps = [Step]()

        DesktopGuestReadinessBoundary.complete(
            genericGuest: true,
            prepare: {
                #expect(steps == [.wait])
                steps.append(.prepare)
            },
            waitForSynchronizedPresentation: {
                steps.append(.wait)
            },
            publish: { _ in
                steps.append(.publish)
            }
        )

        #expect(steps == [.wait, .prepare, .publish])
    }

    @Test func managedRendererFailureAfterPreparationPreventsPublication() {
        var steps = [Step]()

        #expect(throws: BoundaryFailure.rendererReadiness) {
            try DesktopGuestReadinessBoundary.complete(
                genericGuest: false,
                prepare: {
                    steps.append(.prepare)
                },
                waitForSynchronizedPresentation: {
                    steps.append(.wait)
                    throw BoundaryFailure.rendererReadiness
                },
                publish: { _ in
                    steps.append(.publish)
                }
            )
        }

        #expect(steps == [.prepare, .wait])
    }

    @Test func genericRendererFailurePreventsPreparationAndPublication() {
        var steps = [Step]()

        #expect(throws: BoundaryFailure.rendererReadiness) {
            try DesktopGuestReadinessBoundary.complete(
                genericGuest: true,
                prepare: {
                    steps.append(.prepare)
                },
                waitForSynchronizedPresentation: {
                    steps.append(.wait)
                    throw BoundaryFailure.rendererReadiness
                },
                publish: { _ in
                    steps.append(.publish)
                }
            )
        }

        #expect(steps == [.wait])
    }
}
