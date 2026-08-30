import Foundation
import Testing

@testable import DoryARMVirtQualification

@Suite struct DoryConsoleInteractionScriptTests {
  @Test func drivesOrderedPromptsWithoutReusingEarlierConsoleBytes() throws {
    let driver = try DoryConsoleInteractionDriver(
      script: DoryConsoleInteractionScript(steps: [
        DoryConsoleInteractionStep(waitFor: "login: ", send: "root\n"),
        DoryConsoleInteractionStep(waitFor: "# ", send: "reboot\n", detachInstallerAfterSend: true),
        DoryConsoleInteractionStep(waitFor: "login: ", send: "root\n"),
      ]))
    var console = Array("guest login: ".utf8)

    #expect(driver.nextInput(consoleBytes: console) == Array("root\n".utf8))
    #expect(driver.nextInput(consoleBytes: console) == nil)
    console.append(contentsOf: Array("root\r\nguest:~# ".utf8))
    #expect(driver.nextInput(consoleBytes: console) == Array("reboot\n".utf8))
    #expect(driver.shouldDetachInstaller)
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
    #expect(throws: DoryConsoleInteractionScriptError.multipleInstallerDetachSteps) {
      try DoryConsoleInteractionDriver(
        script: DoryConsoleInteractionScript(steps: [
          DoryConsoleInteractionStep(waitFor: "a", send: "x", detachInstallerAfterSend: true),
          DoryConsoleInteractionStep(waitFor: "b", send: "y", detachInstallerAfterSend: true),
        ]))
    }
  }

  @Test func omittedDetachFlagDecodesAsFalse() throws {
    let script = try JSONDecoder().decode(
      DoryConsoleInteractionScript.self,
      from: Data(##"{"schemaVersion":1,"steps":[{"waitFor":"# ","send":"id\n"}]}"##.utf8)
    )

    #expect(script.steps == [DoryConsoleInteractionStep(waitFor: "# ", send: "id\n")])
  }
}
