// Unit-only synthetic screen generator. These bytes are NOT physical guest evidence.
import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(2) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: 1280, height: 720).fill()
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                                               .foregroundColor: NSColor.white]
for (index, line) in CommandLine.arguments[1].components(separatedBy: "\n").enumerated() {
    NSAttributedString(string: line, attributes: attributes).draw(at: NSPoint(x: 30, y: 650 - index * 40))
}
NSGraphicsContext.restoreGraphicsState()
guard let bytes = bitmap.representation(using: .png, properties: [:]) else { exit(2) }
try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .withoutOverwriting)
