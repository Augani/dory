import Foundation

struct MachineUseCase: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let recipeID: String?
    let cpus: Int
    let memoryGB: Int

    var recipe: DevRecipe? { recipeID.flatMap(DevRecipe.forID) }

    static let all: [MachineUseCase] = [
        MachineUseCase(id: "web", title: "Web / Node.js", subtitle: "Node.js · npm",
                       icon: "globe", recipeID: "node", cpus: 2, memoryGB: 2),
        MachineUseCase(id: "python", title: "Python & ML", subtitle: "Python 3 · pip · NumPy",
                       icon: "brain", recipeID: "python", cpus: 2, memoryGB: 4),
        MachineUseCase(id: "go", title: "Go", subtitle: "Go toolchain",
                       icon: "g.circle", recipeID: "go", cpus: 2, memoryGB: 2),
        MachineUseCase(id: "rust", title: "Rust", subtitle: "rustc + cargo",
                       icon: "r.circle", recipeID: "rust", cpus: 2, memoryGB: 2),
        MachineUseCase(id: "jvm", title: "Java / JVM", subtitle: "JDK + Maven",
                       icon: "cup.and.saucer", recipeID: "java", cpus: 2, memoryGB: 4),
        MachineUseCase(id: "devops", title: "DevOps & CI", subtitle: "docker CLI + kubectl",
                       icon: "shippingbox", recipeID: "devops", cpus: 2, memoryGB: 2),
        MachineUseCase(id: "clean", title: "Just a clean Linux", subtitle: "Plain Dory Linux",
                       icon: "terminal", recipeID: nil, cpus: 2, memoryGB: 2),
    ]

    static func forID(_ id: String) -> MachineUseCase? { all.first { $0.id == id } }
}
