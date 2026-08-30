import Foundation
import Testing
@testable import DoryOperations

@Suite("Compositional virtualization platform resolver")
struct DoryVirtualizationPlatformResolverTests {
    @Test("all four product cells have one exact composition", arguments: [
        (
            DoryGuestPlatform(family: .linux, architecture: .arm64),
            DoryTranslationConsent.notRequired,
            DoryExecutionEngineIdentity.nativeARM64,
            DoryMachineModelIdentity.armVirtV1,
            DoryFirmwareABIIdentity.armVirtV1
        ),
        (
            DoryGuestPlatform(family: .linux, architecture: .x86_64),
            DoryTranslationConsent.explicit,
            DoryExecutionEngineIdentity.x86ToARM64,
            DoryMachineModelIdentity.pcV1,
            DoryFirmwareABIIdentity.pcV1
        ),
        (
            DoryGuestPlatform(family: .macOS, architecture: .arm64),
            DoryTranslationConsent.notRequired,
            DoryExecutionEngineIdentity.vzMac,
            DoryMachineModelIdentity.appleVZMacV1,
            DoryFirmwareABIIdentity.appleVZMacV1
        ),
        (
            DoryGuestPlatform(family: .macOS, architecture: .x86_64),
            DoryTranslationConsent.explicit,
            DoryExecutionEngineIdentity.x86ToARM64,
            DoryMachineModelIdentity.intelMacV1,
            DoryFirmwareABIIdentity.intelMacV1
        ),
    ])
    func resolvesProductCell(
        guest: DoryGuestPlatform,
        consent: DoryTranslationConsent,
        engine: DoryExecutionEngineIdentity,
        machine: DoryMachineModelIdentity,
        firmware: DoryFirmwareABIIdentity
    ) throws {
        let resolution = try DoryVirtualizationPlatformResolver.resolve(
            DoryVirtualizationResolutionRequest(
                hostArchitecture: .arm64,
                guest: guest,
                translationConsent: consent
            )
        ).get()

        #expect(resolution.platform.executionEngine == engine)
        #expect(resolution.platform.machineModel == machine)
        #expect(resolution.platform.firmwareABI == firmware)
        #expect(resolution.supportState == .research)
        #expect(resolution.executionClass == (guest.architecture == .arm64 ? .native : .translated))
    }

    @Test("Intel hosts fail at the resolver boundary")
    func rejectsIntelHostBeforeRouteSelection() {
        let result = DoryVirtualizationPlatformResolver.resolve(
            DoryVirtualizationResolutionRequest(
                hostArchitecture: .x86_64,
                guest: DoryGuestPlatform(family: .linux, architecture: .arm64)
            )
        )

        #expect(result == .failure(.unsupportedHostArchitecture(.x86_64)))
        #expect(result.failure?.reasonCode == .unsupportedHostArchitecture)
    }

    @Test("translation requires explicit consent")
    func requiresTranslationConsent() {
        let result = DoryVirtualizationPlatformResolver.resolve(
            DoryVirtualizationResolutionRequest(
                hostArchitecture: .arm64,
                guest: DoryGuestPlatform(family: .linux, architecture: .x86_64)
            )
        )

        #expect(result == .failure(.translationConsentRequired(.x86_64)))
    }

    @Test("component absence is reported without rerouting")
    func missingComponentsNeverChangeComposition() throws {
        let request = DoryVirtualizationResolutionRequest(
            hostArchitecture: .arm64,
            guest: DoryGuestPlatform(family: .linux, architecture: .x86_64),
            translationConsent: .explicit
        )
        let missing = try DoryVirtualizationPlatformResolver.resolve(request).get()
        var readyRequest = request
        readyRequest.readyComponents = Set(missing.requiredComponents)
        let ready = try DoryVirtualizationPlatformResolver.resolve(readyRequest).get()

        #expect(missing.platform == ready.platform)
        #expect(missing.missingComponents == missing.requiredComponents)
        #expect(ready.missingComponents.isEmpty)
    }

    @Test("persisted platform identities contain no legacy backend identity")
    func encodingContainsOnlyCompositionalIdentities() throws {
        let resolution = try DoryVirtualizationPlatformResolver.resolve(
            DoryVirtualizationResolutionRequest(
                hostArchitecture: .arm64,
                guest: DoryGuestPlatform(family: .linux, architecture: .x86_64),
                translationConsent: .explicit
            )
        ).get()
        let json = String(decoding: try JSONEncoder().encode(resolution.platform), as: UTF8.self)

        #expect(json.contains("dory.dbt.x86-to-arm64@1"))
        #expect(json.contains("dory.pc@1"))
        #expect(!json.contains("qemu"))
        #expect(!json.contains("backend"))
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
