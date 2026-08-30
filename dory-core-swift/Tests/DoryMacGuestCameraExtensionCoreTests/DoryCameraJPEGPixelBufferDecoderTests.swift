import CoreGraphics
import CoreVideo
import DoryCameraBridgeContracts
import DoryMacGuestCameraExtensionCore
import Foundation
import ImageIO
import XCTest

final class DoryCameraJPEGPixelBufferDecoderTests: XCTestCase {
    func testJPEGBecomesExpectedBGRAPixelBuffer() throws {
        let width = 640
        let height = 480
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let frame = try DoryCameraBridgeV1.JPEGFrame(
            widthPixels: UInt32(width),
            heightPixels: UInt32(height),
            hostPresentationTimeNanoseconds: 1,
            jpeg: jpeg as Data
        )
        let pixelBuffer = try DoryCameraJPEGPixelBufferDecoder.decode(frame)
        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer), width)
        XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer), height)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixelBuffer), kCVPixelFormatType_32BGRA)
    }
}
