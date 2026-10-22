import XCTest
import AVFoundation
import UIKit
@testable import RKMotion

final class EditRulesTests: XCTestCase {
    private let parts = ProjectPart.laid(["a.mov", "b.mov", "c.mov"], durations: [20, 10, 4])

    func testLongClipsBecomeShortSeparateShots() {
        var scores = Array(repeating: 0.2, count: 40)
        scores[3] = 0.9; scores[14] = 0.95; scores[15] = 0.9
        let long = Clip(start: 0, end: 20, score: 0.5)
        let short = ClipRules.capped([long, Clip(start: 30, end: 33)], limit: 5, scores: scores)
        // Two stretches of ten seconds, the strongest five of each.
        XCTAssertEqual(short.count, 3)
        XCTAssertTrue(short.allSatisfy {$0.duration <= 5.0001})
        XCTAssertTrue((0...3).contains(short[0].start) && short[0].end >= 4, "the first keeps its peak: \(short[0])")
        XCTAssertTrue(short[1].start <= 14 && short[1].end >= 16, "the second keeps its peak: \(short[1])")
        XCTAssertEqual(short[0].uid, long.uid)
        XCTAssertNotEqual(short[1].uid, long.uid)
        XCTAssertGreaterThan(short[1].score ?? 0, short[0].score ?? 1)
        // A clip within the limit, and one the rider made, stay as they are.
        XCTAssertEqual(short[2], Clip(start: 30, end: 33, uid: short[2].uid))
        var manual = Clip(start: 0, end: 20); manual.manual = true
        XCTAssertEqual(ClipRules.capped([manual], limit: 5, scores: scores), [manual])
        XCTAssertEqual(ClipRules.capped([long], limit: nil, scores: scores), [long])
        XCTAssertNil(ClipRules.maxLength(["maxClip": .text("off")]))
        XCTAssertEqual(ClipRules.maxLength(["maxClip": .text("5")]), 5)
    }
    func testEveryVideoGetsAClip() {
        var scores = Array(repeating: 0.1, count: 34)
        scores[24] = 0.4
        let found = [Clip(start: 2, end: 8, score: 0.8)]
        let covered = ClipRules.covered(found, parts: parts, scores: scores, limit: nil)
        XCTAssertEqual(covered.count, 3)
        XCTAssertEqual(covered.map(\.start), [2, 21, 30], "the second video's strongest seconds; all of the short third")
        XCTAssertEqual(covered[1].duration, ClipRules.coverLength)
        XCTAssertEqual(covered[2].end, 34)
        // Picking for a short movie still keeps one clip of each video.
        let groups = ClipRules.groups(covered, parts: parts)
        XCTAssertEqual(groups, [0, 1, 2])
        let picked = ClipPicker.autoPick(covered, seconds: 5, groups: groups)
        XCTAssertEqual(picked.map {$0.selected != false}, [true, true, true])
        XCTAssertEqual(ClipPicker.autoPick(covered, seconds: 5).filter {$0.selected != false}.count, 1)
        // Turned off, nothing is added.
        let apart = ClipRules.apply(found, parts: parts, scores: scores, settings: ["everyVideo": .flag(false)])
        XCTAssertEqual(apart, found)
        XCTAssertEqual(ClipRules.apply(found, parts: parts, scores: scores, settings: [:]).count, 3)
    }
    func testSlowMotionModes() {
        let scores = [0.1, 0.2, 0.9, 0.3, 0.1, 0.5, 0.2, 0.2, 0.8, 0.1]
        let clips = [Clip(start: 0, end: 4), Clip(start: 4, end: 7), Clip(start: 7, end: 10)]
        XCTAssertEqual(SlowMotion.mode([:]), "off")
        XCTAssertEqual(SlowMotion.mode(["slowPeak": .flag(true)]), "peak", "older edits keep their slow peak")
        XCTAssertEqual(SlowMotion.mode(["slowPeak": .flag(true), "slowMode": .text("each")]), "each")
        let peak = SlowMotion.shaped(clips, scores: scores, settings: ["slowMode": .text("peak")])
        XCTAssertEqual(peak.map {$0.slowAt != nil}, [true, false, false])
        let each = SlowMotion.shaped(clips, scores: scores, settings: ["slowMode": .text("each"), "slowRate": .text("4"), "slowLength": .text("1.5")])
        XCTAssertEqual(each.map {$0.slowAt != nil}, [true, true, true])
        // Four times slower: a 1.5 s stretch plays for 6 s.
        XCTAssertEqual(each[0].shown(1), 4 + 1.5 * 3, accuracy: 1e-9)
        // A clip the rider marked keeps its own mark in every mode.
        var marked = clips; marked[1].slowAt = 4.2
        let off = SlowMotion.shaped(marked, scores: scores, settings: ["slowMode": .text("off")])
        XCTAssertEqual(off.map {$0.slowAt}, [nil, 4.2, nil])
        XCTAssertEqual(SlowMotion.shaped(marked, scores: scores, settings: ["slowMode": .text("each")])[1].slowAt, 4.2)
        // A longer slow stretch on a short clip slows what fits.
        var short = Clip(start: 0, end: 2.5, slowAt: 0); short.slowLength = 3
        XCTAssertEqual(short.slowRange?.end ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(short.footage(atScreen: short.screenOffset(of: 1.2, speed: 1), speed: 1), 1.2, accuracy: 1e-9)
    }
    func testLengthPickCountsSlowMotion() {
        let clips = (0..<10).map {Clip(start: Double($0) * 4, end: Double($0) * 4 + 4, score: 1 - Double($0) / 100)}
        let scores = Array(repeating: 0.5, count: 40)
        let settings: [String: Setting] = ["slowMode": .text("each"), "slowRate": .text("4"), "slowLength": .text("3")]
        // Each clip plays 4 + 3 × 3 = 13 seconds, so a 30-second movie holds two.
        let picked = ClipPicker.autoPick(clips, seconds: 30, shape: {SlowMotion.shaped($0, scores: scores, settings: settings)})
        XCTAssertEqual(picked.filter {$0.selected != false}.count, 2)
        XCTAssertEqual(ClipPicker.autoPick(clips, seconds: 30).filter {$0.selected != false}.count, 8)
    }
    func testTransitionPreviewHoldsThenPasses() {
        XCTAssertEqual(TransitionPreview.progress(at: 0.1), 0)
        XCTAssertEqual(TransitionPreview.progress(at: TransitionPreview.loop / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TransitionPreview.progress(at: TransitionPreview.loop - 0.1), 1)
        XCTAssertTrue(TransitionPreview.smartCycle.allSatisfy {LocalEngine.transitions.contains($0)})
    }

    // MARK: - Reading

    private func signals(motion: Double, scenes: [String: Double] = [:], animals: Double? = nil, beauty: Double? = nil, speech: Double = 0) -> Signals {
        let seconds = 20
        return Signals(motion: (0..<seconds).map {motion + Double($0 % 3) * 0.002}, loudness: (0..<seconds).map {0.1 + Double($0 % 4) * 0.05},
                       music: Array(repeating: 0, count: seconds), speech: Array(repeating: speech, count: seconds),
                       cheer: Array(repeating: 0, count: seconds), people: Array(repeating: 0, count: seconds), scenes: scenes,
                       animals: animals.map {Array(repeating: $0, count: seconds)}, beauty: beauty.map {Array(repeating: $0, count: seconds)})
    }
    func testReadsTheNewKinds() {
        XCTAssertEqual(ContentReading.read(signals(motion: 0.03, animals: 1)).detected, .pets)
        XCTAssertEqual(ContentReading.read(signals(motion: 0.03, scenes: ["dog": 0.6])).detected, .pets)
        XCTAssertEqual(ContentReading.read(signals(motion: 0.06, scenes: ["soccer": 0.7, "stadium": 0.4])).detected, .sports)
        XCTAssertEqual(ContentReading.read(signals(motion: 0.015, scenes: ["sunset_sunrise": 0.7], beauty: 0.8)).detected, .scenery)
        XCTAssertEqual(ContentReading.read(signals(motion: 0.012, scenes: ["food": 0.6, "dessert": 0.3])).detected, .food)
        XCTAssertEqual(ContentReading.share(["swimming_pool": 0.5], ContentReading.sportScenes), 0.5)
        // Still nothing in particular: general, and a close call worth a second opinion.
        let plain = ContentReading.read(signals(motion: 0.01))
        XCTAssertEqual(plain.detected, .general)
        XCTAssertTrue(plain.uncertain)
    }
    func testOffersTheNextLikelyKind() {
        let close = ContentReading.read(signals(motion: 0.05, scenes: ["dog": 0.45, "soccer": 0.45]))
        XCTAssertNotNil(close.runnerUp)
        XCTAssertNotEqual(close.runnerUp, close.kind)
        XCTAssertTrue([ContentKind.pets, .sports].contains(close.kind))
    }
    func testModelAnswersAreRead() {
        XCTAssertEqual(ModelReading.parse("pets"), .pets)
        XCTAssertEqual(ModelReading.parse("The kind is: Scenery."), .scenery)
        XCTAssertNil(ModelReading.parse("I am not sure"))
        let s = signals(motion: 0.03, scenes: ["dog": 0.5, "grass": 0.3])
        let prompt = ModelReading.prompt(ContentReading.read(s), signals: s)
        XCTAssertTrue(prompt.contains("dog (50%)"), prompt)
    }
    func testNewSignalsJoinAcrossVideos() {
        let a = signals(motion: 0.03, animals: 2), b = signals(motion: 0.03, beauty: 0.7)
        let joined = Signals.joined([(a, 0, 20), (b, 20, 20)])
        XCTAssertEqual(joined.animals?.count, 40)
        XCTAssertEqual(joined.animals?.first, 2)
        XCTAssertEqual(joined.animals?.last, 0)
        XCTAssertEqual(joined.beauty?.last, 0.7)
        XCTAssertNil(Signals.joined([(signals(motion: 0.03), 0, 20), (signals(motion: 0.03), 20, 20)]).beauty)
    }

    // MARK: - Photos

    func testPhotoMovesTowardsItsFocus() {
        let route = PhotoMotion.path(image: CGSize(width: 4000, height: 3000), frame: CGSize(width: 1920, height: 1080), focus: CGPoint(x: 3800, y: 1500))
        XCTAssertEqual(route.from.width / route.from.height, 1920 / 1080, accuracy: 0.001)
        XCTAssertEqual(route.from.width, 4000, accuracy: 0.5)
        XCTAssertEqual(route.to.width, 4000 / PhotoMotion.zoom, accuracy: 0.5)
        XCTAssertEqual(route.to.maxX, 4000, accuracy: 0.5, "pushes in towards the right edge, never past it")
        XCTAssertEqual(PhotoMotion.crop(route, at: 0).minX, route.from.minX, accuracy: 0.01)
        XCTAssertEqual(PhotoMotion.crop(route, at: 1).minX, route.to.minX, accuracy: 0.01)
        XCTAssertEqual(PhotoMotion.crop(route, at: 1).width, route.to.width, accuracy: 0.01)
        XCTAssertEqual(PhotoMotion.frame(for: CGSize(width: 3000, height: 4000)), CGSize(width: 1080, height: 1920))
        XCTAssertTrue(PhotoMotion.isPhoto(URL(fileURLWithPath: "/tmp/a.HEIC")))
        XCTAssertFalse(PhotoMotion.isPhoto(URL(fileURLWithPath: "/tmp/a.mov")))
    }
    func testPhotoBecomesAVideo() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image {context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 520, y: 200, width: 160, height: 160))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer {try? FileManager.default.removeItem(at: output)}
        try await PhotoMotion.makeVideo(from: data, to: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, PhotoMotion.seconds, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
    }
}

private extension Clip {
    init(start: Double, end: Double, uid: String) {self.init(uid: uid, start: start, end: end)}
}
