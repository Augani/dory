import Foundation
import Testing
@testable import DoryOperations

@Suite("Virtual machine backend planner")
struct DoryVirtualMachineBackendPlannerTests {
    private static let guestArtifactSHA256 = String(repeating: "c", count: 64)
    private static let linuxISOArtifactSHA256 = String(repeating: "a", count: 64)
    private static let windowsISOArtifactSHA256 = String(repeating: "b", count: 64)
    private static let macOSRestoreArtifactSHA256 = String(repeating: "d", count: 64)
    private static let manifestSHA256 = String(repeating: "e", count: 64)
    private static let inspectionReportSHA256 = String(repeating: "f", count: 64)
    private static let provenanceReceiptSHA256 = String(repeating: "1", count: 64)
    private static let runtimeQualificationReportSHA256 = String(repeating: "2", count: 64)
    private static let qualifiedLinuxGraphics = DoryTrustedGuestImageGraphicsQualification(
        auditEvidence: DorySignedArtifactQualificationEvidence(
            manifestIdentity: "dory-linux-desktop-arm64-gpu-v1",
            artifactSHA256: guestArtifactSHA256,
            manifestSHA256: manifestSHA256,
            signingKeyID: "dory-release-2026",
            manifestFormatVersion: 1
        ),
        virtioGPUKernelAndDeviceSupportQualified: true,
        venusVulkanGuestRuntimeQualified: true
    )

    private static let host = DoryAppleSiliconHostFacts(
        macOSMajorVersion: 15,
        virtualizationFrameworkAvailable: true,
        hypervisorFrameworkAvailable: true,
        doryHypervisorAvailable: true,
        qemuHypervisorFrameworkAvailable: true,
        windowsUEFIFirmwareAvailable: true,
        windowsSecureBootAvailable: true,
        windowsSBSADeviceModelAvailable: true,
        virtualTPM20Available: true,
        windowsGuestDrivers: DoryWindowsGuestDriverFacts(
            storageAvailable: true,
            networkAvailable: true,
            displayAvailable: true,
            inputAvailable: true
        ),
        macOSGuestVirtualizationSupported: true,
        macOSRestoreImageInstallationSupported: true,
        doryMacOSBackendAvailable: true,
        doryMacOSBackendQualified: true,
        metalAvailable: true,
        doryAcceleratedRendererAvailable: true,
        runtimeQualificationContext: DoryVirtualMachineRuntimeQualificationHostContext(
            virtualHardwareABIVersion: 1,
            doryHypervisorRuntimeBuildID: "dory-hv-2026.8",
            virtualizationFrameworkAdapterBuildID: "dory-vz-2026.8",
            qemuRuntimeBuildID: "qemu-hvf-2026.8"
        )
    )

    @Test("default backend order reflects currently runnable boot paths")
    func truthfulDefaults() {
        let linux = DoryGuestPlatform(family: .linux, architecture: .arm64)
        let macOS = DoryGuestPlatform(family: .macOS, architecture: .arm64)
        let windows = DoryGuestPlatform(family: .windows, architecture: .arm64)

        #expect(DoryAppleSiliconVirtualMachineBackendPlanner.defaultBackends(
            for: linux,
            bootMedia: .installerISO
        ) == [.appleVirtualizationFramework, .qemuHypervisorFramework])
        #expect(DoryAppleSiliconVirtualMachineBackendPlanner.defaultBackends(
            for: linux,
            bootMedia: .installedLinuxBootBundle
        ) == [.doryHypervisor])
        #expect(DoryAppleSiliconVirtualMachineBackendPlanner.defaultBackends(
            for: macOS,
            bootMedia: .macOSRestoreImage
        ) == [.appleVirtualizationFramework])
        #expect(DoryAppleSiliconVirtualMachineBackendPlanner.defaultBackends(
            for: windows,
            bootMedia: .installerISO
        ) == [.qemuHypervisorFramework])
    }

    @Test("Linux ISO selects Virtualization.framework before experimental QEMU")
    func linuxInstallerSelection() throws {
        let result = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.software]
        )
        let selected = try #require(result.selectedDescriptor)

        #expect(result.isSuccess)
        #expect(selected.request.backend == .appleVirtualizationFramework)
        #expect(selected.availability.supportTier == .supported)
        #expect(selected.bootMediaInspectionEvidence?.artifactSHA256
            == Self.linuxISOArtifactSHA256)
        #expect(result.evaluatedDescriptors.map(\.request.backend) == [
            .appleVirtualizationFramework,
            .qemuHypervisorFramework,
        ])
    }

    @Test("structurally bootable ISO requires experimental opt-in without runtime qualification")
    func unqualifiedISORuntimeRequiresOptIn() throws {
        let denied = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.software],
            automaticallyQualifyRuntime: false
        )
        let allowed = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.software],
            allowsExperimental: true,
            automaticallyQualifyRuntime: false
        )

        #expect(denied.failure?.code == .noCandidate)
        #expect(denied.evaluatedDescriptors.first?.availability.supportTier == .experimental)
        #expect(denied.evaluatedDescriptors.first?.availability.reason?.code
            == .runtimeQualificationUnavailable)
        #expect(try #require(allowed.selectedDescriptor).availability.supportTier
            == .experimental)
    }

    @Test("mutable virtual disks cannot be planned from a digest without provenance")
    func mutableDiskRequiresProvenanceReceipt() {
        let result = plan(
            family: .linux,
            media: .virtualDisk,
            graphics: [.software],
            allowsExperimental: true,
            mediaArtifactSHA256: String(repeating: "9", count: 64),
            automaticallyResolveMutableProvenance: false,
            automaticallyQualifyRuntime: false
        )

        #expect(result.failure?.code == .noCandidate)
        #expect(result.evaluatedDescriptors.allSatisfy {
            $0.availability.reason?.code == .mutableBootMediaProvenanceUnavailable
        })
    }

    @Test("installed Linux direct boot selects Dory's native hypervisor")
    func installedLinuxSelection() throws {
        let result = plan(
            family: .linux,
            media: .installedLinuxBootBundle,
            graphics: [.hardwareAccelerated3D, .software],
            mediaArtifactSHA256: Self.guestArtifactSHA256,
            trustedGuestImageGraphicsQualification: Self.qualifiedLinuxGraphics
        )
        let selected = try #require(result.selectedDescriptor)

        #expect(selected.request.backend == .doryHypervisor)
        #expect(selected.request.graphics == .hardwareAccelerated3D)
        #expect(selected.request.bootMedia.artifactSHA256 == Self.guestArtifactSHA256)
        #expect(selected.runtimeQualificationEvidence?.backend == .doryHypervisor)
        #expect(result.evaluatedDescriptors.count == 2)
    }

    @Test("planner defaults cannot authorize Linux 3D without image qualification")
    func installedLinuxUnqualifiedGraphicsIsFailClosed() throws {
        let noFallback = plan(
            family: .linux,
            media: .installedLinuxBootBundle,
            graphics: [.hardwareAccelerated3D],
            mediaArtifactSHA256: Self.guestArtifactSHA256
        )
        let explicitHeadlessFallback = plan(
            family: .linux,
            media: .installedLinuxBootBundle,
            graphics: [.hardwareAccelerated3D, .none],
            mediaArtifactSHA256: Self.guestArtifactSHA256
        )
        let selected = try #require(explicitHeadlessFallback.selectedDescriptor)

        #expect(noFallback.failure?.code == .noCandidate)
        #expect(noFallback.evaluatedDescriptors.first?.availability.reason?.code
            == .trustedGuestImageGraphicsQualificationUnavailable)
        #expect(selected.request.graphics == .none)
        #expect(selected.request.bootMedia.artifactSHA256 == Self.guestArtifactSHA256)
    }

    @Test("preferred backend order is honored across explicitly allowed support tiers")
    func backendPreferenceOrderIsHonored() throws {
        let result = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.software],
            backends: [.qemuHypervisorFramework, .appleVirtualizationFramework],
            allowsExperimental: true
        )
        let selected = try #require(result.selectedDescriptor)

        #expect(selected.request.backend == .qemuHypervisorFramework)
        #expect(result.evaluatedDescriptors.map(\.request.backend) == [
            .qemuHypervisorFramework,
            .appleVirtualizationFramework,
        ])
    }

    @Test("preferred backends permit automatic fallback while required backends do not")
    func backendPreferencePolicyControlsFallback() throws {
        var unavailableQEMUHost = Self.host
        unavailableQEMUHost.qemuHypervisorFrameworkAvailable = false
        let preferred = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.software],
            backends: [.qemuHypervisorFramework],
            backendPolicy: .preferred,
            host: unavailableQEMUHost,
            allowsExperimental: true
        )
        let required = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.software],
            backends: [.qemuHypervisorFramework],
            backendPolicy: .required,
            host: unavailableQEMUHost,
            allowsExperimental: true
        )

        #expect(try #require(preferred.selectedDescriptor).request.backend
            == .appleVirtualizationFramework)
        #expect(preferred.evaluatedDescriptors.map(\.request.backend) == [
            .qemuHypervisorFramework,
            .appleVirtualizationFramework,
        ])
        #expect(required.failure?.code == .noCandidate)
        #expect(required.evaluatedDescriptors.map(\.request.backend)
            == [.qemuHypervisorFramework])
    }

    @Test("graphics is never downgraded unless the caller supplied the fallback")
    func graphicsFallbackMustBeExplicit() throws {
        let noFallback = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.hardwareAccelerated3D]
        )
        let withFallback = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.hardwareAccelerated3D, .software]
        )
        let selected = try #require(withFallback.selectedDescriptor)

        #expect(!noFallback.isSuccess)
        #expect(noFallback.failure?.code == .noCandidate)
        #expect(noFallback.evaluatedDescriptors.count == 2)
        #expect(selected.request.graphics == .software)
        #expect(withFallback.evaluatedDescriptors.count == 4)
    }

    @Test("Windows remains unavailable unless experimental backends are explicitly allowed")
    func windowsRequiresExperimentalOptIn() throws {
        let denied = plan(
            family: .windows,
            media: .installerISO,
            graphics: [.software]
        )
        let allowed = plan(
            family: .windows,
            media: .installerISO,
            graphics: [.hardwareAccelerated3D, .software],
            allowsExperimental: true
        )
        let selected = try #require(allowed.selectedDescriptor)

        #expect(denied.failure?.code == .noCandidate)
        #expect(denied.evaluatedDescriptors.first?.availability.isUsable == true)
        #expect(selected.availability.supportTier == .experimental)
        #expect(selected.request.graphics == .software)
        #expect(allowed.evaluatedDescriptors.first?.availability.reason?.code
            == .windows3DAccelerationUnsupported)
    }

    @Test("macOS default is VZ and retains external Apple media provenance")
    func macOSSelection() throws {
        let result = plan(
            family: .macOS,
            media: .macOSRestoreImage,
            source: .vendorDownload,
            graphics: [.hardwareAccelerated3D],
            allowsExperimental: true
        )
        let selected = try #require(result.selectedDescriptor)

        #expect(selected.request.backend == .appleVirtualizationFramework)
        #expect(selected.availability.supportTier == .experimental)
        #expect(selected.request.bootMedia.source == .vendorDownload)
        #expect(result.evaluatedDescriptors.count == 1)
    }

    @Test("empty and duplicate preferences fail before capability evaluation")
    func invalidPreferences() {
        let emptyGraphics = plan(family: .linux, media: .installerISO, graphics: [])
        let duplicateGraphics = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.software, .software]
        )
        let emptyBackends = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.software],
            backends: []
        )
        let duplicateBackends = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.software],
            backends: [.appleVirtualizationFramework, .appleVirtualizationFramework]
        )
        let missingRequiredBackends = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.software],
            backendPolicy: .required
        )

        #expect(emptyGraphics.failure?.code == .invalidPreference)
        #expect(emptyGraphics.failure?.preferenceField == .graphics)
        #expect(emptyGraphics.failure?.preferenceIssue == .empty)
        #expect(duplicateGraphics.failure?.preferenceIssue == .duplicate)
        #expect(emptyBackends.failure?.preferenceField == .backend)
        #expect(emptyBackends.failure?.preferenceIssue == .empty)
        #expect(duplicateBackends.failure?.preferenceIssue == .duplicate)
        #expect(missingRequiredBackends.failure?.preferenceIssue == .missing)
        #expect(emptyGraphics.evaluatedDescriptors.isEmpty)
        #expect(duplicateBackends.evaluatedDescriptors.isEmpty)
    }

    @Test("planner results preserve evaluation evidence through Codable")
    func codableResult() throws {
        let result = plan(
            family: .linux,
            media: .installerISO,
            graphics: [.hardwareAccelerated3D]
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(
            DoryVirtualMachineBackendPlanResult.self,
            from: data
        )

        #expect(decoded == result)
        #expect(decoded.failure?.code == .noCandidate)
        #expect(decoded.evaluatedDescriptors.count == 2)
    }

    @Test("successful 3D plans retain revalidation evidence through Codable")
    func qualifiedPlanAuditRoundTrip() throws {
        let result = plan(
            family: .linux,
            media: .installedLinuxBootBundle,
            graphics: [.hardwareAccelerated3D],
            mediaArtifactSHA256: Self.guestArtifactSHA256,
            trustedGuestImageGraphicsQualification: Self.qualifiedLinuxGraphics
        )
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(
            DoryVirtualMachineBackendPlanResult.self,
            from: encoded
        )
        let selected = try #require(decoded.selectedDescriptor)

        #expect(selected.graphicsQualificationEvidence
            == Self.qualifiedLinuxGraphics.auditEvidence)
        #expect(selected.graphicsQualificationEvidence?.manifestSHA256
            == Self.manifestSHA256)
        #expect(selected.request.bootMedia.artifactSHA256 == Self.guestArtifactSHA256)
        #expect(selected.runtimeQualificationEvidence?.qualificationIdentity
            == "linux-runtime-qualification-v1")
    }

    @Test("runtime inventory selection is order independent for ISO digest and runtime build")
    func runtimeInventoryMatchesExactISORecordInEitherOrder() throws {
        let exact = runtimeQualification(
            media: .installerISO,
            immutableArtifactSHA256: Self.linuxISOArtifactSHA256,
            backend: .appleVirtualizationFramework,
            runtimeBuildID: "dory-vz-2026.8"
        )
        let staleDigest = runtimeQualification(
            media: .installerISO,
            immutableArtifactSHA256: String(repeating: "7", count: 64),
            backend: .appleVirtualizationFramework,
            runtimeBuildID: "dory-vz-2026.8"
        )
        let staleRuntime = runtimeQualification(
            media: .installerISO,
            immutableArtifactSHA256: Self.linuxISOArtifactSHA256,
            backend: .appleVirtualizationFramework,
            runtimeBuildID: "dory-vz-2026.7"
        )

        for inventory in [
            [staleDigest, staleRuntime, exact],
            [exact, staleRuntime, staleDigest],
        ] {
            let result = plan(
                family: .linux,
                media: .installerISO,
                graphics: [.software],
                trustedRuntimeQualifications: inventory
            )
            let selected = try #require(result.selectedDescriptor)
            #expect(selected.availability.supportTier == .supported)
            #expect(selected.runtimeQualificationEvidence?.immutableArtifactSHA256
                == Self.linuxISOArtifactSHA256)
            #expect(selected.runtimeQualificationEvidence?.backendRuntimeBuildID
                == "dory-vz-2026.8")
        }
    }

    @Test("runtime inventory selection is order independent for mutable revision and runtime build")
    func runtimeInventoryMatchesExactMutableRecordInEitherOrder() throws {
        let exactProvenance = DoryMutableBootMediaProvenanceReference(
            repositoryIdentity: "dory-test-store",
            mediaIdentity: "linux-system-disk",
            revision: 7
        )
        let staleProvenance = DoryMutableBootMediaProvenanceReference(
            repositoryIdentity: "dory-test-store",
            mediaIdentity: "linux-system-disk",
            revision: 6
        )
        let exact = runtimeQualification(
            media: .virtualDisk,
            mutableProvenance: exactProvenance,
            backend: .appleVirtualizationFramework,
            runtimeBuildID: "dory-vz-2026.8"
        )
        let staleRevision = runtimeQualification(
            media: .virtualDisk,
            mutableProvenance: staleProvenance,
            backend: .appleVirtualizationFramework,
            runtimeBuildID: "dory-vz-2026.8"
        )
        let staleRuntime = runtimeQualification(
            media: .virtualDisk,
            mutableProvenance: exactProvenance,
            backend: .appleVirtualizationFramework,
            runtimeBuildID: "dory-vz-2026.7"
        )

        for inventory in [
            [staleRevision, staleRuntime, exact],
            [exact, staleRuntime, staleRevision],
        ] {
            let result = plan(
                family: .linux,
                media: .virtualDisk,
                graphics: [.software],
                trustedRuntimeQualifications: inventory
            )
            let selected = try #require(result.selectedDescriptor)
            #expect(selected.availability.supportTier == .supported)
            #expect(selected.runtimeQualificationEvidence?.mutableProvenance?.revision == 7)
            #expect(selected.runtimeQualificationEvidence?.backendRuntimeBuildID
                == "dory-vz-2026.8")
        }
    }

    @Test("planner carries the exact device request and rejects unsupported modes")
    func plannerNegotiatesDevices() throws {
        let minimum = plan(
            family: .linux,
            media: .virtualDisk,
            graphics: [.software]
        )
        let disconnected = plan(
            family: .linux,
            media: .virtualDisk,
            graphics: [.software],
            devices: DoryVirtualMachineDeviceCapabilityRequest(networkAttachment: .disconnected)
        )

        #expect(try #require(minimum.selectedDescriptor).resolvedDevices == .minimumBootable)
        #expect(disconnected.failure?.code == .noCandidate)
        #expect(disconnected.evaluatedDescriptors.allSatisfy {
            $0.availability.reason?.code == .networkAttachmentUnsupported
        })
    }

    @Test("legacy planner requests decode with conservative policy and device defaults")
    func legacyPlanRequestDecoding() throws {
        let data = Data(#"""
        {
          "guest":{"family":"linux","architecture":"arm64"},
          "bootMedia":{"kind":"virtual-disk","source":"user-provided"},
          "acceptableGraphics":["software"],
          "backendPreferences":["apple-virtualization-framework"],
          "allowsExperimentalBackends":false
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(
            DoryVirtualMachineBackendPlanRequest.self,
            from: data
        )

        #expect(decoded.devices == .minimumBootable)
        #expect(decoded.backendPreferencePolicy == .preferred)
    }

    private func plan(
        family: DoryGuestFamily,
        media: DoryBootMediaKind,
        source: DoryBootMediaSource = .userProvided,
        graphics: [DoryGraphicsAccelerationLevel],
        devices: DoryVirtualMachineDeviceCapabilityRequest = .minimumBootable,
        backends: [DoryVirtualizationBackendIdentity]? = nil,
        backendPolicy: DoryVirtualMachineBackendPreferencePolicy = .preferred,
        host: DoryAppleSiliconHostFacts = DoryVirtualMachineBackendPlannerTests.host,
        allowsExperimental: Bool = false,
        mediaArtifactSHA256: String? = nil,
        trustedGuestImageGraphicsQualification: DoryTrustedGuestImageGraphicsQualification? = nil,
        automaticallyTrustBootMedia: Bool = true,
        trustedBootMediaInspection: DoryTrustedBootMediaInspection? = nil,
        automaticallyResolveMutableProvenance: Bool = true,
        automaticallyQualifyRuntime: Bool = true,
        trustedRuntimeQualifications: [DoryTrustedVirtualMachineRuntimeQualification]? = nil
    ) -> DoryVirtualMachineBackendPlanResult {
        let resolvedArtifactSHA256 = mediaArtifactSHA256
            ?? defaultArtifactSHA256(family: family, media: media)
        let resolvedInspection = trustedBootMediaInspection
            ?? (automaticallyTrustBootMedia
                ? makeBootMediaInspection(
                    family: family,
                    media: media,
                    artifactSHA256: resolvedArtifactSHA256
                )
                : nil)
        let mutableProvenance = automaticallyResolveMutableProvenance && media == .virtualDisk
            ? DoryMutableBootMediaProvenanceReference(
                repositoryIdentity: "dory-test-store",
                mediaIdentity: "\(family.rawValue)-system-disk",
                revision: 7
            )
            : nil
        let trustedMutableProvenance = makeTrustedMutableProvenance(mutableProvenance)
        let planRequest = DoryVirtualMachineBackendPlanRequest(
            guest: DoryGuestPlatform(family: family, architecture: .arm64),
            bootMedia: DoryBootMedia(
                kind: media,
                source: source,
                artifactSHA256: resolvedArtifactSHA256,
                mutableProvenance: mutableProvenance
            ),
            acceptableGraphics: graphics,
            devices: devices,
            backendPreferences: backends,
            backendPreferencePolicy: backendPolicy,
            allowsExperimentalBackends: allowsExperimental
        )
        let resolvedRuntimeQualifications = trustedRuntimeQualifications
            ?? (automaticallyQualifyRuntime
                ? makeRuntimeQualifications(request: planRequest, host: host)
                : [])
        return DoryAppleSiliconVirtualMachineBackendPlanner.plan(
            planRequest,
            host: host,
            trustedGuestImageGraphicsQualification: trustedGuestImageGraphicsQualification,
            trustedBootMediaInspection: resolvedInspection,
            trustedMutableBootMediaProvenance: trustedMutableProvenance,
            trustedRuntimeQualifications: resolvedRuntimeQualifications
        )
    }

    private func defaultArtifactSHA256(
        family: DoryGuestFamily,
        media: DoryBootMediaKind
    ) -> String? {
        switch (family, media) {
        case (.linux, .installerISO):
            Self.linuxISOArtifactSHA256
        case (.windows, .installerISO):
            Self.windowsISOArtifactSHA256
        case (.macOS, .macOSRestoreImage):
            Self.macOSRestoreArtifactSHA256
        default:
            nil
        }
    }

    private func makeBootMediaInspection(
        family: DoryGuestFamily,
        media: DoryBootMediaKind,
        artifactSHA256: String?
    ) -> DoryTrustedBootMediaInspection? {
        guard media == .installerISO || media == .macOSRestoreImage,
              let artifactSHA256 else {
            return nil
        }
        return DoryTrustedBootMediaInspection(
            auditEvidence: DoryBootMediaInspectionAuditEvidence(
                inspectionIdentity: "inspection-\(family.rawValue)-\(media.rawValue)",
                artifactSHA256: artifactSHA256,
                inspectionReportSHA256: Self.inspectionReportSHA256,
                inspectorID: "dory-media-inspector",
                inspectorVersion: 1
            ),
            detectedKind: media,
            detectedGuestFamily: family,
            detectedArchitecture: .arm64,
            isEFIBootable: true,
            macOSBuildIdentifier: family == .macOS ? "25A123" : nil,
            macOSHardwareModelCompatible: family == .macOS,
            macOSAuxiliaryStorageCompatible: family == .macOS
        )
    }

    private func makeTrustedMutableProvenance(
        _ provenance: DoryMutableBootMediaProvenanceReference?
    ) -> DoryTrustedMutableBootMediaProvenance? {
        guard let provenance else { return nil }
        return DoryTrustedMutableBootMediaProvenance(
            auditEvidence: DoryMutableBootMediaProvenanceAuditEvidence(
                receiptIdentity: "mutable-disk-receipt-\(provenance.mediaIdentity)",
                provenance: provenance,
                receiptSHA256: Self.provenanceReceiptSHA256,
                resolverID: "dory-artifact-resolver",
                resolverVersion: 1
            )
        )
    }

    private func makeRuntimeQualifications(
        request: DoryVirtualMachineBackendPlanRequest,
        host: DoryAppleSiliconHostFacts
    ) -> [DoryTrustedVirtualMachineRuntimeQualification] {
        guard request.guest.family == .linux,
              let hostContext = host.runtimeQualificationContext else {
            return []
        }
        return request.acceptableGraphics.flatMap { graphics in
            DoryVirtualizationBackendIdentity.allCases.compactMap { backend in
                let immutableArtifactSHA256 = request.bootMedia.kind == .virtualDisk
                    ? nil : request.bootMedia.artifactSHA256
                guard immutableArtifactSHA256 != nil
                        || request.bootMedia.mutableProvenance != nil else {
                    return nil
                }
                return DoryTrustedVirtualMachineRuntimeQualification(
                    auditEvidence: DoryVirtualMachineRuntimeQualificationEvidence(
                        qualificationIdentity: "linux-runtime-qualification-v1",
                        qualificationReportSHA256: Self.runtimeQualificationReportSHA256,
                        signingKeyID: "dory-runtime-qualification-2026",
                        qualificationFormatVersion: 1,
                        guest: request.guest,
                        bootMediaKind: request.bootMedia.kind,
                        immutableArtifactSHA256: immutableArtifactSHA256,
                        mutableProvenance: request.bootMedia.kind == .virtualDisk
                            ? request.bootMedia.mutableProvenance : nil,
                        backend: backend,
                        backendRuntimeBuildID: hostContext.runtimeBuildID(for: backend),
                        virtualHardwareABIVersion: request.virtualHardwareABIVersion,
                        graphics: graphics,
                        devices: request.devices
                    ),
                    runtimeQualified: true
                )
            }
        }
    }

    private func runtimeQualification(
        media: DoryBootMediaKind,
        immutableArtifactSHA256: String? = nil,
        mutableProvenance: DoryMutableBootMediaProvenanceReference? = nil,
        backend: DoryVirtualizationBackendIdentity,
        runtimeBuildID: String
    ) -> DoryTrustedVirtualMachineRuntimeQualification {
        DoryTrustedVirtualMachineRuntimeQualification(
            auditEvidence: DoryVirtualMachineRuntimeQualificationEvidence(
                qualificationIdentity: "linux-runtime-qualification-v1",
                qualificationReportSHA256: Self.runtimeQualificationReportSHA256,
                signingKeyID: "dory-runtime-qualification-2026",
                qualificationFormatVersion: 1,
                guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
                bootMediaKind: media,
                immutableArtifactSHA256: immutableArtifactSHA256,
                mutableProvenance: mutableProvenance,
                backend: backend,
                backendRuntimeBuildID: runtimeBuildID,
                virtualHardwareABIVersion: 1,
                graphics: .software,
                devices: .minimumBootable
            ),
            runtimeQualified: true
        )
    }
}
