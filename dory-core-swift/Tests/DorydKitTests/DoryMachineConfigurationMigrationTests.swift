import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Legacy machine configuration migration")
struct DoryMachineConfigurationMigrationTests {
    private let gibibyte: UInt64 = 1_073_741_824

    @Test("managed desktop projects typed policy and round trips canonical legacy bytes")
    func managedDesktopRoundTrip() throws {
        let legacy = DoryMachineConfiguration(
            id: "ubuntu-dev",
            kernelPath: "/managed/ubuntu-dev/kernel",
            rootfsPath: "/managed/ubuntu-dev/rootfs.ext4",
            memoryMB: 8_192,
            cpuCount: 6,
            address: "192.168.64.20",
            displayMode: .desktop,
            shares: [DoryMachineShareConfiguration(
                tag: "source",
                hostPath: "/Users/developer/Source",
                guestPath: "/workspace/source",
                readOnly: true
            )],
            environment: [
                DoryDesktopVMMPreference.environmentKey: "accelerated",
                DoryDesktopGraphicsPreference.environmentKey: "virgl",
                "DORY_DESKTOP_DISTRO": "ubuntu",
                "PRIVATE_RUNTIME_VALUE": "do-not-copy-into-workspace",
            ]
        )
        let migrated = try migrate(legacy, capacity: 96 * gibibyte)

        #expect(migrated.definition.isValid)
        #expect(migrated.bootContract == .managedDirectKernel)
        #expect(migrated.definition.workload == .desktop)
        #expect(migrated.definition.boot.phase == .normal)
        #expect(migrated.definition.boot.devices[0].kind == .installedLinuxBootBundle)
        #expect(migrated.definition.boot.devices[0].source == .bundledByDory)
        #expect(migrated.definition.backendPreference == DoryVMBackendPreference(
            mode: .preferred,
            backend: .doryHypervisor
        ))
        #expect(migrated.definition.graphics.acceptableLevels == [.hardwareAccelerated3D])
        #expect(migrated.definition.resources.memoryBytes == 8 * gibibyte)
        #expect(migrated.definition.resources.virtualCPUCount == 6)
        #expect(migrated.definition.storage[0].capacityBytes == 96 * gibibyte)
        #expect(migrated.hostPath(for: migrated.definition.shares[0].hostLocation)
            == "/Users/developer/Source")
        #expect(migrated.artifactPath(for: migrated.definition.storage[0].artifact)
            == legacy.rootfsPath)

        let definitionData = try JSONEncoder().encode(migrated.definition)
        let definitionJSON = try #require(String(data: definitionData, encoding: .utf8))
        #expect(!definitionJSON.contains("/Users/developer"))
        #expect(!definitionJSON.contains("PRIVATE_RUNTIME_VALUE"))
        #expect(!definitionJSON.contains("do-not-copy-into-workspace"))

        #expect(try migrated.legacyConfiguration() == legacy)
        #expect(try migrated.authoritativeLegacyData()
            == DoryMachineConfigurationMigrationBridge.encodeLegacy(legacy))

        let repeated = try migrate(legacy, capacity: 96 * gibibyte)
        #expect(repeated.definition.storage[0].artifact == migrated.definition.storage[0].artifact)
        #expect(repeated.definition.boot.devices[0].artifact
            == migrated.definition.boot.devices[0].artifact)
        #expect(repeated.definition.shares[0].hostLocation
            == migrated.definition.shares[0].hostLocation)
    }

    @Test("headless Linux maps to an explicit non-graphical Virtualization.framework contract")
    func headlessRoundTrip() throws {
        let legacy = DoryMachineConfiguration(
            id: "build-server",
            kernelPath: "/managed/build-server/kernel",
            rootfsPath: "/managed/build-server/rootfs.ext4",
            memoryMB: 4_096,
            cpuCount: 4,
            displayMode: .headless,
            environment: ["SERVICE_TOKEN": "legacy-only-value"]
        )
        let migrated = try migrate(legacy, capacity: 48 * gibibyte)

        #expect(migrated.definition.workload == .server)
        #expect(migrated.definition.display == .disabled)
        #expect(migrated.definition.graphics.acceptableLevels == [.none])
        #expect(migrated.definition.backendPreference.backend == .appleVirtualizationFramework)
        #expect(!migrated.definition.audio.inputEnabled)
        #expect(!migrated.definition.audio.outputEnabled)
        #expect(!migrated.definition.input.keyboardEnabled)
        #expect(!migrated.definition.input.pointerEnabled)
        #expect(try migrated.legacyConfiguration() == legacy)
    }

    @Test("custom EFI ISO maps installer media and preserves blank-disk intent")
    func customEFIInstallerRoundTrip() throws {
        let legacy = DoryMachineConfiguration(
            id: "omarchy",
            kernelPath: "/managed/omarchy/kernel",
            rootfsPath: "/managed/omarchy/rootfs.ext4",
            bootMode: .efi,
            installerISOPath: "/managed/omarchy/installer.iso",
            diskSizeBytes: 80 * gibibyte,
            memoryMB: 8_192,
            cpuCount: 6,
            displayMode: .desktop,
            environment: ["DORY_CUSTOM_LINUX": "1"]
        )
        let migrated = try migrate(legacy, capacity: 80 * gibibyte)

        #expect(migrated.bootContract == .efiInstaller)
        #expect(migrated.definition.boot.phase == .install)
        #expect(migrated.definition.boot.devices[0].kind == .installerISO)
        #expect(migrated.definition.boot.devices[0].source == .userProvided)
        #expect(migrated.definition.boot.devices[0].removable)
        #expect(migrated.definition.backendPreference.backend == .appleVirtualizationFramework)
        #expect(migrated.artifactPath(for: migrated.definition.boot.devices[0].artifact)
            == legacy.installerISOPath)
        #expect(try migrated.legacyConfiguration() == legacy)
    }

    @Test("installed EFI firmware and direct-boot bundle mappings remain distinct")
    func installedEFIMappings() throws {
        let legacy = DoryMachineConfiguration(
            id: "installed-linux",
            kernelPath: "/managed/installed-linux/kernel",
            rootfsPath: "/managed/installed-linux/rootfs.ext4",
            bootMode: .efi,
            memoryMB: 4_096,
            cpuCount: 4,
            displayMode: .desktop,
            environment: [DoryDesktopVMMPreference.environmentKey: "accelerated"]
        )

        let firmware = try migrate(
            legacy,
            capacity: 64 * gibibyte,
            installedEFI: .firmwareDisk
        )
        #expect(firmware.bootContract == .efiFirmwareDisk)
        #expect(firmware.definition.boot.devices[0].kind == .virtualDisk)
        #expect(firmware.definition.boot.devices[0].artifact
            == firmware.definition.storage[0].artifact)
        #expect(firmware.definition.backendPreference.backend == .appleVirtualizationFramework)
        #expect(try firmware.legacyConfiguration() == legacy)

        let direct = try migrate(
            legacy,
            capacity: 64 * gibibyte,
            installedEFI: .installedLinuxBootBundle
        )
        #expect(direct.bootContract == .efiInstalledDirectBoot)
        #expect(direct.definition.boot.devices[0].kind == .installedLinuxBootBundle)
        #expect(direct.definition.boot.devices[0].artifact
            != direct.definition.storage[0].artifact)
        #expect(direct.definition.backendPreference.backend == .doryHypervisor)
        #expect(try direct.legacyConfiguration() == legacy)
    }

    @Test("typed policy edits use canonical legacy environment keys without losing other values")
    func typedPolicyBackProjection() throws {
        let legacy = DoryMachineConfiguration(
            id: "desktop",
            kernelPath: "/managed/desktop/kernel",
            rootfsPath: "/managed/desktop/rootfs.ext4",
            memoryMB: 4_096,
            cpuCount: 4,
            displayMode: .desktop,
            environment: [
                DoryDesktopGraphicsPreference.legacyClassicOnlyEnvironmentKey: "1",
                "PRESERVE": "yes",
            ]
        )
        var migrated = try migrate(legacy, capacity: 64 * gibibyte)
        migrated.definition.backendPreference = DoryVMBackendPreference(
            mode: .preferred,
            backend: .appleVirtualizationFramework
        )
        migrated.definition.graphics = DoryVMGraphicsPolicy(acceptableLevels: [.software])
        let projected = try migrated.legacyConfiguration()

        #expect(projected.environment[DoryDesktopVMMPreference.environmentKey] == "compatible")
        #expect(projected.environment[DoryDesktopGraphicsPreference.environmentKey] == "software")
        #expect(projected.environment[
            DoryDesktopGraphicsPreference.legacyClassicOnlyEnvironmentKey
        ] == nil)
        #expect(projected.environment["PRESERVE"] == "yes")
    }

    @Test("unsupported and under-specified migrations fail explicitly")
    func explicitMigrationFailures() throws {
        let direct = DoryMachineConfiguration(
            id: "direct",
            kernelPath: "/managed/direct/kernel",
            rootfsPath: "/managed/direct/rootfs.ext4"
        )
        #expect(throws: DoryMachineConfigurationMigrationError.missingSystemDiskCapacity) {
            try DoryMachineConfigurationMigrationBridge.migrate(
                direct,
                facts: facts(capacity: nil)
            )
        }

        let installedEFI = DoryMachineConfiguration(
            id: "installed",
            kernelPath: "/managed/installed/kernel",
            rootfsPath: "/managed/installed/rootfs.ext4",
            bootMode: .efi,
            displayMode: .desktop
        )
        #expect(throws: DoryMachineConfigurationMigrationError.missingInstalledEFIBootFact) {
            try DoryMachineConfigurationMigrationBridge.migrate(
                installedEFI,
                facts: facts(capacity: 64 * gibibyte)
            )
        }

        var migrated = try migrate(direct, capacity: 64 * gibibyte)
        migrated.definition.backendPreference = DoryVMBackendPreference(
            mode: .required,
            backend: .doryHypervisor
        )
        #expect(throws: DoryMachineConfigurationMigrationError.unsupportedDefinitionChange(
            "backendPreference"
        )) {
            try migrated.legacyConfiguration()
        }

        migrated = try migrate(direct, capacity: 64 * gibibyte)
        migrated.definition.storage[0].artifact = DoryVMResolverReference(
            namespace: "artifact",
            identifier: "unknown"
        )
        #expect(throws: DoryMachineConfigurationMigrationError.unresolvedArtifact(
            DoryVMResolverReference(namespace: "artifact", identifier: "unknown")
        )) {
            try migrated.legacyConfiguration()
        }
    }

    @Test("old legacy JSON defaults decode and retain the canonical machine.json wire shape")
    func legacyGoldenWireCompatibility() throws {
        let oldData = Data(#"{"id":"legacy","kernelPath":"/m/legacy/kernel","rootfsPath":"/m/legacy/rootfs.ext4"}"#.utf8)
        let migrated = try DoryMachineConfigurationMigrationBridge.decodeAndMigrate(
            oldData,
            facts: facts(capacity: 32 * gibibyte)
        )
        let canonical = try migrated.authoritativeLegacyData()
        let canonicalString = try #require(String(data: canonical, encoding: .utf8))
        #expect(canonicalString == #"""
        {
          "bootMode" : "linux-kernel",
          "cpuCount" : 2,
          "displayMode" : "headless",
          "environment" : {

          },
          "id" : "legacy",
          "kernelPath" : "\/m\/legacy\/kernel",
          "memoryMB" : 2048,
          "rootfsPath" : "\/m\/legacy\/rootfs.ext4",
          "shares" : [

          ]
        }
        """#)
    }

    private func migrate(
        _ configuration: DoryMachineConfiguration,
        capacity: UInt64,
        installedEFI: DoryMachineConfigurationInstalledEFIBoot? = nil
    ) throws -> DoryMachineConfigurationMigrationResult {
        try DoryMachineConfigurationMigrationBridge.migrate(
            configuration,
            facts: facts(capacity: capacity, installedEFI: installedEFI)
        )
    }

    private func facts(
        capacity: UInt64?,
        installedEFI: DoryMachineConfigurationInstalledEFIBoot? = nil
    ) -> DoryMachineConfigurationMigrationFacts {
        DoryMachineConfigurationMigrationFacts(
            guestArchitecture: .arm64,
            systemDiskCapacityBytes: capacity,
            installedEFIBoot: installedEFI,
            lifecycle: DoryVMLifecycleMetadata(
                revision: 1,
                createdAtUnixMilliseconds: 1_787_200_000_000,
                updatedAtUnixMilliseconds: 1_787_200_000_000
            )
        )
    }
}
