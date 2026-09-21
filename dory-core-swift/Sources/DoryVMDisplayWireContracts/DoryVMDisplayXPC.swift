import Foundation
import Metal

/// Least-authority display relay shared by the VM owner, doryd broker, and Dory app. The runner
/// keeps a publish reply open until the app commits or rejects the corresponding Metal command
/// buffer, preserving the existing exactly-once guest-flush acknowledgement.
@objc(DoryVMDisplayBrokerXPCProtocol)
public protocol DoryVMDisplayBrokerXPCProtocol: NSObjectProtocol {
    func publishFrame(
        _ frame: Data,
        descriptors: [FileHandle],
        sharedTextureHandle: MTLSharedTextureHandle?,
        withReply reply: @escaping (Bool, String) -> Void
    )
    func nextFrame(
        _ machineID: String,
        scanoutID: UInt32,
        afterSequence: UInt64,
        withReply reply: @escaping (Bool, Data, [FileHandle], MTLSharedTextureHandle?, String) -> Void
    )
    func acknowledgeFrame(
        _ machineID: String,
        leaseID: String,
        presented: Bool,
        withReply reply: @escaping (Bool, String) -> Void
    )
    func sendCommand(
        _ command: Data,
        withReply reply: @escaping (Bool, String) -> Void
    )
    func nextCommand(
        _ machineID: String,
        operationID: String,
        afterSequence: UInt64,
        withReply reply: @escaping (Bool, Data, String) -> Void
    )
    func retireRunner(
        _ machineID: String,
        operationID: String,
        withReply reply: @escaping (Bool, String) -> Void
    )
}

public enum DoryVMDisplayBrokerXPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: DoryVMDisplayBrokerXPCProtocol.self)
        let descriptorClasses = NSSet(objects: NSArray.self, FileHandle.self) as! Set<AnyHashable>
        let textureClasses = NSSet(objects: MTLSharedTextureHandle.self) as! Set<AnyHashable>
        let publishSelector = #selector(
            DoryVMDisplayBrokerXPCProtocol.publishFrame(
                _:descriptors:sharedTextureHandle:withReply:
            )
        )
        let nextSelector = #selector(
            DoryVMDisplayBrokerXPCProtocol.nextFrame(
                _:scanoutID:afterSequence:withReply:
            )
        )
        interface.setClasses(
            descriptorClasses,
            for: publishSelector,
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            textureClasses,
            for: publishSelector,
            argumentIndex: 2,
            ofReply: false
        )
        interface.setClasses(
            descriptorClasses,
            for: nextSelector,
            argumentIndex: 2,
            ofReply: true
        )
        interface.setClasses(
            textureClasses,
            for: nextSelector,
            argumentIndex: 3,
            ofReply: true
        )
        return interface
    }
}
