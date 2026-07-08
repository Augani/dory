import DorydKit
import Foundation

struct HelperOptions {
    var planPath: String?
    var dryRun = false
    var fileSystemRoot = "/"
}

func usage() -> String {
    """
    usage: dory-network-helper --plan-json <path|-> [--dry-run] [--file-system-root <path>]
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

enum HelperError: Error {
    case usage
}

func readPlan(path: String) throws -> NetworkingAuthorizationPlan {
    let data: Data
    if path == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    }
    return try JSONDecoder().decode(NetworkingAuthorizationPlan.self, from: data)
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let plan = try readPlan(path: options.planPath!)
    let results = try NetworkingAuthorizationApplier(
        fileSystemRoot: options.fileSystemRoot,
        dryRun: options.dryRun
    ).apply(plan)
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
