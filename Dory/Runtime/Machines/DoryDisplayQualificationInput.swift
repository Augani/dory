import CryptoKit
import Darwin
import DoryVMDisplayWireContracts
import Foundation

nonisolated enum DoryDisplayQualificationInputError: Error, Equatable,
    CustomStringConvertible {
    case invalidScript
    case invalidScriptPath
    case invalidReceiptPath
    case scriptUnavailable
    case scriptChanged
    case receiptExists
    case receiptWriteFailed

    var description: String {
        switch self {
        case .invalidScript:
            "the qualification keyboard script is invalid"
        case .invalidScriptPath:
            "the qualification keyboard script path is invalid"
        case .invalidReceiptPath:
            "the qualification input receipt path is invalid"
        case .scriptUnavailable:
            "the qualification keyboard script is unavailable"
        case .scriptChanged:
            "the qualification keyboard script changed while it was read"
        case .receiptExists:
            "the qualification input receipt already exists"
        case .receiptWriteFailed:
            "the qualification input receipt could not be written"
        }
    }
}

nonisolated enum DoryDisplayQualificationInputCommandError: Error, Equatable {
    case unavailable
    case operationChanged
    case rejected(String)
}

/// A bounded sequence of complete evdev keyboard frames for an isolated physical campaign.
///
/// Raw key codes keep the app independent of the installer's locale. Validation requires every
/// press to be released, so a malformed or interrupted plan cannot intentionally leave a key held.
nonisolated struct DoryDisplayQualificationInputScript: Codable, Equatable, Sendable {
    static let kind = "dev.dory.display-qualification-keyboard-script"
    static let schemaVersion = 1
    static let maximumEncodedByteCount = 256 * 1_024
    static let maximumStepCount = 1_024
    static let maximumTotalEventCount = 8_192
    static let maximumStepDelayMilliseconds: UInt64 = 300_000
    static let maximumTotalDelayMilliseconds: UInt64 = 7_200_000

    struct Step: Codable, Equatable, Sendable {
        let delayMilliseconds: UInt64
        let events: [DoryVMDisplayInputEvent]
    }

    let kind: String
    let schemaVersion: Int
    let machineID: String
    let steps: [Step]

    var eventCount: Int { steps.reduce(0) { $0 + $1.events.count } }
    var totalDelayMilliseconds: UInt64 {
        steps.reduce(0) { partial, step in
            partial.addingReportingOverflow(step.delayMilliseconds).overflow
                ? .max : partial + step.delayMilliseconds
        }
    }

    static func decode(_ data: Data, machineID: String) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedByteCount,
              let script = try? JSONDecoder().decode(Self.self, from: data) else {
            throw DoryDisplayQualificationInputError.invalidScript
        }
        try script.validate(machineID: machineID)
        return script
    }

    func validate(machineID expectedMachineID: String) throws {
        guard kind == Self.kind,
              schemaVersion == Self.schemaVersion,
              machineID == expectedMachineID,
              !steps.isEmpty,
              steps.count <= Self.maximumStepCount,
              eventCount <= Self.maximumTotalEventCount,
              totalDelayMilliseconds <= Self.maximumTotalDelayMilliseconds else {
            throw DoryDisplayQualificationInputError.invalidScript
        }

        for step in steps {
            guard step.delayMilliseconds <= Self.maximumStepDelayMilliseconds,
                  !step.events.isEmpty,
                  step.events.count <= DoryVMDisplayCommand.maximumInputEventCount else {
                throw DoryDisplayQualificationInputError.invalidScript
            }
            var pressed = Set<UInt16>()
            for event in step.events {
                guard event.type == 1, (1...255).contains(event.code) else {
                    throw DoryDisplayQualificationInputError.invalidScript
                }
                switch event.value {
                case 0:
                    guard pressed.remove(event.code) != nil else {
                        throw DoryDisplayQualificationInputError.invalidScript
                    }
                case 1:
                    guard pressed.insert(event.code).inserted else {
                        throw DoryDisplayQualificationInputError.invalidScript
                    }
                case 2:
                    guard pressed.contains(event.code) else {
                        throw DoryDisplayQualificationInputError.invalidScript
                    }
                default:
                    throw DoryDisplayQualificationInputError.invalidScript
                }
            }
            guard pressed.isEmpty else {
                throw DoryDisplayQualificationInputError.invalidScript
            }
        }
    }
}

nonisolated struct DoryDisplayQualificationLoadedInput: Sendable {
    let script: DoryDisplayQualificationInputScript
    let sha256: String
}

nonisolated enum DoryDisplayQualificationInputFiles {
    static func loadScript(
        at path: String,
        machineID: String
    ) throws -> DoryDisplayQualificationLoadedInput {
        guard DoryDisplayQualificationLaunch.validAbsolutePath(path) else {
            throw DoryDisplayQualificationInputError.invalidScriptPath
        }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryDisplayQualificationInputError.scriptUnavailable
        }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0,
              before.st_size <= DoryDisplayQualificationInputScript.maximumEncodedByteCount else {
            throw DoryDisplayQualificationInputError.scriptUnavailable
        }
        let expectedCount = Int(before.st_size)
        var data = Data(count: expectedCount)
        let readCount = data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return -1 }
            var offset = 0
            while offset < expectedCount {
                let count = read(descriptor, base.advanced(by: offset), expectedCount - offset)
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    return -1
                }
            }
            return offset
        }
        var after = stat()
        guard readCount == expectedCount,
              fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw DoryDisplayQualificationInputError.scriptChanged
        }
        return DoryDisplayQualificationLoadedInput(
            script: try DoryDisplayQualificationInputScript.decode(
                data,
                machineID: machineID
            ),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    static func writeReceipt<T: Encodable>(_ receipt: T, at path: String) throws {
        guard DoryDisplayQualificationLaunch.validAbsolutePath(path) else {
            throw DoryDisplayQualificationInputError.invalidReceiptPath
        }
        let destination = URL(fileURLWithPath: path)
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw DoryDisplayQualificationInputError.invalidReceiptPath
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DoryDisplayQualificationInputError.receiptExists
        }
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try (encoder.encode(receipt) + Data("\n".utf8)).write(
                to: temporary,
                options: .withoutOverwriting
            )
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw DoryDisplayQualificationInputError.receiptWriteFailed
        }
    }
}

nonisolated struct DoryDisplayQualificationInputReceipt: Encodable, Sendable {
    let kind = "dev.dory.display-qualification-input"
    let schemaVersion = 1
    let delivery = "runner-applied"
    let completedAt: String
    let bundleIdentifier: String
    let processID: Int32
    let machineID: String
    let machServiceName: String
    let operationID: String
    let scriptSHA256: String
    let stepCount: Int
    let eventCount: Int
    let firstCommandSequence: UInt64
    let lastCommandSequence: UInt64
}
