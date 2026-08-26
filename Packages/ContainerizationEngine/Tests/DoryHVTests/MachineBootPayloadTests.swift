import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DoryHV

struct MachineBootPayloadTests {
    @Test func readsAnonymousReadOnlyDescriptorsWithPreadAndClosesThem() throws {
        let kernelBytes = Data("immutable-kernel".utf8)
        let initrdBytes = Data("immutable-initrd".utf8)
        let kernel = try anonymousReadOnlyBlob(kernelBytes)
        let initrd = try anonymousReadOnlyBlob(initrdBytes)
        #expect(lseek(kernel, 0, SEEK_END) == off_t(kernelBytes.count))
        #expect(lseek(initrd, 1, SEEK_SET) == 1)

        let payload = try MachineBootPayload.inheritedReadOnlyDescriptors(
            kernel: authority(kernel, bytes: kernelBytes, maximum: 1024),
            initrd: authority(initrd, bytes: initrdBytes, maximum: 1024)
        )

        #expect(
            payload.retainedImmutableByteCount == UInt64(kernelBytes.count + initrdBytes.count)
        )
        try payload.consumeForGuestLoad { loadedKernel, loadInitrd in
            #expect(loadedKernel == kernelBytes)
            let loadedInitrd = try loadInitrd()
            #expect(loadedInitrd == initrdBytes)
        }
        #expect(payload.retainedImmutableByteCount == 0)
        #expect(payload.immutableBytesWereConsumed)
        #expect(fcntl(kernel, F_GETFD) == -1)
        #expect(fcntl(initrd, F_GETFD) == -1)
    }

    @Test func immutableAuthorityReleasesBytesAfterSuccessfulGuestMemoryLoad() throws {
        let kernelBytes = arm64Image(textOffset: 0x1_000, byteCount: 4_096)
        let initrdBytes = Data("immutable-initrd".utf8)
        let payload = MachineBootPayload.immutableBytes(
            kernel: kernelBytes,
            initrd: initrdBytes
        )
        let configuration = MachineConfiguration(
            bootPayload: payload,
            commandLine: "console=ttyAMA0",
            memoryBytes: 1 << 20,
            cpuCount: 1
        )
        let copiedConfiguration = configuration
        let memory = try GuestMemory(guestBase: 0x8000_0000, size: 1 << 20)
        let initrdAddress = memory.guestBase + 0x20_000

        #expect(
            copiedConfiguration.bootPayload.retainedImmutableByteCount
                == UInt64(kernelBytes.count + initrdBytes.count)
        )
        try configuration.bootPayload.consumeForGuestLoad { kernelData, loadInitrd in
            // Ownership has already left every retained payload/configuration copy while the
            // loader holds the sole temporary references.
            #expect(payload.retainedImmutableByteCount == 0)
            #expect(copiedConfiguration.bootPayload.retainedImmutableByteCount == 0)

            let image = try KernelImage(data: kernelData)
            #expect(
                try image.load(into: memory) == memory.guestBase + image.textOffset
            )
            let initrdData = try #require(try loadInitrd())
            let destination = try memory.hostPointer(
                at: initrdAddress,
                count: UInt64(initrdData.count)
            )
            initrdData.withUnsafeBytes { source in
                destination.copyMemory(
                    from: source.baseAddress!,
                    byteCount: source.count
                )
            }
        }

        #expect(
            try memory.readBytes(
                at: memory.guestBase + 0x1_000,
                count: kernelBytes.count
            ) == Array(kernelBytes)
        )
        #expect(
            try memory.readBytes(at: initrdAddress, count: initrdBytes.count)
                == Array(initrdBytes)
        )
        #expect(payload.retainedImmutableByteCount == 0)
        #expect(configuration.bootPayload.retainedImmutableByteCount == 0)
        #expect(copiedConfiguration.bootPayload.retainedImmutableByteCount == 0)
        #expect(payload.immutableBytesWereConsumed)
        assertAlreadyConsumed(payload)
    }

    @Test func immutableAuthorityRetiresDeterministicallyWhenGuestLoadThrows() {
        let payload = MachineBootPayload.immutableBytes(
            kernel: Data("invalid-kernel".utf8),
            initrd: Data("initrd".utf8)
        )

        do {
            try payload.consumeForGuestLoad { _, _ in
                throw VMError.bootFailure("deterministic loader failure")
            }
            Issue.record("failing loader unexpectedly succeeded")
        } catch {
            #expect(
                String(describing: error) == "boot failure: deterministic loader failure"
            )
        }
        #expect(payload.retainedImmutableByteCount == 0)
        #expect(payload.immutableBytesWereConsumed)
        assertAlreadyConsumed(payload)
    }

    @Test func legacyPathPayloadRemainsRepeatable() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: false
        )
        let kernelPath = directory + "/kernel"
        let initrdPath = directory + "/initrd"
        let kernelBytes = Data("legacy-kernel".utf8)
        let initrdBytes = Data("legacy-initrd".utf8)
        try kernelBytes.write(to: URL(fileURLWithPath: kernelPath))
        try initrdBytes.write(to: URL(fileURLWithPath: initrdPath))
        let payload = MachineBootPayload.legacyPaths(
            kernel: kernelPath,
            initrd: initrdPath
        )

        for _ in 0..<2 {
            try payload.consumeForGuestLoad { kernel, loadInitrd in
                #expect(kernel == kernelBytes)
                let loadedInitrd = try loadInitrd()
                #expect(loadedInitrd == initrdBytes)
            }
        }
        #expect(payload.retainedImmutableByteCount == 0)
        #expect(!payload.immutableBytesWereConsumed)
    }

    @Test func rejectsWritableOrStillLinkedBootAuthority() throws {
        let bytes = Data("kernel".utf8)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        #expect(chmod(directory, 0o700) == 0)
        let path = directory + "/blob"
        try bytes.write(to: URL(fileURLWithPath: path))
        #expect(chmod(path, 0o600) == 0)

        let writable = open(path, O_RDWR | O_CLOEXEC)
        #expect(writable >= 0)
        #expect(throws: (any Error).self) {
            _ = try MachineBootPayload.inheritedReadOnlyDescriptors(
            kernel: authority(writable, bytes: bytes, maximum: 1024),
            initrd: nil
            )
        }
        #expect(fcntl(writable, F_GETFD) == -1)

        let linkedReadOnly = open(path, O_RDONLY | O_CLOEXEC)
        #expect(linkedReadOnly >= 0)
        #expect(throws: (any Error).self) {
            _ = try MachineBootPayload.inheritedReadOnlyDescriptors(
                kernel: authority(linkedReadOnly, bytes: bytes, maximum: 1024),
                initrd: nil
            )
        }
        #expect(fcntl(linkedReadOnly, F_GETFD) == -1)
    }

    @Test func rejectsDigestSizeAndAllocationCeilingBeforeReturningBytes() throws {
        let bytes = Data("kernel-authority".utf8)

        let wrongDigest = try anonymousReadOnlyBlob(bytes)
        #expect(throws: (any Error).self) {
            _ = try MachineBootPayload.inheritedReadOnlyDescriptors(
                kernel: MachineInheritedBootBlob(
                    descriptor: wrongDigest,
                    byteCount: UInt64(bytes.count),
                    sha256: String(repeating: "0", count: 64),
                    maximumByteCount: 1024
                ),
                initrd: nil
            )
        }
        #expect(fcntl(wrongDigest, F_GETFD) == -1)

        let wrongSize = try anonymousReadOnlyBlob(bytes)
        #expect(throws: (any Error).self) {
            _ = try MachineBootPayload.inheritedReadOnlyDescriptors(
                kernel: MachineInheritedBootBlob(
                    descriptor: wrongSize,
                    byteCount: UInt64(bytes.count + 1),
                    sha256: digest(bytes),
                    maximumByteCount: 1024
                ),
                initrd: nil
            )
        }
        #expect(fcntl(wrongSize, F_GETFD) == -1)

        let oversized = try anonymousReadOnlyBlob(bytes)
        #expect(throws: (any Error).self) {
            _ = try MachineBootPayload.inheritedReadOnlyDescriptors(
                kernel: MachineInheritedBootBlob(
                    descriptor: oversized,
                    byteCount: 2_048,
                    sha256: digest(bytes),
                    maximumByteCount: 1_024
                ),
                initrd: nil
            )
        }
        #expect(fcntl(oversized, F_GETFD) == -1)
    }

    private func authority(
        _ descriptor: Int32,
        bytes: Data,
        maximum: UInt64
    ) -> MachineInheritedBootBlob {
        MachineInheritedBootBlob(
            descriptor: descriptor,
            byteCount: UInt64(bytes.count),
            sha256: digest(bytes),
            maximumByteCount: maximum
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func arm64Image(textOffset: UInt64, byteCount: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: max(byteCount, 65))
        putLittleEndian(textOffset, into: &bytes, at: 8)
        putLittleEndian(UInt64(bytes.count), into: &bytes, at: 16)
        putLittleEndian(UInt32(0x644D_5241), into: &bytes, at: 56)
        return Data(bytes)
    }

    private func putLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        for index in 0..<MemoryLayout<T>.size {
            bytes[offset + index] = UInt8(
                truncatingIfNeeded: value >> T(index * 8)
            )
        }
    }

    private func assertAlreadyConsumed(_ payload: MachineBootPayload) {
        do {
            try payload.consumeForGuestLoad { _, _ in
                Issue.record("consumed resolved authority invoked its loader")
            }
            Issue.record("consumed payload unexpectedly permitted reuse")
        } catch {
            #expect(
                String(describing: error)
                    == "invalid configuration: resolved immutable boot payload has already been consumed"
            )
        }
    }

    private func anonymousReadOnlyBlob(_ data: Data) throws -> Int32 {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        #expect(chmod(directory, 0o700) == 0)
        let path = directory + "/blob"
        try data.write(to: URL(fileURLWithPath: path))
        #expect(chmod(path, 0o600) == 0)
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        #expect(descriptor >= 0)
        #expect(unlink(path) == 0)
        try FileManager.default.removeItem(atPath: directory)
        return descriptor
    }

    private func temporaryDirectory() -> String {
        "/tmp/dory-machine-boot-payload-\(getpid())-\(UUID().uuidString)"
    }
}
