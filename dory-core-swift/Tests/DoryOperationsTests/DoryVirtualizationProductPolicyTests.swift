import Foundation
import Testing
@testable import DoryOperations

@Suite("Three-cell virtualization product policy")
struct DoryVirtualizationProductPolicyTests {
    @Test("product cells map host+guest onto one backend and composition", arguments: [
        (
            DoryGuestPlatform(family: .linux, architecture: .arm64),
            DoryProductCell.linuxARM64Native,
            DoryVirtualizationBackendIdentity.doryHypervisor,
            DoryMachineModelIdentity.armVirtV1,
            DoryExecutionClass.native
        ),
        (
            DoryGuestPlatform(family: .linux, architecture: .x86_64),
            DoryProductCell.linuxX86_64Translated,
            DoryVirtualizationBackendIdentity.doryHypervisor,
            DoryMachineModelIdentity.pcV1,
            DoryExecutionClass.translated
        ),
        (
            DoryGuestPlatform(family: .macOS, architecture: .arm64),
            DoryProductCell.macOSARM64VZMac,
            DoryVirtualizationBackendIdentity.appleVirtualizationFramework,
            DoryMachineModelIdentity.appleVZMacV1,
            DoryExecutionClass.native
        ),
    ])
    func productCellTable(
        guest: DoryGuestPlatform,
        cell: DoryProductCell,
        backend: DoryVirtualizationBackendIdentity,
        machine: DoryMachineModelIdentity,
        execution: DoryExecutionClass
    ) throws {
        let resolved = try DoryVirtualizationProductPolicy.cell(
            hostArchitecture: .arm64,
            guest: guest
        ).get()
        #expect(resolved == cell)
        #expect(resolved.backendIdentity == backend)
        #expect(resolved.platform.machineModel == machine)
        #expect(resolved.executionClass == execution)
        #expect(
            DoryVirtualizationProductPolicy.defaultBackends(
                hostArchitecture: .arm64,
                guest: guest
            ) == [backend]
        )
    }

    @Test("Intel hosts, Windows, and macOS x86_64 are rejected before any route exists")
    func rejectsNonProductCombinations() {
        #expect(
            DoryVirtualizationProductPolicy.cell(
                hostArchitecture: .x86_64,
                guest: DoryGuestPlatform(family: .linux, architecture: .arm64)
            ) == .failure(.unsupportedHostArchitecture(.x86_64))
        )
        #expect(
            DoryVirtualizationProductPolicy.cell(
                hostArchitecture: .unsupported,
                guest: DoryGuestPlatform(family: .linux, architecture: .arm64)
            ) == .failure(.unsupportedHostArchitecture(.unsupported))
        )
        #expect(
            DoryVirtualizationProductPolicy.cell(
                hostArchitecture: .arm64,
                guest: DoryGuestPlatform(family: .windows, architecture: .arm64)
            ) == .failure(.unsupportedGuestFamily(.windows))
        )
        #expect(
            DoryVirtualizationProductPolicy.cell(
                hostArchitecture: .arm64,
                guest: DoryGuestPlatform(family: .macOS, architecture: .x86_64)
            ) == .failure(.unsupportedGuestArchitecture(.x86_64))
        )
        #expect(
            DoryVirtualizationProductPolicy.defaultBackends(
                hostArchitecture: .arm64,
                guest: DoryGuestPlatform(family: .windows, architecture: .x86_64)
            ).isEmpty
        )
    }

    @Test("architecture facts keep requested, detected, host, profile, ABI and tier distinct")
    func architectureFactsDoNotCollapseLabels() throws {
        let guest = DoryGuestPlatform(family: .linux, architecture: .x86_64)
        let cell = try DoryVirtualizationProductPolicy.cell(
            hostArchitecture: .arm64,
            guest: guest
        ).get()
        let facts = DoryVirtualMachineArchitectureFacts.resolving(
            hostArchitecture: .arm64,
            guest: guest,
            detectedMediaArchitecture: .x86_64,
            cell: cell
        )
        #expect(facts.hostArchitecture == .arm64)
        #expect(facts.requestedGuestArchitecture == .x86_64)
        #expect(facts.detectedMediaArchitecture == .x86_64)
        #expect(facts.cpuProfile == .compatibleX8664V1)
        #expect(facts.machineABI == .pcV1)
        #expect(facts.executionTier == .translated)
        #expect(facts.productCell == .linuxX86_64Translated)
    }
}
