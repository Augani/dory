import DoryCore
import Foundation

public struct MachineRecipeProvisionResult: Sendable, Equatable {
    public var recipeID: String
    public var install: DoryExecResult
    public var verify: DoryExecResult
}

public enum MachineRecipeProvisionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownRecipe(String)
    case commandFailed(recipe: String, stage: String, exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case let .unknownRecipe(recipe):
            return "unknown machine recipe: \(recipe)"
        case let .commandFailed(recipe, stage, exitCode, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "machine recipe \(recipe) \(stage) failed with exit code \(exitCode)\(detail.isEmpty ? "" : ": \(detail)")"
        }
    }
}

public enum MachineRecipeProvisioner {
    public struct Recipe: Sendable, Equatable {
        public var id: String
        public var installScript: String
        public var verifyCommand: String
        public var timeoutMs: UInt64
        public var outputLimitBytes: UInt64
    }

    private static func packageInstallScript(alpine: String, debian: String) -> String {
        """
        if command -v apk >/dev/null 2>&1; then
          apk add --no-cache \(alpine)
        elif command -v apt-get >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update
          apt-get install -y --no-install-recommends \(debian)
          rm -rf /var/lib/apt/lists/*
        else
          echo "Dory recipes support Alpine apk and Debian apt guests" >&2
          exit 69
        fi
        """
    }

    public static func recipe(id rawID: String) throws -> Recipe {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch id {
        case "rust", "rust-dev":
            return Recipe(
                id: "rust",
                installScript: packageInstallScript(
                    alpine: "cargo rust",
                    debian: "cargo rustc build-essential pkg-config"
                ),
                verifyCommand: "cargo --version",
                timeoutMs: 600_000,
                outputLimitBytes: 4 * 1024 * 1024
            )
        case "node", "nodejs":
            return Recipe(
                id: "node",
                installScript: packageInstallScript(
                    alpine: "nodejs npm",
                    debian: "nodejs npm build-essential"
                ),
                verifyCommand: "node --version && npm --version",
                timeoutMs: 600_000,
                outputLimitBytes: 4 * 1024 * 1024
            )
        case "go", "golang":
            return Recipe(
                id: "go",
                installScript: packageInstallScript(alpine: "go", debian: "golang-go"),
                verifyCommand: "go version",
                timeoutMs: 600_000,
                outputLimitBytes: 4 * 1024 * 1024
            )
        case "java", "jvm":
            return Recipe(
                id: "java",
                installScript: packageInstallScript(
                    alpine: "openjdk21 maven",
                    debian: "openjdk-21-jdk-headless maven"
                ),
                verifyCommand: "java -version && mvn --version",
                timeoutMs: 600_000,
                outputLimitBytes: 4 * 1024 * 1024
            )
        case "ruby":
            return Recipe(
                id: "ruby",
                installScript: packageInstallScript(
                    alpine: "ruby ruby-bundler build-base",
                    debian: "ruby-full ruby-bundler build-essential"
                ),
                verifyCommand: "ruby --version && bundle --version",
                timeoutMs: 600_000,
                outputLimitBytes: 4 * 1024 * 1024
            )
        case "python", "python-ml":
            return Recipe(
                id: "python-ml",
                installScript: packageInstallScript(
                    alpine: "python3 py3-pip py3-numpy",
                    debian: "python3 python3-pip python3-numpy python3-venv"
                ),
                verifyCommand: "python3 --version && python3 -m pip --version && python3 -c 'import numpy'",
                timeoutMs: 600_000,
                outputLimitBytes: 4 * 1024 * 1024
            )
        case "docker-host", "docker-cli":
            return Recipe(
                id: "docker-host",
                installScript: packageInstallScript(alpine: "docker-cli", debian: "docker-cli"),
                verifyCommand: "docker --version",
                timeoutMs: 120_000,
                outputLimitBytes: 1024 * 1024
            )
        case "devops":
            return Recipe(
                id: "devops",
                installScript: packageInstallScript(
                    alpine: "docker-cli kubectl",
                    debian: "docker-cli kubectl"
                ),
                verifyCommand: "docker --version && kubectl version --client=true",
                timeoutMs: 600_000,
                outputLimitBytes: 4 * 1024 * 1024
            )
        case "k8s", "k8s-lab", "kubectl":
            return Recipe(
                id: "k8s-lab",
                installScript: packageInstallScript(alpine: "kubectl", debian: "kubectl"),
                verifyCommand: "kubectl version --client=true",
                timeoutMs: 600_000,
                outputLimitBytes: 4 * 1024 * 1024
            )
        default:
            throw MachineRecipeProvisionError.unknownRecipe(rawID)
        }
    }

    public static func provision(
        machineID: String,
        recipeID: String,
        manager: MachineManager
    ) throws -> MachineRecipeProvisionResult {
        let recipe = try recipe(id: recipeID)
        let install = try manager.exec(
            id: machineID,
            argv: ["/bin/sh", "-lc", recipe.installScript],
            timeoutMs: recipe.timeoutMs,
            outputLimitBytes: recipe.outputLimitBytes
        )
        try requireSuccess(install, recipe: recipe.id, stage: "install")
        let verify = try manager.exec(
            id: machineID,
            argv: ["/bin/sh", "-lc", recipe.verifyCommand],
            timeoutMs: recipe.timeoutMs,
            outputLimitBytes: recipe.outputLimitBytes
        )
        try requireSuccess(verify, recipe: recipe.id, stage: "verify")
        return MachineRecipeProvisionResult(recipeID: recipe.id, install: install, verify: verify)
    }

    static func requireSuccess(
        _ result: DoryExecResult,
        recipe: String,
        stage: String
    ) throws {
        guard result.exitCode == 0, !result.timedOut else {
            throw MachineRecipeProvisionError.commandFailed(
                recipe: recipe,
                stage: stage,
                exitCode: result.timedOut ? 124 : result.exitCode,
                stderr: String(decoding: result.stderr, as: UTF8.self)
            )
        }
    }
}
