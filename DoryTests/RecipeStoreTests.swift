import Foundation
import Testing
@testable import Dory

struct RecipeStoreTests {
    @Test func validRecipeLoadsAndSubstitutesTemplates() throws {
        let url = try writeRecipe("""
        name: rust-dev
        summary: Rust toolchain
        distro: ubuntu:24.04
        arch: arm64
        resources: {cpus: 4, memory: 8GiB, disk: 60GiB}
        packages: [build-essential, pkg-config, libssl-dev]
        runcmd:
          - echo /home/{{user}}
        mounts:
          - ~/Projects:~/Projects
        ports: [3000]
        env: {CARGO_HOME: /home/{{user}}/.cargo}
        ssh: {agent_forward: true}
        docker: true
        user: {name: "{{host_user}}", sudo: true, shell: /bin/bash}
        """)

        let recipe = try DevRecipe.load(from: url)
        #expect(recipe.id == "rust-dev")
        #expect(recipe.resources.memory == "8GiB")
        #expect(recipe.packages == ["build-essential", "pkg-config", "libssl-dev"])
        #expect(recipe.ports == [3000])
        #expect(recipe.ssh.agentForward)
        #expect(recipe.docker)

        let substituted = recipe.substituted(hostUser: "augustus")
        #expect(substituted.user.name == "augustus")
        #expect(substituted.env["CARGO_HOME"] == "/home/augustus/.cargo")
    }

    @Test func unknownKeysAreRejected() throws {
        let url = try writeRecipe("""
        name: bad
        distro: ubuntu:24.04
        surprise: nope
        """)
        #expect(throws: DevRecipe.RecipeError.self) {
            _ = try DevRecipe.load(from: url)
        }
    }

    @Test func badMemoryStringIsRejected() throws {
        let url = try writeRecipe("""
        name: bad
        distro: ubuntu:24.04
        resources: {cpus: 2, memory: lots, disk: 20GiB}
        """)
        #expect(throws: DevRecipe.RecipeError.self) {
            _ = try DevRecipe.load(from: url)
        }
    }

    @Test func missingArchDefaultsToHostArch() throws {
        let url = try writeRecipe("""
        name: host-default
        distro: ubuntu:24.04
        """)

        let recipe = try DevRecipe.load(from: url)
        #expect(recipe.arch == MachineArch.host.rawValue)
    }

    @Test func storeLoadsYamlFilesSortedByID() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dory-recipes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "name: zed\ndistro: ubuntu:24.04\n".write(to: dir.appendingPathComponent("zed.yaml"), atomically: true, encoding: .utf8)
        try "name: alpha\ndistro: alpine:3.20\n".write(to: dir.appendingPathComponent("alpha.yml"), atomically: true, encoding: .utf8)

        let recipes = try RecipeStore(userDirectory: dir, builtInDirectory: nil).loadAll()
        #expect(recipes.map(\.id) == ["alpha", "zed"])
    }

    @Test func sourceBuiltInCatalogLoads() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repo = sourceFile.deletingLastPathComponent().deletingLastPathComponent()
        let catalog = repo.appendingPathComponent("Dory/Resources/Recipes")
        let recipes = try RecipeStore(userDirectory: catalog.appendingPathComponent("missing"), builtInDirectory: catalog).loadAll()
        #expect(recipes.map(\.id) == ["docker-host", "go", "k8s-lab", "node", "python-ml", "rust", "ubuntu-dev"])
        #expect(recipes.first { $0.id == "docker-host" }?.docker == true)
        #expect(recipes.first { $0.id == "rust" }?.env["CARGO_HOME"] == "/home/{{user}}/.cargo")
    }

    private func writeRecipe(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dory-recipe-\(UUID().uuidString).yaml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
