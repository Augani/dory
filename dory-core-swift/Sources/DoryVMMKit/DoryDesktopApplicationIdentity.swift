import AppKit
import Foundation

/// Gives every interactive desktop backend one Dory-family identity without making the desktop
/// process look like a second copy of the Dory manager in the Dock.
@MainActor
public enum DoryDesktopApplicationIdentity {
    private static let managerBundleIdentifier = "com.pythonxi.Dory"
    private static let iconPointSize = NSSize(width: 512, height: 512)

    @MainActor
    public static func install(on application: NSApplication) {
        application.applicationIconImage = desktopIcon(
            managerIcon: enclosingManagerIcon(startingAt: Bundle.main.bundleURL)
        )
    }

    static func desktopIcon(managerIcon: NSImage?) -> NSImage {
        let icon = NSImage(size: iconPointSize, flipped: false) { bounds in
            if let managerIcon {
                managerIcon.draw(
                    in: bounds,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
            } else {
                drawFallbackDoryIcon(in: bounds)
            }

            drawDesktopBadge(in: bounds)
            return true
        }
        icon.isTemplate = false
        return icon
    }

    private static func enclosingManagerIcon(startingAt bundleURL: URL) -> NSImage? {
        var candidate = bundleURL.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app",
               candidate != bundleURL,
               Bundle(url: candidate)?.bundleIdentifier == managerBundleIdentifier {
                let iconURL = candidate
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("AppIcon.icns")
                if let icon = NSImage(contentsOf: iconURL) {
                    return icon
                }
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static func drawDesktopBadge(in bounds: NSRect) {
        let scale = bounds.width / iconPointSize.width
        let badge = NSRect(x: 310, y: 24, width: 178, height: 178).scaled(by: scale)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 16 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -5 * scale)
        shadow.set()
        NSColor(red: 0.05, green: 0.11, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 43 * scale, yRadius: 43 * scale).fill()
        NSGraphicsContext.restoreGraphicsState()

        let screen = NSRect(x: 337, y: 79, width: 124, height: 82).scaled(by: scale)
        NSColor.white.withAlphaComponent(0.96).setStroke()
        let screenPath = NSBezierPath(
            roundedRect: screen,
            xRadius: 14 * scale,
            yRadius: 14 * scale
        )
        screenPath.lineWidth = 10 * scale
        screenPath.stroke()

        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 399, y: 79).scaled(by: scale))
        stand.line(to: NSPoint(x: 399, y: 58).scaled(by: scale))
        stand.move(to: NSPoint(x: 372, y: 58).scaled(by: scale))
        stand.line(to: NSPoint(x: 426, y: 58).scaled(by: scale))
        stand.lineWidth = 10 * scale
        stand.lineCapStyle = .round
        stand.stroke()
    }

    private static func drawFallbackDoryIcon(in bounds: NSRect) {
        let scale = bounds.width / iconPointSize.width
        NSColor(red: 0.91, green: 0.94, blue: 1, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 8 * scale, dy: 8 * scale),
            xRadius: 112 * scale,
            yRadius: 112 * scale
        ).fill()

        NSColor(red: 1, green: 0.69, blue: 0.13, alpha: 1).setFill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 378, y: 226).scaled(by: scale))
        tail.line(to: NSPoint(x: 470, y: 164).scaled(by: scale))
        tail.line(to: NSPoint(x: 470, y: 318).scaled(by: scale))
        tail.close()
        tail.fill()

        NSColor(red: 0.24, green: 0.49, blue: 0.96, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 86, y: 118, width: 320, height: 274).scaled(by: scale)).fill()

        NSColor(red: 0.05, green: 0.11, blue: 0.24, alpha: 1).setFill()
        let cap = NSBezierPath()
        cap.move(to: NSPoint(x: 104, y: 332).scaled(by: scale))
        cap.curve(
            to: NSPoint(x: 390, y: 246).scaled(by: scale),
            controlPoint1: NSPoint(x: 188, y: 420).scaled(by: scale),
            controlPoint2: NSPoint(x: 334, y: 402).scaled(by: scale)
        )
        cap.curve(
            to: NSPoint(x: 104, y: 332).scaled(by: scale),
            controlPoint1: NSPoint(x: 326, y: 326).scaled(by: scale),
            controlPoint2: NSPoint(x: 202, y: 334).scaled(by: scale)
        )
        cap.fill()

        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 140, y: 230, width: 62, height: 62).scaled(by: scale)).fill()
        NSColor(red: 0.05, green: 0.11, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 153, y: 241, width: 35, height: 35).scaled(by: scale)).fill()
    }
}

private extension NSRect {
    func scaled(by scale: CGFloat) -> NSRect {
        NSRect(x: origin.x * scale, y: origin.y * scale, width: width * scale, height: height * scale)
    }
}

private extension NSPoint {
    func scaled(by scale: CGFloat) -> NSPoint {
        NSPoint(x: x * scale, y: y * scale)
    }
}
