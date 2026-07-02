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

    static let sentinel = "@@DORYENV@@"

    static func probeCommand(for names: [String]) -> String {
        normalize(names).map { name in
            "printf '\(sentinel)\(name)=%s\(sentinel)' \"${\(name):-}\""
        }.joined(separator: "; ")
    }

    static func parseProbeOutput(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        let segments = output.components(separatedBy: sentinel)
        for segment in segments {
            guard let eq = segment.firstIndex(of: "="), segment.hasSuffix("=") == false else { continue }
            let key = String(segment[segment.startIndex..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(segment[segment.index(after: eq)...])
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    static func resolve(names: [String]) async -> [String: String] {
        let normalized = normalize(names)
        guard !normalized.isEmpty else { return [:] }
        let command = probeCommand(for: normalized)
        let result = await withTimeout(seconds: 6) {
            await Shell.runAsyncResult(loginShell(), ["-lic", command])
        }
        guard let output = result?.output else { return [:] }
        return parseProbeOutput(output)
    }

    private static func loginShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return Shell.find("zsh", candidates: ["/bin/zsh", "/opt/homebrew/bin/zsh", "/usr/local/bin/zsh"]) ?? "/bin/zsh"
    }

    private static func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
