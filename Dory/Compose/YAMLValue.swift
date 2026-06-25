import Foundation

enum MergeTag: Sendable, Equatable {
    case reset
    case override
}

indirect enum YAMLValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case mapping([String: YAMLValue])
    case sequence([YAMLValue])
    case tagged(MergeTag, YAMLValue)

    nonisolated var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .number(value): value == value.rounded() ? String(Int(value)) : String(value)
        case let .bool(value): value ? "true" : "false"
        case let .tagged(_, inner): inner.stringValue
        default: nil
        }
    }

    nonisolated var mappingValue: [String: YAMLValue]? {
        switch self {
        case let .mapping(value): return value
        case let .tagged(_, inner): return inner.mappingValue
        default: return nil
        }
    }

    nonisolated var sequenceValue: [YAMLValue]? {
        switch self {
        case let .sequence(value): return value
        case .null: return []
        case let .tagged(_, inner): return inner.sequenceValue
        default: return nil
        }
    }

    nonisolated var boolValue: Bool? {
        switch self {
        case let .bool(value): value
        case let .string(value): ["true", "yes", "on", "1"].contains(value.lowercased())
        case let .tagged(_, inner): inner.boolValue
        default: nil
        }
    }

    nonisolated subscript(key: String) -> YAMLValue? { mappingValue?[key] }

    /// Coerce any scalar/sequence to an array of strings (for ports/volumes/command lists).
    nonisolated var stringList: [String] {
        switch self {
        case let .sequence(items): return items.compactMap(\.stringValue)
        case let .string(value): return [value]
        case let .tagged(_, inner): return inner.stringList
        default: return []
        }
    }
}
