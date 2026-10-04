import Darwin
import Foundation
import XCTest

@testable import DoryVZMacCore

final class DoryVZMacMetalProbeCollectorTests: XCTestCase {
  func testChallengeAcceptsIssuerMillisecondTimestamp() throws {
    let challenge = try makeChallenge(issuedAt: "2026-09-22T00:00:00.123Z")
    XCTAssertEqual(challenge.issuedAt, "2026-09-22T00:00:00.123Z")
  }

  func testProductWindowTokenChangesWithRunIdentity() throws {
    let original = try makeChallenge()
    let changedNonce = try DoryVZMacMetalProbeChallenge(
      issuedAt: original.issuedAt,
      candidateID: original.candidateID,
      machineID: original.machineID,
      operationID: original.operationID,
      nonce: "different-nonce",
      guestToolsManifestSHA256: original.guestToolsManifestSHA256,
      guestToolsBundleIdentifier: original.guestToolsBundleIdentifier,
      guestToolsVersion: original.guestToolsVersion,
      guestToolsBuild: original.guestToolsBuild
    )
    XCTAssertEqual(original.productWindowTitleToken, original.productWindowTitleToken)
    XCTAssertNotEqual(original.productWindowTitleToken, changedNonce.productWindowTitleToken)
    XCTAssertTrue(original.productWindowTitleToken.hasPrefix("Dory Metal "))
  }

  func testSessionBindsAndRetainsOneFramedGuestResult() throws {
    var sockets = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let resultURL = directory.appendingPathComponent("metal-result.json")
    let challenge = try makeChallenge()
    let completed = expectation(description: "host retained the guest result")
    let hostDescriptor = sockets[0]

    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.fulfill() }
      do {
        _ = try DoryVZMacMetalProbeSession(ownedDescriptor: hostDescriptor).collect(
          challenge: challenge,
          resultURL: resultURL
        )
      } catch {
        XCTFail("Metal probe collection failed: \(error)")
      }
    }

    let encodedChallenge = try DoryVZMacMetalProbeSession.readFrame(from: sockets[1])
    XCTAssertEqual(
      try JSONDecoder().decode(DoryVZMacMetalProbeChallenge.self, from: encodedChallenge),
      challenge
    )
    let result = try resultData(challenge: challenge)
    try DoryVZMacMetalProbeSession.writeFrame(result, to: sockets[1])
    wait(for: [completed], timeout: 2)
    close(sockets[1])

    XCTAssertEqual(try Data(contentsOf: resultURL), result)
    var resultStatus = stat()
    XCTAssertEqual(lstat(resultURL.path, &resultStatus), 0)
    XCTAssertEqual(resultStatus.st_mode & 0o777, 0o600)
    let receipt = try JSONDecoder().decode(
      DoryVZMacMetalProbeTransportReceipt.self,
      from: Data(contentsOf: resultURL.appendingPathExtension("transport.json"))
    )
    XCTAssertEqual(receipt.collection, "vz-virtio-socket")
    XCTAssertEqual(receipt.schema, DoryVZMacMetalProbeTransport.receiptSchema)
    XCTAssertGreaterThan(receipt.collectedMonotonicNanoseconds, 0)
    XCTAssertNotNil(receipt.collectedAt.range(of: #"\.\d{3}Z$"#, options: .regularExpression))
    XCTAssertEqual(receipt.machineID, challenge.machineID)
    XCTAssertEqual(receipt.operationID, challenge.operationID)
    XCTAssertEqual(receipt.nonce, challenge.nonce)
    XCTAssertEqual(receipt.resultByteCount, result.count)
    XCTAssertEqual(receipt.resultSHA256.count, 64)
  }

  func testSessionRejectsResultFromAnotherMachine() throws {
    var sockets = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
    let resultURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let challenge = try makeChallenge()
    let completed = expectation(description: "host rejected the unbound result")
    let hostDescriptor = sockets[0]

    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.fulfill() }
      do {
        _ = try DoryVZMacMetalProbeSession(ownedDescriptor: hostDescriptor).collect(
          challenge: challenge,
          resultURL: resultURL
        )
        XCTFail("collector accepted a result bound to another machine")
      } catch {
        // Expected: the guest payload is not bound to this selected VM challenge.
      }
    }
    _ = try DoryVZMacMetalProbeSession.readFrame(from: sockets[1])
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: resultData(challenge: challenge)) as? [String: Any]
    )
    object["machineID"] = "another-machine"
    try DoryVZMacMetalProbeSession.writeFrame(
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      to: sockets[1]
    )
    wait(for: [completed], timeout: 2)
    close(sockets[1])
    XCTAssertFalse(FileManager.default.fileExists(atPath: resultURL.path))
  }

  func testSessionReportsDisconnectedGuestWithoutTerminatingHelper() throws {
    var sockets = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
    defer { close(sockets[0]) }
    // Install the production options before disconnecting: setting options after
    // closure can itself fail on Darwin and would not exercise the framed write.
    try DoryVZMacMetalProbeSession.configureTimeouts(sockets[0])
    close(sockets[1])

    XCTAssertThrowsError(
      try DoryVZMacMetalProbeSession.writeFrame(
        Data("challenge".utf8),
        to: sockets[0]
      )
    ) { error in
      XCTAssertEqual((error as? POSIXError)?.code, .EPIPE)
    }
  }

  func testSessionNeverOverwritesExistingEvidence() throws {
    var sockets = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
    let resultURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let existing = Data("existing-evidence".utf8)
    try existing.write(to: resultURL)
    defer { try? FileManager.default.removeItem(at: resultURL) }
    let challenge = try makeChallenge()
    let completed = expectation(description: "host refused to overwrite evidence")
    let hostDescriptor = sockets[0]

    DispatchQueue.global(qos: .userInitiated).async {
      defer { completed.fulfill() }
      do {
        _ = try DoryVZMacMetalProbeSession(ownedDescriptor: hostDescriptor).collect(
          challenge: challenge,
          resultURL: resultURL
        )
        XCTFail("collector replaced an existing evidence file")
      } catch {
        // Expected: evidence destinations are append-only for a qualification nonce.
      }
    }
    _ = try DoryVZMacMetalProbeSession.readFrame(from: sockets[1])
    try DoryVZMacMetalProbeSession.writeFrame(
      resultData(challenge: challenge),
      to: sockets[1]
    )
    wait(for: [completed], timeout: 2)
    close(sockets[1])
    XCTAssertEqual(try Data(contentsOf: resultURL), existing)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: resultURL.appendingPathExtension("transport.json").path
      ))
  }

  func testChallengeRejectsInvalidDigestAndBundleIdentity() throws {
    XCTAssertThrowsError(
      try DoryVZMacMetalProbeChallenge(
        issuedAt: "2026-09-22T00:00:00Z",
        candidateID: "candidate-1",
        machineID: "machine-1",
        operationID: "operation-1",
        nonce: "nonce-1",
        guestToolsManifestSHA256: "not-a-digest",
        guestToolsBundleIdentifier: "com.example.Untrusted",
        guestToolsVersion: "1.0",
        guestToolsBuild: "1"
      ))
  }

  private func makeChallenge(
    issuedAt: String = "2026-09-22T00:00:00Z"
  ) throws -> DoryVZMacMetalProbeChallenge {
    try DoryVZMacMetalProbeChallenge(
      issuedAt: issuedAt,
      candidateID: "candidate-1",
      machineID: String(repeating: "a", count: 64),
      operationID: "operation-1",
      nonce: "nonce-1",
      guestToolsManifestSHA256: String(repeating: "b", count: 64),
      guestToolsBundleIdentifier: "com.pythonxi.Dory.GuestTools",
      guestToolsVersion: "1.0",
      guestToolsBuild: "1"
    )
  }

  private func resultData(challenge: DoryVZMacMetalProbeChallenge) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "schema": DoryVZMacMetalProbeTransport.resultSchema,
        "candidateID": challenge.candidateID,
        "machineID": challenge.machineID,
        "operationID": challenge.operationID,
        "nonce": challenge.nonce,
        "guestToolsBundleIdentifier": challenge.guestToolsBundleIdentifier,
        "guestToolsVersion": challenge.guestToolsVersion,
        "guestToolsBuild": challenge.guestToolsBuild,
        "computeCommandBufferStatus": "completed",
        "renderCommandBufferStatus": "completed",
        "computeValueCount": 1_024,
        "renderedWidth": 64,
        "renderedHeight": 64,
        "visualChallenge": [
          "kind": "dev.dory.visual-challenge",
          "version": 1,
          "encoding": "fnv1a64-frame16-grid12x10",
          "frameMarker": 1,
          "payloadHash": DoryVZMacMetalProbeTransport.visualChallengePayloadHash(
            nonce: challenge.nonce,
            frameMarker: 1
          ),
        ],
      ], options: [.sortedKeys])
  }
}
