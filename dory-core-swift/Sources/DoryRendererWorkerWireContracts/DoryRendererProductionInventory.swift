import CryptoKit
import Foundation

public enum DoryRendererProductionInventoryError: Error, Equatable, Sendable {
    case nonCanonicalJSON
    case schemaMismatch
    case definitionMismatch
    case componentMismatch(String)
}

/// Canonical, path-relative renderer bundle identity shared by the daemon and signed worker.
/// This type parses identity only; each process must still open the named files beneath its own
/// already-authorized runner Contents descriptor and compare byte count plus SHA-256.
public struct DoryRendererProductionInventory: Equatable, Sendable {
    public enum ComponentIdentity {
        public static let candidateInventory = "dory-renderer-inventory"
        public static let guestMesa = "dory-renderer-guest-mesa"
        public static let worker = "dory-renderer-worker"
    }

    public struct FileRecord: Equatable, Sendable {
        public let path: String
        public let byteCount: UInt64
        public let sha256: DoryRendererArtifactDigest
    }

    public struct Component: Equatable, Sendable {
        public let name: String
        public let digest: DoryRendererArtifactDigest
        public let files: [FileRecord]
    }

    public static let relativePath = "Resources/renderer-production-inventory.json"
    public static let rendererWorkerRelativePath =
        "XPCServices/DoryRendererWorker.xpc/Contents/MacOS/DoryRendererWorker"
    public static let angleEGLRelativePath =
        "XPCServices/DoryRendererWorker.xpc/Contents/Frameworks/libEGL.dylib"
    public static let angleGLESv2RelativePath =
        "XPCServices/DoryRendererWorker.xpc/Contents/Frameworks/libGLESv2.dylib"
    public static let maximumEncodedBytes = 1_024 * 1_024
    public static let maximumArtifactBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    public static let expectedFiles: [String: [String]] = [
        "angleMetal": [angleEGLRelativePath, angleGLESv2RelativePath],
        "rendererWorker": [rendererWorkerRelativePath],
    ]

    public let candidateInventory: DoryRendererArtifactDigest
    public let definition: DoryRendererArtifactDigest
    public let components: [String: Component]

    public static func decodeCanonical(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let canonical = try? canonicalJSONData(root),
              data == canonical + Data("\n".utf8) else {
            throw DoryRendererProductionInventoryError.nonCanonicalJSON
        }
        let rootKeys: Set<String> = [
            "architecture", "buildPolicy", "components", "dependencyBuildPolicy",
            "dependencySources", "definitionSha256", "guestMesaBuildPolicy", "kind",
            "platform", "producerFence", "profile", "schemaVersion", "sourceTuple",
            "sources", "toolchain",
        ]
        guard Set(root.keys) == rootKeys,
              root["kind"] as? String == "dev.dory.renderer-artifact-inventory",
              unsigned(root["schemaVersion"]) == 3,
              root["profile"] as? String == "rendererBundle",
              root["sourceTuple"] as? String == "dory-dual-metal-20260826",
              root["architecture"] as? String == "arm64",
              root["platform"] as? String == "macos",
              let definitionHex = root["definitionSha256"] as? String else {
            throw DoryRendererProductionInventoryError.schemaMismatch
        }
        let definition = try DoryRendererArtifactDigest(
            lowercaseSHA256: definitionHex,
            field: "definitionSha256"
        )
        guard definitionHex == DoryRendererSourceTuple.productionDefinitionSHA256 else {
            throw DoryRendererProductionInventoryError.definitionMismatch
        }
        guard let rawComponents = root["components"] as? [String: Any],
              Set(rawComponents.keys) == Set(expectedFiles.keys) else {
            throw DoryRendererProductionInventoryError.schemaMismatch
        }

        var decodedComponents = [String: Component]()
        for name in expectedFiles.keys.sorted() {
            guard let expectedPaths = expectedFiles[name],
                  let rawComponent = rawComponents[name] as? [String: Any],
                  Set(rawComponent.keys) == Set(["digest", "files"]),
                  let componentHex = rawComponent["digest"] as? String,
                  let rawFiles = rawComponent["files"] as? [[String: Any]],
                  rawFiles.count == expectedPaths.count else {
                throw DoryRendererProductionInventoryError.componentMismatch(name)
            }
            let componentDigest = try DoryRendererArtifactDigest(
                lowercaseSHA256: componentHex,
                field: name
            )
            var files = [FileRecord]()
            for (rawFile, expectedPath) in zip(rawFiles, expectedPaths) {
                guard Set(rawFile.keys) == Set(["bytes", "path", "sha256"]),
                      rawFile["path"] as? String == expectedPath,
                      let byteCount = unsigned(rawFile["bytes"]),
                      byteCount > 0, byteCount <= maximumArtifactBytes,
                      let sha256 = rawFile["sha256"] as? String else {
                    throw DoryRendererProductionInventoryError.componentMismatch(name)
                }
                files.append(FileRecord(
                    path: expectedPath,
                    byteCount: byteCount,
                    sha256: try DoryRendererArtifactDigest(
                        lowercaseSHA256: sha256,
                        field: expectedPath
                    )
                ))
            }
            let digestObject: [String: Any] = ["files": rawFiles, "name": name]
            guard let digestBytes = try? canonicalJSONData(digestObject) else {
                throw DoryRendererProductionInventoryError.componentMismatch(name)
            }
            let computed = SHA256.hash(data: digestBytes + Data("\n".utf8))
            guard Data(computed) == componentDigest.bytes else {
                throw DoryRendererProductionInventoryError.componentMismatch(name)
            }
            decodedComponents[name] = Component(
                name: name,
                digest: componentDigest,
                files: files
            )
        }

        return Self(
            candidateInventory: try DoryRendererArtifactDigest(
                bytes: Data(SHA256.hash(data: data)),
                field: "candidateInventory"
            ),
            definition: definition,
            components: decodedComponents
        )
    }

    public func componentDigest(_ name: String) throws -> DoryRendererArtifactDigest {
        guard let component = components[name] else {
            throw DoryRendererProductionInventoryError.componentMismatch(name)
        }
        return component.digest
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let signed = number.int64Value
        guard signed >= 0, number.doubleValue == Double(signed) else { return nil }
        return UInt64(signed)
    }

    /// Encodes the renderer inventory's cross-language canonical JSON form. Packaging and
    /// out-of-module fixture producers must use this exact UTF-8 byte ordering instead of
    /// Foundation's locale-sensitive `sortedKeys` comparison. The returned data excludes the
    /// inventory format's required trailing newline so it can also encode component-digest input.
    public static func canonicalJSONData(_ value: Any) throws -> Data {
        if let dictionary = value as? [String: Any] {
            var result = Data("{".utf8)
            let keys = dictionary.keys.sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }
            for (index, key) in keys.enumerated() {
                if index > 0 { result.append(UInt8(ascii: ",")) }
                result.append(try canonicalJSONString(key))
                result.append(UInt8(ascii: ":"))
                guard let child = dictionary[key] else {
                    throw DoryRendererProductionInventoryError.nonCanonicalJSON
                }
                result.append(try canonicalJSONData(child))
            }
            result.append(UInt8(ascii: "}"))
            return result
        }
        if let array = value as? [Any] {
            var result = Data("[".utf8)
            for (index, child) in array.enumerated() {
                if index > 0 { result.append(UInt8(ascii: ",")) }
                result.append(try canonicalJSONData(child))
            }
            result.append(UInt8(ascii: "]"))
            return result
        }
        if let string = value as? String {
            return try canonicalJSONString(string)
        }
        if value is NSNull {
            return Data("null".utf8)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return Data((number.boolValue ? "true" : "false").utf8)
            }
            let objectiveCType = String(cString: number.objCType)
            guard objectiveCType != "f", objectiveCType != "d" else {
                throw DoryRendererProductionInventoryError.nonCanonicalJSON
            }
            let signed = number.int64Value
            guard number.compare(NSNumber(value: signed)) == .orderedSame else {
                throw DoryRendererProductionInventoryError.nonCanonicalJSON
            }
            return Data(String(signed).utf8)
        }
        throw DoryRendererProductionInventoryError.nonCanonicalJSON
    }

    private static func canonicalJSONString(_ value: String) throws -> Data {
        let wrapped = try JSONSerialization.data(
            withJSONObject: [value],
            options: [.withoutEscapingSlashes]
        )
        guard wrapped.count >= 2,
              wrapped.first == UInt8(ascii: "["),
              wrapped.last == UInt8(ascii: "]") else {
            throw DoryRendererProductionInventoryError.nonCanonicalJSON
        }
        return Data(wrapped.dropFirst().dropLast())
    }
}
