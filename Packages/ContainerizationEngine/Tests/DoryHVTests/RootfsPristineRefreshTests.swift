import Foundation
import Testing
@testable import DoryHV

@Suite struct RootfsPristineRefreshTests {
    @Test func installsPristineAndStampWhenBothAbsent() throws {
        let state = try makeStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: state) }
        let bundle = try writeFixture(in: state, named: "bundle.ext4", contents: "bundle-A")
        let pristine = state + "/rootfs-pristine.ext4"
        let stamp = state + "/rootfs-pristine.stamp"

        #expect(!FileManager.default.fileExists(atPath: pristine))

        try PristineRootfs.ensure(state: state, bundledRootfs: bundle)

        #expect(contents(ofFile: pristine) == "bundle-A")
        #expect(contents(ofFile: stamp) == (try PristineRootfs.identity(ofBundledRootfs: bundle)))
    }

    @Test func reinstallsWhenStampAbsentEvenIfPristineExists() throws {
        let state = try makeStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: state) }
        let bundle = try writeFixture(in: state, named: "bundle.ext4", contents: "fresh-bundle")
        let pristine = try writeFixture(in: state, named: "rootfs-pristine.ext4", contents: "stale-pristine")
        let stamp = state + "/rootfs-pristine.stamp"

        #expect(!FileManager.default.fileExists(atPath: stamp))

        try PristineRootfs.ensure(state: state, bundledRootfs: bundle)

        #expect(contents(ofFile: pristine) == "fresh-bundle")
        #expect(contents(ofFile: stamp) == (try PristineRootfs.identity(ofBundledRootfs: bundle)))
    }

    @Test func reinstallsWhenStampDoesNotMatchBundle() throws {
        let state = try makeStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: state) }
        let bundle = try writeFixture(in: state, named: "bundle.ext4", contents: "new-bundle-content")
        let pristine = try writeFixture(in: state, named: "rootfs-pristine.ext4", contents: "old-pristine")
        let stamp = try writeFixture(in: state, named: "rootfs-pristine.stamp", contents: "stale-identity")

        try PristineRootfs.ensure(state: state, bundledRootfs: bundle)

        #expect(contents(ofFile: pristine) == "new-bundle-content")
        let identity = try PristineRootfs.identity(ofBundledRootfs: bundle)
        #expect(contents(ofFile: stamp) == identity)
        #expect(contents(ofFile: stamp) != "stale-identity")
    }

    @Test func doesNotRecopyWhenStampMatches() throws {
        let state = try makeStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: state) }
        let bundle = try writeFixture(in: state, named: "bundle.ext4", contents: "bundle-content")
        // Pristine content deliberately differs from the bundle so a wrongful recopy is observable.
        let pristine = try writeFixture(in: state, named: "rootfs-pristine.ext4", contents: "sentinel-unchanged")
        let identity = try PristineRootfs.identity(ofBundledRootfs: bundle)
        _ = try writeFixture(in: state, named: "rootfs-pristine.stamp", contents: identity)
        let before = try modificationDate(ofFile: pristine)

        try PristineRootfs.ensure(state: state, bundledRootfs: bundle)

        #expect(contents(ofFile: pristine) == "sentinel-unchanged")
        #expect(try modificationDate(ofFile: pristine) == before)
    }

    @Test func removesAbandonedPartialEvenWhenPristineAndStampAreCurrent() throws {
        let state = try makeStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: state) }
        let bundle = try writeFixture(in: state, named: "bundle.ext4", contents: "bundle-content")
        let pristine = try writeFixture(in: state, named: "rootfs-pristine.ext4", contents: "sentinel-unchanged")
        let identity = try PristineRootfs.identity(ofBundledRootfs: bundle)
        _ = try writeFixture(in: state, named: "rootfs-pristine.stamp", contents: identity)
        let partial = try writeFixture(in: state, named: "rootfs-pristine.ext4.partial", contents: "crash-residue")

        try PristineRootfs.ensure(state: state, bundledRootfs: bundle)

        #expect(!FileManager.default.fileExists(atPath: partial))
        #expect(contents(ofFile: pristine) == "sentinel-unchanged")
    }

    private func makeStateDirectory() throws -> String {
        let directory = NSTemporaryDirectory() + "dory-pristine-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeFixture(in directory: String, named name: String, contents: String) throws -> String {
        let path = directory + "/" + name
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func contents(ofFile path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func modificationDate(ofFile path: String) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let date = attributes[.modificationDate] as? Date else {
            throw VMError.invalidConfiguration("no mtime for \(path)")
        }
        return date
    }
}
