import Darwin
import Foundation

public enum DoryVZMacUSBMassStorageError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case requiresMacOS15
    case invalidArtifact(String)

    public var description: String {
        switch self {
        case .requiresMacOS15:
            "virtual USB mass storage for VZMac requires macOS 15 or newer"
        case .invalidArtifact(let path):
            "VZMac USB storage is not a direct, non-empty, accessible regular file: \(path)"
        }
    }
}

/// A local disk image presented as virtual USB mass storage.
///
/// This is deliberately distinct from physical USB passthrough. It is the public,
/// older-host-compatible removable-storage path available to VZMac on macOS 15–26.
public struct DoryVZMacUSBMassStorage: Sendable, Equatable {
    public let url: URL
    public let readOnly: Bool
    public let byteCount: UInt64

    public init(url: URL, readOnly: Bool) throws {
        let standardizedURL = url.standardizedFileURL
        var status = stat()
        guard url.isFileURL,
              lstat(standardizedURL.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size > 0,
              access(standardizedURL.path, R_OK) == 0,
              readOnly || access(standardizedURL.path, W_OK) == 0 else {
            throw DoryVZMacUSBMassStorageError.invalidArtifact(url.path)
        }
        self.url = standardizedURL
        self.readOnly = readOnly
        byteCount = UInt64(status.st_size)
    }
}
