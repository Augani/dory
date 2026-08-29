import DoryOperations
import DoryRendererWorkerWireContracts
import Foundation
import MachO
import Security

/// Fail-closed decoding and acquisition failures for the renderer identity sealed into the live
/// production daemon's signed Mach-O image.
enum DoryRendererReleaseIdentityError: Error, Equatable, Sendable {
    case productionDaemonIdentityUnavailable
    case embeddedIdentityUnavailable
    case nonCanonicalIdentity
    case unsupportedSchemaVersion(Int)
    case invalidCodeDirectoryHash(field: String)
    case tupleDefinitionMismatch
}

/// The acyclic release binding produced after the nested worker and runner receive their final
/// signatures and before doryd receives its final signature. It intentionally does not contain
/// doryd's own CDHash.
struct DoryRendererReleaseIdentityV1: Equatable, Sendable {
    static let machOSegmentName = "__TEXT"
    static let machOSectionName = "__doryid"
    static let schemaVersion = 1

    private static let schemaVersionKey = "schema-version"
    private static let runnerCDHashKey = "runner-cdhash"
    private static let rendererWorkerCDHashKey = "renderer-worker-cdhash"
    private static let tupleDefinitionSHA256Key = "tuple-definition-sha256"
    private static let canonicalKeys: Set<String> = [
        schemaVersionKey,
        runnerCDHashKey,
        rendererWorkerCDHashKey,
        tupleDefinitionSHA256Key,
    ]

    let runnerCodeDirectoryHash: DoryCodeDirectoryHash
    let rendererWorkerCodeDirectoryHash: DoryCodeDirectoryHash
    let tupleDefinitionSHA256: DoryRendererArtifactDigest

    /// Decodes the already-parsed embedded plist. Exact keys, scalar types, lowercase hash
    /// spellings, and the compiled tuple definition are all part of the canonical form.
    static func decode(identityDictionary: [String: Any]) throws -> Self {
        guard Set(identityDictionary.keys) == canonicalKeys,
              let rawSchemaVersion = exactInteger(
                identityDictionary[schemaVersionKey]
              ),
              let runnerCDHash = identityDictionary[runnerCDHashKey] as? String,
              let rendererWorkerCDHash =
                identityDictionary[rendererWorkerCDHashKey] as? String,
              let tupleDefinitionSHA256 =
                identityDictionary[tupleDefinitionSHA256Key] as? String else {
            throw DoryRendererReleaseIdentityError.nonCanonicalIdentity
        }
        guard rawSchemaVersion == schemaVersion else {
            throw DoryRendererReleaseIdentityError.unsupportedSchemaVersion(
                rawSchemaVersion
            )
        }
        guard tupleDefinitionSHA256
                == DoryRendererSourceTuple.productionDefinitionSHA256 else {
            throw DoryRendererReleaseIdentityError.tupleDefinitionMismatch
        }

        let runner: DoryCodeDirectoryHash
        do {
            runner = try DoryCodeDirectoryHash(
                lowercaseHexadecimal: runnerCDHash,
                field: runnerCDHashKey
            )
        } catch {
            throw DoryRendererReleaseIdentityError.invalidCodeDirectoryHash(
                field: runnerCDHashKey
            )
        }
        let worker: DoryCodeDirectoryHash
        do {
            worker = try DoryCodeDirectoryHash(
                lowercaseHexadecimal: rendererWorkerCDHash,
                field: rendererWorkerCDHashKey
            )
        } catch {
            throw DoryRendererReleaseIdentityError.invalidCodeDirectoryHash(
                field: rendererWorkerCDHashKey
            )
        }
        let tuple: DoryRendererArtifactDigest
        do {
            tuple = try DoryRendererArtifactDigest(
                lowercaseSHA256: tupleDefinitionSHA256,
                field: tupleDefinitionSHA256Key
            )
        } catch {
            // Equality with the compiled definition should make this unreachable, but decoding
            // still fails closed if that compile-time constant is malformed.
            throw DoryRendererReleaseIdentityError.nonCanonicalIdentity
        }
        return Self(
            runnerCodeDirectoryHash: runner,
            rendererWorkerCodeDirectoryHash: worker,
            tupleDefinitionSHA256: tuple
        )
    }

    /// Swift can bridge CFBoolean and floating-point NSNumber values through surprising numeric
    /// casts. Embedded identity schema versions accept only a lossless integer CFNumber scalar.
    private static func exactInteger(_ value: Any?) -> Int? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == CFNumberGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        let objectiveCType = String(cString: number.objCType)
        guard objectiveCType != "f", objectiveCType != "d" else { return nil }
        let signedValue = number.int64Value
        guard number.compare(NSNumber(value: signedValue)) == .orderedSame else {
            return nil
        }
        return Int(exactly: signedValue)
    }
}

/// Injection seam for production trust composition and pure tests. No caller should infer release
/// identity from the installed Runner or Worker path when this provider is unavailable.
protocol DoryRendererReleaseIdentityProviding: Sendable {
    func loadReleaseIdentity() throws -> DoryRendererReleaseIdentityV1
}

/// Selects live renderer identity authority only for the exact production capability that can
/// consume it. This keeps VZ, software display, classic virgl display, and legacy launches free of
/// renderer-release-identity dependencies while making Venus admission fail closed.
enum DoryProductionRendererReleaseIdentityAuthority {
    static func resolve(
        backend: DoryVirtualizationBackendIdentity,
        graphics: DoryGraphicsAccelerationLevel,
        provider: any DoryRendererReleaseIdentityProviding
    ) throws -> DoryDaemonVirtualMachinePreSpawnLaunchAuthority {
        guard backend == .doryHypervisor,
              graphics == .hardwareAccelerated3D else {
            return .noRendererReleaseIdentityRequired
        }
        let identity = try provider.loadReleaseIdentity()
        guard identity.tupleDefinitionSHA256.lowercaseSHA256
                == DoryRendererSourceTuple.productionDefinitionSHA256 else {
            throw DoryRendererReleaseIdentityError.tupleDefinitionMismatch
        }
        return .rendererReleaseIdentity(identity)
    }
}

/// Reads the canonical identity plist embedded in the live doryd Mach-O after proving that the
/// running task satisfies doryd's complete production requirement. The __TEXT section is covered
/// by doryd's own Code Directory, so no adjacent file or mutable bundle metadata is trusted.
struct DoryEmbeddedRendererReleaseIdentityProvider:
    DoryRendererReleaseIdentityProviding,
    Sendable
{
    func loadReleaseIdentity() throws -> DoryRendererReleaseIdentityV1 {
        guard DorydXPCSecurity.currentProcessSatisfiesProductionDaemonRequirement() else {
            throw DoryRendererReleaseIdentityError.productionDaemonIdentityUnavailable
        }
        guard let data = Self.embeddedIdentityData() else {
            throw DoryRendererReleaseIdentityError.embeddedIdentityUnavailable
        }
        let value: Any
        do {
            value = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw DoryRendererReleaseIdentityError.nonCanonicalIdentity
        }
        guard let dictionary = value as? [String: Any] else {
            throw DoryRendererReleaseIdentityError.nonCanonicalIdentity
        }
        return try DoryRendererReleaseIdentityV1.decode(identityDictionary: dictionary)
    }

    private static func embeddedIdentityData() -> Data? {
        guard let imageHeader = _dyld_get_image_header(0),
              imageHeader.pointee.magic == MH_MAGIC_64 else {
            return nil
        }
        let header = UnsafeRawPointer(imageHeader)
            .assumingMemoryBound(to: mach_header_64.self)
        var size: UInt = 0
        let bytes = getsectiondata(
            header,
            DoryRendererReleaseIdentityV1.machOSegmentName,
            DoryRendererReleaseIdentityV1.machOSectionName,
            &size
        )
        guard let bytes, size > 0, size <= 1_048_576,
              let count = Int(exactly: size) else {
            return nil
        }
        return Data(bytes: bytes, count: count)
    }
}
