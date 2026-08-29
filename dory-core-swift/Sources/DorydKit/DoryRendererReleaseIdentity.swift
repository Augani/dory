import DoryOperations
import DoryRendererWorkerWireContracts
import Foundation
import Security

/// Fail-closed decoding and acquisition failures for the renderer identity sealed into the live
/// production daemon. The entitlement is an identity carrier only; it grants no OS privilege.
enum DoryRendererReleaseIdentityError: Error, Equatable, Sendable {
    case productionDaemonIdentityUnavailable
    case currentTaskUnavailable
    case entitlementUnavailable
    case nonCanonicalEntitlement
    case unsupportedSchemaVersion(Int)
    case invalidCodeDirectoryHash(field: String)
    case tupleDefinitionMismatch
}

/// The acyclic release binding produced after the nested worker and runner receive their final
/// signatures and before doryd receives its final signature. It intentionally does not contain
/// doryd's own CDHash.
struct DoryRendererReleaseIdentityV1: Equatable, Sendable {
    static let entitlementName = "com.pythonxi.dory.renderer-release-identity.v1"
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

    /// Decodes the already-parsed entitlement value. Exact keys, scalar types, lowercase hash
    /// spellings, and the compiled tuple definition are all part of the canonical form.
    static func decode(entitlementDictionary: [String: Any]) throws -> Self {
        guard Set(entitlementDictionary.keys) == canonicalKeys,
              let rawSchemaVersion = exactInteger(
                entitlementDictionary[schemaVersionKey]
              ),
              let runnerCDHash = entitlementDictionary[runnerCDHashKey] as? String,
              let rendererWorkerCDHash =
                entitlementDictionary[rendererWorkerCDHashKey] as? String,
              let tupleDefinitionSHA256 =
                entitlementDictionary[tupleDefinitionSHA256Key] as? String else {
            throw DoryRendererReleaseIdentityError.nonCanonicalEntitlement
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
            throw DoryRendererReleaseIdentityError.nonCanonicalEntitlement
        }
        return Self(
            runnerCodeDirectoryHash: runner,
            rendererWorkerCodeDirectoryHash: worker,
            tupleDefinitionSHA256: tuple
        )
    }

    /// Swift can bridge CFBoolean and floating-point NSNumber values through surprising numeric
    /// casts. Entitlement schema versions accept only a lossless integer CFNumber scalar.
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
/// renderer-entitlement dependencies while making Venus admission fail closed.
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

/// Reads the entitlement attached to the live doryd task, after proving that the task satisfies
/// doryd's complete production requirement. Adjacent files and bundle metadata are never inputs.
struct DoryCurrentTaskRendererReleaseIdentityProvider:
    DoryRendererReleaseIdentityProviding,
    Sendable
{
    func loadReleaseIdentity() throws -> DoryRendererReleaseIdentityV1 {
        guard DorydXPCSecurity.currentProcessSatisfiesProductionDaemonRequirement() else {
            throw DoryRendererReleaseIdentityError.productionDaemonIdentityUnavailable
        }
        guard let task = SecTaskCreateFromSelf(nil) else {
            throw DoryRendererReleaseIdentityError.currentTaskUnavailable
        }
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            DoryRendererReleaseIdentityV1.entitlementName as CFString,
            nil
        ) else {
            throw DoryRendererReleaseIdentityError.entitlementUnavailable
        }
        guard let dictionary = value as? [String: Any] else {
            throw DoryRendererReleaseIdentityError.nonCanonicalEntitlement
        }
        return try DoryRendererReleaseIdentityV1.decode(
            entitlementDictionary: dictionary
        )
    }
}
