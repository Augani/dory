import Darwin
import Foundation

public struct UsbipRequestContext: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }

}

public protocol UsbipExportedDevice: Sendable {
    var descriptor: UsbipDeviceDescriptor { get }
    func submit(_ command: UsbipSubmitCommand, context: UsbipRequestContext) throws -> UsbipSubmitReply
    func unlink(_ command: UsbipUnlinkCommand, context: UsbipRequestContext) throws -> UsbipUnlinkReply
    func closeSession(_ context: UsbipRequestContext)
    func shutdown()
}

public enum UsbipServerError: Error, Equatable {
    case unknownDevice(String)
    case invalidDeviceDescriptor(String)
}

public final class UsbipServer: @unchecked Sendable {
    private let devicesByBusID: [String: any UsbipExportedDevice]

    public init(devices: [any UsbipExportedDevice]) {
        var mapped: [String: any UsbipExportedDevice] = [:]
        for device in devices where mapped[device.descriptor.busID] == nil {
            mapped[device.descriptor.busID] = device
        }
        self.devicesByBusID = mapped
    }

    public func handleImport(_ bytes: [UInt8]) throws -> [UInt8] {
        let request = try UsbipImportRequest(decoding: bytes)
        guard let device = devicesByBusID[request.busID] else {
            return UsbipImportReply(status: 1, device: nil).encoded()
        }
        return UsbipImportReply(status: 0, device: device.descriptor).encoded()
    }

    public func handleURB(_ bytes: [UInt8], busID: String, context: UsbipRequestContext) throws -> [UInt8] {
        guard let device = devicesByBusID[busID] else {
            throw UsbipServerError.unknownDevice(busID)
        }
        let basic = try UsbipHeaderBasic(decoding: bytes)
        try validateDeviceID(basic.deviceID, for: device.descriptor)
        switch basic.command {
        case .cmdSubmit:
            let metadata = try UsbipSubmitCommand.inspectHeader(bytes)
            if metadata.isIsochronous {
                let replyHeader = UsbipHeaderBasic(
                    command: .retSubmit,
                    sequenceNumber: metadata.header.sequenceNumber,
                    deviceID: 0,
                    direction: .out,
                    endpoint: 0
                )
                return UsbipSubmitReply(
                    header: replyHeader,
                    status: -EPIPE,
                    actualLength: 0,
                    numberOfPackets: metadata.numberOfPackets
                ).encoded()
            }
            let command = try UsbipSubmitCommand(decoding: bytes)
            return try device.submit(command, context: context).encoded()
        case .cmdUnlink:
            return try device.unlink(try UsbipUnlinkCommand(decoding: bytes), context: context).encoded()
        case .retSubmit, .retUnlink:
            throw UsbipProtocolError.unexpectedOperation(expected: .cmdSubmit, actual: basic.command)
        }
    }

    public func closeSession(_ context: UsbipRequestContext, busID: String?) {
        guard let busID, let device = devicesByBusID[busID] else { return }
        device.closeSession(context)
    }

    private func validateDeviceID(_ actual: UInt32, for descriptor: UsbipDeviceDescriptor) throws {
        guard descriptor.busNumber <= UInt32(UInt16.max),
              descriptor.deviceNumber > 0,
              descriptor.deviceNumber <= UInt32(UInt16.max) else {
            throw UsbipServerError.invalidDeviceDescriptor(descriptor.busID)
        }
        let expected = (descriptor.busNumber << 16) | descriptor.deviceNumber
        guard actual == expected else {
            throw UsbipProtocolError.unexpectedDeviceID(expected: expected, actual: actual)
        }
    }
}
