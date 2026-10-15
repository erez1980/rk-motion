import XCTest
@testable import RKMotion

/// Counts how many pictures are being made at once.
actor MakerProbe {
    private(set) var calls = 0, now = 0, most = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holding = false
    func hold() {holding = true}
    func release() {holding = false; held.forEach {$0.resume()}; held = []}
    func make() async -> CGImage {
        calls += 1; now += 1; most = max(most, now)
        if holding {await withCheckedContinuation {held.append($0)}} else {try? await Task.sleep(for: .milliseconds(20))}
        now -= 1
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}

/// F08: project pictures are made a few at a time, once, and kept.
final class ThumbnailTests: XCTestCase {
    private var folder: URL!
    override func setUp() {folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}
    override func tearDown() {try? FileManager.default.removeItem(at: folder)}
    private func projects(_ count: Int) -> [LocalProject] {(0..<count).map {LocalProject(name: "\($0)", source: "source-\($0).mov")}}

    /// The old list started a decoder for every project at once, every time.
    func testAtMostTwoAreMadeAtOnceAndEachOnlyOnce() async throws {
        let probe = MakerProbe()
        let thumbnails = Thumbnails(folder: folder, limit: 2) {_ in await probe.make()}
        let list = projects(10)
        let images = await withTaskGroup(of: UIImage?.self) {group in
            for p in list {group.addTask {await thumbnails.image(for: p)}}
            return await group.reduce(into: []) {$0.append($1)}
        }
        XCTAssertEqual(images.compactMap {$0}.count, 10)
        let most = await probe.most, calls = await probe.calls
        XCTAssertLessThanOrEqual(most, 2)
        XCTAssertEqual(calls, 10)
        // Shown again: from memory. A fresh launch: from disk.
        for p in list {_ = await thumbnails.image(for: p)}
        let relaunched = Thumbnails(folder: folder, limit: 2) {_ in await probe.make()}
        for p in list {let image = await relaunched.image(for: p); XCTAssertNotNil(image)}
        let after = await probe.calls
        XCTAssertEqual(after, 10, "Nothing is decoded twice")
    }
    /// A row that scrolls away while waiting for its turn gives the turn up.
    func testARowThatLeavesBeforeItsTurnDecodesNothing() async throws {
        let probe = MakerProbe()
        await probe.hold()
        let thumbnails = Thumbnails(folder: folder, limit: 2) {_ in await probe.make()}
        let list = projects(3)
        let busy = list.prefix(2).map {p in Task {await thumbnails.image(for: p)}}
        while await probe.now < 2 {await Task.yield()}
        let leaving = Task {await thumbnails.image(for: list[2])}
        try await Task.sleep(for: .milliseconds(50))
        leaving.cancel()
        let left = await leaving.value
        XCTAssertNil(left)
        await probe.release()
        for task in busy {let image = await task.value; XCTAssertNotNil(image)}
        let calls = await probe.calls
        XCTAssertEqual(calls, 2, "The row that left never had its picture made")
    }
}
