import XCTest
@testable import DorydKit

final class MachineRecipeProvisionerTests: XCTestCase {
    func testBuiltInRecipeAliasesResolveToAlpineRecipes() throws {
        let cases: [(String, String, String)] = [
            ("node", "node", "node --version"),
            ("python", "python-ml", "python3 --version"),
            ("go", "go", "go version"),
            ("java", "java", "java -version"),
            ("ruby", "ruby", "ruby --version"),
            ("rust", "rust", "cargo --version"),
            ("devops", "devops", "docker --version"),
            ("docker-cli", "docker-host", "docker --version"),
            ("kubectl", "k8s-lab", "kubectl version"),
        ]

        for (input, expectedID, verifyNeedle) in cases {
            let recipe = try MachineRecipeProvisioner.recipe(id: input)
            XCTAssertEqual(recipe.id, expectedID, input)
            XCTAssertTrue(recipe.verifyCommand.contains(verifyNeedle), input)
            XCTAssertGreaterThan(recipe.timeoutMs, 0, input)
        }
    }
}
