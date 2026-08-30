import Testing
@testable import DoryVMContracts

@Suite struct DoryUSBPhysicalIdentityTests {
    @Test func exactPhysicalTupleProducesStableOpaqueToken() throws {
        let identity = try DoryUSBPhysicalIdentity(
            locationID: 0x0114_0000,
            vendorID: 0x1d6c,
            productID: 0x0103,
            bcdDevice: 0x0010,
            serialNumber: "V011R007C001B004"
        )

        #expect(identity.token.rawValue
            == "77d9ff2a53033fcfcbbee7c6ec98e94aa575c8165cd5144d1359413c049f32f1")
        #expect(DoryUSBPhysicalIdentityToken(rawValue: identity.token.rawValue) == identity.token)
    }

    @Test func everyIdentityFieldChangesTheToken() throws {
        let base = try token()
        let variants = try [
            token(locationID: 0x0115_0000),
            token(vendorID: 0x1235),
            token(productID: 0xabce),
            token(bcdDevice: 0x0101),
            token(serialNumber: "different"),
        ]

        #expect(Set(variants).count == variants.count)
        #expect(!variants.contains(base))
    }

    @Test func identityInputsAndWireTokenAreStrictlyBounded() {
        #expect(throws: DoryUSBPhysicalIdentityError.invalidLocationID) {
            _ = try DoryUSBPhysicalIdentity(
                locationID: 0,
                vendorID: 1,
                productID: 2,
                bcdDevice: 3,
                serialNumber: ""
            )
        }
        #expect(throws: DoryUSBPhysicalIdentityError.invalidSerialNumber) {
            _ = try token(serialNumber: String(repeating: "x", count: 513))
        }
        #expect(DoryUSBPhysicalIdentityToken(rawValue: String(repeating: "a", count: 64)) != nil)
        for malformed in [
            "", String(repeating: "A", count: 64), String(repeating: "g", count: 64),
            String(repeating: "0", count: 63), String(repeating: "0", count: 65),
        ] {
            #expect(DoryUSBPhysicalIdentityToken(rawValue: malformed) == nil)
        }
    }

    private func token(
        locationID: UInt32 = 0x0114_0000,
        vendorID: UInt16 = 0x1234,
        productID: UInt16 = 0xabcd,
        bcdDevice: UInt16 = 0x0100,
        serialNumber: String = "serial"
    ) throws -> DoryUSBPhysicalIdentityToken {
        try DoryUSBPhysicalIdentity(
            locationID: locationID,
            vendorID: vendorID,
            productID: productID,
            bcdDevice: bcdDevice,
            serialNumber: serialNumber
        ).token
    }
}
