import XCTest
@testable import RKMotion

/// Serves scripted answers to ranged requests, so the download loop itself
/// runs against a server that misbehaves in known ways.
final class ScriptedServer: URLProtocol {
    struct Answer {var status: Int; var headers: [String: String]; var body: Data}
    /// Given the request's Range start and end, what the server sends.
    nonisolated(unsafe) static var answer: (_ first: Int, _ last: Int) -> Answer = {_, _ in Answer(status: 500, headers: [:], body: Data())}
    nonisolated(unsafe) static var requests: [String] = []
    override class func canInit(with request: URLRequest) -> Bool {true}
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {request}
    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        Self.requests.append(range)
        let bounds = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap {Int($0)}
        let answer = Self.answer(bounds.first ?? 0, bounds.count > 1 ? bounds[1] : Int.max)
        var headers = answer.headers
        // "omit" sends no length at all, as a chunked response does.
        if headers["Content-Length"] == "omit" {headers.removeValue(forKey: "Content-Length")}
        else {headers["Content-Length"] = headers["Content-Length"] ?? "\(answer.body.count)"}
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In two pieces, as a network delivers it.
        let half = answer.body.count / 2
        client?.urlProtocol(self, didLoad: answer.body.prefix(half))
        client?.urlProtocol(self, didLoad: answer.body.dropFirst(half))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// F05: the ranged download loop, run against a scripted server.
final class YouTubeTransportTests: XCTestCase {
    private let song = Data((0..<10_000).map {UInt8($0 % 251)})
    private var target: URL!
    private var session: URLSession!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedServer.self]
        session = URLSession(configuration: config)
        target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        ScriptedServer.requests = []
    }
    override func tearDown() {try? FileManager.default.removeItem(at: target)}
    private func fetch(chunk: Int = 4096, limit: Int = YouTubeMusic.sizeLimit) async throws {
        try await YouTubeMusic.fetch(URL(string: "https://media.example/song")!, to: target, session: session, chunk: chunk, limit: limit) {_ in}
    }
    private func partial(_ first: Int, _ last: Int, total: String? = nil, body: Data? = nil) -> ScriptedServer.Answer {
        let end = min(last, song.count - 1)
        return .init(status: 206, headers: ["Content-Range": "bytes \(first)-\(end)/\(total ?? "\(song.count)")"], body: body ?? song[first...end])
    }

    func testWellBehavedRangesAssembleTheWholeSong() async throws {
        ScriptedServer.answer = {self.partial($0, $1)}
        try await fetch()
        XCTAssertEqual(try Data(contentsOf: target), song)
        XCTAssertEqual(ScriptedServer.requests, ["bytes=0-4095", "bytes=4096-8191", "bytes=8192-12287"])
    }
    /// A 206 may carry less than asked; the loop asks again from where it got to.
    func testShortPiecesAreContinuedFromWhereTheyStopped() async throws {
        ScriptedServer.answer = {first, last in self.partial(first, min(last, first + 999))}
        try await fetch()
        XCTAssertEqual(try Data(contentsOf: target), song)
    }
    /// The old loop appended a whole-file 200 after the bytes it already had.
    func testA200MidwayStartsTheFileOverFromThatBody() async throws {
        ScriptedServer.answer = {first, last in
            first == 0 ? self.partial(first, last) : .init(status: 200, headers: [:], body: self.song)
        }
        try await fetch()
        XCTAssertEqual(try Data(contentsOf: target), song, "The file is the 200's body, not the first piece plus it")
    }
    func testAPieceForTheWrongOffsetIsRefused() async throws {
        ScriptedServer.answer = {first, last in first == 0 ? self.partial(first, last) : self.partial(0, 4095)}
        await assertFails(message: "ההורדה מ־YouTube הגיעה שבורה ונעצרה. נסו שוב.")
    }
    func testAPieceLongerThanItsContentRangeIsRefused() async throws {
        ScriptedServer.answer = {first, last in self.partial(first, last, body: self.song[first...min(first + 6000, self.song.count - 1)])}
        await assertFails(message: "ההורדה מ־YouTube הגיעה שבורה ונעצרה. נסו שוב.")
    }
    func testASizeThatChangesMidwayIsRefused() async throws {
        ScriptedServer.answer = {first, last in self.partial(first, last, total: first == 0 ? nil : "20000")}
        await assertFails(message: "ההורדה מ־YouTube הגיעה שבורה ונעצרה. נסו שוב.")
    }
    func testAMissingContentRangeIsRefused() async throws {
        ScriptedServer.answer = {first, last in .init(status: 206, headers: [:], body: self.song[first...min(last, self.song.count - 1)])}
        await assertFails(message: "ההורדה מ־YouTube הגיעה שבורה ונעצרה. נסו שוב.")
    }
    func testAFileOverTheLimitIsRefusedBeforeItIsDownloaded() async throws {
        ScriptedServer.answer = {self.partial($0, $1)}
        await assertFails(limit: 5000, message: "קובץ השמע גדול מדי לשיר.")
        XCTAssertEqual(ScriptedServer.requests.count, 1)
    }
    func testAWhole200BodyOverTheLimitIsStoppedWhileStreaming() async throws {
        // No length declared, so only counting the bytes as they come stops it.
        ScriptedServer.answer = {_, _ in .init(status: 200, headers: ["Content-Length": "omit"], body: self.song)}
        await assertFails(limit: 5000, message: "קובץ השמע גדול מדי לשיר.")
    }
    func testAnErrorStatusIsRefused() async throws {
        ScriptedServer.answer = {_, _ in .init(status: 403, headers: [:], body: Data("no".utf8))}
        await assertFails(message: "YouTube סירב להוריד את השמע. נסו שוב מאוחר יותר.")
    }
    private func assertFails(limit: Int = YouTubeMusic.sizeLimit, message: String, line: UInt = #line) async {
        do {
            try await fetch(limit: limit)
            XCTFail("The download was accepted", line: line)
        } catch let error as AppError {
            XCTAssertEqual(error.message, message, line: line)
        } catch {XCTFail("Unexpected \(error)", line: line)}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "A failed download leaves no file", line: line)
    }
}
