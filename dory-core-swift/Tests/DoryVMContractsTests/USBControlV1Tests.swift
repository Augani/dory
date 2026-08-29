import Foundation
import Testing
@testable import DoryVMContracts

@Suite struct DoryUSBControlV1Tests {
    @Test func requestCodecUsesExactVersionOneShapes() throws {
        let busID = try DoryUSBControlV1.BusID("pci_1:USB.4")
        let attach = DoryUSBControlV1.Request.attach(
            busID: busID,
            mode: .userAuthorized
        )
        let detach = DoryUSBControlV1.Request.detach(busID: busID)

        let attachFrame = try DoryUSBControlV1.encodeRequest(attach)
        let detachFrame = try DoryUSBControlV1.encodeRequest(detach)
        #expect(String(decoding: attachFrame, as: UTF8.self)
            == #"{"busid":"pci_1:USB.4","cmd":"attach","mode":"userAuthorized"}"#)
        #expect(String(decoding: detachFrame, as: UTF8.self)
            == #"{"busid":"pci_1:USB.4","cmd":"detach"}"#)
        #expect(try DoryUSBControlV1.decodeRequest(attachFrame) == attach)
        #expect(try DoryUSBControlV1.decodeRequest(detachFrame) == detach)
    }

    @Test func responseCodecPreservesTypedFailureDisposition() throws {
        let attached = DoryUSBControlV1.Response.attachSuccess(try .init(
            port: 7,
            vsockPort: 1_025,
            deviceID: 196_610,
            speed: 3
        ))
        let detached = DoryUSBControlV1.Response.detachSuccess
        let rejected = DoryUSBControlV1.Response.failure(
            disposition: .rejected,
            error: "device is busy"
        )
        let unknown = DoryUSBControlV1.Response.failure(
            disposition: .outcomeUnknown,
            error: "guest reply was lost"
        )

        for response in [attached, detached, rejected, unknown] {
            let frame = try DoryUSBControlV1.encodeResponse(response)
            #expect(frame.count <= DoryUSBControlV1.maximumFrameBytes)
            #expect(try DoryUSBControlV1.decodeResponse(frame) == response)
        }
    }

    @Test func duplicateTopLevelFieldsAreRejectedBeforeFoundationCanCollapseThem() {
        let duplicateLiteral = Data(
            #"{"ok":false,"ok":true,"disposition":"rejected","error":"busy"}"#.utf8
        )
        #expect(throws: DoryUSBControlV1.CodecError.duplicateField("ok")) {
            try DoryUSBControlV1.decodeResponse(duplicateLiteral)
        }

        let duplicateEscapedAlias = Data(
            #"{"ok":false,"\u006f\u006b":true,"disposition":"rejected","error":"busy"}"#.utf8
        )
        #expect(throws: DoryUSBControlV1.CodecError.duplicateField("ok")) {
            try DoryUSBControlV1.decodeResponse(duplicateEscapedAlias)
        }
    }

    @Test func exactFieldSetsRejectUnknownMissingAndNullCompatibilityShapes() {
        for malformed in [
            #"{"ok":true,"future":1}"#,
            #"{"ok":true,"error":null}"#,
            #"{"ok":false,"error":"busy"}"#,
            #"{"ok":false,"disposition":"rejected","error":"busy","port":1}"#,
            #"{"ok":true,"port":1,"vsockPort":1025,"deviceID":3}"#,
        ] {
            #expect(throws: DoryUSBControlV1.CodecError.self) {
                try DoryUSBControlV1.decodeResponse(Data(malformed.utf8))
            }
        }

        for malformed in [
            #"{"cmd":"attach","busid":"3-2"}"#,
            #"{"cmd":"detach","busid":"3-2","mode":null}"#,
            #"{"cmd":"detach","busid":"3-2","future":true}"#,
        ] {
            #expect(throws: DoryUSBControlV1.CodecError.self) {
                try DoryUSBControlV1.decodeRequest(Data(malformed.utf8))
            }
        }
    }

    @Test func busIDGrammarIsCanonicalBoundedASCII() throws {
        for valid in ["3-2", "pci_1:USB.4", String(repeating: "a", count: 31)] {
            #expect(DoryUSBControlV1.BusID.isValid(valid))
            _ = try DoryUSBControlV1.BusID(valid)
        }
        for invalid in [
            "", "3/2", "3 2", "usb\n2", "usb-é", String(repeating: "a", count: 32),
        ] {
            #expect(!DoryUSBControlV1.BusID.isValid(invalid))
            #expect(throws: DoryUSBControlV1.CodecError.invalidBusID) {
                try DoryUSBControlV1.BusID(invalid)
            }
        }
    }

    @Test func failureTextIsNonemptyPrintableASCIIAndBounded() throws {
        let boundary = String(repeating: "x", count: 3_000)
        #expect(DoryUSBControlV1.isValidFailureMessage(boundary))
        _ = try DoryUSBControlV1.encodeResponse(.failure(
            disposition: .rejected,
            error: boundary
        ))

        for invalid in ["", "line\nbreak", "café", String(repeating: "x", count: 3_001)] {
            #expect(!DoryUSBControlV1.isValidFailureMessage(invalid))
            #expect(throws: DoryUSBControlV1.CodecError.invalidFailureMessage) {
                try DoryUSBControlV1.encodeResponse(.failure(
                    disposition: .outcomeUnknown,
                    error: invalid
                ))
            }
        }

        let sanitized = DoryUSBControlV1.sanitizedFailureMessage(
            String(repeating: "x", count: 3_000) + "\né"
        )
        #expect(sanitized.utf8.count == 3_000)
        #expect(sanitized.hasSuffix("..."))
        #expect(DoryUSBControlV1.isValidFailureMessage(sanitized))
    }

    @Test func framesAndAttachmentMetadataAreSemanticallyBounded() {
        let oversized = Data(repeating: 0x20, count: DoryUSBControlV1.maximumFrameBytes + 1)
        #expect(throws: DoryUSBControlV1.CodecError.frameTooLarge(
            actual: oversized.count,
            maximum: DoryUSBControlV1.maximumFrameBytes
        )) {
            try DoryUSBControlV1.decodeResponse(oversized)
        }

        for malformed in [
            #"{"ok":true,"port":-1,"vsockPort":1025,"deviceID":3,"speed":1}"#,
            #"{"ok":true,"port":1,"vsockPort":1026,"deviceID":3,"speed":1}"#,
            #"{"ok":true,"port":1,"vsockPort":1025,"deviceID":0,"speed":1}"#,
            #"{"ok":true,"port":1,"vsockPort":1025,"deviceID":3,"speed":0}"#,
        ] {
            #expect(throws: DoryUSBControlV1.CodecError.self) {
                try DoryUSBControlV1.decodeResponse(Data(malformed.utf8))
            }
        }
    }
}
