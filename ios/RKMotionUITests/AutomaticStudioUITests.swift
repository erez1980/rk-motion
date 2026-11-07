import XCTest

final class AutomaticStudioUITests: XCTestCase {
    func testOneTapCreatesAMovieWithoutOpeningMusicOrSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-RKUITestFixture", "-RKSkipAutomaticPhotos", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let button = app.buttons["automatic.make"]
        XCTAssertTrue(button.waitForExistence(timeout: 120), app.debugDescription)
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: button)
        waitForExpectations(timeout: 120)
        button.tap()
        let completed = app.staticTexts["Your movie is ready. Moments, music and editing were chosen on your iPhone."]
        XCTAssertTrue(completed.waitForExistence(timeout: 180), app.debugDescription)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(app.textFields["music.query"].exists)
        XCTAssertTrue(app.buttons["automatic.studio"].exists)
    }
}
