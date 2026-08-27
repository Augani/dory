import DoryCore
import Foundation

public struct MachineRecipeProvisionResult: Sendable, Equatable {
    public var recipeID: String
    public var install: DoryExecResult
    public var verify: DoryExecResult
}

public struct MachineRecipeCapability: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var summary: String
    public var category: String
    public var aliases: [String]
    public var executables: [String]
    public var versionCommand: String
    public var packages: [String: [String]]

    public init(
        id: String,
        displayName: String,
        summary: String,
        category: String,
        aliases: [String] = [],
        executables: [String],
        versionCommand: String,
        packages: [String: [String]]
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.category = category
        self.aliases = aliases
        self.executables = executables
        self.versionCommand = versionCommand
        self.packages = packages
    }
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
        public var capability: MachineRecipeCapability
        public var installScript: String
        public var verifyCommand: String
        public var timeoutMs: UInt64
        public var outputLimitBytes: UInt64

        public var id: String { capability.id }
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

    private static func capability(
        id: String,
        displayName: String,
        summary: String,
        category: String,
        aliases: [String] = [],
        executables: [String],
        versionCommand: String,
        alpinePackages: String,
        debianPackages: String
    ) -> MachineRecipeCapability {
        MachineRecipeCapability(
            id: id,
            displayName: displayName,
            summary: summary,
            category: category,
            aliases: aliases,
            executables: executables,
            versionCommand: versionCommand,
            packages: [
                "alpine": alpinePackages.split(separator: " ").map(String.init),
                "debian": debianPackages.split(separator: " ").map(String.init),
            ]
        )
    }

    private static func recipe(
        capability: MachineRecipeCapability,
        additionalInstallScript: String = "",
        timeoutMs: UInt64 = 600_000,
        outputLimitBytes: UInt64 = 4 * 1024 * 1024
    ) -> Recipe {
        let alpinePackages = capability.packages["alpine", default: []].joined(separator: " ")
        let debianPackages = capability.packages["debian", default: []].joined(separator: " ")
        return Recipe(
            capability: capability,
            installScript: packageInstallScript(
                alpine: alpinePackages,
                debian: debianPackages
            ) + additionalInstallScript,
            verifyCommand: capability.versionCommand,
            timeoutMs: timeoutMs,
            outputLimitBytes: outputLimitBytes
        )
    }

    private static let recipes: [Recipe] = {
        let agentCore = capability(
            id: "agent-core",
            displayName: "Agent Core",
            summary: "Shell, Git, search, patching, archives, SSH, Python, and native build essentials for coding agents.",
            category: "foundation",
            aliases: ["agent", "agent-ready"],
            executables: ["bash", "curl", "fd", "git", "jq", "make", "python3", "rg", "setpriv", "ssh", "tar", "tmux", "unzip", "zip"],
            versionCommand: "bash --version && git --version && curl --version && jq --version && rg --version && fd --version && python3 --version && make --version && setpriv --version && tmux -V",
            alpinePackages: "bash build-base ca-certificates coreutils curl fd file findutils git jq less openssh-client patch python3 py3-pip ripgrep tar tmux unzip util-linux zip",
            debianPackages: "bash build-essential ca-certificates coreutils curl fd-find file findutils git jq less openssh-client patch python3 python3-pip ripgrep tar tmux unzip util-linux zip"
        )
        return [
            recipe(
                capability: agentCore,
                additionalInstallScript: """
                if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
                  ln -sf "$(command -v fdfind)" /usr/local/bin/fd
                fi
                """
            ),
            recipe(capability: capability(
                id: "node", displayName: "Node.js", summary: "Node.js and npm with native addon build support.",
                category: "runtime", aliases: ["nodejs"], executables: ["node", "npm"],
                versionCommand: "node --version && npm --version",
                alpinePackages: "nodejs npm", debianPackages: "nodejs npm build-essential"
            )),
            recipe(capability: capability(
                id: "python-ml", displayName: "Python + NumPy", summary: "Python, pip, virtual environments, and NumPy for application, data, and ML work.",
                category: "runtime", aliases: ["python"], executables: ["python3", "pip"],
                versionCommand: "python3 --version && python3 -m pip --version && python3 -c 'import numpy'",
                alpinePackages: "python3 py3-pip py3-numpy", debianPackages: "python3 python3-pip python3-numpy python3-venv"
            )),
            recipe(capability: capability(
                id: "go", displayName: "Go", summary: "Go compiler and standard development tools.",
                category: "runtime", aliases: ["golang"], executables: ["go"], versionCommand: "go version",
                alpinePackages: "go", debianPackages: "golang-go"
            )),
            recipe(capability: capability(
                id: "rust", displayName: "Rust", summary: "Rust compiler, Cargo, pkg-config, and native build support.",
                category: "runtime", aliases: ["rust-dev"], executables: ["cargo", "rustc"], versionCommand: "cargo --version",
                alpinePackages: "cargo rust", debianPackages: "cargo rustc build-essential pkg-config"
            )),
            recipe(capability: capability(
                id: "java", displayName: "Java 21 + Maven", summary: "Headless Java 21 development kit and Maven.",
                category: "runtime", aliases: ["jvm"], executables: ["java", "javac", "mvn"],
                versionCommand: "java -version && mvn --version",
                alpinePackages: "openjdk21 maven", debianPackages: "openjdk-21-jdk-headless maven"
            )),
            recipe(capability: capability(
                id: "ruby", displayName: "Ruby", summary: "Ruby, Bundler, and native extension build tools.",
                category: "runtime", executables: ["ruby", "bundle"], versionCommand: "ruby --version && bundle --version",
                alpinePackages: "ruby ruby-bundler build-base", debianPackages: "ruby-full ruby-bundler build-essential"
            )),
            recipe(
                capability: capability(
                    id: "docker-host", displayName: "Docker CLI", summary: "Docker CLI for workflows that are explicitly granted a Docker endpoint.",
                    category: "infrastructure", aliases: ["docker-cli"], executables: ["docker"], versionCommand: "docker --version",
                    alpinePackages: "docker-cli", debianPackages: "docker-cli"
                ),
                timeoutMs: 120_000,
                outputLimitBytes: 1024 * 1024
            ),
            recipe(capability: capability(
                id: "k8s-lab", displayName: "Kubernetes CLI", summary: "kubectl for cluster automation and troubleshooting.",
                category: "infrastructure", aliases: ["k8s", "kubectl"], executables: ["kubectl"],
                versionCommand: "kubectl version --client=true",
                alpinePackages: "kubectl", debianPackages: "kubectl"
            )),
            recipe(capability: capability(
                id: "devops", displayName: "Cloud + DevOps", summary: "Docker and Kubernetes CLIs for infrastructure agents.",
                category: "infrastructure", executables: ["docker", "kubectl"],
                versionCommand: "docker --version && kubectl version --client=true",
                alpinePackages: "docker-cli kubectl", debianPackages: "docker-cli kubectl"
            )),
        ]
    }()

    public static var catalog: [MachineRecipeCapability] {
        recipes.map(\.capability)
    }

    public static func recipe(id rawID: String) throws -> Recipe {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let recipe = recipes.first(where: {
            $0.id == id || $0.capability.aliases.contains(id)
        }) else {
            throw MachineRecipeProvisionError.unknownRecipe(rawID)
        }
        return recipe
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
