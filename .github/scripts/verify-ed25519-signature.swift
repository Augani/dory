#!/usr/bin/env swift

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Ed25519 verification error: \(message)\n".utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else {
    fail("usage: verify-ed25519-signature.swift PUBLIC_KEY_BASE64 SIGNATURE_FILE MESSAGE_FILE")
}

guard let publicKeyData = Data(base64Encoded: arguments[0]), publicKeyData.count == 32 else {
    fail("public key must be one canonical 32-byte base64 value")
}

let signatureURL = URL(fileURLWithPath: arguments[1])
let messageURL = URL(fileURLWithPath: arguments[2])
let signatureText: String
let message: Data
do {
    signatureText = try String(contentsOf: signatureURL, encoding: .utf8)
    message = try Data(contentsOf: messageURL, options: [.mappedIfSafe])
} catch {
    fail("input could not be read")
}

let trimmedSignature = signatureText.trimmingCharacters(in: .whitespacesAndNewlines)
guard !trimmedSignature.isEmpty,
      signatureText == trimmedSignature + "\n",
      let signature = Data(base64Encoded: trimmedSignature),
      signature.count == 64 else {
    fail("signature must be one canonical 64-byte base64 line")
}

do {
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard publicKey.isValidSignature(signature, for: message) else {
        fail("signature does not authenticate the message")
    }
} catch {
    fail("public key is invalid")
}
