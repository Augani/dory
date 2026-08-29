import Foundation
import Testing
@testable import DoryVMContracts

@Suite struct DoryVMContractsDependencyBoundaryTests {
    @Test func targetIsALeafAndSourcesImportOnlyFoundationAndCryptoKit() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let declaration = try #require(targetDeclaration(named: "DoryVMContracts", in: manifest))
        #expect(declaration.contains("dependencies: []"))

        let sourceRoot = packageRoot.appendingPathComponent("Sources/DoryVMContracts")
        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!sourceFiles.isEmpty)

        let allowedImports: Set<String> = ["Foundation", "CryptoKit"]
        var importedModules = Set<String>()
        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count == 2, fields[0] == "import" {
                    importedModules.insert(String(fields[1]))
                }
            }
        }
        #expect(importedModules.isSubset(of: allowedImports))

        for forbidden in [
            "DoryOperations", "DoryCore", "DorydKit", "DoryVMMKit",
            "AppKit", "Hypervisor", "Virtualization",
        ] {
            #expect(!importedModules.contains(forbidden))
            #expect(!declaration.contains("\"\(forbidden)\""))
        }
    }

    private func targetDeclaration(named name: String, in manifest: String) -> String? {
        let targetPrefix = ".target(\n            name: \"\(name)\""
        guard let start = manifest.range(of: targetPrefix) else { return nil }
        guard let end = manifest[start.upperBound...].range(of: "\n        ),") else {
            return nil
        }
        return String(manifest[start.lowerBound..<end.upperBound])
    }
}
