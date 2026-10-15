import XCTest
import SwiftUI
@testable import RKMotion

/// F09: every screen was forced right to left, so English read backwards.
final class LanguageDirectionTests: XCTestCase {
    func testDirectionFollowsTheLanguage() {
        XCTAssertEqual(AppLanguage.direction(for: "he"), .rightToLeft)
        XCTAssertEqual(AppLanguage.direction(for: "he-IL"), .rightToLeft)
        XCTAssertEqual(AppLanguage.direction(for: "en"), .leftToRight)
        XCTAssertEqual(AppLanguage.direction(for: "en-GB"), .leftToRight)
        XCTAssertEqual(AppLanguage.direction(for: nil), .leftToRight)
    }
    func testTheAppUsesTheDirectionOfTheLanguageItRunsIn() {
        let language = Bundle.main.preferredLocalizations.first
        XCTAssertEqual(AppLanguage.direction, AppLanguage.direction(for: language))
    }
    func testNoScreenIsForcedRightToLeft() throws {
        // The app's sources sit next to this test file in the repository.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("RKMotion")
        guard let files = try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil), !files.isEmpty else {
            throw XCTSkip("Sources are not reachable from this test run")
        }
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("layoutDirection, .rightToLeft"), file.lastPathComponent)
        }
    }
}
