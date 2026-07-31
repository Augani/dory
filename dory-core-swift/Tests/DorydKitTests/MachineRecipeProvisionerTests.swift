import DoryCore
import XCTest
@testable import DorydKit

final class MachineRecipeProvisionerTests: XCTestCase {
    func testBuiltInRecipeAliasesResolveToAlpineAndDebianRecipes() throws {
        let cases: [(String, String, String, String)] = [
            ("agent-ready", "agent-core", "rg --version", "bash build-essential ca-certificates coreutils curl fd-find file findutils git jq less openssh-client patch python3 python3-pip ripgrep tar unzip zip"),
            ("node", "node", "node --version", "nodejs npm build-essential"),
            ("python", "python-ml", "python3 --version", "python3 python3-pip python3-numpy python3-venv"),
            ("go", "go", "go version", "golang-go"),
            ("java", "java", "java -version", "openjdk-21-jdk-headless maven"),
            ("ruby", "ruby", "ruby --version", "ruby-full ruby-bundler build-essential"),
            ("rust", "rust", "cargo --version", "cargo rustc build-essential pkg-config"),
            ("devops", "devops", "docker --version", "docker-cli kubectl"),
            ("docker-cli", "docker-host", "docker --version", "docker-cli"),
            ("kubectl", "k8s-lab", "kubectl version", "kubectl"),
        ]

        for (input, expectedID, verifyNeedle, debianPackages) in cases {
            let recipe = try MachineRecipeProvisioner.recipe(id: input)
            XCTAssertEqual(recipe.id, expectedID, input)
            XCTAssertTrue(recipe.verifyCommand.contains(verifyNeedle), input)
            XCTAssertTrue(recipe.installScript.contains("command -v apk"), input)
            XCTAssertTrue(recipe.installScript.contains("command -v apt-get"), input)
            XCTAssertTrue(recipe.installScript.contains("apt-get install -y --no-install-recommends \(debianPackages)"), input)
            XCTAssertGreaterThan(recipe.timeoutMs, 0, input)
            if expectedID == "agent-core" {
                XCTAssertTrue(recipe.installScript.contains("/usr/local/bin/fd"), input)
                XCTAssertTrue(recipe.verifyCommand.contains("fd --version"), input)
            }
        }
    }

    func testRequiredProvisioningStageRejectsNonzeroExitWithStderr() {
        let result = DoryExecResult(
            exitCode: 17,
            stdout: Data(),
            stderr: Data("missing required configuration".utf8),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        )

        XCTAssertThrowsError(
            try MachineRecipeProvisioner.requireSuccess(result, recipe: "k8s-lab", stage: "install")
        ) { error in
            XCTAssertEqual(
                error as? MachineRecipeProvisionError,
                .commandFailed(
                    recipe: "k8s-lab",
                    stage: "install",
                    exitCode: 17,
                    stderr: "missing required configuration"
                )
            )
        }
    }

    func testRequiredProvisioningStageRejectsTimeoutEvenWithZeroExit() {
        let result = DoryExecResult(
            exitCode: 0,
            stdout: Data(),
            stderr: Data(),
            timedOut: true,
            stdoutTruncated: false,
            stderrTruncated: false
        )

        XCTAssertThrowsError(
            try MachineRecipeProvisioner.requireSuccess(result, recipe: "rust", stage: "verify")
        ) { error in
            XCTAssertEqual(
                error as? MachineRecipeProvisionError,
                .commandFailed(recipe: "rust", stage: "verify", exitCode: 124, stderr: "")
            )
        }
    }
}
