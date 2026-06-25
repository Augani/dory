//
//  DoryUITests.swift
//  DoryUITests
//
//  Created by Augustus Otu on 18/06/2026.
//

import XCTest

final class DoryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testExample() throws {
        let app = makeApp()
        if app.state != .notRunning {
            app.terminate()
        }
        Thread.sleep(forTimeInterval: 0.5)
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8), "app window should launch")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            makeApp().launch()
        }
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.pythonxi.Dory")
        app.launchEnvironment["DORY_RUNTIME"] = "mock"
        return app
    }
}
