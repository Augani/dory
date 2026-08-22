@testable import DorydKit
import Testing

struct DoryHostUSBDiscoveryTests {
    @Test func propertyProjectionMatchesTheRawHVBusIdentityWithoutSerialData() throws {
        let device = try #require(IOKitDoryHostUSBDiscovery.device(from: [
            "idVendor": 0x05ac,
            "idProduct": 0x12a8,
            "locationID": 0x0300_0000,
            "USB Address": 2,
            "USB Vendor Name": "Example Vendor",
            "USB Product Name": "Example Device",
            "USB Serial Number": "private-serial",
            "bDeviceClass": 3,
            "Device Speed": 4,
        ]))

        #expect(device == DoryHostUSBDevice(
            busID: "3-2",
            vendorID: 0x05ac,
            productID: 0x12a8,
            vendorName: "Example Vendor",
            productName: "Example Device",
            deviceClass: 3,
            speed: 4
        ))
        #expect(!device.xpcDictionary.allValues.contains { ($0 as? String) == "private-serial" })
    }

    @Test func propertyProjectionRejectsAmbiguousOrMalformedIdentity() {
        #expect(IOKitDoryHostUSBDiscovery.device(from: [
            "idVendor": true,
            "idProduct": 1,
            "USB Address": 2,
        ]) == nil)
        #expect(IOKitDoryHostUSBDiscovery.device(from: [
            "idVendor": 1,
            "idProduct": 2,
            "USB Address": 0,
        ]) == nil)
        #expect(IOKitDoryHostUSBDiscovery.device(from: [
            "idVendor": 1,
            "idProduct": 2,
            "USB Address": 3,
            "DoryBusID": "../device",
        ]) == nil)
    }

    @Test func publicProjectionIsSortedBoundedAndRejectsDuplicates() throws {
        let first = DoryHostUSBDevice(busID: "1-2", vendorID: 1, productID: 2)
        let second = DoryHostUSBDevice(busID: "1-1", vendorID: 1, productID: 3)
        #expect(try DoryHostUSBProjection.validated([first, second]).map(\.busID) == ["1-1", "1-2"])
        #expect(throws: DoryHostUSBDiscoveryError.duplicateBusID("1-2")) {
            try DoryHostUSBProjection.validated([first, first])
        }
        #expect(throws: DoryHostUSBDiscoveryError.invalidDeviceProjection) {
            try DoryHostUSBProjection.validated([
                DoryHostUSBDevice(busID: "../device", vendorID: 1, productID: 2),
            ])
        }
    }
}
