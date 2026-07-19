import Foundation
import Testing
@testable import Dory

struct LocalDorydCapabilityTests {
    @Test func localToolsCatalogExposesOnlyImplementedLocalCommands() throws {
        let capabilities = AppStore.localDorydCapabilityCatalog
        let ids = capabilities.map(\.id)

        #expect(Set(ids) == ["support-bundle", "agent-guide", "mcp", "sandbox", "wait", "events"])
        #expect(ids.count == Set(ids).count)

        for capability in capabilities {
            #expect(capability.command.hasPrefix("dory "))
            #expect(!capability.title.localizedCaseInsensitiveContains("Apple"))
            #expect(!capability.summary.localizedCaseInsensitiveContains("Apple"))
            #expect(!capability.command.localizedCaseInsensitiveContains("apple"))
            #expect(capability.status == "Stable")
        }

        let stableIDs = Set(capabilities.filter { $0.status == "Stable" }.map(\.id))
        #expect(stableIDs == ["support-bundle", "agent-guide", "mcp", "sandbox", "wait", "events"])

        let support = try #require(capabilities.first { $0.id == "support-bundle" })
        #expect(support.command == "dory support bundle")

        let sandbox = try #require(capabilities.first { $0.id == "sandbox" })
        #expect(sandbox.status == "Stable")
        #expect(sandbox.summary.contains("non-root"))
        #expect(sandbox.summary.contains("resource caps"))
    }

    @Test func settingsAndRuntimeLabelsDoNotAdvertiseUnsupportedAppleRuntime() {
        #expect(SettingsTab.allCases.contains(.localTools))
        #expect(SettingsTab.localTools.label == "Local Tools")
        let activeRuntimeLabels = [
            RuntimeKind.docker.displayName,
            RuntimeKind.sharedVM.displayName,
            RuntimeKind.disconnected.displayName,
            RuntimeKind.mock.displayName,
        ]
        #expect(!activeRuntimeLabels.contains { $0.localizedCaseInsensitiveContains("Unsupported") })
        #expect(!activeRuntimeLabels.contains { $0.localizedCaseInsensitiveContains("Apple") })
    }
}
