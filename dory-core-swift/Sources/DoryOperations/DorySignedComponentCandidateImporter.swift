import CryptoKit
import Darwin
import Foundation

public struct DorySignedComponentCandidateImportResult: Sendable, Equatable {
    public let operationID: UUID
    public let catalogDigest: String
    public let installed: [DoryInstalledComponent]

    public init(
        operationID: UUID,
        catalogDigest: String,
        installed: [DoryInstalledComponent]
    ) {
        self.operationID = operationID
        self.catalogDigest = catalogDigest
        self.installed = installed
    }
}

/// Installs an immutable pre-publication component set from a local release-candidate directory.
///
/// The directory is only transport. The compiled production key authenticates the exact catalog,
/// and every local filename, byte count, digest, dependency, and installed result is derived from
/// that signed catalog before it can become active.
public struct DorySignedComponentCandidateImporter: Sendable {
    public let store: DoryComponentStore
    private let publicKey: String
    private let expectedArchitecture: String
    private let appVersion: String

    public init(
        store: DoryComponentStore,
        expectedArchitecture: String = DoryComponentDefaults.architecture,
        appVersion: String
    ) {
        self.init(
            store: store,
            publicKey: DoryComponentDefaults.publicKey,
            expectedArchitecture: expectedArchitecture,
            appVersion: appVersion
        )
    }

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

    public func install(
        _ id: DoryComponentID,
        from candidateDirectory: String,
        operationID: UUID = UUID()
    ) throws -> DorySignedComponentCandidateImportResult {
        guard id.isRemovable else { throw DoryComponentError.coreCannotBeChanged }
        guard operationID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw DoryComponentError.invalidOperationID
        }
        let root = try Self.candidateDirectory(candidateDirectory)
        let catalogPath = try Self.candidateFile("catalog.json", in: root)
        let digestPath = try Self.candidateFile("catalog.json.sha256", in: root)
        let signaturePath = try Self.candidateFile("catalog.json.sig", in: root)
        let catalogData = try Self.stableData(catalogPath, maximumBytes: 2 * 1_024 * 1_024)
        let digestData = try Self.stableData(digestPath, maximumBytes: 256)
        let signatureData = try Self.stableData(signaturePath, maximumBytes: 256)
        guard let digestLine = String(data: digestData, encoding: .ascii),
              let signatureLine = String(data: signatureData, encoding: .ascii),
              digestLine == DoryComponentCatalogVerifier.digest(catalogData) + "\n",
              signatureLine == signatureLine.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" else {
            throw DoryComponentError.invalidCatalog("candidate metadata binding is invalid")
        }
        let catalog = try DoryComponentCatalogVerifier.verify(
            catalogData: catalogData,
            signatureBase64: signatureLine,
            publicKeyBase64: publicKey,
            expectedArchitecture: expectedArchitecture,
            appVersion: appVersion
        )
        guard catalog.schemaVersion == DoryComponentCatalog.schemaVersion,
              let qualification = catalog.virtualMachineQualification,
              let publicKeyData = Data(base64Encoded: publicKey),
              publicKeyData.count == 32,
              qualification.signingKeyID == Self.digest(publicKeyData) else {
            throw DoryComponentError.invalidCatalog(
                "candidate does not contain production VM qualification authority"
            )
        }
        let ordered = try Self.installationOrder(id, catalog: catalog)
        let availableIDs = Set(catalog.components.map(\.id))
        guard ordered.allSatisfy({ release in
            release.dependencies.allSatisfy { $0 == .dockerCore || availableIDs.contains($0) }
        }) else {
            throw DoryComponentError.invalidCatalog("candidate dependency is unavailable")
        }

        var sourcesByComponent: [DoryComponentID: [String: String]] = [:]
        var claimedNames: Set<String> = []
        for release in ordered {
            var sources: [String: String] = [:]
            for asset in release.assets {
                guard let url = URL(string: asset.url),
                      url.scheme == "https",
                      url.host == "github.com",
                      url.user == nil,
                      url.password == nil,
                      url.port == nil,
                      url.query == nil,
                      url.fragment == nil,
                      url.path.hasPrefix(
                        "/Augani/dory/releases/download/v\(catalog.releaseVersion)/"
                      ) else {
                    throw DoryComponentError.invalidCatalog(
                        "candidate asset URL is outside the signed Dory release"
                    )
                }
                let name = url.lastPathComponent
                guard DoryComponentCatalogVerifier.safeRelativePath(name),
                      name.hasPrefix(
                        "Dory-\(catalog.releaseVersion)-component-\(release.id.rawValue)-"
                      ),
                      claimedNames.insert(name).inserted else {
                    throw DoryComponentError.invalidCatalog("candidate asset name is invalid")
                }
                sources[asset.path] = try Self.candidateFile(name, in: root)
            }
            sourcesByComponent[release.id] = sources
        }

        _ = try store.cacheCatalog(
            data: catalogData,
            signature: signatureLine,
            publicKey: publicKey,
            expectedArchitecture: expectedArchitecture,
            appVersion: appVersion
        )
        let catalogDigest = DoryComponentCatalogVerifier.digest(catalogData)
        var installed: [DoryInstalledComponent] = []
        for release in ordered {
            let component = try store.install(
                release,
                catalogDigest: catalogDigest,
                downloadedAssets: sourcesByComponent[release.id] ?? [:],
                operationID: operationID
            )
            try store.verify(component)
            installed.append(component)
        }
        return DorySignedComponentCandidateImportResult(
            operationID: operationID,
            catalogDigest: catalogDigest,
            installed: installed
        )
    }

    private static func installationOrder(
        _ id: DoryComponentID,
        catalog: DoryComponentCatalog
    ) throws -> [DoryComponentRelease] {
        var visited: Set<DoryComponentID> = []
        var visiting: Set<DoryComponentID> = []
        var ordered: [DoryComponentRelease] = []
        func append(_ current: DoryComponentID) throws {
            guard current != .dockerCore, !visited.contains(current) else { return }
            guard visiting.insert(current).inserted,
                  let release = catalog.component(current) else {
                throw DoryComponentError.invalidCatalog("candidate dependency graph is invalid")
            }
            for dependency in release.dependencies { try append(dependency) }
            visiting.remove(current)
            visited.insert(current)
            ordered.append(release)
        }
        try append(id)
        return ordered
    }

    private static func candidateDirectory(_ path: String) throws -> String {
        var info = stat()
        guard !path.isEmpty,
              lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o022 == 0 else {
            throw DoryComponentError.invalidAsset(path)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func candidateFile(_ name: String, in root: String) throws -> String {
        guard DoryComponentCatalogVerifier.safeRelativePath(name) else {
            throw DoryComponentError.invalidAsset(name)
        }
        let path = root + "/" + name
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_mode & 0o022 == 0 else {
            throw DoryComponentError.invalidAsset(path)
        }
        return path
    }

    private static func stableData(_ path: String, maximumBytes: Int) throws -> Data {
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw DoryComponentError.invalidAsset(path) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0,
              before.st_size <= maximumBytes else {
            throw DoryComponentError.invalidAsset(path)
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes, 1 << 20))
        while true {
            let count = buffer.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, $0.count)
            }
            guard count >= 0 else {
                throw DoryComponentError.filesystem(
                    "read signed component candidate: errno \(errno)"
                )
            }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else {
                throw DoryComponentError.invalidAsset(path)
            }
            data.append(buffer, count: count)
        }
        var after = stat()
        var current = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(path, &current) == 0,
              Self.sameSnapshot(before, after),
              Self.sameSnapshot(after, current) else {
            throw DoryComponentError.invalidAsset(path)
        }
        return data
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
