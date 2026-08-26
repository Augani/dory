import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Typed machine write authority")
struct DoryMachineTypedWriteAuthorityTests {
    @Test("typed wire round trip is exact and contains no raw environment")
    func wireRoundTrip() throws {
        let source = DoryMachineTypedSettingsPatch(
            guestUsername: .set("developer"),
            guestNumericUserID: .set(1_000),
            desktopDistributionIdentifier: .set("ubuntu"),
            desktopDisplayName: .set("Ubuntu"),
            desktopVersion: .set("24.04"),
            desktopEnvironment: .set("GNOME"),
            clipboardPolicy: .set(.legacyDesktop(.hostToGuest)),
            runtimePreference: .set(.accelerated),
            graphicsPreference: .set(.virglVenus),
            networkMode: .set(.disconnected),
            portForwards: .set([
                DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
                DoryVMPortForward(
                    id: "dns",
                    transport: .udp,
                    hostPort: 5_353,
                    guestPort: 53,
                    exposure: .lan
                ),
            ]),
            audioInputEnabled: .set(false),
            audioOutputEnabled: .set(true),
            intelApplicationTranslationEnabled: .set(true)
        )

        let wire = source.xpcDictionary
        #expect(wire["env"] == nil)
        #expect(try DoryMachineTypedSettingsPatch(
            xpcDictionary: wire,
            allowsClears: false
        ) == source)
    }

    @Test("raw environment write authority is rejected even when empty")
    func rejectsRawEnvironment() {
        for raw: Any in [NSArray(), NSNull(), [["key": "SAFE", "value": "value"]]] {
            let dictionary: NSDictionary = ["env": raw]
            #expect(throws: DoryMachineTypedWriteAuthorityError.rawEnvironmentForbidden) {
                try DoryMachineTypedSettingsPatch(
                    xpcDictionary: dictionary,
                    allowsClears: true
                )
            }
        }
    }

    @Test("update applies fields locally and preserves opaque legacy values")
    func fieldLocalBackProjection() throws {
        let legacy = [
            "DORY_GUEST_USER": "../../unsafe-old-user",
            "DORY_GUEST_UID": "not-a-uid",
            "DORY_DESKTOP_DISTRO": "unsafe://old",
            "DORY_VIRGL_CLASSIC_ONLY": "1",
            "PRIVATE_TOKEN": "must-remain-opaque",
        ]
        let patch = DoryMachineTypedSettingsPatch(
            desktopDisplayName: .set("Ubuntu")
        )

        let projected = try patch.applying(to: legacy, displayMode: .desktop)

        #expect(projected["DORY_DESKTOP_NAME"] == "Ubuntu")
        #expect(projected["DORY_GUEST_USER"] == "../../unsafe-old-user")
        #expect(projected["DORY_GUEST_UID"] == "not-a-uid")
        #expect(projected["DORY_DESKTOP_DISTRO"] == "unsafe://old")
        #expect(projected["DORY_VIRGL_CLASSIC_ONLY"] == "1")
        #expect(projected["PRIVATE_TOKEN"] == "must-remain-opaque")

        let runtime = try DoryMachineTypedSettingsPatch(
            runtimePreference: .set(.compatible),
            graphicsPreference: .set(.software)
        ).applying(to: legacy, displayMode: .desktop)
        #expect(runtime["DORY_DESKTOP_VMM"] == "compatible")
        #expect(runtime["DORY_DESKTOP_GRAPHICS"] == "software")
    }

    @Test("legacy status projection exposes only bounded typed settings")
    func safeLegacyStatusProjection() throws {
        let snapshot = DoryMachineTypedSettingsSnapshot(
            legacyEnvironment: [
                "DORY_GUEST_USER": "developer",
                "DORY_GUEST_UID": "1000",
                "DORY_DESKTOP_DISTRO": "ubuntu",
                "DORY_DESKTOP_NAME": "Ubuntu",
                "DORY_CLIPBOARD_POLICY": "host-to-guest",
                "DORY_DESKTOP_VMM": "accelerated",
                "DORY_DESKTOP_GRAPHICS": "virgl-venus",
                "PRIVATE_TOKEN": "must-never-cross-xpc",
            ],
            displayMode: .desktop
        )

        #expect(snapshot.guestIdentityIntent.account?.username == "developer")
        #expect(snapshot.guestIdentityIntent.account?.numericUserID == 1_000)
        #expect(snapshot.guestIdentityIntent.desktop?.distributionIdentifier == "ubuntu")
        #expect(snapshot.guestIdentityIntent.desktop?.displayName == "Ubuntu")
        #expect(snapshot.clipboardPolicy?.text == .hostToGuest)
        #expect(snapshot.runtimePreference == .accelerated)
        #expect(snapshot.graphicsPreference == .virglVenus)
        #expect(snapshot.networkMode == .sharedNAT)
        #expect(snapshot.portForwards.isEmpty)
        #expect(snapshot.audioConfiguration == DoryVMAudioConfiguration(
            inputEnabled: true,
            outputEnabled: true
        ))
        #expect(snapshot.intelApplicationTranslationEnabled == nil)
        #expect(snapshot.xpcDictionary.description.contains("must-never-cross-xpc") == false)

        let invalid = DoryMachineTypedSettingsSnapshot(
            legacyEnvironment: [
                "DORY_GUEST_USER": "../../unsafe",
                "DORY_GUEST_UID": "not-a-uid",
                "PRIVATE_TOKEN": "opaque",
            ],
            displayMode: .desktop
        )
        #expect(invalid.guestIdentityIntent.account == nil)
        #expect(invalid.xpcDictionary.description.contains("opaque") == false)

        var historical = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
                as? [String: Any]
        )
        historical.removeValue(forKey: "networkMode")
        historical.removeValue(forKey: "audioConfiguration")
        historical.removeValue(forKey: "portForwards")
        historical.removeValue(forKey: "intelApplicationTranslationEnabled")
        let decoded = try JSONDecoder().decode(
            DoryMachineTypedSettingsSnapshot.self,
            from: JSONSerialization.data(withJSONObject: historical)
        )
        #expect(decoded.networkMode == .sharedNAT)
        #expect(decoded.audioConfiguration == nil)
        #expect(decoded.portForwards.isEmpty)
        #expect(decoded.intelApplicationTranslationEnabled == nil)
    }

    @Test("update clear is explicit and field scoped")
    func explicitClear() throws {
        let source = DoryMachineTypedSettingsPatch(
            guestUsername: .clear,
            desktopVersion: .clear,
            clipboardPolicy: .clear
        )
        let wire = source.xpcDictionary
        let decoded = try DoryMachineTypedSettingsPatch(
            xpcDictionary: wire,
            allowsClears: true
        )
        let projected = try decoded.applying(
            to: [
                "DORY_GUEST_USER": "developer",
                "DORY_GUEST_UID": "1000",
                "DORY_DESKTOP_VERSION": "24.04",
                "DORY_DESKTOP_NAME": "Ubuntu",
                "DORY_CLIPBOARD_POLICY": "bidirectional",
            ],
            displayMode: .desktop
        )

        #expect(projected["DORY_GUEST_USER"] == nil)
        #expect(projected["DORY_DESKTOP_VERSION"] == nil)
        #expect(projected["DORY_CLIPBOARD_POLICY"] == nil)
        #expect(projected["DORY_GUEST_UID"] == "1000")
        #expect(projected["DORY_DESKTOP_NAME"] == "Ubuntu")
        #expect(throws: DoryMachineTypedWriteAuthorityError.invalidField(
            "guestIdentityIntent.account.username"
        )) {
            try DoryMachineTypedSettingsPatch(
                xpcDictionary: wire,
                allowsClears: false
            )
        }
    }

    @Test("headless snapshot replacement preserves desktop-only launch policy")
    func headlessSnapshotPreservesLaunchPolicy() throws {
        let migration = try DoryMachineConfigurationMigrationBridge.migrate(
            DoryMachineConfiguration(
                id: "headless-snapshot",
                kernelPath: "/fixture/kernel",
                rootfsPath: "/fixture/rootfs",
                displayMode: .headless
            ),
            facts: DoryMachineConfigurationMigrationFacts(
                guestArchitecture: .arm64,
                systemDiskCapacityBytes: 32 * 1_024 * 1_024 * 1_024,
                lifecycle: DoryVMLifecycleMetadata(
                    revision: 1,
                    createdAtUnixMilliseconds: 1_700_000_000_000,
                    updatedAtUnixMilliseconds: 1_700_000_000_000
                )
            )
        )
        let snapshot = try DoryMachineTypedSettingsSnapshot(
            definition: migration.definition
        )
        let restored = try snapshot.applyingAsReplacement(
            to: migration.definition,
            displayMode: .headless
        )

        #expect(snapshot.runtimePreference == nil)
        #expect(snapshot.graphicsPreference == nil)
        #expect(snapshot.audioConfiguration == nil)
        #expect(restored.backendPreference == migration.definition.backendPreference)
        #expect(restored.graphics == migration.definition.graphics)
        #expect(restored.clipboardPolicy == migration.definition.clipboardPolicy)
    }

    @Test("portable EFI snapshot preserves the implicit VZ graphics recovery policy")
    func portableEFISnapshotPreservesGraphicsPolicy() throws {
        let migration = try DoryMachineConfigurationMigrationBridge.migrate(
            DoryMachineConfiguration(
                id: "portable-efi-snapshot",
                kernelPath: "/fixture/installer-kernel-placeholder",
                rootfsPath: "/fixture/system.raw",
                bootMode: .efi,
                installerISOPath: "/fixture/linux-arm64.iso",
                displayMode: .desktop
            ),
            facts: DoryMachineConfigurationMigrationFacts(
                guestArchitecture: .arm64,
                systemDiskCapacityBytes: 32 * 1_024 * 1_024 * 1_024,
                lifecycle: DoryVMLifecycleMetadata(
                    revision: 1,
                    createdAtUnixMilliseconds: 1_700_000_000_000,
                    updatedAtUnixMilliseconds: 1_700_000_000_000
                )
            )
        )
        var legacyDefinition = migration.definition
        legacyDefinition.graphics = DoryVMGraphicsPolicy(acceptableLevels: [
            .hostAcceleratedDisplay, .software,
        ])
        let snapshot = try DoryMachineTypedSettingsSnapshot(definition: legacyDefinition)
        let restored = try snapshot.applyingAsReplacement(
            to: legacyDefinition,
            displayMode: .desktop
        )

        #expect(legacyDefinition.graphics.acceptableLevels == [
            .hostAcceleratedDisplay, .software,
        ])
        #expect(snapshot.runtimePreference == .compatible)
        #expect(snapshot.graphicsPreference == nil)
        #expect(restored.graphics == legacyDefinition.graphics)
    }

    @Test("hostile and out of range guest fields fail closed")
    func hostileGuestFields() {
        let cases: [NSDictionary] = [
            ["guestIdentityIntent": ["account": ["username": "../../host"]]],
            ["guestIdentityIntent": ["account": ["numericUserID": 99]]],
            ["guestIdentityIntent": ["account": ["numericUserID": 60_001]]],
            ["guestIdentityIntent": ["desktop": ["displayName": "token\nvalue"]]],
            ["guestIdentityIntent": ["desktop": ["displayName": "a" + String(repeating: "\u{301}", count: 128)]]],
            ["guestIdentityIntent": ["unexpected": "value"]],
            ["guestIdentityIntent": ["account": ["username": "developer", "secret": "x"]]],
        ]
        for dictionary in cases {
            #expect(throws: (any Error).self) {
                try DoryMachineTypedSettingsPatch(
                    xpcDictionary: dictionary,
                    allowsClears: false
                )
            }
        }
    }

    @Test("current compatibility runtime rejects widening clipboard or desktop on headless")
    func runtimeRepresentability() throws {
        let widened = DoryMachineTypedSettingsPatch(clipboardPolicy: .set(
            DoryVMClipboardPolicy(
                text: .hostToGuest,
                image: .guestToHost,
                files: .off
            )
        ))
        #expect(throws: DoryMachineTypedWriteAuthorityError.unsupportedByLegacyRuntime(
            "clipboardPolicy"
        )) {
            try widened.applying(to: [:], displayMode: .desktop)
        }

        let files = DoryMachineTypedSettingsPatch(clipboardPolicy: .set(
            DoryVMClipboardPolicy(text: .off, image: .off, files: .hostToGuest)
        ))
        #expect(throws: DoryMachineTypedWriteAuthorityError.unsupportedByLegacyRuntime(
            "clipboardPolicy"
        )) {
            try files.applying(to: [:], displayMode: .desktop)
        }

        let fixedAudio = DoryMachineTypedSettingsPatch(
            audioInputEnabled: .set(true),
            audioOutputEnabled: .set(true)
        )
        #expect(try fixedAudio.applying(
            to: ["OPAQUE": "preserved"],
            displayMode: .desktop
        ) == ["OPAQUE": "preserved"])
        #expect(throws: DoryMachineTypedWriteAuthorityError.unsupportedByLegacyRuntime(
            "audio"
        )) {
            try DoryMachineTypedSettingsPatch(
                audioInputEnabled: .set(false),
                audioOutputEnabled: .set(true)
            ).applying(to: [:], displayMode: .desktop)
        }

        let desktop = DoryMachineTypedSettingsPatch(desktopDisplayName: .set("Ubuntu"))
        #expect(throws: DoryMachineTypedWriteAuthorityError.unsupportedForDisplay(
            "guestIdentityIntent.desktop"
        )) {
            try desktop.applying(to: [:], displayMode: .headless)
        }

        let enabledClipboard = DoryMachineTypedSettingsPatch(
            clipboardPolicy: .set(.legacyDesktop(.bidirectional))
        )
        #expect(throws: DoryMachineTypedWriteAuthorityError.unsupportedForDisplay(
            "clipboardPolicy"
        )) {
            try enabledClipboard.applying(to: [:], displayMode: .headless)
        }
        #expect(try DoryMachineTypedSettingsPatch(
            clipboardPolicy: .set(.disabled)
        ).applying(to: [:], displayMode: .headless)["DORY_CLIPBOARD_POLICY"] == "off")
        #expect(throws: DoryMachineTypedWriteAuthorityError.unsupportedForDisplay(
            "desktopRuntimePreference"
        )) {
            try DoryMachineTypedSettingsPatch(
                runtimePreference: .set(.accelerated)
            ).applying(to: [:], displayMode: .headless)
        }

        let disconnected = DoryMachineTypedSettingsPatch(
            networkMode: .set(.disconnected)
        )
        #expect(throws: DoryMachineTypedWriteAuthorityError.unsupportedByLegacyRuntime(
            "networkMode"
        )) {
            try disconnected.applying(to: [:], displayMode: .desktop)
        }
        let migrated = try DoryMachineConfigurationMigrationBridge.migrate(
            DoryMachineConfiguration(
                id: "offline",
                kernelPath: "/fixture/kernel",
                rootfsPath: "/fixture/rootfs",
                displayMode: .desktop
            ),
            facts: DoryMachineConfigurationMigrationFacts(
                guestArchitecture: .arm64,
                systemDiskCapacityBytes: 32 * 1_024 * 1_024 * 1_024,
                lifecycle: DoryVMLifecycleMetadata(
                    revision: 1,
                    createdAtUnixMilliseconds: 1_700_000_000_000,
                    updatedAtUnixMilliseconds: 1_700_000_000_000
                )
            )
        )
        #expect(try disconnected.applying(
            to: migrated.definition,
            displayMode: .desktop
        ).networkMode == .disconnected)
        let exactClipboard = try files.applying(
            to: migrated.definition,
            displayMode: .desktop
        )
        #expect(exactClipboard.clipboardPolicy.files == .hostToGuest)

        let audio = DoryMachineTypedSettingsPatch(audioInputEnabled: .set(false))
        #expect(throws: DoryMachineTypedWriteAuthorityError.unsupportedByLegacyRuntime(
            "audio"
        )) {
            try audio.applying(to: [:], displayMode: .desktop)
        }
        #expect(try audio.applying(
            to: migrated.definition,
            displayMode: .desktop
        ).audio == DoryVMAudioConfiguration(inputEnabled: false, outputEnabled: true))

        let translation = DoryMachineTypedSettingsPatch(
            intelApplicationTranslationEnabled: .set(true)
        )
        #expect(throws: DoryMachineTypedWriteAuthorityError.unsupportedByLegacyRuntime(
            "intelApplicationTranslationEnabled"
        )) {
            try translation.applying(to: [:], displayMode: .desktop)
        }
        let translated = try translation.applying(
            to: migrated.definition,
            displayMode: .desktop
        )
        #expect(translated.integrations.contains(.intelApplicationTranslation))
        #expect(try DoryMachineTypedSettingsSnapshot(
            definition: translated
        ).intelApplicationTranslationEnabled == true)
        #expect(try DoryMachineTypedSettingsPatch(
            intelApplicationTranslationEnabled: .set(false)
        ).applying(
            to: translated,
            displayMode: .desktop
        ).integrations.contains(.intelApplicationTranslation) == false)
        #expect(throws: DoryMachineTypedWriteAuthorityError.unsupportedForDisplay(
            "intelApplicationTranslationEnabled"
        )) {
            try translation.applying(to: migrated.definition, displayMode: .headless)
        }

        let forwards = DoryMachineTypedSettingsPatch(portForwards: .set([
            DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
        ]))
        #expect(throws: DoryMachineTypedWriteAuthorityError.unsupportedByLegacyRuntime(
            "portForwards"
        )) {
            try forwards.applying(to: [:], displayMode: .desktop)
        }
        #expect(try forwards.applying(
            to: migrated.definition,
            displayMode: .desktop
        ).portForwards == [
            DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
        ])
    }

    @Test("port-forward wire shape is exact, bounded, and conflict free")
    func exactPortForwardWireShape() throws {
        let source = DoryMachineTypedSettingsPatch(portForwards: .set([
            DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
            DoryVMPortForward(
                id: "dns",
                transport: .udp,
                hostPort: 5_353,
                guestPort: 53,
                exposure: .lan
            ),
        ]))
        let wire = source.xpcDictionary
        #expect(try DoryMachineTypedSettingsPatch(
            xpcDictionary: wire,
            allowsClears: false
        ) == source)

        let malformed: [Any] = [
            [["id": "web", "transport": "tcp", "hostPort": 8080, "guestPort": 80]],
            [["id": "web", "transport": "sctp", "hostPort": 8080, "guestPort": 80,
              "exposure": "loopback"]],
            [["id": "web", "transport": "tcp", "hostPort": true, "guestPort": 80,
              "exposure": "loopback"]],
            [["id": "web", "transport": "tcp", "hostPort": 443, "guestPort": 80,
              "exposure": "loopback"]],
            [["id": "../web", "transport": "tcp", "hostPort": 8080, "guestPort": 80,
              "exposure": "loopback"]],
        ]
        for value in malformed {
            #expect(throws: (any Error).self) {
                try DoryMachineTypedSettingsPatch(
                    xpcDictionary: ["portForwards": value],
                    allowsClears: false
                )
            }
        }
        #expect(throws: (any Error).self) {
            try DoryMachineTypedSettingsPatch(
                xpcDictionary: ["portForwards": [
                    ["id": "one", "transport": "tcp", "hostPort": 8080,
                     "guestPort": 80, "exposure": "loopback"],
                    ["id": "two", "transport": "tcp", "hostPort": 8080,
                     "guestPort": 81, "exposure": "loopback"],
                ]],
                allowsClears: false
            )
        }
    }

    @Test("clipboard wire shape is complete and exact")
    func exactClipboardWireShape() {
        let cases: [NSDictionary] = [
            ["clipboardPolicy": ["text": "off", "image": "off"]],
            [
                "clipboardPolicy": [
                    "text": "off",
                    "image": "off",
                    "files": "off",
                    "token": "secret",
                ],
            ],
            [
                "clipboardPolicy": [
                    "text": "invalid",
                    "image": "off",
                    "files": "off",
                ],
            ],
        ]
        for dictionary in cases {
            #expect(throws: DoryMachineTypedWriteAuthorityError.invalidField(
                "clipboardPolicy"
            )) {
                try DoryMachineTypedSettingsPatch(
                    xpcDictionary: dictionary,
                    allowsClears: false
                )
            }
        }
    }

    @Test("audio wire shape is strict, leaf-scoped, and resets explicitly")
    func exactAudioWireShape() throws {
        let patch = try DoryMachineTypedSettingsPatch(
            xpcDictionary: ["audio": ["inputEnabled": false]],
            allowsClears: true
        )
        #expect(patch.audioInputEnabled == .set(false))
        #expect(patch.audioOutputEnabled == .unchanged)
        #expect((patch.xpcDictionary["audio"] as? NSDictionary)?["inputEnabled"] as? Bool == false)

        for raw: Any in [
            ["inputEnabled": 0],
            ["outputEnabled": "true"],
            ["inputEnabled": true, "secret": "opaque"],
            [:],
        ] {
            #expect(throws: (any Error).self) {
                try DoryMachineTypedSettingsPatch(
                    xpcDictionary: ["audio": raw],
                    allowsClears: true
                )
            }
        }
        #expect(throws: DoryMachineTypedWriteAuthorityError.invalidField("audio")) {
            try DoryMachineTypedSettingsPatch(
                xpcDictionary: ["audio": NSNull()],
                allowsClears: false
            )
        }

        let reset = try DoryMachineTypedSettingsPatch(
            xpcDictionary: ["audio": NSNull()],
            allowsClears: true
        )
        #expect(reset.audioInputEnabled == .clear)
        #expect(reset.audioOutputEnabled == .clear)
    }

    @Test("CLI consumes typed persistence options and leaves raw env unconsumed")
    func cliTypedOptions() throws {
        var arguments = [
            "--memory-mb", "4096",
            "--guest-user", "developer",
            "--guest-uid", "1000",
            "--desktop-distro", "ubuntu",
            "--desktop-name", "Ubuntu",
            "--desktop-version", "24.04",
            "--desktop-environment", "GNOME",
            "--clipboard", "guest-to-host",
            "--runtime", "compatible",
            "--graphics", "software",
            "--network", "disconnected",
            "--forward", "web:tcp:8080:80:loopback",
            "--forward", "dns:udp:5353:53:lan",
            "--audio-input", "off",
            "--audio-output", "on",
            "--intel-application-translation", "on",
            "--env", "TOKEN=secret",
        ]

        let patch = try DoryMachineTypedSettingsPatch.consumeCLIArguments(
            &arguments,
            allowsClears: false
        )

        #expect(patch.guestUsername == .set("developer"))
        #expect(patch.guestNumericUserID == .set(1_000))
        #expect(patch.desktopDistributionIdentifier == .set("ubuntu"))
        #expect(patch.clipboardPolicy == .set(.legacyDesktop(.guestToHost)))
        #expect(patch.runtimePreference == .set(.compatible))
        #expect(patch.graphicsPreference == .set(.software))
        #expect(patch.networkMode == .set(.disconnected))
        #expect(patch.portForwards == .set([
            DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
            DoryVMPortForward(
                id: "dns",
                transport: .udp,
                hostPort: 5_353,
                guestPort: 53,
                exposure: .lan
            ),
        ]))
        #expect(patch.audioInputEnabled == .set(false))
        #expect(patch.audioOutputEnabled == .set(true))
        #expect(patch.intelApplicationTranslationEnabled == .set(true))
        #expect(arguments == ["--memory-mb", "4096", "--env", "TOKEN=secret"])
        #expect(patch.xpcDictionary["env"] == nil)
    }

    @Test("CLI presents host-only while preserving the historical isolated wire identity")
    func cliHostOnlyAlias() throws {
        var arguments = ["--network", "host-only"]
        let patch = try DoryMachineTypedSettingsPatch.consumeCLIArguments(
            &arguments,
            allowsClears: false
        )
        #expect(patch.networkMode == .set(.isolated))
        #expect(patch.xpcDictionary["networkMode"] as? String == "isolated")
        #expect(arguments.isEmpty)
    }

    @Test("CLI clear groups are explicit and conflict with replacement values")
    func cliClearSemantics() throws {
        var clearing = [
            "--clear-guest-account",
            "--clear-desktop-identity",
            "--clear-clipboard",
            "--clear-runtime",
            "--clear-graphics",
            "--clear-network",
            "--clear-forwards",
            "--clear-audio",
            "--clear-intel-application-translation",
        ]
        let patch = try DoryMachineTypedSettingsPatch.consumeCLIArguments(
            &clearing,
            allowsClears: true
        )
        #expect(clearing.isEmpty)
        #expect(patch.guestUsername == .clear)
        #expect(patch.guestNumericUserID == .clear)
        #expect(patch.desktopDistributionIdentifier == .clear)
        #expect(patch.desktopDisplayName == .clear)
        #expect(patch.clipboardPolicy == .clear)
        #expect(patch.runtimePreference == .clear)
        #expect(patch.graphicsPreference == .clear)
        #expect(patch.networkMode == .clear)
        #expect(patch.portForwards == .clear)
        #expect(patch.audioInputEnabled == .clear)
        #expect(patch.audioOutputEnabled == .clear)
        #expect(patch.intelApplicationTranslationEnabled == .clear)

        var createClear = ["--clear-clipboard"]
        #expect(throws: DoryMachineTypedWriteAuthorityError.invalidField("clear options")) {
            try DoryMachineTypedSettingsPatch.consumeCLIArguments(
                &createClear,
                allowsClears: false
            )
        }
        var conflict = ["--guest-user", "developer", "--clear-guest-account"]
        #expect(throws: DoryMachineTypedWriteAuthorityError.invalidField(
            "--clear-guest-account"
        )) {
            try DoryMachineTypedSettingsPatch.consumeCLIArguments(
                &conflict,
                allowsClears: true
            )
        }
    }
}
