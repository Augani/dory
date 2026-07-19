import Foundation

enum UsbPassthroughAvailability: Sendable {
    static let attachSupported = false
    static let unavailableReason =
        "USB passthrough is not available in the current Dory engine. Host discovery works, but " +
        "attach, detach, and automatic replay remain disabled until the guest USB/IP RPC ships."
}

struct UsbAttachment: Codable, Equatable, Identifiable, Sendable {
    var machine: String
    var busID: String
    var port: Int
    var createdAt: Date

    var id: String { "\(machine):\(busID)" }
}

enum UsbAttachmentStoreError: Error, Equatable {
    case invalidMachine
    case invalidBusID
    case invalidPort
}

struct UsbAttachmentStore: Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "dev.dory.usb.attachments") {
        self.defaults = defaults
        self.key = key
    }

    func attachments() -> [UsbAttachment] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([UsbAttachment].self, from: data) else {
            return []
        }
        return decoded.sorted { lhs, rhs in
            lhs.machine == rhs.machine ? lhs.busID < rhs.busID : lhs.machine < rhs.machine
        }
    }

    func attachments(for machine: String) -> [UsbAttachment] {
        let normalized = machine.trimmingCharacters(in: .whitespacesAndNewlines)
        return attachments().filter { $0.machine == normalized }
    }

    func remember(machine: String, busID: String, port: Int, now: Date = Date()) throws -> UsbAttachment {
        let machine = try Self.normalizedMachine(machine)
        let busID = try Self.normalizedBusID(busID)
        guard (0...65_535).contains(port) else { throw UsbAttachmentStoreError.invalidPort }
        var all = attachments()
        let attachment = UsbAttachment(machine: machine, busID: busID, port: port, createdAt: now)
        all.removeAll { $0.id == attachment.id }
        all.append(attachment)
        try save(all)
        return attachment
    }

    func forget(machine: String, busID: String) throws {
        let machine = try Self.normalizedMachine(machine)
        let busID = try Self.normalizedBusID(busID)
        try save(attachments().filter { !($0.machine == machine && $0.busID == busID) })
    }

    func forgetMachine(_ machine: String) throws {
        let machine = try Self.normalizedMachine(machine)
        try save(attachments().filter { $0.machine != machine })
    }

    func reattachCommands(for machine: String) -> [[String]] {
        attachments(for: machine).map {
            ["usb", "attach", $0.busID, "--port", "\($0.port)", "--machine", $0.machine]
        }
    }

    private func save(_ attachments: [UsbAttachment]) throws {
        let sorted = attachments.sorted { lhs, rhs in
            lhs.machine == rhs.machine ? lhs.busID < rhs.busID : lhs.machine < rhs.machine
        }
        defaults.set(try JSONEncoder().encode(sorted), forKey: key)
    }

    static func normalizedMachine(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 64,
              trimmed.first?.isLetter == true || trimmed.first?.isNumber == true,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }) else {
            throw UsbAttachmentStoreError.invalidMachine
        }
        return trimmed
    }

    static func normalizedBusID(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 128,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" || $0 == ":" || $0 == "/" }) else {
            throw UsbAttachmentStoreError.invalidBusID
        }
        return trimmed
    }
}
