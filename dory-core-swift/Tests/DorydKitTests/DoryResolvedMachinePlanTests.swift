import Darwin
import DoryOperations
@testable import DorydKit
import Foundation
import Testing

@Suite("Resolved machine plan")
struct DoryResolvedMachinePlanTests {
    @Test("current exact plan validates and round trips")
    func roundTrip() throws {
        let plan = supportedPlan()
        #expect(plan.validate().isEmpty)
        let encoded = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(DoryResolvedMachinePlan.self, from: encoded) == plan)
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
        let plan = mutableVZPlan()
        #expect(plan.validate().isEmpty)
        var input = exactInput(for: plan)
        input.runtimeEvidence.bootMedia.media.mutableProvenance?.revision += 1

        let result = DoryResolvedMachinePlanStartValidator.revalidate(plan, against: input)
        #expect(!result.mayStart)
        #expect(result.issues.contains { $0.code == .bootMediaEvidenceMismatch })
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
        let plan = try fallbackVZPlan(policy: .preferred, includeAuthorization: true)
        let selection = try #require(plan.selectionEvidence)
        #expect(selection.disposition == .approvedFallback)
        #expect(selection.selectedEvaluationIndex == 1)
        #expect(selection.rejectedCandidates.count == 1)
        #expect(selection.rejectedCandidates[0].backend == .doryHypervisor)
        #expect(selection.rejectedCandidates[0].availability.reason?.code
            == .bootMediaDoesNotSupportBackend)
        #expect(selection.fallbackAuthorization?.fromBackend == .doryHypervisor)
        #expect(selection.fallbackAuthorization?.toBackend == .appleVirtualizationFramework)
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
            _ = try fallbackVZPlan(policy: .preferred, includeAuthorization: false)
        }

        let requiredAlternative = try fallbackVZPlan(
            policy: .required,
            includeAuthorization: false
        )
        #expect(requiredAlternative.selectionEvidence?.disposition == .explicitAlternative)
        #expect(requiredAlternative.selectionEvidence?.fallbackAuthorization == nil)
        #expect(requiredAlternative.validate().isEmpty)

        #expect(throws: DoryResolvedMachinePlanConstructionError.fallbackAuthorizationInvalid) {
            _ = try fallbackVZPlan(policy: .required, includeAuthorization: true)
        }
    }

    @Test("required policy permits an explicitly listed lower graphics contract")
    func requiredGraphicsAlternative() throws {
        var plan = supportedPlan()
        let request = DoryVirtualMachineBackendPlanRequest(
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
        plan.selectionEvidence = try DoryResolvedMachineBackendSelectionEvidence.resolving(
            request: request,
            result: DoryVirtualMachineBackendPlanResult(
                selectedDescriptor: selected,
                evaluatedDescriptors: [rejected, selected],
                failure: nil
            ),
            definitionRevision: plan.definitionRevision
        )

        #expect(plan.selectionEvidence?.disposition == .explicitAlternative)
        #expect(plan.selectionEvidence?.selectedEvaluationIndex == 1)
        #expect(plan.validate().isEmpty)
    }

    @Test("required policy rejects a backend the request did not list")
    func requiredImplicitBackendRejection() {
        let plan = mutableVZPlan()
        let request = DoryVirtualMachineBackendPlanRequest(
            guest: plan.guest,
            bootMedia: plan.bootMedia.media,
            acceptableGraphics: [plan.graphics],
            devices: plan.devices,
            virtualHardwareABIVersion: plan.virtualHardwareABIVersion,
            backendPreferences: [.doryHypervisor],
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
        let plan = try fallbackVZPlan(policy: .preferred, includeAuthorization: true)
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

    private func fallbackVZPlan(
        policy: DoryVirtualMachineBackendPreferencePolicy,
        includeAuthorization: Bool
    ) throws -> DoryResolvedMachinePlan {
        var plan = mutableVZPlan()
        let request = DoryVirtualMachineBackendPlanRequest(
            guest: plan.guest,
            bootMedia: plan.bootMedia.media,
            acceptableGraphics: [plan.graphics],
            devices: plan.devices,
            virtualHardwareABIVersion: plan.virtualHardwareABIVersion,
            backendPreferences: [.doryHypervisor, .appleVirtualizationFramework],
            backendPreferencePolicy: policy
        )
        let rejectedRequest = DoryVirtualMachineCapabilityRequest(
            guest: plan.guest,
            bootMedia: plan.bootMedia.media,
            backend: .doryHypervisor,
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
                fromBackend: .doryHypervisor,
                fromGraphics: plan.graphics,
                toBackend: .appleVirtualizationFramework,
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
            let initial = supportedPlan()
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
            let plan = supportedPlan()
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
            let plan = supportedPlan()
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
            var unsupported = supportedPlan()
            unsupported.supportTier = .unsupported
            #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
                try repository.create(unsupported)
            }

            var experimental = supportedPlan()
            experimental.supportTier = .experimental
            experimental.qualificationEvidence.runtime = nil
            #expect(throws: DoryResolvedMachinePlanRepositoryError.self) {
                try repository.create(experimental)
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
}

private func supportedPlan() -> DoryResolvedMachinePlan {
    let artifact = digest("a")
    let devices = DoryVirtualMachineDeviceCapabilityRequest.minimumBootable
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
        )
    )
}

private func mutableVZPlan() -> DoryResolvedMachinePlan {
    let provenance = DoryMutableBootMediaProvenanceReference(
        repositoryIdentity: "machine-store",
        mediaIdentity: "workspace-one-disk",
        revision: 7
    )
    let devices = DoryVirtualMachineDeviceCapabilityRequest.minimumBootable
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
        backend: .appleVirtualizationFramework,
        backendImplementationIdentifier: "dory.vz-linux.compatibility.v1",
        backendRuntimeBuildIdentifier: "vz-runtime-1",
        virtualHardwareABIVersion: 1,
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
            componentIdentifier: "dory-vmm",
            buildIdentifier: "vz-runtime-1",
            artifactSHA256: digest("d")
        )],
        devices: devices,
        graphics: .software,
        supportTier: .supported,
        selectionEvidence: primarySelectionEvidence(
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            media: media,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            devices: devices
        ),
        qualificationEvidence: DoryResolvedMachineQualificationEvidence(
            runtime: runtimeQualification(
                media: media,
                backend: .appleVirtualizationFramework,
                runtimeBuild: "vz-runtime-1",
                graphics: .software,
                devices: devices
            )
        ),
        resourceAdmission: resourceAdmission(),
        hostQualification: hostQualification(
            backend: .appleVirtualizationFramework,
            runtimeBuild: "vz-runtime-1"
        )
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
