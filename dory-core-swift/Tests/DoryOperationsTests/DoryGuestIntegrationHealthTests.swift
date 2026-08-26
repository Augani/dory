import Testing
@testable import DoryOperations

@Suite("Dory guest integration health")
struct DoryGuestIntegrationHealthTests {
    @Test("resolved running workspace reports exact healthy integrations")
    func healthyResolvedWorkspace() throws {
        let health = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: true,
            sharedFoldersExpected: true,
            agentBuild: "dory-agent/0.4.5",
            agentProtocolVersion: 1,
            agentCapabilities: currentCapabilities
        )

        #expect(health.state == .healthy)
        #expect(health.isValid)
        #expect(health.features.map(\.id.rawValue) == health.features.map(\.id.rawValue).sorted())
        #expect(health.features.first { $0.id == .clipboardText }?.state == .active)
        #expect(health.features.first { $0.id == .fileTransferPull }?.state == .active)
        #expect(health.features.first { $0.id == .snapshotQuiesce }?.negotiatedVersion == 2)
    }

    @Test("stopped workspace is inactive without retaining a stale live handshake")
    func stoppedWorkspace() {
        let health = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: false,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: true,
            sharedFoldersExpected: false,
            agentBuild: "dory-agent/0.4.5",
            agentProtocolVersion: 1,
            agentCapabilities: currentCapabilities
        )

        #expect(health.state == .inactive)
        #expect(health.agentBuild == nil)
        #expect(health.agentProtocolVersion == nil)
        #expect(health.features.allSatisfy { $0.state == .inactive })
        #expect(health.isValid)
    }

    @Test("missing and incompatible tools are distinct fail-closed states")
    func missingAndIncompatibleTools() {
        let missing = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: false,
            sharedFoldersExpected: false,
            agentBuild: nil,
            agentProtocolVersion: nil,
            agentCapabilities: []
        )
        #expect(missing.state == .missingTools)
        #expect(missing.features.first { $0.id == .clockSynchronization }?.state == .unavailable)
        #expect(missing.isValid)

        let efiWithoutGuestTools = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .legacyCompatibility,
            desktopIntegrationsExpected: true,
            sharedFoldersExpected: false,
            agentBuild: "dory-vmm/efi",
            agentProtocolVersion: nil,
            agentCapabilities: []
        )
        #expect(efiWithoutGuestTools.state == .missingTools)
        #expect(efiWithoutGuestTools.agentBuild == nil)
        #expect(efiWithoutGuestTools.agentProtocolVersion == nil)
        #expect(efiWithoutGuestTools.isValid)

        let incompatible = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: false,
            sharedFoldersExpected: false,
            agentBuild: "dory-agent/9.0.0",
            agentProtocolVersion: 9,
            agentCapabilities: currentCapabilities
        )
        #expect(incompatible.state == .incompatible)
        #expect(incompatible.features.filter { $0.provider == .guestAgent }
            .allSatisfy { $0.state == .unavailable })
        #expect(incompatible.isValid)

        let malformed = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: false,
            sharedFoldersExpected: false,
            agentBuild: "dory-agent/0.4.5",
            agentProtocolVersion: 1,
            agentCapabilities: [
                .init(id: "exec", version: 1),
                .init(id: "exec", version: 2),
            ]
        )
        #expect(malformed.state == .incompatible)
        #expect(malformed.isValid)
    }

    @Test("missing required capabilities and stale runtime authority degrade independently")
    func degradedWorkspace() {
        let missingCore = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: false,
            sharedFoldersExpected: false,
            agentBuild: "dory-agent/0.4.5",
            agentProtocolVersion: 1,
            agentCapabilities: currentCapabilities.filter { $0.id != "telemetry" }
        )
        #expect(missingCore.state == .degraded)
        #expect(missingCore.features.first { $0.id == .telemetry }?.state == .unavailable)
        #expect(missingCore.isValid)

        let replanning = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .requiresReplanning,
            desktopIntegrationsExpected: true,
            sharedFoldersExpected: false,
            agentBuild: "dory-agent/0.4.5",
            agentProtocolVersion: 1,
            agentCapabilities: currentCapabilities
        )
        #expect(replanning.state == .degraded)
        #expect(replanning.features.first { $0.id == .displayResize }?.state == .updateRequired)
        #expect(replanning.isValid)
    }

    @Test("resolved authority cannot qualify runtime integrations absent from the pinned plan")
    func resolvedRuntimeFeaturesArePlanBound() {
        let health = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: true,
            clipboardTextExpected: true,
            clipboardImageExpected: false,
            sharedFoldersExpected: true,
            qualifiedRuntimeFeatures: [.gracefulShutdown],
            agentBuild: "dory-agent/0.4.5",
            agentProtocolVersion: 1,
            agentCapabilities: currentCapabilities
        )

        #expect(health.state == .degraded)
        #expect(health.features.first { $0.id == .gracefulShutdown }?.state == .active)
        #expect(health.features.first { $0.id == .displayResize }?.state == .unavailable)
        #expect(health.features.first { $0.id == .clipboardText }?.state == .unavailable)
        #expect(health.features.contains { $0.id == .clipboardImage } == false)
        #expect(health.features.first { $0.id == .sharedFolderMountStatus }?.state == .unavailable)
        #expect(health.isValid)
    }

    @Test("legacy runtime stays visibly compatibility-only")
    func compatibilityWorkspace() {
        let health = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .legacyCompatibility,
            desktopIntegrationsExpected: true,
            sharedFoldersExpected: true,
            agentBuild: "dory-agent/0.4.5",
            agentProtocolVersion: 1,
            agentCapabilities: currentCapabilities
        )

        #expect(health.state == .compatibility)
        #expect(health.features.first { $0.id == .clipboardImage }?.state == .unqualified)
        #expect(health.features.first { $0.id == .clockSynchronization }?.state == .active)
        #expect(health.isValid)
    }

    @Test("invalid wire-shaped health claims are rejected structurally")
    func invalidClaims() throws {
        var health = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: false,
            sharedFoldersExpected: false,
            agentBuild: "dory-agent/0.4.5",
            agentProtocolVersion: 1,
            agentCapabilities: currentCapabilities
        )
        #expect(health.isValid)

        health.features.reverse()
        #expect(!health.isValid)

        health = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: false,
            sharedFoldersExpected: false,
            agentBuild: "dory-agent/0.4.5",
            agentProtocolVersion: 1,
            agentCapabilities: currentCapabilities
        )
        health.features.removeLast()
        #expect(health.isValid)
        #expect(!health.isValid(
            desktopIntegrationsExpected: false,
            clipboardTextExpected: false,
            clipboardImageExpected: false,
            sharedFoldersExpected: false
        ))

        health = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: false,
            sharedFoldersExpected: false,
            agentBuild: "dory-agent/0.4.5",
            agentProtocolVersion: 1,
            agentCapabilities: currentCapabilities
        )
        health.state = .healthy
        let telemetryIndex = try #require(health.features.firstIndex { $0.id == .telemetry })
        health.features[telemetryIndex].state = .unavailable
        health.features[telemetryIndex].negotiatedVersion = nil
        #expect(!health.isValid)

        health = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .legacyCompatibility,
            desktopIntegrationsExpected: true,
            sharedFoldersExpected: false,
            agentBuild: "dory-agent/0.4.5",
            agentProtocolVersion: 1,
            agentCapabilities: currentCapabilities
        )
        let displayIndex = try #require(
            health.features.firstIndex { $0.id == .displayResize }
        )
        health.features[displayIndex].state = .active
        #expect(!health.isValid)
    }

    private var currentCapabilities: [DoryGuestIntegrationNegotiatedCapability] {
        [
            .init(id: "clock-sync", version: 1),
            .init(id: "exec", version: 1),
            .init(id: "exec-stdin", version: 1),
            .init(id: "lifecycle-receipt", version: 1),
            .init(id: "ports-watch", version: 1),
            .init(id: "snapshot-quiesce", version: 2),
            .init(id: "sync-pull", version: 1),
            .init(id: "sync-push", version: 2),
            .init(id: "telemetry", version: 1),
        ]
    }
}

private extension DoryGuestIntegrationHealth {
    static func evaluate(
        machineIsRunning: Bool,
        runtimeAuthority: DoryGuestIntegrationRuntimeAuthority,
        desktopIntegrationsExpected: Bool,
        sharedFoldersExpected: Bool,
        agentBuild: String?,
        agentProtocolVersion: UInt32?,
        agentCapabilities: [DoryGuestIntegrationNegotiatedCapability]
    ) -> Self {
        var qualifiedRuntimeFeatures: Set<DoryGuestIntegrationCapabilityID> = [
            .gracefulShutdown,
        ]
        if desktopIntegrationsExpected {
            qualifiedRuntimeFeatures.formUnion([
                .clipboardImage, .clipboardText, .displayResize,
            ])
        }
        if sharedFoldersExpected {
            qualifiedRuntimeFeatures.formUnion([
                .sharedFolderDiscovery, .sharedFolderMountStatus,
            ])
        }
        return evaluate(
            machineIsRunning: machineIsRunning,
            runtimeAuthority: runtimeAuthority,
            desktopIntegrationsExpected: desktopIntegrationsExpected,
            clipboardTextExpected: desktopIntegrationsExpected,
            clipboardImageExpected: desktopIntegrationsExpected,
            sharedFoldersExpected: sharedFoldersExpected,
            qualifiedRuntimeFeatures: qualifiedRuntimeFeatures,
            agentBuild: agentBuild,
            agentProtocolVersion: agentProtocolVersion,
            agentCapabilities: agentCapabilities
        )
    }
}
