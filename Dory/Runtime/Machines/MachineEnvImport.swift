import Foundation

nonisolated enum MachineEnvImport {
    static let defaultNames: [String] = ["ANTHROPIC_API_KEY"]
    static let optionalExtras: [String] = ["OPENAI_API_KEY", "GH_TOKEN", "HF_TOKEN"]

    static func normalize(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for name in defaultNames + names {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !cleaned.isEmpty, cleaned.wholeMatch(of: /[A-Z_][A-Z0-9_]*/) != nil else { continue }
            guard seen.insert(cleaned).inserted else { continue }
            ordered.append(cleaned)
        }
        return ordered
    }

    static func parse(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ", \t\n")
        return normalize(raw.components(separatedBy: separators))
    }

    static func serialize(_ names: [String]) -> String {
        normalize(names).joined(separator: ",")
    }
}
