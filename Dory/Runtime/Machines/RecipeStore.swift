import Foundation

struct RecipeStore: Sendable {
    let userDirectory: URL
    let builtInDirectory: URL?

    init(
        userDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dory")
            .appendingPathComponent("recipes"),
        builtInDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Recipes")
    ) {
        self.userDirectory = userDirectory
        self.builtInDirectory = builtInDirectory
    }

    func loadAll() throws -> [DevRecipe] {
        var recipes = [DevRecipe]()
        if let builtInDirectory {
            recipes.append(contentsOf: try loadRecipes(in: builtInDirectory, missingIsEmpty: true))
        }
        recipes.append(contentsOf: try loadRecipes(in: userDirectory, missingIsEmpty: true))
        return recipes.sorted { $0.id < $1.id }
    }

    func load(named nameOrPath: String) throws -> DevRecipe? {
        let explicit = URL(fileURLWithPath: NSString(string: nameOrPath).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: explicit.path) {
            return try DevRecipe.load(from: explicit)
        }
        return try loadAll().first { $0.id == nameOrPath }
    }

    private func loadRecipes(in directory: URL, missingIsEmpty: Bool) throws -> [DevRecipe] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            if missingIsEmpty { return [] }
            throw CocoaError(.fileNoSuchFile)
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
        return try urls.map(DevRecipe.load(from:))
    }
}
