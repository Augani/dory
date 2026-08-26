import Testing
@testable import dory_hv

@Suite struct DesktopGenericGuestShareReadinessTests {
    @Test func mountedSharesAreProvenExplicitlyInReadiness() {
        #expect(
            DesktopMode.GenericGuestShareReadiness.mounted(2).detailSuffix
                == "; 2 virtio-fs share(s) proven mounted by Dory Tools"
        )
        #expect(DesktopMode.GenericGuestShareReadiness.mounted(0).detailSuffix.isEmpty)
    }

    @Test func missingCapabilityNamesEveryUnavailableShare() {
        let detail = DesktopMode.GenericGuestShareReadiness
            .unavailableMissingCapability(["home", "workspace"])
            .detailSuffix

        #expect(detail.contains("does not advertise virtiofs-mount@1"))
        #expect(detail.hasSuffix("home, workspace"))
    }

    @Test func missingToolsNeverImplyThatRequestedSharesMounted() {
        let detail = DesktopMode.GenericGuestShareReadiness
            .unavailableMissingTools(["workspace"])
            .detailSuffix

        #expect(detail.contains("unavailable because guest tools are not installed"))
        #expect(detail.hasSuffix("workspace"))
        #expect(DesktopMode.GenericGuestShareReadiness
            .unavailableMissingTools([]).detailSuffix.isEmpty)
    }
}
