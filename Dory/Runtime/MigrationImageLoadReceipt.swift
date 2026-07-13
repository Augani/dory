import Foundation

nonisolated enum MigrationImageLoadReceiptError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(detail): "invalid Docker image-load receipt: \(detail)"
        }
    }
}

nonisolated struct MigrationImageLoadReceipt: Sendable, Equatable {
    static let maximumResponseBytes = 8 * 1_024 * 1_024

    let loadedImageID: String

    static func parse(_ data: Data) throws -> MigrationImageLoadReceipt {
        guard !data.isEmpty else {
            throw MigrationImageLoadReceiptError.invalid("response is empty")
        }
        guard data.count <= maximumResponseBytes else {
            throw MigrationImageLoadReceiptError.invalid("response exceeds the 8 MiB limit")
        }
        guard let response = String(data: data, encoding: .utf8) else {
            throw MigrationImageLoadReceiptError.invalid("response is not UTF-8")
        }

        var loadedIDs = Set<String>()
        var objectCount = 0
        for rawLine in response.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            objectCount += 1
            guard let lineData = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(MigrationImageLoadMessage.self, from: lineData) else {
                throw MigrationImageLoadReceiptError.invalid(
                    "response contains a malformed JSON message"
                )
            }
            try validate(message, loadedIDs: &loadedIDs)
        }

        guard objectCount > 0 else {
            throw MigrationImageLoadReceiptError.invalid("response has no JSON messages")
        }
        guard let loadedImageID = loadedIDs.first else {
            throw MigrationImageLoadReceiptError.invalid("response has no immutable image ID")
        }
        guard loadedIDs.count == 1 else {
            throw MigrationImageLoadReceiptError.invalid("response names multiple image IDs")
        }
        return MigrationImageLoadReceipt(loadedImageID: loadedImageID)
    }
}

private extension MigrationImageLoadReceipt {
    nonisolated static let loadedIDPrefix = "Loaded image ID: "
    nonisolated static let loadedTagPrefix = "Loaded image: "

    nonisolated static func validate(
        _ message: MigrationImageLoadMessage,
        loadedIDs: inout Set<String>
    ) throws {
        if let detail = message.errorDetail?.message, !detail.isEmpty {
            throw MigrationImageLoadReceiptError.invalid("engine reported an error: \(detail)")
        }
        if let error = message.error, !error.isEmpty {
            throw MigrationImageLoadReceiptError.invalid("engine reported an error: \(error)")
        }
        guard let stream = message.stream else { return }

        for rawLine in stream.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix(loadedTagPrefix) {
                throw MigrationImageLoadReceiptError.invalid(
                    "archive applied a mutable image reference"
                )
            }
            guard line.hasPrefix(loadedIDPrefix) else {
                throw MigrationImageLoadReceiptError.invalid(
                    "response contains unexpected engine output"
                )
            }
            let identifier = String(line.dropFirst(loadedIDPrefix.count))
            guard validImageID(identifier) else {
                throw MigrationImageLoadReceiptError.invalid(
                    "engine returned a malformed immutable image ID"
                )
            }
            loadedIDs.insert(identifier)
        }
    }

    nonisolated static func validImageID(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.utf8.count == 64 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

private nonisolated struct MigrationImageLoadMessage: Decodable {
    struct ErrorDetail: Decodable {
        let message: String?
    }

    let stream: String?
    let error: String?
    let errorDetail: ErrorDetail?
}
