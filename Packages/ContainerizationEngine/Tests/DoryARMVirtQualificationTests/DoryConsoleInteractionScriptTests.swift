import Foundation
import Testing

@testable import DoryARMVirtQualification

@Suite struct DoryConsoleInteractionScriptTests {
  @Test func drivesOrderedPromptsWithoutReusingEarlierConsoleBytes() throws {
    let driver = try DoryConsoleInteractionDriver(
      script: DoryConsoleInteractionScript(steps: [
        DoryConsoleInteractionStep(waitFor: "login: ", send: "root\n"),
        DoryConsoleInteractionStep(
          waitFor: "# ",
          send: "reboot\n",
          installerMediaAfterSend: .detached
        ),
        DoryConsoleInteractionStep(waitFor: "login: ", send: "root\n"),
      ]))
    var console = Array("guest login: ".utf8)

    #expect(driver.nextInput(consoleBytes: console) == Array("root\n".utf8))
    #expect(driver.nextInput(consoleBytes: console) == nil)
    console.append(contentsOf: Array("root\r\nguest:~# ".utf8))
    #expect(driver.nextInput(consoleBytes: console) == Array("reboot\n".utf8))
    #expect(driver.installerMediaState == .detached)
    #expect(driver.installerMediaTransitionCount == 1)
    #expect(driver.inputContains("reboot"))
    #expect(!driver.inputContains("DORY_SUCCESS"))
    console.append(contentsOf: Array("rebooting\r\nguest login: ".utf8))
    #expect(driver.nextInput(consoleBytes: console) == Array("root\n".utf8))
    #expect(driver.isComplete)
    #expect(driver.completedStepCount == 3)
  }

  @Test func rejectsUnboundedOrAmbiguousScripts() {
    #expect(throws: DoryConsoleInteractionScriptError.invalidStepCount(0)) {
      try DoryConsoleInteractionDriver(script: DoryConsoleInteractionScript(steps: []))
    }
    #expect(throws: DoryConsoleInteractionScriptError.invalidWaitMarker(step: 0)) {
      try DoryConsoleInteractionDriver(
        script: DoryConsoleInteractionScript(steps: [
          DoryConsoleInteractionStep(waitFor: "", send: "x")
        ]))
    }
    #expect(
      throws: DoryConsoleInteractionScriptError.redundantInstallerMediaTransition(
        step: 0,
        state: .attached
      )
    ) {
      try DoryConsoleInteractionDriver(
        script: DoryConsoleInteractionScript(steps: [
          DoryConsoleInteractionStep(
            waitFor: "a",
            send: "x",
            installerMediaAfterSend: .attached
          )
        ]))
    }
  }

  @Test func omittedMediaTransitionDecodesAsNil() throws {
    let script = try JSONDecoder().decode(
      DoryConsoleInteractionScript.self,
      from: Data(##"{"schemaVersion":1,"steps":[{"waitFor":"# ","send":"id\n"}]}"##.utf8)
    )

    #expect(script.steps == [DoryConsoleInteractionStep(waitFor: "# ", send: "id\n")])
  }

  @Test func retainsCursorAndDetachAuthorityAcrossMultipleGuestResets() throws {
    let driver = try DoryConsoleInteractionDriver(
      script: DoryConsoleInteractionScript(steps: [
        DoryConsoleInteractionStep(waitFor: "live login:", send: "root\n"),
        DoryConsoleInteractionStep(
          waitFor: "install complete",
          send: "reboot\n",
          installerMediaAfterSend: .detached
        ),
        DoryConsoleInteractionStep(waitFor: "disk login:", send: "root\n"),
        DoryConsoleInteractionStep(waitFor: "# ", send: "upgrade && reboot\n"),
        DoryConsoleInteractionStep(waitFor: "updated login:", send: "root\n"),
      ]))
    var console = Array("live login:".utf8)

    #expect(driver.nextInput(consoleBytes: console) == Array("root\n".utf8))
    console.append(contentsOf: Array(" install complete".utf8))
    #expect(driver.nextInput(consoleBytes: console) == Array("reboot\n".utf8))
    #expect(driver.installerMediaState == .detached)
    #expect(driver.installerMediaTransitionCount == 1)
    console.append(contentsOf: Array(" disk login:".utf8))
    #expect(driver.nextInput(consoleBytes: console) == Array("root\n".utf8))
    console.append(contentsOf: Array(" # ".utf8))
    #expect(driver.nextInput(consoleBytes: console) == Array("upgrade && reboot\n".utf8))
    console.append(contentsOf: Array(" updated login:".utf8))
    #expect(driver.nextInput(consoleBytes: console) == Array("root\n".utf8))
    #expect(driver.isComplete)
    #expect(driver.completedStepCount == 5)
  }

  @Test func appliesOrderedDetachAndReattachTransitions() throws {
    let driver = try DoryConsoleInteractionDriver(
      script: DoryConsoleInteractionScript(steps: [
        DoryConsoleInteractionStep(
          waitFor: "installed",
          send: "reboot\n",
          installerMediaAfterSend: .detached
        ),
        DoryConsoleInteractionStep(
          waitFor: "recovery",
          send: "reboot\n",
          installerMediaAfterSend: .attached
        ),
      ]))

    #expect(driver.containsInstallerMediaTransition)
    #expect(driver.nextInput(consoleBytes: Array("installed".utf8)) == Array("reboot\n".utf8))
    #expect(driver.installerMediaState == .detached)
    #expect(driver.installerMediaTransitionCount == 1)
    #expect(
      driver.nextInput(consoleBytes: Array("installed recovery".utf8)) == Array("reboot\n".utf8)
    )
    #expect(driver.installerMediaState == .attached)
    #expect(driver.installerMediaTransitionCount == 2)
  }

  @Test func hostActionsBlockFurtherInputUntilAcknowledged() throws {
    let driver = try DoryConsoleInteractionDriver(
      script: DoryConsoleInteractionScript(steps: [
        DoryConsoleInteractionStep(
          waitFor: "snapshot-now",
          send: "poweroff\n",
          afterGuestStop: .captureColdSnapshot
        ),
        DoryConsoleInteractionStep(
          waitFor: "restore-now",
          send: "poweroff\n",
          afterGuestStop: .restoreColdSnapshot
        ),
      ]))
    let console = Array("snapshot-now restore-now".utf8)

    #expect(driver.hostActionCount == 2)
    #expect(driver.nextInput(consoleBytes: console) == Array("poweroff\n".utf8))
    #expect(driver.pendingHostAction == .captureColdSnapshot)
    #expect(driver.nextInput(consoleBytes: console) == nil)
    try driver.completeHostAction(.captureColdSnapshot)
    #expect(driver.nextInput(consoleBytes: console) == Array("poweroff\n".utf8))
    #expect(driver.pendingHostAction == .restoreColdSnapshot)
    try driver.completeHostAction(.restoreColdSnapshot)
    #expect(driver.completedHostActionCount == 2)
    #expect(driver.isComplete)
  }

  @Test func rejectsRestoreWithoutEarlierCapture() {
    #expect(
      throws: DoryConsoleInteractionScriptError.invalidColdSnapshotActionSequence(
        step: 0,
        action: .restoreColdSnapshot
      )
    ) {
      try DoryConsoleInteractionDriver(
        script: DoryConsoleInteractionScript(steps: [
          DoryConsoleInteractionStep(
            waitFor: "stop",
            send: "poweroff\n",
            afterGuestStop: .restoreColdSnapshot
          )
        ]))
    }
  }
}
