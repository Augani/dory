import Foundation
import Testing
@testable import DoryOperations

@Suite("Virtual machine definition")
struct DoryVirtualMachineDefinitionTests {
    private let gibibyte: UInt64 = 1_073_741_824
    private let nowMilliseconds: Int64 = 1_787_200_000_000

    @Test("schema 3 round trips with stable resolver and timestamp representations")
    func currentRoundTrip() throws {
        let original = linuxDefinition()
        #expect(original.isValid)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(DoryVirtualMachineDefinition.self, from: data)
        #expect(decoded == original)

        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"schemaVersion\":3"))
        #expect(json.contains("\"virtualHardwareABIVersion\":1"))
        #expect(json.contains("\"createdAtUnixMilliseconds\":1787200000000"))
        #expect(json.contains("\"namespace\":\"boot\""))
        #expect(json.contains("\"clipboardPolicy\""))
        #expect(json.contains("\"guestIdentityIntent\""))
        #expect(json.contains("\"backingScaleFactor\":2"))
        #expect(json.contains("\"guestUIScaleFactor\":2"))
        #expect(!json.contains("\"bootMedia\""))
        #expect(!json.contains("artifactID"))
        #expect(!json.contains("hostLocationID"))
    }

    @Test("schema 2 records migrate storage provenance and typed-intent defaults")
    func additiveSchemaTwoMigration() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(linuxDefinition())
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "guestIdentityIntent")
        object.removeValue(forKey: "clipboardPolicy")
        object["schemaVersion"] = 2
        var storage = try #require(object["storage"] as? [[String: Any]])
        for index in storage.indices { storage[index].removeValue(forKey: "source") }
        object["storage"] = storage
        let oldSchemaTwo = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            DoryVirtualMachineDefinition.self,
            from: oldSchemaTwo
        )
        #expect(decoded.guestIdentityIntent == .unspecified)
        #expect(decoded.clipboardPolicy == .legacyDesktop(.bidirectional))
        #expect(decoded.schemaVersion == 3)
        #expect(decoded.storage.allSatisfy { $0.source == .userProvided })
        #expect(decoded.display.backingScaleFactor == 2)
        #expect(decoded.display.guestUIScaleFactor == 2)
        #expect(decoded.isValid)
    }

    @Test("disconnected networking is durable typed intent")
    func disconnectedNetworkRoundTrip() throws {
        var original = linuxDefinition()
        original.networkMode = .disconnected

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DoryVirtualMachineDefinition.self, from: data)

        #expect(decoded.networkMode == .disconnected)
        #expect(decoded == original)
        #expect(decoded.isValid)
    }

    @Test("sandbox lifecycle and credential grants are closed bounded intent")
    func sandboxPolicyValidation() throws {
        var definition = linuxDefinition()
        definition.workload = .server
        definition.graphics = DoryVMGraphicsPolicy(acceptableLevels: [.none])
        definition.display = .disabled
        definition.audio = DoryVMAudioConfiguration(
            inputEnabled: false,
            outputEnabled: false
        )
        definition.input = DoryVMInputConfiguration(
            keyboardEnabled: false,
            pointerEnabled: false
        )
        definition.integrations = [.clockSynchronization, .gracefulShutdown]
        definition.clipboardPolicy = .disabled
        definition.sandboxPolicy = DoryVMSandboxPolicy(
            expiresAtUnixSeconds: 1_900_000_000,
            sshAgentAccess: .granted,
            profile: .agentReady,
            tools: [.agentCore, .node],
            baselineSnapshotID: "dory-agent-ready-baseline-v1"
        )
        #expect(definition.isValid)

        let encoded = try JSONEncoder().encode(definition)
        let decoded = try JSONDecoder().decode(
            DoryVirtualMachineDefinition.self,
            from: encoded
        )
        #expect(decoded == definition)
        #expect(decoded.sandboxPolicy?.sshAgentAccess == .granted)

        definition.sandboxPolicy?.tools = [.node, .agentCore]
        #expect(has(.invalidSandboxPolicy, "sandboxPolicy", in: definition.validate()))
        definition.sandboxPolicy?.tools = [.agentCore, .node]
        definition.sandboxPolicy?.baselineSnapshotID = "../host"
        #expect(has(.invalidSandboxPolicy, "sandboxPolicy", in: definition.validate()))
        definition.sandboxPolicy?.baselineSnapshotID = "dory-agent-ready-baseline-v1"
        definition.display = DoryVMDisplayConfiguration()
        #expect(has(
            .sandboxPolicyIncompatibleWithGuest,
            "sandboxPolicy",
            in: definition.validate()
        ))
    }

    @Test("guest identity and clipboard policies are bounded typed intent")
    func guestIdentityAndClipboardValidation() {
        var definition = linuxDefinition()
        definition.guestIdentityIntent = DoryVMGuestIdentityIntent(
            account: DoryVMGuestAccountIntent(username: "developer", numericUserID: 1_000),
            desktop: DoryVMDesktopIdentityIntent(
                distributionIdentifier: "ubuntu",
                displayName: "Ubuntu",
                version: "24.04 LTS",
                desktopEnvironment: "GNOME"
            )
        )
        definition.clipboardPolicy = DoryVMClipboardPolicy(
            text: .hostToGuest,
            image: .guestToHost,
            files: .off
        )
        #expect(definition.isValid)
        #expect(definition.clipboardPolicy.text.allowsHostToGuest)
        #expect(!definition.clipboardPolicy.text.allowsGuestToHost)

        definition.guestIdentityIntent.account?.username = "../host"
        #expect(has(
            .invalidGuestIdentityIntent,
            "guestIdentityIntent.account.username",
            in: definition.validate()
        ))
        definition.guestIdentityIntent.account?.username = "developer"
        definition.guestIdentityIntent.account?.numericUserID = 99
        #expect(has(
            .invalidGuestIdentityIntent,
            "guestIdentityIntent.account.numericUserID",
            in: definition.validate()
        ))
        definition.guestIdentityIntent.account?.numericUserID = 100
        #expect(!has(
            .invalidGuestIdentityIntent,
            "guestIdentityIntent.account.numericUserID",
            in: definition.validate()
        ))
        definition.guestIdentityIntent.account?.numericUserID = 60_000
        #expect(!has(
            .invalidGuestIdentityIntent,
            "guestIdentityIntent.account.numericUserID",
            in: definition.validate()
        ))
        definition.guestIdentityIntent.account?.numericUserID = 60_001
        #expect(has(
            .invalidGuestIdentityIntent,
            "guestIdentityIntent.account.numericUserID",
            in: definition.validate()
        ))
        definition.guestIdentityIntent.account?.numericUserID = 1_000
        definition.guestIdentityIntent.desktop?.distributionIdentifier = "Ubuntu/../../host"
        #expect(has(
            .invalidGuestIdentityIntent,
            "guestIdentityIntent.desktop.distributionIdentifier",
            in: definition.validate()
        ))
        definition.guestIdentityIntent.desktop?.distributionIdentifier = "ubuntu"
        definition.guestIdentityIntent.desktop?.version = "https://token.invalid/secret"
        #expect(has(
            .invalidGuestIdentityIntent,
            "guestIdentityIntent.desktop.version",
            in: definition.validate()
        ))

        definition.guestIdentityIntent.desktop?.version = "a"
            + String(repeating: "\u{0301}", count: 128)
        #expect(has(
            .invalidGuestIdentityIntent,
            "guestIdentityIntent.desktop.version",
            in: definition.validate()
        ))

        definition.guestIdentityIntent.desktop?.version = "24.04"
        definition.integrations.removeAll { $0 == .clipboard }
        #expect(has(
            .clipboardPolicyRequiresIntegration,
            "clipboardPolicy",
            in: definition.validate()
        ))

        for family in [DoryGuestFamily.windows, .macOS] {
            var nonLinux = installerDefinition(family: family)
            nonLinux.guestIdentityIntent = DoryVMGuestIdentityIntent(
                account: DoryVMGuestAccountIntent(username: "developer", numericUserID: 1_000)
            )
            #expect(has(
                .guestIdentityIncompatibleWithGuest,
                "guestIdentityIntent",
                in: nonLinux.validate()
            ))
        }
    }

    @Test("oldest schema 1 golden JSON migrates deterministically")
    func oldestSchemaMigration() throws {
        let golden = Data(#"""
        {
          "schemaVersion": 1,
          "identity": {"id":"legacy-vm","name":"Legacy Installer"},
          "guest": {"family":"linux","architecture":"arm64"},
          "workload": "installer",
          "bootMedia": {
            "role":"installer","kind":"installer-iso","source":"user-provided",
            "artifactID":"install:ubuntu-24.04"
          },
          "backendPreference": {"mode":"automatic"},
          "graphics": {"desiredLevel":"host-accelerated-display","allowsFallback":true},
          "resources": {"virtualCPUCount":4,"memoryBytes":8589934592,"diskBytes":68719476736},
          "storage": [{
            "id":"system","role":"system","artifactID":"disk:legacy-system",
            "capacityBytes":68719476736,"readOnly":false
          }],
          "networkMode":"shared-nat",
          "display":{"enabled":true,"widthPixels":1920,"heightPixels":1080,"pixelsPerInch":110},
          "audio":{"inputEnabled":false,"outputEnabled":true},
          "input":{"keyboardEnabled":true,"pointerEnabled":true},
          "shares":[],
          "integrations":["dynamic-display","graceful-shutdown"],
          "lifecycle":{"revision":1,"createdAt":721692800,"updatedAt":721692800}
        }
        """#.utf8)

        let migrated = try JSONDecoder().decode(DoryVirtualMachineDefinition.self, from: golden)
        #expect(migrated.schemaVersion == 3)
        #expect(migrated.virtualHardwareABIVersion == 1)
        #expect(migrated.workload == .desktop)
        #expect(migrated.boot.phase == .install)
        #expect(migrated.boot.order == ["installer"])
        #expect(migrated.boot.devices[0].artifact == reference("install", "ubuntu-24.04"))
        #expect(migrated.graphics.acceptableLevels == [.hostAcceleratedDisplay, .software])
        #expect(migrated.storage[0].source == .userProvided)
        #expect(migrated.lifecycle.createdAtUnixMilliseconds == 1_700_000_000_000)
        #expect(migrated.display.backingScaleFactor == 2)
        #expect(migrated.display.guestUIScaleFactor == 2)
        #expect(migrated.isValid)

        let upgraded = try JSONEncoder().encode(migrated)
        let upgradedJSON = try #require(String(data: upgraded, encoding: .utf8))
        #expect(upgradedJSON.contains("\"schemaVersion\":3"))
        #expect(upgradedJSON.contains("createdAtUnixMilliseconds"))
        #expect(!upgradedJSON.contains("\"bootMedia\""))
    }

    @Test("install and live phases are independent from desktop or server workload")
    func bootPhaseIndependentFromWorkload() {
        let desktopInstaller = installerDefinition(family: .linux, workload: .desktop)
        let serverInstaller = installerDefinition(family: .windows, workload: .server)
        var liveWorkspace = installerDefinition(family: .linux, workload: .desktop)
        liveWorkspace.boot.phase = .live
        liveWorkspace.storage = []

        #expect(desktopInstaller.isValid)
        #expect(serverInstaller.isValid)
        #expect(liveWorkspace.isValid)

        var legacy = desktopInstaller
        legacy.workload = .installer
        #expect(has(.legacyInstallerWorkload, "workload", in: legacy.validate()))
    }

    @Test("recovery and boot order are explicit")
    func bootOrderAndRecovery() {
        var definition = recoveryDefinition()
        #expect(definition.isValid)

        definition.boot.order = ["system", "recovery"]
        #expect(has(.invalidBootPhase, "boot.phase", in: definition.validate()))

        definition.boot.order = ["recovery", "missing"]
        #expect(has(.invalidBootOrder, "boot.order", in: definition.validate()))

        definition.boot.order = ["recovery", "system"]
        definition.boot.devices[1].id = "recovery"
        #expect(has(
            .duplicateBootDeviceIdentifier,
            "boot.devices[1].id",
            in: definition.validate()
        ))
    }

    @Test("boot attachment role and removability are validated")
    func bootAttachmentInvariants() {
        var definition = installerDefinition(family: .linux)
        definition.boot.devices[0].removable = false
        #expect(has(
            .invalidBootAttachment,
            "boot.devices[0].removable",
            in: definition.validate()
        ))

        definition.boot.devices[0].removable = true
        definition.boot.devices[0].role = .system
        #expect(has(.bootMediaRoleMismatch, "boot.devices[0].role", in: definition.validate()))
        #expect(has(.invalidBootPhase, "boot.phase", in: definition.validate()))
    }

    @Test("guest families reject incompatible media", arguments: [
        (DoryGuestFamily.linux, DoryBootMediaKind.macOSRestoreImage),
        (DoryGuestFamily.windows, DoryBootMediaKind.installedLinuxBootBundle),
        (DoryGuestFamily.macOS, DoryBootMediaKind.installerISO),
    ])
    func guestMediaCompatibility(family: DoryGuestFamily, kind: DoryBootMediaKind) {
        var definition = linuxDefinition()
        definition.guest.family = family
        definition.boot.devices[0].kind = kind
        #expect(has(
            .bootMediaIncompatibleWithGuest,
            "boot.devices[0].kind",
            in: definition.validate()
        ))
    }

    @Test("Windows and macOS media cannot claim Dory redistribution")
    func proprietaryMediaProvenance() {
        var windows = installerDefinition(family: .windows)
        windows.boot.devices[0].source = .bundledByDory
        var macOS = installerDefinition(family: .macOS)
        macOS.boot.devices[0].source = .bundledByDory

        #expect(has(.guestMediaCannotBeBundled, "boot.devices[0].source", in: windows.validate()))
        #expect(has(.guestMediaCannotBeBundled, "boot.devices[0].source", in: macOS.validate()))
    }

    @Test("schema identity lifecycle and positive resources are validated")
    func foundationalInvariants() {
        var definition = linuxDefinition()
        definition.schemaVersion = 99
        definition.virtualHardwareABIVersion = 2
        definition.identity = DoryVirtualMachineIdentity(id: " ", name: "\n")
        definition.resources = DoryVMResourceRequest(
            virtualCPUCount: 0,
            memoryBytes: 0,
            diskBytes: 0
        )
        definition.lifecycle = DoryVMLifecycleMetadata(
            revision: 0,
            createdAtUnixMilliseconds: 0,
            updatedAtUnixMilliseconds: -1
        )

        let issues = definition.validate()
        #expect(has(.unsupportedSchemaVersion, "schemaVersion", in: issues))
        #expect(has(.unsupportedVirtualHardwareABIVersion, "virtualHardwareABIVersion", in: issues))
        #expect(has(.emptyIdentifier, "identity.id", in: issues))
        #expect(has(.emptyName, "identity.name", in: issues))
        #expect(has(.nonPositiveResource, "resources.virtualCPUCount", in: issues))
        #expect(has(.nonPositiveResource, "resources.memoryBytes", in: issues))
        #expect(has(.nonPositiveResource, "resources.diskBytes", in: issues))
        #expect(has(.invalidLifecycleMetadata, "lifecycle", in: issues))
    }

    @Test("machine identifiers match the launch-safe MachineManager contract")
    func machineIdentifierContract() {
        for invalidID in [
            "-starts-with-dash", "contains+plus", "contains space", "é",
            String(repeating: "a", count: 64),
        ] {
            var definition = linuxDefinition()
            definition.identity.id = invalidID
            #expect(has(.invalidIdentifier, "identity.id", in: definition.validate()))
        }
    }

    @Test("resolver references reject paths URLs controls and token-like values")
    func hostileResolverReferences() {
        let hostile = [
            reference("artifact", "/Users/me/image.iso"),
            reference("artifact", "https://example.com/image.iso"),
            reference("artifact", "C:\\images\\disk.raw"),
            reference("artifact", "name\u{001F}control"),
            reference("artifact", "sk-proj-123456"),
            reference("artifact", "ghp_123456"),
            reference("artifact", "eyJhbGciOiJIUzI1NiJ9"),
            reference("Bad-Namespace", "image"),
            reference("artifact", String(repeating: "a", count: 65)),
        ]

        for hostileReference in hostile {
            var boot = linuxDefinition()
            boot.boot.devices[0].artifact = hostileReference
            #expect(has(
                .invalidResolverReference,
                "boot.devices[0].artifact",
                in: boot.validate()
            ))

            var share = linuxDefinition()
            share.shares[0].hostLocation = hostileReference
            #expect(has(
                .invalidResolverReference,
                "shares[0].hostLocation",
                in: share.validate()
            ))
        }
    }

    @Test("storage identifiers capacities and one system disk are enforced")
    func storageInvariants() {
        var definition = linuxDefinition()
        definition.storage.append(DoryVMStorageAttachment(
            id: "system",
            role: .system,
            artifact: reference("disk", "duplicate"),
            capacityBytes: 0,
            readOnly: true
        ))
        let issues = definition.validate()
        #expect(has(.duplicateAttachmentIdentifier, "storage[1].id", in: issues))
        #expect(has(.nonPositiveAttachmentCapacity, "storage[1].capacityBytes", in: issues))
        #expect(has(.multipleSystemDisks, "storage", in: issues))

        definition.storage = []
        #expect(has(.missingSystemDisk, "storage", in: definition.validate()))
    }

    @Test("artifact reuse is allowed only when every occurrence is read-only")
    func storageArtifactAliasing() {
        let shared = reference("disk", "shared-data")

        var readWriteThenReadOnly = linuxDefinition()
        readWriteThenReadOnly.storage.append(storage("data-rw", artifact: shared, readOnly: false))
        readWriteThenReadOnly.storage.append(storage("data-ro", artifact: shared, readOnly: true))
        #expect(has(
            .duplicateWritableStorageArtifactIdentity,
            "storage[2].artifact",
            in: readWriteThenReadOnly.validate()
        ))

        var readOnlyThenReadWrite = linuxDefinition()
        readOnlyThenReadWrite.storage.append(storage("data-ro", artifact: shared, readOnly: true))
        readOnlyThenReadWrite.storage.append(storage("data-rw", artifact: shared, readOnly: false))
        #expect(has(
            .duplicateWritableStorageArtifactIdentity,
            "storage[2].artifact",
            in: readOnlyThenReadWrite.validate()
        ))

        var allReadOnly = linuxDefinition()
        allReadOnly.storage.append(storage("data-ro-1", artifact: shared, readOnly: true))
        allReadOnly.storage.append(storage("data-ro-2", artifact: shared, readOnly: true))
        #expect(!allReadOnly.validate().contains {
            $0.code == .duplicateWritableStorageArtifactIdentity
        })
        #expect(allReadOnly.isValid)
    }

    @Test("system disk agrees with resource and virtual-disk boot identity")
    func systemDiskAgreement() {
        var definition = linuxDefinition(kind: .virtualDisk)
        definition.storage[0].readOnly = true
        definition.storage[0].capacityBytes = 63 * gibibyte
        definition.storage[0].artifact = reference("disk", "other")

        let issues = definition.validate()
        #expect(has(.readOnlySystemDisk, "storage[0].readOnly", in: issues))
        #expect(has(.systemDiskCapacityMismatch, "storage[0].capacityBytes", in: issues))
        #expect(has(.bootDiskArtifactMismatch, "boot.devices", in: issues))
    }

    @Test("system boot validation follows boot order and rejects ambiguous system devices")
    func systemBootResolutionUsesPersistedOrder() {
        let systemA = DoryVMBootMediaReference(
            id: "system-a",
            role: .system,
            kind: .virtualDisk,
            source: .userProvided,
            artifact: reference("disk", "system-a"),
            removable: false
        )
        let systemB = DoryVMBootMediaReference(
            id: "system-b",
            role: .system,
            kind: .virtualDisk,
            source: .userProvided,
            artifact: reference("disk", "system-b"),
            removable: false
        )

        var arrayAOrderB = linuxDefinition(kind: .virtualDisk)
        arrayAOrderB.storage[0].artifact = systemA.artifact
        arrayAOrderB.boot.devices = [systemA, systemB]
        arrayAOrderB.boot.order = [systemB.id, systemA.id]
        let arrayAOrderBIssues = arrayAOrderB.validate()
        #expect(has(.multipleSystemBootDevices, "boot.devices", in: arrayAOrderBIssues))
        #expect(has(.bootDiskArtifactMismatch, "boot.devices", in: arrayAOrderBIssues))

        var arrayBOrderA = arrayAOrderB
        arrayBOrderA.boot.devices = [systemB, systemA]
        arrayBOrderA.boot.order = [systemA.id, systemB.id]
        let arrayBOrderAIssues = arrayBOrderA.validate()
        #expect(has(.multipleSystemBootDevices, "boot.devices", in: arrayBOrderAIssues))
        #expect(!has(.bootDiskArtifactMismatch, "boot.devices", in: arrayBOrderAIssues))
    }

    @Test("Unix mount paths are canonical and unique")
    func unixSharePaths() {
        for unsafePath in [
            "relative/path", "/srv/../secret", "/srv//source", "/srv/source/", "//srv/source",
        ] {
            var definition = linuxDefinition()
            definition.shares[0].guestMountPath = unsafePath
            #expect(has(.unsafeGuestMountPath, "shares[0].guestMountPath", in: definition.validate()))
        }

        var duplicate = linuxDefinition()
        duplicate.shares.append(share("source-copy", path: "/workspace/source"))
        #expect(has(.duplicateGuestMountPath, "shares[1].guestMountPath", in: duplicate.validate()))
    }

    @Test("Windows paths reject aliases and unsafe device components")
    func windowsSharePaths() {
        var definition = installerDefinition(family: .windows)
        definition.shares = [share("source", path: "C:\\Workspace\\Source")]
        #expect(definition.isValid)

        definition.shares.append(share("source-copy", path: "c:\\workspace\\source"))
        #expect(has(.duplicateGuestMountPath, "shares[1].guestMountPath", in: definition.validate()))
        definition.shares.removeLast()

        for unsafePath in [
            "Workspace\\Source", "C:\\Workspace\\..\\Secret", "C:/Workspace/Source",
            "\\\\server\\share", "C:\\Workspace\\CON.txt", "C:\\Workspace\\CON .txt",
            "C:\\Workspace\\PRN.data", "C:\\Workspace\\AUX.log", "C:\\Workspace\\NUL",
            "C:\\Workspace\\COM1.txt", "C:\\Workspace\\LPT9.log",
            "C:\\Workspace\\trailing.", "C:\\Workspace\\trailing ",
            "C:\\Workspace\\control\u{001F}char",
        ] {
            definition.shares[0].guestMountPath = unsafePath
            #expect(has(.unsafeGuestMountPath, "shares[0].guestMountPath", in: definition.validate()))
        }
    }

    @Test("graphics and backend preferences are explicit structural contracts")
    func graphicsAndBackendPolicy() {
        var definition = linuxDefinition()
        definition.graphics = DoryVMGraphicsPolicy(acceptableLevels: [])
        #expect(has(.emptyGraphicsPolicy, "graphics.acceptableLevels", in: definition.validate()))

        definition.graphics = DoryVMGraphicsPolicy(acceptableLevels: [.software, .software])
        #expect(has(
            .duplicateGraphicsLevel,
            "graphics.acceptableLevels[1]",
            in: definition.validate()
        ))

        definition.graphics = DoryVMGraphicsPolicy(acceptableLevels: [.hardwareAccelerated3D])
        definition.backendPreference = DoryVMBackendPreference(
            mode: .required,
            backend: .doryHypervisor
        )
        #expect(definition.isValid)

        definition.backendPreference = DoryVMBackendPreference(mode: .required, backend: nil)
        #expect(has(.backendPreferenceMalformed, "backendPreference", in: definition.validate()))
    }

    @Test("dynamic display integration requires an enabled display")
    func dynamicDisplayRequiresDisplay() {
        var definition = linuxDefinition()
        definition.display = .disabled
        #expect(has(.integrationRequiresDisplay, "integrations", in: definition.validate()))

        definition.integrations.removeAll { $0 == .dynamicDisplay }
        #expect(definition.isValid)
    }

    @Test("display backing and guest UI scales are distinct bounded intent")
    func displayScaleValidation() {
        var definition = linuxDefinition()
        definition.display.backingScaleFactor = 1
        definition.display.guestUIScaleFactor = 2
        #expect(definition.isValid)

        definition.display.backingScaleFactor = 0
        #expect(has(.invalidDisplayConfiguration, "display", in: definition.validate()))
        definition.display.backingScaleFactor = 2
        definition.display.guestUIScaleFactor = 3
        #expect(has(.invalidDisplayConfiguration, "display", in: definition.validate()))
    }

    private func linuxDefinition(
        kind: DoryBootMediaKind = .installedLinuxBootBundle
    ) -> DoryVirtualMachineDefinition {
        let bootArtifact = kind == .virtualDisk
            ? reference("disk", "system")
            : reference("boot", "ubuntu-24.04")
        return DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(id: "vm-ubuntu-dev", name: "Ubuntu Development"),
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            workload: .desktop,
            boot: DoryVMBootConfiguration(
                phase: .normal,
                devices: [DoryVMBootMediaReference(
                    id: "system",
                    role: .system,
                    kind: kind,
                    source: .userProvided,
                    artifact: bootArtifact,
                    removable: false
                )],
                order: ["system"]
            ),
            backendPreference: DoryVMBackendPreference(
                mode: .preferred,
                backend: .doryHypervisor
            ),
            graphics: DoryVMGraphicsPolicy(acceptableLevels: [.hardwareAccelerated3D]),
            resources: resources(),
            storage: [DoryVMStorageAttachment(
                id: "system",
                role: .system,
                artifact: reference("disk", "system"),
                capacityBytes: 64 * gibibyte
            )],
            shares: [share("source", path: "/workspace/source")],
            integrations: [.clipboard, .clockSynchronization, .dynamicDisplay, .gracefulShutdown],
            lifecycle: lifecycle()
        )
    }

    private func installerDefinition(
        family: DoryGuestFamily,
        workload: DoryVMWorkloadProfile = .desktop
    ) -> DoryVirtualMachineDefinition {
        let kind: DoryBootMediaKind = family == .macOS ? .macOSRestoreImage : .installerISO
        let source: DoryBootMediaSource = family == .macOS ? .vendorDownload : .userProvided
        return DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(
                id: "vm-\(family.rawValue)-installer",
                name: "\(family.rawValue) Installer"
            ),
            guest: DoryGuestPlatform(family: family, architecture: .arm64),
            workload: workload,
            boot: DoryVMBootConfiguration(
                phase: .install,
                devices: [DoryVMBootMediaReference(
                    id: "installer",
                    role: .installer,
                    kind: kind,
                    source: source,
                    artifact: reference("install", family.rawValue),
                    removable: true
                )],
                order: ["installer"]
            ),
            graphics: DoryVMGraphicsPolicy(
                acceptableLevels: [.hostAcceleratedDisplay, .software]
            ),
            resources: resources(),
            storage: [DoryVMStorageAttachment(
                id: "system",
                role: .system,
                artifact: reference("disk", family.rawValue),
                capacityBytes: 64 * gibibyte
            )],
            lifecycle: lifecycle()
        )
    }

    private func recoveryDefinition() -> DoryVirtualMachineDefinition {
        var definition = linuxDefinition(kind: .virtualDisk)
        definition.boot = DoryVMBootConfiguration(
            phase: .recovery,
            devices: [
                DoryVMBootMediaReference(
                    id: "recovery",
                    role: .recovery,
                    kind: .installerISO,
                    source: .userProvided,
                    artifact: reference("recovery", "ubuntu-rescue"),
                    removable: true
                ),
                DoryVMBootMediaReference(
                    id: "system",
                    role: .system,
                    kind: .virtualDisk,
                    source: .userProvided,
                    artifact: reference("disk", "system"),
                    removable: false
                ),
            ],
            order: ["recovery", "system"]
        )
        return definition
    }

    private func resources() -> DoryVMResourceRequest {
        DoryVMResourceRequest(
            virtualCPUCount: 4,
            memoryBytes: 8 * gibibyte,
            diskBytes: 64 * gibibyte
        )
    }

    private func storage(
        _ id: String,
        artifact: DoryVMResolverReference,
        readOnly: Bool
    ) -> DoryVMStorageAttachment {
        DoryVMStorageAttachment(
            id: id,
            role: .data,
            artifact: artifact,
            capacityBytes: 10 * gibibyte,
            readOnly: readOnly
        )
    }

    private func share(_ id: String, path: String) -> DoryVMShare {
        DoryVMShare(
            id: id,
            hostLocation: reference("bookmark", id),
            guestMountPath: path
        )
    }

    private func reference(_ namespace: String, _ identifier: String) -> DoryVMResolverReference {
        DoryVMResolverReference(namespace: namespace, identifier: identifier)
    }

    private func lifecycle() -> DoryVMLifecycleMetadata {
        DoryVMLifecycleMetadata(
            revision: 1,
            createdAtUnixMilliseconds: nowMilliseconds,
            updatedAtUnixMilliseconds: nowMilliseconds
        )
    }

    private func has(
        _ code: DoryVMDefinitionValidationCode,
        _ field: String,
        in issues: [DoryVMDefinitionValidationIssue]
    ) -> Bool {
        issues.contains(DoryVMDefinitionValidationIssue(code: code, field: field))
    }
}
