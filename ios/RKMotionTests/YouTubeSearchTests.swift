import XCTest
@testable import RKMotion

/// YouTube cannot be reached from CI, so these feed the parser the shapes its
/// search answers take and check what a rider would be offered.
final class YouTubeSearchTests: XCTestCase {
    private func video(_ id: String, title: Any, length: String?, owner: String = "Artist") -> [String: Any] {
        var entry: [String: Any] = ["videoId": id, "title": title, "ownerText": ["runs": [["text": owner]]],
                                    "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/\(id)/default.jpg"], ["url": "//i.ytimg.com/vi/\(id)/hq.jpg"]]]]
        if let length {entry["lengthText"] = ["simpleText": length]}
        return ["videoRenderer": entry]
    }

    func testFindsVideosWhereverTheLayoutPutsThem() {
        let shelf: [String: Any] = ["shelfRenderer": ["content": ["verticalListRenderer": ["items": [video("bbbbbbbbbbb", title: ["simpleText": "Wake Me Up"], length: "1:02:03")]]]]]
        let items: [[String: Any]] = [video("aaaaaaaaaaa", title: ["runs": [["text": "Levels "], ["text": "(Radio Edit)"]]], length: "3:20"), shelf]
        let section: [String: Any] = ["itemSectionRenderer": ["contents": items]]
        let json: [String: Any] = ["contents": ["twoColumnSearchResultsRenderer": ["primaryContents": ["sectionListRenderer": ["contents": [section]]]]]]
        let found = YouTubeSearch.results(in: json)
        XCTAssertEqual(found.map(\.id), ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        XCTAssertEqual(found.first?.title, "Levels (Radio Edit)")
        XCTAssertEqual(found.first?.channel, "Artist")
        XCTAssertEqual(found.first?.duration, 200)
        XCTAssertEqual(found.last?.duration, 3723)
        // Protocol-relative thumbnails need a scheme before they load.
        XCTAssertEqual(found.first?.thumbnail?.absoluteString, "https://i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg")
        XCTAssertEqual(found.first?.link.absoluteString, "https://www.youtube.com/watch?v=aaaaaaaaaaa")
    }

    func testSkipsLiveStreamsDuplicatesAndBadIDs() {
        let json: [Any] = [
            video("ccccccccccc", title: ["simpleText": "Live now"], length: nil),
            video("ddddddddddd", title: ["simpleText": "Song"], length: "4:00"),
            video("ddddddddddd", title: ["simpleText": "Song again"], length: "4:00"),
            video("not/an/id!!", title: ["simpleText": "Odd"], length: "2:00"),
            video("short", title: ["simpleText": "Short id"], length: "2:00"),
        ]
        XCTAssertEqual(YouTubeSearch.results(in: json).map(\.id), ["ddddddddddd"])
    }

    func testStopsAtTheLimit() {
        let json = (0..<20).map {video(String(format: "v%010d", $0), title: ["simpleText": "\($0)"], length: "3:00")}
        XCTAssertEqual(YouTubeSearch.results(in: json, limit: 5).count, 5)
    }

    func testReadsLengths() {
        XCTAssertEqual(YouTubeSearch.seconds("0:45"), 45)
        XCTAssertEqual(YouTubeSearch.seconds("12:05"), 725)
        XCTAssertEqual(YouTubeSearch.seconds("1:00:00"), 3600)
        XCTAssertNil(YouTubeSearch.seconds("LIVE"))
        XCTAssertNil(YouTubeSearch.seconds("45"))
    }

    func testFindsTheDataInTheResultsPage() {
        let html = "<html><script>var ytInitialData = {\"a\":[1,2]};</script><script>other();</script></html>"
        XCTAssertEqual(YouTubeSearch.initialData(in: html), "{\"a\":[1,2]}")
        XCTAssertNil(YouTubeSearch.initialData(in: "<html>nothing here</html>"))
    }

    func testEachSongKeepsItsOwnStart() {
        var edit = Edit(clips: [])
        edit.settings["musicStart"] = .text("12")
        // An older project's single start still applies to its first song only.
        XCTAssertEqual(edit.musicStart(for: "one", first: true), 12)
        XCTAssertEqual(edit.musicStart(for: "two", first: false), 0)
        edit.setMusicStart(73.456, for: "two")
        XCTAssertEqual(edit.musicStart(for: "two", first: false), 73.46, accuracy: 0.001)
        edit.setMusicStart(-5, for: "one")
        XCTAssertEqual(edit.musicStart(for: "one", first: true), 0)
    }
}
