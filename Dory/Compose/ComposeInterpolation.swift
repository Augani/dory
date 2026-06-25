import Foundation

/// Compose variable interpolation: `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR-default}`,
/// `${VAR:?err}`, and `$$` (literal `$`). Matches Docker Compose precedence semantics.
enum ComposeInterpolation {
    static func interpolate(_ text: String, variables: [String: String]) -> String {
        let chars = Array(text)
        var result = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "$" else { result.append(chars[i]); i += 1; continue }
            if i + 1 < chars.count, chars[i + 1] == "$" { result.append("$"); i += 2; continue }
            if i + 1 < chars.count, chars[i + 1] == "{" {
                var j = i + 2
                var expr = ""
                var depth = 1
                while j < chars.count, depth > 0 {
                    if chars[j] == "{" { depth += 1 }
                    else if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                    if depth > 0 { expr.append(chars[j]) }
                    j += 1
                }
                result.append(resolveBraced(expr, variables: variables))
                i = j + 1
            } else if i + 1 < chars.count, isNameStart(chars[i + 1]) {
                var j = i + 1
                var name = ""
                while j < chars.count, isNameChar(chars[j]) { name.append(chars[j]); j += 1 }
                result.append(variables[name] ?? "")
                i = j
            } else {
                result.append(chars[i]); i += 1
            }
        }
        return result
    }

    static func interpolate(_ value: YAMLValue, variables: [String: String]) -> YAMLValue {
        switch value {
        case let .string(string): return .string(interpolate(string, variables: variables))
        case let .mapping(map): return .mapping(map.mapValues { interpolate($0, variables: variables) })
        case let .sequence(items): return .sequence(items.map { interpolate($0, variables: variables) })
        case let .tagged(tag, inner): return .tagged(tag, interpolate(inner, variables: variables))
        default: return value
        }
    }

    private static func resolveBraced(_ expr: String, variables: [String: String]) -> String {
        // Two-character operators must be matched before the single-character ones, otherwise a
        // hyphen or question mark inside a default/error message would be misparsed as the operator.
        if let range = expr.range(of: ":-") {
            let name = String(expr[expr.startIndex..<range.lowerBound])
            let fallback = String(expr[range.upperBound...])
            let value = variables[name] ?? ""
            return value.isEmpty ? interpolate(fallback, variables: variables) : value
        }
        if let range = expr.range(of: ":?") {
            let name = String(expr[expr.startIndex..<range.lowerBound])
            let value = variables[name] ?? ""
            return value // required-or-error semantics simplified to the value (empty if unset)
        }
        if let range = expr.range(of: "-"), !expr.hasPrefix("-") {
            let name = String(expr[expr.startIndex..<range.lowerBound])
            let fallback = String(expr[range.upperBound...])
            return variables[name] ?? interpolate(fallback, variables: variables)
        }
        if let range = expr.range(of: "?"), !expr.hasPrefix("?") {
            let name = String(expr[expr.startIndex..<range.lowerBound])
            return variables[name] ?? ""
        }
        return variables[expr] ?? ""
    }

    private static func isNameStart(_ c: Character) -> Bool { c == "_" || c.isLetter }
    private static func isNameChar(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }

    /// Parse a `.env` file body into a variable dictionary.
    static func parseDotEnv(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
