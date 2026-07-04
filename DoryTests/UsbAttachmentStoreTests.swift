import Foundation
import Testing
@testable import Dory

struct UsbAttachmentStoreTests {
    @Test func remembersAttachmentsSortedByMachineAndBusID() throws {
        let defaults = try makeDefaults()
        let store = UsbAttachmentStore(defaults: defaults, key: "usb")

        _ = try store.remember(machine: "zed", busID: "2-1", port: 3, now: Date(timeIntervalSince1970: 20))
        _ = try store.remember(machine: "dev", busID: "1-4", port: 2, now: Date(timeIntervalSince1970: 10))
        _ = try store.remember(machine: "dev", busID: "1-2", port: 1, now: Date(timeIntervalSince1970: 5))

        #expect(store.attachments().map(\.id) == ["dev:1-2", "dev:1-4", "zed:2-1"])
    }

    @Test func rememberReplacesExistingMachineBusIDPair() throws {
        let defaults = try makeDefaults()
        let store = UsbAttachmentStore(defaults: defaults, key: "usb")

        _ = try store.remember(machine: "dev", busID: "1-2", port: 1, now: Date(timeIntervalSince1970: 1))
        _ = try store.remember(machine: "dev", busID: "1-2", port: 4, now: Date(timeIntervalSince1970: 2))

        #expect(store.attachments() == [
            UsbAttachment(machine: "dev", busID: "1-2", port: 4, createdAt: Date(timeIntervalSince1970: 2))
        ])
    }

    @Test func forgetRemovesOneAttachment() throws {
        let defaults = try makeDefaults()
        let store = UsbAttachmentStore(defaults: defaults, key: "usb")

        _ = try store.remember(machine: "dev", busID: "1-2", port: 1)
        _ = try store.remember(machine: "dev", busID: "1-3", port: 1)
        try store.forget(machine: "dev", busID: "1-2")

        #expect(store.attachments().map(\.busID) == ["1-3"])
    }

    @Test func reattachCommandsIncludePortAndMachine() throws {
        let defaults = try makeDefaults()
        let store = UsbAttachmentStore(defaults: defaults, key: "usb")

        _ = try store.remember(machine: "dev", busID: "1-2", port: 9)

        #expect(store.reattachCommands(for: "dev") == [
            ["usb", "attach", "1-2", "--port", "9", "--machine", "dev"]
        ])
        #expect(store.reattachCommands(for: "other").isEmpty)
    }

    @Test func rejectsUnsafeValues() throws {
        let defaults = try makeDefaults()
        let store = UsbAttachmentStore(defaults: defaults, key: "usb")

        #expect(throws: UsbAttachmentStoreError.invalidMachine) {
            try store.remember(machine: "../dev", busID: "1-2", port: 0)
        }
        #expect(throws: UsbAttachmentStoreError.invalidBusID) {
            try store.remember(machine: "dev", busID: "1-2;rm", port: 0)
        }
        #expect(throws: UsbAttachmentStoreError.invalidPort) {
            try store.remember(machine: "dev", busID: "1-2", port: 70_000)
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "dev.dory.tests.usb.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
