import XCTest

/// Drives the real app in its honest disconnected state: automation launches never boot the
/// engine and the app ships no demo data, so these tests assert navigation chrome, empty states,
/// sheets, and the onboarding overlay rather than fixture containers.
final class DoryScreensUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["DORY_UI_TEST"] = "1"
        if app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
        }
        app.launch()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
        }
        app = nil
    }

    private func nav(_ id: String) {
        let button = app.buttons["nav-\(id)"]
        XCTAssertTrue(button.waitForExistence(timeout: 8), "nav-\(id) should exist")
        button.click()
    }

    private func assertText(_ text: String, timeout: TimeInterval = 4) {
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: timeout), "expected text '\(text)'")
    }

    func testNavigatesEverySection() {
        nav("containers"); assertText("Containers"); assertText("Engine not running")
        nav("images"); assertText("Images")
        nav("volumes"); assertText("Volumes")
        nav("networks"); assertText("Networks")
        nav("kubernetes"); assertText("Kubernetes")
        nav("machines"); assertText("Linux Machines")
        nav("settings"); assertText("STARTUP")
    }

    func testSettingsSubTabs() {
        nav("settings")
        app.buttons["settings-resources"].click()
        assertText("THIS MAC")
        XCTAssertTrue(app.buttons["use-existing-data-drive"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["restore-verify-data-drive"].exists)
        app.buttons["settings-engine"].click()
        assertText("ENGINE RESOURCES")
        XCTAssertTrue(app.buttons["engine-resources-apply"].exists)
        app.buttons["settings-about"].click()
        app.buttons["settings-network"].click()
        app.buttons["settings-general"].click(); assertText("APPEARANCE")
    }

    func testThemeToggleAndAppearancePicker() {
        nav("settings")
        // Appearance picker selects light/dark without crashing.
        app.buttons["appearance-light"].click()
        app.buttons["appearance-dark"].click()
        // The sidebar theme toggle flips appearance.
        let toggle = app.buttons["theme-toggle"]
        XCTAssertTrue(toggle.exists)
        toggle.click()
        toggle.click()
        assertText("STARTUP")
    }

    func testOnboardingOverlay() {
        app.buttons["brand"].click()
        XCTAssertTrue(app.buttons["onboarding-start"].waitForExistence(timeout: 4), "onboarding overlay should appear")
        app.buttons["onboarding-skip"].click()
        // After dismissing, the main UI is back in its disconnected state.
        nav("containers"); assertText("Engine not running")
    }

    func testNewContainerSheetOpensAndCancels() {
        nav("containers")
        app.buttons["primary-action"].click()
        assertText("New Container")
        XCTAssertTrue(app.buttons["sheet-submit"].waitForExistence(timeout: 2), "submit button should be visible")
        // Cancel without creating.
        app.buttons["Cancel"].firstMatch.click()
        nav("images")
        app.buttons["primary-action"].click()
        assertText("Pull Image")
        app.buttons["Cancel"].firstMatch.click()
    }

    func testNewMachineResourceControlsReachTheirBoundsWithoutCrashing() {
        nav("machines")
        let create = app.buttons["create-first-machine"]
        XCTAssertTrue(create.waitForExistence(timeout: 4))
        create.click()
        XCTAssertTrue(app.buttons["customize-machine"].waitForExistence(timeout: 4))
        app.buttons["customize-machine"].click()
        let advanced = app.buttons["new-machine-advanced-toggle"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 4))
        advanced.click()
        XCTAssertEqual(advanced.value as? String, "Expanded")

        let cpuIncrement = app.buttons["new-machine-cpus-increment"]
        let cpuDecrement = app.buttons["new-machine-cpus-decrement"]
        let memoryIncrement = app.buttons["new-machine-memory-increment"]
        let memoryDecrement = app.buttons["new-machine-memory-decrement"]
        XCTAssertTrue(cpuIncrement.waitForExistence(timeout: 4))
        XCTAssertTrue(memoryIncrement.waitForExistence(timeout: 4))
        XCTAssertTrue(cpuIncrement.isHittable)
        XCTAssertTrue(memoryIncrement.isHittable)
        for _ in 0..<6 { cpuIncrement.click() }
        for _ in 0..<14 { memoryIncrement.click() }
        XCTAssertFalse(cpuIncrement.isEnabled)
        XCTAssertFalse(memoryIncrement.isEnabled)
        XCTAssertTrue(app.staticTexts["8 cores"].exists)
        XCTAssertTrue(app.staticTexts["16 GB"].exists)
        for _ in 0..<7 { cpuDecrement.click() }
        for _ in 0..<15 { memoryDecrement.click() }
        XCTAssertFalse(cpuDecrement.isEnabled)
        XCTAssertFalse(memoryDecrement.isEnabled)
        XCTAssertTrue(app.staticTexts["1 core"].exists)
        XCTAssertTrue(app.staticTexts["1 GB"].exists)
        app.buttons["Cancel"].firstMatch.click()
        assertText("Linux Machines")
    }
}
