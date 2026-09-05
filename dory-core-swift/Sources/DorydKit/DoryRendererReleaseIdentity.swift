import DoryOperations
import DoryRendererWorkerWireContracts
import Foundation
import Security

/// Fail-closed decoding and acquisition failures for the renderer identity sealed into the live
/// production daemon's signed executable metadata. The payload is identity data only; it grants no
/// OS privilege and is accepted only after the live daemon satisfies its production requirement.
enum DoryRendererReleaseIdentityError: Error, Equatable, Sendable {
    case productionDaemonIdentityUnavailable
    case currentTaskUnavailable
    case signingInformationUnavailable
    case securedInfoPlistUnavailable
    case identityUnavailable
    case nonCanonicalIdentity
    case unsupportedSchemaVersion(Int)
    case invalidCodeDirectoryHash(field: String)
    case tupleDefinitionMismatch
    case releaseIdentityMismatch
}

/// The acyclic release binding produced after the nested worker and runner receive their final
/// signatures and before doryd receives its final signature. It intentionally does not contain
/// doryd's own CDHash.
struct DoryRendererReleaseIdentityV1: Equatable, Sendable {
    static let securedInfoPlistKey = "DoryRendererReleaseIdentityV1"
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

    /// Decodes the already-parsed signed identity value. Exact keys, scalar types, lowercase hash
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

/// Reads the secured Info.plist embedded in the live doryd executable, after proving that the task
/// satisfies doryd's complete production requirement. Mutable bundle resources, adjacent files,
/// environment variables, and unprovisionable private entitlements are never inputs.
struct DoryCurrentTaskRendererReleaseIdentityProvider:
    DoryRendererReleaseIdentityProviding,
    Sendable
{
    func loadReleaseIdentity() throws -> DoryRendererReleaseIdentityV1 {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else {
            throw DoryRendererReleaseIdentityError.currentTaskUnavailable
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            DorydXPCSecurity.productionDaemonRequirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement,
        SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess else {
            throw DoryRendererReleaseIdentityError.productionDaemonIdentityUnavailable
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
                == errSecSuccess else {
            throw DoryRendererReleaseIdentityError.signingInformationUnavailable
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let values = signingInformation as? [CFString: Any] else {
            throw DoryRendererReleaseIdentityError.signingInformationUnavailable
        }
        guard let securedInfoPlist = values[kSecCodeInfoPList] as? [String: Any] else {
            throw DoryRendererReleaseIdentityError.securedInfoPlistUnavailable
        }
        guard let dictionary = securedInfoPlist[
            DoryRendererReleaseIdentityV1.securedInfoPlistKey
        ] as? [String: Any] else {
            throw DoryRendererReleaseIdentityError.identityUnavailable
        }
        let identity = try DoryRendererReleaseIdentityV1.decode(
            identityDictionary: dictionary
        )
        // Signing information can read disk-backed metadata. Recheck the live code after
        // decoding so an executable substitution cannot become this process's release pin.
        guard SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess else {
            throw DoryRendererReleaseIdentityError.productionDaemonIdentityUnavailable
        }
        return identity
    }
}
