import AppKit
import CoreGraphics
import DoryOperations

@MainActor
public enum DoryHostDisplayPresentation {
    public static func stableUUID(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber,
              let unmanaged = CGDisplayCreateUUIDFromDisplayID(
                  CGDirectDisplayID(number.uint32Value)
              ) else { return nil }
        let uuid = unmanaged.takeRetainedValue()
        return (CFUUIDCreateString(nil, uuid) as String).lowercased()
    }

    public static func screen(
        forStableUUID uuid: String,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSScreen? {
        screens.first { stableUUID(for: $0) == uuid }
    }

    /// Moves a guest window onto its requested physical display before native fullscreen begins.
    /// Returns false when the display is disconnected; callers then keep a normal window.
    @discardableResult
    public static func enterDedicatedFullscreen(
        window: NSWindow,
        assignment: DoryGuestDisplayPresentationAssignment?
    ) -> Bool {
        guard assignment?.mode == .dedicatedFullscreen,
              let uuid = assignment?.hostDisplayUUID,
              let screen = screen(forStableUUID: uuid) else { return false }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrame(screen.frame, display: false)
        window.makeKeyAndOrderFront(nil)
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        return true
    }

    /// Exits a now-orphaned fullscreen space when its remembered monitor disappears.
    @discardableResult
    public static func recoverDisconnectedDisplay(
        window: NSWindow,
        assignment: DoryGuestDisplayPresentationAssignment?
    ) -> Bool {
        guard assignment?.mode == .dedicatedFullscreen,
              let uuid = assignment?.hostDisplayUUID,
              screen(forStableUUID: uuid) == nil else { return false }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        if let main = NSScreen.main {
            window.setFrameOrigin(NSPoint(
                x: main.visibleFrame.midX - window.frame.width / 2,
                y: main.visibleFrame.midY - window.frame.height / 2
            ))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}
