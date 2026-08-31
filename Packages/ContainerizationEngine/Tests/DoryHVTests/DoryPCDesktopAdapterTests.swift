import CoreGraphics
import DoryVirtio
import Foundation
import ImageIO
import Testing
@testable import dory_hv

@Suite struct DoryPCDesktopAdapterTests {
    @Test func cameraBridgeConvertsJPEGToExactYUY2Frame() throws {
        var pixels: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255]
        let image = try pixels.withUnsafeMutableBytes { bytes -> CGImage in
            let context = try #require(CGContext(
                data: bytes.baseAddress,
                width: 2,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            return try #require(context.makeImage())
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let converted = try #require(DoryPCCameraBridge.yuy2(
            jpeg: data as Data,
            width: 2,
            height: 1
        ))
        #expect(converted.count == 4)
        #expect(abs(Int(converted[0]) - 82) <= 8)
        #expect(abs(Int(converted[1]) - 90) <= 8)
        #expect(abs(Int(converted[2]) - 82) <= 8)
        #expect(abs(Int(converted[3]) - 240) <= 8)
    }

    @Test func softwareFrameConversionClipsDamageAndCopiesExactRows() throws {
        let mailbox = DesktopFrameMailbox(scanoutID: 0)
        let sink = DoryPCSoftwareDisplaySink(mailbox: mailbox)
        let pixels = Array(UInt8(0)..<UInt8(48))
        let converted = try #require(sink.convert(DoryVirtioGPUFrame(
            scanoutID: 0,
            resourceID: 9,
            scanoutRectangle: .init(x: 1, y: 1, width: 3, height: 2),
            damagedRectangle: .init(x: 2, y: 0, width: 3, height: 3),
            resourceWidth: 4,
            resourceHeight: 3,
            format: .b8g8r8a8UNorm,
            pixels: pixels
        )))

        #expect(converted.width == 3)
        #expect(converted.height == 2)
        #expect(converted.stride == 8)
        #expect(converted.dirtyRect == .init(x: 1, y: 0, width: 2, height: 2))
        #expect(converted.bytes == Data(pixels[24..<32] + pixels[40..<48]))
    }

    @Test func softwareFrameGenerationAdvancesOnlyWhenResourceIdentityChanges() throws {
        let sink = DoryPCSoftwareDisplaySink(mailbox: DesktopFrameMailbox(scanoutID: 0))
        func frame(width: UInt32, height: UInt32) -> DoryVirtioGPUFrame {
            DoryVirtioGPUFrame(
                scanoutID: 0,
                resourceID: 7,
                scanoutRectangle: .init(x: 0, y: 0, width: width, height: height),
                damagedRectangle: .init(x: 0, y: 0, width: width, height: height),
                resourceWidth: width,
                resourceHeight: height,
                format: .b8g8r8a8UNorm,
                pixels: [UInt8](repeating: 0, count: Int(width * height * 4))
            )
        }

        let first = try #require(sink.convert(frame(width: 2, height: 2)))
        let second = try #require(sink.convert(frame(width: 2, height: 2)))
        let replacement = try #require(sink.convert(frame(width: 3, height: 2)))
        #expect(first.resourceGeneration == second.resourceGeneration)
        #expect(replacement.resourceGeneration == first.resourceGeneration + 1)
    }

    @Test func softwareFrameConversionRejectsTruncatedResources() {
        let sink = DoryPCSoftwareDisplaySink(mailbox: DesktopFrameMailbox(scanoutID: 0))
        let frame = DoryVirtioGPUFrame(
            scanoutID: 0,
            resourceID: 1,
            scanoutRectangle: .init(x: 0, y: 0, width: 2, height: 2),
            damagedRectangle: .init(x: 0, y: 0, width: 2, height: 2),
            resourceWidth: 2,
            resourceHeight: 2,
            format: .b8g8r8a8UNorm,
            pixels: [UInt8](repeating: 0, count: 15)
        )
        #expect(sink.convert(frame) == nil)
    }
}
