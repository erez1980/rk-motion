import XCTest

/// Drives the real edit screen on a ride the app makes for itself.
final class PlayerUITests: XCTestCase {
    override func setUp() {continueAfterFailure = false}

    private func launch(language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-RKUITestFixture", "-AppleLanguages", "(\(language))", "-AppleLocale", language == "he" ? "he_IL" : "en_US"]
        app.launch()
        return app
    }
    /// Waits for `element`; on a timeout the failure carries what the app was
    /// showing, since CI keeps only the log.
    private func wait(for element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval, _ message: String) {
        if element.waitForExistence(timeout: timeout) {return}
        XCTFail("\(message). App state \(app.state.rawValue). Screen:\n\(app.debugDescription)")
    }

    /// F01: the same AVPlayerItem was handed to a new AVPlayer on every tap of
    /// "Edit", and on coming back to the step, which AVFoundation answers by
    /// ending the app. Tap it over and over, switch back and forth, leave the
    /// step and return: the app must still be running and showing the editor.
    func testRepeatedTapsOnTheEditPreviewKeepTheAppAlive() throws {
        let app = launch()
        let showEdit = app.buttons["edit.showEdit"], showSource = app.buttons["edit.showSource"]
        wait(for: showEdit, in: app, timeout: 120, "The fixture ride never reached the edit step")
        showEdit.tap()
        // The first tap prepares the preview; then the choice is enabled again.
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: showEdit)
        waitForExpectations(timeout: 90)
        for _ in 0..<6 {showEdit.tap()}
        for _ in 0..<4 {showSource.tap(); showEdit.tap()}
        // Away to the music step and back re-creates the edit screen.
        for _ in 0..<3 {
            app.buttons["step.2"].tap()
            XCTAssertTrue(app.buttons["step.1"].waitForExistence(timeout: 10))
            app.buttons["step.1"].tap()
            XCTAssertTrue(showEdit.waitForExistence(timeout: 10))
            showEdit.tap(); showEdit.tap()
        }
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.otherElements["edit.player"].exists || app.descendants(matching: .any)["edit.player"].exists)
    }

    /// Reported from the simulator: tapping the words of "From YouTube" or
    /// "New ride", not their icons, did nothing.
    func testTilesRespondToATapOnTheirWords() throws {
        let app = launch()
        let music = app.buttons["step.2"]
        wait(for: app.buttons["edit.showEdit"], in: app, timeout: 120, "The fixture ride never reached the edit step")
        music.tap()
        let youTube = app.buttons["music.youtube"]
        XCTAssertTrue(youTube.waitForExistence(timeout: 10))
        // Well past the icon, on the words and the space after them.
        youTube.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
        XCTAssertTrue(app.textFields["music.query"].waitForExistence(timeout: 5), "A tap on the words opens the YouTube search")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let newRide = app.buttons["home.newRide"]
        XCTAssertTrue(newRide.waitForExistence(timeout: 10))
        newRide.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["step.0"].waitForExistence(timeout: 10), "A tap on the words starts a new ride")
    }

    /// F09: in English the screens read left to right; the step bar's first
    /// step sits on the left. In Hebrew it sits on the right.
    func testLayoutFollowsTheLanguage() throws {
        for (language, firstOnLeft) in [("en", true), ("he", false)] {
            let app = launch(language: language)
            let first = app.buttons["step.0"], last = app.buttons["step.3"]
            wait(for: first, in: app, timeout: 120, "No step bar in \(language)")
            XCTAssertEqual(first.frame.midX < last.frame.midX, firstOnLeft, "language \(language)")
            app.terminate()
        }
    }
}
