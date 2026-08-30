import CoreFoundation
import CoreMediaIO
import DoryMacGuestCameraExtensionCore

let source = DoryCameraProviderSource()
CMIOExtensionProvider.startService(provider: source.provider)
CFRunLoopRun()
