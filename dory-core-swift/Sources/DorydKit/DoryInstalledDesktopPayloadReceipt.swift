import Foundation
import DoryOperations

/// Identifies how an installed desktop payload receipt was established.
///
/// Legacy receipts are a read-only compatibility projection of the two historical environment
/// fields. Newly installed payloads are always bound to the exact verified update bundle.
public enum DoryInstalledDesktopPayloadReceiptProvenance: String, Codable, Sendable, Equatable, Hashable {
    case legacyEnvironment = "legacy-environment"
    case legacySnapshotMigration = "legacy-snapshot-migration"
    case verifiedUpdateBundle = "verified-update-bundle"
}

/// Non-secret, versioned evidence describing the desktop payload installed in a Linux guest.
///
/// This is observed durable state rather than desired VM intent. It deliberately contains no
/// host path, token, credential, or guest output beyond bounded identifiers and SHA-256 digests.
public struct DoryInstalledDesktopPayloadReceipt: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let legacyReleaseVersionEnvironmentKey = "DORY_DESKTOP_RELEASE_VERSION"
    public static let legacyInputSHA256EnvironmentKey = "DORY_DESKTOP_INPUT_SHA256"

    public var schemaVersion: UInt16
    public var provenance: DoryInstalledDesktopPayloadReceiptProvenance
    public var distributionIdentifier: String
    public var releaseVersion: String
    public var inputSHA256: String
    public var bundleSHA256: String?
    public var distributionComponentIdentifier: String?
    public var distributionInstallationName: String?
    public var distributionCatalogSHA256: String?
    public var bundleAssetIdentifier: String?
    public var runtimeComponentIdentifier: String?
    public var runtimeInstallationName: String?
    public var runtimeCatalogSHA256: String?
    public var kernelAssetIdentifier: String?
    public var kernelSHA256: String?

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        provenance: DoryInstalledDesktopPayloadReceiptProvenance,
        distributionIdentifier: String,
        releaseVersion: String,
        inputSHA256: String,
        bundleSHA256: String? = nil,
        distributionComponentIdentifier: String? = nil,
        distributionInstallationName: String? = nil,
        distributionCatalogSHA256: String? = nil,
        bundleAssetIdentifier: String? = nil,
        runtimeComponentIdentifier: String? = nil,
        runtimeInstallationName: String? = nil,
        runtimeCatalogSHA256: String? = nil,
        kernelAssetIdentifier: String? = nil,
        kernelSHA256: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.provenance = provenance
        self.distributionIdentifier = distributionIdentifier
        self.releaseVersion = releaseVersion
        self.inputSHA256 = inputSHA256
        self.bundleSHA256 = bundleSHA256
        self.distributionComponentIdentifier = distributionComponentIdentifier
        self.distributionInstallationName = distributionInstallationName
        self.distributionCatalogSHA256 = distributionCatalogSHA256
        self.bundleAssetIdentifier = bundleAssetIdentifier
        self.runtimeComponentIdentifier = runtimeComponentIdentifier
        self.runtimeInstallationName = runtimeInstallationName
        self.runtimeCatalogSHA256 = runtimeCatalogSHA256
        self.kernelAssetIdentifier = kernelAssetIdentifier
        self.kernelSHA256 = kernelSHA256
    }

    public static func verifiedUpdate(
        distributionIdentifier: String,
        releaseVersion: String,
        inputSHA256: String,
        bundleSHA256: String,
        distributionComponentIdentifier: String,
        distributionInstallationName: String,
        distributionCatalogSHA256: String,
        bundleAssetIdentifier: String,
        runtimeComponentIdentifier: String,
        runtimeInstallationName: String,
        runtimeCatalogSHA256: String,
        kernelAssetIdentifier: String,
        kernelSHA256: String
    ) -> Self {
        Self(
            provenance: .verifiedUpdateBundle,
            distributionIdentifier: distributionIdentifier,
            releaseVersion: releaseVersion,
            inputSHA256: inputSHA256,
            bundleSHA256: bundleSHA256,
            distributionComponentIdentifier: distributionComponentIdentifier,
            distributionInstallationName: distributionInstallationName,
            distributionCatalogSHA256: distributionCatalogSHA256,
            bundleAssetIdentifier: bundleAssetIdentifier,
            runtimeComponentIdentifier: runtimeComponentIdentifier,
            runtimeInstallationName: runtimeInstallationName,
            runtimeCatalogSHA256: runtimeCatalogSHA256,
            kernelAssetIdentifier: kernelAssetIdentifier,
            kernelSHA256: kernelSHA256
        )
    }

    /// Projects an old machine's receipt without mutating or canonicalizing its raw metadata.
    public static func legacyEnvironment(_ environment: [String: String]) -> Self? {
        guard let distributionIdentifier = environment["DORY_DESKTOP_DISTRO"],
              let releaseVersion = environment[legacyReleaseVersionEnvironmentKey],
              let inputSHA256 = environment[legacyInputSHA256EnvironmentKey] else {
            return nil
        }
        let receipt = Self(
            provenance: .legacyEnvironment,
            distributionIdentifier: distributionIdentifier,
            releaseVersion: releaseVersion,
            inputSHA256: inputSHA256
        )
        return receipt.isValid ? receipt : nil
    }

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.isValidDistributionIdentifier(distributionIdentifier),
              Self.isValidReleaseVersion(releaseVersion),
              Self.isLowercaseSHA256(inputSHA256) else {
            return false
        }
        switch provenance {
        case .legacyEnvironment:
            return allVerifiedAuthorityFieldsAreNil
        case .legacySnapshotMigration:
            return allVerifiedAuthorityFieldsAreNil
        case .verifiedUpdateBundle:
            guard bundleSHA256.map(Self.isLowercaseSHA256) == true,
                  kernelSHA256.map(Self.isLowercaseSHA256) == true,
                  distributionComponentIdentifier == Self.componentIdentifier(for: distributionIdentifier),
                  runtimeComponentIdentifier == DoryComponentID.linuxDesktop.rawValue,
                  distributionInstallationName.map(Self.isSafeIdentifier) == true,
                  runtimeInstallationName.map(Self.isSafeIdentifier) == true,
                  distributionCatalogSHA256.map(Self.isLowercaseSHA256) == true,
                  runtimeCatalogSHA256.map(Self.isLowercaseSHA256) == true,
                  bundleAssetIdentifier == Self.bundleAssetIdentifier(for: distributionIdentifier),
                  kernelAssetIdentifier == Self.kernelAssetIdentifier else {
                return false
            }
            return true
        }
    }

    public func matchesLegacyEnvironment(_ environment: [String: String]) -> Bool {
        provenance == .legacyEnvironment && Self.legacyEnvironment(environment) == self
    }

    /// Converts a raw legacy projection into an explicitly historical, path-free snapshot claim.
    /// It is never treated as verified active-component provenance.
    public var archivedLegacySnapshotReceipt: Self? {
        guard provenance == .legacyEnvironment, isValid else { return nil }
        var copy = self
        copy.provenance = .legacySnapshotMigration
        return copy
    }

    /// Portable bundles are integrity checked but are not signed component-store authority.
    /// Preserve bounded historical identity while discarding any active-verification claim.
    public var portableSnapshotReceipt: Self? {
        guard isValid else { return nil }
        if provenance == .legacySnapshotMigration { return self }
        return Self(
            provenance: .legacySnapshotMigration,
            distributionIdentifier: distributionIdentifier,
            releaseVersion: releaseVersion,
            inputSHA256: inputSHA256
        )
    }

    public func hasCoherentAuthority(environment: [String: String]) -> Bool {
        guard isValid else { return false }
        let hasLegacyRelease = environment[Self.legacyReleaseVersionEnvironmentKey] != nil
        let hasLegacyInput = environment[Self.legacyInputSHA256EnvironmentKey] != nil
        switch provenance {
        case .legacyEnvironment:
            return matchesLegacyEnvironment(environment)
        case .legacySnapshotMigration:
            return !hasLegacyRelease && !hasLegacyInput
                && (environment["DORY_DESKTOP_DISTRO"] == nil
                    || environment["DORY_DESKTOP_DISTRO"] == distributionIdentifier)
        case .verifiedUpdateBundle:
            return !hasLegacyRelease && !hasLegacyInput
                && (environment["DORY_DESKTOP_DISTRO"] == nil
                    || environment["DORY_DESKTOP_DISTRO"] == distributionIdentifier)
        }
    }

    public static func componentIdentifier(for distributionIdentifier: String) -> String? {
        switch distributionIdentifier {
        case "debian": DoryComponentID.desktopDebian.rawValue
        case "ubuntu": DoryComponentID.desktopUbuntu.rawValue
        case "kali": DoryComponentID.desktopKali.rawValue
        default: nil
        }
    }

    public static func bundleAssetIdentifier(for distributionIdentifier: String) -> String {
        "dory-desktop-\(distributionIdentifier)-update-arm64.tar"
    }

    public static let kernelAssetIdentifier = "dory-desktop-kernel-arm64.lzfse"

    private var allVerifiedAuthorityFieldsAreNil: Bool {
        bundleSHA256 == nil
            && distributionComponentIdentifier == nil
            && distributionInstallationName == nil
            && distributionCatalogSHA256 == nil
            && bundleAssetIdentifier == nil
            && runtimeComponentIdentifier == nil
            && runtimeInstallationName == nil
            && runtimeCatalogSHA256 == nil
            && kernelAssetIdentifier == nil
            && kernelSHA256 == nil
    }

    private static func isValidDistributionIdentifier(_ value: String) -> Bool {
        ["debian", "kali", "ubuntu"].contains(value)
    }

    private static func isValidReleaseVersion(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._+-]{0,127}/) != nil
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...255).contains(bytes.count),
              let first = bytes.first,
              (first >= 48 && first <= 57)
                || (first >= 65 && first <= 90)
                || (first >= 97 && first <= 122) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 43 || byte == 45 || byte == 46 || byte == 95
        }
    }
}

/// Stable, caller-visible selection identity. Host paths never cross XPC.
public struct DoryDesktopUpdateRequest: Sendable, Equatable {
    public var distro: String
    public var version: String
    public var distributionInstallationName: String
    public var runtimeInstallationName: String

    public init(
        distro: String,
        version: String,
        distributionInstallationName: String,
        runtimeInstallationName: String
    ) {
        self.distro = distro
        self.version = version
        self.distributionInstallationName = distributionInstallationName
        self.runtimeInstallationName = runtimeInstallationName
    }
}

public struct DoryDesktopUpdateArtifactAuthority: Sendable, Equatable {
    public var receipt: DoryInstalledDesktopPayloadReceipt
    public var bundlePath: String
    public var bundleByteCount: UInt64
    public var kernelPath: String
    public var kernelByteCount: UInt64

    public init(
        receipt: DoryInstalledDesktopPayloadReceipt,
        bundlePath: String,
        bundleByteCount: UInt64,
        kernelPath: String,
        kernelByteCount: UInt64
    ) {
        self.receipt = receipt
        self.bundlePath = bundlePath
        self.bundleByteCount = bundleByteCount
        self.kernelPath = kernelPath
        self.kernelByteCount = kernelByteCount
    }
}

public protocol DoryDesktopUpdateArtifactResolving: Sendable {
    func resolve(
        _ request: DoryDesktopUpdateRequest,
        guestArchitecture: String
    ) throws -> DoryDesktopUpdateArtifactAuthority
}

/// Resolves only the active, already signature-qualified component generations. This type never
/// accepts a caller-controlled path and re-verifies every byte immediately before returning it.
public struct DoryComponentStoreDesktopUpdateArtifactResolver: DoryDesktopUpdateArtifactResolving {
    public let store: DoryComponentStore
    public let publicKey: String
    public let expectedArchitecture: String
    public let appVersion: String

    /// Production construction is pinned to daemon-compiled trust inputs. The helper executable
    /// must not derive qualification authority from its mutable bundle metadata.
    public init(store: DoryComponentStore) {
        self.init(
            store: store,
            publicKey: DoryComponentDefaults.publicKey,
            expectedArchitecture: DoryComponentDefaults.architecture,
            appVersion: DoryDaemonVirtualMachineProductionTrustFactory.compiledDaemonVersion
        )
    }

    /// Internal seam for signed-catalog fixtures; production callers use the pinned initializer.
    init(
        store: DoryComponentStore,
        publicKey: String,
        expectedArchitecture: String,
        appVersion: String
    ) {
        self.store = store
        self.publicKey = publicKey
        self.expectedArchitecture = expectedArchitecture
        self.appVersion = appVersion
    }

    public func resolve(
        _ request: DoryDesktopUpdateRequest,
        guestArchitecture: String
    ) throws -> DoryDesktopUpdateArtifactAuthority {
        guard guestArchitecture == expectedArchitecture,
              let rawComponentID = DoryInstalledDesktopPayloadReceipt.componentIdentifier(
                for: request.distro
              ),
              let distributionID = DoryComponentID(rawValue: rawComponentID) else {
            throw MachineManagerError.persistence("desktop update platform is unsupported")
        }
        let distribution = try store.verify(distributionID)
        let runtime = try store.verify(.linuxDesktop)
        guard let signed = try store.cachedCatalog(
            publicKey: publicKey,
            expectedArchitecture: expectedArchitecture,
            appVersion: appVersion
        ) else {
            throw MachineManagerError.persistence("signed desktop component catalog is unavailable")
        }
        let signedCatalogSHA256 = DoryComponentCatalogVerifier.digest(signed.data)
        guard distribution.catalogDigest.lowercased() == signedCatalogSHA256,
              runtime.catalogDigest.lowercased() == signedCatalogSHA256,
              let signedDistribution = signed.catalog.components.first(where: {
                $0.id == distributionID && $0.version == distribution.version
              }),
              let signedRuntime = signed.catalog.components.first(where: {
                $0.id == .linuxDesktop && $0.version == runtime.version
              }),
              signedDistribution.assets == distribution.assets,
              signedRuntime.assets == runtime.assets else {
            throw MachineManagerError.persistence("active desktop components do not match the signed catalog")
        }
        guard distribution.installationName == request.distributionInstallationName,
              runtime.installationName == request.runtimeInstallationName,
              request.version == distribution.version + "+runtime." + runtime.version else {
            throw MachineManagerError.persistence("desktop update component selection is stale")
        }
        let bundleAssetID = DoryInstalledDesktopPayloadReceipt.bundleAssetIdentifier(
            for: request.distro
        )
        let kernelAssetID = DoryInstalledDesktopPayloadReceipt.kernelAssetIdentifier
        guard let bundle = distribution.assets.first(where: { $0.path == bundleAssetID }),
              let kernel = runtime.assets.first(where: { $0.path == kernelAssetID }),
              bundle.compression == .none,
              kernel.installedBytes > 0,
              let bundlePath = store.assetPath(component: distributionID, path: bundleAssetID),
              let kernelPath = store.assetPath(component: .linuxDesktop, path: kernelAssetID) else {
            throw MachineManagerError.persistence("desktop update component assets are invalid")
        }
        let placeholderInput = String(repeating: "0", count: 64)
        let receipt = DoryInstalledDesktopPayloadReceipt.verifiedUpdate(
            distributionIdentifier: request.distro,
            releaseVersion: request.version,
            inputSHA256: placeholderInput,
            bundleSHA256: bundle.installedSHA256,
            distributionComponentIdentifier: distribution.id.rawValue,
            distributionInstallationName: distribution.installationName,
            distributionCatalogSHA256: distribution.catalogDigest.lowercased(),
            bundleAssetIdentifier: bundle.path,
            runtimeComponentIdentifier: runtime.id.rawValue,
            runtimeInstallationName: runtime.installationName,
            runtimeCatalogSHA256: runtime.catalogDigest.lowercased(),
            kernelAssetIdentifier: kernel.path,
            kernelSHA256: kernel.installedSHA256
        )
        guard receipt.isValid else {
            throw MachineManagerError.persistence("desktop update component evidence is invalid")
        }
        return DoryDesktopUpdateArtifactAuthority(
            receipt: receipt,
            bundlePath: bundlePath,
            bundleByteCount: bundle.installedBytes,
            kernelPath: kernelPath,
            kernelByteCount: kernel.installedBytes
        )
    }
}
