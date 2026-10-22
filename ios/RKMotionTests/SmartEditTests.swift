import XCTest
import CoreLocation
@testable import RKMotion

final class ChatEditTests: XCTestCase {
    func testHebrewRequestsBecomeCommands() {
        XCTAssertEqual(ChatEdit.commands(from: "תקצר לחצי דקה"), [.length("30")])
        XCTAssertEqual(ChatEdit.commands(from: "בלי הילוך איטי"), [.slowMode("off")])
        XCTAssertEqual(ChatEdit.commands(from: "תוריד את ההילוך האיטי"), [.slowMode("off")])
        XCTAssertEqual(ChatEdit.commands(from: "יותר הילוך איטי"), [.slowMode("each")])
        XCTAssertEqual(ChatEdit.commands(from: "קטעים של 3 שניות"), [.maxClip("3")])
        XCTAssertEqual(ChatEdit.commands(from: "שלושים שניות"), [.length("30")])
        XCTAssertEqual(ChatEdit.commands(from: "תמצא את הים"), [.search("הים")])
        XCTAssertEqual(ChatEdit.commands(from: "זה טיול"), [.kind(.trip)])
        XCTAssertEqual(ChatEdit.commands(from: "מעברים רכים"), [.transition("dissolve")])
        XCTAssertEqual(ChatEdit.commands(from: "בלי מוזיקה"), [.flag("useMusic", false)])
        XCTAssertEqual(ChatEdit.commands(from: "תשתיק את הקול המקורי"), [.flag("muteOriginal", true)])
        XCTAssertEqual(ChatEdit.commands(from: "יותר ארוך"), [.longer])
        XCTAssertEqual(ChatEdit.commands(from: "סתם משפט בלי כלום"), [])
    }
    func testANegationStaysInItsOwnPartOfTheRequest() {
        // "No whoosh, and with beat zoom": the "no" does not reach the zoom.
        XCTAssertEqual(ChatEdit.commands(from: "בלי ווש ועם זום על הביט"), [.flag("beatZoom", true), .flag("whoosh", false)])
    }
    func testModelAnswersAreReadAsCommands() {
        XCTAssertEqual(ChatEdit.commands(fromModel: "length 30\nslow off\n- whoosh: on\nsearch red car\nnonsense"),
                       [.length("30"), .slowMode("off"), .flag("whoosh", true), .search("red car")])
        XCTAssertNil(ChatEdit.command("length 2"))
        XCTAssertEqual(ChatEdit.command("transition smart"), .transition(SmartTransitions.name))
        XCTAssertEqual(ChatEdit.command("kind pets"), .kind(.pets))
    }
    func testCommandsChangeTheSettings() {
        var settings: [String: Setting] = ["targetLength": .text("45")]
        XCTAssertEqual(ChatEdit.apply([.shorter], to: &settings, currentLength: nil), .length)
        XCTAssertEqual(settings["targetLength"]?.string, "30")
        _ = ChatEdit.apply([.longer, .longer], to: &settings, currentLength: nil)
        XCTAssertEqual(settings["targetLength"]?.string, "60")
        _ = ChatEdit.apply([.slower], to: &settings, currentLength: nil)
        XCTAssertEqual(settings["slowRate"]?.string, "3")
        XCTAssertEqual(SlowMotion.mode(settings), "peak")
        _ = ChatEdit.apply([.faster], to: &settings, currentLength: nil)
        XCTAssertEqual(settings["speed"]?.string, "1.25")
        XCTAssertEqual(ChatEdit.apply([.maxClip("3")], to: &settings, currentLength: nil), .suggestions)
        XCTAssertEqual(ChatEdit.apply([.flag("whoosh", true)], to: &settings, currentLength: nil), .nothing)
        XCTAssertEqual(settings["whoosh"]?.bool, true)
    }
}

final class SightingTests: XCTestCase {
    private func sighting(_ time: Double, _ labels: [String: Double], faces: [[Float]] = []) -> Sighting {
        Sighting(time: time, labels: labels, faces: faces.isEmpty ? nil : faces.map {
            Sighting.Face(x: 0.4, y: 0.4, width: 0.2, height: 0.2, print: Sighting.packed($0))
        })
    }
    func testSearchWordsMeanVisionLabels() {
        XCTAssertTrue(FrameSearch.terms(for: "תמצא את הכלב").contains("dog"))
        XCTAssertTrue(FrameSearch.terms(for: "הים").contains("beach"))
        XCTAssertTrue(FrameSearch.terms(for: "ובים").contains("sea"))
        XCTAssertEqual(FrameSearch.terms(for: "dogs"), ["dog"])
        XCTAssertTrue(FrameSearch.terms(for: "גן שעשועים").contains("playground"))
    }
    func testFoundMomentsJoinAndStayInsideOneVideo() {
        let frames = [sighting(1, ["dog": 0.8]), sighting(2.5, ["dog": 0.5]), sighting(10, ["beach": 0.9]), sighting(20, ["dog_breed": 0.9])]
        let found = FrameSearch.moments(frames, terms: ["dog"], parts: [ProjectPart(file: "a", start: 0, duration: 30)])
        XCTAssertEqual(found.map(\.start), [0, 18])
        XCTAssertEqual(found.map(\.end), [4.5, 22])
        XCTAssertEqual(found.map(\.score), [0.8, 0.9])
        XCTAssertTrue(found.allSatisfy {$0.manual == true})
        let parts = [ProjectPart(file: "a", start: 0, duration: 3), ProjectPart(file: "b", start: 3, duration: 7)]
        let split = FrameSearch.moments([sighting(2.9, ["dog": 0.6]), sighting(3.2, ["dog": 0.6])], terms: ["dog"], parts: parts)
        XCTAssertEqual(split.map(\.start), [0, 3])
        XCTAssertEqual(split.map(\.end), [3, 7])
        XCTAssertEqual(FrameSearch.vocabulary(frames).first, "dog")
        XCTAssertEqual(ModelSearch.parse("Dog breed, beach", vocabulary: ["dog_breed", "beach", "car"]), ["dog", "breed", "beach"])
    }
    func testFacesGroupIntoPeopleAndFollowTheStar() {
        let a: [Float] = [1, 0, 0, 0], near: [Float] = [0.95, 0.1, 0, 0], b: [Float] = [0, 1, 0, 0], c: [Float] = [0, 0, 0, 1]
        let frames = [sighting(0.5, [:], faces: [a, b]), sighting(3.5, [:], faces: [b]), sighting(6.5, [:], faces: [near, c])]
        let people = FaceGroups.groups(frames)
        // c is seen once, so it is not offered.
        XCTAssertEqual(people.map(\.key), ["0:0", "0:1"])
        XCTAssertEqual(people[0].members.map(\.sighting), [0, 2])
        let star = FaceGroups.presence(people[0], sightings: frames, count: 8)
        XCTAssertEqual(star, [true, true, false, false, false, true, true, true])
        XCTAssertEqual(FaceGroups.group("0:1", in: frames)?.members.map(\.sighting), [0, 1])
        // The star's seconds rise above every other; the rest sink.
        let signals = Signals(motion: [0.02, 0.05, 0.08, 0.03, 0.06, 0.04, 0.05, 0.02], loudness: [0.1, 0.3, 0.4, 0.2, 0.3, 0.2, 0.1, 0.2])
        let plain = signals.scores(for: .general), followed = signals.scores(for: .general, star: star)
        for index in plain.indices {
            if star[index] {XCTAssertGreaterThanOrEqual(followed[index], Signals.starFloor)}
            else {XCTAssertEqual(followed[index], plain[index] * 0.5, accuracy: 1e-9)}
        }
    }
    func testJoinedVideosKeepTheirFramesInPlace() {
        var first = Signals(motion: [0, 0], loudness: [0, 0]); first.sightings = [sighting(1, ["dog": 0.5])]
        var second = Signals(motion: [0, 0, 0], loudness: [0, 0, 0]); second.sightings = [sighting(0.5, ["cat": 0.5])]
        let joined = Signals.joined([(first, 0, 2), (second, 2, 3)])
        XCTAssertEqual(joined.sightings?.map(\.time), [1, 2.5])
    }
    func testPrintsPackToUnitBytes() {
        let packed = Sighting.packed([3, 4])
        let face = Sighting.Face(x: 0, y: 0, width: 1, height: 1, print: packed)
        XCTAssertEqual(face.vector[0], 0.6, accuracy: 0.01)
        XCTAssertEqual(face.vector[1], 0.8, accuracy: 0.01)
        XCTAssertEqual(Sighting.pixels(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), in: CGSize(width: 100, height: 100), margin: 0),
                       CGRect(x: 25, y: 25, width: 50, height: 25))
    }
}

final class RecapTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private let home = CLLocationCoordinate2D(latitude: 32.08, longitude: 34.78)
    private let rome = CLLocationCoordinate2D(latitude: 41.9, longitude: 12.5)

    func testATripIsBusyDaysAwayFromHome() {
        var items: [Recap.Item] = []
        // One shot a day at home all spring: never a trip.
        for d in 1...28 {items.append(Recap.Item(id: "h\(d)", date: day(4, d), video: false, place: home))}
        // A busy weekend at home is not a trip either.
        for d in 2...3 {for h in 0..<8 {items.append(Recap.Item(id: "w\(d)-\(h)", date: day(5, d, hour: 8 + h), video: true, duration: 10, place: home))}}
        // Three days in Rome with a quiet day between.
        for (d, count) in [(10, 6), (12, 5), (13, 5)] {
            for h in 0..<count {items.append(Recap.Item(id: "r\(d)-\(h)", date: day(8, d, hour: 8 + h), video: h % 2 == 0, duration: 12, place: rome))}
        }
        let trips = Recap.trips(items, calendar: calendar)
        XCTAssertEqual(trips, [DateInterval(start: day(8, 10, hour: 0), end: day(8, 14, hour: 0))])
        XCTAssertEqual(Recap.interval(.trip, now: day(9, 1), items: items, calendar: calendar), trips.last)
    }
    func testWithoutPlacesBusyDaysAreATrip() {
        let items = (0..<14).map {Recap.Item(id: "\($0)", date: day(7, 1 + $0 / 7, hour: 8 + $0 % 7), video: true, duration: 8)}
        XCTAssertEqual(Recap.trips(items, calendar: calendar).count, 1)
        XCTAssertTrue(Recap.trips(Array(items.prefix(7)), calendar: calendar).isEmpty)
    }
    func testChoiceTakesFromEveryDayFavouritesFirst() {
        let items = [
            Recap.Item(id: "a", date: day(8, 1, hour: 9), video: true, duration: 20),
            Recap.Item(id: "b", date: day(8, 1, hour: 10), video: true, duration: 5, favorite: true),
            Recap.Item(id: "c", date: day(8, 1, hour: 11), video: true, duration: 600),
            Recap.Item(id: "d", date: day(8, 2), video: true, duration: 1),
            Recap.Item(id: "e", date: day(8, 3), video: true, duration: 30),
            Recap.Item(id: "p", date: day(8, 2, hour: 8), video: false),
        ]
        let chosen = Recap.choose(items, videos: 3, photos: 1, spread: .day, calendar: calendar)
        XCTAssertEqual(chosen.map(\.id), ["b", "p", "d", "e"])
        let more = Recap.choose(items, videos: 4, photos: 0, spread: .day, calendar: calendar)
        // The second round goes back to the first day: a usable length before a ten-minute one.
        XCTAssertEqual(more.map(\.id), ["a", "b", "d", "e"])
    }
}
