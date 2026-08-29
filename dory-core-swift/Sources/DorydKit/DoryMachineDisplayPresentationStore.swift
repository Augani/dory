import Darwin
import DoryOperations
import Foundation

enum DoryMachineDisplayPresentationStoreError: Error, Equatable {
    case invalidMachineID
    case invalidPresentation
    case invalidRecord
    case filesystem(String)
}

/// Daemon-owned host presentation preferences. These records intentionally live outside each
/// portable machine directory so snapshots, exports, and plan digests never capture host monitor
/// identities.
final class DoryMachineDisplayPresentationStore: @unchecked Sendable {
    private static let directoryName = ".display-presentation-v1"
    private static let maximumRecordBytes = 64 * 1_024

    private let root: String
    private let lock = NSLock()

    init(root: String) {
        self.root = URL(fileURLWithPath: root)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .standardizedFileURL.path
    }

    func read(machineID: String) throws -> DoryMachineDisplayPresentation {
        lock.lock()
        defer { lock.unlock() }
        let path = try recordPath(machineID: machineID)
        guard Self.pathExists(path) else { return .windowed }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.filesystem("open display presentation") }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o077) == 0,
              metadata.st_size >= 0,
              metadata.st_size <= Self.maximumRecordBytes else {
            throw DoryMachineDisplayPresentationStoreError.invalidRecord
        }
        var data = Data(count: Int(metadata.st_size))
        let expectedCount = data.count
        let readCount = try data.withUnsafeMutableBytes { bytes -> Int in
            var total = 0
            while total < expectedCount {
                let count = Darwin.read(
                    descriptor,
                    bytes.baseAddress!.advanced(by: total),
                    expectedCount - total
                )
                if count > 0 { total += count }
                else if count == 0 { break }
                else if errno != EINTR { throw Self.filesystem("read display presentation") }
            }
            return total
        }
        guard readCount == expectedCount,
              let decoded = try? JSONDecoder().decode(
                  DoryMachineDisplayPresentation.self,
                  from: data
              ), decoded.isValid else {
            throw DoryMachineDisplayPresentationStoreError.invalidRecord
        }
        return decoded.canonicalized
    }

    func publish(
        _ presentation: DoryMachineDisplayPresentation,
        machineID: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard presentation.isValid else {
            throw DoryMachineDisplayPresentationStoreError.invalidPresentation
        }
        try prepareRoot()
        let path = try recordPath(machineID: machineID)
        let encoded = try JSONEncoder.canonical.encode(presentation.canonicalized)
        guard !encoded.isEmpty, encoded.count <= Self.maximumRecordBytes else {
            throw DoryMachineDisplayPresentationStoreError.invalidPresentation
        }
        let temporary = root + "/.tmp-\(UUID().uuidString.lowercased())"
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Self.filesystem("create display presentation") }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary { _ = unlink(temporary) }
        }
        try encoded.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
                if count > 0 { written += count }
                else if errno != EINTR { throw Self.filesystem("write display presentation") }
            }
        }
        guard fsync(descriptor) == 0,
              rename(temporary, path) == 0 else {
            throw Self.filesystem("publish display presentation")
        }
        removeTemporary = false
        try syncRoot()
    }

    func remove(machineID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let path = try recordPath(machineID: machineID)
        guard Self.pathExists(path) else { return }
        guard unlink(path) == 0 else { throw Self.filesystem("remove display presentation") }
        try syncRoot()
    }

    private func prepareRoot() throws {
        if mkdir(root, mode_t(0o700)) != 0, errno != EEXIST {
            throw Self.filesystem("create display presentation directory")
        }
        var metadata = stat()
        guard lstat(root, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & 0o077) == 0 else {
            throw DoryMachineDisplayPresentationStoreError.invalidRecord
        }
    }

    private func syncRoot() throws {
        let descriptor = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Self.filesystem("open display presentation directory") }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw Self.filesystem("sync display presentation directory")
        }
    }

    private func recordPath(machineID: String) throws -> String {
        guard machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil,
              !machineID.hasPrefix(".") else {
            throw DoryMachineDisplayPresentationStoreError.invalidMachineID
        }
        return root + "/\(machineID).json"
    }

    private static func pathExists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    private static func filesystem(_ operation: String) -> DoryMachineDisplayPresentationStoreError {
        .filesystem("\(operation): \(String(cString: strerror(errno)))")
    }
}

private extension JSONEncoder {
    static var canonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
