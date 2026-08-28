import Foundation
import DoryOperations
import Testing
@testable import Dory

@Suite(.serialized)
struct DorydClientTests {
    @MainActor
    @Test func machineDisplayPresentationRoundTripsExactXPCShape() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)
        let presentation = DoryMachineDisplayPresentation(assignments: [
            .init(
                guestDisplayID: "display-0",
                mode: .dedicatedFullscreen,
                hostDisplayUUID: "00000000-0000-0000-0000-000000000001"
            ),
        ])
        let status = try await client.machineDisplayPresentationSet(
            "dev",
            presentation: presentation
        )
        #expect(status.displayPresentation == presentation)
        #expect(try await client.machineList().first?.displayPresentation == presentation)
    }

    @MainActor
    @Test func machineUSBControlRequiresExactResolvedResponse() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        let hostDevices = try await client.hostUSBDevices()
        #expect(hostDevices == [DorydHostUSBDevice(
            busID: "3-2",
            vendorID: 0x05ac,
            productID: 0x12a8,
            vendorName: "Example Vendor",
            productName: "Example Device",
            deviceClass: 3,
            speed: 4
        )])

        service.setHostUSBDevicesResponse([
            [
                "busID": "3-2",
                "vendorID": 0x05ac,
                "productID": 0x12a8,
                "vendorName": "Example Vendor",
                "productName": "Example Device",
                "deviceClass": 3,
                "speed": 4,
                "serialNumber": "must-not-cross-xpc",
            ],
        ])
        await #expect(throws: (any Error).self) {
            _ = try await client.hostUSBDevices()
        }

        let attachment = try await client.machineUSBAttach("dev", busID: "3-2")
        #expect(attachment == DorydMachineUSBAttachment(
            machineID: "dev",
            busID: "3-2",
            port: 4,
            vsockPort: 1_025,
            deviceID: 0x0003_0002,
            speed: 3
        ))
        try await client.machineUSBDetach("dev", busID: "3-2")

        service.setMachineUSBAttachResponse([
            "machineID": "dev",
            "busID": "3-2",
            "port": 4,
            "vsockPort": 1_025,
            "deviceID": 0x0003_0002,
            "speed": 3,
            "unexpected": true,
        ])
        await #expect(throws: (any Error).self) {
            _ = try await client.machineUSBAttach("dev", busID: "3-2")
        }

        service.setMachineUSBAttachResponse([
            "machineID": "dev",
            "busID": "3-2",
            "port": true,
            "vsockPort": 1_025,
            "deviceID": 0x0003_0002,
            "speed": 3,
        ])
        await #expect(throws: (any Error).self) {
            _ = try await client.machineUSBAttach("dev", busID: "3-2")
        }

        service.setMachineUSBAttachResponse([
            "machineID": "dev",
            "busID": "3-2",
            "port": 4,
            "vsockPort": 1_026,
            "deviceID": 0x0003_0002,
            "speed": 3,
        ])
        await #expect(throws: (any Error).self) {
            _ = try await client.machineUSBAttach("dev", busID: "3-2")
        }

        service.setMachineUSBDetachResponse([
            "machineID": "dev",
            "busID": "different",
        ])
        await #expect(throws: (any Error).self) {
            try await client.machineUSBDetach("dev", busID: "3-2")
        }
    }

    @MainActor
    @Test func desktopUpdateRejectsPresentMalformedOperationIdentity() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        service.setMachineDesktopUpdateOperationIDResponse(NSNumber(value: 7))
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        await #expect(throws: (any Error).self) {
            _ = try await client.machineDesktopUpdate(
                "dev",
                distro: "ubuntu",
                version: "1.0.0",
                distributionInstallationName: "ubuntu-1",
                runtimeInstallationName: "runtime-1"
            )
        }
    }

    @Test func dorydSharesPreserveStableTagsAndAllocateAroundExistingIdentity() {
        let mounts = [
            MountPair(host: "/tmp/first", guest: "/workspace/first", shareTag: "doryapp0"),
            MountPair(host: "/tmp/new-a", guest: "/workspace/new-a"),
            MountPair(host: "/tmp/stable", guest: "/workspace/stable", shareTag: "project-src"),
            MountPair(host: "/tmp/new-b", guest: "/workspace/new-b"),
        ]

        let shares = AppStore.dorydShares(from: mounts)

        #expect(shares.map(\.tag) == ["doryapp0", "doryapp1", "project-src", "doryapp2"])
        #expect(
            AppStore.dorydShares(from: [mounts[2], mounts[0]]).map(\.tag)
                == ["project-src", "doryapp0"]
        )
    }

    @MainActor
    @Test func machineTransferUsesPrivateStageAndRejectsMalformedEvidence() async throws {
        let root = URL(fileURLWithPath: "/tmp/dory-client-transfer-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))")
        let source = root.appendingPathComponent("source", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let selected = source.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: selected)
        let staged = try DoryMachineFileTransferStager.stage(
            fileURLs: [selected],
            stagingDirectory: staging
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        let result = try await client.machineTransfer("dev", staged: staged)
        #expect(result.filesSent == 1)
        #expect(result.bytesSent == 5)
        #expect(result.guestDestination == "/home/developer/Downloads/Dory Transfer " + result.transferID)
        #expect(service.latestMachineTransferRequest?["privateStagingRoot"] as? String == staged.rootPath)
        #expect(service.latestMachineTransferRequest?["schema"] as? UInt16 == 1)

        let validID = String(repeating: "a", count: 32)
        service.setMachineTransferResponse([
            "schema": UInt16(1),
            "transferID": validID,
            "guestDestination": "/home/developer/Downloads/Dory Transfer " + validID,
            "filesSent": UInt64(1),
            "bytesSent": UInt64(5),
            "unexpected": true,
        ])
        await #expect(throws: (any Error).self) {
            _ = try await client.machineTransfer("dev", staged: staged)
        }

        service.setMachineTransferResponse([
            "schema": UInt16(1),
            "transferID": validID,
            "guestDestination": "/tmp/host-path/" + validID,
            "filesSent": UInt64(1),
            "bytesSent": UInt64(5),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await client.machineTransfer("dev", staged: staged)
        }

        service.setMachineTransferResponse([
            "schema": UInt16(1),
            "transferID": validID,
            "guestDestination": "/home/developer/Downloads/Dory Transfer " + validID,
            "filesSent": true,
            "bytesSent": UInt64(5),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await client.machineTransfer("dev", staged: staged)
        }

        service.setMachineTransferResponse(nil)
        let started = try await client.machineTransferStart("dev", staged: staged)
        #expect(started.machineID == "dev")
        #expect(started.phase == .preparing)
        #expect(started.fractionCompleted == 0)
        #expect(service.latestMachineTransferStartRequest?["privateStagingRoot"] as? String == staged.rootPath)
        #expect(service.latestMachineTransferStartRequest?["schema"] as? UInt16 == 2)

        service.setMachineTransferCurrentResponse([
            "schema": UInt16(1),
            "active": true,
            "operation": service.machineTransferOperationResponse(
                operationID: started.operationID,
                phase: "transferring"
            ),
        ])
        let current = try #require(try await client.machineTransferCurrent("dev"))
        #expect(current.operationID == started.operationID)
        #expect(current.phase == .transferring)

        service.setMachineTransferCurrentResponse([
            "schema": UInt16(1),
            "active": false,
        ])
        #expect(try await client.machineTransferCurrent("dev") == nil)
        service.setMachineTransferCurrentResponse([
            "schema": UInt16(1),
            "active": false,
            "operation": service.machineTransferOperationResponse(
                operationID: started.operationID,
                phase: "transferring"
            ),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await client.machineTransferCurrent("dev")
        }
        service.setMachineTransferCurrentResponse(nil)

        let completed = try await client.machineTransferStatus(
            "dev",
            operationID: started.operationID
        )
        #expect(completed.phase == .completed)
        #expect(completed.phase.isTerminal)
        #expect(completed.result?.transferID == started.operationID)
        #expect(completed.result?.filesSent == 1)
        #expect(completed.result?.bytesSent == 5)
        #expect(completed.fractionCompleted == 1)

        let cancelled = try await client.machineTransferCancel(
            "dev",
            operationID: started.operationID
        )
        #expect(cancelled.phase == .cancelled)
        #expect(cancelled.result == nil)
        #expect(cancelled.failure == nil)

        let baseOperation = service.machineTransferOperationResponse(
            operationID: started.operationID,
            phase: "transferring"
        )
        for malformed in [
            baseOperation.adding("unexpected", true),
            baseOperation.adding("currentPath", "../host-secret"),
            baseOperation.replacing("filesCompleted", with: UInt64(2)),
            baseOperation
                .replacing("phase", with: "failed")
                .adding("failure", [
                    "schema": UInt16(1),
                    "code": "unknown-code",
                    "message": "failed",
                ] as NSDictionary),
        ] {
            service.setMachineTransferOperationResponse(malformed)
            await #expect(throws: (any Error).self) {
                _ = try await client.machineTransferStatus(
                    "dev",
                    operationID: started.operationID
                )
            }
        }
        service.setMachineTransferOperationResponse(nil)
    }

    @MainActor
    @Test func machineGuestExportUsesExactEvidenceAndRejectsHostPathSubstitution() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        let guestSource = "/home/developer/Documents/project"
        let started = try await client.machineGuestExportStart(
            "dev",
            guestSource: guestSource
        )
        #expect(started.machineID == "dev")
        #expect(started.phase == .preparing)
        #expect(started.result == nil)
        #expect(
            Set(service.latestMachineGuestExportRequest?.allKeys.compactMap {
                $0 as? String
            } ?? []) == ["schema", "guestSource"]
        )
        #expect(
            service.latestMachineGuestExportRequest?["guestSource"] as? String
                == guestSource
        )
        #expect(
            (service.latestMachineGuestExportRequest?["schema"] as? NSNumber)?.uint16Value
                == 1
        )

        service.setMachineGuestExportCurrentResponse([
            "schema": UInt16(1),
            "active": true,
            "operation": service.machineGuestExportOperationResponse(
                operationID: started.operationID,
                phase: "transferring"
            ),
        ])
        let current = try #require(try await client.machineGuestExportCurrent("dev"))
        #expect(current.operationID == started.operationID)
        #expect(current.phase == .transferring)

        service.setMachineGuestExportCurrentResponse([
            "schema": UInt16(1),
            "active": false,
        ])
        #expect(try await client.machineGuestExportCurrent("dev") == nil)
        service.setMachineGuestExportCurrentResponse([
            "schema": UInt16(1),
            "active": false,
            "operation": service.machineGuestExportOperationResponse(
                operationID: started.operationID,
                phase: "transferring"
            ),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await client.machineGuestExportCurrent("dev")
        }
        service.setMachineGuestExportCurrentResponse(nil)

        let completed = try await client.machineGuestExportStatus(
            "dev",
            operationID: started.operationID
        )
        #expect(completed.phase == .completed)
        #expect(completed.result?.exportID == started.operationID)
        #expect(completed.result?.filesReceived == 1)
        #expect(completed.result?.directoriesReceived == 1)
        #expect(completed.result?.bytesReceived == 12)
        #expect(
            completed.result?.privateStagingRoot.hasSuffix("-" + started.operationID)
                == true
        )
        #expect(completed.fractionCompleted == 1)

        let completedRow = service.machineGuestExportOperationResponse(
            operationID: started.operationID,
            phase: "completed"
        )
        service.setMachineGuestExportCurrentResponse([
            "schema": UInt16(1),
            "active": true,
            "operation": completedRow,
        ])
        let recoveredCompleted = try #require(
            try await client.machineGuestExportCurrent("dev")
        )
        #expect(recoveredCompleted.phase == .completed)
        #expect(recoveredCompleted.result?.exportID == started.operationID)
        service.setMachineGuestExportCurrentResponse(nil)

        let cancelled = try await client.machineGuestExportCancel(
            "dev",
            operationID: started.operationID
        )
        #expect(cancelled.phase == .cancelled)
        #expect(cancelled.result == nil)
        #expect(service.machineGuestExportCancelCount == 1)
        let discarded = try await client.machineGuestExportDiscard(
            "dev",
            operationID: started.operationID
        )
        #expect(discarded.ok)
        #expect(service.machineGuestExportDiscardCount == 1)

        let raceID = String(repeating: "e", count: 32)
        let completedRace = service.machineGuestExportOperationResponse(
            operationID: raceID,
            phase: "completed"
        )
        service.setMachineGuestExportStartResponse(completedRace.removing("result"))
        service.setMachineGuestExportOperationResponse(completedRace)
        let raced = try await client.machineGuestExportStart(
            "dev",
            guestSource: guestSource
        )
        #expect(raced.phase == .completed)
        #expect(raced.result?.exportID == raceID)
        service.setMachineGuestExportStartResponse(nil)

        let resultRow = try #require(completedRow["result"] as? NSDictionary)
        let otherID = String(repeating: "f", count: 32)
        let malformed: [NSDictionary] = [
            completedRow.adding("unexpected", true),
            completedRow.removing("result"),
            completedRow.replacing(
                "result",
                with: resultRow.replacing(
                    "privateStagingRoot",
                    with: "/tmp/host-secret"
                )
            ),
            completedRow.replacing(
                "result",
                with: resultRow.adding("unexpected", true)
            ),
            completedRow.replacing(
                "result",
                with: resultRow.replacing("filesReceived", with: true)
            ),
            completedRow.replacing(
                "result",
                with: resultRow
                    .replacing("exportID", with: otherID)
                    .replacing(
                        "privateStagingRoot",
                        with: DoryMachineFileTransferStager.defaultStagingDirectory
                            .appendingPathComponent(
                                "export-\(getpid())-\(otherID)",
                                isDirectory: true
                            ).path
                    )
            ),
            completedRow.replacing(
                "result",
                with: resultRow.replacing(
                    "directoriesReceived",
                    with: UInt64(DoryMachineFileTransferStager.maximumEntryCount)
                )
            ),
        ]
        for row in malformed {
            service.setMachineGuestExportOperationResponse(row)
            await #expect(throws: (any Error).self) {
                _ = try await client.machineGuestExportStatus(
                    "dev",
                    operationID: started.operationID
                )
            }
        }
        service.setMachineGuestExportOperationResponse(nil)
    }

    @Test func legacyDesktopDefaultsAndTogglesRemainFieldLocalInTypedEdits() throws {
        let defaults = DorydMachineTypedSettings(
            legacyEnvironment: [:],
            displayMode: .desktop
        )
        #expect(defaults.clipboardPolicy == .legacyDesktop(.bidirectional))
        #expect(defaults.runtimePreference == .automatic)
        #expect(defaults.graphicsPreference == .automatic)
        #expect(defaults.networkMode == .sharedNAT)
        #expect(defaults.portForwards.isEmpty)
        #expect(defaults.cameraConfiguration == DoryVMCameraConfiguration(enabled: false))
        #expect(defaults.intelApplicationTranslationEnabled == nil)

        var disconnected = defaults
        disconnected.networkMode = .disconnected
        let networkWire = DorydMachineTypedSettingsPatch(
            baseline: defaults,
            desired: disconnected
        ).xpcDictionary
        #expect(networkWire.count == 1)
        #expect(networkWire["networkMode"] as? String == "disconnected")

        var forwarded = defaults
        forwarded.portForwards = [
            DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
        ]
        let forwardWire = DorydMachineTypedSettingsPatch(
            baseline: defaults,
            desired: forwarded
        ).xpcDictionary
        let forwards = try #require(forwardWire["portForwards"] as? NSArray)
        #expect(forwards.count == 1)
        #expect((forwards[0] as? NSDictionary)?["id"] as? String == "web")

        #expect(defaults.audioConfiguration == DoryVMAudioConfiguration(
            inputEnabled: true,
            outputEnabled: true
        ))
        var microphoneDisabled = defaults
        microphoneDisabled.audioConfiguration?.inputEnabled = false
        let audioWire = DorydMachineTypedSettingsPatch(
            baseline: defaults,
            desired: microphoneDisabled
        ).xpcDictionary
        #expect(audioWire.count == 1)
        let audio = try #require(audioWire["audio"] as? NSDictionary)
        #expect(audio.count == 1)
        #expect(audio["inputEnabled"] as? Bool == false)
        #expect(audio["outputEnabled"] == nil)

        var cameraEnabled = defaults
        cameraEnabled.cameraConfiguration?.enabled = true
        let cameraWire = DorydMachineTypedSettingsPatch(
            baseline: defaults,
            desired: cameraEnabled
        ).xpcDictionary
        #expect(cameraWire.count == 1)
        #expect(cameraWire["cameraEnabled"] as? Bool == true)

        var translationEnabled = defaults
        translationEnabled.intelApplicationTranslationEnabled = true
        let translationWire = DorydMachineTypedSettingsPatch(
            baseline: defaults,
            desired: translationEnabled
        ).xpcDictionary
        #expect(translationWire.count == 1)
        #expect(translationWire["intelApplicationTranslationEnabled"] as? Bool == true)

        for (legacy, expected) in [("1", DoryDesktopGraphicsPreference.virgl),
                                   ("0", DoryDesktopGraphicsPreference.virglVenus)] {
            let settings = DorydMachineTypedSettings(
                legacyEnvironment: ["DORY_VIRGL_CLASSIC_ONLY": legacy],
                displayMode: .desktop
            )
            #expect(settings.graphicsPreference == expected)
            #expect(DorydMachineTypedSettingsPatch(
                baseline: settings,
                desired: settings
            ).xpcDictionary["desktopGraphicsPreference"] == nil)
        }

        let hostile = [
            "DORY_GUEST_USER": "../../unsafe-user",
            "DORY_GUEST_UID": "not-a-uid",
            "DORY_CLIPBOARD_POLICY": "invalid-and-must-remain",
            "DORY_DESKTOP_VMM": "invalid-and-must-remain",
            "DORY_DESKTOP_GRAPHICS": "invalid-and-must-remain",
        ]
        let baseline = DorydMachineTypedSettings(
            legacyEnvironment: hostile,
            displayMode: .desktop
        )
        #expect(baseline.guestIdentityIntent.account == nil)
        #expect(baseline.clipboardPolicy == .disabled)
        #expect(baseline.runtimePreference == .automatic)
        #expect(baseline.graphicsPreference == .automatic)
        var desired = baseline
        desired.guestIdentityIntent.account = DoryVMGuestAccountIntent(
            username: "developer"
        )
        let wire = DorydMachineTypedSettingsPatch(
            baseline: baseline,
            desired: desired
        ).xpcDictionary
        let identity = try #require(wire["guestIdentityIntent"] as? NSDictionary)
        let account = try #require(identity["account"] as? NSDictionary)
        #expect(account["username"] as? String == "developer")
        #expect(account["numericUserID"] == nil)
        #expect(wire["clipboardPolicy"] == nil)
        #expect(wire["desktopRuntimePreference"] == nil)
        #expect(wire["desktopGraphicsPreference"] == nil)
    }

    @Test func desktopAssetEnvironmentUsesSelectedDistribution() {
        for distro in DesktopMachineDistro.allCases {
            let environment = AppStore.desktopAssetEnvironment(
                processEnvironment: [
                    "DORY_DESKTOP_DISTRO": distro == .kali ? "ubuntu" : "kali",
                    "DORYD_DESKTOP_ROOTFS": "/tmp/rootfs.raw",
                ],
                distro: distro
            )

            #expect(environment["DORY_DESKTOP_DISTRO"] == distro.rawValue)
            #expect(environment["DORYD_DESKTOP_ROOTFS"] == "/tmp/rootfs.raw")
        }
    }

    @MainActor
    @Test func dorydIsTheOnlyProductionOwnerForDorysLocalEngine() {
        #expect(AppStore.dorydEngineEnabled(environment: [:]))
        #expect(AppStore.dorydEngineEnabled(environment: ["DORY_APP_USE_DORYD": "1"]))
        #expect(AppStore.dorydEngineEnabled(environment: ["DORY_APP_USE_DORYD": "0"]))
        #expect(AppStore.dorydEngineEnabled(environment: ["DORY_APP_DISABLE_DORYD": "1"]))
    }

    @Test func cleanInstallAttachWindowCoversSignedLaunchAgentStartup() {
        #expect(AppStore.dorydBackendAttachTimeout >= 60)
    }

    @Test func customDomainPatternsAcceptExactAndLeftmostWildcardOnly() {
        #expect(AppStore.normalizedCustomDomainPattern(" Admin.MyProject.Local. ") == "admin.myproject.local")
        #expect(AppStore.normalizedCustomDomainPattern("*.Tenant.Test") == "*.tenant.test")
        #expect(AppStore.normalizedCustomDomainPattern("localhost") == nil)
        #expect(AppStore.normalizedCustomDomainPattern("admin.*.local") == nil)
        #expect(AppStore.normalizedCustomDomainPattern("-admin.myproject.local") == nil)
    }

    @Test func doryCLIResolverPrefersBundledHelperOverAuxiliaryExecutable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DoryCLI-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let helpers = root.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let macOS = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let helper = helpers.appendingPathComponent("dory")
        let appExecutable = macOS.appendingPathComponent("Dory")
        _ = FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8))
        _ = FileManager.default.createFile(atPath: appExecutable.path, contents: Data())

        let resolved = DoryCLI.bundledPath(
            named: "dory",
            bundleURL: root,
            auxiliaryPath: appExecutable.path,
            isExecutable: { $0 == helper.path || $0 == appExecutable.path }
        )

        #expect(resolved == helper.path)
    }

    @Test func healthDiagnosticsUsesDorydHealthAndIdleWithoutLegacyCLIs() async throws {
        let recorder = HealthDiagnosticsCLIRunRecorder()
        let healthJSON = """
        {
          "results": [
            {"id":"socket.exists","status":"pass","code":"socket.ok","title":"Socket","detail":"ok"},
            {"id":"compat.docker","status":"pass","code":"compat.ok","title":"Compatibility","detail":"ok"}
          ]
        }
        """
        let idleStatus = try JSONDecoder().decode(IdleStatus.self, from: Data(
            """
            {"mode":"auto-idle","auto_idle_enabled":true,"can_sleep":true,"sleep_after_minutes":15,"blockers":[],"policy":{"sleepAfterMinutes":15,"keepPublishedPortsAwake":true,"keepKubernetesAwake":true,"keepPinnedProjectsAwake":true,"showWakeNotifications":true}}
            """.utf8
        ))

        let snapshot = await HealthDiagnostics.load(
            active: false,
            cli: URL(fileURLWithPath: "/tmp/dory"),
            daemonHealthJSON: { _ in healthJSON },
            daemonIncidents: { _ in
                [Incident(at: "2026-07-07T00:00:00Z", type: "engine.start", detail: "started")]
            },
            daemonIdleStatus: { idleStatus },
            daemonIdleHistory: { _ in
                [IdleHistoryEntry(at: "2026-07-07T00:00:00Z", state: "sleeping", detail: "idle")]
            },
            runCLI: { _, arguments, _ in
                recorder.record(arguments)
                return (false, "", "unexpected CLI command: \(arguments.joined(separator: " "))")
            }
        )

        #expect(snapshot.checks.map(\.id) == ["socket.exists", "compat.docker"])
        #expect(snapshot.idle?.mode == "auto-idle")
        #expect(snapshot.history.map(\.state) == ["sleeping"])
        #expect(snapshot.incidents.map(\.type) == ["engine.start"])
        #expect(recorder.commands.isEmpty)
    }

    @Test func engineStopAndSleepOutliveTheDefaultControlTimeout() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(engineShutdownReplyDelay: 0.05)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let client = DorydClient(endpoint: listener.endpoint, timeout: 0.01)
        #expect(try await client.engineStop() == DorydCommandResult(ok: true, message: ""))
        #expect(try await client.engineSleep() == DorydCommandResult(ok: true, message: ""))
    }

    @Test func machineListPrefersExactTypedSettingsAndRejectsMalformedClaims() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        service.setMachineTypedSettings("dev", [
            "guestIdentityIntent": [
                "account": [
                    "username": "developer",
                    "numericUserID": UInt32(1_000),
                ] as NSDictionary,
                "desktop": [
                    "distributionIdentifier": "ubuntu",
                    "displayName": "Ubuntu",
                ] as NSDictionary,
            ] as NSDictionary,
            "clipboardPolicy": [
                "text": "bidirectional", "image": "bidirectional", "files": "off",
            ] as NSDictionary,
            "desktopRuntimePreference": "accelerated",
            "desktopGraphicsPreference": "virgl-venus",
            "networkMode": "shared-nat",
            "portForwards": [[
                "id": "web",
                "transport": "tcp",
                "hostPort": 8_080,
                "guestPort": 80,
                "exposure": "loopback",
            ] as NSDictionary] as NSArray,
            "audio": [
                "inputEnabled": false,
                "outputEnabled": true,
            ] as NSDictionary,
            "cameraEnabled": true,
            "intelApplicationTranslationEnabled": true,
        ])
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let client = DorydClient(endpoint: listener.endpoint)
        let status = try #require((try await client.machineList()).first { $0.id == "dev" })
        #expect(status.environment.isEmpty)
        #expect(status.typedSettings?.guestIdentityIntent.account?.username == "developer")
        #expect(status.typedSettings?.guestIdentityIntent.desktop?.distributionIdentifier
            == "ubuntu")
        #expect(status.typedSettings?.runtimePreference == .accelerated)
        #expect(status.typedSettings?.graphicsPreference == .virglVenus)
        #expect(status.typedSettings?.networkMode == .sharedNAT)
        #expect(status.typedSettings?.portForwards == [
            DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
        ])
        #expect(status.typedSettings?.audioConfiguration == DoryVMAudioConfiguration(
            inputEnabled: false,
            outputEnabled: true
        ))
        #expect(status.typedSettings?.cameraConfiguration
            == DoryVMCameraConfiguration(enabled: true))
        #expect(status.typedSettings?.intelApplicationTranslationEnabled == true)

        service.setMachineTypedSettings("dev", ["unknown": "claim"])
        await #expect(throws: (any Error).self) {
            _ = try await client.machineList()
        }

        for malformed: NSDictionary in [
            ["audio": ["inputEnabled": 0, "outputEnabled": true]],
            ["cameraEnabled": 1],
            ["intelApplicationTranslationEnabled": 1],
            ["audio": ["inputEnabled": true]],
            ["portForwards": [[
                "id": "web", "transport": "tcp", "hostPort": 443,
                "guestPort": 80, "exposure": "loopback",
            ]]],
            [
                "networkMode": "disconnected",
                "portForwards": [[
                    "id": "web", "transport": "tcp", "hostPort": 8080,
                    "guestPort": 80, "exposure": "loopback",
                ]],
            ],
            [
                "audio": [
                    "inputEnabled": true,
                    "outputEnabled": true,
                    "route": "private-host-device",
                ],
            ],
        ] {
            service.setMachineTypedSettings("dev", malformed)
            await #expect(throws: (any Error).self) {
                _ = try await client.machineList()
            }
        }
    }

    @Test func machineListRequiresExactSavedStateEvidenceForSuspendedRows() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let client = DorydClient(endpoint: listener.endpoint)
        let valid: NSDictionary = [
            "schemaVersion": 1,
            "backend": "apple-virtualization-framework",
            "stateFileSHA256": String(repeating: "b", count: 64),
            "stateFileByteCount": UInt64(8192),
            "hostHardwareModel": "Mac16,1",
            "hostOperatingSystemBuild": "25G90",
            "createdAtUnixMilliseconds": Int64(1_787_318_400_000),
            "portable": false,
        ]
        service.setMachineState("dev", "suspended")
        service.setMachineSavedState("dev", valid)

        let suspended = try #require((try await client.machineList()).first { $0.id == "dev" })
        #expect(suspended.state == "suspended")
        #expect(suspended.savedState?.stateFileSHA256 == String(repeating: "b", count: 64))
        #expect(suspended.savedState?.stateFileByteCount == 8192)

        let malformed = valid.mutableCopy() as! NSMutableDictionary
        malformed["unknown"] = "claim"
        service.setMachineSavedState("dev", malformed)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineList()
        }

        let wrongWireType = valid.mutableCopy() as! NSMutableDictionary
        wrongWireType["schemaVersion"] = "1"
        service.setMachineSavedState("dev", wrongWireType)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineList()
        }

        let nonStringKey = valid.mutableCopy() as! NSMutableDictionary
        nonStringKey[NSNumber(value: 9)] = "claim"
        service.setMachineSavedState("dev", nonStringKey)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineList()
        }

        service.setMachineSavedState("dev", nil)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineList()
        }
    }

    @Test func machineListRequiresExactStructuredFailureAndOperationEvidence() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)
        let operationID = "01234567-89ab-4cde-8fab-0123456789ab"
        let validFailure: NSDictionary = [
            "schemaVersion": UInt16(1),
            "code": "readiness-timed-out",
            "occurredAtUnixMilliseconds": Int64(1_787_318_400_000),
            "operationID": operationID,
            "causalChain": ["readiness-gate"],
            "recoveryDisposition": "retry",
            "evidenceReferences": [[
                "kind": "journal",
                "identifier": operationID,
            ] as NSDictionary],
        ]
        let activeOperation: NSDictionary = [
            "operationID": operationID,
            "kind": "starting",
        ]
        service.setMachineFailure(
            "dev",
            validFailure,
            activeOperation: activeOperation
        )

        let valid = try #require((try await client.machineList()).first)
        #expect(valid.failure?.code == .readinessTimedOut)
        #expect(valid.failure?.causalChain == [.readinessGate])
        #expect(valid.failure?.recoveryDisposition == .retry)
        #expect(valid.failure?.operationID == operationID)
        #expect(valid.activeOperation?.operationID == operationID)
        #expect(valid.activeOperation?.kind == .starting)

        let unknown = validFailure.mutableCopy() as! NSMutableDictionary
        unknown["detail"] = "/private/opaque"
        service.setMachineFailure("dev", unknown, activeOperation: activeOperation)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineList()
        }

        let pathEvidence = validFailure.mutableCopy() as! NSMutableDictionary
        pathEvidence["evidenceReferences"] = [[
            "kind": "journal", "identifier": "/private/journal",
        ] as NSDictionary]
        service.setMachineFailure("dev", pathEvidence, activeOperation: activeOperation)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineList()
        }

        service.setMachineFailure(
            "dev",
            validFailure,
            activeOperation: [
                "operationID": operationID,
                "kind": "future-operation",
            ] as NSDictionary
        )
        await #expect(throws: (any Error).self) {
            _ = try await client.machineList()
        }
    }

    @Test func machineListRequiresExactFlightRecorderSummary() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        service.setMachineFlightRecorderSummary("dev", [
            "headSequence": UInt64(17),
            "available": true,
        ] as NSDictionary)
        let current = try #require((try await client.machineList()).first)
        #expect(current.flightRecorderHeadSequence == 17)
        #expect(current.flightRecorderAvailable)

        service.setMachineFlightRecorderSummary("dev", nil)
        let oldDaemon = try #require((try await client.machineList()).first)
        #expect(oldDaemon.flightRecorderHeadSequence == 0)
        #expect(!oldDaemon.flightRecorderAvailable)

        service.setMachineFlightRecorderSummary("dev", [
            "headSequence": "17",
            "available": true,
        ] as NSDictionary)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineList()
        }
    }

    @MainActor
    @Test func machineEventCursorRequiresExactOrderedSafeEvidence() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        let valid = FakeDorydService.machineEventBatchRow()
        service.setMachineEventBatch(valid)
        let batch = try await client.machineEvents(afterSequence: 4)
        #expect(batch.headSequence == 5)
        #expect(!batch.snapshotRequired)
        #expect(batch.events.map(\.sequence) == [5])
        #expect(batch.events.first?.status?.state == "running")

        let failureBatch = valid.mutableCopy() as! NSMutableDictionary
        let failureEvent = (valid["events"] as! [NSDictionary])[0]
            .mutableCopy() as! NSMutableDictionary
        let failureStatus = (failureEvent["status"] as! NSDictionary)
            .mutableCopy() as! NSMutableDictionary
        failureStatus["hasFailure"] = true
        failureStatus["failureCode"] = "helper-exited"
        failureStatus["recoveryDisposition"] = "retry"
        failureStatus["operationID"] = "01234567-89ab-4cde-8fab-0123456789ab"
        failureStatus["operationKind"] = "starting"
        failureEvent["status"] = failureStatus
        failureBatch["events"] = [failureEvent]
        service.setMachineEventBatch(failureBatch)
        let failed = try await client.machineEvents(afterSequence: 4)
        #expect(failed.events.first?.status?.failureCode == .helperExited)
        #expect(failed.events.first?.status?.recoveryDisposition == .retry)
        #expect(failed.events.first?.status?.operationKind == .starting)

        let truncatedFailureBatch = failureBatch.mutableCopy() as! NSMutableDictionary
        let truncatedEvent = failureEvent.mutableCopy() as! NSMutableDictionary
        let truncatedStatus = failureStatus.mutableCopy() as! NSMutableDictionary
        truncatedStatus.removeObject(forKey: "recoveryDisposition")
        truncatedEvent["status"] = truncatedStatus
        truncatedFailureBatch["events"] = [truncatedEvent]
        service.setMachineEventBatch(truncatedFailureBatch)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineEvents(afterSequence: 4)
        }

        let eventRows = valid["events"] as! [NSDictionary]
        let invalidStatusEvent = eventRows[0].mutableCopy() as! NSMutableDictionary
        let invalidStatus = (invalidStatusEvent["status"] as! NSDictionary)
            .mutableCopy() as! NSMutableDictionary
        invalidStatus["hostPath"] = "/private/source"
        invalidStatusEvent["status"] = invalidStatus
        let invalidStatusBatch = valid.mutableCopy() as! NSMutableDictionary
        invalidStatusBatch["events"] = [invalidStatusEvent]
        service.setMachineEventBatch(invalidStatusBatch)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineEvents(afterSequence: 4)
        }

        let gap = valid.mutableCopy() as! NSMutableDictionary
        let gapEvent = eventRows[0].mutableCopy() as! NSMutableDictionary
        gapEvent["sequence"] = UInt64(6)
        gap["headSequence"] = UInt64(6)
        gap["events"] = [gapEvent]
        service.setMachineEventBatch(gap)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineEvents(afterSequence: 4)
        }

        let contradictory = valid.mutableCopy() as! NSMutableDictionary
        contradictory["snapshotRequired"] = true
        service.setMachineEventBatch(contradictory)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineEvents(afterSequence: 4)
        }
    }

    @MainActor
    @Test func appStoreUsesMachineEventCursorWithSnapshotFallback() async throws {
        let base = "/tmp/dory-events-app-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        service.setMachineEventBatch([
            "schemaVersion": UInt16(1),
            "headSequence": UInt64(1),
            "snapshotRequired": true,
            "events": [] as [NSDictionary],
        ])
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        try await waitUntil {
            service.machineEventQueryCount >= 1
                && service.machineListCount >= 1
                && store.machines.contains(where: { $0.name == "dev" })
        }

        let initialLists = service.machineListCount
        let initialQueries = service.machineEventQueryCount
        service.setMachineEventBatch([
            "schemaVersion": UInt16(1),
            "headSequence": UInt64(1),
            "snapshotRequired": false,
            "events": [] as [NSDictionary],
        ])
        store.loadMachines()
        try await waitUntil { service.machineEventQueryCount > initialQueries }
        try await Task.sleep(for: .milliseconds(50))
        #expect(service.machineListCount == initialLists)

        let beforeChangedList = service.machineListCount
        service.setMachineEventBatch(
            FakeDorydService.machineEventBatchRow(sequence: 2)
        )
        store.loadMachines()
        try await waitUntil { service.machineListCount > beforeChangedList }

        let beforeFallbackList = service.machineListCount
        service.setMachineEventBatch([:])
        store.loadMachines()
        try await waitUntil { service.machineListCount > beforeFallbackList }
    }

    @MainActor
    @Test func machineFlightRecorderRequiresExactPathFreeCursorEvidence() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        let event: NSDictionary = [
            "schemaVersion": UInt16(1),
            "sequence": UInt64(1),
            "occurredAtUnixMilliseconds": Int64(1_000),
            "machineID": "dev",
            "kind": "workspace-created",
            "evidenceReferences": [] as [NSDictionary],
        ]
        let valid: NSDictionary = [
            "schemaVersion": UInt16(1),
            "machineID": "dev",
            "headSequence": UInt64(1),
            "snapshotRequired": false,
            "events": [event],
        ]
        service.setMachineFlightRecorderBatch(valid)
        let batch = try await client.machineFlightRecorder(
            machineID: "dev",
            afterSequence: 0
        )
        #expect(batch.headSequence == 1)
        #expect(batch.events.first?.kind == .workspaceCreated)

        let leakedEvent = event.mutableCopy() as! NSMutableDictionary
        leakedEvent["detail"] = "/private/opaque"
        let leaked = valid.mutableCopy() as! NSMutableDictionary
        leaked["events"] = [leakedEvent]
        service.setMachineFlightRecorderBatch(leaked)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineFlightRecorder(
                machineID: "dev",
                afterSequence: 0
            )
        }

        let gapEvent = event.mutableCopy() as! NSMutableDictionary
        gapEvent["sequence"] = UInt64(2)
        let gap = valid.mutableCopy() as! NSMutableDictionary
        gap["headSequence"] = UInt64(2)
        gap["events"] = [gapEvent]
        service.setMachineFlightRecorderBatch(gap)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineFlightRecorder(
                machineID: "dev",
                afterSequence: 0
            )
        }

        let deviceEvent = event.mutableCopy() as! NSMutableDictionary
        deviceEvent["kind"] = "device-health-event"
        deviceEvent["operationID"] = "12345678-1234-4234-8234-123456789abc"
        deviceEvent["operationKind"] = "starting"
        deviceEvent["deviceID"] = "virtio-network-7"
        deviceEvent["deviceEventKind"] = "queue-stall"
        deviceEvent["deviceEventSequence"] = UInt64(1)
        deviceEvent["deviceEventOccurrences"] = UInt64(2)
        let deviceBatch = valid.mutableCopy() as! NSMutableDictionary
        deviceBatch["events"] = [deviceEvent]
        service.setMachineFlightRecorderBatch(deviceBatch)
        let deviceFlight = try await client.machineFlightRecorder(
            machineID: "dev",
            afterSequence: 0
        )
        #expect(deviceFlight.events.first?.kind == .deviceHealthEvent)
        #expect(deviceFlight.events.first?.deviceID == "virtio-network-7")
        #expect(deviceFlight.events.first?.deviceEventKind == "queue-stall")
        #expect(deviceFlight.events.first?.deviceEventOccurrences == 2)

        deviceEvent.removeObject(forKey: "deviceEventOccurrences")
        service.setMachineFlightRecorderBatch(deviceBatch)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineFlightRecorder(
                machineID: "dev",
                afterSequence: 0
            )
        }
    }

    @MainActor
    @Test func machineDeviceTelemetryRequiresExactBoundedLaunchEvidence() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        let operationID = "12345678-1234-4234-8234-123456789abc"
        let metric: NSDictionary = [
            "kind": "receive-drops",
            "unit": "count",
            "availability": "measured",
            "value": UInt64(2),
        ]
        let device: NSDictionary = [
            "id": "virtio-network-7",
            "kind": "network",
            "health": "degraded",
            "metrics": [
                metric,
                [
                    "kind": "configured-port-forwards",
                    "unit": "count",
                    "availability": "measured",
                    "value": UInt64(2),
                ] as NSDictionary,
                [
                    "kind": "active-port-forwards",
                    "unit": "count",
                    "availability": "measured",
                    "value": UInt64(1),
                ] as NSDictionary,
                [
                    "kind": "port-forward-reconciliation-failures",
                    "unit": "count",
                    "availability": "measured",
                    "value": UInt64(3),
                ] as NSDictionary,
            ],
        ]
        let event: NSDictionary = [
            "sequence": UInt64(1),
            "monotonicNanoseconds": UInt64(20),
            "deviceID": "virtio-network-7",
            "kind": "queue-stall",
            "occurrences": UInt64(2),
        ]
        let valid: NSDictionary = [
            "schemaVersion": UInt16(1),
            "machineID": "dev",
            "operationID": operationID,
            "backend": "apple-virtualization-framework",
            "sampleSequence": UInt64(1),
            "sampledAtUnixMilliseconds": UInt64(10),
            "monotonicNanoseconds": UInt64(20),
            "devices": [device],
            "events": [event],
        ]
        service.setMachineDeviceTelemetryResponse(valid)
        let snapshot = try await client.machineDeviceTelemetry("dev")
        #expect(snapshot.operationID == operationID)
        #expect(snapshot.backend == .appleVirtualizationFramework)
        #expect(snapshot.devices.first?.metrics.first?.value == 2)
        #expect(snapshot.devices.first?.metrics.last?.kind == "port-forward-reconciliation-failures")
        #expect(snapshot.devices.first?.metrics.last?.value == 3)
        #expect(snapshot.events.first?.kind == "queue-stall")
        #expect(snapshot.events.first?.occurrences == 2)

        let recoveryEvent = event.mutableCopy() as! NSMutableDictionary
        recoveryEvent["sequence"] = UInt64(2)
        recoveryEvent["kind"] = "port-forward-recovered"
        let validWithRecovery = valid.mutableCopy() as! NSMutableDictionary
        validWithRecovery["events"] = [event, recoveryEvent]
        service.setMachineDeviceTelemetryResponse(validWithRecovery)
        let recovered = try await client.machineDeviceTelemetry("dev")
        #expect(recovered.events.last?.kind == "port-forward-recovered")

        let unavailableWithValue: NSDictionary = [
            "kind": "receive-drops",
            "unit": "count",
            "availability": "unavailable",
            "unavailableReason": "framework API unavailable",
            "value": UInt64(0),
        ]
        let invalidDevice = device.mutableCopy() as! NSMutableDictionary
        invalidDevice["metrics"] = [unavailableWithValue]
        let invalidMetricShape = valid.mutableCopy() as! NSMutableDictionary
        invalidMetricShape["devices"] = [invalidDevice]

        let wrongUnitMetric = metric.mutableCopy() as! NSMutableDictionary
        wrongUnitMetric["unit"] = "bytes"
        let wrongUnitDevice = device.mutableCopy() as! NSMutableDictionary
        wrongUnitDevice["metrics"] = [wrongUnitMetric]
        let invalidMetricUnit = valid.mutableCopy() as! NSMutableDictionary
        invalidMetricUnit["devices"] = [wrongUnitDevice]

        let orphanEvent = event.mutableCopy() as! NSMutableDictionary
        orphanEvent["deviceID"] = "virtio-storage-9"
        let invalidEventAuthority = valid.mutableCopy() as! NSMutableDictionary
        invalidEventAuthority["events"] = [orphanEvent]

        for malformed in [
            valid.adding("hostPath", "/private/opaque"),
            valid.replacing("sampleSequence", with: true),
            invalidMetricShape,
            invalidMetricUnit,
            invalidEventAuthority,
        ] {
            service.setMachineDeviceTelemetryResponse(malformed)
            await #expect(throws: (any Error).self) {
                _ = try await client.machineDeviceTelemetry("dev")
            }
        }
    }

    @MainActor
    @Test func machineSerialConsoleRequiresExactBoundedCursorEvidence() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)
        let generation = String(repeating: "a", count: 64)
        service.setMachineSerialConsoleBatch([
            "schemaVersion": UInt16(1),
            "machineID": "dev",
            "generation": generation,
            "startOffset": UInt64(0),
            "nextOffset": UInt64(4),
            "totalBytes": UInt64(4),
            "snapshotRequired": true,
            "inputAvailable": false,
            "bytesBase64": Data("boot".utf8).base64EncodedString(),
        ])
        let initial = try await client.machineSerialConsole(machineID: "dev", limit: 64)
        #expect(initial.bytes == Data("boot".utf8))
        #expect(initial.snapshotRequired)
        #expect(initial.cursor.generation == generation)
        #expect(initial.cursor.offset == 4)
        #expect(service.latestMachineSerialConsoleCursor?["offset"] as? UInt64 == 0)

        service.setMachineSerialConsoleBatch([
            "schemaVersion": UInt16(1),
            "machineID": "dev",
            "generation": generation,
            "startOffset": UInt64(4),
            "nextOffset": UInt64(10),
            "totalBytes": UInt64(10),
            "snapshotRequired": false,
            "inputAvailable": true,
            "bytesBase64": Data("ready\n".utf8).base64EncodedString(),
        ])
        let appended = try await client.machineSerialConsole(
            machineID: "dev",
            cursor: initial.cursor,
            limit: 64
        )
        #expect(appended.bytes == Data("ready\n".utf8))
        #expect(!appended.snapshotRequired)
        #expect(appended.inputAvailable)

        let valid = service.machineSerialConsoleBatchResponse
        for malformed in [
            valid.adding("hostPath", "/private/opaque"),
            valid.replacing("bytesBase64", with: "not-base64"),
            valid.replacing("startOffset", with: UInt64(3)),
            valid.replacing("snapshotRequired", with: 0),
        ] {
            service.setMachineSerialConsoleBatch(malformed)
            await #expect(throws: (any Error).self) {
                _ = try await client.machineSerialConsole(
                    machineID: "dev",
                    cursor: initial.cursor,
                    limit: 64
                )
            }
        }

        service.setMachineSerialConsoleBatch(nil)
        let write = try await client.writeMachineSerialConsole(
            machineID: "dev",
            data: Data("recovery\n".utf8)
        )
        #expect(write.ok)
        #expect(service.latestMachineSerialConsoleInput == Data("recovery\n".utf8))
        await #expect(throws: (any Error).self) {
            _ = try await client.writeMachineSerialConsole(
                machineID: "dev",
                data: Data(repeating: 1, count: 4 * 1_024 + 1)
            )
        }
    }

    @MainActor
    @Test func machineImportAssessmentRequiresExactClosedEvidence() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        let valid = FakeDorydService.importAssessmentRow()
        service.setMachineImportAssessment(valid)
        let assessment = try await client.machineAssessSnapshotImport(
            from: "/tmp/dev.dorymachine"
        )
        #expect(assessment.contentID == String(repeating: "a", count: 64))
        #expect(assessment.disposition == .ready)
        #expect(assessment.portable)

        let unknown = valid.mutableCopy() as! NSMutableDictionary
        unknown["unexpected"] = "claim"
        service.setMachineImportAssessment(unknown)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineAssessSnapshotImport(from: "/tmp/dev.dorymachine")
        }

        let wrongWireType = valid.mutableCopy() as! NSMutableDictionary
        wrongWireType["diskSizeBytes"] = "4096"
        service.setMachineImportAssessment(wrongWireType)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineAssessSnapshotImport(from: "/tmp/dev.dorymachine")
        }

        let contradictory = valid.mutableCopy() as! NSMutableDictionary
        contradictory["disposition"] = "requires-components"
        service.setMachineImportAssessment(contradictory)
        await #expect(throws: (any Error).self) {
            _ = try await client.machineAssessSnapshotImport(from: "/tmp/dev.dorymachine")
        }
    }

    @MainActor
    @Test func readsDoctorJSONAndIncidentsOverXPC() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let client = DorydClient(endpoint: listener.endpoint)
        let version = try await client.protocolVersion()
        let socketPath = try await client.dorySocketPath()
        let engineStatus = try await client.engineStatus()
        let started = try await client.engineStart()
        let slept = try await client.engineSleep()
        let woke = try await client.engineWake()
        let dockerAgentInfo = try await client.dockerAgentInfo()
        let dockerAgentPorts = try await client.dockerAgentPorts()
        let dockerAgentTelemetry = try await client.dockerAgentTelemetry()
        let stopped = try await client.engineStop()
        let shareBookmark = Data([0x44, 0x4f, 0x52, 0x59])
        let createdMachine = try await client.machineCreate(DorydMachineConfiguration(
            id: "dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs",
            memoryMB: 2048,
            cpuCount: 2,
            address: "192.168.215.40",
            displayMode: .desktop,
            shares: [
                DorydMachineShareConfiguration(
                    tag: "src",
                    hostPath: "/Users/me/src",
                    guestPath: "/workspace/src",
                    readOnly: true,
                    authorizationBookmark: shareBookmark
                ),
            ],
            typedSettings: DorydMachineTypedSettings(
                guestIdentityIntent: DoryVMGuestIdentityIntent(
                    account: DoryVMGuestAccountIntent(
                        username: "developer",
                        numericUserID: 1_000
                    ),
                    desktop: DoryVMDesktopIdentityIntent(
                        distributionIdentifier: "ubuntu",
                        displayName: "Ubuntu",
                        version: "24.04",
                        desktopEnvironment: "GNOME"
                    )
                ),
                clipboardPolicy: .legacyDesktop(.bidirectional),
                runtimePreference: .accelerated,
                graphicsPreference: .virglVenus,
                networkMode: .sharedNAT,
                portForwards: [
                    DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
                ]
            )
        ))
        let startOperationID = UUID(uuidString: "01234567-89ab-4cde-8f01-23456789abcd")!
        let startedMachine = try await client.machineStart(
            "dev",
            operationID: startOperationID
        )
        #expect(
            service.latestMachineStartOperationID
                == startOperationID.uuidString.lowercased()
        )
        let pauseOperationID = UUID(uuidString: "12345678-9abc-4def-8012-3456789abcde")!
        let pausedMachine = try await client.machinePause(
            "dev",
            operationID: pauseOperationID
        )
        #expect(
            service.latestMachinePauseOperationID
                == pauseOperationID.uuidString.lowercased()
        )
        let resumeOperationID = UUID(uuidString: "23456789-abcd-4ef0-8123-456789abcdef")!
        let resumedMachine = try await client.machineResume(
            "dev",
            operationID: resumeOperationID
        )
        #expect(
            service.latestMachineResumeOperationID
                == resumeOperationID.uuidString.lowercased()
        )
        let restartedMachine = try await client.machineRestart("dev")
        let machineStats = try await client.machineStats("dev")
        let execResult = try await client.machineExec("dev", argv: ["/bin/sh", "-lc", "cargo --version"])
        let provisionedMachine = try await client.machineProvision("dev", recipe: "rust")
        let desktopUpdateOperationID = UUID(
            uuidString: "456789ab-cdef-4012-8345-6789abcdef01"
        )!
        let desktopUpdate = try await client.machineDesktopUpdate(
            "dev",
            operationID: desktopUpdateOperationID,
            distro: "ubuntu",
            version: "24.04+runtime.1",
            distributionInstallationName: "ubuntu-installation",
            runtimeInstallationName: "runtime-installation"
        )
        let snapshot = try await client.machineSnapshot(
            "dev",
            note: "before",
            createdISO: "2026-07-07T00:00:00Z",
            snapshotID: "s1"
        )
        let snapshots = try await client.machineSnapshots(machineID: "dev")
        let clonedSnapshot = try await client.machineCloneSnapshot(machineID: "dev", snapshotID: "s1", newID: "dev-copy")
        let restoredSnapshot = try await client.machineRestoreSnapshot(machineID: "dev", snapshotID: "s1")
        let exportedSnapshot = try await client.machineExportSnapshot(machineID: "dev", snapshotID: "s1", to: "/tmp/dev.dorymachine")
        let importedSnapshot = try await client.machineImportSnapshot(from: "/tmp/dev.dorymachine")
        let savedBackup = try await client.machineBackupSet(DorydMachineBackupSchedule(
            machineID: "dev",
            enabled: true,
            frequency: .daily,
            keepLocal: 5,
            verifyEveryRuns: 3
        ))
        let backupSchedules = try await client.machineBackupSchedules()
        let completedBackup = try await client.machineBackupRun(machineID: "dev")
        let removedBackup = try await client.machineBackupRemove(machineID: "dev")
        let deletedSnapshot = try await client.machineDeleteSnapshot(machineID: "dev", snapshotID: "s1")
        let stopOperationID = UUID(uuidString: "3456789a-bcde-4f01-8234-56789abcdef0")!
        let stoppedMachine = try await client.machineStop(
            "dev",
            operationID: stopOperationID
        )
        #expect(
            service.latestMachineStopOperationID
                == stopOperationID.uuidString.lowercased()
        )
        let refreshedKernel = try await client.machineRefreshManagedDesktopKernel(
            "dev",
            sourcePath: "/vm/.assets/dory-desktop-kernel-arm64",
            sourceSHA256: String(repeating: "a", count: 64)
        )
        let updatedMachine = try await client.machineUpdate(
            "dev",
            memoryMB: 4096,
            cpuCount: 4,
            address: "192.168.215.41",
            typedSettings: DorydMachineTypedSettings(
                guestIdentityIntent: DoryVMGuestIdentityIntent(
                    account: DoryVMGuestAccountIntent(username: "builder")
                ),
                clipboardPolicy: .legacyDesktop(.hostToGuest),
                runtimePreference: .compatible,
                graphicsPreference: .software,
                networkMode: .sharedNAT
            )
        )
        let machines = try await client.machineList()
        let deletedMachine = try await client.machineDelete("dev")
        let remoteInfo = try await client.remoteConnect(DorydRemoteMachineConfiguration(
            id: "vps",
            host: "vps.example.com",
            port: 22,
            user: "dory",
            privateKeyID: "primary",
            hostKeyType: "pinned",
            hostKey: "ssh-ed25519 AAAA fake",
            knownHostsPath: nil,
            knownHostsHost: nil,
            knownHostsPort: nil,
            endpointType: "unix",
            endpointPath: "/run/dory/agent.sock",
            endpointHost: nil,
            endpointPort: nil,
            remoteRoot: "/srv/app",
            build: "test"
        ))
        let pushStats = try await client.remotePush(machineID: "vps", localRoot: "/tmp/local")
        let remoteStatus = try await client.remoteStatus(machineID: "vps")
        let replacedRoutes = try await client.networkReplaceRoutes([
            DorydDomainRoute(
                hostname: "web.default.k8s.dory.local",
                address: "127.0.0.1",
                port: 18_001,
                pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy"
            ),
        ])
        let networkStatus = try await client.networkStatus()
        let networkPlan = try await client.networkAuthorizationPlan()
        let repairedNetwork = try await client.repairSubsystem("dns")
        let balloonPlan = try await client.balloonStatus()
        let reconciledBalloonPlan = try await client.balloonReconcile()
        let idleStatus = try await client.idleStatus()
        let idleHistory = try await client.idleHistory(limit: 40)
        let updatedIdlePolicy = try await client.idleSetPolicy(key: "sleepAfterMinutes", value: "30")
        let updatedIdleMode = try await client.idleSetMode("manual")
        let healthJSON = try await client.healthJSON()
        let health = try JSONDecoder().decode(DoctorReport.self, from: Data(healthJSON.utf8))
        let doctorJSON = try await client.doctorJSON()
        let report = try JSONDecoder().decode(DoctorReport.self, from: Data(doctorJSON.utf8))
        let incidents = try await client.incidents(limit: 40)

        #expect(version == 1)
        #expect(socketPath == service.socketPath)
        #expect(engineStatus == DorydEngineStatus(state: "running", detail: "ok"))
        #expect(started == DorydCommandResult(ok: true, message: ""))
        #expect(slept == DorydCommandResult(ok: true, message: ""))
        #expect(woke == DorydCommandResult(ok: true, message: ""))
        #expect(dockerAgentInfo.agentBuild == "docker-agent")
        #expect(dockerAgentInfo.capabilities.map(\.id) == [
            "clock-sync", "exec", "exec-stdin", "ports-watch", "telemetry",
        ])
        #expect(dockerAgentPorts.ports == [DorydListenPort(protocol: "tcp", port: 8080)])
        #expect(dockerAgentPorts.added == [DorydListenPort(protocol: "tcp", port: 8080)])
        #expect(dockerAgentTelemetry.memTotalKB == 2048)
        #expect(stopped == DorydCommandResult(ok: true, message: ""))
        #expect(
            service.latestMachineDesktopUpdateOperationID
                == desktopUpdateOperationID.uuidString.lowercased()
        )
        #expect(desktopUpdate.operationID == desktopUpdateOperationID.uuidString.lowercased())
        #expect(refreshedKernel.id == "dev")
        #expect(
            service.latestManagedDesktopKernelRefreshRequest?["sourcePath"] as? String
                == "/vm/.assets/dory-desktop-kernel-arm64"
        )
        let createShares = try #require(
            service.latestMachineCreateConfig?["shares"] as? [NSDictionary]
        )
        #expect(createShares.first?["authorizationBookmark"] as? Data == shareBookmark)
        let createForwards = try #require(
            service.latestMachineCreateConfig?["portForwards"] as? NSArray
        )
        #expect((createForwards.firstObject as? NSDictionary)?["hostPort"] as? Int == 8_080)
        #expect(createdMachine.state == "created")
        #expect(createdMachine.displayMode == .desktop)
        #expect(startedMachine.pid == 1234)
        #expect(startedMachine.agentBuild == "agent-test")
        #expect(startedMachine.agentSocketPath == "/tmp/agent.sock")
        #expect(startedMachine.address == "192.168.215.40")
        #expect(startedMachine.configuredAddress == "192.168.215.40")
        #expect(startedMachine.runtimeIdentity == .legacyCompatibility)
        #expect(startedMachine.shares == [
            DorydMachineShareConfiguration(tag: "src", hostPath: "/Users/me/src", guestPath: "/workspace/src", readOnly: true),
        ])
        #expect(startedMachine.environment["DORY_GUEST_USER"] == "developer")
        #expect(startedMachine.environment["DORY_DESKTOP_DISTRO"] == "ubuntu")
        #expect(startedMachine.displayMode == .desktop)
        #expect(pausedMachine.state == "paused")
        #expect(pausedMachine.pid == startedMachine.pid)
        #expect(resumedMachine.state == "running")
        #expect(resumedMachine.pid == startedMachine.pid)
        #expect(restartedMachine.state == "running")
        #expect(restartedMachine.pid == 1235)
        #expect(execResult.stdout == "cargo 1.0\n")
        #expect(execResult.exitCode == 0)
        #expect(machineStats.cpuPercent == 12.5)
        #expect(machineStats.memoryUsedBytes == 1_073_741_824)
        #expect(machineStats.memoryTotalBytes == 2_147_483_648)
        #expect(machineStats.processCount == 12)
        #expect(provisionedMachine.recipeID == "rust")
        #expect(provisionedMachine.verify.stdout == "cargo 1.0\n")
        #expect(snapshot.id == "s1")
        #expect(snapshot.machineID == "dev")
        #expect(snapshot.runtimeIdentity == .legacyCompatibility)
        #expect(snapshot.consistency == .coldStopped)
        #expect(snapshot.guestQuiesceReceipt == nil)
        #expect(snapshots.map(\.id).contains("s1"))
        #expect(clonedSnapshot.id == "dev-copy")
        #expect(restoredSnapshot.id == "dev")
        #expect(exportedSnapshot == DorydCommandResult(ok: true, message: ""))
        #expect(importedSnapshot.machineID == "dev")
        #expect(savedBackup.schedule.keepLocal == 5)
        #expect(savedBackup.schedule.verifyEveryRuns == 3)
        #expect(backupSchedules.map(\.schedule.machineID) == ["dev"])
        #expect(completedBackup.successfulRuns == 1)
        #expect(completedBackup.lastBootVerificationISO == "2026-07-07T00:00:00Z")
        #expect(removedBackup == DorydCommandResult(ok: true, message: ""))
        #expect(deletedSnapshot == DorydCommandResult(ok: true, message: ""))
        #expect(stoppedMachine.state == "stopped")
        #expect(updatedMachine.memoryMB == 4096)
        #expect(updatedMachine.cpuCount == 4)
        #expect(updatedMachine.address == "192.168.215.41")
        #expect(updatedMachine.environment["DORY_GUEST_USER"] == "builder")
        #expect(updatedMachine.environment["DORY_CLIPBOARD_POLICY"] == "host-to-guest")
        #expect(updatedMachine.environment["DORY_DESKTOP_VMM"] == "compatible")
        #expect(updatedMachine.environment["DORY_DESKTOP_GRAPHICS"] == "software")
        #expect(machines.map(\.id) == ["dev", "dev-copy"])
        #expect(deletedMachine == DorydCommandResult(ok: true, message: ""))
        #expect(remoteInfo.agentBuild == "remote-agent")
        #expect(remoteInfo.capabilities.map(\.id) == ["exec", "sync-push", "telemetry"])
        #expect(pushStats == DorydPushStats(filesSent: 2, bytesSent: 30, filesDeleted: 1))
        #expect(remoteStatus.telemetry?.memAvailableKB == 512)
        #expect(replacedRoutes == DorydCommandResult(ok: true, message: ""))
        #expect(networkStatus.mode == "high-port-dns-http-https-proxy")
        #expect(networkStatus.httpProxyPort == 18080)
        #expect(networkStatus.httpProxyRunning)
        #expect(networkStatus.httpsProxyPort == 18443)
        #expect(networkStatus.httpsProxyRunning)
        #expect(networkStatus.routes == [
            DorydDomainRoute(
                hostname: "web.default.k8s.dory.local",
                address: "127.0.0.1",
                port: 18_001,
                pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy"
            ),
        ])
        #expect(networkStatus.customRoutes == networkStatus.routes)
        #expect(networkPlan.suffix == "dory.local")
        #expect(networkPlan.dnsBindAddress == "127.0.0.1")
        #expect(networkPlan.dnsPort == 15353)
        #expect(networkPlan.httpProxyPort == 18080)
        #expect(networkPlan.httpsProxyPort == 18443)
        #expect(networkPlan.privilegedTCPForwards == [
            DorydPrivilegedTCPForward(listenPort: 25, targetPort: 1025),
        ])
        #expect(networkPlan.requests.map(\.kind) == ["resolverFile"])
        #expect(repairedNetwork == DorydCommandResult(ok: true, message: "repaired dns"))
        #expect(balloonPlan.host.pressure == "warning")
        #expect(balloonPlan.applicableTargets.map(\.id) == ["docker"])
        #expect(reconciledBalloonPlan.host.pressure == "warning")
        #expect(reconciledBalloonPlan.applicableTargets.map(\.id) == ["docker"])
        #expect(idleStatus.mode == "always-on")
        #expect(idleHistory.map(\.state) == ["sleeping"])
        #expect(updatedIdlePolicy.policy?.sleepAfterMinutes == 30)
        #expect(updatedIdleMode.mode == "manual")
        #expect(health.results.map(\.id) == ["socket.exists", "machine.local"])
        #expect(report.results.map(\.id) == ["socket.exists"])
        #expect(report.results.first?.status == "pass")
        #expect(incidents == [
            Incident(at: "2026-07-07T00:00:00Z", type: "engine.start", detail: "started")
        ])
    }

    @Test func presentInvalidRuntimeIdentityFailsStatusAndSnapshotClosed() async throws {
        let resolvedWithoutComponentsOrMedia = NSMutableDictionary(
            dictionary: validResolvedRuntimeIdentity()
        )
        resolvedWithoutComponentsOrMedia.removeObject(forKey: "components")
        resolvedWithoutComponentsOrMedia.removeObject(forKey: "bootMedia")
        let mixedQualification = NSMutableDictionary(
            dictionary: validResolvedRuntimeIdentity()
        )
        mixedQualification["runtimeQualification"] = [
            "qualificationIdentity": "runtime-qualification-1",
            "qualificationReportSHA256": String(repeating: "3", count: 64),
            "signingKeyID": "dory-runtime-1",
            "manifestIdentity": "wrong-shape-field",
        ]
        let orphanProvenance = NSMutableDictionary(
            dictionary: validResolvedRuntimeIdentity()
        )
        orphanProvenance["bootMedia"] = [
            "kind": "installed-linux-boot-bundle",
            "source": "user-provided",
            "artifactSHA256": String(repeating: "6", count: 64),
            "provenanceReceiptIdentity": "orphan-receipt",
        ]
        let unsupportedGraphics = NSMutableDictionary(
            dictionary: validResolvedRuntimeIdentity()
        )
        unsupportedGraphics["graphics"] = "automatic"
        for identity in [
            [
                "schemaVersion": 2,
                "mode": "legacy-compatibility",
                "virtualHardwareABIVersion": 1,
            ] as NSDictionary,
            [
                "schemaVersion": 1,
                "mode": "legacy-compatibility",
                "virtualHardwareABIVersion": 1,
                "components": [[
                    "componentIdentifier": "dory-hv",
                    "buildIdentifier": "runtime-1",
                    "artifactSHA256": String(repeating: "a", count: 64),
                ]],
            ] as NSDictionary,
            resolvedWithoutComponentsOrMedia,
            mixedQualification,
            orphanProvenance,
            unsupportedGraphics,
        ] {
            let listener = NSXPCListener.anonymous()
            let service = FakeDorydService(runtimeIdentityOverride: identity)
            let delegate = FakeDorydListenerDelegate(service: service)
            listener.delegate = delegate
            listener.resume()
            defer { listener.invalidate() }
            let client = DorydClient(endpoint: listener.endpoint)

            do {
                _ = try await client.machineList()
                Issue.record("present invalid status identity must fail closed")
            } catch let error as DorydClientError {
                #expect(error.description.contains("invalid machine list"))
            }

            do {
                _ = try await client.machineSnapshot(
                    "dev",
                    note: "invalid identity",
                    createdISO: "2026-07-07T00:00:00Z",
                    snapshotID: "invalid-identity"
                )
                Issue.record("present invalid snapshot identity must fail closed")
            } catch let error as DorydClientError {
                #expect(error.description.contains("invalid doryd response"))
            }
        }
    }

    @Test func machineRuntimeEvidenceSurfacesPlanGraphicsBackendAndGuestTools() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(runtimeIdentityOverride: validResolvedRuntimeIdentity())
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let status = try #require(
            (try await DorydClient(endpoint: listener.endpoint).machineList()).first
        )
        #expect(status.runtimeGraphicsSelection?.isQualifiedAcceleration == true)
        #expect(status.runtimeIdentity.authorizesRemovableUSBHotplug)
        #expect(UsbPassthroughAvailability.attachSupported(for: status))
        let machine = AppStore.machine(fromDoryd: status)
        #expect(machine.runtimeIdentity.graphics == "hardware-accelerated-3d")
        #expect(machine.runtimeGraphicsSelection?.backend == "virgl-venus")
        #expect(machine.agentProtocolVersion == 1)
        #expect(machine.agentCapabilities.map(\.id) == [
            "clock-sync", "exec", "exec-stdin", "ports-watch", "snapshot-quiesce", "sync-push",
            "telemetry",
        ])
        #expect(machine.runtimeEvidence.map(\.label) == [
            "Supported", "Raw HV", "Qualified 3D", "Tools partially ready",
        ])
        #expect(machine.runtimeEvidence.first { $0.id == "authority" }?.detail
            == "runtime-qualification-1")

        let missingFence = NSMutableDictionary(
            dictionary: try #require(service.machineRuntimeGraphicsSelection("dev"))
        )
        missingFence.removeObject(forKey: "guestProducerFenceProofSHA256")
        service.setMachineRuntimeGraphicsSelection("dev", missingFence)
        await #expect(throws: DorydClientError.self) {
            _ = try await DorydClient(endpoint: listener.endpoint).machineList()
        }
        service.setMachineRuntimeGraphicsSelection(
            "dev",
            try #require(service.defaultRuntimeGraphicsSelection("dev"))
        )

        var replanning = machine
        replanning.runtimeIdentity = DorydMachineRuntimeIdentity(
            schemaVersion: 1,
            mode: "requires-replanning",
            virtualHardwareABIVersion: 1,
            invalidationReason: "restored-snapshot"
        )
        replanning.agentBuild = nil
        replanning.agentProtocolVersion = nil
        replanning.agentCapabilities = []
        #expect(replanning.runtimeEvidence.map(\.label) == [
            "Needs planning", "Tools unavailable",
        ])

        var legacyHandshake = machine
        legacyHandshake.agentProtocolVersion = nil
        legacyHandshake.agentCapabilities = []
        #expect(legacyHandshake.runtimeEvidence.last?.label == "Tools unavailable")

        var partialHandshake = machine
        partialHandshake.agentCapabilities = [DorydAgentCapability(id: "exec", version: 1)]
        #expect(partialHandshake.runtimeEvidence.last?.label == "Tools partially ready")
        #expect(partialHandshake.runtimeEvidence.last?.detail.contains("clock-sync") == true)

        var oldQuiesceHandshake = machine
        oldQuiesceHandshake.agentCapabilities = machine.agentCapabilities.map {
            $0.id == "snapshot-quiesce"
                ? DorydAgentCapability(id: $0.id, version: 1) : $0
        }
        #expect(oldQuiesceHandshake.runtimeEvidence.last?.label == "Tools partially ready")
        #expect(oldQuiesceHandshake.integrationHealthProjection.features.first {
            $0.id == .snapshotQuiesce
        }?.state == .updateRequired)

        var oldSyncHandshake = machine
        oldSyncHandshake.agentCapabilities = machine.agentCapabilities.map {
            $0.id == "sync-push"
                ? DorydAgentCapability(id: $0.id, version: 1) : $0
        }
        #expect(oldSyncHandshake.runtimeEvidence.last?.label == "Tools partially ready")
        #expect(oldSyncHandshake.integrationHealthProjection.features.first {
            $0.id == .fileTransferPush
        }?.state == .updateRequired)

        var incompatibleHandshake = machine
        incompatibleHandshake.agentProtocolVersion = 2
        #expect(incompatibleHandshake.runtimeEvidence.last?.label == "Tools incompatible")
    }

    @MainActor
    @Test func qualificationBootstrapGraphicsReceiptDoesNotInvalidateLegacyMachineList() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let selection: NSDictionary = [
            "schemaVersion": UInt16(1),
            "operationID": "01234567-89ab-4cde-8f01-23456789abcd",
            "resolvedPlanSHA256": String(repeating: "a", count: 64),
            "planRevision": UInt64(1),
            "accelerationLevel": "hardware-accelerated-3d",
            "backend": "virgl-venus",
            "rendererGeneration": UInt64(1),
            "rendererWorkerReceiptSHA256": String(repeating: "7", count: 64),
            "guestProducerFenceProofSHA256": String(repeating: "8", count: 64),
        ]
        service.setMachineRuntimeGraphicsSelection("dev", selection)

        let status = try #require(
            (try await DorydClient(endpoint: listener.endpoint).machineList()).first
        )
        #expect(status.runtimeIdentity.mode == "legacy-compatibility")
        #expect(status.runtimeGraphicsSelection?.backend == "virgl-venus")

        let machine = AppStore.machine(fromDoryd: status)
        #expect(machine.runtimeEvidence.first { $0.id == "authority" }?.label
            == "Compatibility")
        #expect(machine.runtimeEvidence.contains { $0.id == "graphics" } == false)

        let malformed = NSMutableDictionary(dictionary: selection)
        malformed.removeObject(forKey: "guestProducerFenceProofSHA256")
        service.setMachineRuntimeGraphicsSelection("dev", malformed)
        await #expect(throws: DorydClientError.self) {
            _ = try await DorydClient(endpoint: listener.endpoint).machineList()
        }
    }

    @Test func portableVZSoftwarePlanIsAcceptedWithoutAccelerationQualification() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(
            runtimeIdentityOverride: validPortableVZRuntimeIdentity()
        )
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let status = try #require(
            (try await DorydClient(endpoint: listener.endpoint).machineList()).first
        )
        #expect(status.runtimeIdentity.backend == "apple-virtualization-framework")
        #expect(status.runtimeIdentity.graphics == "software")
        #expect(status.runtimeIdentity.runtimeQualification == nil)
        #expect(status.runtimeIdentity.hostQualification == nil)
        #expect(status.runtimeGraphicsSelection == nil)

        let machine = AppStore.machine(fromDoryd: status)
        let graphics = try #require(machine.runtimeEvidence.first { $0.id == "graphics" })
        #expect(graphics.label == "Software graphics")
        #expect(graphics.detail == "Plan-bound Virtualization.framework display")
        #expect(graphics.tone == .standard)
    }

    @Test func machineIntegrationHealthUsesExactPresentShapeAndRejectsContradictions() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(runtimeIdentityOverride: validResolvedRuntimeIdentity())
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        let health = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: true,
            clipboardTextExpected: true,
            clipboardImageExpected: true,
            sharedFoldersExpected: true,
            qualifiedRuntimeFeatures: [
                .clipboardImage, .clipboardText, .displayResize, .gracefulShutdown,
                .sharedFolderDiscovery, .sharedFolderMountStatus,
            ],
            agentBuild: "agent-test",
            agentProtocolVersion: 1,
            agentCapabilities: [
                .init(id: "clock-sync", version: 1),
                .init(id: "exec", version: 1),
                .init(id: "exec-stdin", version: 1),
                .init(id: "lifecycle-receipt", version: 1),
                .init(id: "ports-watch", version: 1),
                .init(id: "snapshot-quiesce", version: 2),
                .init(id: "sync-push", version: 2),
                .init(id: "telemetry", version: 1),
            ]
        )
        let validDictionary = try integrationHealthDictionary(health)
        service.setMachineIntegrationHealth("dev", validDictionary)

        let status = try #require((try await client.machineList()).first)
        #expect(status.integrationHealth == health)
        let machine = AppStore.machine(fromDoryd: status)
        #expect(machine.integrationHealthProjection == health)
        #expect(machine.runtimeEvidence.last?.label == "Tools ready")

        let inactive = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: false,
            runtimeAuthority: .resolvedPlan,
            desktopIntegrationsExpected: true,
            clipboardTextExpected: true,
            clipboardImageExpected: true,
            sharedFoldersExpected: true,
            qualifiedRuntimeFeatures: [],
            agentBuild: "stale-agent-build",
            agentProtocolVersion: 1,
            agentCapabilities: []
        )
        service.setMachineState("dev", "paused")
        service.setMachineIntegrationHealth(
            "dev",
            try integrationHealthDictionary(inactive)
        )
        let paused = try #require((try await client.machineList()).first)
        #expect(paused.integrationHealth?.state == .inactive)

        service.setMachineState("dev", "running")

        let malformed = NSMutableDictionary(dictionary: validDictionary)
        malformed["unexpected"] = true
        service.setMachineIntegrationHealth("dev", malformed)
        do {
            _ = try await client.machineList()
            Issue.record("present integration health with unknown fields must fail closed")
        } catch let error as DorydClientError {
            #expect(error.description.contains("invalid machine list"))
        }

        let truncated = NSMutableDictionary(dictionary: validDictionary)
        let features = try #require(validDictionary["features"] as? [NSDictionary])
        truncated["features"] = Array(features.dropLast())
        service.setMachineIntegrationHealth("dev", truncated)
        do {
            _ = try await client.machineList()
            Issue.record("truncated integration health must fail closed")
        } catch let error as DorydClientError {
            #expect(error.description.contains("invalid machine list"))
        }

        let contradictory = NSMutableDictionary(dictionary: validDictionary)
        contradictory["runtimeAuthority"] = "legacy-compatibility"
        service.setMachineIntegrationHealth("dev", contradictory)
        do {
            _ = try await client.machineList()
            Issue.record("integration health contradicting runtime authority must fail closed")
        } catch let error as DorydClientError {
            #expect(error.description.contains("invalid machine list"))
        }
    }

    @MainActor
    @Test func machineListAcceptsRunningEFIInstallerWithoutGuestTools() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let health = DoryGuestIntegrationHealth.evaluate(
            machineIsRunning: true,
            runtimeAuthority: .legacyCompatibility,
            desktopIntegrationsExpected: true,
            clipboardTextExpected: true,
            clipboardImageExpected: true,
            sharedFoldersExpected: false,
            qualifiedRuntimeFeatures: [],
            agentBuild: "dory-vmm/efi",
            agentProtocolVersion: nil,
            agentCapabilities: []
        )
        #expect(health.state == .missingTools)
        #expect(health.isValid)
        service.setMachineEFIRuntime(
            "dev",
            integrationHealth: try integrationHealthDictionary(health)
        )

        let status = try #require(
            (try await DorydClient(endpoint: listener.endpoint).machineList()).first
        )
        #expect(status.bootMode == .efi)
        #expect(status.installerMediaAttached)
        #expect(status.agentBuild == "dory-vmm/efi")
        #expect(status.agentProtocolVersion == nil)
        #expect(status.integrationHealth?.state == .missingTools)

        let machine = AppStore.machine(fromDoryd: status)
        #expect(machine.distro == "Custom Linux")
        #expect(machine.displayMode == .desktop)
    }

    @Test func machineCapabilityHandshakeRejectsMalformedPresentClaims() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        let valid = try #require((try await client.machineList()).first)
        #expect(valid.agentProtocolVersion == 1)
        #expect(valid.agentCapabilities.count == 7)

        let malformed: [(Any?, Any?)] = [
            (nil, [["id": "exec", "version": 1] as NSDictionary]),
            (true, nil),
            (1, [["id": "exec", "version": 1, "unknown": "claim"] as NSDictionary]),
            (1, [
                ["id": "exec", "version": 1] as NSDictionary,
                ["id": "exec", "version": 1] as NSDictionary,
            ]),
        ]
        for (protocolVersion, capabilities) in malformed {
            service.setMachineAgentHandshake(
                "dev",
                protocolVersion: protocolVersion,
                capabilities: capabilities
            )
            do {
                _ = try await client.machineList()
                Issue.record("present malformed capability handshake must fail closed")
            } catch let error as DorydClientError {
                #expect(error.description.contains("invalid machine list"))
            }
        }
    }

    @Test func machineSharesUseAbsentOnlyCompatibilityAndRejectMalformedClaims() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)

        let valid = try #require((try await client.machineList()).first)
        #expect(valid.shares.map(\.tag) == ["src"])

        service.setMachineShares("dev", nil)
        #expect(try await client.machineList().first?.shares == [])

        let base: [String: Any] = [
            "tag": "src",
            "hostPath": "/Users/me/src",
            "guestPath": "/workspace/src",
            "readOnly": true,
        ]
        let malformed: [Any] = [
            true,
            [["tag": "src", "guestPath": "/workspace/src", "readOnly": true]],
            [base.merging(["unexpected": true]) { _, new in new }],
            [base.merging(["readOnly": "true"]) { _, new in new }],
            [base.merging(["mode": "rw"]) { _, new in new }],
            [base, base],
        ]
        for claim in malformed {
            service.setMachineShares("dev", claim)
            await #expect(throws: DorydClientError.self) {
                _ = try await client.machineList()
            }
        }
    }

    @Test func snapshotArtifactEvidenceIsAbsentOnlyForLegacyAndOtherwiseExact() async throws {
        let malformedEvidence = [
            "schemaVersion": 1,
            "rootfs": [
                "byteCount": 0,
                "sha256": String(repeating: "a", count: 64),
            ],
            "kernel": [
                "byteCount": 1,
                "sha256": String(repeating: "b", count: 64),
            ],
        ] as NSDictionary
        for fixture in [
            (runtime: [
                "schemaVersion": 1,
                "mode": "legacy-compatibility",
                "virtualHardwareABIVersion": 1,
            ] as NSDictionary,
             artifacts: malformedEvidence),
            (runtime: validResolvedRuntimeIdentity(), artifacts: nil),
        ] as [(runtime: NSDictionary, artifacts: NSDictionary?)] {
            let listener = NSXPCListener.anonymous()
            let service = FakeDorydService(
                runtimeIdentityOverride: fixture.runtime,
                artifactEvidenceOverride: fixture.artifacts
            )
            let delegate = FakeDorydListenerDelegate(service: service)
            listener.delegate = delegate
            listener.resume()
            defer { listener.invalidate() }
            let client = DorydClient(endpoint: listener.endpoint)

            do {
                _ = try await client.machineSnapshot(
                    "dev",
                    note: "invalid artifacts",
                    createdISO: "2026-07-07T00:00:00Z",
                    snapshotID: "invalid-artifacts"
                )
                Issue.record("invalid or missing non-legacy artifact evidence must fail closed")
            } catch let error as DorydClientError {
                #expect(error.description.contains("invalid doryd response"))
            }
        }
    }

    @Test func snapshotConsistencyDefaultsOnlyWhenAbsentAndRejectsMalformedClaims() async throws {
        let receipt = [
            "schemaVersion": 1,
            "receiptID": String(repeating: "a", count: 32),
            "agentBuild": "dory-agent/test",
            "agentProtocolVersion": 1,
            "capabilityVersion": 2,
        ] as NSDictionary
        let validService = FakeDorydService(
            snapshotConsistencyOverride: "guest-quiesced",
            snapshotQuiesceReceiptOverride: receipt
        )
        let validListener = NSXPCListener.anonymous()
        let validDelegate = FakeDorydListenerDelegate(service: validService)
        validListener.delegate = validDelegate
        validListener.resume()
        defer { validListener.invalidate() }
        let valid = try await DorydClient(endpoint: validListener.endpoint).machineSnapshot(
            "dev",
            note: "consistent",
            createdISO: "2026-07-07T00:00:00Z",
            snapshotID: "consistent"
        )
        #expect(valid.consistency == .guestQuiesced)
        #expect(valid.guestQuiesceReceipt?.agentBuild == "dory-agent/test")

        for fixture in [
            (consistency: 1 as Any, receipt: nil as NSDictionary?),
            (consistency: "guest-quiesced" as Any, receipt: nil as NSDictionary?),
            (consistency: "cold-stopped" as Any, receipt: receipt),
            (consistency: "guest-quiesced" as Any, receipt: [
                "schemaVersion": "1",
                "receiptID": String(repeating: "a", count: 32),
                "agentBuild": "dory-agent/test",
                "agentProtocolVersion": 1,
                "capabilityVersion": 2,
            ] as NSDictionary),
            (consistency: "guest-quiesced" as Any, receipt: [
                "schemaVersion": 1,
                "receiptID": String(repeating: "a", count: 32),
                "agentBuild": "dory-agent/test",
                "agentProtocolVersion": 1,
                "capabilityVersion": 2,
                "unknown": true,
            ] as NSDictionary),
        ] {
            let listener = NSXPCListener.anonymous()
            let service = FakeDorydService(
                snapshotConsistencyOverride: fixture.consistency,
                snapshotQuiesceReceiptOverride: fixture.receipt
            )
            let delegate = FakeDorydListenerDelegate(service: service)
            listener.delegate = delegate
            listener.resume()
            let client = DorydClient(endpoint: listener.endpoint)
            do {
                _ = try await client.machineSnapshot(
                    "dev",
                    note: "invalid consistency",
                    createdISO: "2026-07-07T00:00:00Z",
                    snapshotID: "invalid-consistency"
                )
                Issue.record("present malformed snapshot consistency must fail closed")
            } catch let error as DorydClientError {
                #expect(error.description.contains("invalid doryd response"))
            }
            listener.invalidate()
        }
    }

    @Test func installedDesktopPayloadReceiptUsesAbsentOnlyLegacyCompatibilityAndRejectsMalformedClaims() async throws {
        let digest = String(repeating: "a", count: 64)
        let valid: [String: Any] = [
            "schemaVersion": 1,
            "provenance": "verified-update-bundle",
            "distributionIdentifier": "ubuntu",
            "releaseVersion": "24.04+runtime.7",
            "inputSHA256": digest,
            "bundleSHA256": String(repeating: "b", count: 64),
            "distributionComponentIdentifier": "desktop-ubuntu",
            "distributionInstallationName": "ubuntu-installation",
            "distributionCatalogSHA256": String(repeating: "c", count: 64),
            "bundleAssetIdentifier": "dory-desktop-ubuntu-update-arm64.tar",
            "runtimeComponentIdentifier": "linux-desktop",
            "runtimeInstallationName": "runtime-installation",
            "runtimeCatalogSHA256": String(repeating: "d", count: 64),
            "kernelAssetIdentifier": "dory-desktop-kernel-arm64.lzfse",
            "kernelSHA256": String(repeating: "e", count: 64),
        ]
        do {
            let listener = NSXPCListener.anonymous()
            let service = FakeDorydService(
                installedDesktopPayloadReceiptOverride: valid as NSDictionary
            )
            let delegate = FakeDorydListenerDelegate(service: service)
            listener.delegate = delegate
            listener.resume()
            defer { listener.invalidate() }
            let client = DorydClient(endpoint: listener.endpoint)
            let status = try #require(try await client.machineList().first)
            #expect(status.installedDesktopPayloadReceipt?.releaseVersion == "24.04+runtime.7")
            #expect(status.installedDesktopPayloadReceipt?.bundleSHA256 == String(repeating: "b", count: 64))
            let snapshot = try await client.machineSnapshot(
                "dev",
                note: "receipt",
                createdISO: "2026-07-07T00:00:00Z",
                snapshotID: "receipt"
            )
            #expect(snapshot.installedDesktopPayloadReceipt == status.installedDesktopPayloadReceipt)
        }

        do {
            let listener = NSXPCListener.anonymous()
            let service = FakeDorydService()
            service.setMachineEnvironment("dev", [
                "DORY_DESKTOP_DISTRO": "ubuntu",
                "DORY_DESKTOP_RELEASE_VERSION": "24.04+runtime.6",
                "DORY_DESKTOP_INPUT_SHA256": digest,
            ])
            let delegate = FakeDorydListenerDelegate(service: service)
            listener.delegate = delegate
            listener.resume()
            defer { listener.invalidate() }
            let status = try #require(
                try await DorydClient(endpoint: listener.endpoint).machineList().first
            )
            #expect(status.installedDesktopPayloadReceipt?.provenance == "legacy-environment")
            #expect(status.installedDesktopPayloadReceipt?.releaseVersion == "24.04+runtime.6")
            #expect(status.installedDesktopPayloadReceipt?.bundleSHA256 == nil)
        }

        for malformed in [
            [
                "schemaVersion": 2,
                "provenance": "verified-update-bundle",
                "distributionIdentifier": "ubuntu",
                "releaseVersion": "24.04+runtime.7",
                "inputSHA256": digest,
                "bundleSHA256": String(repeating: "b", count: 64),
            ],
            [
                "schemaVersion": 1,
                "provenance": "verified-update-bundle",
                "distributionIdentifier": "ubuntu",
                "releaseVersion": "24.04+runtime.7",
                "inputSHA256": digest,
            ],
            valid.merging(["unknownEvidence": "must-reject"]) { _, new in new },
            valid.merging(["schemaVersion": "1"]) { _, new in new },
            valid.merging(["bundleSHA256": NSNumber(value: 7)]) { _, new in new },
            valid.merging(["distributionInstallationName": "../../outside-store"]) { _, new in new },
        ] as [[String: Any]] {
            let listener = NSXPCListener.anonymous()
            let service = FakeDorydService(
                installedDesktopPayloadReceiptOverride: malformed as NSDictionary
            )
            let delegate = FakeDorydListenerDelegate(service: service)
            listener.delegate = delegate
            listener.resume()
            defer { listener.invalidate() }
            let client = DorydClient(endpoint: listener.endpoint)
            await #expect(throws: DorydClientError.self) {
                _ = try await client.machineList()
            }
            await #expect(throws: DorydClientError.self) {
                _ = try await client.machineSnapshot(
                    "dev",
                    note: "invalid receipt",
                    createdISO: "2026-07-07T00:00:00Z",
                    snapshotID: "invalid-receipt"
                )
            }
        }
    }

    @Test func machineCloneReceiptRequiresExactShape() async throws {
        let valid: NSDictionary = [
            "schemaVersion": UInt16(1),
            "sourceMachineID": "source",
            "sourceSnapshotID": "base",
            "sourceRootfsSHA256": String(repeating: "a", count: 64),
            "sourceRootfsByteCount": UInt64(4_096),
            "storageMode": "apfs-copy-on-write",
            "createdAtUnixMilliseconds": Int64(1_787_300_000_000),
        ]
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        service.setMachineCloneReceipt("dev", valid)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = DorydClient(endpoint: listener.endpoint)
        let status = try #require(try await client.machineList().first)
        #expect(status.cloneReceipt?.sourceMachineID == "source")
        #expect(status.cloneReceipt?.sourceSnapshotID == "base")
        #expect(status.cloneReceipt?.storageMode == "apfs-copy-on-write")

        let malformed = NSMutableDictionary(dictionary: valid)
        malformed["unknown"] = true
        service.setMachineCloneReceipt("dev", malformed)
        await #expect(throws: DorydClientError.self) {
            _ = try await client.machineList()
        }

        let wrongType = NSMutableDictionary(dictionary: valid)
        wrongType["sourceRootfsByteCount"] = true
        service.setMachineCloneReceipt("dev", wrongType)
        await #expect(throws: DorydClientError.self) {
            _ = try await client.machineList()
        }
    }

    @Test func desktopUpdateSkipRequiresExactVerifiedActiveComponentProvenance() {
        let receipt = DorydInstalledDesktopPayloadReceipt(
            schemaVersion: 1,
            provenance: "verified-update-bundle",
            distributionIdentifier: "ubuntu",
            releaseVersion: "24.04+runtime.7",
            inputSHA256: String(repeating: "a", count: 64),
            bundleSHA256: String(repeating: "b", count: 64),
            distributionComponentIdentifier: "desktop-ubuntu",
            distributionInstallationName: "ubuntu-installation",
            distributionCatalogSHA256: String(repeating: "c", count: 64),
            bundleAssetIdentifier: "dory-desktop-ubuntu-update-arm64.tar",
            runtimeComponentIdentifier: "linux-desktop",
            runtimeInstallationName: "runtime-installation",
            runtimeCatalogSHA256: String(repeating: "d", count: 64),
            kernelAssetIdentifier: "dory-desktop-kernel-arm64.lzfse",
            kernelSHA256: String(repeating: "e", count: 64)
        )
        let matches: (DorydInstalledDesktopPayloadReceipt?) -> Bool = { candidate in
            AppStore.desktopReceiptMatchesActiveComponents(
                candidate,
                distributionIdentifier: "ubuntu",
                releaseVersion: "24.04+runtime.7",
                distributionComponentIdentifier: "desktop-ubuntu",
                distributionInstallationName: "ubuntu-installation",
                distributionCatalogSHA256: String(repeating: "c", count: 64),
                bundleAssetIdentifier: "dory-desktop-ubuntu-update-arm64.tar",
                bundleSHA256: String(repeating: "b", count: 64),
                runtimeInstallationName: "runtime-installation",
                runtimeCatalogSHA256: String(repeating: "d", count: 64),
                kernelAssetIdentifier: "dory-desktop-kernel-arm64.lzfse",
                kernelSHA256: String(repeating: "e", count: 64)
            )
        }
        #expect(matches(receipt))
        var wrongDistro = receipt
        wrongDistro.distributionIdentifier = "kali"
        #expect(!matches(wrongDistro))
        var staleBundle = receipt
        staleBundle.bundleSHA256 = String(repeating: "f", count: 64)
        #expect(!matches(staleBundle))
        var legacy = receipt
        legacy.provenance = "legacy-environment"
        #expect(!matches(legacy))
        #expect(
            AppStore.managedDesktopDistributionIdentifier(
                configuredIdentifier: nil,
                receipt: receipt
            ) == "ubuntu"
        )
        #expect(
            AppStore.managedDesktopDistributionIdentifier(
                configuredIdentifier: "kali",
                receipt: receipt
            ) == "kali"
        )
    }

    private func validResolvedRuntimeIdentity() -> NSDictionary {
        [
            "schemaVersion": 1,
            "mode": "resolved-plan",
            "virtualHardwareABIVersion": 1,
            "definitionRevision": UInt64(1),
            "definitionSHA256": String(repeating: "1", count: 64),
            "planRevision": UInt64(1),
            "planSHA256": String(repeating: "2", count: 64),
            "backend": "dory-hypervisor",
            "backendImplementationIdentifier": "dev.dory.raw-hv-linux",
            "backendRuntimeBuildIdentifier": "runtime-1",
            "supportTier": "supported",
            "graphics": "hardware-accelerated-3d",
            "removableUSBHotplug": true,
            "selectionDisposition": "primary",
            "runtimeQualification": [
                "qualificationIdentity": "runtime-qualification-1",
                "qualificationReportSHA256": String(repeating: "3", count: 64),
                "signingKeyID": "dory-runtime-1",
            ],
            "hostQualification": [
                "qualificationIdentity": "host-qualification-1",
                "qualificationReportSHA256": String(repeating: "4", count: 64),
                "qualifierIdentifier": "dory-host-qualifier",
            ],
            "components": [[
                "componentIdentifier": "dory-hv",
                "buildIdentifier": "runtime-1",
                "artifactSHA256": String(repeating: "5", count: 64),
            ]],
            "bootMedia": [
                "kind": "installed-linux-boot-bundle",
                "source": "user-provided",
                "artifactSHA256": String(repeating: "6", count: 64),
            ],
        ] as NSDictionary
    }

    private func validPortableVZRuntimeIdentity() -> NSDictionary {
        [
            "schemaVersion": 1,
            "mode": "resolved-plan",
            "virtualHardwareABIVersion": 1,
            "definitionRevision": UInt64(1),
            "definitionSHA256": String(repeating: "1", count: 64),
            "planRevision": UInt64(1),
            "planSHA256": String(repeating: "2", count: 64),
            "backend": "apple-virtualization-framework",
            "backendImplementationIdentifier": "dory.vz-linux.compatibility.v1",
            "backendRuntimeBuildIdentifier": "sha256:" + String(repeating: "3", count: 64),
            "supportTier": "supported",
            "graphics": "software",
            "removableUSBHotplug": false,
            "selectionDisposition": "primary",
            "components": [[
                "componentIdentifier": "dory-vmm",
                "buildIdentifier": "sha256:" + String(repeating: "3", count: 64),
                "artifactSHA256": String(repeating: "3", count: 64),
            ]],
            "bootMedia": [
                "kind": "installer-iso",
                "source": "user-provided",
                "artifactSHA256": String(repeating: "4", count: 64),
                "resolverNamespace": "legacy-artifact",
                "resolverIdentifier": "portable-installer",
                "inspectionIdentity": "dory-iso-inspector:portable",
                "inspectionReportSHA256": String(repeating: "5", count: 64),
            ],
        ] as NSDictionary
    }

    private func integrationHealthDictionary(
        _ health: DoryGuestIntegrationHealth
    ) throws -> NSDictionary {
        let data = try JSONEncoder().encode(health)
        return try #require(
            JSONSerialization.jsonObject(with: data, options: []) as? NSDictionary
        )
    }

    @MainActor
    @Test func healthRecoveryUsesDaemonOwnedSubsystemRepair() async {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(dorydClient: DorydClient(endpoint: listener.endpoint))
        await store.runRepairTarget("dns")

        #expect(service.repairTargets == ["dns"])
        #expect(store.healthActionError == nil)
        #expect(!store.healthActionInFlight)
    }

    @MainActor
    @Test func automationDoesNotContactDefaultPreferredDorydWithoutExplicitOptIn() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(dorydClient: DorydClient(endpoint: listener.endpoint))
        await store.connectBackend()

        #expect(service.engineStartCount == 0)
        #expect(store.loadState == .engineOff)
    }

    @MainActor
    @Test func appStoreUsesDorydEngineSocketWithoutStartingLegacyShim() async throws {
        let base = "/tmp/dac-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()

        #expect(service.engineStartCount == 0)
        #expect(store.runtimeKind == .sharedVM)
        #expect(store.shimSocketPath == socketPath)
        #expect(!store.shimRunning)
        #expect(!store.localNetworkingActiveForTests)
        #expect(store.loadState == .ready)
        #expect(!store.containers.isEmpty)
        #expect(service.latestNetworkRoutes.isEmpty)
    }

    @MainActor
    @Test func appStoreKeepsDoryPreferenceOnDorydStartFailure() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        service.setEngineStatus("stopped", detail: "stopped")
        service.setEngineStartResult(ok: false, message: "doryd test failure")
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            environment: [:]
        )
        store.routeDockerCLI = false
        store.enginePreference = .dory

        await store.connectBackend()

        #expect(service.engineStartCount == 1)
        #expect(store.loadState == .engineOff)
        #expect(store.sharedVMStatus == "doryd test failure")
        #expect(store.runtimeKind == .disconnected)
        #expect(!store.shimRunning)
    }

    @MainActor
    @Test func appStoreRecoversAnActiveDaemonFileTransferAfterReconnect() async throws {
        let base = "/tmp/dory-transfer-recovery-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let operationID = String(repeating: "e", count: 32)
        let active = service.machineTransferOperationResponse(
            operationID: operationID,
            phase: "transferring"
        )
        service.setMachineTransferCurrentResponse([
            "schema": UInt16(1),
            "active": true,
            "operation": active,
        ])
        service.setMachineTransferOperationResponse(active)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        store.loadMachines()

        try await waitUntil {
            store.machineFileTransfer(for: "dev")?.operationID == operationID
                && store.isMachineBusy("dev")
        }
        #expect(store.machineFileTransfer(for: "dev")?.phase == .transferring)

        service.setMachineTransferOperationResponse(
            service.machineTransferOperationResponse(
                operationID: operationID,
                phase: "completed"
            )
        )
        try await waitUntil {
            store.machineFileTransfer(for: "dev") == nil
                && !store.isMachineBusy("dev")
        }
        #expect(store.settingsNotice?.message.contains("Sent 1 file") == true)
    }

    @MainActor
    @Test func appStoreRecoversCompletedGuestExportForExplicitSaveOrDiscard() async throws {
        let base = "/tmp/dory-export-recovery-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let operationID = String(repeating: "f", count: 32)
        service.setMachineGuestExportCurrentResponse([
            "schema": UInt16(1),
            "active": true,
            "operation": service.machineGuestExportOperationResponse(
                operationID: operationID,
                phase: "completed"
            ),
        ])
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        store.loadMachines()

        try await waitUntil {
            store.machineGuestFileExport(for: "dev")?.phase == .completed
        }
        #expect(!store.isMachineBusy("dev"))
        #expect(store.settingsNotice?.message.contains("ready to save") == true)

        let machine = try #require(store.machines.first { $0.name == "dev" })
        await store.discardGuestFileExport(from: machine)
        #expect(store.machineGuestFileExport(for: "dev") == nil)
        #expect(service.machineGuestExportDiscardCount == 1)
    }

    @MainActor
    @Test func appStoreRoutesMachineLifecycleToDorydVMs() async throws {
        let base = "/tmp/dam-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        service.setMachineAgentHandshake(
            "dev",
            protocolVersion: UInt32(1),
            capabilities: [
                ["id": "clock-sync", "version": 1] as NSDictionary,
                ["id": "exec", "version": 1] as NSDictionary,
                ["id": "exec-stdin", "version": 1] as NSDictionary,
                ["id": "ports-watch", "version": 1] as NSDictionary,
                ["id": "snapshot-quiesce", "version": 2] as NSDictionary,
                ["id": "sync-pull", "version": 1] as NSDictionary,
                ["id": "sync-push", "version": 2] as NSDictionary,
                ["id": "telemetry", "version": 1] as NSDictionary,
            ]
        )
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        store.loadMachines()
        try await waitUntil {
            store.machines.contains {
                $0.name == "dev" && $0.cpuPercent == 12.5 && $0.memoryDisplay == "1 GB / 2 GB"
            }
        }

        var machine = try #require(store.machines.first { $0.name == "dev" })
        #expect(machine.distro == "Debian")
        #expect(machine.version == "13 · Xfce")
        #expect(machine.username == "dory")
        #expect(machine.loginShell == "/bin/bash")
        #expect(machine.status == .running)
        #expect(machine.cpuPercent == 12.5)
        #expect(machine.memoryDisplay == "1 GB / 2 GB")
        #expect(machine.ip == "192.168.215.40")
        #expect(machine.displayMode == .desktop)
        #expect(machine.mounts == [MountPair(
            host: "/Users/me/src",
            guest: "/workspace/src",
            readOnly: true,
            shareTag: "src"
        )])
        #expect(machine.containerID.isEmpty)
        #expect(store.machineTerminalCommand(machine) == "dory machine shell dev")
        #expect(store.canUseMachineArtifacts(machine))
        #expect(store.canTransferFiles(to: machine))
        #expect(store.canTransferFolders(to: machine))
        #expect(store.canExportGuestFiles(from: machine))
        #expect(store.canRepairMachineTools(machine))

        var customInstaller = machine
        customInstaller.bootMode = .efi
        customInstaller.shellSocketPath = ""
        #expect(store.machineTerminalCommand(customInstaller) == nil)
        #expect(!store.canOpenMachineTerminal(customInstaller))
        #expect(!store.canRepairMachineTools(customInstaller))

        var headlessMachine = machine
        headlessMachine.displayMode = .headless
        #expect(!store.canRepairMachineTools(headlessMachine))

        let transferRoot = URL(
            fileURLWithPath: "/tmp/dory-store-transfer-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: transferRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transferRoot) }
        let transferFile = transferRoot.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: transferFile)
        let transferred = try #require(await store.transferFiles([transferFile], to: machine))
        #expect(transferred.filesSent == 1)
        #expect(transferred.bytesSent == 5)
        #expect(store.settingsNotice?.message.contains(transferred.guestDestination) == true)
        let stagedRoot = try #require(
            service.latestMachineTransferStartRequest?["privateStagingRoot"] as? String
        )
        #expect(!FileManager.default.fileExists(atPath: stagedRoot))
        #expect(store.machineFileTransfer(for: machine.name) == nil)

        let transferFolder = transferRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: transferFolder.appendingPathComponent("empty/deep", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(
            to: transferFolder.appendingPathComponent("hello.txt")
        )
        let transferredFolder = try #require(
            await store.transferFiles([transferFolder], to: machine)
        )
        #expect(transferredFolder.filesSent == 1)
        #expect(transferredFolder.bytesSent == 5)
        #expect(store.settingsNotice?.message.contains("1 file and 3 folders") == true)
        let stagedFolderRoot = try #require(
            service.latestMachineTransferStartRequest?["privateStagingRoot"] as? String
        )
        #expect(!FileManager.default.fileExists(atPath: stagedFolderRoot))

        var fileOnlyTransfer = machine
        fileOnlyTransfer.agentCapabilities = fileOnlyTransfer.agentCapabilities.map {
            $0.id == "sync-push" ? DorydAgentCapability(id: $0.id, version: 1) : $0
        }
        #expect(store.canTransferFiles(to: fileOnlyTransfer))
        #expect(!store.canTransferFolders(to: fileOnlyTransfer))
        #expect(await store.transferFiles([transferFolder], to: fileOnlyTransfer) == nil)
        #expect(store.actionError?.contains("Update Dory Tools") == true)
        #expect(
            service.latestMachineTransferStartRequest?["privateStagingRoot"] as? String
                == stagedFolderRoot
        )

        let cancellingID = String(repeating: "c", count: 32)
        service.setMachineTransferOperationResponse(
            service.machineTransferOperationResponse(
                operationID: cancellingID,
                phase: "transferring"
            )
        )
        let cancellingTransfer = Task {
            await store.transferFiles([transferFile], to: machine)
        }
        try await waitUntil {
            store.machineFileTransfer(for: machine.name)?.phase == .transferring
        }
        await store.cancelFileTransfer(to: machine)
        #expect(await cancellingTransfer.value == nil)
        #expect(service.machineTransferCancelCount == 1)
        #expect(store.machineFileTransfer(for: machine.name) == nil)
        #expect(store.settingsNotice?.message.contains("Cancelled") == true)
        service.setMachineTransferOperationResponse(nil)

        let exportID = String(repeating: "d", count: 32)
        let privateExportRoot = DoryMachineFileTransferStager.defaultStagingDirectory
            .appendingPathComponent(
                "export-\(getpid())-\(exportID)",
                isDirectory: true
            ).path
        try? FileManager.default.removeItem(atPath: privateExportRoot)
        try FileManager.default.createDirectory(
            atPath: privateExportRoot + "/nested",
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("guest-export".utf8).write(
            to: URL(fileURLWithPath: privateExportRoot + "/nested/file.txt")
        )
        defer {
            try? FileManager.default.removeItem(atPath: privateExportRoot)
        }
        let receivedURL = transferRoot.appendingPathComponent(
            "received-project",
            isDirectory: true
        )
        let received = try #require(await store.exportGuestFiles(
            "/home/dory/Documents/project",
            from: machine,
            to: receivedURL
        ))
        #expect(received == receivedURL)
        #expect(
            try Data(contentsOf: received.appendingPathComponent("nested/file.txt"))
                == Data("guest-export".utf8)
        )
        #expect(store.machineGuestFileExport(for: machine.name) == nil)
        #expect(service.machineGuestExportDiscardCount == 1)
        #expect(store.settingsNotice?.message.contains("Saved 1 file and 1 folder") == true)

        let cancellingExportID = String(repeating: "e", count: 32)
        let transferringExport = service.machineGuestExportOperationResponse(
            operationID: cancellingExportID,
            phase: "transferring"
        )
        service.setMachineGuestExportStartResponse(transferringExport)
        service.setMachineGuestExportOperationResponse(transferringExport)
        let cancellingExport = Task {
            await store.exportGuestFiles(
                "/home/dory/Documents/project",
                from: machine,
                to: transferRoot.appendingPathComponent("cancelled-export")
            )
        }
        try await waitUntil {
            store.machineGuestFileExport(for: machine.name)?.phase == .transferring
        }
        await store.cancelGuestFileExport(from: machine)
        #expect(await cancellingExport.value == nil)
        #expect(service.machineGuestExportCancelCount == 1)
        #expect(store.machineGuestFileExport(for: machine.name) == nil)
        service.setMachineGuestExportStartResponse(nil)
        service.setMachineGuestExportOperationResponse(nil)

        var transferUnavailable = machine
        transferUnavailable.agentCapabilities = transferUnavailable.agentCapabilities.filter {
            $0.id != "sync-push"
        }
        #expect(!store.canTransferFiles(to: transferUnavailable))

        var receiveOnly = machine
        receiveOnly.fileTransferPolicy = .guestToHost
        #expect(!store.canTransferFiles(to: receiveOnly))
        #expect(store.canExportGuestFiles(from: receiveOnly))

        var exportUnavailable = machine
        exportUnavailable.agentCapabilities = exportUnavailable.agentCapabilities.filter {
            $0.id != "sync-pull"
        }
        #expect(!store.canExportGuestFiles(from: exportUnavailable))

        var sendOnly = machine
        sendOnly.fileTransferPolicy = .hostToGuest
        #expect(store.canTransferFiles(to: sendOnly))
        #expect(!store.canExportGuestFiles(from: sendOnly))

        let currentSettings = await store.machineSettings(machine.name)
        #expect(currentSettings.cpus == 2)
        #expect(currentSettings.memoryMB == 2048)
        #expect(currentSettings.address == "192.168.215.40")
        #expect(currentSettings.displayMode == .desktop)
        #expect(currentSettings.mounts == [MountPair(
            host: "/Users/me/src",
            guest: "/workspace/src",
            readOnly: true,
            shareTag: "src"
        )])
        #expect(currentSettings.env.isEmpty)

        store.toggleMachine(machine)
        try await waitUntil {
            store.machines.first { $0.name == "dev" }?.status == .stopped
        }
        #expect(service.machineStopCount == 1)

        machine = try #require(store.machines.first { $0.name == "dev" })
        store.toggleMachine(machine)
        try await waitUntil {
            store.machines.first { $0.name == "dev" }?.status == .running
        }
        #expect(service.machineStartCount == 1)

        machine = try #require(store.machines.first { $0.name == "dev" })
        store.pauseMachine(machine)
        try await waitUntil {
            store.machines.first { $0.name == "dev" }?.status == .paused
        }
        #expect(service.machinePauseCount == 1)

        machine = try #require(store.machines.first { $0.name == "dev" })
        store.toggleMachine(machine)
        try await waitUntil {
            store.machines.first { $0.name == "dev" }?.status == .running
        }
        #expect(service.machineResumeCount == 1)

        machine = try #require(store.machines.first { $0.name == "dev" })
        store.suspendMachine(machine)
        try await waitUntil {
            store.machines.first { $0.name == "dev" }?.status == .suspended
        }
        #expect(service.machineSuspendCount == 1)

        machine = try #require(store.machines.first { $0.name == "dev" })
        store.toggleMachine(machine)
        try await waitUntil {
            store.machines.first { $0.name == "dev" }?.status == .running
        }
        #expect(service.machineResumeCount == 2)

        machine = try #require(store.machines.first { $0.name == "dev" })
        store.restartMachine(machine)
        try await waitUntil { service.machineRestartCount == 1 }
        #expect(store.machines.first { $0.name == "dev" }?.status == .running)

        machine = try #require(store.machines.first { $0.name == "dev" })
        let editResult = await store.editMachine(
            machine,
            settings: MachineSettings(
                cpus: 4,
                memoryMB: 4096,
                mounts: [MountPair(
                    host: "/Users/me/app",
                    guest: "/workspace/app",
                    shareTag: "src"
                )],
                displayPresentation: DoryMachineDisplayPresentation(assignments: [
                    DoryGuestDisplayPresentationAssignment(
                        guestDisplayID: "primary",
                        mode: .dedicatedFullscreen,
                        hostDisplayUUID: "4e9b6f86-2b92-4fea-8d35-dcb3ed7c19c9"
                    ),
                ]),
                address: "192.168.215.41"
            )
        )
        #expect(editResult == nil)
        try await waitUntil {
            service.machineUpdateCount == 1
                && store.machines.first { $0.name == "dev" }?.memoryDisplay == "2 GB / 4 GB"
        }
        #expect((service.latestMachineUpdateConfig?["memoryMB"] as? NSNumber)?.uint64Value == 4096)
        #expect((service.latestMachineUpdateConfig?["cpuCount"] as? NSNumber)?.intValue == 4)
        #expect(service.latestMachineUpdateConfig?["address"] as? String == "192.168.215.41")
        let updateShares = try #require(service.latestMachineUpdateConfig?["shares"] as? [NSDictionary])
        #expect(updateShares.first?["hostPath"] as? String == "/Users/me/app")
        #expect(updateShares.first?["guestPath"] as? String == "/workspace/app")
        #expect(updateShares.first?["readOnly"] as? Bool == false)
        #expect(updateShares.first?["tag"] as? String == "src")
        #expect(service.latestMachineUpdateConfig?["env"] == nil)
        #expect(await store.machineSettings("dev").displayPresentation?.assignments.first?.hostDisplayUUID
            == "4e9b6f86-2b92-4fea-8d35-dcb3ed7c19c9")

        machine = try #require(store.machines.first { $0.name == "dev" })
        let clearAddressResult = await store.editMachine(
            machine,
            settings: MachineSettings(
                cpus: 4,
                memoryMB: 4096,
                mounts: [MountPair(
                    host: "/Users/me/app",
                    guest: "/workspace/app",
                    shareTag: "src"
                )],
                address: ""
            )
        )
        #expect(clearAddressResult == nil)
        #expect(service.machineUpdateCount == 2)
        #expect(service.latestMachineUpdateConfig?["address"] as? String == "")
        let clearedSettings = await store.machineSettings("dev")
        #expect(clearedSettings.address == nil)

        machine = try #require(store.machines.first { $0.name == "dev" })
        service.setMachineDeleteResult(ok: false, message: "fixture disk is busy")
        store.deleteMachine(machine)
        try await waitUntil {
            service.machineDeleteCount == 1 && !store.isMachineBusy("dev")
        }
        #expect(store.machines.contains { $0.name == "dev" })
        #expect(store.actionError?.contains("fixture disk is busy") == true)

        service.setMachineDeleteResult(ok: true)
        store.deleteMachine(machine)
        try await waitUntil {
            service.machineDeleteCount == 2 && !store.machines.contains { $0.name == "dev" }
        }
        #expect(service.machineDeleteCount == 2)
    }

    @MainActor
    @Test func appStoreRoutesMachineSnapshotsToDorydVMs() async throws {
        let base = "/tmp/das-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        store.loadMachines()
        try await waitUntil {
            store.machines.contains { $0.name == "dev" }
        }
        let machine = try #require(store.machines.first { $0.name == "dev" })

        store.openSnapshots(machine)
        store.takeSnapshot(machine, note: "before upgrade")
        try await waitUntil {
            service.machineSnapshotCount == 1 && store.machineSnapshots.contains { $0.machineName == "dev" }
        }
        let snapshot = try #require(store.machineSnapshots.first)
        #expect(snapshot.note == "before upgrade")
        #expect(snapshot.imageRef.hasPrefix("doryd://dev/"))
        #expect(snapshot.consistency == .coldStopped)
        #expect(snapshot.guestQuiesceReceipt == nil)

        service.setMachineCloneSnapshotDuplicateFailures(1)
        store.cloneSnapshot(snapshot)
        try await waitUntil {
            service.machineCloneSnapshotCount == 2 && store.machines.contains { $0.name.hasPrefix("dev-copy-") }
        }
        let clonedName = try #require(store.machines.first { $0.name.hasPrefix("dev-copy-") }?.name)
        let generatedToken = try #require(clonedName.split(separator: "-").last)
        #expect(generatedToken.count == 12)
        #expect(generatedToken.allSatisfy { $0.isHexDigit })
        #expect(store.machineCreationLog.contains("already exists. Choosing another name"))

        store.restoreSnapshot(snapshot)
        try await waitUntil {
            service.machineRestoreSnapshotCount == 1
        }

        store.deleteSnapshot(snapshot)
        try await waitUntil {
            service.machineDeleteSnapshotCount == 1 && !store.machineSnapshots.contains { $0.id == snapshot.id }
        }

        store.cloneMachine(machine)
        try await waitUntil {
            service.machineCloneSnapshotCount == 3
                && service.machineSnapshotCount == 3
                && service.machineDeleteSnapshotCount == 2
                && !store.isMachineBusy("dev")
        }
        #expect(store.machineCreationLog.contains("Clone dev-copy-"))
    }

    @MainActor
    @Test func appStoreImportsPortableMachineAsVisibleRunningCloneAndCleansSnapshot() async throws {
        let bounded = AppStore.derivedMachineID(
            base: String(repeating: "a", count: 63),
            operation: "import",
            token: "ABCDEF123456"
        )
        #expect(bounded.count == 63)
        #expect(bounded.hasSuffix("-import-abcdef123456"))

        let base = "/tmp/dami-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false
        await store.connectBackend()

        store.importMachine(from: URL(fileURLWithPath: "/tmp/dev.dorymachine"))
        try await waitUntil {
            service.machineCloneSnapshotCount == 1
                && service.machineDeleteSnapshotCount == 1
                && store.machines.contains { $0.name.hasPrefix("dev-import-") }
                && !store.isMachineBusy(AppStore.importBusyKey)
        }
        #expect(store.machineCreationLog.contains("Imported machine dev-import-"))
        #expect(!store.machineCreationLog.contains("Use Clone or Restore"))

        service.setMachineCloneSnapshotResult(ok: false, message: "fixture clone failed")
        store.importMachine(from: URL(fileURLWithPath: "/tmp/broken.dorymachine"))
        try await waitUntil {
            service.machineCloneSnapshotCount == 2
                && service.machineDeleteSnapshotCount == 2
                && !store.isMachineBusy(AppStore.importBusyKey)
        }
        #expect(store.machineCreationError?.contains("fixture clone failed") == true)
        #expect(store.machineCreationLog.contains("Error:"))
    }

    @MainActor
    @Test func appStoreCreatesDorydMachineFromKernelRootfsEnvironment() async throws {
        let base = "/tmp/damc-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            environment: [
                "DORYD_MACHINE_KERNEL": "/vm/Image",
                "DORYD_MACHINE_ROOTFS": "/vm/rootfs.raw",
            ],
            desktopMachineAssetPreparer: { _, environment, _ in
                guard environment["DORY_DESKTOP_DISTRO"] == "ubuntu" else {
                    throw DesktopMachineAssetError.missingAsset("root filesystem")
                }
                return DesktopMachineAssets(kernelPath: "/vm/Image", rootfsPath: "/vm/rootfs.raw")
            }
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        let result = await store.createMachine(
            name: "vmdev",
            recipe: DevRecipe.forID("rust"),
            settings: MachineSettings(
                cpus: 3,
                memoryMB: 3072,
                mounts: [MountPair(host: "/Users/me/project", guest: "/workspace/project")],
                env: [
                    "APP_ENV": "dev",
                    "DORY_DESKTOP_DISTRO": "ubuntu",
                ],
                displayMode: .desktop
            )
        )

        #expect(result == nil)
        #expect(service.machineCreateCount == 1)
        #expect(service.machineStartCount == 1)
        #expect(service.machineProvisionCount == 1)
        #expect(service.latestMachineProvisionRecipe == "rust")
        let config = try #require(service.latestMachineCreateConfig)
        #expect(config["id"] as? String == "vmdev")
        #expect(config["kernelPath"] as? String == "/vm/Image")
        #expect(config["rootfsPath"] as? String == "/vm/rootfs.raw")
        #expect((config["memoryMB"] as? NSNumber)?.uint64Value == 3072)
        #expect((config["cpuCount"] as? NSNumber)?.intValue == 3)
        #expect(config["displayMode"] as? String == "desktop")
        #expect(config["address"] == nil)
        let createShares = try #require(config["shares"] as? [NSDictionary])
        #expect(createShares.first?["hostPath"] as? String == "/Users/me/project")
        #expect(createShares.first?["guestPath"] as? String == "/workspace/project")
        #expect(config["env"] == nil)
        let identity = try #require(config["guestIdentityIntent"] as? NSDictionary)
        let desktop = try #require(identity["desktop"] as? NSDictionary)
        #expect(desktop["distributionIdentifier"] as? String == "ubuntu")

        try await waitUntil {
            store.machines.first { $0.name == "vmdev" }?.status == .running
        }
        #expect(store.machineCreated?.name == "vmdev")
        #expect(store.machineCreationLog.contains("Provisioning Rust"))
        #expect(store.machineCreationLog.contains("cargo 1.0"))
    }

    @MainActor
    @Test func appStoreEditsTypedLeavesWithoutRewritingLegacyEnvironment() async throws {
        let base = "/tmp/dory-typed-edit-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        service.setMachineEnvironment("dev", [
            "DORY_GUEST_USER": "dory",
            "DORY_GUEST_UID": "not-a-uid",
            "DORY_DESKTOP_DISTRO": "ubuntu",
            "DORY_DESKTOP_NAME": "Ubuntu",
            "DORY_DESKTOP_VERSION": "24.04 LTS",
            "DORY_DESKTOP_ENVIRONMENT": "GNOME",
            "DORY_CLIPBOARD_POLICY": "invalid-clipboard",
            "DORY_DESKTOP_VMM": "invalid-runtime",
            "DORY_DESKTOP_GRAPHICS": "invalid-graphics",
            "OPAQUE_LEGACY": "preserve-exactly",
        ])
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        store.loadMachines()
        try await waitUntil {
            store.machines.contains { $0.name == "dev" }
        }
        let machine = try #require(store.machines.first { $0.name == "dev" })
        let baseline = await store.machineSettings("dev")
        let desktop = try #require(
            baseline.virtualMachineSettings?.guestIdentityIntent.desktop
        )
        var desired = try #require(baseline.virtualMachineSettings)
        desired.guestIdentityIntent = DoryVMGuestIdentityIntent(
            account: DoryVMGuestAccountIntent(username: "builder"),
            desktop: desktop
        )

        let result = await store.editMachine(
            machine,
            settings: MachineSettings(
                cpus: baseline.cpus,
                memoryMB: baseline.memoryMB,
                mounts: baseline.mounts,
                env: [:],
                virtualMachineSettings: desired,
                address: baseline.address,
                displayMode: .desktop
            )
        )

        #expect(result == nil)
        let update = try #require(service.latestMachineUpdateConfig)
        #expect(update["env"] == nil)
        let identity = try #require(update["guestIdentityIntent"] as? NSDictionary)
        let account = try #require(identity["account"] as? NSDictionary)
        #expect(account["username"] as? String == "builder")
        #expect(account["numericUserID"] == nil)
        #expect(identity["desktop"] == nil)
        #expect(update["clipboardPolicy"] == nil)
        #expect(update["desktopRuntimePreference"] == nil)
        #expect(update["desktopGraphicsPreference"] == nil)

        let persisted = try #require(
            (try await DorydClient(endpoint: listener.endpoint).machineList())
                .first { $0.id == "dev" }
        )
        #expect(persisted.environment["DORY_GUEST_USER"] == "builder")
        #expect(persisted.environment["DORY_GUEST_UID"] == "not-a-uid")
        #expect(persisted.environment["DORY_DESKTOP_DISTRO"] == "ubuntu")
        #expect(persisted.environment["DORY_DESKTOP_NAME"] == "Ubuntu")
        #expect(persisted.environment["DORY_DESKTOP_VERSION"] == "24.04 LTS")
        #expect(persisted.environment["DORY_DESKTOP_ENVIRONMENT"] == "GNOME")
        #expect(persisted.environment["DORY_CLIPBOARD_POLICY"] == "invalid-clipboard")
        #expect(persisted.environment["DORY_DESKTOP_VMM"] == "invalid-runtime")
        #expect(persisted.environment["DORY_DESKTOP_GRAPHICS"] == "invalid-graphics")
        #expect(persisted.environment["OPAQUE_LEGACY"] == "preserve-exactly")

        let afterUsernameEdit = await store.machineSettings("dev")
        var explicitRuntimeEdit = try #require(
            afterUsernameEdit.virtualMachineSettings
        )
        explicitRuntimeEdit.clipboardPolicy = .legacyDesktop(.hostToGuest)
        explicitRuntimeEdit.runtimePreference = .compatible
        explicitRuntimeEdit.graphicsPreference = .software
        let secondResult = await store.editMachine(
            machine,
            settings: MachineSettings(
                cpus: afterUsernameEdit.cpus,
                memoryMB: afterUsernameEdit.memoryMB,
                mounts: afterUsernameEdit.mounts,
                env: [:],
                virtualMachineSettings: explicitRuntimeEdit,
                address: afterUsernameEdit.address,
                displayMode: .desktop
            )
        )
        #expect(secondResult == nil)
        let explicitUpdate = try #require(service.latestMachineUpdateConfig)
        #expect(explicitUpdate["desktopRuntimePreference"] as? String == "compatible")
        #expect(explicitUpdate["desktopGraphicsPreference"] as? String == "software")
        let clipboard = try #require(
            explicitUpdate["clipboardPolicy"] as? NSDictionary
        )
        #expect(clipboard["text"] as? String == "host-to-guest")
    }

    @MainActor
    @Test func failedRequiredMachineProvisioningRollsBackNewDefinition() async throws {
        let base = "/tmp/damc-provision-failure-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        service.setMachineProvisionResult(ok: false, message: "fixture install failed")
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            environment: [
                "DORYD_MACHINE_KERNEL": "/vm/Image",
                "DORYD_MACHINE_ROOTFS": "/vm/rootfs.raw",
            ]
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        let result = await store.createMachine(
            name: "vmfailed",
            recipe: DevRecipe.forID("rust")
        )

        #expect(result?.contains("fixture install failed") == true)
        #expect(service.machineCreateCount == 1)
        #expect(service.machineStartCount == 1)
        #expect(service.machineProvisionCount == 1)
        #expect(service.machineDeleteCount == 1)
        #expect(store.machineCreated == nil)
        #expect(store.machineCreationLog.contains("Setup failed. Removing the incomplete machine"))
        #expect(store.machineCreationLog.contains("Incomplete machine removed"))
        #expect(!store.machineCreationLog.contains("Machine created and started"))
        #expect(!store.machines.contains { $0.name == "vmfailed" })
    }

    @MainActor
    @Test func appStoreDoesNotCopyHostCredentialsWhenCreatingDorydMachine() async throws {
        let base = "/tmp/damc-env-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            environment: [
                "DORYD_MACHINE_KERNEL": "/vm/Image",
                "DORYD_MACHINE_ROOTFS": "/vm/rootfs.raw",
                "ANTHROPIC_API_KEY": "sk-ant-host",
                "GH_TOKEN": "gh-host",
            ]
        )
        store.routeDockerCLI = false
        store.setMachineEnvAllowList(["ANTHROPIC_API_KEY", "GH_TOKEN", "EMPTY_TOKEN"])

        await store.connectBackend()
        let result = await store.createMachine(
            name: "envdev",
            settings: MachineSettings(
                cpus: nil,
                memoryMB: nil,
                env: [
                    "GH_TOKEN": "gh-explicit",
                    "DORY_DESKTOP_DISTRO": "ubuntu",
                ]
            )
        )

        #expect(result == nil)
        let config = try #require(service.latestMachineCreateConfig)
        #expect(config["env"] == nil)
        #expect(config["guestIdentityIntent"] == nil)
    }

    @MainActor
    @Test func dorydMachineConfigurationRequiresKernelAndRootfsAndUsesSettingsDefaults() throws {
        #expect(AppStore.dorydMachineConfiguration(
            name: "vmdev",
            settings: .default,
            environment: ["DORYD_DISABLE_BUNDLED_MACHINE_ASSETS": "1"]
        ) == nil)

        let config = AppStore.dorydMachineConfiguration(
            name: "vmdev",
            settings: MachineSettings(cpus: 3, memoryMB: 3072, env: ["APP_ENV": "dev"]),
            environment: [
                "DORYD_GUEST_KERNEL": "/vm/Image",
                "DORYD_GUEST_ROOTFS": "/vm/rootfs.raw",
            ]
        )

        #expect(config == DorydMachineConfiguration(
            id: "vmdev",
            kernelPath: "/vm/Image",
            rootfsPath: "/vm/rootfs.raw",
            memoryMB: 3072,
            cpuCount: 3,
            typedSettings: DorydMachineTypedSettings(networkMode: .sharedNAT)
        ))

        let invalidResources = AppStore.dorydMachineConfiguration(
            name: "vmdev",
            settings: .default,
            environment: [
                "DORYD_GUEST_KERNEL": "/vm/Image",
                "DORYD_GUEST_ROOTFS": "/vm/rootfs.raw",
                "DORYD_MACHINE_MEMORY_MB": "0",
                "DORYD_MACHINE_CPUS": "0",
            ]
        )
        #expect(invalidResources?.memoryMB == 0)
        #expect(invalidResources?.cpuCount == 0)

        let malformedResources = AppStore.dorydMachineConfiguration(
            name: "vmdev",
            settings: .default,
            environment: [
                "DORYD_GUEST_KERNEL": "/vm/Image",
                "DORYD_GUEST_ROOTFS": "/vm/rootfs.raw",
                "DORYD_MACHINE_MEMORY_MB": "invalid",
                "DORYD_MACHINE_CPUS": "invalid",
            ]
        )
        #expect(malformedResources?.memoryMB == 0)
        #expect(malformedResources?.cpuCount == 0)

        let customEFI = AppStore.dorydMachineConfiguration(
            name: "omarchy",
            settings: MachineSettings(
                cpus: 4,
                memoryMB: 4_096,
                env: ["DORY_CUSTOM_LINUX": "1", "TOKEN": "must-not-cross"],
                displayMode: .desktop,
                bootMode: .efi,
                installerISOPath: "/staged/omarchy.iso",
                diskSizeGB: 64
            ),
            environment: [:]
        )
        let custom = try #require(customEFI)
        #expect(custom.bootMode == .efi)
        #expect(custom.installerISOPath == "/staged/omarchy.iso")
        #expect(custom.typedSettings.isEmpty)
        #expect(custom.xpcDictionary["env"] == nil)
        #expect(custom.xpcDictionary["guestIdentityIntent"] == nil)
    }

    @MainActor
    @Test func dorydRecipeMappingCoversBuiltInRecipesAndRejectsCustomRecipes() {
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("node")!) == "node")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("python")!) == "python-ml")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("go")!) == "go")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("java")!) == "java")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("ruby")!) == "ruby")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("rust")!) == "rust")
        #expect(AppStore.dorydRecipeID(for: DevRecipe.forID("devops")!) == "devops")
        #expect(AppStore.dorydRecipeID(for: DevRecipe(id: "custom-abc", display: "Custom", icon: "wrench", install: "true")) == nil)
    }

    @MainActor
    @Test func appStoreAutoRefreshDoesNotWakeDorydIdleSleep() async throws {
        let base = "/tmp/daslp-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        #expect(!store.containers.isEmpty)

        store.containers = []
        service.setEngineStatus("sleeping", detail: "idle")

        await store.refreshIfIdle()

        #expect(store.engineSleeping)
        #expect(!store.engineRunning)
        #expect(store.containers.isEmpty)
        #expect(service.engineWakeCount == 0)
    }

    @MainActor
    @Test func appStoreAutoRefreshUsesDaemonObservationInsteadOfPublicDockerActivity() async throws {
        let base = "/tmp/danwp-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        service.setDashboardSnapshot([
            "containers": Data("[{\"Id\":\"observed\",\"Image\":\"alpine:3.21\",\"Names\":[\"/observed\"],\"State\":\"exited\",\"Status\":\"Exited (0)\"}]".utf8),
            "images": Data("[]".utf8),
            "volumes": Data("{\"Volumes\":[]}".utf8),
            "networks": Data("[]".utf8),
            "version": Data("{\"Version\":\"observation-test\",\"ApiVersion\":\"1.47\"}".utf8),
        ])
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        dockerServer.stop()
        service.setEngineStatus("running", detail: "idle candidate")

        await store.refreshIfIdle()

        #expect(service.engineDashboardSnapshotCount == 1)
        #expect(store.containers.map(\.id) == ["observed"])
        #expect(store.engineVersion == "observation-test")
    }

    @MainActor
    @Test func appStoreMenuBarRefreshDoesNotWakeDorydIdleSleep() async throws {
        let base = "/tmp/dmbr-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        #expect(!store.containers.isEmpty)

        store.containers = []
        service.setEngineStatus("sleeping", detail: "idle")

        await store.refreshMenuBar()

        #expect(store.engineSleeping)
        #expect(!store.engineRunning)
        #expect(store.containers.isEmpty)
        #expect(service.engineWakeCount == 0)
    }

    @MainActor
    @Test func appStoreStartsStoppedDorydOnAttach() async throws {
        let base = "/tmp/doryd-start-stopped-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        service.setEngineStatus("stopped", detail: "stopped")
        service.setIdleMode("manual")
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()

        #expect(service.engineStartCount == 1)
        #expect(service.engineWakeCount == 0)
        #expect(store.runtimeMode == "manual")
        #expect(store.loadState == .ready)
        #expect(!store.engineSleeping)
        #expect(store.engineRunning)
    }

    @MainActor
    @Test func appStoreWaitsForDelayedDockerSocketWithoutStoppingDoryd() async throws {
        let base = "/tmp/doryd-delayed-docker-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        service.setEngineStatus("stopped", detail: "cold start")
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let delayedSocket = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(300))
            try dockerServer.start()
        }
        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        try await delayedSocket.value

        #expect(service.engineStartCount == 1)
        #expect(service.engineStopCount == 0)
        #expect(store.runtimeKind == .sharedVM)
        #expect(store.loadState == .ready)
        #expect(store.engineRunning)
        #expect(store.sharedVMStatus == "Running through doryd")
    }

    @MainActor
    @Test func appStoreStartsSleepingDorydOnAttach() async throws {
        let base = "/tmp/doryd-start-sleeping-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        service.setEngineStatus("sleeping", detail: "armed")
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()

        #expect(service.engineStartCount == 1)
        #expect(service.engineWakeCount == 0)
        #expect(store.runtimeKind == .sharedVM)
        #expect(store.loadState == .ready)
        #expect(!store.engineSleeping)
        #expect(store.engineRunning)
        #expect(!store.containers.isEmpty)
    }

    @MainActor
    @Test func daemonOwnedX86ApplicationCompatibilityRestartsAndReconnectsWithExplicitLaunchAgentChoice() async throws {
        guard MacHostPlatform.current().isAppleSilicon else { return }
        let key = SharedVMProvisioner.Config.rosettaX86Key
        let previousDefault = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousDefault { UserDefaults.standard.set(previousDefault, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)

        let base = "/tmp/doryd-setting-success-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder()
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder()

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) }
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        await store.setRosettaX86(true)

        #expect(service.engineStopCount == 1)
        #expect(service.engineStartCount == 1)
        #expect(launchAgent.configurations.last?.amd64EmulationEnabled == true)
        #expect(launchAgent.configurations.last?.gpuVenusEnabled == false)
        #expect(store.rosettaX86Enabled)
        #expect(UserDefaults.standard.bool(forKey: key))
        #expect(store.loadState == .ready)
        #expect(store.dorydRuntimeActive)
        #expect(store.settingsNotice?.kind == .success)
        #expect(store.settingsNotice?.message == "x86_64 application compatibility enabled.")
        let restarted = await workloadRecorder.startedIDs
        #expect(Set(restarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
        #expect(!restarted.contains("c5"))
    }

    @MainActor
    @Test func manualDaemonRestartRestoresOnlyPreviouslyRunningWorkloads() async throws {
        let base = "/tmp/doryd-manual-restart-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder()
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder()

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) }
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        await store.restartEngine()

        #expect(service.engineStopCount == 1)
        #expect(service.engineStartCount == 1)
        #expect(store.loadState == .ready)
        #expect(store.dorydRuntimeActive)
        #expect(store.settingsNotice?.kind == .success)
        let restarted = await workloadRecorder.startedIDs
        #expect(Set(restarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
        #expect(!restarted.contains("c5"))
    }

    @MainActor
    @Test func dataDriveMaintenanceRestoresRunningContainersAndLinuxMachines() async throws {
        let base = "/tmp/doryd-data-drive-maintenance-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder()
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder()

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            dorydLaunchAgentBootout: { true }
        )
        store.routeDockerCLI = false
        await store.connectBackend()

        let captured = try await store.quiesceDorydForDataDriveOperation()
        #expect(captured.machineIDs == ["dev"])
        #expect(Set(captured.containers.map(\.id)) == Set(MockData.containers.filter(\.isRunning).map(\.id)))

        let recovery = await store.reconnectAfterDataDriveOperation(workloads: captured)

        #expect(recovery == nil)
        #expect(service.machineStartCount == 1)
        let restarted = await workloadRecorder.startedIDs
        #expect(Set(restarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
        #expect(!restarted.contains("c5"))
    }

    @MainActor
    @Test func daemonEngineResourcesPersistRestartAndRestoreRunningWorkloads() async throws {
        let keys = [AppStore.engineCPUCountKey, AppStore.engineMemoryMBKey]
        let previousDefaults = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, UserDefaults.standard.object(forKey: $0))
        })
        defer {
            for key in keys {
                if let value = previousDefaults[key] as? Int {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        let base = "/tmp/doryd-resource-setting-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder()
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder()

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            environment: ["XCTestConfigurationFilePath": "DoryTests.xctest"]
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        let limits = AppStore.engineResourceLimits()
        guard limits.maximumCPUCount > 1 else { return }
        let targetCPU = store.engineCPUCount == 1 ? 2 : 1
        let targetMemoryMB = store.engineMemoryMB

        await store.setEngineResources(cpuCount: targetCPU, memoryMB: targetMemoryMB)

        #expect(service.engineStopCount == 1)
        #expect(service.engineStartCount == 1)
        #expect(launchAgent.configurations.last?.cpuCount == UInt16(targetCPU))
        #expect(launchAgent.configurations.last?.memoryMB == UInt32(targetMemoryMB))
        #expect(store.engineCPUCount == targetCPU)
        #expect(store.engineMemoryMB == targetMemoryMB)
        #expect(UserDefaults.standard.integer(forKey: AppStore.engineCPUCountKey) == targetCPU)
        #expect(UserDefaults.standard.integer(forKey: AppStore.engineMemoryMBKey) == targetMemoryMB)
        #expect(store.settingsNotice?.kind == .success)
        #expect(store.settingsNotice?.message == "Engine resources set to \(targetCPU) cores and \(targetMemoryMB / 1024) GB.")
        let restarted = await workloadRecorder.startedIDs
        #expect(Set(restarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
        #expect(!restarted.contains("c5"))
    }

    @MainActor
    @Test func dockerBridgeSubnetPersistsRestartsAndRestoresRunningWorkloads() async throws {
        let key = AppStore.defaultBridgeSubnetKey
        let previousDefault = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousDefault { UserDefaults.standard.set(previousDefault, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let base = "/tmp/doryd-bridge-setting-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder()
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder()

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            environment: ["XCTestConfigurationFilePath": "DoryTests.xctest"]
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        await store.setDefaultBridgeSubnet("10.44.19.8/20")

        #expect(service.engineStopCount == 1)
        #expect(service.engineStartCount == 1)
        #expect(launchAgent.configurations.last?.bridgeSubnetCIDR == "10.44.16.0/20")
        #expect(store.defaultBridgeSubnet == "10.44.16.0/20")
        #expect(UserDefaults.standard.string(forKey: key) == "10.44.16.0/20")
        #expect(store.settingsNotice?.kind == .success)
        #expect(
            store.settingsNotice?.message
                == "Docker bridge subnet changed to 10.44.16.0/20. Existing data was preserved."
        )
        let restarted = await workloadRecorder.startedIDs
        #expect(Set(restarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
        #expect(!restarted.contains("c5"))
    }

    @MainActor
    @Test func daemonOwnedSettingRollsBackWhenLaunchAgentRejectsNewConfiguration() async throws {
        guard MacHostPlatform.current().isAppleSilicon else { return }
        let key = SharedVMProvisioner.Config.rosettaX86Key
        let previousDefault = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousDefault { UserDefaults.standard.set(previousDefault, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: key)

        let base = "/tmp/doryd-setting-rollback-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let workloadRecorder = WorkloadStartRecorder(failingIDs: ["c3"])
        let shim = DockerShim(runtime: RecordingWorkloadRuntime(recorder: workloadRecorder))
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in await shim.handle(request) }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let launchAgent = LaunchAgentConfigurationRecorder(rejectAMD64: true)

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true,
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) }
        )
        store.routeDockerCLI = false
        await store.connectBackend()
        await store.setRosettaX86(true)

        #expect(service.engineStopCount == 1)
        #expect(service.engineStartCount == 1)
        #expect(launchAgent.configurations.map(\.amd64EmulationEnabled) == [false, true, false])
        #expect(!store.rosettaX86Enabled)
        #expect(!UserDefaults.standard.bool(forKey: key))
        #expect(store.loadState == .ready)
        #expect(store.dorydRuntimeActive)
        #expect(store.settingsNotice?.kind == .failure)
        #expect(store.settingsNotice?.message.contains("previous setting was restored") == true)
        #expect(store.settingsNotice?.message.contains("web-api") == true)
        let rollbackRestarted = await workloadRecorder.startedIDs
        #expect(Set(rollbackRestarted) == Set(MockData.containers.filter(\.isRunning).map(\.id)))
    }

    @MainActor
    @Test func idleSettingsDoNotPublishRejectedDorydState() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        service.setIdleAvailable(false)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.runtimeMode = "manual"
        store.idlePolicy = IdlePolicy(sleepAfterMinutes: 15)

        await store.setRuntimeMode("auto-idle")

        #expect(store.runtimeMode == "manual")
        #expect(store.settingsNotice?.kind == .failure)
        #expect(store.settingsNotice?.message == "doryd did not apply the idle mode: idle unavailable")

        await store.setIdleSleepAfter(5)

        #expect(store.runtimeMode == "manual")
        #expect(store.idlePolicy.sleepAfterMinutes == 15)
        #expect(store.actionError == nil)
        #expect(store.settingsNotice?.kind == .failure)
        #expect(store.settingsNotice?.message == "doryd did not apply the idle policy: idle unavailable")
    }

    @MainActor
    @Test func disablingDomainsRemovesAuthorizationBeforeStoppingDaemonListeners() async throws {
        let key = AppStore.domainsEnabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let removal = AuthorizedNetworkingRemovalRecorder()
        let trust = LocalCATrustRemovalRecorder()
        let launchAgent = LaunchAgentConfigurationRecorder()
        let store = AppStore(
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            authorizedNetworkingRemover: { try removal.remove() },
            localCATrustManager: trust
        )

        store.applyNetworkingSettings(domainsEnabled: false)
        try await waitUntil { !store.networkingAuthorizationInFlight }

        #expect(removal.callCount == 1)
        #expect(trust.removeCallCount == 1)
        #expect(launchAgent.configurations.map(\.domainsEnabled) == [false])
        #expect(!store.domainsEnabled)
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == false)
        #expect(store.networkingAuthorizationMessage == "Local domains and their system routing are disabled.")
    }

    @MainActor
    @Test func failedDomainAuthorizationRemovalKeepsDaemonNetworkingEnabled() async throws {
        let key = AppStore.domainsEnabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let removal = AuthorizedNetworkingRemovalRecorder(fails: true)
        let trust = LocalCATrustRemovalRecorder()
        let launchAgent = LaunchAgentConfigurationRecorder()
        let store = AppStore(
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            authorizedNetworkingRemover: { try removal.remove() },
            localCATrustManager: trust
        )

        store.applyNetworkingSettings(domainsEnabled: false)
        try await waitUntil { !store.networkingAuthorizationInFlight }

        #expect(removal.callCount == 1)
        #expect(trust.removeCallCount == 0)
        #expect(launchAgent.configurations.map(\.domainsEnabled) == [true])
        #expect(store.domainsEnabled)
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == true)
        #expect(store.networkingAuthorizationMessage?.contains("stayed enabled") == true)
    }

    @MainActor
    @Test func failedLocalCATrustCleanupStillLeavesDomainsSafelyDisabled() async throws {
        let key = AppStore.domainsEnabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let removal = AuthorizedNetworkingRemovalRecorder()
        let trust = LocalCATrustRemovalRecorder(fails: true)
        let launchAgent = LaunchAgentConfigurationRecorder()
        let store = AppStore(
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            authorizedNetworkingRemover: { try removal.remove() },
            localCATrustManager: trust
        )

        store.applyNetworkingSettings(domainsEnabled: false)
        try await waitUntil { !store.networkingAuthorizationInFlight }

        #expect(removal.callCount == 1)
        #expect(trust.removeCallCount == 1)
        #expect(!store.domainsEnabled)
        #expect(store.networkingAuthorizationMessage?.contains("login keychain") == true)
        #expect(store.settingsNotice?.kind == .failure)
    }

    @MainActor
    @Test func rejectedDomainDisableRestoresEnabledDaemonConfiguration() async throws {
        let key = AppStore.domainsEnabledKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let removal = AuthorizedNetworkingRemovalRecorder()
        let trust = LocalCATrustRemovalRecorder()
        let launchAgent = LaunchAgentConfigurationRecorder(rejectDisabledDomains: true)
        let store = AppStore(
            dorydLaunchAgentEnsurer: { configuration in launchAgent.ensure(configuration) },
            authorizedNetworkingRemover: { try removal.remove() },
            localCATrustManager: trust
        )

        store.applyNetworkingSettings(domainsEnabled: false)
        try await waitUntil { !store.networkingAuthorizationInFlight }

        #expect(removal.callCount == 1)
        #expect(trust.removeCallCount == 1)
        #expect(launchAgent.configurations.map(\.domainsEnabled) == [false, true])
        #expect(store.domainsEnabled)
        #expect(store.networkingAuthorizationMessage?.contains("Reauthorize") == true)
    }

    @MainActor
    @Test func idleSettingsShowInAppNoticeOnSuccess() async throws {
        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService()
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.runtimeMode = "manual"

        await store.setRuntimeMode("auto-idle")

        #expect(store.runtimeMode == "auto-idle")
        #expect(store.settingsNotice?.kind == .success)
        #expect(store.settingsNotice?.message == "Auto-Idle applied.")
    }

#if DEBUG
    @MainActor
    @Test func appStoreDoesNotMakeIdleSleepDecisionForDorydEngine() async throws {
        let base = "/tmp/dasid-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let socketPath = base + "/doryd.sock"
        defer { try? FileManager.default.removeItem(atPath: base) }

        let shim = DockerShim(runtime: MockRuntime())
        let dockerServer = ShimHTTPServer(socketPath: socketPath) { request in
            await shim.handle(request)
        }
        try dockerServer.start()
        defer { dockerServer.stop() }

        let listener = NSXPCListener.anonymous()
        let service = FakeDorydService(socketPath: socketPath)
        let delegate = FakeDorydListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let store = AppStore(
            dorydClient: DorydClient(endpoint: listener.endpoint),
            useDorydEngine: true
        )
        store.routeDockerCLI = false

        await store.connectBackend()
        store.containers = []
        store.runtimeMode = "auto-idle"
        store.idlePolicy = IdlePolicy(sleepAfterMinutes: 1)
        store.engineSleeping = false
        store.engineRunning = true
        store.loadState = .ready
        store.engineActivity.setLastForTests(Date(timeIntervalSinceNow: -120))

        await store.evaluateIdleSleepForTests()

        #expect(service.engineSleepCount == 0)
        #expect(!store.engineSleeping)
    }
#endif
}

private enum WorkloadStartFixtureError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let id): "fixture rejected start for \(id)"
        }
    }
}

private actor WorkloadStartRecorder {
    private(set) var startedIDs: [String] = []
    private let failingIDs: Set<String>

    init(failingIDs: Set<String> = []) {
        self.failingIDs = failingIDs
    }

    func recordStart(_ id: String) throws {
        startedIDs.append(id)
        if failingIDs.contains(id) {
            throw WorkloadStartFixtureError.rejected(id)
        }
    }
}

private struct RecordingWorkloadRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    let recorder: WorkloadStartRecorder

    func snapshot() async throws -> RuntimeSnapshot { try await MockRuntime().snapshot() }
    func start(containerID: String) async throws { try await recorder.recordStart(containerID) }
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func pull(image: String, registryAuth: String?) async throws {}
    func create(_ spec: ContainerSpec) async throws -> String { "recording-\(spec.name)" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        ExecResult(exitCode: 0, output: "")
    }
    func createNetwork(name: String, labels: [String: String]) async throws {}
    func removeNetwork(name: String) async throws {}
    func removeVolume(name: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
}

private final class LaunchAgentConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let rejectAMD64: Bool
    private let rejectDisabledDomains: Bool
    private var recorded: [DorydLaunchAgent.Configuration] = []

    init(rejectAMD64: Bool = false, rejectDisabledDomains: Bool = false) {
        self.rejectAMD64 = rejectAMD64
        self.rejectDisabledDomains = rejectDisabledDomains
    }

    var configurations: [DorydLaunchAgent.Configuration] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func ensure(_ configuration: DorydLaunchAgent.Configuration) -> Bool {
        lock.lock()
        recorded.append(configuration)
        lock.unlock()
        return !(rejectAMD64 && configuration.amd64EmulationEnabled)
            && !(rejectDisabledDomains && !configuration.domainsEnabled)
    }
}

private final class AuthorizedNetworkingRemovalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let fails: Bool
    private var calls = 0

    init(fails: Bool = false) {
        self.fails = fails
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func remove() throws {
        lock.lock()
        calls += 1
        lock.unlock()
        if fails { throw AuthorizedNetworkingRemovalError.injectedFailure }
    }
}

private final class LocalCATrustRemovalRecorder: LocalCATrustManaging, @unchecked Sendable {
    private let lock = NSLock()
    private let fails: Bool
    private var removeCalls = 0

    init(fails: Bool = false) {
        self.fails = fails
    }

    var removeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return removeCalls
    }

    func install(certificateAt path: String) throws -> Bool { false }

    func remove(certificateAt path: String) throws -> Bool {
        lock.lock()
        removeCalls += 1
        lock.unlock()
        if fails { throw LocalCATrustRemovalError.injectedFailure }
        return true
    }
}

private enum LocalCATrustRemovalError: Error {
    case injectedFailure
}

private enum AuthorizedNetworkingRemovalError: Error {
    case injectedFailure
}

private final class FakeDorydService: NSObject, DorydControlXPC {
    let socketPath: String
    let engineShutdownReplyDelay: TimeInterval
    private let lock = NSLock()
    private var _engineStartCount = 0
    private var _engineStopCount = 0
    private var _engineWakeCount = 0
    private var _engineSleepCount = 0
    private var _engineDashboardSnapshotCount = 0
    private var _engineDashboardSnapshot: [String: Data]?
    private var _engineState = "running"
    private var _engineDetail = "ok"
    private var _engineStartOK = true
    private var _engineStartMessage = ""
    private var _idleAvailable = true
    private var idleMode = "always-on"
    private var idlePolicy: [String: Any] = [
        "sleepAfterMinutes": 15,
        "keepPublishedPortsAwake": true,
        "keepKubernetesAwake": true,
        "keepPinnedProjectsAwake": true,
        "showWakeNotifications": true,
    ]
    private var networkRouteBatches: [[DorydDomainRoute]] = []
    private var _repairTargets: [String] = []
    private var machines: [String: NSDictionary] = [
        "dev": FakeDorydService.machineRow(
            id: "dev",
            state: "running",
            pid: 1234,
            agentBuild: "agent-test",
            handoffFDCount: 2,
            address: "192.168.215.40",
            displayMode: "desktop",
            shares: [
                [
                    "tag": "src",
                    "hostPath": "/Users/me/src",
                    "guestPath": "/workspace/src",
                    "readOnly": true,
                ] as NSDictionary,
            ],
            environment: [
                [
                    "key": "ANTHROPIC_API_KEY",
                    "value": "test-token",
                ] as NSDictionary,
            ]
        )
    ]
    private var _machineStartCount = 0
    private var _latestMachineStartOperationID: String?
    private var _machineStopCount = 0
    private var _latestMachineStopOperationID: String?
    private var _machinePauseCount = 0
    private var _latestMachinePauseOperationID: String?
    private var _machineSuspendCount = 0
    private var _machineResumeCount = 0
    private var _latestMachineResumeOperationID: String?
    private var _machineRestartCount = 0
    private var _machineDeleteCount = 0
    private var _machineDeleteOK = true
    private var _machineDeleteMessage = ""
    private var _machineCreateCount = 0
    private var _machineUpdateCount = 0
    private var _latestManagedDesktopKernelRefreshRequest: NSDictionary?
    private var _machineProvisionCount = 0
    private var _machineProvisionOK = true
    private var _machineProvisionMessage = ""
    private var _machineSnapshotCount = 0
    private var _machineCloneSnapshotCount = 0
    private var _machineCloneSnapshotOK = true
    private var _machineCloneSnapshotMessage = ""
    private var _machineCloneSnapshotDuplicateFailures = 0
    private var _machineRestoreSnapshotCount = 0
    private var _machineDeleteSnapshotCount = 0
    private var _latestMachineCreateConfig: NSDictionary?
    private var _latestMachineUpdateConfig: NSDictionary?
    private var _latestMachineProvisionRecipe: String?
    private var _latestMachineDesktopUpdateOperationID: String?
    private var _machineDesktopUpdateOperationIDResponseOverride: Any?
    private var _latestMachineTransferRequest: NSDictionary?
    private var _latestMachineTransferStartRequest: NSDictionary?
    private var _machineTransferResponseOverride: NSDictionary?
    private var _machineTransferOperationResponseOverride: NSDictionary?
    private var _machineTransferCurrentResponseOverride: NSDictionary?
    private var _machineTransferCancelCount = 0
    private var _latestMachineGuestExportRequest: NSDictionary?
    private var _machineGuestExportStartResponseOverride: NSDictionary?
    private var _machineGuestExportOperationResponseOverride: NSDictionary?
    private var _machineGuestExportCurrentResponseOverride: NSDictionary?
    private var _machineImportAssessmentOverride: NSDictionary?
    private var _machineEventBatchOverride: NSDictionary?
    private var _machineFlightRecorderBatchOverride: NSDictionary?
    private var _machineDeviceTelemetryResponseOverride: NSDictionary?
    private var _machineUSBAttachResponseOverride: NSDictionary?
    private var _machineUSBDetachResponseOverride: NSDictionary?
    private var _hostUSBDevicesResponseOverride: NSArray?
    private var _machineSerialConsoleBatchOverride: NSDictionary?
    private var _latestMachineSerialConsoleCursor: NSDictionary?
    private var _latestMachineSerialConsoleInput: Data?
    private var _machineEventQueryCount = 0
    private var _machineListCount = 0
    private var _machineGuestExportCancelCount = 0
    private var _machineGuestExportDiscardCount = 0
    private var runtimeIdentityOverride: NSDictionary?
    private var artifactEvidenceOverride: NSDictionary?
    private var installedDesktopPayloadReceiptOverride: NSDictionary?
    private var snapshotConsistencyOverride: Any?
    private var snapshotQuiesceReceiptOverride: NSDictionary?
    private var snapshots: [String: [NSDictionary]] = [:]
    private var backupStatuses: [String: NSDictionary] = [:]
    var engineStartCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _engineStartCount
    }

    var latestMachineTransferRequest: NSDictionary? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineTransferRequest
    }

    var latestMachineTransferStartRequest: NSDictionary? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineTransferStartRequest
    }

    var machineTransferCancelCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineTransferCancelCount
    }

    func setMachineTransferResponse(_ response: NSDictionary?) {
        lock.lock(); defer { lock.unlock() }
        _machineTransferResponseOverride = response
    }

    func setMachineUSBAttachResponse(_ response: NSDictionary?) {
        lock.lock(); defer { lock.unlock() }
        _machineUSBAttachResponseOverride = response
    }

    func setMachineUSBDetachResponse(_ response: NSDictionary?) {
        lock.lock(); defer { lock.unlock() }
        _machineUSBDetachResponseOverride = response
    }

    func setHostUSBDevicesResponse(_ response: NSArray?) {
        lock.lock(); defer { lock.unlock() }
        _hostUSBDevicesResponseOverride = response
    }

    func setMachineTransferOperationResponse(_ response: NSDictionary?) {
        lock.lock(); defer { lock.unlock() }
        _machineTransferOperationResponseOverride = response
    }

    func setMachineTransferCurrentResponse(_ response: NSDictionary?) {
        lock.lock(); defer { lock.unlock() }
        _machineTransferCurrentResponseOverride = response
    }

    func machineTransferOperationResponse(
        operationID: String,
        phase: String
    ) -> NSDictionary {
        Self.transferOperationRow(operationID: operationID, phase: phase)
    }

    var latestMachineGuestExportRequest: NSDictionary? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineGuestExportRequest
    }

    var machineGuestExportCancelCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineGuestExportCancelCount
    }

    var machineGuestExportDiscardCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineGuestExportDiscardCount
    }

    func setMachineGuestExportStartResponse(_ response: NSDictionary?) {
        lock.lock(); defer { lock.unlock() }
        _machineGuestExportStartResponseOverride = response
    }

    func setMachineGuestExportOperationResponse(_ response: NSDictionary?) {
        lock.lock(); defer { lock.unlock() }
        _machineGuestExportOperationResponseOverride = response
    }

    func setMachineGuestExportCurrentResponse(_ response: NSDictionary?) {
        lock.lock(); defer { lock.unlock() }
        _machineGuestExportCurrentResponseOverride = response
    }

    func setMachineImportAssessment(_ response: NSDictionary?) {
        lock.lock(); defer { lock.unlock() }
        _machineImportAssessmentOverride = response
    }

    func setMachineEventBatch(_ response: NSDictionary?) {
        lock.lock(); defer { lock.unlock() }
        _machineEventBatchOverride = response
    }

    var machineEventQueryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineEventQueryCount
    }

    var machineListCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineListCount
    }

    func machineGuestExportOperationResponse(
        operationID: String,
        phase: String
    ) -> NSDictionary {
        Self.guestExportOperationRow(operationID: operationID, phase: phase)
    }
    var engineStopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _engineStopCount
    }
    var engineWakeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _engineWakeCount
    }
    var engineSleepCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _engineSleepCount
    }
    var engineDashboardSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _engineDashboardSnapshotCount
    }
    var machineStartCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineStartCount
    }

    var latestMachineStartOperationID: String? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineStartOperationID
    }

    var latestMachineStopOperationID: String? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineStopOperationID
    }

    var latestMachinePauseOperationID: String? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachinePauseOperationID
    }

    var latestMachineResumeOperationID: String? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineResumeOperationID
    }

    var latestMachineDesktopUpdateOperationID: String? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineDesktopUpdateOperationID
    }

    func setMachineDesktopUpdateOperationIDResponse(_ value: Any) {
        lock.lock()
        _machineDesktopUpdateOperationIDResponseOverride = value
        lock.unlock()
    }

    func setMachineEnvironment(_ machineID: String, _ environment: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = machines[machineID] else { return }
        machines[machineID] = Self.machineRow(
            id: machineID,
            state: current["state"] as? String ?? "stopped",
            pid: (current["pid"] as? NSNumber)?.int32Value,
            agentBuild: current["agentBuild"] as? String,
            handoffFDCount: (current["handoffFDCount"] as? NSNumber)?.intValue ?? 0,
            memoryMB: Self.uint64(current["memoryMB"]) ?? 2_048,
            cpuCount: Self.int(current["cpuCount"]) ?? 2,
            address: current["address"] as? String,
            displayMode: current["displayMode"] as? String ?? "headless",
            shares: Self.shareRows(current["shares"]),
            environment: environment.sorted { $0.key < $1.key }.map {
                ["key": $0.key, "value": $0.value] as NSDictionary
            }
        )
    }

    func setMachineTypedSettings(_ machineID: String, _ typedSettings: NSDictionary) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = machines[machineID]?.mutableCopy() as? NSMutableDictionary else {
            return
        }
        current["typedSettings"] = typedSettings
        current.removeObject(forKey: "env")
        current["displayMode"] = "desktop"
        machines[machineID] = current.copy() as? NSDictionary
    }

    func setMachineShares(_ machineID: String, _ shares: Any?) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = machines[machineID]?.mutableCopy() as? NSMutableDictionary else {
            return
        }
        if let shares {
            current["shares"] = shares
        } else {
            current.removeObject(forKey: "shares")
        }
        machines[machineID] = current.copy() as? NSDictionary
    }

    func setMachineAgentHandshake(
        _ machineID: String,
        protocolVersion: Any?,
        capabilities: Any?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = machines[machineID]?.mutableCopy() as? NSMutableDictionary else {
            return
        }
        current.removeObject(forKey: "agentProtocolVersion")
        current.removeObject(forKey: "agentCapabilities")
        if let protocolVersion {
            current["agentProtocolVersion"] = protocolVersion
        }
        if let capabilities {
            current["agentCapabilities"] = capabilities
        }
        machines[machineID] = current
    }

    func setMachineIntegrationHealth(_ machineID: String, _ health: Any?) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = machines[machineID]?.mutableCopy() as? NSMutableDictionary else {
            return
        }
        if let health {
            current["integrationHealth"] = health
        } else {
            current.removeObject(forKey: "integrationHealth")
        }
        machines[machineID] = current.copy() as? NSDictionary
    }

    func setMachineEFIRuntime(
        _ machineID: String,
        integrationHealth: NSDictionary
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = machines[machineID]?.mutableCopy() as? NSMutableDictionary else {
            return
        }
        current["bootMode"] = "efi"
        current["installerMediaAttached"] = true
        current["displayMode"] = "desktop"
        current["shares"] = []
        current["agentBuild"] = "dory-vmm/efi"
        current.removeObject(forKey: "agentProtocolVersion")
        current.removeObject(forKey: "agentCapabilities")
        current.removeObject(forKey: "agentSocketPath")
        current.removeObject(forKey: "dockerdSocketPath")
        current.removeObject(forKey: "shellSocketPath")
        current["integrationHealth"] = integrationHealth
        machines[machineID] = current.copy() as? NSDictionary
    }

    func setMachineState(_ machineID: String, _ state: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = machines[machineID]?.mutableCopy() as? NSMutableDictionary else {
            return
        }
        current["state"] = state
        machines[machineID] = current.copy() as? NSDictionary
    }

    func setMachineSavedState(_ machineID: String, _ savedState: Any?) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = machines[machineID]?.mutableCopy() as? NSMutableDictionary else {
            return
        }
        if let savedState {
            current["savedState"] = savedState
        } else {
            current.removeObject(forKey: "savedState")
        }
        machines[machineID] = current.copy() as? NSDictionary
    }

    func setMachineCloneReceipt(_ machineID: String, _ receipt: Any?) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = machines[machineID]?.mutableCopy() as? NSMutableDictionary else {
            return
        }
        if let receipt {
            current["cloneReceipt"] = receipt
        } else {
            current.removeObject(forKey: "cloneReceipt")
        }
        machines[machineID] = current.copy() as? NSDictionary
    }

    func setMachineFailure(
        _ machineID: String,
        _ failure: Any?,
        activeOperation: Any? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = machines[machineID]?.mutableCopy() as? NSMutableDictionary else {
            return
        }
        if let failure {
            current["failure"] = failure
        } else {
            current.removeObject(forKey: "failure")
        }
        if let activeOperation {
            current["activeOperation"] = activeOperation
        } else {
            current.removeObject(forKey: "activeOperation")
        }
        machines[machineID] = current.copy() as? NSDictionary
    }

    func setMachineFlightRecorderSummary(_ machineID: String, _ summary: Any?) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = machines[machineID]?.mutableCopy() as? NSMutableDictionary else {
            return
        }
        if let summary {
            current["flightRecorder"] = summary
        } else {
            current.removeObject(forKey: "flightRecorder")
        }
        machines[machineID] = current.copy() as? NSDictionary
    }

    var machineStopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineStopCount
    }
    var machinePauseCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machinePauseCount
    }
    var machineSuspendCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineSuspendCount
    }
    var machineResumeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineResumeCount
    }
    var machineRestartCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineRestartCount
    }
    var machineDeleteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineDeleteCount
    }
    var machineCreateCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineCreateCount
    }
    var machineUpdateCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineUpdateCount
    }
    var machineProvisionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineProvisionCount
    }
    var machineSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineSnapshotCount
    }
    var machineCloneSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineCloneSnapshotCount
    }
    var machineRestoreSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineRestoreSnapshotCount
    }
    var machineDeleteSnapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _machineDeleteSnapshotCount
    }
    var latestMachineCreateConfig: NSDictionary? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineCreateConfig
    }
    var latestMachineUpdateConfig: NSDictionary? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineUpdateConfig
    }
    var latestManagedDesktopKernelRefreshRequest: NSDictionary? {
        lock.lock(); defer { lock.unlock() }
        return _latestManagedDesktopKernelRefreshRequest
    }
    var latestMachineProvisionRecipe: String? {
        lock.lock(); defer { lock.unlock() }
        return _latestMachineProvisionRecipe
    }
    var repairTargets: [String] {
        lock.lock(); defer { lock.unlock() }
        return _repairTargets
    }
    var latestNetworkRoutes: [DorydDomainRoute] {
        lock.lock(); defer { lock.unlock() }
        return networkRouteBatches.last ?? []
    }

    init(
        socketPath: String = "/tmp/doryd-test.sock",
        engineShutdownReplyDelay: TimeInterval = 0,
        runtimeIdentityOverride: NSDictionary? = nil,
        artifactEvidenceOverride: NSDictionary? = nil,
        installedDesktopPayloadReceiptOverride: NSDictionary? = nil,
        snapshotConsistencyOverride: Any? = nil,
        snapshotQuiesceReceiptOverride: NSDictionary? = nil
    ) {
        self.socketPath = socketPath
        self.engineShutdownReplyDelay = engineShutdownReplyDelay
        self.runtimeIdentityOverride = runtimeIdentityOverride
        self.artifactEvidenceOverride = artifactEvidenceOverride
        self.installedDesktopPayloadReceiptOverride = installedDesktopPayloadReceiptOverride
        self.snapshotConsistencyOverride = snapshotConsistencyOverride
        self.snapshotQuiesceReceiptOverride = snapshotQuiesceReceiptOverride
        if let existing = machines["dev"]?.mutableCopy() as? NSMutableDictionary {
            if let runtimeIdentityOverride {
                existing["runtimeIdentity"] = runtimeIdentityOverride
                if let graphicsSelection = Self.runtimeGraphicsSelection(
                    for: runtimeIdentityOverride
                ) {
                    existing["runtimeGraphicsSelection"] = graphicsSelection
                }
            }
            if let installedDesktopPayloadReceiptOverride {
                existing["installedDesktopPayloadReceipt"] =
                    installedDesktopPayloadReceiptOverride
            }
            machines["dev"] = existing.copy() as? NSDictionary
        }
    }

    func machineRuntimeGraphicsSelection(_ machineID: String) -> NSDictionary? {
        lock.lock(); defer { lock.unlock() }
        return machines[machineID]?["runtimeGraphicsSelection"] as? NSDictionary
    }

    func defaultRuntimeGraphicsSelection(_ machineID: String) -> NSDictionary? {
        lock.lock(); defer { lock.unlock() }
        guard let identity = machines[machineID]?["runtimeIdentity"] as? NSDictionary else {
            return nil
        }
        return Self.runtimeGraphicsSelection(for: identity)
    }

    func setMachineRuntimeGraphicsSelection(
        _ machineID: String,
        _ selection: NSDictionary?
    ) {
        lock.lock(); defer { lock.unlock() }
        guard let row = machines[machineID]?.mutableCopy() as? NSMutableDictionary else {
            return
        }
        if let selection {
            row["runtimeGraphicsSelection"] = selection
        } else {
            row.removeObject(forKey: "runtimeGraphicsSelection")
        }
        machines[machineID] = row.copy() as? NSDictionary
    }

    func setEngineStatus(_ state: String, detail: String = "ok") {
        lock.lock()
        _engineState = state
        _engineDetail = detail
        lock.unlock()
    }

    func setDashboardSnapshot(_ snapshot: [String: Data]) {
        lock.lock()
        _engineDashboardSnapshot = snapshot
        lock.unlock()
    }

    func setMachineFlightRecorderBatch(_ response: NSDictionary?) {
        lock.lock()
        _machineFlightRecorderBatchOverride = response
        lock.unlock()
    }

    func setMachineDeviceTelemetryResponse(_ response: NSDictionary?) {
        lock.lock()
        _machineDeviceTelemetryResponseOverride = response
        lock.unlock()
    }

    func setMachineSerialConsoleBatch(_ response: NSDictionary?) {
        lock.lock()
        _machineSerialConsoleBatchOverride = response
        lock.unlock()
    }

    var machineSerialConsoleBatchResponse: NSDictionary {
        lock.lock()
        defer { lock.unlock() }
        return _machineSerialConsoleBatchOverride ?? [:]
    }

    var latestMachineSerialConsoleCursor: NSDictionary? {
        lock.lock()
        defer { lock.unlock() }
        return _latestMachineSerialConsoleCursor
    }

    var latestMachineSerialConsoleInput: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _latestMachineSerialConsoleInput
    }

    func setEngineStartResult(ok: Bool, message: String = "") {
        lock.lock()
        _engineStartOK = ok
        _engineStartMessage = message
        lock.unlock()
    }

    func setMachineProvisionResult(ok: Bool, message: String = "") {
        lock.lock()
        _machineProvisionOK = ok
        _machineProvisionMessage = message
        lock.unlock()
    }

    func setMachineDeleteResult(ok: Bool, message: String = "") {
        lock.lock()
        _machineDeleteOK = ok
        _machineDeleteMessage = message
        lock.unlock()
    }

    func setMachineCloneSnapshotResult(ok: Bool, message: String = "") {
        lock.lock()
        _machineCloneSnapshotOK = ok
        _machineCloneSnapshotMessage = message
        lock.unlock()
    }

    func setMachineCloneSnapshotDuplicateFailures(_ count: Int) {
        lock.lock()
        _machineCloneSnapshotDuplicateFailures = max(0, count)
        lock.unlock()
    }

    func setIdleAvailable(_ available: Bool) {
        lock.lock()
        _idleAvailable = available
        lock.unlock()
    }

    func setIdleMode(_ mode: String) {
        lock.lock()
        idleMode = mode
        lock.unlock()
    }

    func protocolVersion(reply: @escaping (UInt32) -> Void) {
        reply(1)
    }

    func dorySocketPath(reply: @escaping (String) -> Void) {
        reply(socketPath)
    }

    func engineStatus(reply: @escaping (String, String) -> Void) {
        lock.lock()
        let state = _engineState
        let detail = _engineDetail
        lock.unlock()
        reply(state, detail)
    }

    func engineDashboardSnapshot(reply: @escaping (NSDictionary, String) -> Void) {
        lock.lock()
        _engineDashboardSnapshotCount += 1
        let snapshot = _engineDashboardSnapshot
        lock.unlock()
        guard let snapshot else {
            reply([:], "dashboard snapshot unavailable in fake service")
            return
        }
        reply(snapshot.mapValues { $0 as NSData } as NSDictionary, "")
    }

    func engineStart(reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        _engineStartCount += 1
        let ok = _engineStartOK
        let message = _engineStartMessage
        if ok {
            _engineState = "running"
            _engineDetail = "ok"
        }
        lock.unlock()
        reply(ok, message)
    }

    func engineStop(reply: @escaping (Bool, String) -> Void) {
        if engineShutdownReplyDelay > 0 {
            Thread.sleep(forTimeInterval: engineShutdownReplyDelay)
        }
        lock.lock()
        _engineStopCount += 1
        _engineState = "stopped"
        _engineDetail = "stopped"
        lock.unlock()
        reply(true, "")
    }

    func engineSleep(reply: @escaping (Bool, String) -> Void) {
        if engineShutdownReplyDelay > 0 {
            Thread.sleep(forTimeInterval: engineShutdownReplyDelay)
        }
        lock.lock(); _engineSleepCount += 1; lock.unlock()
        reply(true, "")
    }

    func engineWake(reply: @escaping (Bool, String) -> Void) {
        lock.lock(); _engineWakeCount += 1; lock.unlock()
        reply(true, "")
    }

    func dockerAgentInfo(reply: @escaping (NSDictionary, String) -> Void) {
        reply(dockerAgentInfo(), "")
    }

    func dockerAgentPorts(reply: @escaping (NSDictionary, String) -> Void) {
        let port: NSDictionary = ["protocol": "tcp", "port": 8080]
        reply([
            "ports": [port],
            "added": [port],
            "removed": [],
        ] as NSDictionary, "")
    }

    func dockerAgentTelemetry(reply: @escaping (NSDictionary, String) -> Void) {
        reply(dockerTelemetry(), "")
    }

    func machineCreate(_ config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        let id = config["id"] as? String ?? ""
        let row = Self.machineRow(
            id: id,
            state: "created",
            memoryMB: Self.uint64(config["memoryMB"]) ?? 2048,
            cpuCount: Self.int(config["cpuCount"]) ?? 2,
            address: config["address"] as? String,
            displayMode: config["displayMode"] as? String ?? "headless",
            shares: Self.machineStatusShareRows(config["shares"]),
            environment: Self.typedEnvironment(config, baseline: [])
        )
        lock.lock()
        _machineCreateCount += 1
        _latestMachineCreateConfig = config
        machines[id] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineStart(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let current = machines[machineID]
        let row = Self.machineRow(
            id: machineID,
            state: "running",
            pid: 1234,
            agentBuild: "agent-test",
            handoffFDCount: 2,
            memoryMB: Self.uint64(current?["memoryMB"]) ?? 2048,
            cpuCount: Self.int(current?["cpuCount"]) ?? 2,
            address: current?["address"] as? String,
            displayMode: current?["displayMode"] as? String ?? "headless",
            shares: Self.shareRows(current?["shares"]),
            environment: Self.environmentRows(current?["env"])
        )
        _machineStartCount += 1
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineStart(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        _latestMachineStartOperationID = operationID
        lock.unlock()
        machineStart(machineID, reply: reply)
    }

    func machineStop(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let current = machines[machineID]
        let row = Self.machineRow(
            id: machineID,
            state: "stopped",
            memoryMB: Self.uint64(current?["memoryMB"]) ?? 2048,
            cpuCount: Self.int(current?["cpuCount"]) ?? 2,
            address: current?["address"] as? String,
            displayMode: current?["displayMode"] as? String ?? "headless",
            shares: Self.shareRows(current?["shares"]),
            environment: Self.environmentRows(current?["env"])
        )
        _machineStopCount += 1
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineStop(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        _latestMachineStopOperationID = operationID
        lock.unlock()
        machineStop(machineID, reply: reply)
    }

    func machinePause(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let current = machines[machineID]
        let row = Self.machineRow(
            id: machineID,
            state: "paused",
            pid: (current?["pid"] as? NSNumber)?.int32Value ?? 1234,
            agentBuild: current?["agentBuild"] as? String,
            handoffFDCount: Self.int(current?["handoffFDCount"]) ?? 0,
            memoryMB: Self.uint64(current?["memoryMB"]) ?? 2048,
            cpuCount: Self.int(current?["cpuCount"]) ?? 2,
            address: current?["address"] as? String,
            displayMode: current?["displayMode"] as? String ?? "headless",
            shares: Self.shareRows(current?["shares"]),
            environment: Self.environmentRows(current?["env"])
        )
        _machinePauseCount += 1
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machinePause(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        _latestMachinePauseOperationID = operationID
        lock.unlock()
        machinePause(machineID, reply: reply)
    }

    func machineSuspend(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let current = machines[machineID]
        let row = Self.machineRow(
            id: machineID,
            state: "suspended",
            memoryMB: Self.uint64(current?["memoryMB"]) ?? 2048,
            cpuCount: Self.int(current?["cpuCount"]) ?? 2,
            address: current?["address"] as? String,
            displayMode: current?["displayMode"] as? String ?? "headless",
            shares: Self.shareRows(current?["shares"]),
            environment: Self.environmentRows(current?["env"]),
            savedState: Self.savedStateRow
        )
        _machineSuspendCount += 1
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineResume(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let current = machines[machineID]
        let row = Self.machineRow(
            id: machineID,
            state: "running",
            pid: (current?["pid"] as? NSNumber)?.int32Value ?? 1234,
            agentBuild: current?["agentBuild"] as? String,
            handoffFDCount: Self.int(current?["handoffFDCount"]) ?? 0,
            memoryMB: Self.uint64(current?["memoryMB"]) ?? 2048,
            cpuCount: Self.int(current?["cpuCount"]) ?? 2,
            address: current?["address"] as? String,
            displayMode: current?["displayMode"] as? String ?? "headless",
            shares: Self.shareRows(current?["shares"]),
            environment: Self.environmentRows(current?["env"])
        )
        _machineResumeCount += 1
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineResume(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        _latestMachineResumeOperationID = operationID
        lock.unlock()
        machineResume(machineID, reply: reply)
    }

    func machineRestart(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let current = machines[machineID]
        let row = Self.machineRow(
            id: machineID,
            state: "running",
            pid: ((current?["pid"] as? NSNumber)?.int32Value ?? 1234) + 1,
            agentBuild: current?["agentBuild"] as? String,
            handoffFDCount: Self.int(current?["handoffFDCount"]) ?? 0,
            memoryMB: Self.uint64(current?["memoryMB"]) ?? 2048,
            cpuCount: Self.int(current?["cpuCount"]) ?? 2,
            address: current?["address"] as? String,
            displayMode: current?["displayMode"] as? String ?? "headless",
            shares: Self.shareRows(current?["shares"]),
            environment: Self.environmentRows(current?["env"])
        )
        _machineRestartCount += 1
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineUpdate(_ machineID: String, config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        _machineUpdateCount += 1
        _latestMachineUpdateConfig = config
        let current = machines[machineID] ?? Self.machineRow(id: machineID, state: "stopped")
        let memoryMB = (config["memoryMB"] as? NSNumber)?.uint64Value
            ?? config["memoryMB"] as? UInt64
            ?? (current["memoryMB"] as? NSNumber)?.uint64Value
            ?? current["memoryMB"] as? UInt64
            ?? 2048
        let cpuCount = (config["cpuCount"] as? NSNumber)?.intValue
            ?? config["cpuCount"] as? Int
            ?? (current["cpuCount"] as? NSNumber)?.intValue
            ?? current["cpuCount"] as? Int
            ?? 2
        let address = config["address"] == nil ? current["address"] as? String : config["address"] as? String
        let shares = config["shares"] == nil ? Self.shareRows(current["shares"]) : Self.shareRows(config["shares"])
        let environment = Self.typedEnvironment(
            config,
            baseline: Self.environmentRows(current["env"])
        )
        let state = current["state"] as? String ?? "stopped"
        let row = Self.machineRow(
            id: machineID,
            state: state,
            pid: current["pid"] as? Int32,
            agentBuild: current["agentBuild"] as? String,
            handoffFDCount: (current["handoffFDCount"] as? Int) ?? 0,
            memoryMB: memoryMB,
            cpuCount: cpuCount,
            address: address,
            displayMode: current["displayMode"] as? String ?? "headless",
            shares: shares,
            environment: environment,
            displayPresentation: current["displayPresentation"] as? NSDictionary
        )
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineRefreshManagedDesktopKernel(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        _latestManagedDesktopKernelRefreshRequest = request
        let current = machines[machineID] ?? Self.machineRow(
            id: machineID,
            state: "stopped"
        )
        lock.unlock()
        reply(true, current, "")
    }

    func machineDisplayPresentationSet(
        _ machineID: String,
        presentation: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        let current = machines[machineID] ?? Self.machineRow(id: machineID, state: "stopped")
        let row = NSMutableDictionary(dictionary: current)
        row["displayPresentation"] = presentation
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineDelete(_ machineID: String, reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        _machineDeleteCount += 1
        let ok = _machineDeleteOK
        let message = _machineDeleteMessage
        if ok {
            machines.removeValue(forKey: machineID)
        }
        lock.unlock()
        reply(ok, message)
    }

    func machineList(reply: @escaping (NSArray, String) -> Void) {
        lock.lock()
        _machineListCount += 1
        let rows = machines.keys.sorted().compactMap { machines[$0] }
        lock.unlock()
        reply(rows as NSArray, "")
    }

    func machineEvents(
        _ afterSequence: UInt64,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        _machineEventQueryCount += 1
        let row = _machineEventBatchOverride ?? [
            "schemaVersion": UInt16(1),
            "headSequence": afterSequence,
            "snapshotRequired": afterSequence == 0,
            "events": [] as [NSDictionary],
        ]
        lock.unlock()
        reply(true, row, "")
    }

    func machineFlightRecorder(
        _ machineID: String,
        afterSequence: UInt64,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        let row = _machineFlightRecorderBatchOverride ?? [
            "schemaVersion": UInt16(1),
            "machineID": machineID,
            "headSequence": UInt64(0),
            "snapshotRequired": afterSequence > 0,
            "events": [] as [NSDictionary],
        ]
        lock.unlock()
        reply(true, row, "")
    }

    func machineDeviceTelemetry(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        let row = _machineDeviceTelemetryResponseOverride ?? [:]
        lock.unlock()
        reply(true, row, "")
    }

    func machineUSBAttach(
        _ machineID: String,
        busID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        let row = _machineUSBAttachResponseOverride ?? [
            "machineID": machineID,
            "busID": busID,
            "port": 4,
            "vsockPort": UInt32(1_025),
            "deviceID": UInt32(0x0003_0002),
            "speed": UInt32(3),
        ]
        lock.unlock()
        reply(true, row, "")
    }

    func hostUSBDevices(reply: @escaping (Bool, NSArray, String) -> Void) {
        lock.lock()
        let rows = _hostUSBDevicesResponseOverride ?? [
            [
                "busID": "3-2",
                "vendorID": 0x05ac,
                "productID": 0x12a8,
                "vendorName": "Example Vendor",
                "productName": "Example Device",
                "deviceClass": 3,
                "speed": 4,
            ],
        ]
        lock.unlock()
        reply(true, rows, "")
    }

    func machineUSBDetach(
        _ machineID: String,
        busID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        let row = _machineUSBDetachResponseOverride ?? [
            "machineID": machineID,
            "busID": busID,
        ]
        lock.unlock()
        reply(true, row, "")
    }

    func machineSerialConsoleRead(
        _ machineID: String,
        cursor: NSDictionary,
        limit: UInt32,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        _latestMachineSerialConsoleCursor = cursor
        let row = _machineSerialConsoleBatchOverride ?? [
            "schemaVersion": UInt16(1),
            "machineID": machineID,
            "startOffset": UInt64(0),
            "nextOffset": UInt64(0),
            "totalBytes": UInt64(0),
            "snapshotRequired": false,
            "inputAvailable": false,
            "bytesBase64": "",
        ]
        lock.unlock()
        reply(true, row, "")
    }

    func machineSerialConsoleWrite(
        _ machineID: String,
        data: NSData,
        reply: @escaping (Bool, String) -> Void
    ) {
        lock.lock()
        _latestMachineSerialConsoleInput = data as Data
        lock.unlock()
        reply(true, "")
    }

    func machineStats(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let total = (Self.uint64(machines[machineID]?["memoryMB"]) ?? 2048) * 1_048_576
        lock.unlock()
        reply(true, [
            "schema": "dev.dory.machine.stats",
            "version": 1,
            "cpuPercent": 12.5,
            "memoryUsedBytes": total / 2,
            "memoryTotalBytes": total,
            "networkReceiveBytes": UInt64(100),
            "networkTransmitBytes": UInt64(200),
            "blockReadBytes": UInt64(300),
            "blockWriteBytes": UInt64(400),
            "processCount": UInt64(12),
            "uptimeSeconds": 98.765,
        ] as NSDictionary, "")
    }

    func machineExec(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        reply(true, Self.execRow(stdout: "cargo 1.0\n"), "")
    }

    func machineTransfer(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        _latestMachineTransferRequest = request
        let override = _machineTransferResponseOverride
        lock.unlock()
        if let override {
            reply(true, override, "")
            return
        }
        let transferID = String(repeating: "a", count: 32)
        reply(true, [
            "schema": UInt16(1),
            "transferID": transferID,
            "guestDestination": "/home/developer/Downloads/Dory Transfer " + transferID,
            "filesSent": UInt64(1),
            "bytesSent": UInt64(5),
        ], "")
    }

    func machineTransferStart(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        _latestMachineTransferStartRequest = request
        let override = _machineTransferOperationResponseOverride
        lock.unlock()
        reply(
            true,
            override ?? Self.transferOperationRow(
                operationID: String(repeating: "b", count: 32),
                machineID: machineID,
                phase: "preparing"
            ),
            ""
        )
    }

    func machineTransferStatus(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        let override = _machineTransferOperationResponseOverride
        lock.unlock()
        reply(
            true,
            override ?? Self.transferOperationRow(
                operationID: operationID,
                machineID: machineID,
                phase: "completed"
            ),
            ""
        )
    }

    func machineTransferCurrent(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        _ = machineID
        lock.lock()
        let override = _machineTransferCurrentResponseOverride
        lock.unlock()
        reply(
            true,
            override ?? ["schema": UInt16(1), "active": false],
            ""
        )
    }

    func machineTransferCancel(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        let cancelled = Self.transferOperationRow(
            operationID: operationID,
            machineID: machineID,
            phase: "cancelled"
        )
        lock.lock()
        _machineTransferCancelCount += 1
        _machineTransferOperationResponseOverride = cancelled
        lock.unlock()
        reply(
            true,
            cancelled,
            ""
        )
    }

    func machineGuestExportStart(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        _latestMachineGuestExportRequest = request
        let override = _machineGuestExportStartResponseOverride
        lock.unlock()
        reply(
            true,
            override ?? Self.guestExportOperationRow(
                operationID: String(repeating: "d", count: 32),
                machineID: machineID,
                phase: "preparing"
            ),
            ""
        )
    }

    func machineGuestExportCurrent(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        _ = machineID
        lock.lock()
        let override = _machineGuestExportCurrentResponseOverride
        lock.unlock()
        reply(true, override ?? ["schema": UInt16(1), "active": false], "")
    }

    func machineGuestExportStatus(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        let override = _machineGuestExportOperationResponseOverride
        lock.unlock()
        reply(
            true,
            override ?? Self.guestExportOperationRow(
                operationID: operationID,
                machineID: machineID,
                phase: "completed"
            ),
            ""
        )
    }

    func machineGuestExportCancel(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        let cancelled = Self.guestExportOperationRow(
            operationID: operationID,
            machineID: machineID,
            phase: "cancelled"
        )
        lock.lock()
        _machineGuestExportCancelCount += 1
        _machineGuestExportOperationResponseOverride = cancelled
        lock.unlock()
        reply(true, cancelled, "")
    }

    func machineGuestExportDiscard(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, String) -> Void
    ) {
        _ = machineID
        _ = operationID
        lock.lock()
        _machineGuestExportDiscardCount += 1
        lock.unlock()
        reply(true, "")
    }

    func machineProvision(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        let recipe = request["recipe"] as? String ?? "rust"
        lock.lock()
        _machineProvisionCount += 1
        _latestMachineProvisionRecipe = recipe
        let ok = _machineProvisionOK
        let message = _machineProvisionMessage
        lock.unlock()
        guard ok else {
            reply(false, [:], message)
            return
        }
        reply(true, [
            "recipeID": recipe,
            "install": Self.execRow(stdout: "installed \(recipe)\n"),
            "verify": Self.execRow(stdout: "cargo 1.0\n"),
        ] as NSDictionary, "")
    }

    func machineDesktopUpdate(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        let current = machines[machineID] ?? Self.machineRow(id: machineID, state: "stopped")
        _latestMachineDesktopUpdateOperationID = request["operationID"] as? String
        let operationIDResponse = _machineDesktopUpdateOperationIDResponseOverride
            ?? request["operationID"]
        lock.unlock()
        let response = NSMutableDictionary(dictionary: [
            "machineID": machineID,
            "distro": request["distro"] as? String ?? "ubuntu",
            "version": request["version"] as? String ?? "test",
            "inputSHA256": String(repeating: "1", count: 64),
            "bundleSHA256": String(repeating: "2", count: 64),
            "snapshotID": "du-test",
            "restoredRunningState": false,
            "status": current,
        ] as NSDictionary)
        if let operationIDResponse {
            response["operationID"] = operationIDResponse
        }
        reply(true, response, "")
    }

    func machineSnapshot(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        let id = request["snapshotID"] as? String ?? "s\(UUID().uuidString.prefix(8).lowercased())"
        let baseRow = Self.snapshotRow(
            id: id,
            machineID: machineID,
            note: request["note"] as? String ?? "",
            createdISO: request["createdISO"] as? String ?? "2026-07-07T00:00:00Z"
        )
        lock.lock()
        let mutable = baseRow.mutableCopy() as? NSMutableDictionary
            ?? NSMutableDictionary(dictionary: baseRow)
        if let runtimeIdentityOverride {
            mutable["runtimeIdentity"] = runtimeIdentityOverride
        }
        if let artifactEvidenceOverride {
            mutable["artifactEvidence"] = artifactEvidenceOverride
        }
        if let installedDesktopPayloadReceiptOverride {
            mutable["installedDesktopPayloadReceipt"] =
                installedDesktopPayloadReceiptOverride
        }
        if let snapshotConsistencyOverride {
            mutable["consistency"] = snapshotConsistencyOverride
        }
        if let snapshotQuiesceReceiptOverride {
            mutable["guestQuiesceReceipt"] = snapshotQuiesceReceiptOverride
        }
        let row = mutable.copy() as? NSDictionary ?? baseRow
        _machineSnapshotCount += 1
        snapshots[machineID, default: []].insert(row, at: 0)
        lock.unlock()
        reply(true, row, "")
    }

    func machineSnapshots(_ machineID: String, reply: @escaping (NSArray, String) -> Void) {
        lock.lock()
        let rows: [NSDictionary]
        if machineID.isEmpty {
            rows = snapshots.keys.sorted().flatMap { snapshots[$0] ?? [] }
        } else {
            rows = snapshots[machineID] ?? []
        }
        lock.unlock()
        reply(rows as NSArray, "")
    }

    func machineCloneSnapshot(
        _ machineID: String,
        snapshotID: String,
        newID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        let row = Self.machineRow(id: newID, state: "running", pid: 1234, agentBuild: "agent-test", handoffFDCount: 2)
        lock.lock()
        _machineCloneSnapshotCount += 1
        if _machineCloneSnapshotDuplicateFailures > 0 {
            _machineCloneSnapshotDuplicateFailures -= 1
            lock.unlock()
            reply(false, [:], "machine already exists: \(newID)")
            return
        }
        let ok = _machineCloneSnapshotOK
        let message = _machineCloneSnapshotMessage
        if ok {
            machines[newID] = row
        }
        lock.unlock()
        reply(ok, ok ? row : [:], message)
    }

    func machineRestoreSnapshot(_ machineID: String, snapshotID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        let row = Self.machineRow(id: machineID, state: "running", pid: 1234, agentBuild: "agent-test", handoffFDCount: 2)
        lock.lock()
        _machineRestoreSnapshotCount += 1
        machines[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineDeleteSnapshot(_ machineID: String, snapshotID: String, reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        _machineDeleteSnapshotCount += 1
        snapshots[machineID, default: []].removeAll { $0["id"] as? String == snapshotID }
        lock.unlock()
        reply(true, "")
    }

    func machineExportSnapshot(_ machineID: String, snapshotID: String, path: String, reply: @escaping (Bool, String) -> Void) {
        reply(true, "")
    }

    func machineAssessSnapshotImport(
        _ path: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        lock.lock()
        let row = _machineImportAssessmentOverride ?? Self.importAssessmentRow()
        lock.unlock()
        reply(true, row, "")
    }

    func machineImportSnapshot(_ path: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        let row = Self.snapshotRow(
            id: "imported",
            machineID: "dev",
            note: "imported",
            createdISO: "2026-07-07T00:00:00Z"
        )
        lock.lock()
        snapshots["dev", default: []].insert(row, at: 0)
        lock.unlock()
        reply(true, row, "")
    }

    func machineImportSnapshot(
        _ path: String,
        expectedContentID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard expectedContentID == String(repeating: "a", count: 64) else {
            reply(false, [:], "machine bundle changed after import assessment")
            return
        }
        machineImportSnapshot(path, reply: reply)
    }

    func machineBackupSchedules(reply: @escaping (NSArray, String) -> Void) {
        lock.lock()
        let rows = backupStatuses.keys.sorted().compactMap { backupStatuses[$0] }
        lock.unlock()
        reply(rows as NSArray, "")
    }

    func machineBackupSet(_ schedule: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        guard let machineID = schedule["machineID"] as? String,
              let frequency = schedule["frequency"] as? String else {
            reply(false, [:], "invalid backup schedule")
            return
        }
        let row = Self.backupStatusRow(
            machineID: machineID,
            frequency: frequency,
            keepLocal: Self.int(schedule["keepLocal"]) ?? 7,
            verifyEveryRuns: Self.int(schedule["verifyEveryRuns"]) ?? 7
        )
        lock.lock()
        backupStatuses[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func machineBackupRemove(_ machineID: String, reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        backupStatuses.removeValue(forKey: machineID)
        lock.unlock()
        reply(true, "")
    }

    func machineBackupRun(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        lock.lock()
        let current = backupStatuses[machineID]
        let row = Self.backupStatusRow(
            machineID: machineID,
            frequency: current?["frequency"] as? String ?? "daily",
            keepLocal: Self.int(current?["keepLocal"]) ?? 7,
            verifyEveryRuns: Self.int(current?["verifyEveryRuns"]) ?? 7,
            successfulRuns: (Self.int(current?["successfulRuns"]) ?? 0) + 1,
            verified: true
        )
        backupStatuses[machineID] = row
        lock.unlock()
        reply(true, row, "")
    }

    func remoteConnect(_ config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        reply(true, agentInfo(), "")
    }

    func remotePush(_ machineID: String, localRoot: String, remoteRoot: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        reply(true, [
            "filesSent": 2,
            "bytesSent": 30,
            "filesDeleted": 1,
        ], "")
    }

    func remoteStatus(_ machineID: String, reply: @escaping (NSDictionary, String) -> Void) {
        reply([
            "id": machineID,
            "state": "connected",
            "lastError": "",
            "info": agentInfo(),
            "telemetry": telemetry(),
        ], "")
    }

    func networkReplaceRoutes(_ routes: NSArray, reply: @escaping (Bool, String) -> Void) {
        let decoded = routes.compactMap(Self.domainRoute)
        guard decoded.count == routes.count else {
            reply(false, "invalid routes")
            return
        }
        lock.lock(); networkRouteBatches.append(decoded); lock.unlock()
        reply(true, "")
    }

    func networkStatus(reply: @escaping (NSDictionary, String) -> Void) {
        let customRoutes = latestNetworkRoutes
        let routes = customRoutes.isEmpty
            ? [DorydDomainRoute(hostname: "web.dory.local", address: "127.0.0.42", port: 8080)]
            : customRoutes
        reply([
            "mode": "high-port-dns-http-https-proxy",
            "suffix": "dory.local",
            "dnsBindAddress": "127.0.0.1",
            "dnsPort": 15353,
            "dnsRunning": true,
            "httpProxyPort": 18080,
            "httpProxyRunning": true,
            "httpsProxyPort": 18443,
            "httpsProxyRunning": true,
            "routes": routes.map(Self.dictionary),
            "customRoutes": customRoutes.map(Self.dictionary),
        ] as NSDictionary, "")
    }

    func networkAuthorizationPlan(reply: @escaping (NSDictionary, String) -> Void) {
        reply([
            "degradedMode": "high-port-dns-only",
            "authorizedMode": "system-resolver-proxy-tls",
            "suffix": "dory.local",
            "dnsBindAddress": "127.0.0.1",
            "dnsPort": 15353,
            "httpProxyPort": 18080,
            "httpsProxyPort": 18443,
            "privilegedTCPForwards": [
                [
                    "listenPort": 25,
                    "targetPort": 1025,
                ],
            ],
            "requests": [
                [
                    "id": "resolver.dory.local",
                    "kind": "resolverFile",
                    "title": "Install dory.local resolver",
                    "reason": "Route local domains to doryd.",
                    "requiresAdmin": true,
                    "filePath": "/etc/resolver/dory.local",
                    "fileContents": "nameserver 127.0.0.1\nport 15353\n",
                    "command": ["/usr/bin/install", "-m", "0644", "<generated>", "/etc/resolver/dory.local"],
                ],
            ],
        ] as NSDictionary, "")
    }

    func corporateConnectivityStatus(
        _ runProbes: Bool,
        reply: @escaping (String, String) -> Void
    ) {
        reply(
            """
            {"schemaVersion":1,"enabled":false,"profile":null,"proxyReachable":null,"registryReachable":null,"certificateInstalled":false,"lastCheckedAt":null,"diagnostics":[]}
            """,
            ""
        )
    }

    func corporateConnectivityApply(
        _ profileJSON: String,
        dryRun: Bool,
        reply: @escaping (String, String) -> Void
    ) {
        reply(profileJSON, "")
    }

    func corporateConnectivityDisable(reply: @escaping (String, String) -> Void) {
        corporateConnectivityStatus(false, reply: reply)
    }

    func repairSubsystem(_ target: String, reply: @escaping (Bool, String) -> Void) {
        lock.lock(); _repairTargets.append(target); lock.unlock()
        reply(true, "repaired \(target)")
    }

    func balloonStatus(reply: @escaping (NSDictionary, String) -> Void) {
        let target: NSDictionary = [
            "id": "docker",
            "kind": "docker",
            "currentTargetMB": 2048,
            "targetMB": 1536,
            "reason": "hostWarning",
            "canApply": true,
        ]
        reply([
            "host": [
                "totalBytes": 16_000_000_000,
                "availableBytes": 1_000_000_000,
                "freeBytes": 500_000_000,
                "availableRatio": 0.0625,
                "pressure": "warning",
            ],
            "targets": [target],
            "applicableTargets": [target],
        ] as NSDictionary, "")
    }

    func balloonReconcile(reply: @escaping (NSDictionary, String) -> Void) {
        balloonStatus(reply: reply)
    }

    func idleStatus(reply: @escaping (NSDictionary, String) -> Void) {
        guard idleAvailable else {
            reply([:], "idle unavailable")
            return
        }
        reply(idleStatusDictionary(), "")
    }

    func idleHistory(_ limit: Int, reply: @escaping (NSArray, String) -> Void) {
        let rows: [NSDictionary] = [
            [
                "at": "2026-07-07T00:00:00Z",
                "state": "sleeping",
                "detail": "idle",
            ] as NSDictionary
        ]
        reply(Array(rows.suffix(max(0, limit))) as NSArray, "")
    }

    func idleSetMode(_ mode: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        guard idleAvailable else {
            reply(false, [:], "idle unavailable")
            return
        }
        lock.lock()
        idleMode = mode
        lock.unlock()
        reply(true, idleStatusDictionary(), "")
    }

    func idleSetPolicy(_ key: String, value: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        guard idleAvailable else {
            reply(false, [:], "idle unavailable")
            return
        }
        lock.lock()
        switch key {
        case "sleepAfterMinutes":
            idlePolicy[key] = Int(value) ?? 15
        default:
            idlePolicy[key] = ["1", "true", "yes", "on"].contains(value.lowercased())
        }
        lock.unlock()
        reply(true, idleStatusDictionary(), "")
    }

    func health(reply: @escaping (NSDictionary, String) -> Void) {
        reply([
            "results": [
                [
                    "id": "socket.exists",
                    "status": "pass",
                    "code": "SOCKET_OK",
                    "title": "Socket",
                    "detail": "ok",
                ],
                [
                    "id": "machine.local",
                    "status": "pass",
                    "code": "machine.running",
                    "title": "Local machine running",
                    "detail": "dev=running",
                ],
            ],
        ] as NSDictionary, "")
    }

    func doctorJSON(reply: @escaping (String, String) -> Void) {
        reply(
            """
            {"results":[{"id":"socket.exists","status":"pass","code":"SOCKET_OK","title":"Socket","detail":"ok","action":null}]}
            """,
            ""
        )
    }

    func incidents(_ limit: Int, reply: @escaping (NSArray, String) -> Void) {
        reply([
            [
                "at": "2026-07-07T00:00:00Z",
                "type": "engine.start",
                "detail": "started",
            ]
        ] as NSArray, "")
    }

    private func idleStatusDictionary() -> NSDictionary {
        lock.lock()
        let mode = idleMode
        let policy = idlePolicy
        lock.unlock()
        return [
            "generated_at": "2026-07-07T00:00:00Z",
            "mode": mode,
            "auto_idle_enabled": mode == "auto-idle" || mode == "battery-saver",
            "sleep_after_minutes": policy["sleepAfterMinutes"] ?? 15,
            "can_sleep": true,
            "blockers": [],
            "engine_state": [
                "available": true,
                "owner": "doryd",
                "state": "running",
            ],
            "policy": policy,
        ] as NSDictionary
    }

    private var idleAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return _idleAvailable
    }

    private func dockerAgentInfo() -> NSDictionary {
        [
            "protocolVersion": 1,
            "kernel": "Linux docker",
            "agentBuild": "docker-agent",
            "uptimeSeconds": 11,
            "capabilities": [
                ["id": "clock-sync", "version": 1] as NSDictionary,
                ["id": "exec", "version": 1] as NSDictionary,
                ["id": "exec-stdin", "version": 1] as NSDictionary,
                ["id": "ports-watch", "version": 1] as NSDictionary,
                ["id": "telemetry", "version": 1] as NSDictionary,
            ],
        ]
    }

    private func dockerTelemetry() -> NSDictionary {
        [
            "memTotalKB": 2048,
            "memAvailableKB": 1024,
            "psiSomeAvg10": 0.2,
            "psiFullAvg10": 0.0,
        ]
    }

    private func agentInfo() -> NSDictionary {
        [
            "protocolVersion": 1,
            "kernel": "Linux test",
            "agentBuild": "remote-agent",
            "uptimeSeconds": 9,
            "capabilities": [
                ["id": "exec", "version": 1] as NSDictionary,
                ["id": "sync-push", "version": 1] as NSDictionary,
                ["id": "telemetry", "version": 1] as NSDictionary,
            ],
        ]
    }

    private func telemetry() -> NSDictionary {
        [
            "memTotalKB": 1024,
            "memAvailableKB": 512,
            "psiSomeAvg10": 0.1,
            "psiFullAvg10": 0.0,
        ]
    }

    private static func machineRow(
        id: String,
        state: String,
        pid: Int32? = nil,
        agentBuild: String? = nil,
        agentProtocolVersion: UInt32? = 1,
        agentCapabilities: [NSDictionary] = [
            ["id": "clock-sync", "version": 1] as NSDictionary,
            ["id": "exec", "version": 1] as NSDictionary,
            ["id": "exec-stdin", "version": 1] as NSDictionary,
            ["id": "ports-watch", "version": 1] as NSDictionary,
            ["id": "snapshot-quiesce", "version": 2] as NSDictionary,
            ["id": "sync-push", "version": 2] as NSDictionary,
            ["id": "telemetry", "version": 1] as NSDictionary,
        ],
        handoffFDCount: Int = 0,
        memoryMB: UInt64 = 2048,
        cpuCount: Int = 2,
        address: String? = nil,
        displayMode: String = "headless",
        shares: [NSDictionary] = [],
        environment: [NSDictionary] = [],
        savedState: NSDictionary? = nil,
        displayPresentation: NSDictionary? = nil
    ) -> NSDictionary {
        var row: [String: Any] = [
            "id": id,
            "state": state,
            "lastError": "",
            "handoffFDCount": handoffFDCount,
            "memoryMB": memoryMB,
            "cpuCount": cpuCount,
            "displayMode": displayMode,
            "flightRecorder": [
                "headSequence": UInt64(0),
                "available": true,
            ] as NSDictionary,
        ]
        if let pid { row["pid"] = pid }
        if let agentBuild {
            row["agentBuild"] = agentBuild
            if let agentProtocolVersion {
                row["agentProtocolVersion"] = agentProtocolVersion
                if !agentCapabilities.isEmpty {
                    row["agentCapabilities"] = agentCapabilities
                }
            }
            row["handoffSocketPath"] = "/tmp/handoff.sock"
            row["agentSocketPath"] = "/tmp/agent.sock"
            row["dockerdSocketPath"] = "/tmp/dockerd.sock"
            row["shellSocketPath"] = "/tmp/shell.sock"
        }
        if let address {
            row["address"] = address
            row["configuredAddress"] = address
        }
        row["shares"] = shares
        row["env"] = environment
        if let savedState {
            row["savedState"] = savedState
        }
        if let displayPresentation {
            row["displayPresentation"] = displayPresentation
        }
        return row as NSDictionary
    }

    private static func runtimeGraphicsSelection(
        for runtimeIdentity: NSDictionary
    ) -> NSDictionary? {
        guard runtimeIdentity["mode"] as? String == "resolved-plan",
              runtimeIdentity["backend"] as? String == "dory-hypervisor",
              let planSHA256 = runtimeIdentity["planSHA256"] as? String,
              let planRevision = runtimeIdentity["planRevision"],
              let graphics = runtimeIdentity["graphics"] as? String else {
            return nil
        }
        let backend: String
        switch graphics {
        case "software":
            backend = "software"
        case "host-accelerated-display":
            backend = "virgl"
        case "hardware-accelerated-3d":
            backend = "virgl-venus"
        default:
            return nil
        }
        var selection: [String: Any] = [
            "schemaVersion": UInt16(1),
            "operationID": "01234567-89ab-4cde-8f01-23456789abcd",
            "resolvedPlanSHA256": planSHA256,
            "planRevision": planRevision,
            "accelerationLevel": graphics,
            "backend": backend,
        ]
        if graphics != "software" {
            selection["rendererGeneration"] = UInt64(1)
            selection["rendererWorkerReceiptSHA256"] = String(repeating: "7", count: 64)
            selection["guestProducerFenceProofSHA256"] = String(repeating: "8", count: 64)
        }
        return selection as NSDictionary
    }

    private static let savedStateRow: NSDictionary = [
        "schemaVersion": 1,
        "backend": "apple-virtualization-framework",
        "stateFileSHA256": String(repeating: "a", count: 64),
        "stateFileByteCount": UInt64(4096),
        "hostHardwareModel": "Mac16,1",
        "hostOperatingSystemBuild": "25G90",
        "createdAtUnixMilliseconds": Int64(1_787_318_400_000),
        "portable": false,
    ]

    private static func shareRows(_ value: Any?) -> [NSDictionary] {
        if let rows = value as? [NSDictionary] {
            return rows
        }
        if let rows = value as? NSArray {
            return rows.compactMap { $0 as? NSDictionary }
        }
        return []
    }

    /// Machine-create requests carry host authorization bookmarks. Daemon status deliberately
    /// projects only non-secret share identity, so the fake must enforce the same XPC boundary.
    private static func machineStatusShareRows(_ value: Any?) -> [NSDictionary] {
        shareRows(value).compactMap { row in
            guard let tag = row["tag"] as? String,
                  let hostPath = row["hostPath"] as? String,
                  let guestPath = row["guestPath"] as? String,
                  let readOnly = row["readOnly"] as? NSNumber,
                  CFGetTypeID(readOnly) == CFBooleanGetTypeID() else {
                return nil
            }
            return [
                "tag": tag,
                "hostPath": hostPath,
                "guestPath": guestPath,
                "readOnly": readOnly,
            ] as NSDictionary
        }
    }

    private static func environmentRows(_ value: Any?) -> [NSDictionary] {
        if let rows = value as? [NSDictionary] {
            return rows
        }
        if let rows = value as? NSArray {
            return rows.compactMap { $0 as? NSDictionary }
        }
        return []
    }

    private static func typedEnvironment(
        _ config: NSDictionary,
        baseline: [NSDictionary]
    ) -> [NSDictionary] {
        var environment = Dictionary(uniqueKeysWithValues: baseline.compactMap {
            row -> (String, String)? in
            guard let key = row["key"] as? String,
                  let value = row["value"] as? String else { return nil }
            return (key, value)
        })
        if let identity = config["guestIdentityIntent"] as? NSDictionary {
            if let account = identity["account"] as? NSDictionary {
                apply(account["username"], key: "DORY_GUEST_USER", to: &environment)
                let uid = (account["numericUserID"] as? NSNumber)?.stringValue
                    ?? (account["numericUserID"] as? UInt32).map(String.init)
                if account["numericUserID"] != nil {
                    apply(uid ?? NSNull(), key: "DORY_GUEST_UID", to: &environment)
                }
            }
            if let desktop = identity["desktop"] as? NSDictionary {
                apply(
                    desktop["distributionIdentifier"],
                    key: "DORY_DESKTOP_DISTRO",
                    to: &environment
                )
                apply(desktop["displayName"], key: "DORY_DESKTOP_NAME", to: &environment)
                apply(desktop["version"], key: "DORY_DESKTOP_VERSION", to: &environment)
                apply(
                    desktop["desktopEnvironment"],
                    key: "DORY_DESKTOP_ENVIRONMENT",
                    to: &environment
                )
            }
        }
        if let clipboard = config["clipboardPolicy"] as? NSDictionary {
            apply(clipboard["text"], key: "DORY_CLIPBOARD_POLICY", to: &environment)
        }
        apply(
            config["desktopRuntimePreference"],
            key: "DORY_DESKTOP_VMM",
            to: &environment
        )
        apply(
            config["desktopGraphicsPreference"],
            key: "DORY_DESKTOP_GRAPHICS",
            to: &environment
        )
        return environment.sorted { $0.key < $1.key }.map { key, value in
            ["key": key, "value": value] as NSDictionary
        }
    }

    private static func apply(
        _ raw: Any?,
        key: String,
        to environment: inout [String: String]
    ) {
        guard let raw else { return }
        if raw is NSNull {
            environment.removeValue(forKey: key)
        } else if let value = raw as? String {
            environment[key] = value
        }
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        return value as? UInt64
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func transferOperationRow(
        operationID: String,
        machineID: String = "dev",
        phase: String
    ) -> NSDictionary {
        var row: [String: Any] = [
            "schema": UInt16(1),
            "operationID": operationID,
            "machineID": machineID,
            "phase": phase,
            "filesTotal": UInt64(phase == "completed" ? 1 : 0),
            "filesCompleted": UInt64(phase == "completed" ? 1 : 0),
            "bytesTotal": UInt64(phase == "completed" ? 5 : 0),
            "bytesCompleted": UInt64(phase == "completed" ? 5 : 0),
        ]
        if phase == "completed" {
            let destination = "/home/developer/Downloads/Dory Transfer " + operationID
            row["guestDestination"] = destination
            row["result"] = [
                "schema": UInt16(1),
                "transferID": operationID,
                "guestDestination": destination,
                "filesSent": UInt64(1),
                "bytesSent": UInt64(5),
            ] as NSDictionary
        }
        return row as NSDictionary
    }

    private static func guestExportOperationRow(
        operationID: String,
        machineID: String = "dev",
        phase: String
    ) -> NSDictionary {
        var row: [String: Any] = [
            "schema": UInt16(1),
            "operationID": operationID,
            "machineID": machineID,
            "phase": phase,
            "filesTotal": UInt64(phase == "completed" ? 1 : 0),
            "filesCompleted": UInt64(phase == "completed" ? 1 : 0),
            "bytesTotal": UInt64(phase == "completed" ? 12 : 0),
            "bytesCompleted": UInt64(phase == "completed" ? 12 : 0),
        ]
        if phase == "completed" {
            let root = DoryMachineFileTransferStager.defaultStagingDirectory
                .appendingPathComponent(
                    "export-\(getpid())-\(operationID)",
                    isDirectory: true
                ).path
            row["result"] = [
                "schema": UInt16(1),
                "exportID": operationID,
                "privateStagingRoot": root,
                "filesReceived": UInt64(1),
                "directoriesReceived": UInt64(1),
                "bytesReceived": UInt64(12),
            ] as NSDictionary
        }
        return row as NSDictionary
    }

    private static func execRow(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) -> NSDictionary {
        [
            "exitCode": exitCode,
            "stdout": stdout,
            "stderr": stderr,
            "timedOut": false,
            "stdoutTruncated": false,
            "stderrTruncated": false,
        ] as NSDictionary
    }

    static func machineEventBatchRow(sequence: UInt64 = 5) -> NSDictionary {
        [
            "schemaVersion": UInt16(1),
            "headSequence": sequence,
            "snapshotRequired": false,
            "events": [[
                "schemaVersion": UInt16(1),
                "sequence": sequence,
                "observedAtUnixMilliseconds": Int64(1_000),
                "machineID": "dev",
                "kind": "updated",
                "status": [
                    "schemaVersion": UInt16(1),
                    "machineID": "dev",
                    "configurationRevision": String(repeating: "a", count: 64),
                    "observedRevision": String(repeating: "b", count: 64),
                    "state": "running",
                    "hasFailure": false,
                    "memoryMB": UInt64(2_048),
                    "cpuCount": 2,
                    "displayMode": "headless",
                    "bootMode": "linux-kernel",
                    "installerMediaAttached": false,
                    "shareCount": 0,
                    "integrationHealth": "missing-tools",
                    "runtimeMode": "legacy-compatibility",
                    "virtualHardwareABIVersion": UInt16(1),
                ] as NSDictionary,
            ] as NSDictionary] as [NSDictionary],
        ]
    }

    static func importAssessmentRow() -> NSDictionary {
        [
            "schemaVersion": 1,
            "contentID": String(repeating: "a", count: 64),
            "sourceMachineID": "dev",
            "sourceSnapshotID": "imported",
            "architecture": "arm64",
            "bootMode": "linux-kernel",
            "diskSizeBytes": 4_096,
            "virtualHardwareABIVersion": 1,
            "sourceRuntimeMode": "legacy-compatibility",
            "portable": true,
            "disposition": "ready",
            "issues": [] as [String],
            "components": [] as [NSDictionary],
        ]
    }

    private static func snapshotRow(id: String, machineID: String, note: String, createdISO: String) -> NSDictionary {
        [
            "id": id,
            "machineID": machineID,
            "note": note,
            "createdISO": createdISO,
            "rootfsPath": "/tmp/\(machineID)-\(id).ext4",
            "sizeBytes": 1024,
            "kernelPath": "/tmp/kernel",
            "architecture": "arm64",
            "memoryMB": 2048,
            "cpuCount": 2,
        ] as NSDictionary
    }

    private static func backupStatusRow(
        machineID: String,
        frequency: String,
        keepLocal: Int,
        verifyEveryRuns: Int,
        successfulRuns: Int = 0,
        verified: Bool = false
    ) -> NSDictionary {
        var row: [String: Any] = [
            "machineID": machineID,
            "enabled": true,
            "frequency": frequency,
            "keepLocal": keepLocal,
            "verifyEveryRuns": verifyEveryRuns,
            "inProgress": false,
            "successfulRuns": successfulRuns,
            "consecutiveFailures": 0,
            "retainedSnapshots": successfulRuns,
            "retainedArchives": successfulRuns,
            "nextRunISO": "2026-07-08T00:00:00Z",
        ]
        if verified {
            row["lastAttemptISO"] = "2026-07-07T00:00:00Z"
            row["lastSuccessISO"] = "2026-07-07T00:00:00Z"
            row["lastVerificationISO"] = "2026-07-07T00:00:00Z"
            row["lastBootVerificationISO"] = "2026-07-07T00:00:00Z"
            row["lastSnapshotID"] = "scheduled-1"
            row["lastArchivePath"] = "/tmp/dev.dorymachine"
        }
        return row as NSDictionary
    }

    private static func domainRoute(_ value: Any) -> DorydDomainRoute? {
        guard let dictionary = value as? NSDictionary,
              let hostname = dictionary["hostname"] as? String,
              let address = dictionary["address"] as? String else {
            return nil
        }
        let port: UInt16
        if let number = dictionary["port"] as? NSNumber {
            port = number.uint16Value
        } else if let raw = dictionary["port"] as? UInt16 {
            port = raw
        } else {
            port = 80
        }
        let pathPrefix = dictionary["pathPrefix"] as? String ?? ""
        return DorydDomainRoute(hostname: hostname, address: address, port: port, pathPrefix: pathPrefix)
    }

    private static func dictionary(_ route: DorydDomainRoute) -> NSDictionary {
        var dictionary: [String: Any] = [
            "hostname": route.hostname,
            "address": route.address,
            "port": route.port,
        ]
        if !route.pathPrefix.isEmpty {
            dictionary["pathPrefix"] = route.pathPrefix
        }
        return dictionary as NSDictionary
    }
}

private extension NSDictionary {
    func adding(_ key: String, _ value: Any) -> NSDictionary {
        var copy = stringKeyedCopy
        copy[key] = value
        return copy as NSDictionary
    }

    func replacing(_ key: String, with value: Any) -> NSDictionary {
        adding(key, value)
    }

    func removing(_ key: String) -> NSDictionary {
        var copy = stringKeyedCopy
        copy.removeValue(forKey: key)
        return copy as NSDictionary
    }

    var stringKeyedCopy: [String: Any] {
        var copy: [String: Any] = [:]
        for (key, value) in self {
            if let key = key as? String {
                copy[key] = value
            }
        }
        return copy
    }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<80 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(condition())
}

private final class FakeDorydListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: FakeDorydService

    init(service: FakeDorydService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DorydControlXPC.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private final class HealthDiagnosticsCLIRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCommands: [[String]] = []

    var commands: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recordedCommands
    }

    func record(_ command: [String]) {
        lock.lock()
        recordedCommands.append(command)
        lock.unlock()
    }
}
