import XCTest

final class DoryScreensUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.pythonxi.Dory")
        app.launchEnvironment["DORY_RUNTIME"] = "mock"
        if app.state != .notRunning {
            app.terminate()
        }
        Thread.sleep(forTimeInterval: 0.5)
        app.launch()
    }

    private func nav(_ id: String) {
        let button = app.buttons["nav-\(id)"]
        XCTAssertTrue(button.waitForExistence(timeout: 8), "nav-\(id) should exist")
        button.click()
    }

    private func assertText(_ text: String, timeout: TimeInterval = 4) {
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: timeout), "expected text '\(text)'")
    }

    private func selectKubeResource(_ id: String) {
        let button = app.buttons["kube-resource-\(id)"]
        XCTAssertTrue(button.waitForExistence(timeout: 4), "kube resource \(id) should exist")
        button.click()
    }

    func testNavigatesEverySection() {
        nav("containers"); assertText("postgres-db")
        nav("images"); assertText("postgres")
        nav("volumes"); assertText("USED BY")
        nav("networks"); assertText("SUBNET"); assertText("dory-default")
        nav("kubernetes"); assertText("POD")
        nav("machines"); assertText("ADDRESS"); assertText("ubuntu")
        nav("settings"); assertText("STARTUP")
    }

    func testContainerDetailTabs() {
        nav("containers")
        assertText("DETAILS") // Overview is default for the selected container
        app.buttons["tab-stats"].click(); assertText("CPU usage · last 60s")
        app.buttons["tab-logs"].click()
        app.buttons["tab-env"].click(); assertText("NODE_ENV")
        app.buttons["tab-terminal"].click()
        app.buttons["tab-overview"].click(); assertText("Restart policy")
    }

    func testKubernetesResourceSwitcherShowsWorkloadInventory() {
        nav("kubernetes")
        assertText("web-7d9f8b6c4-xk2lp")

        selectKubeResource("configMaps")
        assertText("web-config")
        assertText("KEYS")

        selectKubeResource("secrets")
        assertText("web-secrets")
        assertText("Opaque")

        selectKubeResource("ingresses")
        assertText("web.dory.local")
        assertText("PATHS")
    }

    func testSettingsSubTabs() {
        nav("settings")
        app.buttons["settings-resources"].click(); assertText("THIS MAC")
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
        // After dismissing, the main UI is back.
        nav("containers"); assertText("postgres-db")
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
}
