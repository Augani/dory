import Foundation
import Testing
@testable import DoryOperations

@Suite("Virtual machine capability negotiation")
struct VirtualMachineCapabilitiesTests {
    private static let guestArtifactSHA256 = String(repeating: "a", count: 64)
    private static let linuxISOArtifactSHA256 = String(repeating: "b", count: 64)
    private static let windowsISOArtifactSHA256 = String(repeating: "c", count: 64)
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

    private static let provisionedHost = DoryAppleSiliconHostFacts(
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

    @Test("installed Linux ARM64 with native 3D is supported when all components are present")
    func linuxNative3DIsSupported() {
        let descriptor = evaluate(
            family: .linux,
            media: .installedLinuxBootBundle,
            source: .userProvided,
            backend: .doryHypervisor,
            graphics: .hardwareAccelerated3D,
            mediaArtifactSHA256: Self.guestArtifactSHA256,
            trustedGuestImageGraphicsQualification: Self.qualifiedLinuxGraphics
        )

        #expect(descriptor.schemaVersion == 2)
        #expect(descriptor.evaluatorVersion == 2)
        #expect(descriptor.availability.supportTier == .supported)
        #expect(descriptor.availability.state == .available)
        #expect(descriptor.availability.reason == nil)
        #expect(descriptor.availability.isUsable)
        #expect(descriptor.graphicsQualificationEvidence
            == Self.qualifiedLinuxGraphics.auditEvidence)
        #expect(descriptor.runtimeQualificationEvidence?.backend == .doryHypervisor)
    }

    @Test("host renderer facts cannot authorize an unqualified Linux guest image")
    func linux3DRequiresExactSignedGuestQualification() {
        let missing = evaluate(
            family: .linux,
            media: .installedLinuxBootBundle,
            source: .userProvided,
            backend: .doryHypervisor,
            graphics: .hardwareAccelerated3D
        )
        let invalidArtifactIdentity = evaluateLinux3D(
            mediaArtifactSHA256: "not-a-sha256",
            trustedQualification: Self.qualifiedLinuxGraphics
        )
        let missingManifestIdentity = trustedQualification(signedManifestIdentity: "")
        let invalidManifestDigest = trustedQualification(manifestSHA256: "invalid")
        let mismatched = trustedQualification(
            qualifiedArtifactSHA256: String(repeating: "b", count: 64)
        )
        let noVirtioGPU = trustedQualification(virtioGPUQualified: false)
        let noVenus = trustedQualification(venusVulkanQualified: false)

        #expect(missing.availability.reason?.code == .guestImageArtifactDigestUnavailable)
        #expect(invalidArtifactIdentity.availability.reason?.code
            == .bootMediaArtifactDigestInvalid)
        #expect(evaluateLinux3D(trustedQualification: missingManifestIdentity).availability.reason?.code
            == .guestImageQualificationAuditEvidenceInvalid)
        #expect(evaluateLinux3D(trustedQualification: invalidManifestDigest).availability.reason?.code
            == .guestImageQualificationAuditEvidenceInvalid)
        #expect(evaluateLinux3D(trustedQualification: mismatched).availability.reason?.code
            == .guestImageArtifactQualificationMismatch)
        #expect(evaluateLinux3D(trustedQualification: noVirtioGPU).availability.reason?.code
            == .linuxVirtioGPUKernelDeviceUnqualified)
        #expect(evaluateLinux3D(trustedQualification: noVenus).availability.reason?.code
            == .linuxVenusVulkanRuntimeUnqualified)
        #expect(evaluateLinux3D(
            trustedQualification: Self.qualifiedLinuxGraphics
        ).availability.isUsable)
    }

    @Test("caller-authored qualification fields cannot cross the request trust boundary")
    func spoofedRequestQualificationIsIgnored() throws {
        let request = DoryVirtualMachineCapabilityRequest(
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            bootMedia: DoryBootMedia(
                kind: .installedLinuxBootBundle,
                source: .userProvided,
                artifactSHA256: Self.guestArtifactSHA256
            ),
            backend: .doryHypervisor,
            graphics: .hardwareAccelerated3D
        )
        let encoded = try JSONEncoder().encode(request)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["guestImageGraphicsQualification"] = [
            "manifestSignatureVerified": true,
            "qualifiedArtifactSHA256": Self.guestArtifactSHA256,
            "virtioGPUKernelAndDeviceSupportQualified": true,
            "venusVulkanGuestRuntimeQualified": true,
        ]
        let spoofed = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            DoryVirtualMachineCapabilityRequest.self,
            from: spoofed
        )
        let descriptor = DoryAppleSiliconCapabilityEvaluator.evaluate(
            decoded,
            host: Self.provisionedHost
        )

        #expect(descriptor.availability.reason?.code
            == .trustedGuestImageGraphicsQualificationUnavailable)
    }

    @Test("native hypervisor only accepts the post-install direct-boot bundle")
    func nativeHypervisorRejectsInstallerISO() {
        let native = evaluate(
            family: .linux,
            media: .installerISO,
            source: .userProvided,
            backend: .doryHypervisor,
            graphics: .software
        )
        let installer = evaluate(
            family: .linux,
            media: .installerISO,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software
        )

        #expect(native.availability.reason?.code == .bootMediaDoesNotSupportBackend)
        #expect(!native.availability.isUsable)
        #expect(installer.availability.isUsable)
    }

    @Test("Apple Silicon never labels x86_64 execution as virtualization")
    func x86RequiresEmulation() {
        let descriptor = evaluate(
            family: .linux,
            architecture: .x86_64,
            media: .installerISO,
            source: .userProvided,
            backend: .qemuHypervisorFramework,
            graphics: .software
        )

        #expect(descriptor.availability.supportTier == .unsupported)
        #expect(descriptor.availability.state == .unavailable)
        #expect(descriptor.availability.reason?.code == .guestArchitectureRequiresEmulation)
        #expect(!descriptor.availability.isUsable)
    }

    @Test("Windows ARM64 is explicitly experimental and never promises 3D")
    func windowsSupportBoundaries() {
        let experimental = evaluate(
            family: .windows,
            media: .installerISO,
            source: .userProvided,
            backend: .qemuHypervisorFramework,
            graphics: .hostAcceleratedDisplay
        )
        let threeD = evaluate(
            family: .windows,
            media: .virtualDisk,
            source: .userProvided,
            backend: .qemuHypervisorFramework,
            graphics: .hardwareAccelerated3D
        )

        #expect(experimental.availability.supportTier == .experimental)
        #expect(experimental.availability.state == .available)
        #expect(experimental.availability.reason?.code == .windowsSupportIsExperimental)
        #expect(experimental.availability.isUsable)
        #expect(threeD.availability.supportTier == .unsupported)
        #expect(threeD.availability.reason?.code == .windows3DAccelerationUnsupported)
        #expect(!threeD.availability.isUsable)
    }

    @Test("Windows support does not leak onto backends that cannot boot it")
    func windowsRequiresQEMUBackend() {
        let descriptor = evaluate(
            family: .windows,
            media: .installerISO,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software
        )

        #expect(descriptor.availability.supportTier == .unsupported)
        #expect(descriptor.availability.reason?.code == .backendDoesNotSupportGuest)
    }

    @Test("macOS media is vendor or user supplied, never Dory redistributed")
    func macOSMediaProvenance() {
        let bundled = evaluate(
            family: .macOS,
            media: .macOSRestoreImage,
            source: .bundledByDory,
            backend: .appleVirtualizationFramework,
            graphics: .hardwareAccelerated3D
        )
        let vendor = evaluate(
            family: .macOS,
            media: .macOSRestoreImage,
            source: .vendorDownload,
            backend: .appleVirtualizationFramework,
            graphics: .hardwareAccelerated3D
        )

        #expect(bundled.availability.supportTier == .unsupported)
        #expect(bundled.availability.reason?.code == .guestMediaRedistributionUnavailable)
        #expect(vendor.availability.supportTier == .experimental)
        #expect(vendor.availability.state == .available)
    }

    @Test("Windows installation media is never represented as Dory redistributable")
    func windowsMediaProvenance() {
        let descriptor = evaluate(
            family: .windows,
            media: .installerISO,
            source: .bundledByDory,
            backend: .qemuHypervisorFramework,
            graphics: .software
        )

        #expect(descriptor.availability.supportTier == .unsupported)
        #expect(descriptor.availability.reason?.code == .guestMediaRedistributionUnavailable)
    }

    @Test("guest-specific boot formats are rejected before host probing")
    func bootMediaCompatibility() {
        let windowsKernel = evaluate(
            family: .windows,
            media: .installedLinuxBootBundle,
            source: .userProvided,
            backend: .qemuHypervisorFramework,
            graphics: .software
        )
        let linuxRestore = evaluate(
            family: .linux,
            media: .macOSRestoreImage,
            source: .vendorDownload,
            backend: .doryHypervisor,
            graphics: .software
        )

        #expect(windowsKernel.availability.reason?.code == .bootMediaDoesNotSupportGuest)
        #expect(linuxRestore.availability.reason?.code == .bootMediaDoesNotSupportGuest)
    }

    @Test("missing renderer blocks accelerated native graphics but not software graphics")
    func rendererAvailabilityIsExact() {
        var host = Self.provisionedHost
        host.doryAcceleratedRendererAvailable = false

        let accelerated = evaluate(
            family: .linux,
            media: .installedLinuxBootBundle,
            source: .userProvided,
            backend: .doryHypervisor,
            graphics: .hardwareAccelerated3D,
            host: host,
            mediaArtifactSHA256: Self.guestArtifactSHA256,
            trustedGuestImageGraphicsQualification: Self.qualifiedLinuxGraphics
        )
        let software = evaluate(
            family: .linux,
            media: .installedLinuxBootBundle,
            source: .userProvided,
            backend: .doryHypervisor,
            graphics: .software,
            host: host,
            mediaArtifactSHA256: Self.guestArtifactSHA256,
            trustedGuestImageGraphicsQualification: Self.qualifiedLinuxGraphics
        )

        #expect(accelerated.availability.supportTier == .supported)
        #expect(accelerated.availability.state == .unavailable)
        #expect(accelerated.availability.reason?.code == .acceleratedRendererUnavailable)
        #expect(software.availability.isUsable)
    }

    @Test("host facts distinguish product support from local component availability")
    func backendComponentAvailability() {
        var host = Self.provisionedHost
        host.qemuHypervisorFrameworkAvailable = false

        let descriptor = evaluate(
            family: .windows,
            media: .installerISO,
            source: .userProvided,
            backend: .qemuHypervisorFramework,
            graphics: .software,
            host: host
        )

        #expect(descriptor.availability.supportTier == .experimental)
        #expect(descriptor.availability.state == .unavailable)
        #expect(descriptor.availability.reason?.code == .backendComponentUnavailable)
    }

    @Test("Windows requires a complete qualified boot and driver stack")
    func windowsRequiresCompleteRuntime() {
        var noFirmware = Self.provisionedHost
        noFirmware.windowsUEFIFirmwareAvailable = false
        var noDeviceModel = Self.provisionedHost
        noDeviceModel.windowsSBSADeviceModelAvailable = false
        var noSecureBoot = Self.provisionedHost
        noSecureBoot.windowsSecureBootAvailable = false
        var noTPM = Self.provisionedHost
        noTPM.virtualTPM20Available = false
        var noStorage = Self.provisionedHost
        noStorage.windowsGuestDrivers.storageAvailable = false
        var noNetwork = Self.provisionedHost
        noNetwork.windowsGuestDrivers.networkAvailable = false
        var noDisplay = Self.provisionedHost
        noDisplay.windowsGuestDrivers.displayAvailable = false
        var noInput = Self.provisionedHost
        noInput.windowsGuestDrivers.inputAvailable = false

        #expect(windows(host: noFirmware).availability.reason?.code == .windowsUEFIFirmwareUnavailable)
        #expect(windows(host: noSecureBoot).availability.reason?.code == .windowsSecureBootUnavailable)
        #expect(windows(host: noDeviceModel).availability.reason?.code == .windowsSBSADeviceModelUnavailable)
        #expect(windows(host: noTPM).availability.reason?.code == .virtualTPM20Unavailable)
        #expect(windows(host: noStorage).availability.reason?.code == .windowsStorageDriverUnavailable)
        #expect(windows(host: noNetwork).availability.reason?.code == .windowsNetworkDriverUnavailable)
        #expect(windows(host: noDisplay).availability.reason?.code == .windowsDisplayDriverUnavailable)
        #expect(windows(host: noInput).availability.reason?.code == .windowsInputDriverUnavailable)
    }

    @Test("macOS availability requires host-qualified VZMac and restore-image support")
    func macOSHostQualification() {
        var noPlatform = Self.provisionedHost
        noPlatform.macOSGuestVirtualizationSupported = false
        var noRestore = Self.provisionedHost
        noRestore.macOSRestoreImageInstallationSupported = false

        let platform = evaluate(
            family: .macOS,
            media: .macOSRestoreImage,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            host: noPlatform
        )
        let restore = evaluate(
            family: .macOS,
            media: .macOSRestoreImage,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            host: noRestore
        )

        #expect(platform.availability.reason?.code == .macOSGuestVirtualizationUnavailable)
        #expect(restore.availability.reason?.code == .macOSRestoreImageUnsupported)
    }

    @Test("Apple host support cannot substitute for Dory's qualified VZMac adapter")
    func macOSRequiresQualifiedDoryAdapter() {
        var noAdapter = Self.provisionedHost
        noAdapter.doryMacOSBackendAvailable = false
        var unqualified = Self.provisionedHost
        unqualified.doryMacOSBackendQualified = false

        let absent = evaluate(
            family: .macOS,
            media: .macOSRestoreImage,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            host: noAdapter
        )
        let notQualified = evaluate(
            family: .macOS,
            media: .macOSRestoreImage,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            host: unqualified
        )

        #expect(absent.availability.supportTier == .experimental)
        #expect(absent.availability.state == .unavailable)
        #expect(absent.availability.reason?.code == .backendComponentUnavailable)
        #expect(notQualified.availability.reason?.code == .backendComponentUnqualified)
    }

    @Test("native backend host requirements are deterministic")
    func nativeBackendHostRequirements() {
        var oldHost = Self.provisionedHost
        oldHost.macOSMajorVersion = 14
        let oldOS = evaluate(
            family: .linux,
            media: .installedLinuxBootBundle,
            source: .userProvided,
            backend: .doryHypervisor,
            graphics: .software,
            host: oldHost,
            mediaArtifactSHA256: Self.guestArtifactSHA256,
            trustedGuestImageGraphicsQualification: Self.qualifiedLinuxGraphics
        )

        var noHypervisor = Self.provisionedHost
        noHypervisor.hypervisorFrameworkAvailable = false
        let noFramework = evaluate(
            family: .linux,
            media: .installedLinuxBootBundle,
            source: .userProvided,
            backend: .doryHypervisor,
            graphics: .software,
            host: noHypervisor,
            mediaArtifactSHA256: Self.guestArtifactSHA256,
            trustedGuestImageGraphicsQualification: Self.qualifiedLinuxGraphics
        )

        #expect(oldOS.availability.reason?.code == .hostOperatingSystemUnsupported)
        #expect(noFramework.availability.reason?.code == .hypervisorFrameworkUnavailable)
    }

    @Test("capability descriptors have stable Codable round trips")
    func codableRoundTrip() throws {
        let descriptor = evaluate(
            family: .macOS,
            media: .macOSRestoreImage,
            source: .vendorDownload,
            backend: .appleVirtualizationFramework,
            graphics: .hardwareAccelerated3D
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(descriptor)
        let decoded = try JSONDecoder().decode(
            DoryVirtualMachineCapabilityDescriptor.self,
            from: encoded
        )
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(decoded == descriptor)
        #expect(json.contains(#""schemaVersion":2"#))
        #expect(json.contains(#""family":"macos""#))
        #expect(json.contains(#""kind":"macos-restore-image""#))
        #expect(json.contains(#""backend":"apple-virtualization-framework""#))
        #expect(json.contains(#""graphics":"hardware-accelerated-3d""#))
        #expect(decoded.bootMediaInspectionEvidence?.artifactSHA256
            == Self.macOSRestoreArtifactSHA256)
    }

    @Test("qualified graphics audit evidence survives descriptor persistence")
    func graphicsAuditEvidenceRoundTrip() throws {
        let descriptor = evaluateLinux3D(
            trustedQualification: Self.qualifiedLinuxGraphics
        )
        let encoded = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(
            DoryVirtualMachineCapabilityDescriptor.self,
            from: encoded
        )

        #expect(decoded.graphicsQualificationEvidence
            == Self.qualifiedLinuxGraphics.auditEvidence)
        #expect(decoded.graphicsQualificationEvidence?.artifactSHA256
            == Self.guestArtifactSHA256)
        #expect(decoded.graphicsQualificationEvidence?.manifestSHA256
            == Self.manifestSHA256)
        #expect(decoded.graphicsQualificationEvidence?.signingKeyID == "dory-release-2026")
        #expect(decoded.graphicsQualificationEvidence?.manifestFormatVersion == 1)
        #expect(decoded.runtimeQualificationEvidence?.backendRuntimeBuildID
            == "dory-hv-2026.8")
        #expect(decoded.runtimeQualificationEvidence?.virtualHardwareABIVersion == 1)
    }

    @Test("raw-HV graphical modes require digest-bound virtio-gpu qualification")
    func everyRawGraphicalModeRequiresGuestDriverQualification() {
        for graphics in [
            DoryGraphicsAccelerationLevel.software,
            .hostAcceleratedDisplay,
            .hardwareAccelerated3D,
        ] {
            let descriptor = evaluate(
                family: .linux,
                media: .installedLinuxBootBundle,
                source: .userProvided,
                backend: .doryHypervisor,
                graphics: graphics,
                mediaArtifactSHA256: Self.guestArtifactSHA256,
                automaticallyTrustGuestGraphics: false
            )
            #expect(descriptor.availability.reason?.code
                == .trustedGuestImageGraphicsQualificationUnavailable)
        }

        let noVirtio = trustedQualification(virtioGPUQualified: false)
        let software = evaluate(
            family: .linux,
            media: .installedLinuxBootBundle,
            source: .userProvided,
            backend: .doryHypervisor,
            graphics: .software,
            mediaArtifactSHA256: Self.guestArtifactSHA256,
            trustedGuestImageGraphicsQualification: noVirtio,
            automaticallyTrustGuestGraphics: false
        )
        let noVenus = trustedQualification(venusVulkanQualified: false)
        let hostDisplay = evaluate(
            family: .linux,
            media: .installedLinuxBootBundle,
            source: .userProvided,
            backend: .doryHypervisor,
            graphics: .hostAcceleratedDisplay,
            mediaArtifactSHA256: Self.guestArtifactSHA256,
            trustedGuestImageGraphicsQualification: noVenus,
            automaticallyTrustGuestGraphics: false
        )

        #expect(software.availability.reason?.code == .linuxVirtioGPUKernelDeviceUnqualified)
        #expect(hostDisplay.availability.isUsable)
    }

    @Test("all supplied media digests are validated before backend availability")
    func malformedDigestFailsForVZSoftware() {
        let descriptor = evaluate(
            family: .linux,
            media: .virtualDisk,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            mediaArtifactSHA256: "spoof"
        )

        #expect(descriptor.availability.reason?.code == .bootMediaArtifactDigestInvalid)
        #expect(!descriptor.availability.isUsable)
    }

    @Test("structural ISO inspection never implies supported runtime compatibility")
    func structuralISOWithoutRuntimeQualificationIsExperimental() {
        let descriptor = evaluate(
            family: .linux,
            media: .installerISO,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            automaticallyQualifyRuntime: false
        )

        #expect(descriptor.availability.supportTier == .experimental)
        #expect(descriptor.availability.state == .available)
        #expect(descriptor.availability.reason?.code == .runtimeQualificationUnavailable)
        #expect(descriptor.bootMediaInspectionEvidence?.artifactSHA256
            == Self.linuxISOArtifactSHA256)
        #expect(descriptor.runtimeQualificationEvidence == nil)
    }

    @Test("runtime qualification is exact to backend build and virtual-device ABI")
    func runtimeQualificationCannotCrossRuntimeContexts() throws {
        let request = DoryVirtualMachineCapabilityRequest(
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            bootMedia: DoryBootMedia(
                kind: .installerISO,
                source: .userProvided,
                artifactSHA256: Self.linuxISOArtifactSHA256
            ),
            backend: .appleVirtualizationFramework,
            graphics: .software,
            devices: .minimumBootable,
            virtualHardwareABIVersion: 1
        )
        let valid = try #require(makeRuntimeQualification(
            request: request,
            host: Self.provisionedHost
        ))
        var wrongBuildEvidence = valid.auditEvidence
        wrongBuildEvidence.backendRuntimeBuildID = "other-vz-build"
        var wrongABIEvidence = valid.auditEvidence
        wrongABIEvidence.virtualHardwareABIVersion = 2
        let inspection = makeBootMediaInspection(
            family: .linux,
            architecture: .arm64,
            media: .installerISO,
            artifactSHA256: Self.linuxISOArtifactSHA256
        )

        let wrongBuild = DoryAppleSiliconCapabilityEvaluator.evaluate(
            request,
            host: Self.provisionedHost,
            trustedBootMediaInspection: inspection,
            trustedRuntimeQualification: DoryTrustedVirtualMachineRuntimeQualification(
                auditEvidence: wrongBuildEvidence,
                runtimeQualified: true
            )
        )
        let wrongABI = DoryAppleSiliconCapabilityEvaluator.evaluate(
            request,
            host: Self.provisionedHost,
            trustedBootMediaInspection: inspection,
            trustedRuntimeQualification: DoryTrustedVirtualMachineRuntimeQualification(
                auditEvidence: wrongABIEvidence,
                runtimeQualified: true
            )
        )

        #expect(wrongBuild.availability.reason?.code == .runtimeQualificationHostMismatch)
        #expect(wrongABI.availability.reason?.code == .runtimeQualificationRequestMismatch)
        #expect(!wrongBuild.availability.isUsable)
        #expect(!wrongABI.availability.isUsable)
    }

    @Test("a content digest cannot replace daemon provenance for a mutable disk")
    func mutableDiskRequiresTrustedRevisionProvenance() {
        let digestOnly = evaluate(
            family: .linux,
            media: .virtualDisk,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            mediaArtifactSHA256: String(repeating: "8", count: 64),
            automaticallyResolveMutableProvenance: false,
            automaticallyQualifyRuntime: false
        )
        let provenanceButUnqualified = evaluate(
            family: .linux,
            media: .virtualDisk,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            automaticallyQualifyRuntime: false
        )

        #expect(digestOnly.availability.reason?.code
            == .mutableBootMediaProvenanceUnavailable)
        #expect(!digestOnly.availability.isUsable)
        #expect(provenanceButUnqualified.availability.supportTier == .experimental)
        #expect(provenanceButUnqualified.availability.reason?.code
            == .runtimeQualificationUnavailable)
        #expect(provenanceButUnqualified.mutableBootMediaProvenanceEvidence?.provenance.revision
            == 7)
    }

    @Test("installer media architecture and EFI bootability come from trusted inspection")
    func installerInspectionIsAuthoritative() {
        let x86Inspection = makeBootMediaInspection(
            family: .linux,
            architecture: .x86_64,
            media: .installerISO,
            artifactSHA256: Self.linuxISOArtifactSHA256
        )
        var nonEFI = try! #require(makeBootMediaInspection(
            family: .linux,
            architecture: .arm64,
            media: .installerISO,
            artifactSHA256: Self.linuxISOArtifactSHA256
        ))
        nonEFI = DoryTrustedBootMediaInspection(
            auditEvidence: nonEFI.auditEvidence,
            detectedKind: nonEFI.detectedKind,
            detectedGuestFamily: nonEFI.detectedGuestFamily,
            detectedArchitecture: nonEFI.detectedArchitecture,
            isEFIBootable: false
        )

        let mislabeled = evaluate(
            family: .linux,
            media: .installerISO,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            automaticallyTrustBootMedia: false,
            trustedBootMediaInspection: x86Inspection
        )
        let unbootable = evaluate(
            family: .linux,
            media: .installerISO,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            automaticallyTrustBootMedia: false,
            trustedBootMediaInspection: nonEFI
        )
        let uninspected = evaluate(
            family: .linux,
            media: .installerISO,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            automaticallyTrustBootMedia: false
        )

        #expect(mislabeled.availability.reason?.code
            == .bootMediaArchitectureInspectionMismatch)
        #expect(unbootable.availability.reason?.code == .bootMediaNotEFIBootable)
        #expect(uninspected.availability.reason?.code == .trustedBootMediaInspectionUnavailable)
    }

    @Test("macOS restore compatibility is bound to the exact inspected artifact")
    func macOSRestoreInspectionIsExact() {
        let mismatched = makeBootMediaInspection(
            family: .macOS,
            architecture: .arm64,
            media: .macOSRestoreImage,
            artifactSHA256: String(repeating: "9", count: 64)
        )
        let incompatible = DoryTrustedBootMediaInspection(
            auditEvidence: DoryBootMediaInspectionAuditEvidence(
                inspectionIdentity: "macos-restore-inspection",
                artifactSHA256: Self.macOSRestoreArtifactSHA256,
                inspectionReportSHA256: Self.inspectionReportSHA256,
                inspectorID: "dory-media-inspector",
                inspectorVersion: 1
            ),
            detectedKind: .macOSRestoreImage,
            detectedGuestFamily: .macOS,
            detectedArchitecture: .arm64,
            isEFIBootable: true,
            macOSBuildIdentifier: "25A123",
            macOSHardwareModelCompatible: false,
            macOSAuxiliaryStorageCompatible: true
        )

        let mismatchResult = evaluate(
            family: .macOS,
            media: .macOSRestoreImage,
            source: .vendorDownload,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            automaticallyTrustBootMedia: false,
            trustedBootMediaInspection: mismatched
        )
        let incompatibleResult = evaluate(
            family: .macOS,
            media: .macOSRestoreImage,
            source: .vendorDownload,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            automaticallyTrustBootMedia: false,
            trustedBootMediaInspection: incompatible
        )

        #expect(mismatchResult.availability.reason?.code
            == .bootMediaArtifactInspectionMismatch)
        #expect(incompatibleResult.availability.reason?.code
            == .macOSRestoreHardwareModelIncompatible)
    }

    @Test("device contract is exact and unsupported modes fail closed")
    func deviceCapabilitiesAreNegotiated() {
        let resolved = evaluate(
            family: .linux,
            media: .virtualDisk,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            devices: .minimumBootable
        )
        let disconnected = evaluate(
            family: .linux,
            media: .virtualDisk,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            devices: DoryVirtualMachineDeviceCapabilityRequest(networkAttachment: .disconnected)
        )
        let spoofedGuestTools = evaluate(
            family: .linux,
            media: .virtualDisk,
            source: .userProvided,
            backend: .appleVirtualizationFramework,
            graphics: .software,
            devices: DoryVirtualMachineDeviceCapabilityRequest(directorySharing: true)
        )

        #expect(resolved.resolvedDevices == .minimumBootable)
        #expect(disconnected.availability.reason?.code == .networkAttachmentUnsupported)
        #expect(spoofedGuestTools.availability.reason?.code == .directorySharingUnsupported)
    }

    @Test("version-one descriptor JSON remains readable with conservative device defaults")
    func versionOneDescriptorDecoding() throws {
        let data = Data(#"""
        {
          "schemaVersion":1,
          "evaluatorVersion":1,
          "request":{
            "guest":{"family":"linux","architecture":"arm64"},
            "bootMedia":{"kind":"virtual-disk","source":"user-provided"},
            "backend":"apple-virtualization-framework",
            "graphics":"software"
          },
          "availability":{"supportTier":"supported","state":"available"}
        }
        """#.utf8)
        let descriptor = try JSONDecoder().decode(
            DoryVirtualMachineCapabilityDescriptor.self,
            from: data
        )

        #expect(descriptor.schemaVersion == 1)
        #expect(descriptor.request.devices == .minimumBootable)
        #expect(descriptor.resolvedDevices == nil)
        #expect(descriptor.graphicsQualificationEvidence == nil)
        #expect(descriptor.bootMediaInspectionEvidence == nil)
    }

    private func evaluate(
        family: DoryGuestFamily,
        architecture: DoryGuestArchitecture = .arm64,
        media: DoryBootMediaKind,
        source: DoryBootMediaSource,
        backend: DoryVirtualizationBackendIdentity,
        graphics: DoryGraphicsAccelerationLevel,
        host: DoryAppleSiliconHostFacts = provisionedHost,
        mediaArtifactSHA256: String? = nil,
        trustedGuestImageGraphicsQualification: DoryTrustedGuestImageGraphicsQualification? = nil,
        automaticallyTrustGuestGraphics: Bool = true,
        devices: DoryVirtualMachineDeviceCapabilityRequest = .minimumBootable,
        automaticallyTrustBootMedia: Bool = true,
        trustedBootMediaInspection: DoryTrustedBootMediaInspection? = nil,
        automaticallyResolveMutableProvenance: Bool = true,
        mutableProvenance: DoryMutableBootMediaProvenanceReference? = nil,
        trustedMutableProvenance: DoryTrustedMutableBootMediaProvenance? = nil,
        automaticallyQualifyRuntime: Bool = true,
        trustedRuntimeQualification: DoryTrustedVirtualMachineRuntimeQualification? = nil
    ) -> DoryVirtualMachineCapabilityDescriptor {
        let resolvedArtifactSHA256 = mediaArtifactSHA256
            ?? defaultArtifactSHA256(family: family, media: media)
        let resolvedInspection = trustedBootMediaInspection
            ?? (automaticallyTrustBootMedia
                ? makeBootMediaInspection(
                    family: family,
                    architecture: architecture,
                    media: media,
                    artifactSHA256: resolvedArtifactSHA256
                )
                : nil)
        let resolvedGraphicsQualification = trustedGuestImageGraphicsQualification
            ?? (automaticallyTrustGuestGraphics
                && family == .linux
                && backend == .doryHypervisor
                && graphics != .none
                && resolvedArtifactSHA256 == Self.guestArtifactSHA256
                ? Self.qualifiedLinuxGraphics
                : nil)
        let resolvedMutableProvenance = mutableProvenance
            ?? (automaticallyResolveMutableProvenance && media == .virtualDisk
                ? DoryMutableBootMediaProvenanceReference(
                    repositoryIdentity: "dory-test-store",
                    mediaIdentity: "\(family.rawValue)-system-disk",
                    revision: 7
                )
                : nil)
        let resolvedTrustedMutableProvenance = trustedMutableProvenance
            ?? (automaticallyResolveMutableProvenance
                ? makeTrustedMutableProvenance(resolvedMutableProvenance)
                : nil)
        let request = DoryVirtualMachineCapabilityRequest(
            guest: DoryGuestPlatform(family: family, architecture: architecture),
            bootMedia: DoryBootMedia(
                kind: media,
                source: source,
                artifactSHA256: resolvedArtifactSHA256,
                mutableProvenance: resolvedMutableProvenance
            ),
            backend: backend,
            graphics: graphics,
            devices: devices
        )
        let resolvedRuntimeQualification = trustedRuntimeQualification
            ?? (automaticallyQualifyRuntime
                ? makeRuntimeQualification(request: request, host: host)
                : nil)
        return DoryAppleSiliconCapabilityEvaluator.evaluate(
            request,
            host: host,
            trustedGuestImageGraphicsQualification: resolvedGraphicsQualification,
            trustedBootMediaInspection: resolvedInspection,
            trustedMutableBootMediaProvenance: resolvedTrustedMutableProvenance,
            trustedRuntimeQualification: resolvedRuntimeQualification
        )
    }

    private func windows(
        host: DoryAppleSiliconHostFacts
    ) -> DoryVirtualMachineCapabilityDescriptor {
        evaluate(
            family: .windows,
            media: .installerISO,
            source: .userProvided,
            backend: .qemuHypervisorFramework,
            graphics: .software,
            host: host
        )
    }

    private func evaluateLinux3D(
        mediaArtifactSHA256: String = guestArtifactSHA256,
        trustedQualification: DoryTrustedGuestImageGraphicsQualification?
    ) -> DoryVirtualMachineCapabilityDescriptor {
        evaluate(
            family: .linux,
            media: .installedLinuxBootBundle,
            source: .userProvided,
            backend: .doryHypervisor,
            graphics: .hardwareAccelerated3D,
            mediaArtifactSHA256: mediaArtifactSHA256,
            trustedGuestImageGraphicsQualification: trustedQualification,
            automaticallyTrustGuestGraphics: false
        )
    }

    private func trustedQualification(
        signedManifestIdentity: String = "dory-linux-desktop-arm64-gpu-v1",
        qualifiedArtifactSHA256: String = guestArtifactSHA256,
        manifestSHA256: String = manifestSHA256,
        signingKeyID: String = "dory-release-2026",
        manifestFormatVersion: UInt16 = 1,
        virtioGPUQualified: Bool = true,
        venusVulkanQualified: Bool = true
    ) -> DoryTrustedGuestImageGraphicsQualification {
        DoryTrustedGuestImageGraphicsQualification(
            auditEvidence: DorySignedArtifactQualificationEvidence(
                manifestIdentity: signedManifestIdentity,
                artifactSHA256: qualifiedArtifactSHA256,
                manifestSHA256: manifestSHA256,
                signingKeyID: signingKeyID,
                manifestFormatVersion: manifestFormatVersion
            ),
            virtioGPUKernelAndDeviceSupportQualified: virtioGPUQualified,
            venusVulkanGuestRuntimeQualified: venusVulkanQualified
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
        architecture: DoryGuestArchitecture,
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
            detectedArchitecture: architecture,
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

    private func makeRuntimeQualification(
        request: DoryVirtualMachineCapabilityRequest,
        host: DoryAppleSiliconHostFacts
    ) -> DoryTrustedVirtualMachineRuntimeQualification? {
        guard request.guest.family == .linux,
              request.backend == .doryHypervisor
                || request.backend == .appleVirtualizationFramework,
              let hostContext = host.runtimeQualificationContext else {
            return nil
        }
        let immutableArtifactSHA256 = request.bootMedia.kind == .virtualDisk
            ? nil : request.bootMedia.artifactSHA256
        guard immutableArtifactSHA256 != nil || request.bootMedia.mutableProvenance != nil else {
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
                backend: request.backend,
                backendRuntimeBuildID: hostContext.runtimeBuildID(for: request.backend),
                virtualHardwareABIVersion: request.virtualHardwareABIVersion,
                graphics: request.graphics,
                devices: request.devices
            ),
            runtimeQualified: true
        )
    }
}
