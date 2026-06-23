import Testing
import Foundation
@testable import Dory

struct VolumeBrowserTests {
    private func makeTar(name: String, content: [UInt8]) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        for (i, b) in Array(name.utf8).prefix(100).enumerated() { header[i] = b }
        let sizeOctal = Array(String(format: "%011o", content.count).utf8)
        for (i, b) in sizeOctal.enumerated() { header[124 + i] = b }
        header[156] = UInt8(ascii: "0")
        var tar = header + content
        let pad = (512 - content.count % 512) % 512
        tar += [UInt8](repeating: 0, count: pad)
        tar += [UInt8](repeating: 0, count: 1024)
        return Data(tar)
    }

    @Test func extractsRegularFileContent() {
        let content = Array("hi there".utf8)
        let tar = makeTar(name: "hello.txt", content: content)
        #expect(VolumeBrowser.extractSingleFileFromTar(tar) == Data(content))
    }

    @Test func extractsEmptyFile() {
        let tar = makeTar(name: "empty", content: [])
        #expect(VolumeBrowser.extractSingleFileFromTar(tar) == Data())
    }

    @Test func extractsBinaryContentLosslessly() {
        let content: [UInt8] = [0x00, 0xFF, 0x10, 0x80, 0x00, 0x7F]
        let tar = makeTar(name: "bin.dat", content: content)
        #expect(VolumeBrowser.extractSingleFileFromTar(tar) == Data(content))
    }

    @Test func returnsNilForShortData() {
        #expect(VolumeBrowser.extractSingleFileFromTar(Data([1, 2, 3])) == nil)
    }

    @Test func returnsNilForAllZeroData() {
        #expect(VolumeBrowser.extractSingleFileFromTar(Data(count: 1024)) == nil)
    }
}
