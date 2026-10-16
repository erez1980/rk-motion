import XCTest
@testable import RKMotion
import CoreImage

/// GoPro GPS in GPMF, built byte by byte the way the camera writes it.
final class TelemetryTests: XCTestCase {
    private func entry(_ key: String, _ type: UInt8, _ size: Int, _ count: Int, _ payload: [UInt8]) -> [UInt8] {
        var bytes = Array(key.utf8) + [type, UInt8(size), UInt8(count >> 8), UInt8(count & 255)] + payload
        while bytes.count % 4 != 0 {bytes.append(0)}
        return bytes
    }
    private func nest(_ key: String, _ children: [UInt8]) -> [UInt8] {entry(key, 0, 4, children.count / 4, children)}
    private func long(_ value: Int32) -> [UInt8] {withUnsafeBytes(of: value.bigEndian) {Array($0)}}
    private func short(_ value: UInt16) -> [UInt8] {withUnsafeBytes(of: value.bigEndian) {Array($0)}}
    private let l = UInt8(ascii: "l"), L = UInt8(ascii: "L"), complex = UInt8(ascii: "?")

    private func stream(fix: Int32?, rows: [[Int32]], key: String = "GPS5", tail: [UInt8] = [], tails: [[UInt8]]? = nil, scale: [Int32] = [10_000_000, 10_000_000, 1000, 1000, 1000]) -> Data {
        let size = key == "GPS9" ? 32 : 20
        let readings = rows.indices.flatMap {rows[$0].flatMap(long) + (tails?[$0] ?? tail)}
        return Data(nest("DEVC", nest("STRM",
            (fix.map {entry("GPSF", L, 4, 1, long($0))} ?? []) +
            entry("SCAL", l, 4, scale.count, scale.flatMap(long)) +
            entry(key, key == "GPS9" ? complex : l, size, rows.count, readings))))
    }

    func testReadsGPS5InRealUnits() throws {
        let rows = Telemetry.gps(stream(fix: 3, rows: [[321_234_567, -1_225_000_000, 812_345, 8_333, 8_400], [321_234_600, -1_225_000_100, 812_500, 9_000, 9_100]]))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0], 32.1234567, accuracy: 1e-7)
        XCTAssertEqual(rows[0][1], -122.5, accuracy: 1e-7)
        XCTAssertEqual(rows[0][2], 812.345, accuracy: 1e-6)
        XCTAssertEqual(rows[1][3], 9, accuracy: 1e-6)
    }
    func testReadsTheNewerGPS9() throws {
        // GPS9 adds days, seconds, precision and fix after the first five fields.
        let rows = Telemetry.gps(stream(fix: 3, rows: [[321_234_567, 347_654_321, 100_000, 12_500, 12_600, 9000, 3600]], key: "GPS9",
                                        tail: short(150) + short(3), scale: [10_000_000, 10_000_000, 1000, 1000, 100, 1, 1000, 100, 1]))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][3], 12.5, accuracy: 1e-6)
        XCTAssertEqual(rows[0][4], 126, accuracy: 1e-6)
    }
    func testGPS9KeepsOnlyReadingsWithTheirOwnLock() {
        // No stream-wide GPSF: each GPS9 reading says whether it was locked.
        let row: [Int32] = [321_234_567, 347_654_321, 100_000, 12_500, 12_600, 9000, 3600]
        let rows = Telemetry.gps(stream(fix: nil, rows: [row, row, row], key: "GPS9", tails: [short(150) + short(0), short(150) + short(3), short(150) + short(2)],
                                        scale: [10_000_000, 10_000_000, 1000, 1000, 100, 1, 1000, 100, 1]))
        XCTAssertEqual(rows.count, 2)
    }
    func testIgnoresReadingsWithoutASatelliteLock() {
        XCTAssertTrue(Telemetry.gps(stream(fix: 0, rows: [[321_234_567, 347_654_321, 100_000, 12_500, 12_600]])).isEmpty)
        XCTAssertTrue(Telemetry.gps(Data([1, 2, 3])).isEmpty)
    }

    func testAddsUpDistanceButNotAcrossAGap() {
        let samples = [0.0, 1, 2, 7, 8].map {Telemetry.Sample(time: $0, speed: 10, altitude: 500)}
        XCTAssertEqual(Telemetry.withDistance(samples).map(\.distance), [0, 10, 20, 20, 30])
    }
    func testReadoutInRiderUnits() throws {
        let samples = Telemetry.withDistance(stride(from: 0.0, to: 600, by: 0.1).map {Telemetry.Sample(time: $0, speed: 10, altitude: 812.4)})
        let readout = try XCTUnwrap(Telemetry.readout(at: 300, in: samples))
        XCTAssertEqual(readout.speed, 36)
        XCTAssertEqual(readout.altitude, 812)
        XCTAssertEqual(readout.distance, 3, accuracy: 0.05)
        XCTAssertNil(Telemetry.readout(at: 900, in: samples))
    }
    func testOverlayFollowsTheRideThroughCutsAndSlowMotion() throws {
        let samples = Telemetry.withDistance(stride(from: 0.0, to: 300, by: 0.1).map {Telemetry.Sample(time: $0, speed: $0 / 10, altitude: 0)})
        var slow = Clip(start: 200, end: 210)
        slow.slowAt = 204
        let clips = [Clip(start: 100, end: 104), slow]
        let segments = LocalEngine.timeline(clips: clips, speed: 1, transition: 0)
        let frames = Telemetry.frames(clips: clips, segments: segments, speed: 1, length: segments.last!.end, samples: samples)
        // 2 s into the movie is 102 s into the ride: 10.2 m/s, 37 km/h.
        XCTAssertEqual(try XCTUnwrap(frames.first {$0.time == 2}?.readout).speed, 37)
        // The slow stretch plays footage 204 to 205.5 over three seconds.
        XCTAssertEqual(slow.footage(atScreen: 6, speed: 1), 205, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(frames.first {$0.time == 8}?.readout).speed, Int((20.4 * 3.6).rounded()))
    }
    func testFootageIsTheInverseOfScreenTime() {
        var clip = Clip(start: 10, end: 20)
        clip.slowAt = 13
        for second in stride(from: 10.0, through: 20, by: 0.25) {
            for speed in [1.0, 1.5, 2.0] {
                XCTAssertEqual(clip.footage(atScreen: clip.screenOffset(of: second, speed: speed), speed: speed), second, accuracy: 0.0001)
            }
        }
    }
    func testDrawsThePanelAndLaysItOverTheMovie() throws {
        let readout = Telemetry.Readout(speed: 42, altitude: 812, distance: 12.4)
        let panel = try XCTUnwrap(Telemetry.panel(readout, width: 400))
        XCTAssertEqual(panel.width, 400)
        XCTAssertEqual(panel.height, 168)
        let frames = [Telemetry.Frame(time: 0, readout: readout), Telemetry.Frame(time: 0.5, readout: nil)]
        let panels = Telemetry.panels(frames, render: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(panels.count, 1)
        // Low on the left of the frame, clear of the edge.
        let placed = try XCTUnwrap(panels[readout])
        XCTAssertEqual(placed.extent.minX, 54, accuracy: 0.5)
        XCTAssertEqual(placed.extent.minY, 54 * 1.6, accuracy: 0.5)
        let movie = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        XCTAssertFalse(Telemetry.composite(movie, at: 0.2, frames: frames, panels: panels) === movie)
        // No reading then, or past the end, leaves the frame as it was.
        XCTAssertTrue(Telemetry.composite(movie, at: 0.7, frames: frames, panels: panels) === movie)
        XCTAssertTrue(Telemetry.composite(movie, at: 9, frames: frames, panels: panels) === movie)
    }
    func testOrdersChaptersTheSameWhicheverWayTheSortLooks() {
        // Both recordings share a date; recording 7 was picked first.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let picked = ["GX020007.MP4", "GX010008.MP4", "GX010007.MP4"].map {(url: URL(fileURLWithPath: "/x/" + $0), date: date)}
        XCTAssertEqual(EditorModel.ordered(picked).map(\.lastPathComponent), ["GX010007.MP4", "GX020007.MP4", "GX010008.MP4"])
        // An earlier date still comes first, and other videos keep their place.
        let mixed = [(url: URL(fileURLWithPath: "/x/IMG_2.MOV"), date: date), (url: URL(fileURLWithPath: "/x/IMG_1.MOV"), date: date.addingTimeInterval(-60))]
        XCTAssertEqual(EditorModel.ordered(mixed).map(\.lastPathComponent), ["IMG_1.MOV", "IMG_2.MOV"])
    }
    func testReadsGoProChapterNames() {
        XCTAssertEqual(EditorModel.goProChapter(URL(fileURLWithPath: "/x/GX020482.MP4"))?.chapter, 2)
        XCTAssertEqual(EditorModel.goProChapter(URL(fileURLWithPath: "/x/GH010007.mp4"))?.recording, 7)
        XCTAssertNil(EditorModel.goProChapter(URL(fileURLWithPath: "/x/IMG_1234.MOV")))
        XCTAssertNil(EditorModel.goProChapter(URL(fileURLWithPath: "/x/GXAB0482.MP4")))
    }
}
