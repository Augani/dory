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
        // This measures how long it takes to launch your application. Terminate between
        // iterations so every launch is cold — a still-running instance records no metric.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = makeApp()
            app.launch()
            app.terminate()
        }
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DORY_UI_TEST"] = "1"
        return app
    }
}
