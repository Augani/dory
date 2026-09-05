import CryptoKit
import Darwin
import DoryOperations
import DoryVMContracts
@testable import DorydKit
import Foundation
import Testing

@Suite("Resolved machine plan")
struct DoryResolvedMachinePlanTests {
    @Test("persistence authority rejects missing, malformed and changed workspace roots")
    func exactPersistenceBinding() throws {
        for path in ["relative", "/", "/private/tmp/../other", "/private/tmp/", "/private/tmp\0bad"] {
            #expect(throws: DoryResolvedMachinePlanConstructionError.invalidPersistenceRoot) {
                _ = try DoryResolvedMachinePersistence(stateDirectory: path, machineID: "workspace-one")
            }
        }
        let plan = supportedPlan()
        var missing = plan
        missing.persistence = nil
        #expect(missing.validate().contains { $0.code == .invalidPersistenceBinding })
        for data in [
            Data("{\"workspaceRootSHA256\":\"bad\",\"layoutVersion\":1}".utf8),
            Data("{\"workspaceRootSHA256\":\"\(digest("a"))\",\"layoutVersion\":2}".utf8),
        ] {
            var malformed = plan
            malformed.persistence = try JSONDecoder().decode(DoryResolvedMachinePersistence.self, from: data)
            #expect(malformed.validate().contains { $0.code == .invalidPersistenceBinding })
        }
        var input = exactInput(for: plan)
        input.runtimeEvidence.persistence = try DoryResolvedMachinePersistence(
            stateDirectory: "/other/machines", machineID: plan.machineID
        )
        let result = DoryResolvedMachinePlanStartValidator.revalidate(plan, against: input)
        #expect(!result.mayStart)
        #expect(result.issues.contains { $0.code == .persistenceMismatch })
    }

    @Test("firmware URLs have one canonical plan digest across encoders and runtime identity")
    func canonicalPlanEncoding() throws {
        let plan = mutableARMVirtPlan()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let decoded = try JSONDecoder().decode(DoryResolvedMachinePlan.self, from: encoder.encode(plan))
        #expect(try plan.canonicalData() == decoded.canonicalData())
        #expect(try plan.canonicalSHA256() == decoded.canonicalSHA256())
        #expect(try plan.canonicalSHA256() == DoryMachineRuntimeIdentity.planSHA256(plan))
    }

    @Test("UEFI plans require exact firmware and reject changes during start revalidation")
    func exactFirmwareBinding() throws {
        let plan = mutableARMVirtPlan()
        #expect(plan.validate().isEmpty)
        #expect(try JSONDecoder().decode(
            DoryResolvedMachinePlan.self, from: JSONEncoder().encode(plan)
        ) == plan)
        var missing = plan
        missing.firmware = nil
        #expect(missing.validate().contains { $0.code == .invalidFirmwareBinding })
        var wrongPlatform = plan
        wrongPlatform.firmware = try resolvedFirmwareTestArtifacts(platform: .pcV1).manifest
        #expect(wrongPlatform.validate().contains { $0.code == .invalidFirmwareBinding })
        var unexpected = supportedPlan()
        unexpected.firmware = plan.firmware
        #expect(unexpected.validate().contains { $0.code == .invalidFirmwareBinding })
        var input = exactInput(for: plan)
        input.runtimeEvidence.firmware = try resolvedFirmwareTestArtifacts(fill: 0xb6).manifest
        let validation = DoryResolvedMachinePlanStartValidator.revalidate(plan, against: input)
        #expect(!validation.mayStart)
        #expect(validation.issues.contains { $0.code == .firmwareMismatch })
    }

    @Test("runtime identity shares immutable plan storage while copies remain independent")
    func runtimeIdentityValueSemantics() throws {
        let plan = supportedPlan()
        let original = try DoryMachineRuntimeIdentity(
            resolvedPlan: plan, planSHA256: DoryMachineRuntimeIdentity.planSHA256(plan)
        )
        var edited = original
        edited.resolvedPlan?.planRevision += 1
        #expect(original.resolvedPlan == plan)
        #expect(edited.resolvedPlan?.planRevision == plan.planRevision + 1)
        let data = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["planStorage"] == nil)
        #expect(object["resolvedPlan"] != nil)
        #expect(try JSONDecoder().decode(DoryMachineRuntimeIdentity.self, from: data) == original)
    }

    @Test("schema six rejects missing and inconsistent architecture or resource authority")
    func exactArchitectureAndResources() throws {
        let mutations: [(inout DoryResolvedMachinePlan) -> Void] = [
            { $0.architecture = nil },
            { $0.platform = nil },
            { $0.resources = nil },
            { $0.architecture?.hostArchitecture = .x86_64 },
            { $0.architecture?.cpuProfile = .compatibleX8664V1 },
            { $0.architecture?.machineABI = .pcV1 },
            { $0.architecture?.executionTier = .translated },
            { $0.architecture?.productCell = .macOSARM64VZMac },
            { $0.architecture?.detectedMediaArchitecture = .arm64 },
            { $0.resources = DoryVMResourceRequest(virtualCPUCount: 99, memoryBytes: 1, diskBytes: 1) },
        ]
        for mutate in mutations {
            var plan = supportedPlan()
            mutate(&plan)
            let decoded = try JSONDecoder().decode(
                DoryResolvedMachinePlan.self, from: JSONEncoder().encode(plan)
            )
            #expect(!decoded.validate().isEmpty)
            #expect(!DoryResolvedMachinePlanStartValidator.revalidate(
                decoded, against: exactInput(for: decoded)
            ).mayStart)
        }
    }

    @Test("current exact plan validates and round trips")
    func roundTrip() throws {
        let plan = supportedPlan()
        #expect(plan.validate().isEmpty)
        let encoded = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(DoryResolvedMachinePlan.self, from: encoded) == plan)
    }

    @Test("installed native Mac baseline requires one mutable disk used for boot and storage")
    func installedNativeMacBaselineRequiresExactMutableSystemDisk() throws {
        let plan = installedNativeMacPlan()
        #expect(plan.validate().isEmpty)
        #expect(plan.usesPreparedNativeMacOSBaseline)

        var missingBootUsage = plan
        missingBootUsage.launchArtifacts[0].usages.removeAll { $0.kind == .boot }
        #expect(!missingBootUsage.usesPreparedNativeMacOSBaseline)
        #expect(!missingBootUsage.validate().isEmpty)

    }

    @Test("Linux plans never admit QEMU/HVF as a runnable runtime")
    func linuxQEMUIsNotRunnable() {
        var plan = mutableARMVirtPlan()
        plan.backend = .qemuHypervisorFramework

        #expect(plan.validate().contains {
            $0.code == .unsupportedRuntimeCombination
                && $0.field == "bootMedia.media.kind"
        })
    }

    @Test("x86_64 Linux plans are invalid even on the VZ backend")
    func x86LinuxGuestIsNotPersistable() {
        var plan = mutableARMVirtPlan()
        plan.backend = .appleVirtualizationFramework
        plan.guest.architecture = .x86_64

        #expect(plan.validate().contains {
            $0.code == .unsupportedRuntimeCombination
                && $0.field == "guest.architecture"
        })
    }

    @Test("golden schema v1 decodes only as a non-runnable migration")
    func goldenV1Migration() throws {
        let migrated = try JSONDecoder().decode(
            DoryResolvedMachinePlan.self,
            from: Data(Self.goldenV1Plan.utf8)
        )
        #expect(migrated.schemaVersion == DoryResolvedMachinePlan.currentSchemaVersion)
        #expect(migrated.sourceSchemaVersion == 1)
        #expect(migrated.migrationDisposition == .requiresReplanning)
        #expect(migrated.backendRuntimeBuildIdentifier == "raw-runtime-1")
        #expect(migrated.components.map(\.componentIdentifier) == ["dory-hv", "renderer"])
        #expect(migrated.validate().contains { $0.code == .legacyPlanRequiresReplanning })

        let input = DoryResolvedMachinePlanStartRevalidationInput(
            machineID: migrated.machineID,
            expectedPlanRevision: migrated.planRevision,
            currentDefinitionRevision: migrated.definitionRevision,
            currentDefinitionSHA256: digest("1"),
            runtimeEvidence: DoryResolvedMachineRuntimeEvidence(plan: migrated)
        )
        let result = DoryResolvedMachinePlanStartValidator.revalidate(migrated, against: input)
        #expect(!result.mayStart)
        #expect(result.issues.contains { $0.code == .storedPlanInvalid })
    }

    @Test("schema v2 without launch-artifact evidence requires replanning")
    func schemaV2LaunchArtifactMigration() throws {
        let encoded = try JSONEncoder().encode(supportedPlan())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["schemaVersion"] = 2
        object["sourceSchemaVersion"] = 2
        object.removeValue(forKey: "launchArtifacts")

        let migrated = try JSONDecoder().decode(
            DoryResolvedMachinePlan.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
        #expect(migrated.schemaVersion == DoryResolvedMachinePlan.currentSchemaVersion)
        #expect(migrated.sourceSchemaVersion == 2)
        #expect(migrated.migrationDisposition == .requiresReplanning)
        #expect(migrated.launchArtifacts.isEmpty)
        #expect(migrated.validate().contains { $0.code == .legacyPlanRequiresReplanning })
        #expect(migrated.validate().contains { $0.code == .invalidLaunchArtifactEvidence })
    }

    @Test("schema v3 without port-forward authority requires replanning")
    func schemaV3PortForwardMigration() throws {
        let encoded = try JSONEncoder().encode(supportedPlan())
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["schemaVersion"] = 3
        object["sourceSchemaVersion"] = 3
        object.removeValue(forKey: "portForwards")

        let migrated = try JSONDecoder().decode(
            DoryResolvedMachinePlan.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
        #expect(migrated.sourceSchemaVersion == 3)
        #expect(migrated.migrationDisposition == .requiresReplanning)
        #expect(migrated.portForwards.isEmpty)
        #expect(migrated.validate().contains { $0.code == .legacyPlanRequiresReplanning })
    }

    @Test("exact fresh evidence authorizes start")
    func exactStartEvidence() {
        let plan = supportedPlan()
        let result = DoryResolvedMachinePlanStartValidator.revalidate(
            plan,
            against: exactInput(for: plan)
        )
        #expect(result.mayStart)
        #expect(result.issues.isEmpty)
    }

    @Test("definition and plan revisions are exact start gates")
    func revisionMismatch() {
        let plan = supportedPlan()
        var input = exactInput(for: plan)
        input.expectedPlanRevision += 1
        input.currentDefinitionRevision += 1
        input.currentDefinitionSHA256 = digest("9")

        let codes = Set(DoryResolvedMachinePlanStartValidator.revalidate(
            plan,
            against: input
        ).issues.map(\.code))
        #expect(codes.contains(.planRevisionMismatch))
        #expect(codes.contains(.definitionRevisionMismatch))
        #expect(codes.contains(.definitionDigestMismatch))
    }

    @Test("backend runtime component host and admission evidence mismatches are explicit")
    func runtimeEvidenceMismatch() {
        let plan = supportedPlan()
        var input = exactInput(for: plan)
        input.runtimeEvidence.backendRuntimeBuildIdentifier = "raw-runtime-2"
        input.runtimeEvidence.components[0].artifactSHA256 = digest("9")
        input.runtimeEvidence.hostQualification?.hostOperatingSystemBuild = "26B999"
        input.runtimeEvidence.resourceAdmission?.existingMemoryCommitmentBytes += 1

        let codes = Set(DoryResolvedMachinePlanStartValidator.revalidate(
            plan,
            against: input
        ).issues.map(\.code))
        #expect(codes.contains(.backendRuntimeBuildMismatch))
        #expect(codes.contains(.componentEvidenceMismatch))
        #expect(codes.contains(.hostQualificationMismatch))
        #expect(codes.contains(.resourceAdmissionMismatch))
    }

    @Test("NIC identity and MTU are exact start gates")
    func networkInterfaceEvidenceMismatch() {
        var plan = supportedPlan()
        plan.devices.networkInterface = .stable(machineID: plan.machineID)
        var input = exactInput(for: plan)
        input.runtimeEvidence.devices.networkInterface = .stable(machineID: "substituted-machine")

        let result = DoryResolvedMachinePlanStartValidator.revalidate(plan, against: input)
        #expect(!result.mayStart)
        #expect(result.issues.contains { $0.code == .deviceContractMismatch })
    }

    @Test("connected VZ plans enforce the file-handle MTU floor without rejecting detached NICs")
    func vzFileHandleMTUContract() {
        func bindNetwork(
            _ plan: inout DoryResolvedMachinePlan,
            attachment: DoryVirtualMachineNetworkAttachmentMode,
            mtu: UInt16
        ) {
            let networkInterface = DoryVirtualMachineNetworkInterfaceCapabilityRequest(
                macAddress: "02:11:22:33:44:55",
                maximumTransmissionUnit: mtu
            )
            plan.devices.networkAttachment = attachment
            plan.devices.networkInterface = networkInterface
            plan.selectionEvidence?.plannerRequest.devices = plan.devices
            plan.qualificationEvidence.runtime?.devices = plan.devices
        }

        var connectedLow = mutableARMVirtPlan()
        connectedLow.backend = .appleVirtualizationFramework
        connectedLow.armVirtTopology = nil
        bindNetwork(&connectedLow, attachment: .sharedNAT, mtu: 1_280)
        #expect(connectedLow.validate().contains {
            $0.code == .unsupportedRuntimeCombination
                && $0.field == "devices.networkInterface.maximumTransmissionUnit"
        })

        var hostOnlyLow = mutableARMVirtPlan()
        hostOnlyLow.backend = .appleVirtualizationFramework
        hostOnlyLow.armVirtTopology = nil
        bindNetwork(&hostOnlyLow, attachment: .isolated, mtu: 1_280)
        #expect(hostOnlyLow.validate().contains {
            $0.code == .unsupportedRuntimeCombination
        })

        var connected = mutableARMVirtPlan()
        connected.backend = .appleVirtualizationFramework
        connected.armVirtTopology = nil
        bindNetwork(&connected, attachment: .sharedNAT, mtu: 1_500)
        #expect(connected.validate().contains { $0.code == .platformCompositionMismatch })

        var disconnected = mutableARMVirtPlan()
        disconnected.backend = .appleVirtualizationFramework
        disconnected.armVirtTopology = nil
        bindNetwork(&disconnected, attachment: .disconnected, mtu: 1_280)
        #expect(disconnected.validate().contains { $0.code == .platformCompositionMismatch })
    }

    @Test("port forwards are exact start evidence and fail closed structurally")
    func portForwardEvidenceMismatch() {
        let plan = supportedPlan()
        #expect(plan.validate().isEmpty)
        var input = exactInput(for: plan)
        input.runtimeEvidence.portForwards[0].guestPort = 2_222
        let mismatch = DoryResolvedMachinePlanStartValidator.revalidate(plan, against: input)
        #expect(!mismatch.mayStart)
        #expect(mismatch.issues.contains { $0.code == .portForwardContractMismatch })

        var invalid = plan
        invalid.portForwards.append(DoryVMPortForward(
            id: "duplicate-binding",
            hostPort: 2_222,
            guestPort: 220
        ))
        #expect(invalid.validate().contains { $0.code == .invalidPortForwardContract })

        invalid = plan
        invalid.portForwards[0].hostPort = 443
        #expect(invalid.validate().contains { $0.code == .invalidPortForwardContract })
    }

    @Test("immutable media and qualification evidence mismatches are exact")
    func immutableEvidenceMismatch() {
        let plan = supportedPlan()
        var input = exactInput(for: plan)
        input.runtimeEvidence.bootMedia.media.artifactSHA256 = digest("9")
        input.runtimeEvidence.qualificationEvidence.runtime?.qualificationReportSHA256 = digest("8")

        let codes = Set(DoryResolvedMachinePlanStartValidator.revalidate(
            plan,
            against: input
        ).issues.map(\.code))
        #expect(codes.contains(.bootMediaEvidenceMismatch))
        #expect(codes.contains(.qualificationEvidenceMismatch))
    }

    @Test("mutable disk provenance revision mismatch rejects start")
    func mutableProvenanceMismatch() {
        let plan = mutableARMVirtPlan()
        #expect(plan.validate().isEmpty)
        var input = exactInput(for: plan)
        input.runtimeEvidence.bootMedia.media.mutableProvenance?.revision += 1

        let result = DoryResolvedMachinePlanStartValidator.revalidate(plan, against: input)
        #expect(!result.mayStart)
        #expect(result.issues.contains { $0.code == .bootMediaEvidenceMismatch })
    }

    @Test("portable installed EFI disk needs provenance but no distro qualification")
    func portableInstalledEFIDiskPlan() throws {
        var plan = mutableARMVirtPlan()
        plan.qualificationEvidence = DoryResolvedMachineQualificationEvidence()
        plan.hostQualification = nil

        #expect(plan.validate().isEmpty)
        #expect(DoryResolvedMachinePlanStartValidator.revalidate(
            plan,
            against: exactInput(for: plan)
        ).mayStart)
        let roundTrip = try JSONDecoder().decode(
            DoryResolvedMachinePlan.self,
            from: JSONEncoder().encode(plan)
        )
        #expect(roundTrip == plan)

        var accelerated = plan
        accelerated.graphics = .hostAcceleratedDisplay
        accelerated.selectionEvidence?.plannerRequest.acceptableGraphics = [
            .hostAcceleratedDisplay,
        ]
        #expect(accelerated.validate().contains {
            $0.code == .missingRuntimeQualification
        })
        #expect(accelerated.validate().contains {
            $0.code == .invalidHostQualification
        })
    }

    @Test("support tier is revalidated and unsupported plans never validate")
    func supportTierSafety() {
        let plan = supportedPlan()
        var input = exactInput(for: plan)
        input.runtimeEvidence.supportTier = .experimental
        #expect(DoryResolvedMachinePlanStartValidator.revalidate(
            plan,
            against: input
        ).issues.contains { $0.code == .supportTierMismatch })

        var unsupported = plan
        unsupported.supportTier = .unsupported
        #expect(unsupported.validate().contains { $0.code == .unsupportedSupportTier })
        #expect(!DoryResolvedMachinePlanStartValidator.revalidate(
            unsupported,
            against: exactInput(for: unsupported)
        ).mayStart)
    }

    @Test("experimental plan requires exact persisted authorization")
    func experimentalAuthorization() {
        var plan = supportedPlan()
        plan.supportTier = .experimental
        plan.qualificationEvidence.runtime = nil
        plan.selectionEvidence?.plannerRequest.allowsExperimentalBackends = true
        #expect(plan.validate().contains { $0.code == .missingExperimentalAuthorization })

        plan.experimentalAuthorization = DoryResolvedExperimentalSupportAuthorization(
            authorizationIdentity: "experimental-consent-1",
            definitionRevision: plan.definitionRevision,
            backend: plan.backend,
            authorizedAtUnixMilliseconds: plan.createdAtUnixMilliseconds
        )
        #expect(plan.validate().isEmpty)
        var input = exactInput(for: plan)
        input.runtimeEvidence.experimentalAuthorization?.authorizationIdentity = "different-consent"
        #expect(DoryResolvedMachinePlanStartValidator.revalidate(
            plan,
            against: input
        ).issues.contains { $0.code == .experimentalAuthorizationMismatch })
    }

    @Test("selected capability construction rejects descriptor and availability substitution")
    func selectedCapabilityConstruction() {
        let plan = supportedPlan()
        let capability = capabilityDescriptor(from: plan, availability: DoryCapabilityAvailability(
            supportTier: .supported,
            state: .available
        ))
        let plannerRequest = backendPlannerRequest(from: plan)
        let plannerResult = DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: capability,
            evaluatedDescriptors: [capability],
            failure: nil
        )

        #expect(throws: DoryResolvedMachinePlanConstructionError.backendDescriptorMismatch) {
            _ = try DoryResolvedMachinePlan(
                machineID: plan.machineID,
                definitionRevision: plan.definitionRevision,
                definitionSHA256: plan.definitionSHA256!,
                planRevision: 1,
                createdAtUnixMilliseconds: plan.createdAtUnixMilliseconds,
                updatedAtUnixMilliseconds: plan.updatedAtUnixMilliseconds,
                backendDescriptor: VirtualizationFrameworkLinuxMachineBackend.backendDescriptor,
                backendRuntimeBuildIdentifier: plan.backendRuntimeBuildIdentifier,
                resolverReference: plan.bootMedia.resolverReference,
                launchArtifacts: plan.launchArtifacts,
                components: plan.components,
                resourceAdmission: plan.resourceAdmission!,
                hostQualification: plan.hostQualification!,
                plannerRequest: plannerRequest,
                plannerResult: plannerResult
            )
        }

        let unavailable = capabilityDescriptor(from: plan, availability: DoryCapabilityAvailability(
            supportTier: .unsupported,
            state: .unavailable
        ))
        let unavailableResult = DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: unavailable,
            evaluatedDescriptors: [unavailable],
            failure: nil
        )
        #expect(throws: DoryResolvedMachinePlanConstructionError.capabilityDescriptorInvalid) {
            _ = try DoryResolvedMachinePlan(
                machineID: plan.machineID,
                definitionRevision: plan.definitionRevision,
                definitionSHA256: plan.definitionSHA256!,
                planRevision: 1,
                createdAtUnixMilliseconds: plan.createdAtUnixMilliseconds,
                updatedAtUnixMilliseconds: plan.updatedAtUnixMilliseconds,
                backendDescriptor: RawHVLinuxMachineBackend.backendDescriptor,
                backendRuntimeBuildIdentifier: plan.backendRuntimeBuildIdentifier,
                resolverReference: plan.bootMedia.resolverReference,
                launchArtifacts: plan.launchArtifacts,
                components: plan.components,
                resourceAdmission: plan.resourceAdmission!,
                hostQualification: plan.hostQualification!,
                plannerRequest: plannerRequest,
                plannerResult: unavailableResult
            )
        }
    }

    @Test("internal evidence bindings reject mismatched host runtime and resource overcommit")
    func structuralEvidenceValidation() {
        var hostMismatch = supportedPlan()
        hostMismatch.hostQualification?.backendRuntimeBuildIdentifier = "other-runtime"
        #expect(hostMismatch.validate().contains { $0.code == .invalidHostQualification })

        var overcommitted = supportedPlan()
        overcommitted.resourceAdmission?.existingMemoryCommitmentBytes = UInt64.max
        #expect(overcommitted.validate().contains { $0.code == .invalidResourceAdmission })

        var qualificationMismatch = supportedPlan()
        qualificationMismatch.qualificationEvidence.runtime?.backendRuntimeBuildID = "other-runtime"
        #expect(qualificationMismatch.validate().contains { $0.code == .runtimeQualificationMismatch })
    }

    @Test("preferred unavailable candidate persists an approved named fallback")
    func approvedFallback() throws {
        let plan = try fallbackARMVirtPlan(policy: .preferred, includeAuthorization: true)
        let selection = try #require(plan.selectionEvidence)
        #expect(selection.disposition == .approvedFallback)
        #expect(selection.selectedEvaluationIndex == 1)
        #expect(selection.rejectedCandidates.count == 1)
        #expect(selection.rejectedCandidates[0].backend == .appleVirtualizationFramework)
        #expect(selection.rejectedCandidates[0].availability.reason?.code
            == .bootMediaDoesNotSupportBackend)
        #expect(selection.fallbackAuthorization?.fromBackend == .appleVirtualizationFramework)
        #expect(selection.fallbackAuthorization?.toBackend == .doryHypervisor)
        #expect(plan.validate().isEmpty)
        #expect(DoryResolvedMachinePlanStartValidator.revalidate(
            plan,
            against: exactInput(for: plan)
        ).mayStart)

        let roundTrip = try JSONDecoder().decode(
            DoryResolvedMachinePlan.self,
            from: JSONEncoder().encode(plan)
        )
        #expect(roundTrip.selectionEvidence == selection)
    }

    @Test("preferred fallback requires approval and required alternatives do not")
    func fallbackPolicySafety() throws {
        #expect(throws: DoryResolvedMachinePlanConstructionError.fallbackAuthorizationRequired) {
            _ = try fallbackARMVirtPlan(policy: .preferred, includeAuthorization: false)
        }

        let requiredAlternative = try fallbackARMVirtPlan(
            policy: .required,
            includeAuthorization: false
        )
        #expect(requiredAlternative.selectionEvidence?.disposition == .explicitAlternative)
        #expect(requiredAlternative.selectionEvidence?.fallbackAuthorization == nil)
        #expect(requiredAlternative.validate().isEmpty)

        #expect(throws: DoryResolvedMachinePlanConstructionError.fallbackAuthorizationInvalid) {
            _ = try fallbackARMVirtPlan(policy: .required, includeAuthorization: true)
        }
    }

    @Test("required backend still requires explicit graphics recovery authorization")
    func requiredGraphicsAlternative() throws {
        var plan = supportedPlan()
        var request = DoryVirtualMachineBackendPlanRequest(
            guest: plan.guest,
            bootMedia: plan.bootMedia.media,
            acceptableGraphics: [.hardwareAccelerated3D, .hostAcceleratedDisplay],
            devices: plan.devices,
            virtualHardwareABIVersion: plan.virtualHardwareABIVersion,
            backendPreferences: [.doryHypervisor],
            backendPreferencePolicy: .required
        )
        let rejected = DoryVirtualMachineCapabilityDescriptor(
            evaluatorVersion: DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
            request: DoryVirtualMachineCapabilityRequest(
                guest: plan.guest,
                bootMedia: plan.bootMedia.media,
                backend: .doryHypervisor,
                graphics: .hardwareAccelerated3D,
                devices: plan.devices,
                virtualHardwareABIVersion: plan.virtualHardwareABIVersion
            ),
            availability: DoryCapabilityAvailability(
                supportTier: .unsupported,
                state: .unavailable,
                reason: DoryCapabilityReason(
                    code: .acceleratedRendererUnavailable,
                    message: "The requested renderer is unavailable."
                )
            )
        )
        let selected = capabilityDescriptor(
            from: plan,
            availability: DoryCapabilityAvailability(
                supportTier: .supported,
                state: .available
            )
        )
        let result = DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: selected, evaluatedDescriptors: [rejected, selected], failure: nil
        )
        #expect(throws: DoryResolvedMachinePlanConstructionError.fallbackDisallowed) {
            _ = try DoryResolvedMachineBackendSelectionEvidence.resolving(
                request: request, result: result, definitionRevision: plan.definitionRevision
            )
        }
        request.graphicsRecovery = true
        #expect(throws: DoryResolvedMachinePlanConstructionError.fallbackAuthorizationRequired) {
            _ = try DoryResolvedMachineBackendSelectionEvidence.resolving(
                request: request, result: result, definitionRevision: plan.definitionRevision
            )
        }
        plan.selectionEvidence = try DoryResolvedMachineBackendSelectionEvidence.resolving(
            request: request, result: result, definitionRevision: plan.definitionRevision,
            fallbackAuthorization: DoryResolvedMachineFallbackAuthorization(
                authorizationIdentity: "explicit-graphics-recovery",
                definitionRevision: plan.definitionRevision,
                fromBackend: plan.backend, fromGraphics: .hardwareAccelerated3D,
                toBackend: plan.backend, toGraphics: plan.graphics,
                authorizedAtUnixMilliseconds: plan.createdAtUnixMilliseconds
            )
        )
        #expect(plan.selectionEvidence?.disposition == .approvedFallback)
        #expect(plan.validate().isEmpty)
        plan.selectionEvidence?.plannerRequest.graphicsRecovery = false
        #expect(plan.validate().contains { $0.code == .fallbackDisallowed })
    }

    @Test("required policy rejects a backend the request did not list")
    func requiredImplicitBackendRejection() {
        let plan = mutableARMVirtPlan()
        let request = DoryVirtualMachineBackendPlanRequest(
            guest: plan.guest,
            bootMedia: plan.bootMedia.media,
            acceptableGraphics: [plan.graphics],
            devices: plan.devices,
            virtualHardwareABIVersion: plan.virtualHardwareABIVersion,
            backendPreferences: [.appleVirtualizationFramework],
            backendPreferencePolicy: .required
        )
        let selected = capabilityDescriptor(
            from: plan,
            availability: DoryCapabilityAvailability(
                supportTier: .supported,
                state: .available
            )
        )
        let result = DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: selected,
            evaluatedDescriptors: [selected],
            failure: nil
        )

        #expect(throws: DoryResolvedMachinePlanConstructionError.plannerResultInvalid) {
            _ = try DoryResolvedMachineBackendSelectionEvidence.resolving(
                request: request,
                result: result,
                definitionRevision: plan.definitionRevision
            )
        }
    }

    @Test("missing or changed fallback evidence rejects start")
    func fallbackTamperSafety() throws {
        let plan = try fallbackARMVirtPlan(policy: .preferred, includeAuthorization: true)
        var missing = plan
        missing.selectionEvidence?.fallbackAuthorization = nil
        #expect(missing.validate().contains { $0.code == .missingFallbackAuthorization })
        #expect(!DoryResolvedMachinePlanStartValidator.revalidate(
            missing,
            against: exactInput(for: missing)
        ).mayStart)

        var input = exactInput(for: plan)
        input.runtimeEvidence.selectionEvidence?.fallbackAuthorization?.authorizationIdentity
            = "different-fallback-consent"
        #expect(DoryResolvedMachinePlanStartValidator.revalidate(
            plan,
            against: input
        ).issues.contains { $0.code == .selectionEvidenceMismatch })
    }

    private func exactInput(
        for plan: DoryResolvedMachinePlan
    ) -> DoryResolvedMachinePlanStartRevalidationInput {
        DoryResolvedMachinePlanStartRevalidationInput(
            machineID: plan.machineID,
            expectedPlanRevision: plan.planRevision,
            currentDefinitionRevision: plan.definitionRevision,
            currentDefinitionSHA256: plan.definitionSHA256 ?? "",
            runtimeEvidence: DoryResolvedMachineRuntimeEvidence(plan: plan)
        )
    }

    private func capabilityDescriptor(
        from plan: DoryResolvedMachinePlan,
        availability: DoryCapabilityAvailability
    ) -> DoryVirtualMachineCapabilityDescriptor {
        DoryVirtualMachineCapabilityDescriptor(
            evaluatorVersion: DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
            request: DoryVirtualMachineCapabilityRequest(
                guest: plan.guest,
                bootMedia: plan.bootMedia.media,
                backend: plan.backend,
                graphics: plan.graphics,
                devices: plan.devices,
                virtualHardwareABIVersion: plan.virtualHardwareABIVersion
            ),
            availability: availability,
            resolvedDevices: availability.isUsable ? plan.devices : nil,
            graphicsQualificationEvidence: plan.qualificationEvidence.graphics,
            bootMediaInspectionEvidence: plan.bootMedia.inspectionEvidence,
            mutableBootMediaProvenanceEvidence: plan.bootMedia.mutableProvenanceEvidence,
            runtimeQualificationEvidence: plan.qualificationEvidence.runtime
        )
    }

    private func fallbackARMVirtPlan(
        policy: DoryVirtualMachineBackendPreferencePolicy,
        includeAuthorization: Bool
    ) throws -> DoryResolvedMachinePlan {
        var plan = mutableARMVirtPlan()
        let request = DoryVirtualMachineBackendPlanRequest(
            guest: plan.guest,
            bootMedia: plan.bootMedia.media,
            acceptableGraphics: [plan.graphics],
            devices: plan.devices,
            virtualHardwareABIVersion: plan.virtualHardwareABIVersion,
            backendPreferences: [.appleVirtualizationFramework, .doryHypervisor],
            backendPreferencePolicy: policy
        )
        let rejectedRequest = DoryVirtualMachineCapabilityRequest(
            guest: plan.guest,
            bootMedia: plan.bootMedia.media,
            backend: .appleVirtualizationFramework,
            graphics: plan.graphics,
            devices: plan.devices,
            virtualHardwareABIVersion: plan.virtualHardwareABIVersion
        )
        let rejected = DoryVirtualMachineCapabilityDescriptor(
            evaluatorVersion: DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
            request: rejectedRequest,
            availability: DoryCapabilityAvailability(
                supportTier: .unsupported,
                state: .unavailable,
                reason: DoryCapabilityReason(
                    code: .bootMediaDoesNotSupportBackend,
                    message: "The preferred backend cannot boot this media."
                )
            )
        )
        let selected = capabilityDescriptor(
            from: plan,
            availability: DoryCapabilityAvailability(
                supportTier: .supported,
                state: .available
            )
        )
        let result = DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: selected,
            evaluatedDescriptors: [rejected, selected],
            failure: nil
        )
        let authorization = includeAuthorization
            ? DoryResolvedMachineFallbackAuthorization(
                authorizationIdentity: "fallback-consent-1",
                definitionRevision: plan.definitionRevision,
                fromBackend: .appleVirtualizationFramework,
                fromGraphics: plan.graphics,
                toBackend: .doryHypervisor,
                toGraphics: plan.graphics,
                authorizedAtUnixMilliseconds: plan.createdAtUnixMilliseconds
            )
            : nil
        plan.selectionEvidence = try DoryResolvedMachineBackendSelectionEvidence.resolving(
            request: request,
            result: result,
            definitionRevision: plan.definitionRevision,
            fallbackAuthorization: authorization
        )
        return plan
    }

    fileprivate static let goldenV1Plan = """
    {
      "schemaVersion": 1,
      "machineID": "workspace-one",
      "definitionRevision": 3,
      "planRevision": 4,
      "createdAtUnixMilliseconds": 1700000000000,
      "updatedAtUnixMilliseconds": 1700000000100,
      "guest": {"family": "linux", "architecture": "arm64"},
      "backend": "dory-hypervisor",
      "backendRuntimeBuildID": "raw-runtime-1",
      "virtualHardwareABIVersion": 1,
      "bootMedia": {
        "kind": "installed-linux-boot-bundle",
        "source": "dory-bundled",
        "artifactSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
      "componentDigests": {
        "renderer": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        "dory-hv": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      },
      "devices": {
        "networkAttachment": "shared-nat",
        "audioInput": false,
        "audioOutput": false,
        "keyboard": false,
        "pointer": false,
        "directorySharing": false,
        "clipboard": false,
        "clockSynchronization": false,
        "dynamicDisplay": false,
        "gracefulShutdown": false
      },
      "graphics": "host-accelerated-display"
    }
    """
}

@Suite("Resolved machine plan repository")
struct DoryResolvedMachinePlanRepositoryTests {
    @Test("create read replace uses owner-only crash-safe optimistic revisions")
    func optimisticLifecycle() throws {
        try withRepository { repository, root in
            let initial = mutableARMVirtPlan()
            try repository.create(initial)
            #expect(try repository.read(id: initial.machineID) == initial)

            let recordPath = root + "/" + initial.machineID + "/"
                + DoryResolvedMachinePlanRepository.recordFileName
            var info = stat()
            #expect(lstat(recordPath, &info) == 0)
            #expect((info.st_mode & 0o777) == 0o600)
            #expect(info.st_nlink == 1)

            var replacement = initial
            replacement.planRevision = 2
            replacement.updatedAtUnixMilliseconds += 1
            try repository.replace(replacement, expectedPlanRevision: 1)
            #expect(try repository.read(id: initial.machineID) == replacement)
            #expect(throws: DoryResolvedMachinePlanRepositoryError.stalePlanRevision(
                expected: 1,
                actual: 2
            )) {
                try repository.replace(replacement, expectedPlanRevision: 1)
            }

            var skipped = replacement
            skipped.planRevision = 4
            #expect(throws: DoryResolvedMachinePlanRepositoryError.invalidPlanRevision(
                expected: 3,
                actual: 4
            )) {
                try repository.replace(skipped, expectedPlanRevision: 2)
            }
        }
    }

    @Test("record integrity digest rejects edited plan bytes")
    func tamperedRecord() throws {
        try withRepository { repository, root in
            let plan = mutableARMVirtPlan()
            try repository.create(plan)
            let path = root + "/" + plan.machineID + "/"
                + DoryResolvedMachinePlanRepository.recordFileName
            var text = try String(contentsOfFile: path, encoding: .utf8)
            text = text.replacingOccurrences(of: "raw-runtime-1", with: "raw-runtime-2")
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            _ = chmod(path, mode_t(0o600))
            #expect(throws: DoryResolvedMachinePlanRepositoryError.invalidRecord(path)) {
                _ = try repository.read(id: plan.machineID)
            }
        }
    }

    @Test("current repository records use one compact canonical JSON representation")
    func canonicalCurrentRecord() throws {
        try withRepository { repository, root in
            let plan = mutableARMVirtPlan()
            try repository.create(plan)
            let path = repositoryRecordPath(root: root, machineID: plan.machineID)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let rootObject = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let planObject = try #require(rootObject["plan"] as? [String: Any])
            let canonicalPlan = try repositoryCanonicalJSON(planObject)

            #expect(data == (try repositoryCanonicalJSON(rootObject)))
            #expect(
                (rootObject["schemaVersion"] as? NSNumber)?.uint16Value
                    == DoryResolvedMachinePlanRepositoryRecord.currentSchemaVersion
            )
            #expect(rootObject["planSHA256"] as? String == repositorySHA256(canonicalPlan))
        }
    }

    @Test("current records reject equivalent noncanonical lexical forms and key ordering")
    func noncanonicalCurrentRecord() throws {
        try withRepository { repository, root in
            let plan = mutableARMVirtPlan()
            try repository.create(plan)
            let path = repositoryRecordPath(root: root, machineID: plan.machineID)
            let original = try Data(contentsOf: URL(fileURLWithPath: path))
            let originalText = try #require(String(data: original, encoding: .utf8))

            let fractionalRevision = originalText.replacingOccurrences(
                of: "\"planRevision\":1",
                with: "\"planRevision\":1.0"
            )
            #expect(fractionalRevision != originalText)
            try overwriteRepositoryRecord(Data(fractionalRevision.utf8), at: path)
            #expect(throws: DoryResolvedMachinePlanRepositoryError.invalidRecord(path)) {
                _ = try repository.read(id: plan.machineID)
            }

            let rootObject = try #require(
                JSONSerialization.jsonObject(with: original) as? [String: Any]
            )
            let planObject = try #require(rootObject["plan"] as? [String: Any])
            let canonicalPlan = try repositoryCanonicalJSON(planObject)
            let planText = try #require(String(data: canonicalPlan, encoding: .utf8))
            let digest = try #require(rootObject["planSHA256"] as? String)
            let reordered = Data(
                "{\"schemaVersion\":3,\"planSHA256\":\"\(digest)\",\"plan\":\(planText)}".utf8
            )
            try overwriteRepositoryRecord(reordered, at: path)
            #expect(throws: DoryResolvedMachinePlanRepositoryError.invalidRecord(path)) {
                _ = try repository.read(id: plan.machineID)
            }
        }
    }

    @Test("record and nested plan authority reject unknown fields even with a valid digest")
    func unknownAuthorityFields() throws {
        try withRepository { repository, root in
            let plan = mutableARMVirtPlan()
            try repository.create(plan)
            let path = repositoryRecordPath(root: root, machineID: plan.machineID)
            let original = try Data(contentsOf: URL(fileURLWithPath: path))
            let originalRoot = try #require(
                JSONSerialization.jsonObject(with: original) as? [String: Any]
            )

            var unknownRecord = originalRoot
            unknownRecord["futureRecordAuthority"] = true
            try overwriteRepositoryRecord(
                try repositoryCanonicalJSON(unknownRecord),
                at: path
            )
            #expect(throws: DoryResolvedMachinePlanRepositoryError.invalidRecord(path)) {
                _ = try repository.read(id: plan.machineID)
            }

            var unknownPlan = try #require(originalRoot["plan"] as? [String: Any])
            unknownPlan["futurePlanAuthority"] = "accepted-by-Codable-without-this-boundary"
            let canonicalPlan = try repositoryCanonicalJSON(unknownPlan)
            var recomputedRecord = originalRoot
            recomputedRecord["plan"] = unknownPlan
            recomputedRecord["planSHA256"] = repositorySHA256(canonicalPlan)
            try overwriteRepositoryRecord(
                try repositoryCanonicalJSON(recomputedRecord),
                at: path
            )
            #expect(throws: DoryResolvedMachinePlanRepositoryError.invalidRecord(path)) {
                _ = try repository.read(id: plan.machineID)
            }

            var unknownNestedPlan = try #require(originalRoot["plan"] as? [String: Any])
            var unknownGuest = try #require(unknownNestedPlan["guest"] as? [String: Any])
            unknownGuest["futureGuestAuthority"] = true
            unknownNestedPlan["guest"] = unknownGuest
            let canonicalNestedPlan = try repositoryCanonicalJSON(unknownNestedPlan)
            var recomputedNestedRecord = originalRoot
            recomputedNestedRecord["plan"] = unknownNestedPlan
            recomputedNestedRecord["planSHA256"] = repositorySHA256(canonicalNestedPlan)
            try overwriteRepositoryRecord(
                try repositoryCanonicalJSON(recomputedNestedRecord),
                at: path
            )
            #expect(throws: DoryResolvedMachinePlanRepositoryError.invalidRecord(path)) {
                _ = try repository.read(id: plan.machineID)
            }
        }
    }

    @Test("historical schema v4 digest remains readable only as replan input")
    func repositoryV4Migration() throws {
        try withRepository { repository, root in
            let plan = mutableARMVirtPlan()
            let path = try installRepositoryRecord(
                try legacySchemaV4Record(from: plan),
                root: root,
                machineID: plan.machineID
            )
            #expect(try Data(contentsOf: URL(fileURLWithPath: path))
                != (try repositoryCanonicalJSON(JSONSerialization.jsonObject(
                    with: Data(contentsOf: URL(fileURLWithPath: path))
                ))))

            let migrated = try repository.read(id: plan.machineID)
            #expect(migrated.sourceSchemaVersion == 4)
            #expect(migrated.migrationDisposition == .requiresReplanning)
            #expect(migrated.armVirtTopology == nil)
            #expect(Set(migrated.validate().map(\.code)) == [
                .legacyPlanRequiresReplanning, .invalidVirtualHardwareTopology,
            ])

            let start = DoryResolvedMachinePlanStartValidator.revalidate(
                migrated,
                against: DoryResolvedMachinePlanStartRevalidationInput(
                    machineID: migrated.machineID,
                    expectedPlanRevision: migrated.planRevision,
                    currentDefinitionRevision: migrated.definitionRevision,
                    currentDefinitionSHA256: migrated.definitionSHA256 ?? "",
                    runtimeEvidence: DoryResolvedMachineRuntimeEvidence(plan: migrated)
                )
            )
            #expect(!start.mayStart)
            #expect(start.issues.contains { $0.code == .storedPlanInvalid })
        }
    }

    @Test("historical schema v4 rejects contradictory provenance and invalid authority")
    func repositoryV4RejectsContradictions() throws {
        try withRepository { repository, root in
            let plan = mutableARMVirtPlan()
            let path = try installRepositoryRecord(
                try legacySchemaV4Record(from: plan) {
                    $0["sourceSchemaVersion"] = 3
                },
                root: root,
                machineID: plan.machineID
            )
            #expect(throws: DoryResolvedMachinePlanRepositoryError.invalidRecord(path)) {
                _ = try repository.read(id: plan.machineID)
            }

            try overwriteRepositoryRecord(
                try legacySchemaV4Record(from: plan) {
                    $0["migrationDisposition"] = "requires-replanning"
                },
                at: path
            )
            #expect(throws: DoryResolvedMachinePlanRepositoryError.invalidRecord(path)) {
                _ = try repository.read(id: plan.machineID)
            }

            try overwriteRepositoryRecord(
                try legacySchemaV4Record(from: plan) {
                    $0["planRevision"] = 0
                },
                at: path
            )
            #expect(throws: DoryResolvedMachinePlanRepositoryError.invalidRecord(path)) {
                _ = try repository.read(id: plan.machineID)
            }
        }
    }

    @Test("schema v1 repository record remains readable but cannot authorize launch")
    func repositoryV1Migration() throws {
        try withRepository { repository, root in
            let machineID = "workspace-one"
            let directory = root + "/" + machineID
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let record = "{\"schemaVersion\":1,\"plan\":\(DoryResolvedMachinePlanTests.goldenV1Plan)}"
            let path = directory + "/" + DoryResolvedMachinePlanRepository.recordFileName
            #expect(FileManager.default.createFile(
                atPath: path,
                contents: Data(record.utf8),
                attributes: [.posixPermissions: 0o600]
            ))

            let migrated = try repository.read(id: machineID)
            #expect(migrated.migrationDisposition == .requiresReplanning)
            #expect(!DoryResolvedMachinePlanStartValidator.revalidate(
                migrated,
                against: DoryResolvedMachinePlanStartRevalidationInput(
                    machineID: machineID,
                    expectedPlanRevision: migrated.planRevision,
                    currentDefinitionRevision: migrated.definitionRevision,
                    currentDefinitionSHA256: digest("1"),
                    runtimeEvidence: DoryResolvedMachineRuntimeEvidence(plan: migrated)
                )
            ).mayStart)
        }
    }

    @Test("repository rejects symlink hard-link public and oversized records")
    func hostileRecords() throws {
        try withRepository { repository, root in
            let plan = mutableARMVirtPlan()
            try repository.create(plan)
            let directory = root + "/" + plan.machineID
            let record = directory + "/" + DoryResolvedMachinePlanRepository.recordFileName
            let saved = directory + "/saved"
            try FileManager.default.moveItem(atPath: record, toPath: saved)

            #expect(symlink(saved, record) == 0)
            #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
                _ = try repository.read(id: plan.machineID)
            }
            #expect(unlink(record) == 0)

            #expect(link(saved, record) == 0)
            #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
                _ = try repository.read(id: plan.machineID)
            }
            #expect(unlink(record) == 0)

            try FileManager.default.copyItem(atPath: saved, toPath: record)
            _ = chmod(record, mode_t(0o644))
            #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
                _ = try repository.read(id: plan.machineID)
            }
            #expect(unlink(record) == 0)

            #expect(FileManager.default.createFile(atPath: record, contents: Data([0])))
            let descriptor = open(record, O_WRONLY | O_CLOEXEC)
            #expect(descriptor >= 0)
            #expect(ftruncate(descriptor, off_t(5 * 1_024 * 1_024)) == 0)
            _ = close(descriptor)
            _ = chmod(record, mode_t(0o600))
            #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
                _ = try repository.read(id: plan.machineID)
            }
        }
    }

    @Test("invalid and experimental-without-authorization plans are never published")
    func publicationValidation() throws {
        try withRepository { repository, _ in
            var unsupported = mutableARMVirtPlan()
            unsupported.supportTier = .unsupported
            #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
                try repository.create(unsupported)
            }

            var experimental = mutableARMVirtPlan()
            experimental.supportTier = .experimental
            experimental.qualificationEvidence.runtime = nil
            #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
                try repository.create(experimental)
            }

            var x86Linux = mutableARMVirtPlan()
            x86Linux.guest.architecture = .x86_64
            #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
                try repository.create(x86Linux)
            }
        }
    }

    private func withRepository(
        _ body: (DoryResolvedMachinePlanRepository, String) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-resolved-plan-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(DoryResolvedMachinePlanRepository(root: root), root)
    }

    private func repositoryRecordPath(root: String, machineID: String) -> String {
        root + "/" + machineID + "/" + DoryResolvedMachinePlanRepository.recordFileName
    }

    private func repositoryCanonicalJSON(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func repositorySHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("schema five records retain their original bytes and require explicit replanning")
    func repositoryV5Migration() throws {
        try withRepository { repository, root in
            let plan = mutableARMVirtPlan()
            var object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
            )
            object["schemaVersion"] = 5
            object["sourceSchemaVersion"] = 5
            for key in ["architecture", "platform", "resources", "firmware", "persistence"] { object.removeValue(forKey: key) }
            let planData = try repositoryCanonicalJSON(object)
            let original = try repositoryCanonicalJSON([
                "schemaVersion": 3, "planSHA256": repositorySHA256(planData), "plan": object,
            ])
            let path = try installRepositoryRecord(original, root: root, machineID: plan.machineID)
            let migrated = try repository.read(id: plan.machineID)
            #expect(migrated.sourceSchemaVersion == 5)
            #expect(migrated.migrationDisposition == .requiresReplanning)
            #expect(migrated.architecture == nil)
            #expect(migrated.resources == nil)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
            #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
                try repository.replace(migrated, expectedPlanRevision: plan.planRevision)
            }
        }
    }

    @Test("embedded schema five identity can be replanned without deleting its original record")
    func embeddedIdentityV5Migration() throws {
        try withRepository { repository, root in
            let plan = mutableARMVirtPlan()
            try repository.create(plan)
            let store = DoryMachineRuntimeIdentityStore(root: root)
            let legacy = Data("retained-machine-definition".utf8)
            let current = try DoryMachineRuntimeIdentity(
                resolvedPlan: plan, planSHA256: DoryMachineRuntimeIdentity.planSHA256(plan)
            )
            try store.publish(current, machineID: plan.machineID, authoritativeLegacyData: legacy)
            let directory = root + "/" + plan.machineID + "/"
            let recordPath = directory + DoryMachineRuntimeIdentityStore.recordFileName
            let headPath = directory + DoryMachineRuntimeIdentityStore.headFileName
            var record = try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: recordPath))
            ) as? [String: Any])
            var identity = try #require(record["identity"] as? [String: Any])
            var historicalPlan = try #require(identity["resolvedPlan"] as? [String: Any])
            historicalPlan["schemaVersion"] = 5
            historicalPlan["sourceSchemaVersion"] = 5
            for key in ["architecture", "platform", "resources", "firmware", "persistence"] { historicalPlan.removeValue(forKey: key) }
            identity["resolvedPlan"] = historicalPlan
            identity["resolvedPlanSHA256"] = repositorySHA256(try repositoryCanonicalJSON(historicalPlan))
            record["identity"] = identity
            let original = try repositoryCanonicalJSON(record)
            try original.write(to: URL(fileURLWithPath: recordPath))
            var head = try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: headPath))
            ) as? [String: Any])
            head["recordSHA256"] = repositorySHA256(original)
            try repositoryCanonicalJSON(head).write(to: URL(fileURLWithPath: headPath))
            let migrated = try #require(try store.readIfPresent(
                machineID: plan.machineID, authoritativeLegacyData: legacy
            ))
            #expect(migrated.mode == .requiresReplanning)
            #expect(migrated.resolvedPlan == nil)
            #expect(try Data(contentsOf: URL(fileURLWithPath: recordPath)) == original)
            try store.publish(current, machineID: plan.machineID, authoritativeLegacyData: legacy)
            #expect(try store.readIfPresent(machineID: plan.machineID, authoritativeLegacyData: legacy) == current)
        }
    }

    private func legacySchemaV4Record(
        from plan: DoryResolvedMachinePlan,
        mutate: (inout [String: Any]) -> Void = { _ in }
    ) throws -> Data {
        var planObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
        )
        planObject["schemaVersion"] = 4
        planObject["sourceSchemaVersion"] = 4
        planObject["migrationDisposition"] = "current"
        planObject.removeValue(forKey: "armVirtTopology")
        planObject.removeValue(forKey: "architecture")
        planObject.removeValue(forKey: "platform")
        planObject.removeValue(forKey: "resources")
        planObject.removeValue(forKey: "firmware")
        planObject.removeValue(forKey: "persistence")
        mutate(&planObject)
        let canonicalPlan = try repositoryCanonicalJSON(planObject)
        return try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "planSHA256": repositorySHA256(canonicalPlan),
                "plan": planObject,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private func installRepositoryRecord(
        _ data: Data,
        root: String,
        machineID: String
    ) throws -> String {
        let directory = root + "/" + machineID
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = repositoryRecordPath(root: root, machineID: machineID)
        #expect(FileManager.default.createFile(
            atPath: path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ))
        return path
    }

    private func overwriteRepositoryRecord(_ data: Data, at path: String) throws {
        try data.write(to: URL(fileURLWithPath: path))
        #expect(chmod(path, mode_t(0o600)) == 0)
    }
}

private func supportedPlan() -> DoryResolvedMachinePlan {
    let artifact = digest("a")
    let devices = DoryVirtualMachineDeviceCapabilityRequest(
        networkInterface: .stable(machineID: "workspace-one"),
        display: DoryVirtualMachineDisplayCapabilityRequest(
            widthPixels: 1_920,
            heightPixels: 1_080
        )
    )
    let media = DoryBootMedia(
        kind: .installedLinuxBootBundle,
        source: .bundledByDory,
        artifactSHA256: artifact
    )
    return DoryResolvedMachinePlan(
        machineID: "workspace-one",
        definitionRevision: 3,
        definitionSHA256: digest("1"),
        planRevision: 1,
        createdAtUnixMilliseconds: 1_700_000_000_000,
        updatedAtUnixMilliseconds: 1_700_000_000_000,
        guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
        backend: .doryHypervisor,
        backendImplementationIdentifier: "dory.raw-hv-linux.compatibility.v1",
        backendRuntimeBuildIdentifier: "raw-runtime-1",
        virtualHardwareABIVersion: 1,
        armVirtTopology: supportedRawHVTopology(),
        bootMedia: DoryResolvedMachineBootMedia(
            resolverReference: DoryVMResolverReference(
                namespace: "artifact",
                identifier: "ubuntu-desktop-1"
            ),
            media: media
        ),
        launchArtifacts: resolvedBootLaunchArtifacts(
            reference: DoryVMResolverReference(
                namespace: "artifact", identifier: "ubuntu-desktop-1"
            ),
            media: media
        ),
        components: [
            DoryResolvedBackendComponentEvidence(
                componentIdentifier: "dory-hv",
                buildIdentifier: "raw-runtime-1",
                artifactSHA256: digest("d")
            ),
            DoryResolvedBackendComponentEvidence(
                componentIdentifier: "renderer",
                buildIdentifier: "renderer-1",
                artifactSHA256: digest("e")
            ),
        ],
        devices: devices,
        graphics: .hostAcceleratedDisplay,
        portForwards: [DoryVMPortForward(
            id: "ssh",
            hostPort: 2_222,
            guestPort: 22
        )],
        supportTier: .supported,
        selectionEvidence: primarySelectionEvidence(
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            media: media,
            backend: .doryHypervisor,
            graphics: .hostAcceleratedDisplay,
            devices: devices
        ),
        qualificationEvidence: DoryResolvedMachineQualificationEvidence(
            graphics: DorySignedArtifactQualificationEvidence(
                manifestIdentity: "ubuntu-graphics-1",
                artifactSHA256: artifact,
                manifestSHA256: digest("b"),
                signingKeyID: "dory-release-1",
                manifestFormatVersion: 1
            ),
            runtime: runtimeQualification(
                media: media,
                backend: .doryHypervisor,
                runtimeBuild: "raw-runtime-1",
                graphics: .hostAcceleratedDisplay,
                devices: devices
            )
        ),
        resourceAdmission: resourceAdmission(),
        hostQualification: hostQualification(
            backend: .doryHypervisor,
            runtimeBuild: "raw-runtime-1"
        ),
        persistence: resolvedPersistenceTestBinding()
    )
}

private func supportedRawHVTopology() -> DoryARMVirtV1Topology {
    try! DoryARMVirtV1Topology(occupiedSlots: [
        DoryARMVirtV1DeviceSlot(
            logicalID: DoryVirtualDeviceID.derived(
                namespace: .systemDisk,
                stableID: "workspace-one-system-disk"
            ),
            role: .systemDisk,
            mmioSlot: 0
        ),
        DoryARMVirtV1DeviceSlot(
            logicalID: "armvirt-graphics",
            role: .graphics,
            mmioSlot: 1
        ),
        DoryARMVirtV1DeviceSlot(
            logicalID: "armvirt-entropy",
            role: .entropy,
            mmioSlot: 2
        ),
        DoryARMVirtV1DeviceSlot(
            logicalID: "armvirt-balloon",
            role: .balloon,
            mmioSlot: 3
        ),
        DoryARMVirtV1DeviceSlot(
            logicalID: "armvirt-vsock",
            role: .vsock,
            mmioSlot: 4
        ),
        DoryARMVirtV1DeviceSlot(
            logicalID: DoryVirtualDeviceID.derived(
                namespace: .network,
                stableID: "nic0"
            ),
            role: .network,
            mmioSlot: 8
        ),
    ])
}

private func mutableARMVirtPlan() -> DoryResolvedMachinePlan {
    let provenance = DoryMutableBootMediaProvenanceReference(
        repositoryIdentity: "machine-store",
        mediaIdentity: "workspace-one-disk",
        revision: 7
    )
    let devices = DoryVirtualMachineDeviceCapabilityRequest(networkInterface: .stable(machineID: "workspace-one"))
    let media = DoryBootMedia(
        kind: .virtualDisk,
        source: .userProvided,
        mutableProvenance: provenance
    )
    return DoryResolvedMachinePlan(
        machineID: "workspace-one",
        definitionRevision: 3,
        definitionSHA256: digest("1"),
        planRevision: 1,
        createdAtUnixMilliseconds: 1_700_000_000_000,
        updatedAtUnixMilliseconds: 1_700_000_000_000,
        guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
        backend: .doryHypervisor,
        backendImplementationIdentifier: "dory.raw-hv-linux.compatibility.v1",
        backendRuntimeBuildIdentifier: "raw-runtime-1",
        virtualHardwareABIVersion: 1,
        armVirtTopology: resolvedARMVirtTestTopology(devices: devices),
        bootMedia: DoryResolvedMachineBootMedia(
            resolverReference: DoryVMResolverReference(
                namespace: "machine",
                identifier: "workspace-one-disk"
            ),
            media: media,
            mutableProvenanceEvidence: DoryMutableBootMediaProvenanceAuditEvidence(
                receiptIdentity: "disk-receipt-7",
                provenance: provenance,
                receiptSHA256: digest("7"),
                resolverID: "machine-store",
                resolverVersion: 1
            )
        ),
        launchArtifacts: resolvedBootLaunchArtifacts(
            reference: DoryVMResolverReference(
                namespace: "machine", identifier: "workspace-one-disk"
            ),
            media: media,
            mutableEvidence: DoryMutableBootMediaProvenanceAuditEvidence(
                receiptIdentity: "disk-receipt-7",
                provenance: provenance,
                receiptSHA256: digest("7"),
                resolverID: "machine-store",
                resolverVersion: 1
            )
        ),
        components: [DoryResolvedBackendComponentEvidence(
            componentIdentifier: "dory-hv",
            buildIdentifier: "raw-runtime-1",
            artifactSHA256: digest("d")
        )],
        devices: devices,
        graphics: .software,
        supportTier: .supported,
        selectionEvidence: primarySelectionEvidence(
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            media: media,
            backend: .doryHypervisor,
            graphics: .software,
            devices: devices
        ),
        qualificationEvidence: DoryResolvedMachineQualificationEvidence(),
        resourceAdmission: resourceAdmission(),
        firmware: try! resolvedFirmwareTestArtifacts().manifest,
        persistence: resolvedPersistenceTestBinding()
    )
}

private func installedNativeMacPlan() -> DoryResolvedMachinePlan {
    let reference = DoryVMResolverReference(
        namespace: "macos-machine",
        identifier: "native-mac-system-disk"
    )
    let provenance = DoryMutableBootMediaProvenanceReference(
        repositoryIdentity: "fixture-artifact-authority",
        mediaIdentity: "native-mac-system-disk",
        revision: 3
    )
    let evidence = DoryMutableBootMediaProvenanceAuditEvidence(
        receiptIdentity: "native-mac-disk-receipt-3",
        provenance: provenance,
        receiptSHA256: digest("3"),
        resolverID: "fixture-artifact-authority",
        resolverVersion: 1
    )
    let media = DoryBootMedia(
        kind: .virtualDisk,
        source: .userProvided,
        mutableProvenance: provenance
    )
    let devices = DoryVirtualMachineDeviceCapabilityRequest(
        networkInterface: .stable(machineID: "native-mac"),
        display: DoryVirtualMachineDisplayCapabilityRequest(
            widthPixels: 1_280,
            heightPixels: 800
        ),
        audioInput: false,
        audioOutput: false,
        keyboard: true,
        pointer: true,
        clipboard: false,
        clipboardPolicy: .disabled,
        dynamicDisplay: true,
        gracefulShutdown: true
    )
    return DoryResolvedMachinePlan(
        machineID: "native-mac",
        definitionRevision: 2,
        definitionSHA256: digest("a"),
        planRevision: 4,
        createdAtUnixMilliseconds: 1_700_000_000_000,
        updatedAtUnixMilliseconds: 1_700_000_000_100,
        guest: DoryGuestPlatform(family: .macOS, architecture: .arm64),
        backend: .appleVirtualizationFramework,
        backendImplementationIdentifier: "dory.vz-machine.v2",
        backendRuntimeBuildIdentifier: "vz-runtime-1",
        virtualHardwareABIVersion: 1,
        bootMedia: DoryResolvedMachineBootMedia(
            resolverReference: reference,
            media: media,
            mutableProvenanceEvidence: evidence
        ),
        launchArtifacts: [DoryResolvedMachineLaunchArtifact(
            resolverReference: reference,
            media: media,
            authorityRevision: 3,
            usages: [
                DoryResolvedMachineLaunchArtifactUsage(
                    kind: .boot,
                    identifier: "system",
                    readOnly: false
                ),
                DoryResolvedMachineLaunchArtifactUsage(
                    kind: .storage,
                    identifier: "system",
                    readOnly: false
                ),
            ],
            mutableProvenanceEvidence: evidence
        )],
        components: [DoryResolvedBackendComponentEvidence(
            componentIdentifier: "dory-vmm",
            buildIdentifier: "vz-runtime-1",
            artifactSHA256: digest("b")
        )],
        devices: devices,
        graphics: .hostAcceleratedDisplay,
        supportTier: .experimental,
        selectionEvidence: {
            var evidence = primarySelectionEvidence(
                guest: DoryGuestPlatform(family: .macOS, architecture: .arm64),
                media: media,
                backend: .appleVirtualizationFramework,
                graphics: .hostAcceleratedDisplay,
                devices: devices
            )
            evidence.plannerRequest.allowsExperimentalBackends = true
            return evidence
        }(),
        qualificationEvidence: DoryResolvedMachineQualificationEvidence(),
        resourceAdmission: resourceAdmission(),
        experimentalAuthorization: DoryResolvedExperimentalSupportAuthorization(
            authorizationIdentity: "explicit-native-macos-create",
            definitionRevision: 2,
            backend: .appleVirtualizationFramework,
            authorizedAtUnixMilliseconds: 1_700_000_000_100
        ),
        persistence: resolvedPersistenceTestBinding(machineID: "native-mac")
    )
}

private func runtimeQualification(
    media: DoryBootMedia,
    backend: DoryVirtualizationBackendIdentity,
    runtimeBuild: String,
    graphics: DoryGraphicsAccelerationLevel,
    devices: DoryVirtualMachineDeviceCapabilityRequest
) -> DoryVirtualMachineRuntimeQualificationEvidence {
    DoryVirtualMachineRuntimeQualificationEvidence(
        qualificationIdentity: "runtime-qualification-1",
        qualificationReportSHA256: digest("c"),
        signingKeyID: "dory-runtime-1",
        qualificationFormatVersion: 1,
        guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
        bootMediaKind: media.kind,
        immutableArtifactSHA256: media.artifactSHA256,
        mutableProvenance: media.mutableProvenance,
        backend: backend,
        backendRuntimeBuildID: runtimeBuild,
        virtualHardwareABIVersion: 1,
        graphics: graphics,
        devices: devices
    )
}

private func primarySelectionEvidence(
    guest: DoryGuestPlatform,
    media: DoryBootMedia,
    backend: DoryVirtualizationBackendIdentity,
    graphics: DoryGraphicsAccelerationLevel,
    devices: DoryVirtualMachineDeviceCapabilityRequest
) -> DoryResolvedMachineBackendSelectionEvidence {
    DoryResolvedMachineBackendSelectionEvidence(
        disposition: .primary,
        plannerRequest: DoryVirtualMachineBackendPlanRequest(
            guest: guest,
            bootMedia: media,
            acceptableGraphics: [graphics],
            devices: devices,
            backendPreferences: [backend],
            backendPreferencePolicy: .required
        ),
        selectedEvaluationIndex: 0,
        rejectedCandidates: []
    )
}

private func backendPlannerRequest(
    from plan: DoryResolvedMachinePlan
) -> DoryVirtualMachineBackendPlanRequest {
    plan.selectionEvidence?.plannerRequest ?? DoryVirtualMachineBackendPlanRequest(
        guest: plan.guest,
        bootMedia: plan.bootMedia.media,
        acceptableGraphics: [plan.graphics],
        devices: plan.devices,
        virtualHardwareABIVersion: plan.virtualHardwareABIVersion,
        backendPreferences: [plan.backend],
        backendPreferencePolicy: .required
    )
}

private func resourceAdmission() -> DoryResolvedMachineResourceAdmissionEvidence {
    DoryResolvedMachineResourceAdmissionEvidence(
        admittedVirtualCPUCount: 4,
        admittedMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        admittedStorageBytes: 64 * 1_024 * 1_024 * 1_024,
        hostLogicalCPUCount: 12,
        hostPhysicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
        hostFreeStorageBytes: 512 * 1_024 * 1_024 * 1_024,
        existingVirtualCPUCommitment: 2,
        existingMemoryCommitmentBytes: 4 * 1_024 * 1_024 * 1_024,
        existingStorageReservationBytes: 32 * 1_024 * 1_024 * 1_024,
        hostReservedLogicalCPUCount: 2,
        hostReservedMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
        hostReservedStorageBytes: 32 * 1_024 * 1_024 * 1_024,
        admissionIdentity: "resource-admission-1",
        admissionReportSHA256: digest("f"),
        assessorIdentifier: "dory-resource-policy",
        assessorVersion: 1
    )
}

private func hostQualification(
    backend: DoryVirtualizationBackendIdentity,
    runtimeBuild: String
) -> DoryResolvedHostQualificationEvidence {
    DoryResolvedHostQualificationEvidence(
        qualificationIdentity: "host-qualification-1",
        qualificationReportSHA256: digest("6"),
        hostHardwareModelIdentifier: "Mac16.1",
        hostOperatingSystemBuild: "26A5406c",
        backend: backend,
        backendRuntimeBuildIdentifier: runtimeBuild,
        virtualHardwareABIVersion: 1,
        qualifierIdentifier: "dory-host-qualifier",
        qualifierVersion: 1
    )
}

private func digest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}
