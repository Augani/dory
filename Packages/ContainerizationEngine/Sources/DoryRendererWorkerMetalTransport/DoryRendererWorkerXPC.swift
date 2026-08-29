import DoryRendererWorkerContracts
import Foundation
import Metal

/// Complete Objective-C/XPC surface for one renderer generation. Exact binary frames and bounded
/// `FileHandle` arrays remain the control/data plane; the only Objective-C graphics object admitted
/// is Metal's secure-coding cross-process texture handle. A foreign renderer pointer never crosses
/// process identity.
@objc(DoryRendererWorkerXPCProtocol)
public protocol DoryRendererWorkerXPCProtocol: NSObjectProtocol {
    func bootstrap(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func exchange(
        _ frame: Data,
        descriptors: [FileHandle],
        withReply reply: @escaping (Data, [FileHandle], MTLSharedTextureHandle?) -> Void
    )
}

/// Constructs the single transport interface used by both authenticated peers. Explicit class
/// allowlists prevent Foundation from widening either descriptor or Metal-handle authority.
public enum DoryRendererWorkerXPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: DoryRendererWorkerXPCProtocol.self)
        let descriptorClasses = NSSet(
            objects: NSArray.self,
            FileHandle.self
        ) as! Set<AnyHashable>
        let textureHandleClasses = NSSet(
            objects: MTLSharedTextureHandle.self
        ) as! Set<AnyHashable>
        let exchangeSelector = #selector(
            DoryRendererWorkerXPCProtocol.exchange(_:descriptors:withReply:)
        )
        interface.setClasses(
            descriptorClasses,
            for: exchangeSelector,
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            descriptorClasses,
            for: exchangeSelector,
            argumentIndex: 1,
            ofReply: true
        )
        interface.setClasses(
            textureHandleClasses,
            for: exchangeSelector,
            argumentIndex: 2,
            ofReply: true
        )
        return interface
    }
}
