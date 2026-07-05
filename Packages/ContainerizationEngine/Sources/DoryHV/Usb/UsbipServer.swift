import Darwin
import Foundation

public protocol UsbipExportedDevice: Sendable {
    var descriptor: UsbipDeviceDescriptor { get }
    func submit(_ command: UsbipSubmitCommand) throws -> UsbipSubmitReply
    func unlink(_ command: UsbipUnlinkCommand) throws -> UsbipUnlinkReply
}

public enum UsbipServerError: Error, Equatable {
    case unknownDevice(String)
    case unsupportedIsochronous
}

public final class UsbipServer: @unchecked Sendable {
    private let devicesByBusID: [String: any UsbipExportedDevice]

    public init(devices: [any UsbipExportedDevice]) {
        self.devicesByBusID = Dictionary(uniqueKeysWithValues: devices.map { ($0.descriptor.busID, $0) })
    }

    public func handleImport(_ bytes: [UInt8]) throws -> [UInt8] {
        let request = try UsbipImportRequest(decoding: bytes)
        guard let device = devicesByBusID[request.busID] else {
            return UsbipImportReply(status: 1, device: nil).encoded()
        }
        return UsbipImportReply(status: 0, device: device.descriptor).encoded()
    }

    public func handleURB(_ bytes: [UInt8], busID: String) throws -> [UInt8] {
        guard let device = devicesByBusID[busID] else {
            throw UsbipServerError.unknownDevice(busID)
        }
        let basic = try UsbipHeaderBasic(decoding: bytes)
        switch basic.command {
        case .cmdSubmit:
            let command = try UsbipSubmitCommand(decoding: bytes)
            guard command.numberOfPackets == 0 || command.numberOfPackets == 0xffff_ffff else {
                let replyHeader = UsbipHeaderBasic(command: .retSubmit, sequenceNumber: command.header.sequenceNumber, deviceID: 0, direction: .out, endpoint: 0)
                return UsbipSubmitReply(header: replyHeader, status: -EPIPE, actualLength: 0, numberOfPackets: command.numberOfPackets).encoded()
            }
            return try device.submit(command).encoded()
        case .cmdUnlink:
            return try device.unlink(try UsbipUnlinkCommand(decoding: bytes)).encoded()
        case .retSubmit, .retUnlink:
            throw UsbipProtocolError.shortFrame
        }
    }
}
