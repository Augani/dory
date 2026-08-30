import Darwin
import Foundation

public enum DoryVZMacSharedDirectoryError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidName(String)
    case invalidDirectory(String)
    case duplicateName(String)

    public var description: String {
        switch self {
        case .invalidName(let name): "invalid VZMac shared-directory name: \(name)"
        case .invalidDirectory(let path): "VZMac share is not a direct directory: \(path)"
        case .duplicateName(let name): "duplicate VZMac shared-directory name: \(name)"
        }
    }
}

public struct DoryVZMacSharedDirectory: Sendable, Equatable {
    public let name: String
    public let url: URL
    public let readOnly: Bool

    public init(name: String, url: URL, readOnly: Bool) throws {
        let bytes = Array(name.utf8)
        let allowedPunctuation = Set(" ._-".utf8)
        guard !bytes.isEmpty,
              bytes.count <= 64,
              bytes.first != 0x20,
              bytes.last != 0x20,
              bytes.allSatisfy({
                  (0x30...0x39).contains($0)
                      || (0x41...0x5A).contains($0)
                      || (0x61...0x7A).contains($0)
                      || allowedPunctuation.contains($0)
              }) else {
            throw DoryVZMacSharedDirectoryError.invalidName(name)
        }
        var status = stat()
        guard url.isFileURL,
              lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw DoryVZMacSharedDirectoryError.invalidDirectory(url.path)
        }
        self.name = name
        self.url = url.standardizedFileURL
        self.readOnly = readOnly
    }
}
