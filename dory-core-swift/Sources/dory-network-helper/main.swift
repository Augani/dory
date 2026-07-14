import DorydKit
import Foundation

if CommandLine.arguments.dropFirst().first == "--daemon" {
    guard geteuid() == 0 else {
        FileHandle.standardError.write(Data("dory-network-helper: --daemon must run as root\n".utf8))
        exit(77)
    }
    SourcePreservingLANPrivilegedDaemon().run()
}

struct HelperOptions {
    var planPath: String?
    var dryRun = false
    var remove = false
    var fileSystemRoot = "/"
    var ownerUID: uid_t?
}

func usage() -> String {
    """
    usage: dory-network-helper --plan-json <path|-> [--dry-run] [--remove] [--owner-uid <uid>] [--file-system-root <path>]
    """
}

func parseOptions(_ arguments: [String]) throws -> HelperOptions {
    var options = HelperOptions()
    var index = arguments.startIndex
    while index < arguments.endIndex {
        let argument = arguments[index]
        index = arguments.index(after: index)
        switch argument {
        case "--plan-json":
            guard index < arguments.endIndex else { throw HelperError.usage }
            options.planPath = arguments[index]
            index = arguments.index(after: index)
        case "--dry-run":
            options.dryRun = true
        case "--remove":
            options.remove = true
        case "--owner-uid":
            guard index < arguments.endIndex,
                  let value = uid_t(arguments[index]) else { throw HelperError.usage }
            options.ownerUID = value
            index = arguments.index(after: index)
        case "--file-system-root":
            guard index < arguments.endIndex else { throw HelperError.usage }
            options.fileSystemRoot = arguments[index]
            index = arguments.index(after: index)
        default:
            throw HelperError.usage
        }
    }
    guard options.planPath != nil else { throw HelperError.usage }
    return options
}

enum HelperError: Error, CustomStringConvertible {
    case usage
    case missingPlanPath
    case planTooLarge
    case readTimeout
    case unsafeFileSystemRoot

    var description: String {
        switch self {
        case .usage:
            return "usage"
        case .missingPlanPath:
            return "missing --plan-json path"
        case .planTooLarge:
            return "plan exceeds maximum size of \(maxPlanBytes) bytes"
        case .readTimeout:
            return "timed out reading plan from standard input"
        case .unsafeFileSystemRoot:
            return "--file-system-root is available only with --dry-run"
        }
    }
}

let maxPlanBytes = 1 << 20
let planReadDeadlineSeconds: TimeInterval = 15

func readPlan(path: String) throws -> NetworkingAuthorizationPlan {
    let data: Data
    if path == "-" {
        data = try readBoundedStandardInput(maxBytes: maxPlanBytes, deadline: planReadDeadlineSeconds)
    } else {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= maxPlanBytes else { throw HelperError.planTooLarge }
    }
    return try JSONDecoder().decode(NetworkingAuthorizationPlan.self, from: data)
}

func readBoundedStandardInput(maxBytes: Int, deadline: TimeInterval) throws -> Data {
    let box = StandardInputReadBox()
    let thread = Thread {
        var data = Data()
        let handle = FileHandle.standardInput
        while true {
            let chunk = handle.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maxBytes {
                box.finish(.failure(HelperError.planTooLarge))
                return
            }
        }
        box.finish(.success(data))
    }
    thread.stackSize = 512 * 1024
    thread.start()
    guard let result = box.wait(deadline: deadline) else {
        throw HelperError.readTimeout
    }
    return try result.get()
}

final class StandardInputReadBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func finish(_ value: Result<Data, Error>) {
        lock.lock()
        if result == nil { result = value }
        lock.unlock()
        semaphore.signal()
    }

    func wait(deadline: TimeInterval) -> Result<Data, Error>? {
        guard semaphore.wait(timeout: .now() + deadline) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    guard let planPath = options.planPath else { throw HelperError.missingPlanPath }
    guard options.fileSystemRoot == "/" || options.dryRun else {
        throw HelperError.unsafeFileSystemRoot
    }
    let plan = try readPlan(path: planPath)
    let applier = NetworkingAuthorizationApplier(
        fileSystemRoot: options.fileSystemRoot,
        dryRun: options.dryRun,
        ownerUID: options.ownerUID
    )
    let results = try options.remove ? applier.remove(plan) : applier.apply(plan)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(results))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch HelperError.usage {
    FileHandle.standardError.write(Data("\(usage())\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("dory-network-helper: \(error)\n".utf8))
    exit(1)
}
