import Foundation
import Testing
@testable import DorydKit

@Suite struct DoryMacGuestToolsHealthTests {
  private let machineID = "dory-mac-1"
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test func freshMachineBoundNegotiatedHealthIsAccepted() throws {
    let health = DoryMacGuestToolsHealth(
      machineID: machineID,
      state: .healthy,
      runtimeGeneration: 9,
      toolsVersion: "1.0",
      toolsBuild: "12",
      guestOSVersion: "macOS 27",
      grantedCapabilities: ["clipboard-text-read", "guest-time", "health", "open-url"],
      lastHealthAtUnixMilliseconds: 2_000_000_000_000,
      guestTimeUnixMilliseconds: 2_000_000_000_500
    )
    #expect(health.isFresh(for: machineID, now: now))
    #expect(!health.isFresh(for: "other-mac", now: now))
    #expect(!health.isFresh(for: machineID, now: now.addingTimeInterval(16)))
    let response = VmmControlResponse(ok: true, macGuestTools: health)
    #expect(try JSONDecoder().decode(
      VmmControlResponse.self, from: JSONEncoder().encode(response)
    ) == response)
  }

  @Test func privilegedOverclaimAndIncompleteHealthAreRejected() {
    let overclaimed = DoryMacGuestToolsHealth(
      machineID: machineID, state: .healthy, runtimeGeneration: 9,
      toolsVersion: "1.0", toolsBuild: "12", guestOSVersion: "macOS 27",
      grantedCapabilities: ["graceful-shutdown", "health"],
      lastHealthAtUnixMilliseconds: 2_000_000_000_000
    )
    #expect(!overclaimed.isFresh(for: machineID, now: now))
    let incomplete = DoryMacGuestToolsHealth(
      machineID: machineID, state: .healthy, runtimeGeneration: 9,
      grantedCapabilities: ["health"]
    )
    #expect(!incomplete.isFresh(for: machineID, now: now))
    let ungrantedTime = DoryMacGuestToolsHealth(
      machineID: machineID, state: .healthy, runtimeGeneration: 9,
      toolsVersion: "1.0", toolsBuild: "12", guestOSVersion: "macOS 27",
      grantedCapabilities: ["health"],
      lastHealthAtUnixMilliseconds: 2_000_000_000_000,
      guestTimeUnixMilliseconds: 2_000_000_000_500
    )
    #expect(!ungrantedTime.isFresh(for: machineID, now: now))
    let disconnected = DoryMacGuestToolsHealth(
      machineID: machineID, state: .disconnected, runtimeGeneration: 9,
      lastErrorCode: "timeout"
    )
    #expect(disconnected.isFresh(for: machineID, now: now))
    let missedTeardown = DoryMacGuestToolsHealth(
      machineID: machineID, state: .disconnected, runtimeGeneration: 9,
      lastErrorCode: "teardown-timeout"
    )
    #expect(missedTeardown.isFresh(for: machineID, now: now))
    let malformed = DoryMacGuestToolsHealth(
      machineID: machineID, state: .disconnected, runtimeGeneration: 9,
      lastErrorCode: "guest-controlled detail"
    )
    #expect(!malformed.isFresh(for: machineID, now: now))
  }
}
