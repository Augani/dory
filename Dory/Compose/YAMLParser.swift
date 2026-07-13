import Foundation

enum YAMLError: Error, Sendable, Equatable {
    case malformed(String)
}

/// Minimal YAML parser covering the Docker Compose subset: block mappings and sequences,
/// flow collections (`[...]`, `{...}`), quoted scalars, and comments. Anchors, multi-document,
/// and block scalars (`|`, `>`) are intentionally unsupported.
struct YAMLParser {
    private struct Line { let indent: Int; let content: String }
    private let lines: [Line]
    private var index = 0

    nonisolated static func parse(_ text: String) throws -> YAMLValue {
        var parser = YAMLParser(text: text)
        return try parser.parseDocument()
    }

    private nonisolated init(text: String) {
        var collected: [Line] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = YAMLParser.stripComment(String(raw))
            if stripped.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let indent = stripped.prefix { $0 == " " }.count
            collected.append(Line(indent: indent, content: String(stripped.drop(while: { $0 == " " }).reversed().drop(while: { $0 == " " }).reversed())))
        }
        lines = collected
    }

    private nonisolated mutating func parseDocument() throws -> YAMLValue {
        guard index < lines.count else { return .null }
        return try parseNode(indent: lines[index].indent)
    }

    private nonisolated mutating func parseNode(indent: Int) throws -> YAMLValue {
        if lines[index].content.hasPrefix("- ") || lines[index].content == "-" {
            return try parseSequence(indent: indent)
        }
        return try parseMapping(indent: indent)
    }

    private nonisolated mutating func parseMapping(indent: Int) throws -> YAMLValue {
        var map: [String: YAMLValue] = [:]
        while index < lines.count, lines[index].indent == indent,
              !lines[index].content.hasPrefix("- ") {
            let content = lines[index].content
            guard let (key, rest) = Self.splitKeyValue(content) else {
                throw YAMLError.malformed("expected key: value, got '\(content)'")
            }
            index += 1
            map[key] = try parseMappingValue(rest, parentIndent: indent)
        }
        return .mapping(map)
    }

    private nonisolated mutating func parseSequence(indent: Int) throws -> YAMLValue {
        var seq: [YAMLValue] = []
        while index < lines.count, lines[index].indent == indent,
              lines[index].content.hasPrefix("- ") || lines[index].content == "-" {
            let content = lines[index].content
            let item = content == "-" ? "" : String(content.dropFirst(2))
            index += 1
            if item.isEmpty {
                seq.append(try parseChildBlock(parentIndent: indent))
            } else if let (key, rest) = Self.splitKeyValue(item), !item.hasPrefix("[") && !item.hasPrefix("{") {
                // Inline mapping item: "- key: value" plus any deeper continuation lines.
                var map: [String: YAMLValue] = [:]
                let childIndent = indent + 2
                map[key] = try parseMappingValue(rest, parentIndent: childIndent)
                while index < lines.count, lines[index].indent >= childIndent,
                      !lines[index].content.hasPrefix("- ") {
                    let line = lines[index].content
                    guard let (k, r) = Self.splitKeyValue(line) else { break }
                    index += 1
                    map[k] = try parseMappingValue(r, parentIndent: childIndent)
                }
                seq.append(.mapping(map))
            } else {
                seq.append(try Self.scalarOrFlow(item))
            }
        }
        return .sequence(seq)
    }

    private nonisolated mutating func parseMappingValue(
        _ rest: String,
        parentIndent: Int
    ) throws -> YAMLValue {
        if rest.isEmpty {
            return try parseChildBlock(parentIndent: parentIndent)
        }
        if let (tag, remainder) = Self.mergeTag(rest), remainder.isEmpty,
           index < lines.count, lines[index].indent > parentIndent {
            return .tagged(tag, try parseChildBlock(parentIndent: parentIndent))
        }
        return try Self.scalarOrFlow(rest)
    }

    private nonisolated mutating func parseChildBlock(parentIndent: Int) throws -> YAMLValue {
        guard index < lines.count else { return .null }
        let next = lines[index]
        if next.indent > parentIndent {
            return try parseNode(indent: next.indent)
        }
        if next.indent == parentIndent && (next.content.hasPrefix("- ") || next.content == "-") {
            return try parseSequence(indent: parentIndent)
        }
        return .null
    }

    // MARK: Scalars and flow collections

    nonisolated static func scalarOrFlow(_ raw: String) throws -> YAMLValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let (tag, remainder) = mergeTag(trimmed) {
            return .tagged(tag, try scalarOrFlow(remainder))
        }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            var scanner = FlowScanner(trimmed)
            return try scanner.parseValue()
        }
        return scalar(trimmed)
    }

    private nonisolated static func mergeTag(_ trimmed: String) -> (MergeTag, String)? {
        for (token, tag) in [("!override", MergeTag.override), ("!reset", MergeTag.reset)] {
            if trimmed == token { return (tag, "") }
            if trimmed.hasPrefix(token + " ") {
                return (tag, String(trimmed.dropFirst(token.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    nonisolated static func scalar(_ raw: String) -> YAMLValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            return .string(unescape(String(trimmed.dropFirst().dropLast())))
        }
        if trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2 {
            return .string(String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        // YAML 1.2 / Compose semantics: only true/false are booleans. yes/no/on/off stay strings,
        // so environment values like `FEATURE: yes` are not silently corrupted to "true".
        switch trimmed.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null", "~", "": return .null
        default: break
        }
        if let number = Double(trimmed), trimmed.allSatisfy({ "0123456789.+-eE".contains($0) }) {
            return .number(number)
        }
        return .string(trimmed)
    }

    private nonisolated static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    nonisolated static func splitKeyValue(_ content: String) -> (key: String, value: String)? {
        var inSingle = false, inDouble = false
        let chars = Array(content)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            else if c == ":" && !inSingle && !inDouble {
                let isLast = i == chars.count - 1
                if isLast || chars[i + 1] == " " {
                    let key = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                    let value = isLast ? "" : String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                    return (Self.unquoteKey(key), value)
                }
            }
            i += 1
        }
        return nil
    }

    private nonisolated static func unquoteKey(_ key: String) -> String {
        if key.hasPrefix("\"") && key.hasSuffix("\"") && key.count >= 2 { return String(key.dropFirst().dropLast()) }
        if key.hasPrefix("'") && key.hasSuffix("'") && key.count >= 2 { return String(key.dropFirst().dropLast()) }
        return key
    }

    private nonisolated static func stripComment(_ line: String) -> String {
        var inSingle = false, inDouble = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            else if c == "#" && !inSingle && !inDouble {
                if i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t" {
                    return String(chars[0..<i])
                }
            }
            i += 1
        }
        return line
    }
}

private struct FlowScanner {
    private let chars: [Character]
    private var i = 0
    nonisolated init(_ string: String) { chars = Array(string) }

    nonisolated mutating func parseValue() throws -> YAMLValue {
        skipSpaces()
        guard i < chars.count else { return .null }
        switch chars[i] {
        case "[": return try parseSequence()
        case "{": return try parseMapping()
        case "\"", "'": return .string(parseQuoted())
        default: return YAMLParser.scalar(parseScalar())
        }
    }

    private nonisolated mutating func parseSequence() throws -> YAMLValue {
        i += 1
        var items: [YAMLValue] = []
        skipSpaces()
        if peek() == "]" { i += 1; return .sequence(items) }
        while i < chars.count {
            items.append(try parseValue())
            skipSpaces()
            if peek() == "," { i += 1; skipSpaces(); continue }
            if peek() == "]" { i += 1; break }
            break
        }
        return .sequence(items)
    }

    private nonisolated mutating func parseMapping() throws -> YAMLValue {
        i += 1
        var map: [String: YAMLValue] = [:]
        skipSpaces()
        if peek() == "}" { i += 1; return .mapping(map) }
        while i < chars.count {
            skipSpaces()
            let key = (peek() == "\"" || peek() == "'") ? parseQuoted() : parseKey()
            skipSpaces()
            if peek() == ":" { i += 1 }
            let value = try parseValue()
            map[key] = value
            skipSpaces()
            if peek() == "," { i += 1; continue }
            if peek() == "}" { i += 1; break }
            break
        }
        return .mapping(map)
    }

    private nonisolated mutating func parseQuoted() -> String {
        let quote = chars[i]; i += 1
        var result = ""
        while i < chars.count, chars[i] != quote { result.append(chars[i]); i += 1 }
        if i < chars.count { i += 1 }
        return result
    }

    private nonisolated mutating func parseScalar() -> String {
        var result = ""
        var braceDepth = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                braceDepth += 1
                result.append(c)
                i += 1
                continue
            }
            if c == "}" {
                if braceDepth == 0 { break }
                braceDepth -= 1
                result.append(c)
                i += 1
                continue
            }
            if c == "," || c == "]" { break }
            result.append(c)
            i += 1
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private nonisolated mutating func parseKey() -> String {
        var result = ""
        while i < chars.count, !":,]}".contains(chars[i]) { result.append(chars[i]); i += 1 }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private nonisolated func peek() -> Character? { i < chars.count ? chars[i] : nil }
    private nonisolated mutating func skipSpaces() { while i < chars.count, chars[i] == " " { i += 1 } }
}
