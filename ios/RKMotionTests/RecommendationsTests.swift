import XCTest
@testable import RKMotion

final class RecommendationsTests: XCTestCase {
    private func reading(_ kind: ContentKind, motion: Double = 0.3, cheer: Double = 0) -> ContentReading {
        ContentReading(detected: kind, kind: kind, musicShare: 0, speechShare: 0, cheerShare: cheer, people: 2, motion: motion, outdoors: 0.5)
    }
    func testEveryKindHasSongSearches() {
        for kind in ContentKind.allCases {
            let ideas = SongIdeas.ideas(for: reading(kind))
            XCTAssertGreaterThanOrEqual(ideas.count, 3, "\(kind)")
            XCTAssertEqual(Set(ideas.map(\.query)).count, ideas.count, "\(kind) repeats a search")
            XCTAssertTrue(ideas.allSatisfy {!$0.title.isEmpty && !$0.query.isEmpty && !$0.named})
        }
    }
    func testPaceSetsTempoAndOrder() {
        XCTAssertEqual(SongIdeas.tempo(for: reading(.talk, motion: 0.9)), 70...95)
        XCTAssertEqual(SongIdeas.tempo(for: reading(.action, motion: 0.9)), 125...150)
        XCTAssertEqual(SongIdeas.tempo(for: reading(.trip, motion: 0.05)), 80...105)
        XCTAssertEqual(SongIdeas.ideas(for: reading(.action, motion: 0.9)).first?.query, "energetic rock action edit music")
        XCTAssertEqual(SongIdeas.ideas(for: reading(.action, motion: 0.1)).first?.query, "upbeat indie rock road music")
    }
    func testPromptDescribesTheFootage() {
        let talk = SongIdeas.prompt(for: reading(.talk), seconds: 42)
        XCTAssertTrue(talk.contains("no vocals"))
        XCTAssertTrue(talk.contains("42 seconds"))
        XCTAssertTrue(talk.contains("70 to 95 BPM"))
        XCTAssertTrue(SongIdeas.prompt(for: reading(.party, cheer: 0.2), seconds: nil).contains("laugh and cheer"))
    }
    func testParsesTheModelsSongs() {
        let ideas = SongIdeas.parse("""
            Here you go:
            1. Pharrell Williams - Happy
            2) "Avicii – Wake Me Up"
            - 50 Cent - In Da Club
            • Pharrell Williams - Happy
            Queen — Don't Stop Me Now
            Daft Punk - One More Time
            Kool & The Gang - Celebration
            """)
        XCTAssertEqual(ideas.map(\.title), ["Pharrell Williams – Happy", "Avicii – Wake Me Up", "50 Cent – In Da Club",
                                           "Queen – Don't Stop Me Now", "Daft Punk – One More Time"])
        XCTAssertEqual(ideas[2].query, "50 Cent In Da Club")
        XCTAssertTrue(ideas.allSatisfy(\.named))
        XCTAssertTrue(SongIdeas.parse("I can't help with that.").isEmpty)
    }

    // MARK: Smart transitions

    /// Thirty seconds whose motion is set per stretch; everything else quiet.
    private func signals(motion: [ClosedRange<Int>: Double], cheer: [ClosedRange<Int>: Double] = [:]) -> Signals {
        func fill(_ spans: [ClosedRange<Int>: Double], base: Double) -> [Double] {
            (0..<30).map {second in spans.first {$0.key.contains(second)}?.value ?? base}
        }
        return Signals(motion: fill(motion, base: 0.01),
                       loudness: Array(repeating: 0.1, count: 30), cheer: fill(cheer, base: 0))
    }
    private let one = [ProjectPart(file: "a.mov", start: 0, duration: 30)]
    func testCalmSeamsDissolveAndBurstsZoom() {
        let s = signals(motion: [10...14: 0.2, 20...24: 0.2])
        let clips = [Clip(start: 0, end: 4), Clip(start: 5, end: 9), Clip(start: 10, end: 14)]
        XCTAssertEqual(SmartTransitions.styles(for: clips, signals: s, kind: .trip, pieces: one), ["dissolve", "zoom"])
    }
    func testFastSeamsPushButNeverTwiceInARow() {
        let s = signals(motion: [0...29: 0.2])
        let clips = [Clip(start: 0, end: 4), Clip(start: 5, end: 9), Clip(start: 10, end: 14), Clip(start: 15, end: 19)]
        // Fast throughout the clips, still after them.
        let fast = signals(motion: [0...19: 0.2])
        XCTAssertEqual(SmartTransitions.styles(for: clips, signals: fast, kind: .action, pieces: one), ["slide", "dissolve", "slide"])
        XCTAssertFalse(SmartTransitions.styles(for: clips, signals: s, kind: .action, pieces: one).contains("cut"))
    }
    func testCheerFlashesAndJumpsDipToBlack() {
        let s = signals(motion: [:], cheer: [5...6: 0.9, 10...11: 0.9])
        let clips = [Clip(start: 0, end: 4), Clip(start: 5, end: 9), Clip(start: 10, end: 14), Clip(start: 20, end: 24), Clip(start: 2, end: 3)]
        let two = [ProjectPart(file: "a.mov", start: 0, duration: 18), ProjectPart(file: "b.mov", start: 18, duration: 12)]
        XCTAssertEqual(SmartTransitions.styles(for: clips, signals: s, kind: .party, pieces: two), ["flash", "zoom", "fade", "fade"])
    }
    func testTalkStaysSoftAndMissingScanFallsBack() {
        let clips = [Clip(start: 0, end: 4), Clip(start: 5, end: 9), Clip(start: 10, end: 14)]
        let s = signals(motion: [5...9: 0.3], cheer: [5...6: 0.9])
        XCTAssertEqual(SmartTransitions.styles(for: clips, signals: s, kind: .talk, pieces: one), ["dissolve", "dissolve"])
        XCTAssertEqual(SmartTransitions.styles(for: clips, signals: nil, kind: .action, pieces: one), ["slide", "dissolve"])
        XCTAssertEqual(SmartTransitions.styles(for: clips, signals: nil, kind: nil, pieces: one), ["dissolve", "dissolve"])
        XCTAssertEqual(SmartTransitions.styles(for: [clips[0]], signals: nil, kind: nil, pieces: one), [])
    }
}
