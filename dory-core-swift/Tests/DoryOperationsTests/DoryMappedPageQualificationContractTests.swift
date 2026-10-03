import CryptoKit
import Foundation
import Testing
@testable import DoryOperations

@Suite struct DoryMappedPageQualificationContractTests {
    let challenge = UUID(uuidString: "aaaa0000-0000-0000-0000-000000000001")!
    let operation = UUID()

    var authority: DoryRuntimeQualificationFaultAuthority {
        .init(machineID: "campaign-arm-page", operationID: operation,
              resolvedPlanSHA256: String(repeating: "b", count: 64),
              campaignManifestSHA256: String(repeating: "c", count: 64),
              expiresAt: Date().addingTimeInterval(60),
              policy: .init(permittedFaults: [.blockFullFlushNoSpace, .mappedPageRepeatedPermission]))
    }

    func request(_ action: DoryRuntimeQualificationFaultRequest.Action = .arm,
                 kind: DoryRuntimeQualificationFaultKind? = .mappedPageRepeatedPermission,
                 address: UInt64? = 0x4000_4000) -> DoryRuntimeQualificationFaultRequest {
        .init(action: action, machineID: authority.machineID, operationID: operation,
              resolvedPlanSHA256: authority.resolvedPlanSHA256,
              campaignManifestSHA256: authority.campaignManifestSHA256,
              challenge: challenge, kind: kind, guestPhysicalAddress: address)
    }

    func observation() -> DoryRuntimeQualificationFaultObservation {
        var value = DoryRuntimeQualificationFaultObservation(
            challenge: challenge, kind: .mappedPageRepeatedPermission, machineID: authority.machineID,
            operationID: operation, resolvedPlanSHA256: authority.resolvedPlanSHA256,
            campaignManifestSHA256: authority.campaignManifestSHA256, state: .retryEscalated)
        value.guestPhysicalAddress = 0x4000_4000
        value.virtualCPUIndex = 0
        value.instructionAddress = 0x1000
        value.faultExitCount = 17
        value.retryCount = 16
        value.guestException = "synchronous-external-data-abort"
        value.memoryProtectionRestored = true
        return value
    }

    @Test func scratchPatternMatchesTheIndependentGuestProtocolVector() {
        let bytes = DoryMappedPageQualificationChallenge.expectedPage(challenge: challenge)
        #expect(bytes.count == 16_384)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "2523d62477f2315f0f61272bd7d825eeee86b3d7b70855b078c4d1343dce1ecd")
        #expect(bytes != DoryMappedPageQualificationChallenge.expectedPage(challenge: UUID()))
    }

    @Test func onlyMappedPageArmingCarriesAPositiveAlignedAddress() {
        #expect(request().matches(authority))
        for address: UInt64? in [nil, 0, 0x4000_4001] {
            #expect(!request(address: address).matches(authority))
        }
        #expect(!request(kind: .blockFullFlushNoSpace).matches(authority))
        #expect(request(kind: .blockFullFlushNoSpace, address: nil).matches(authority))
        for action in [DoryRuntimeQualificationFaultRequest.Action.observe, .cancel] {
            #expect(!request(action, kind: nil).matches(authority))
            #expect(request(action, kind: nil, address: nil).matches(authority))
        }
    }

    @Test func receiptCannotChangeTheNominatedPageOrFabricateCountsAndOwners() {
        let good = observation()
        #expect(good.isValidRuntimeObservation && good.matches(request()))
        #expect(!good.matches(request(address: 0x4000_8000)))
        for mutation: (inout DoryRuntimeQualificationFaultObservation) -> Void in [
            { $0.retryCount = 15 }, { $0.faultExitCount = 18 },
            { $0.virtualCPUIndex = 8 }, { $0.instructionAddress = nil },
            { $0.memoryProtectionRestored = false }, { $0.guestException = "unknown" },
            { $0.injectedErrno = 28 }, { $0.guestPhysicalAddress = 0x4000_4001 }
        ] {
            var bad = good
            mutation(&bad)
            #expect(!bad.isValidRuntimeObservation)
        }
        var recovered = good
        recovered.state = .cancelled
        #expect(recovered.isValidRuntimeObservation)
        recovered.faultExitCount = 1
        recovered.retryCount = 1
        #expect(!recovered.isValidRuntimeObservation)
    }

    @Test func ordinaryFlushRequestsKeepTheirPreviousWireShape() throws {
        let value = request(kind: .blockFullFlushNoSpace, address: nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(object["guestPhysicalAddress"] == nil)
        #expect(try JSONDecoder().decode(DoryRuntimeQualificationFaultRequest.self,
                                        from: JSONSerialization.data(withJSONObject: object)) == value)
    }
}
