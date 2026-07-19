import Compression
import CryptoKit
import Darwin
import Foundation

public enum DoryComponentID: String, Codable, CaseIterable, Hashable, Sendable {
    case dockerCore = "docker-core"
    case kubernetes
    case linuxMachines = "linux-machines"
    case linuxDesktop = "linux-desktop"
    case desktopDebian = "desktop-debian"
    case desktopUbuntu = "desktop-ubuntu"
    case desktopKali = "desktop-kali"

    public var isRemovable: Bool { self != .dockerCore }
}

public enum DoryComponentSelectionURL {
    public static let scheme = "dory"
    public static let host = "components"
    public static let path = "/install"

    public static func parse(_ url: URL) -> [DoryComponentID]? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host,
              components.path == path,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "ids",
              let value = queryItems[0].value,
              !value.isEmpty else {
            return nil
        }

        let rawIDs = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !rawIDs.isEmpty else { return nil }

        var selected: Set<DoryComponentID> = []
        for rawID in rawIDs {
            guard let id = DoryComponentID(rawValue: rawID),
                  id.isRemovable,
                  selected.insert(id).inserted else {
                return nil
            }
        }
        return DoryComponentID.allCases.filter(selected.contains)
    }

    public static func make(_ ids: some Sequence<DoryComponentID>) -> URL? {
        let selected = Set(ids)
        guard !selected.isEmpty, selected.allSatisfy(\.isRemovable) else { return nil }
        let ordered = DoryComponentID.allCases.filter(selected.contains)
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "ids", value: ordered.map(\.rawValue).joined(separator: ",")),
        ]
        return components.url
    }
}

public enum DoryComponentDefaults {
    public static let catalogURL = URL(
        string: "https://augani.github.io/dory/components/arm64/catalog.json"
    )!
    /// Component catalogs use the same pinned Ed25519 trust root as Dory's signed Sparkle feed.
    /// The private key never ships with the app or repository.
    public static let publicKey = "AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4="

    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}

public enum DoryComponentCompression: String, Codable, Sendable {
    case none
    case lzfse
}

public struct DoryComponentAsset: Codable, Sendable, Equatable {
    public let path: String
    public let url: String
    public let compression: DoryComponentCompression
    public let downloadBytes: UInt64
    public let installedBytes: UInt64
    public let sha256: String
    public let installedSHA256: String
    public let executable: Bool

    public init(
        path: String,
        url: String,
        compression: DoryComponentCompression = .none,
        downloadBytes: UInt64,
        installedBytes: UInt64,
        sha256: String,
        installedSHA256: String,
        executable: Bool = false
    ) {
        self.path = path
        self.url = url
        self.compression = compression
        self.downloadBytes = downloadBytes
        self.installedBytes = installedBytes
        self.sha256 = sha256.lowercased()
        self.installedSHA256 = installedSHA256.lowercased()
        self.executable = executable
    }
}

public struct DoryComponentRelease: Codable, Sendable, Equatable, Identifiable {
    public let id: DoryComponentID
    public let version: String
    public let displayName: String
    public let summary: String
    public let dependencies: [DoryComponentID]
    public let downloadBytes: UInt64
    public let installedBytes: UInt64
    public let assets: [DoryComponentAsset]

    public init(
        id: DoryComponentID,
        version: String,
        displayName: String,
        summary: String,
        dependencies: [DoryComponentID] = [.dockerCore],
        downloadBytes: UInt64,
        installedBytes: UInt64,
        assets: [DoryComponentAsset]
    ) {
        self.id = id
        self.version = version
        self.displayName = displayName
        self.summary = summary
        self.dependencies = dependencies
        self.downloadBytes = downloadBytes
        self.installedBytes = installedBytes
        self.assets = assets
    }
}

public struct DoryComponentCatalog: Codable, Sendable, Equatable {
    public static let kind = "dev.dory.component-catalog"
    public static let schemaVersion = 1

    public let kind: String
    public let schemaVersion: Int
    public let releaseVersion: String
    public let generatedAt: String
    public let minimumAppVersion: String
    public let architecture: String
    public let components: [DoryComponentRelease]

    public init(
        releaseVersion: String,
        generatedAt: String,
        minimumAppVersion: String,
        architecture: String,
        components: [DoryComponentRelease]
    ) {
        kind = Self.kind
        schemaVersion = Self.schemaVersion
        self.releaseVersion = releaseVersion
        self.generatedAt = generatedAt
        self.minimumAppVersion = minimumAppVersion
        self.architecture = architecture
        self.components = components
    }

    public func component(_ id: DoryComponentID) -> DoryComponentRelease? {
        components.first { $0.id == id }
    }
}

public enum DoryComponentError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidCatalog(String)
    case invalidSignature
    case incompatibleArchitecture(expected: String, actual: String)
    case incompatibleAppVersion(required: String, actual: String)
    case unknownComponent(String)
    case coreCannotBeChanged
    case missingDependency(DoryComponentID)
    case componentInUse(DoryComponentID)
    case invalidAsset(String)
    case download(String)
    case digestMismatch(String)
    case interrupted(String)
    case unsafePath(String)
    case filesystem(String)

    public var description: String {
        switch self {
        case .invalidCatalog(let detail): "invalid component catalog: \(detail)"
        case .invalidSignature: "component catalog signature is invalid"
        case .incompatibleArchitecture(let expected, let actual):
            "component catalog is for \(actual), but this Mac needs \(expected)"
        case .incompatibleAppVersion(let required, let actual):
            "component catalog requires Dory \(required) or newer; this app is \(actual)"
        case .unknownComponent(let id): "unknown Dory component: \(id)"
        case .coreCannotBeChanged: "Docker Core is part of Dory.app and cannot be installed or removed separately"
        case .missingDependency(let id): "install \(id.rawValue) first"
        case .componentInUse(let id): "remove dependent component \(id.rawValue) first"
        case .invalidAsset(let path): "invalid component asset: \(path)"
        case .download(let detail): "component download failed: \(detail)"
        case .digestMismatch(let path): "component verification failed for \(path)"
        case .interrupted(let detail): "component installation was interrupted: \(detail)"
        case .unsafePath(let path): "refusing unsafe component path: \(path)"
        case .filesystem(let detail): detail
        }
    }
}

public enum DoryComponentCatalogVerifier {
    public static let maximumCatalogBytes = 2 * 1_024 * 1_024

    public static func verify(
        catalogData: Data,
        signatureBase64: String,
        publicKeyBase64: String,
        expectedArchitecture: String,
        appVersion: String
    ) throws -> DoryComponentCatalog {
        guard !catalogData.isEmpty, catalogData.count <= maximumCatalogBytes,
              let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              signature.count == 64,
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              publicKeyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: catalogData) else {
            throw DoryComponentError.invalidSignature
        }
        let catalog: DoryComponentCatalog
        do {
            catalog = try JSONDecoder().decode(DoryComponentCatalog.self, from: catalogData)
        } catch {
            throw DoryComponentError.invalidCatalog("JSON could not be decoded")
        }
        try validate(catalog, expectedArchitecture: expectedArchitecture, appVersion: appVersion)
        return catalog
    }

    public static func validate(
        _ catalog: DoryComponentCatalog,
        expectedArchitecture: String,
        appVersion: String
    ) throws {
        guard catalog.kind == DoryComponentCatalog.kind,
              catalog.schemaVersion == DoryComponentCatalog.schemaVersion,
              validVersion(catalog.releaseVersion),
              validVersion(catalog.minimumAppVersion),
              validTimestamp(catalog.generatedAt),
              !catalog.components.isEmpty else {
            throw DoryComponentError.invalidCatalog("header is incomplete or unsupported")
        }
        guard catalog.architecture == expectedArchitecture else {
            throw DoryComponentError.incompatibleArchitecture(
                expected: expectedArchitecture,
                actual: catalog.architecture
            )
        }
        guard compareVersions(appVersion, catalog.minimumAppVersion) != .orderedAscending else {
            throw DoryComponentError.incompatibleAppVersion(
                required: catalog.minimumAppVersion,
                actual: appVersion
            )
        }
        let ids = catalog.components.map(\.id)
        guard Set(ids).count == ids.count,
              ids.first == .dockerCore,
              catalog.component(.dockerCore)?.assets.isEmpty == true else {
            throw DoryComponentError.invalidCatalog("Docker Core must be the first, unique, payload-free entry")
        }
        for component in catalog.components {
            try validate(component, available: Set(ids))
        }
        try validateDependencyGraph(catalog.components)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func fileDigest(_ path: String) throws -> String {
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw DoryComponentError.invalidAsset(path) }
        defer { close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count >= 0 else { throw DoryComponentError.filesystem("read component asset \(path): errno \(errno)") }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ component: DoryComponentRelease, available: Set<DoryComponentID>) throws {
        guard validVersion(component.version),
              !component.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !component.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(component.dependencies).count == component.dependencies.count,
              !component.dependencies.contains(component.id),
              component.dependencies.allSatisfy(available.contains) else {
            throw DoryComponentError.invalidCatalog("invalid metadata for \(component.id.rawValue)")
        }
        if component.id == .dockerCore {
            guard component.dependencies.isEmpty,
                  component.downloadBytes > 0,
                  component.installedBytes > 0 else {
                throw DoryComponentError.invalidCatalog("invalid Docker Core metadata")
            }
            return
        }
        guard !component.assets.isEmpty,
              component.dependencies.contains(.dockerCore),
              component.downloadBytes == component.assets.reduce(0, { $0 + $1.downloadBytes }),
              component.installedBytes == component.assets.reduce(0, { $0 + $1.installedBytes }) else {
            throw DoryComponentError.invalidCatalog("invalid size or dependency totals for \(component.id.rawValue)")
        }
        let paths = component.assets.map(\.path)
        guard Set(paths).count == paths.count else {
            throw DoryComponentError.invalidCatalog("duplicate asset path in \(component.id.rawValue)")
        }
        for asset in component.assets {
            guard safeRelativePath(asset.path),
                  (URL(string: asset.url)?.scheme == "https" || URL(string: asset.url)?.isFileURL == true),
                  asset.downloadBytes > 0,
                  asset.installedBytes > 0,
                  validDigest(asset.sha256),
                  validDigest(asset.installedSHA256),
                  asset.installedBytes <= 128 * 1_024 * 1_024 * 1_024 else {
                throw DoryComponentError.invalidCatalog("invalid asset in \(component.id.rawValue)")
            }
            if asset.compression == .none,
               (asset.downloadBytes != asset.installedBytes || asset.sha256 != asset.installedSHA256) {
                throw DoryComponentError.invalidCatalog("uncompressed asset metadata disagrees for \(asset.path)")
            }
        }
    }

    private static func validateDependencyGraph(_ components: [DoryComponentRelease]) throws {
        let byID = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0) })
        func visit(_ id: DoryComponentID, path: Set<DoryComponentID>) throws {
            guard !path.contains(id), let component = byID[id] else {
                throw DoryComponentError.invalidCatalog("component dependency cycle")
            }
            var next = path
            next.insert(id)
            for dependency in component.dependencies where dependency != .dockerCore {
                try visit(dependency, path: next)
            }
        }
        for component in components { try visit(component.id, path: []) }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func validVersion(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64
            && value.allSatisfy { $0.isNumber || $0.isLetter || ".+-_".contains($0) }
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    static func validTimestamp(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil
    }

    static func safeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 255, !path.hasPrefix("/"), !path.hasSuffix("/"),
              path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 1 && components[0] != "." && components[0] != ".." && !components[0].isEmpty
    }
}

public struct DoryInstalledComponent: Codable, Sendable, Equatable {
    public static let kind = "dev.dory.installed-component"
    public static let schemaVersion = 2

    public let kind: String
    public let schemaVersion: Int
    public let id: DoryComponentID
    public let version: String
    public let installationName: String
    public let catalogDigest: String
    public let installedAt: String
    public let assets: [DoryComponentAsset]
    public let assetFingerprints: [DoryComponentAssetFingerprint]

    init(
        release: DoryComponentRelease,
        installationName: String,
        catalogDigest: String,
        installedAt: Date,
        assetFingerprints: [DoryComponentAssetFingerprint]
    ) {
        kind = Self.kind
        schemaVersion = Self.schemaVersion
        id = release.id
        version = release.version
        self.installationName = installationName
        self.catalogDigest = catalogDigest
        self.installedAt = DoryComponentStore.timestamp(installedAt)
        assets = release.assets
        self.assetFingerprints = assetFingerprints
    }

    var isStructurallyValid: Bool {
        kind == Self.kind && schemaVersion == Self.schemaVersion && id.isRemovable
            && DoryComponentCatalogVerifier.safeRelativePath(installationName)
            && catalogDigest.count == 64 && catalogDigest.allSatisfy(\.isHexDigit)
            && DoryComponentCatalogVerifier.validTimestamp(installedAt)
            && !assets.isEmpty
            && assetFingerprints.map(\.path) == assets.map(\.path)
    }
}

public struct DoryComponentAssetFingerprint: Codable, Sendable, Equatable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let permissions: UInt32
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
}

public enum DoryComponentState: String, Codable, Sendable {
    case bundled
    case notInstalled
    case installed
    case updateAvailable
    case invalid
}

public struct DoryComponentStatus: Codable, Sendable, Equatable, Identifiable {
    public let id: DoryComponentID
    public let displayName: String
    public let summary: String
    public let availableVersion: String
    public let installedVersion: String?
    public let state: DoryComponentState
    public let downloadBytes: UInt64
    public let installedBytes: UInt64
    public let dependencies: [DoryComponentID]
}

/// Exact active-component selection captured before an app or component transaction. Component
/// payloads are immutable and digest-verified; retaining one prior installation per component lets
/// this small record switch activation back without redownloading or trusting the network.
public struct DoryComponentSelectionSnapshot: Codable, Sendable, Equatable {
    public static let kind = "dev.dory.component-selection-snapshot"
    public static let schemaVersion = 1

    public let kind: String
    public let schemaVersion: Int
    public let capturedAt: String
    public let components: [DoryInstalledComponent]

    public init(capturedAt: Date = Date(), components: [DoryInstalledComponent]) {
        kind = Self.kind
        schemaVersion = Self.schemaVersion
        self.capturedAt = DoryComponentStore.timestamp(capturedAt)
        self.components = components.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    var isStructurallyValid: Bool {
        kind == Self.kind
            && schemaVersion == Self.schemaVersion
            && DoryComponentCatalogVerifier.validTimestamp(capturedAt)
            && Set(components.map(\.id)).count == components.count
            && components.allSatisfy(\.isStructurallyValid)
    }
}

public struct DoryComponentStore: Sendable {
    public let drive: DoryDataDrive
    public var root: String { drive.componentsDirectory }

    public init(drive: DoryDataDrive) {
        self.drive = drive
    }

    public static func selected(home: String = DoryDataDrive.processHome()) throws -> DoryComponentStore {
        let selection = try DoryDataDriveSelectionStore(home: home)
        guard let drive = try selection.inspectSelection() else {
            throw DoryComponentError.filesystem("no Dory data drive is selected")
        }
        return DoryComponentStore(drive: drive)
    }

    public func prepare(fileManager: FileManager = .default) throws {
        try drive.validateManifest(fileManager: fileManager)
        for directory in [root, installedRoot, activeRoot, downloadsRoot, stagingRoot] {
            try Self.ensurePrivateDirectory(directory, fileManager: fileManager)
        }
    }

    public func list(
        catalog: DoryComponentCatalog,
        catalogDigest expectedCatalogDigest: String? = nil
    ) -> [DoryComponentStatus] {
        catalog.components.map { release in
            if release.id == .dockerCore {
                return DoryComponentStatus(
                    id: release.id,
                    displayName: release.displayName,
                    summary: release.summary,
                    availableVersion: release.version,
                    installedVersion: release.version,
                    state: .bundled,
                    downloadBytes: release.downloadBytes,
                    installedBytes: release.installedBytes,
                    dependencies: release.dependencies
                )
            }
            let installed: DoryInstalledComponent?
            let installedRecordInvalid: Bool
            do {
                installed = try installedComponent(release.id)
                installedRecordInvalid = false
            } catch {
                installed = nil
                installedRecordInvalid = FileManager.default.fileExists(atPath: activePath(release.id))
            }
            let state: DoryComponentState
            if installedRecordInvalid {
                state = .invalid
            } else if let installed {
                if (try? validateInstalledAssets(installed)) == nil {
                    state = .invalid
                } else if installed.version == release.version,
                          expectedCatalogDigest == nil || installed.catalogDigest == expectedCatalogDigest {
                    state = .installed
                } else {
                    state = .updateAvailable
                }
            } else {
                state = .notInstalled
            }
            return DoryComponentStatus(
                id: release.id,
                displayName: release.displayName,
                summary: release.summary,
                availableVersion: release.version,
                installedVersion: installed?.version,
                state: state,
                downloadBytes: release.downloadBytes,
                installedBytes: release.installedBytes,
                dependencies: release.dependencies
            )
        }
    }

    public func installedComponent(_ id: DoryComponentID) throws -> DoryInstalledComponent? {
        guard id.isRemovable else { return nil }
        let activationPath = activePath(id)
        guard FileManager.default.fileExists(atPath: activationPath) else { return nil }
        let activation = try readRecord(DoryComponentActivation.self, at: activationPath)
        guard activation.isStructurallyValid, activation.id == id else {
            throw DoryComponentError.invalidAsset(activationPath)
        }
        let recordPath = installationRoot(id: id, name: activation.installationName) + "/installed.json"
        let record = try readRecord(DoryInstalledComponent.self, at: recordPath)
        guard record.isStructurallyValid,
              record.id == id,
              record.version == activation.version,
              record.installationName == activation.installationName,
              record.catalogDigest == activation.catalogDigest else {
            throw DoryComponentError.invalidAsset(recordPath)
        }
        return record
    }

    public func captureSelection() throws -> DoryComponentSelectionSnapshot {
        try prepare()
        let components = try DoryComponentID.allCases.compactMap { id -> DoryInstalledComponent? in
            guard id.isRemovable, let installed = try installedComponent(id) else { return nil }
            try verify(installed)
            return installed
        }
        return DoryComponentSelectionSnapshot(components: components)
    }

    /// Restores only activation records. Durable payload directories are never synthesized or
    /// downgraded: every referenced prior payload must still exist and pass its exact fingerprint.
    public func restoreSelection(
        _ snapshot: DoryComponentSelectionSnapshot,
        fileManager: FileManager = .default
    ) throws {
        guard snapshot.isStructurallyValid else {
            throw DoryComponentError.invalidAsset("component selection snapshot")
        }
        try prepare(fileManager: fileManager)
        let lock = try EngineStateDirectoryLock(stateDirectory: root, lockFileName: "store.lock")
        defer { withExtendedLifetime(lock) {} }
        for component in snapshot.components { try verify(component) }
        let desired = Dictionary(uniqueKeysWithValues: snapshot.components.map { ($0.id, $0) })
        for id in DoryComponentID.allCases where id.isRemovable {
            let path = activePath(id)
            if let component = desired[id] {
                try writeRecord(DoryComponentActivation(component), at: path, fileManager: fileManager)
            } else if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
        }
        try Self.syncDirectory(activeRoot)
    }

    @discardableResult
    public func install(
        _ release: DoryComponentRelease,
        catalogDigest: String,
        downloadedAssets: [String: String],
        installedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> DoryInstalledComponent {
        guard release.id.isRemovable else { throw DoryComponentError.coreCannotBeChanged }
        guard catalogDigest.count == 64, catalogDigest.allSatisfy(\.isHexDigit) else {
            throw DoryComponentError.invalidCatalog("catalog digest is invalid")
        }
        try prepare(fileManager: fileManager)
        let lock = try EngineStateDirectoryLock(stateDirectory: root, lockFileName: "store.lock")
        defer { withExtendedLifetime(lock) {} }
        try pruneStaging(fileManager: fileManager)
        for dependency in release.dependencies where dependency != .dockerCore {
            guard (try installedComponent(dependency)) != nil else {
                throw DoryComponentError.missingDependency(dependency)
            }
        }
        let priorInstallation = (try? installedComponent(release.id))?.installationName
        if let current = try? installedComponent(release.id),
           current.version == release.version,
           current.catalogDigest == catalogDigest,
           (try? verify(current)) != nil {
            return current
        }

        let operationID = UUID().uuidString.lowercased()
        let installationName = "\(release.version)-\(operationID)"
        let staging = stagingRoot + "/\(release.id.rawValue)-\(operationID)"
        let payload = staging + "/payload"
        let destination = installationRoot(id: release.id, name: installationName)
        var published = false
        do {
            try Self.ensurePrivateDirectory(staging, fileManager: fileManager)
            try Self.ensurePrivateDirectory(payload, fileManager: fileManager)
            for asset in release.assets {
                guard let source = downloadedAssets[asset.path] else {
                    throw DoryComponentError.invalidAsset(asset.path)
                }
                try verifyFile(source, bytes: asset.downloadBytes, digest: asset.sha256)
                let output = payload + "/" + asset.path
                try Self.ensurePrivateDirectory(
                    URL(fileURLWithPath: output).deletingLastPathComponent().path,
                    fileManager: fileManager
                )
                switch asset.compression {
                case .none:
                    try fileManager.copyItem(atPath: source, toPath: output)
                case .lzfse:
                    try Self.decompressLZFSE(
                        source: source,
                        destination: output,
                        maximumBytes: asset.installedBytes
                    )
                }
                try fileManager.setAttributes(
                    [.posixPermissions: asset.executable ? 0o700 : 0o600],
                    ofItemAtPath: output
                )
                try verifyFile(output, bytes: asset.installedBytes, digest: asset.installedSHA256)
                try Self.syncFile(output)
            }
            let record = DoryInstalledComponent(
                release: release,
                installationName: installationName,
                catalogDigest: catalogDigest,
                installedAt: installedAt,
                assetFingerprints: try release.assets.map {
                    try Self.assetFingerprint(payload + "/" + $0.path, asset: $0)
                }
            )
            try writeRecord(record, at: staging + "/installed.json", fileManager: fileManager)
            try Self.ensurePrivateDirectory(installedRoot + "/\(release.id.rawValue)", fileManager: fileManager)
            try Self.syncDirectory(payload)
            try Self.syncDirectory(staging)
            try fileManager.moveItem(atPath: staging, toPath: destination)
            published = true
            try Self.syncDirectory(URL(fileURLWithPath: destination).deletingLastPathComponent().path)
            try writeRecord(
                DoryComponentActivation(record),
                at: activePath(release.id),
                fileManager: fileManager
            )
            try? pruneInactiveInstallations(
                for: release.id,
                keeping: Set([installationName, priorInstallation].compactMap { $0 }),
                fileManager: fileManager
            )
            return record
        } catch {
            if !published { try? fileManager.removeItem(atPath: staging) }
            throw error
        }
    }

    @discardableResult
    public func verify(_ id: DoryComponentID) throws -> DoryInstalledComponent {
        guard let installed = try installedComponent(id) else {
            throw DoryComponentError.unknownComponent(id.rawValue)
        }
        try verify(installed)
        return installed
    }

    public func verify(_ installed: DoryInstalledComponent) throws {
        try validateInstalledAssets(installed)
        let payload = installationRoot(id: installed.id, name: installed.installationName) + "/payload"
        for asset in installed.assets {
            try verifyFile(
                payload + "/" + asset.path,
                bytes: asset.installedBytes,
                digest: asset.installedSHA256
            )
        }
    }

    public func isInstalledAndValid(_ id: DoryComponentID) -> Bool {
        guard let installed = try? installedComponent(id) else { return false }
        return (try? validateInstalledAssets(installed)) != nil
    }

    public func remove(
        _ id: DoryComponentID,
        catalog: DoryComponentCatalog,
        fileManager: FileManager = .default
    ) throws {
        guard id.isRemovable else { throw DoryComponentError.coreCannotBeChanged }
        try prepare(fileManager: fileManager)
        let lock = try EngineStateDirectoryLock(stateDirectory: root, lockFileName: "store.lock")
        defer { withExtendedLifetime(lock) {} }
        try pruneStaging(fileManager: fileManager)
        for release in catalog.components where release.dependencies.contains(id) {
            if (try installedComponent(release.id)) != nil {
                throw DoryComponentError.componentInUse(release.id)
            }
        }
        let activation = activePath(id)
        let componentRoot = installedRoot + "/\(id.rawValue)"
        guard fileManager.fileExists(atPath: activation) || fileManager.fileExists(atPath: componentRoot) else {
            return
        }
        if fileManager.fileExists(atPath: activation) {
            try fileManager.removeItem(atPath: activation)
            try Self.syncDirectory(activeRoot)
        }
        if fileManager.fileExists(atPath: componentRoot) {
            try fileManager.removeItem(atPath: componentRoot)
            try Self.syncDirectory(installedRoot)
        }
    }

    public func assetPath(component id: DoryComponentID, path: String) -> String? {
        guard DoryComponentCatalogVerifier.safeRelativePath(path),
              let installed = try? installedComponent(id),
              let asset = installed.assets.first(where: { $0.path == path }) else {
            return nil
        }
        let candidate = installationRoot(id: id, name: installed.installationName) + "/payload/" + path
        guard let expected = installed.assetFingerprints.first(where: { $0.path == path }),
              (try? Self.assetFingerprint(candidate, asset: asset)) == expected else {
            return nil
        }
        return candidate
    }

    public func activePayloadDirectories() -> [String] {
        DoryComponentID.allCases.compactMap { id in
            guard let installed = try? installedComponent(id),
                  (try? validateInstalledAssets(installed)) != nil else { return nil }
            return installationRoot(id: id, name: installed.installationName) + "/payload"
        }
    }

    public static func activeAssetPath(
        component: DoryComponentID,
        path: String,
        home: String = DoryDataDrive.processHome()
    ) -> String? {
        (try? selected(home: home))?.assetPath(component: component, path: path)
    }

    public static func activePayloadDirectories(
        home: String = DoryDataDrive.processHome()
    ) -> [String] {
        (try? selected(home: home))?.activePayloadDirectories() ?? []
    }

    public func cachedCatalog(
        publicKey: String,
        expectedArchitecture: String,
        appVersion: String
    ) throws -> (catalog: DoryComponentCatalog, data: Data, signature: String)? {
        let catalogPath = root + "/catalog.json"
        let signaturePath = root + "/catalog.sig"
        guard FileManager.default.fileExists(atPath: catalogPath),
              FileManager.default.fileExists(atPath: signaturePath),
              let data = try? PrivateRecordFile.read(
                at: catalogPath,
                maximumBytes: DoryComponentCatalogVerifier.maximumCatalogBytes
              ),
              let signatureData = try? PrivateRecordFile.read(at: signaturePath, maximumBytes: 1_024),
              let signature = String(data: signatureData, encoding: .utf8) else {
            return nil
        }
        let catalog = try DoryComponentCatalogVerifier.verify(
            catalogData: data,
            signatureBase64: signature,
            publicKeyBase64: publicKey,
            expectedArchitecture: expectedArchitecture,
            appVersion: appVersion
        )
        return (catalog, data, signature.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func cacheCatalog(
        data: Data,
        signature: String,
        publicKey: String,
        expectedArchitecture: String,
        appVersion: String,
        fileManager: FileManager = .default
    ) throws -> DoryComponentCatalog {
        let catalog = try DoryComponentCatalogVerifier.verify(
            catalogData: data,
            signatureBase64: signature,
            publicKeyBase64: publicKey,
            expectedArchitecture: expectedArchitecture,
            appVersion: appVersion
        )
        try prepare(fileManager: fileManager)
        try Self.writePrivateFile(data, to: root + "/catalog.json", fileManager: fileManager)
        try Self.writePrivateFile(Data(signature.utf8), to: root + "/catalog.sig", fileManager: fileManager)
        return catalog
    }

    public var downloadsDirectory: String { downloadsRoot }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private struct DoryComponentActivation: Codable, Sendable {
        static let kind = "dev.dory.component-activation"
        static let schemaVersion = 1

        let kind: String
        let schemaVersion: Int
        let id: DoryComponentID
        let version: String
        let installationName: String
        let catalogDigest: String

        init(_ component: DoryInstalledComponent) {
            kind = Self.kind
            schemaVersion = Self.schemaVersion
            id = component.id
            version = component.version
            installationName = component.installationName
            catalogDigest = component.catalogDigest
        }

        var isStructurallyValid: Bool {
            kind == Self.kind && schemaVersion == Self.schemaVersion && id.isRemovable
                && DoryComponentCatalogVerifier.safeRelativePath(installationName)
                && catalogDigest.count == 64 && catalogDigest.allSatisfy(\.isHexDigit)
        }
    }

    private var installedRoot: String { root + "/installed" }
    private var activeRoot: String { root + "/active" }
    private var downloadsRoot: String { root + "/downloads" }
    private var stagingRoot: String { root + "/staging" }
    private func activePath(_ id: DoryComponentID) -> String { activeRoot + "/\(id.rawValue).json" }
    private func installationRoot(id: DoryComponentID, name: String) -> String {
        installedRoot + "/\(id.rawValue)/" + name
    }

    private func verifyFile(_ path: String, bytes: UInt64, digest: String) throws {
        guard try Self.regularFileSize(path) == bytes else {
            throw DoryComponentError.digestMismatch(path)
        }
        guard try DoryComponentCatalogVerifier.fileDigest(path) == digest else {
            throw DoryComponentError.digestMismatch(path)
        }
    }

    private func validateInstalledAssets(_ installed: DoryInstalledComponent) throws {
        let payload = installationRoot(id: installed.id, name: installed.installationName) + "/payload"
        guard installed.assets.count == installed.assetFingerprints.count else {
            throw DoryComponentError.invalidAsset(payload)
        }
        for (asset, expected) in zip(installed.assets, installed.assetFingerprints) {
            guard expected.path == asset.path,
                  try Self.assetFingerprint(payload + "/" + asset.path, asset: asset) == expected else {
                throw DoryComponentError.digestMismatch(payload + "/" + asset.path)
            }
        }
    }

    private static func assetFingerprint(
        _ path: String,
        asset: DoryComponentAsset
    ) throws -> DoryComponentAssetFingerprint {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              UInt64(info.st_size) == asset.installedBytes,
              info.st_mode & 0o077 == 0,
              asset.executable ? info.st_mode & 0o100 != 0 : info.st_mode & 0o111 == 0 else {
            throw DoryComponentError.invalidAsset(path)
        }
        return DoryComponentAssetFingerprint(
            path: asset.path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: UInt64(info.st_size),
            permissions: UInt32(info.st_mode & 0o7777),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private func readRecord<T: Decodable>(_ type: T.Type, at path: String) throws -> T {
        guard let data = try? PrivateRecordFile.read(at: path, maximumBytes: 2 * 1_024 * 1_024),
              let value = try? JSONDecoder().decode(type, from: data) else {
            throw DoryComponentError.invalidAsset(path)
        }
        return value
    }

    private func writeRecord<T: Encodable>(
        _ value: T,
        at path: String,
        fileManager: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try Self.writePrivateFile(try encoder.encode(value) + Data("\n".utf8), to: path, fileManager: fileManager)
    }

    private func pruneStaging(fileManager: FileManager) throws {
        for entry in (try? fileManager.contentsOfDirectory(atPath: stagingRoot)) ?? [] {
            try fileManager.removeItem(atPath: stagingRoot + "/" + entry)
        }
    }

    private func pruneInactiveInstallations(
        for id: DoryComponentID,
        keeping: Set<String>,
        fileManager: FileManager
    ) throws {
        let directory = installedRoot + "/\(id.rawValue)"
        guard FileManager.default.fileExists(atPath: directory) else { return }
        for entry in try fileManager.contentsOfDirectory(atPath: directory) where !keeping.contains(entry) {
            try fileManager.removeItem(atPath: directory + "/" + entry)
        }
    }

    private static func ensurePrivateDirectory(_ path: String, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: path) {
            do {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            } catch {
                throw DoryComponentError.filesystem("create component directory \(path): \(error)")
            }
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else {
            throw DoryComponentError.unsafePath(path)
        }
    }

    private static func regularFileSize(_ path: String) throws -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size >= 0 else {
            throw DoryComponentError.invalidAsset(path)
        }
        return UInt64(info.st_size)
    }

    private static func writePrivateFile(
        _ data: Data,
        to path: String,
        fileManager: FileManager
    ) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try ensurePrivateDirectory(parent, fileManager: fileManager)
        let temporary = parent + "/.\(URL(fileURLWithPath: path).lastPathComponent).\(UUID().uuidString).tmp"
        do {
            try data.write(to: URL(fileURLWithPath: temporary), options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
            try syncFile(temporary)
            guard rename(temporary, path) == 0 else {
                throw DoryComponentError.filesystem("publish component record \(path): errno \(errno)")
            }
            try syncDirectory(parent)
        } catch {
            try? fileManager.removeItem(atPath: temporary)
            throw error
        }
    }

    private static func syncFile(_ path: String) throws {
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw DoryComponentError.filesystem("open \(path) for sync: errno \(errno)") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw DoryComponentError.filesystem("sync \(path): errno \(errno)") }
    }

    private static func syncDirectory(_ path: String) throws {
        let descriptor = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw DoryComponentError.filesystem("open \(path) for sync: errno \(errno)") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw DoryComponentError.filesystem("sync \(path): errno \(errno)") }
    }

    private static func decompressLZFSE(
        source: String,
        destination: String,
        maximumBytes: UInt64
    ) throws {
        guard maximumBytes > 0, maximumBytes <= UInt64(Int.max) else {
            throw DoryComponentError.invalidAsset("\(source) (invalid declared LZFSE size)")
        }
        let input = source.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard input >= 0 else { throw DoryComponentError.invalidAsset(source) }
        defer { close(input) }
        var inputInfo = stat()
        guard fstat(input, &inputInfo) == 0,
              inputInfo.st_mode & S_IFMT == S_IFREG,
              inputInfo.st_size > 0,
              UInt64(inputInfo.st_size) <= UInt64(Int.max) else {
            throw DoryComponentError.invalidAsset(source)
        }
        let output = destination.withCString {
            open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard output >= 0 else {
            throw DoryComponentError.filesystem("create decompressed component asset: errno \(errno)")
        }
        defer { close(output) }
        guard ftruncate(output, off_t(maximumBytes)) == 0 else {
            throw DoryComponentError.filesystem("size decompressed component asset: errno \(errno)")
        }
        let inputSize = Int(inputInfo.st_size)
        let outputSize = Int(maximumBytes)
        let inputMap = mmap(nil, inputSize, PROT_READ, MAP_PRIVATE, input, 0)
        guard inputMap != MAP_FAILED else {
            throw DoryComponentError.filesystem("map compressed component asset: errno \(errno)")
        }
        defer { munmap(inputMap, inputSize) }
        let outputMap = mmap(nil, outputSize, PROT_READ | PROT_WRITE, MAP_SHARED, output, 0)
        guard outputMap != MAP_FAILED else {
            throw DoryComponentError.filesystem("map decompressed component asset: errno \(errno)")
        }
        defer { munmap(outputMap, outputSize) }
        let decoded = compression_decode_buffer(
            outputMap!.assumingMemoryBound(to: UInt8.self),
            outputSize,
            inputMap!.assumingMemoryBound(to: UInt8.self),
            inputSize,
            nil,
            COMPRESSION_LZFSE
        )
        guard decoded == outputSize else {
            throw DoryComponentError.invalidAsset("\(source) (LZFSE output does not match its signed size)")
        }
        guard msync(outputMap, outputSize, MS_SYNC) == 0 else {
            throw DoryComponentError.filesystem("sync decompressed component asset: errno \(errno)")
        }
    }
}

public struct DoryComponentProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case downloading
        case verifying
        case installing
        case complete
    }

    public let component: DoryComponentID
    public let phase: Phase
    public let completedBytes: UInt64
    public let totalBytes: UInt64
}

public actor DoryComponentInstaller {
    public typealias Progress = @Sendable (DoryComponentProgress) -> Void

    private let store: DoryComponentStore
    private let session: URLSession

    public init(store: DoryComponentStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    public func install(
        _ release: DoryComponentRelease,
        catalogData: Data,
        progress: @escaping Progress = { _ in }
    ) async throws -> DoryInstalledComponent {
        guard release.id.isRemovable else { throw DoryComponentError.coreCannotBeChanged }
        try store.prepare()
        var downloaded: [String: String] = [:]
        var completed: UInt64 = 0
        for asset in release.assets {
            let completedBeforeAsset = completed
            progress(DoryComponentProgress(
                component: release.id,
                phase: .downloading,
                completedBytes: completed,
                totalBytes: release.downloadBytes
            ))
            let path = try await download(asset) { assetBytes in
                progress(DoryComponentProgress(
                    component: release.id,
                    phase: .downloading,
                    completedBytes: completedBeforeAsset + assetBytes,
                    totalBytes: release.downloadBytes
                ))
            }
            completed += asset.downloadBytes
            downloaded[asset.path] = path
        }
        progress(DoryComponentProgress(
            component: release.id,
            phase: .verifying,
            completedBytes: release.downloadBytes,
            totalBytes: release.downloadBytes
        ))
        let installed = try store.install(
            release,
            catalogDigest: DoryComponentCatalogVerifier.digest(catalogData),
            downloadedAssets: downloaded
        )
        for path in downloaded.values { try? FileManager.default.removeItem(atPath: path) }
        progress(DoryComponentProgress(
            component: release.id,
            phase: .complete,
            completedBytes: release.downloadBytes,
            totalBytes: release.downloadBytes
        ))
        return installed
    }

    private func download(
        _ asset: DoryComponentAsset,
        progress: @escaping @Sendable (UInt64) -> Void
    ) async throws -> String {
        guard let url = URL(string: asset.url) else { throw DoryComponentError.download(asset.url) }
        let destination = store.downloadsDirectory + "/\(asset.sha256).part"
        if url.isFileURL {
            try? FileManager.default.removeItem(atPath: destination)
            try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: destination))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination)
            progress(asset.downloadBytes)
            return destination
        }
        guard url.scheme == "https" else { throw DoryComponentError.download("HTTPS is required") }
        var offset: UInt64 = 0
        var partialInfo = stat()
        if lstat(destination, &partialInfo) == 0 {
            guard partialInfo.st_mode & S_IFMT == S_IFREG,
                  partialInfo.st_uid == getuid(),
                  partialInfo.st_nlink == 1,
                  partialInfo.st_size >= 0 else {
                throw DoryComponentError.unsafePath(destination)
            }
            offset = UInt64(partialInfo.st_size)
        } else if errno != ENOENT {
            throw DoryComponentError.filesystem("inspect partial component download: errno \(errno)")
        }
        if offset > asset.downloadBytes {
            try FileManager.default.removeItem(atPath: destination)
            offset = 0
        }
        if offset == asset.downloadBytes,
           (try? DoryComponentCatalogVerifier.fileDigest(destination)) == asset.sha256 {
            progress(offset)
            return destination
        }
        if offset == asset.downloadBytes {
            try FileManager.default.removeItem(atPath: destination)
            offset = 0
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 300
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 || http.statusCode == 206 else {
            throw DoryComponentError.download("server rejected \(url.absoluteString)")
        }
        if offset > 0, http.statusCode == 206 {
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard contentRange.hasPrefix("bytes \(offset)-") else {
                try? FileManager.default.removeItem(atPath: destination)
                throw DoryComponentError.download("server returned an invalid resume range")
            }
        }
        if offset > 0, http.statusCode != 206 {
            try? FileManager.default.removeItem(atPath: destination)
            offset = 0
        }
        if !FileManager.default.fileExists(atPath: destination) {
            FileManager.default.createFile(atPath: destination, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: destination))
        defer { try? handle.close() }
        if offset == 0 { try handle.truncate(atOffset: 0) } else { try handle.seekToEnd() }
        var buffer = Data()
        buffer.reserveCapacity(256 * 1_024)
        var received = offset
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 256 * 1_024 {
                    try handle.write(contentsOf: buffer)
                    received += UInt64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    guard received <= asset.downloadBytes else {
                        throw DoryComponentError.download("server exceeded declared size")
                    }
                    progress(received)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += UInt64(buffer.count)
                progress(received)
            }
            try handle.synchronize()
        } catch is CancellationError {
            throw DoryComponentError.interrupted(asset.path)
        }
        guard received == asset.downloadBytes,
              try DoryComponentCatalogVerifier.fileDigest(destination) == asset.sha256 else {
            try? FileManager.default.removeItem(atPath: destination)
            throw DoryComponentError.digestMismatch(asset.path)
        }
        return destination
    }
}

public actor DoryComponentCatalogClient {
    private let catalogURL: URL
    private let publicKey: String
    private let expectedArchitecture: String
    private let appVersion: String
    private let session: URLSession

    public init(
        catalogURL: URL,
        publicKey: String,
        expectedArchitecture: String,
        appVersion: String,
        session: URLSession = .shared
    ) {
        self.catalogURL = catalogURL
        self.publicKey = publicKey
        self.expectedArchitecture = expectedArchitecture
        self.appVersion = appVersion
        self.session = session
    }

    public func fetch() async throws -> (catalog: DoryComponentCatalog, data: Data, signature: String) {
        let signatureURL = catalogURL.appendingPathExtension("sig")
        async let catalogResult = session.data(from: catalogURL)
        async let signatureResult = session.data(from: signatureURL)
        let ((data, catalogResponse), (signatureData, signatureResponse)) = try await (catalogResult, signatureResult)
        try validateResponse(catalogResponse, url: catalogURL)
        try validateResponse(signatureResponse, url: signatureURL)
        guard data.count <= DoryComponentCatalogVerifier.maximumCatalogBytes,
              signatureData.count <= 1_024,
              let signature = String(data: signatureData, encoding: .utf8) else {
            throw DoryComponentError.invalidCatalog("downloaded metadata is too large")
        }
        let catalog = try DoryComponentCatalogVerifier.verify(
            catalogData: data,
            signatureBase64: signature,
            publicKeyBase64: publicKey,
            expectedArchitecture: expectedArchitecture,
            appVersion: appVersion
        )
        return (catalog, data, signature.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func validateResponse(_ response: URLResponse, url: URL) throws {
        if url.isFileURL { return }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DoryComponentError.download("metadata server returned an error")
        }
    }
}
