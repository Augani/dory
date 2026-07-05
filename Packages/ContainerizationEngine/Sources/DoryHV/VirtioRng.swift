import Foundation
import Security

/// virtio-entropy: fills guest buffers from the host CSPRNG. Keeps the guest crng healthy in a
/// machine with almost no interrupt-timing entropy.
public final class VirtioRng: VirtioDeviceBackend {
    public let deviceID: UInt32 = 4
    public let queueCount = 1
    public let deviceFeatures: UInt64 = 0
    public var configSpace: [UInt8] { [] }

    public init() {}

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        let virtqueue = transport.queues[0]
        var interrupt = false
        while let chain = (try? virtqueue.pop()) ?? nil {
            var written = 0
            for segment in chain.writableSegments {
                if SecRandomCopyBytes(kSecRandomDefault, segment.length, segment.pointer) == errSecSuccess {
                    written += segment.length
                }
            }
            let wants = (try? virtqueue.push(chain, written: written)) ?? false
            interrupt = interrupt || wants
        }
        if interrupt {
            transport.notifyUsed()
        }
    }
}
