import AppKit
import CoreGraphics

nonisolated struct HostDisplayChoice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String

    @MainActor
    static func connectedDisplays() -> [HostDisplayChoice] {
        NSScreen.screens.compactMap { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber,
                  let unmanaged = CGDisplayCreateUUIDFromDisplayID(
                      CGDirectDisplayID(number.uint32Value)
                  ) else { return nil }
            let uuid = unmanaged.takeRetainedValue()
            return HostDisplayChoice(
                id: (CFUUIDCreateString(nil, uuid) as String).lowercased(),
                name: screen.localizedName
            )
        }
    }
}
