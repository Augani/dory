import Darwin
import DoryFirmware
import Foundation

public enum DoryARMVirtFirmwareBundleLayout {
    public static let manifest = "manifest.json"
    public static let firmwareCode = "firmware-code.fd"
    public static let variableStoreTemplate = "variable-store-template.json"
    public static let sbom = "sbom.json"
}

public enum DoryARMVirtFirmwareBundleError: Error, Sendable, Equatable {
    case invalidDirectory
    case unsafeDirectory
    case unsafeArtifact(String)
    case artifactTooLarge(String)
    case invalidManifest
    case verificationFailed(String)
}

/// Daemon-side admission of one complete DoryARMVirt firmware release bundle.
///
/// The directory is resolved only in the trusted daemon. Runtime helpers receive freshly staged,
/// unlinked read-only descriptors plus the verified manifest embedded in their launch plan.
public struct DoryARMVirtFirmwareBundle: Sendable, Equatable {
    public let directory: String

    public init(directory: String) throws {
        guard directory.hasPrefix("/"), !directory.utf8.contains(0) else {
            throw DoryARMVirtFirmwareBundleError.invalidDirectory
        }
        let canonical = URL(fileURLWithPath: directory).standardizedFileURL.path
        guard canonical == directory, canonical != "/" else {
            throw DoryARMVirtFirmwareBundleError.invalidDirectory
        }
        self.directory = directory
    }

    public func loadVerified(
        expectedPlatform: DoryFirmwarePlatform? = nil
    ) throws -> DoryVerifiedFirmwareArtifacts {
        let descriptor = directory.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 3 else { throw DoryARMVirtFirmwareBundleError.unsafeDirectory }
        defer { Darwin.close(descriptor) }
        var directoryStatus = stat()
        guard fstat(descriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & 0o022 == 0 else {
            throw DoryARMVirtFirmwareBundleError.unsafeDirectory
        }

        let manifestData = try read(
            DoryARMVirtFirmwareBundleLayout.manifest,
            from: descriptor,
            maximumByteCount: 64 * 1_024
        )
        let manifest: DoryFirmwareArtifactManifest
        do {
            manifest = try JSONDecoder().decode(
                DoryFirmwareArtifactManifest.self,
                from: manifestData
            )
        } catch {
            throw DoryARMVirtFirmwareBundleError.invalidManifest
        }
        let firmware = try read(
            DoryARMVirtFirmwareBundleLayout.firmwareCode,
            from: descriptor,
            maximumByteCount: manifest.firmwareCodeByteCount
        )
        let variableTemplate = try read(
            DoryARMVirtFirmwareBundleLayout.variableStoreTemplate,
            from: descriptor,
            maximumByteCount: manifest.variableStoreTemplateByteCount
        )
        let sbom = try read(
            DoryARMVirtFirmwareBundleLayout.sbom,
            from: descriptor,
            maximumByteCount: 16 * 1_024 * 1_024
        )
        do {
            let template = try DoryUEFIVariableStoreSnapshot.decodeCanonicalTemplate(
                variableTemplate
            )
            if let expectedPlatform,
               manifest.platform != expectedPlatform || template.platform != expectedPlatform {
                throw DoryARMVirtFirmwareBundleError.verificationFailed(
                    "firmware bundle platform does not match \(expectedPlatform.rawValue)"
                )
            }
            return try DoryVerifiedFirmwareArtifacts(
                manifest: manifest,
                firmwareCode: firmware,
                variableStoreTemplate: variableTemplate,
                sbom: sbom
            )
        } catch {
            throw DoryARMVirtFirmwareBundleError.verificationFailed(String(describing: error))
        }
    }

    private func read(
        _ name: String,
        from directoryDescriptor: Int32,
        maximumByteCount: UInt64
    ) throws -> Data {
        let descriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 3 else {
            throw DoryARMVirtFirmwareBundleError.unsafeArtifact(name)
        }
        defer { Darwin.close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        var before = stat()
        guard flags >= 0, flags & O_ACCMODE == O_RDONLY,
              fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              before.st_mode & 0o022 == 0,
              before.st_size > 0 else {
            throw DoryARMVirtFirmwareBundleError.unsafeArtifact(name)
        }
        guard UInt64(before.st_size) <= maximumByteCount,
              let count = Int(exactly: before.st_size) else {
            throw DoryARMVirtFirmwareBundleError.artifactTooLarge(name)
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = pread(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
                if result > 0 { offset += result }
                else if result < 0, errno == EINTR { continue }
                else { throw DoryARMVirtFirmwareBundleError.unsafeArtifact(name) }
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw DoryARMVirtFirmwareBundleError.unsafeArtifact(name)
        }
        return data
    }
}
