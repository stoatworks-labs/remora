import XCTest
@testable import RemoraCore
@testable import RemoraEngine
@testable import RemoraHosts

// Stage 5b: REAPER through its web interface, Cantabile over a WebSocket, and what both stand on.

final class SHA1Tests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testKnownDigests() {
        XCTAssertEqual(hex(SHA1.hash(Array("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hex(SHA1.hash([])), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hex(SHA1.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1", "two blocks")
        XCTAssertEqual(hex(SHA1.hash([UInt8](repeating: 0x61, count: 1_000_000))),
                       "34aa973cd4c4daa4f61eeb2bdbad27316534016f", "a million a's")
    }

    /// RFC 6455 §1.3's own example.
    func testTheWebSocketAcceptKey() {
        XCTAssertEqual(WebSocketClient.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}

final class WebSocketFrameTests: XCTestCase {
    func testMaskedFramesOfEachLengthGoAndComeBack() throws {
        for n in [0, 5, 125, 126, 300, 65_535, 65_536, 70_000] {
            let payload = (0..<n).map { UInt8($0 & 0xFF) }
            let bytes = WebSocketFrame.encode(opcode: WebSocketFrame.text, payload: payload, mask: [1, 2, 3, 4])
            XCTAssertEqual(WebSocketFrame.declaredLength(bytes), n)
            let (f, used) = try XCTUnwrap(WebSocketFrame.decode(bytes), "\(n)")
            XCTAssertEqual(used, bytes.count)
            XCTAssertEqual(f.payload, payload)
            XCTAssertEqual(f.mask, [1, 2, 3, 4])
            XCTAssertTrue(f.fin)
            XCTAssertNil(WebSocketFrame.decode(Array(bytes.dropLast())), "not all there yet")
        }
    }

    /// RFC 6455 §5.7: "Hello", unmasked and masked.
    func testTheRFCsExamples() throws {
        XCTAssertEqual(WebSocketFrame.encode(opcode: 1, payload: Array("Hello".utf8)), [0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f])
        XCTAssertEqual(WebSocketFrame.encode(opcode: 1, payload: Array("Hello".utf8), mask: [0x37, 0xfa, 0x21, 0x3d]),
                       [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58])
        let (f, _) = try XCTUnwrap(WebSocketFrame.decode([0x01, 0x03, 0x48, 0x65, 0x6c]))
        XCTAssertFalse(f.fin, "the first piece of a fragmented message")
    }
}

/// A WebSocket server on a test stream: the handshake, then text frames each way.
final class FakeWebSocketServer {
    var badAccept = false
    /// Text messages the client sent, in order.
    private(set) var heard: [String] = []
    /// Answers a client's message with any number of messages.
    var answer: (String) -> [String] = { _ in [] }
    private(set) var stream: TestStream?

    func attach(to p: TestPlatform) {
        p.configureStream = { [weak self] s in
            s.connectsOnStart = true
            self?.stream = s
            var shaken = false
            var buffer: [UInt8] = []
            s.onSend = { [weak self, weak s] bytes in
                guard let self, let s else { return }
                if !shaken {
                    let request = String(decoding: bytes, as: UTF8.self)
                    let key = request.components(separatedBy: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key: ") }?
                        .dropFirst("Sec-WebSocket-Key: ".count) ?? ""
                    let accept = self.badAccept ? "nonsense" : WebSocketClient.acceptKey(for: String(key))
                    shaken = true
                    s.receive(Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
                    return
                }
                buffer += bytes
                while let (f, used) = WebSocketFrame.decode(buffer) {
                    buffer.removeFirst(used)
                    XCTAssertNotNil(f.mask, "a client's frames are masked")
                    guard f.opcode == WebSocketFrame.text else { continue }
                    let text = String(decoding: f.payload, as: UTF8.self)
                    self.heard.append(text)
                    for reply in self.answer(text) { self.say(reply) }
                }
            }
        }
    }

    /// A message from the server.
    func say(_ text: String) {
        stream?.receive(WebSocketFrame.encode(opcode: WebSocketFrame.text, payload: Array(text.utf8)))
    }
}

final class WebSocketClientTests: XCTestCase {
    /// The stream holds the client weakly, as a module owns it: a test keeps `c`.
    private func client(_ server: FakeWebSocketServer) -> (WebSocketClient, TestPlatform, () -> [WebSocketClient.State], () -> [String]) {
        let p = TestPlatform()
        server.attach(to: p)
        let c = WebSocketClient(stream: p.tcp(host: "10.0.0.5", port: 35007, queue: .main), host: "10.0.0.5",
                                port: 35007, path: "/api/socket/")
        var states: [WebSocketClient.State] = []
        var texts: [String] = []
        c.onState = { states.append($0) }
        c.onText = { texts.append($0) }
        c.start()
        return (c, p, { states }, { texts })
    }

    func testOpensSendsAndReceives() throws {
        let server = FakeWebSocketServer()
        server.answer = { ["echo: " + $0] }
        let (c, p, states, texts) = client(server)
        XCTAssertEqual(states(), [.connecting, .open])
        let request = String(decoding: try XCTUnwrap(p.streams.first?.sent.first), as: UTF8.self)
        XCTAssertTrue(request.hasPrefix("GET /api/socket/ HTTP/1.1\r\nHost: 10.0.0.5:35007\r\n"))
        XCTAssertTrue(request.contains("Sec-WebSocket-Version: 13\r\n"))
        c.send(text: "hello")
        XCTAssertEqual(server.heard, ["hello"])
        XCTAssertEqual(texts(), ["echo: hello"])
    }

    func testAWrongKeyIsNotAWebSocket() {
        let server = FakeWebSocketServer()
        server.badAccept = true
        let (c, _, states, _) = client(server)
        XCTAssertEqual(states(), [.connecting, .failed("10.0.0.5:35007 didn't answer as a WebSocket server")])
        c.send(text: "hello")
        XCTAssertEqual(server.heard, [], "nothing sent on a link that never opened")
    }

    func testPingsArePongedAndPiecesJoined() throws {
        let server = FakeWebSocketServer()
        let (c, p, _, texts) = client(server)
        defer { c.stop() }
        let s = try XCTUnwrap(p.streams.first)
        let before = s.sent.count
        s.receive(WebSocketFrame.encode(opcode: WebSocketFrame.ping, payload: [9, 8]))
        let (pong, _) = try XCTUnwrap(WebSocketFrame.decode(try XCTUnwrap(s.sent.last)))
        XCTAssertEqual(s.sent.count, before + 1)
        XCTAssertEqual(pong.opcode, WebSocketFrame.pong)
        XCTAssertEqual(pong.payload, [9, 8])
        s.receive(WebSocketFrame.encode(opcode: WebSocketFrame.text, payload: Array("Hel".utf8), fin: false)
                  + WebSocketFrame.encode(opcode: WebSocketFrame.continuation, payload: Array("lo".utf8)))
        XCTAssertEqual(texts(), ["Hello"])
    }

    func testAMaskedFrameFromTheServerDropsTheLink() throws {
        let server = FakeWebSocketServer()
        let (c, p, states, texts) = client(server)
        defer { c.stop() }
        try XCTUnwrap(p.streams.first).receive(WebSocketFrame.encode(opcode: 1, payload: [65], mask: [1, 1, 1, 1]))
        XCTAssertEqual(states().last, .failed("the server masked a frame"))
        XCTAssertEqual(texts(), [])
    }

    func testAFrameTooBigIsRefusedBeforeItComes() throws {
        let server = FakeWebSocketServer()
        let (c, p, states, _) = client(server)
        defer { c.stop() }
        // Only the header of a 9 MB frame.
        try XCTUnwrap(p.streams.first).receive([0x81, 127, 0, 0, 0, 0, 0, 0x90, 0, 0])
        XCTAssertEqual(states().last, .failed("a message over 8 MB"))
    }

    func testACloseIsAnsweredWithAClose() throws {
        let server = FakeWebSocketServer()
        let (c, p, states, _) = client(server)
        defer { c.stop() }
        let s = try XCTUnwrap(p.streams.first)
        s.receive(WebSocketFrame.encode(opcode: WebSocketFrame.close, payload: [0x03, 0xE8, 0x62, 0x79, 0x65]))
        let (echo, _) = try XCTUnwrap(WebSocketFrame.decode(try XCTUnwrap(s.sent.last)))
        XCTAssertEqual(echo.opcode, WebSocketFrame.close)
        XCTAssertEqual(echo.payload, [0x03, 0xE8], "its status code, back")
        XCTAssertEqual(states().last, .failed(WebSocketClient.closedByServer))
        c.send(text: "after")
        XCTAssertEqual(server.heard, [], "nothing after a close")
    }
}

final class HTTPGetTests: XCTestCase {
    func testAnswersWithAndWithoutALength() {
        let head = Array("HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\n".utf8)
        XCTAssertNil(HTTPGet.parse(head + Array("ab".utf8), ended: false), "more to come")
        XCTAssertEqual(HTTPGet.parse(head + Array("abcdeXX".utf8), ended: false), .success(.init(status: 200, body: "abcde")))
        let open = Array("HTTP/1.0 401 Unauthorized\r\n\r\nno".utf8)
        XCTAssertNil(HTTPGet.parse(open, ended: false), "no length: only the close ends it")
        XCTAssertEqual(HTTPGet.parse(open, ended: true), .success(.init(status: 401, body: "no")))
        XCTAssertEqual(HTTPGet.parse(Array("SSH-2.0-OpenSSH\r\n\r\n".utf8), ended: true), .failure(.badAnswer))
        XCTAssertEqual(HTTPGet.parse(Array("HTTP/1.0 200".utf8), ended: true), .failure(.badAnswer))
    }

    func testOneRequestOnAStreamOfItsOwnThenStopped() throws {
        let p = TestPlatform()
        p.configureStream = { s in
            s.connectsOnStart = true
            s.onSend = { [weak s] _ in
                s?.receive(Array("HTTP/1.0 200 OK\r\n\r\nTRACK\t0\tMASTER\t0\n".utf8))
                s?.closeFromServer()
            }
        }
        var result: Result<HTTPGet.Answer, HTTPGet.Failure>?
        HTTPGet.get(p, host: "127.0.0.1", port: 8080, path: "/_/TRACK", queue: .main) { result = $0 }
        XCTAssertEqual(result, .success(.init(status: 200, body: "TRACK\t0\tMASTER\t0\n")))
        let s = try XCTUnwrap(p.streams.first)
        XCTAssertEqual(String(decoding: s.sent[0], as: UTF8.self),
                       "GET /_/TRACK HTTP/1.0\r\nHost: 127.0.0.1:8080\r\nUser-Agent: Remora\r\nAccept: text/plain\r\n\r\n")
        XCTAssertTrue(s.stopped, "stopped, so it doesn't dial again")
    }

    func testNothingThere() {
        let p = TestPlatform()
        p.configureStream = { s in
            s.onState = nil
            DispatchQueue.main.async { s.refuse() }
        }
        var result: Result<HTTPGet.Answer, HTTPGet.Failure>?
        HTTPGet.get(p, host: "127.0.0.1", port: 8080, path: "/_/TRACK", queue: .main) { result = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(result, .failure(.unreachable("connection refused")))
    }
}

/// REAPER's web interface as its notes describe it: TRACK, 40297 and SET/TRACK/n/SEL/1, nothing
/// else. It keeps every path it was asked, and fails the test on any it doesn't know.
final class FakeREAPER {
    var tracks: [(name: String, selected: Bool)]
    private(set) var paths: [String] = []
    var status = 200
    var contentLength = true

    init(_ names: [String], selected: Int? = nil) {
        tracks = names.enumerated().map { ($0.element, $0.offset == selected) }
    }

    func attach(to p: TestPlatform) {
        p.configureStream = { [weak self] s in
            s.connectsOnStart = true
            s.onSend = { [weak self, weak s] bytes in
                guard let self, let s else { return }
                self.answer(String(decoding: bytes, as: UTF8.self), on: s)
            }
        }
    }

    private func answer(_ request: String, on s: TestStream) {
        let path = String(request.split(separator: " ")[1])
        paths.append(path)
        var body = ""
        for c in path.dropFirst(3).split(separator: ";") {
            let p = c.split(separator: "/")
            if c == "TRACK" {
                body += "TRACK\t0\tMASTER\t0\t1.0\t0.0\t-1500\t-1500\t1.0\t0\t0\t0\t1\t0\n"
                for (i, t) in tracks.enumerated() {
                    body += "TRACK\t\(i + 1)\t\(t.name)\t\(t.selected ? 6 : 4)\t1.0\t0.0\t-1500\t-1500\t1.0\t0\t0\t0\t1\t0\n"
                }
            } else if c == "40297" {
                for i in tracks.indices { tracks[i].selected = false }
            } else if p.count == 5, p[0] == "SET", p[1] == "TRACK", let n = Int(p[2]), p[3] == "SEL", p[4] == "1",
                      tracks.indices.contains(n - 1) {
                tracks[n - 1].selected = true
            } else {
                XCTFail("REAPER was sent \(c)")
            }
        }
        var head = "HTTP/1.0 \(status) OK\r\nContent-Type: text/plain\r\n"
        if contentLength { head += "Content-Length: \(body.utf8.count)\r\n" }
        s.receive(Array((head + "\r\n" + body).utf8))
        s.closeFromServer()
    }
}

final class REAPERTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    func testTheWhitelist() {
        for ok in ["/_/TRACK", "/_/40297;SET/TRACK/3/SEL/1;TRACK", "/_/SET/TRACK/12/SEL/1"] {
            XCTAssertTrue(REAPER.isAllowed(ok), ok)
        }
        for never in ["/_/TRACK;", "/_/1007", "/_/40297;SET/TRACK/0/SEL/1", "/_/SET/TRACK/1/SEL/0", "/_/SET/TRACK/1/MUTE/1",
                      "/_/SET/TRACK/1/RECARM/1", "/_/SET/TRACK/01/SEL/1", "/_/SET/TRACK/+1/SEL/1", "/_/TRANSPORT",
                      "/_/OSC/device/track/select/1", "/_/SET/UNDO/x", "/_/_SWS_ACTION", "/TRACK", "/_/", "/_/40297;40298",
                      "/_/SET/TRACK/1/SEL/1/1", "/_/SET/TRACK/1/P_NAME/x"] {
            XCTAssertFalse(REAPER.isAllowed(never), never)
        }
    }

    func testReadsTheTracksAndTheSelection() {
        let body = "TRACK\t0\tMASTER\t0\t1\nTRACK\t1\tKick\t4\t1\nTRACK\t2\tSnare\t6\t1\nTRACK\t3\t\t2\t1\nTRANSPORT\t0\n"
        let t = REAPER.tracks(body)
        XCTAssertEqual(t.map(\.name), ["Kick", "Snare", ""])
        XCTAssertEqual(t.map(\.number), [1, 2, 3])
        XCTAssertEqual(t.map(\.selected), [false, true, true])
    }

    private func run(_ reaper: FakeREAPER, _ commands: [HostCommand], every: TimeInterval = 60)
        -> (paths: [String], events: [HostEvent]) {
        let p = TestPlatform()
        reaper.attach(to: p)
        let m = REAPERModule(ModuleContext(settings: Settings(), platform: p), every: every)
        var events: [HostEvent] = []
        let lock = NSLock()
        m.onEvent = { e in lock.lock(); events.append(e); lock.unlock() }
        m.start()
        for c in commands { m.perform(c) }
        m.waitUntilIdle()
        m.stop()
        lock.lock()
        defer { lock.unlock() }
        return (reaper.paths, events)
    }

    func testShowsATrackBySelectingItAlone() {
        let reaper = FakeREAPER(["Kick", "Snare", "Vox"], selected: 0)
        let r = run(reaper, [.show(2), .step(-1), .step(-1), .step(-1), .show(9), .overview, .resync])
        XCTAssertEqual(r.paths, ["/_/TRACK",
                                 "/_/40297;SET/TRACK/3/SEL/1;TRACK",
                                 "/_/40297;SET/TRACK/2/SEL/1;TRACK",
                                 "/_/40297;SET/TRACK/1/SEL/1;TRACK",
                                 "/_/TRACK"],
                       "a step at the first track stays put; no track 10; Overview isn't REAPER's")
        XCTAssertEqual(reaper.tracks.map(\.selected), [true, false, false])
        XCTAssertTrue(r.events.contains(.racks([Rack(index: 0, name: "Kick"), Rack(index: 1, name: "Snare"), Rack(index: 2, name: "Vox")])))
        XCTAssertEqual(r.events.first, .link(.connecting(peer: "127.0.0.1:8080")))
        XCTAssertTrue(r.events.contains(.link(.connected(name: "REAPER", peer: "127.0.0.1:8080"))))
        XCTAssertEqual(r.events.last, .position(0))
        for path in r.paths { XCTAssertTrue(REAPER.isAllowed(path), path) }
    }

    func testAskedAgainEverySoOften() {
        let reaper = FakeREAPER(["Kick"])
        let p = TestPlatform()
        reaper.attach(to: p)
        let m = REAPERModule(ModuleContext(settings: Settings(), platform: p), every: 0.02)
        m.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        m.stop()
        let asked = reaper.paths.count
        XCTAssertGreaterThan(asked, 2)
        XCTAssertEqual(Set(reaper.paths), ["/_/TRACK"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(reaper.paths.count, asked, "stopping stops the asking")
    }

    func testAPasswordIsSaidPlainly() {
        let reaper = FakeREAPER(["Kick"])
        reaper.status = 401
        reaper.contentLength = false
        let r = run(reaper, [])
        XCTAssertEqual(r.events.last, .link(.failed("REAPER asked for a username and password, and Remora sends none: leave them empty in REAPER's web interface settings")))
    }

    func testNotGatedButEverythingElseDropped() {
        XCTAssertFalse(REAPER.info.capabilities.contains(.showChangesSound))
        let reaper = FakeREAPER(["Kick", "Snare"])
        let r = run(reaper, [.stepPlugin(1), .openRack, .cc(number: 20, value: 127), .step(1)])
        XCTAssertEqual(r.paths, ["/_/TRACK"], "no track selected: a step has nowhere to start from")
    }
}

final class CantabileTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    /// A set list with a break: the racks are the songs, and a song's index counts the break.
    private func server() -> FakeWebSocketServer {
        var current = 0
        let items: [[String: Any]] = [["kind": "song", "name": "Intro", "pr": 0], ["kind": "break", "name": "Interval"],
                                      ["kind": "song", "name": "Ballad", "pr": 1], ["kind": "song", "name": "Encore", "pr": 2]]
        let s = FakeWebSocketServer()
        s.answer = { text in
            guard let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let rid = m["rid"] as? Int else { return [] }
            func json(_ o: [String: Any]) -> String {
                String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
            }
            switch (m["method"] as? String, m["ep"] as? String) {
            case ("open", "/api/setlist"):
                return [json(["rid": rid, "status": 200, "epid": 7,
                              "data": ["name": "Gig", "preLoaded": false, "current": current, "items": items]])]
            case ("post", "/loadSongByIndex"):
                current = ((m["data"] as? [String: Any])?["index"] as? Int) ?? current
            case ("post", "/loadNextSong"):
                let d = ((m["data"] as? [String: Any])?["direction"] as? Int) ?? 1
                var c = current + d
                while items.indices.contains(c), items[c]["kind"] as? String != "song" { c += d }
                if items.indices.contains(c) { current = c }
            default:
                return [json(["rid": rid, "status": 200])]
            }
            return [json(["rid": rid, "status": 200]),
                    json(["epid": 7, "eventName": "currentSongChanged", "data": ["current": current]])]
        }
        return s
    }

    private func run(ticked: Bool = true, _ commands: [HostCommand], then: ((FakeWebSocketServer) -> Void)? = nil)
        -> (server: FakeWebSocketServer, events: [HostEvent], platform: TestPlatform) {
        var s = Settings()
        s.editHost(Cantabile.info.id) {
            $0.address = "10.0.0.5"
            $0.showChangesSoundAccepted = ticked
        }
        let p = TestPlatform()
        let srv = server()
        srv.attach(to: p)
        let m = CantabileModule(ModuleContext(settings: s, platform: p))
        var events: [HostEvent] = []
        let lock = NSLock()
        m.onEvent = { e in lock.lock(); events.append(e); lock.unlock() }
        m.start()
        for c in commands { m.perform(c) }
        m.waitUntilIdle()
        then?(srv)
        m.waitUntilIdle()
        m.stop()
        lock.lock()
        defer { lock.unlock() }
        return (srv, events, p)
    }

    /// What came after the set list opened.
    private func afterOpening(_ events: [HostEvent]) -> [HostEvent] {
        Array(events.drop(while: { $0 != .link(.connected(name: "Cantabile", peer: "10.0.0.5:35007")) }).dropFirst())
    }

    private func requests(_ s: FakeWebSocketServer) -> [[String: Any]] {
        s.heard.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    func testUnTickedItDoesntEvenConnect() {
        let r = run(ticked: false, [.show(1), .step(1), .resync])
        XCTAssertTrue(r.platform.streams.isEmpty)
        XCTAssertTrue(r.events.isEmpty)
    }

    func testTheSongsAreTheRacksAndTheBreakCounts() {
        let r = run([.show(1), .show(1), .step(1), .show(0), .overview, .cc(number: 1, value: 2)])
        XCTAssertEqual(r.server.heard, [
            #"{"ep":"/api/setlist","method":"open","rid":1}"#,
            #"{"data":{"delayed":false,"index":2},"ep":"/loadSongByIndex","epid":7,"method":"post","rid":2}"#,
            #"{"data":{"delayed":false,"direction":1,"wrap":false},"ep":"/loadNextSong","epid":7,"method":"post","rid":3}"#,
            #"{"data":{"delayed":false,"index":0},"ep":"/loadSongByIndex","epid":7,"method":"post","rid":4}"#,
        ], "Ballad is item 2, behind the break; showing it twice loads it once")
        XCTAssertTrue(r.events.contains(.racks([Rack(index: 0, name: "Intro"), Rack(index: 1, name: "Ballad"), Rack(index: 2, name: "Encore")])))
        XCTAssertTrue(r.events.contains(.link(.connected(name: "Cantabile", peer: "10.0.0.5:35007"))))
        XCTAssertEqual(r.events.last, .position(0))
        XCTAssertEqual(r.platform.streams.first?.port, 35007)
    }

    func testFollowsTheSetListsEvents() {
        let r = run([]) { s in
            s.say(#"{"epid":7,"eventName":"itemMoved","data":{"from":3,"to":0}}"#)
            s.say(#"{"epid":7,"eventName":"currentSongChanged","data":{"current":0}}"#)
            s.say(#"{"epid":9,"eventName":"currentSongChanged","data":{"current":3}}"#)
        }
        XCTAssertEqual(afterOpening(r.events), [
            .racks([Rack(index: 0, name: "Encore"), Rack(index: 1, name: "Intro"), Rack(index: 2, name: "Ballad")]),
            .position(1),
            .position(0),
        ], "Intro stays loaded as Encore moves in front of it; another end point's event is not ours")
    }

    func testTheLoadedSongIsFollowedThroughEdits() {
        let r = run([]) { s in
            s.say(#"{"epid":7,"eventName":"itemAdded","data":{"index":0,"item":{"kind":"break","name":"Doors"}}}"#)
            s.say(#"{"epid":7,"eventName":"itemRemoved","data":{"index":1}}"#)
            s.say(#"{"epid":7,"eventName":"itemChanged","data":{"index":0,"item":{"kind":"song","name":"Opener"}}}"#)
        }
        XCTAssertEqual(afterOpening(r.events), [
            .racks([Rack(index: 0, name: "Ballad"), Rack(index: 1, name: "Encore")]),
            .position(nil),
            .racks([Rack(index: 0, name: "Opener"), Rack(index: 1, name: "Ballad"), Rack(index: 2, name: "Encore")]),
        ], "a break in front changes nothing; the loaded song removed, nothing is loaded; a break made a song is a rack")
    }

    func testAClosedConnectionIsSaidAsCantabiles() {
        let r = run([]) { s in s.stream?.closeFromServer() }
        XCTAssertEqual(r.events.last, .link(.failed("Cantabile closed the connection")))
    }

    func testResyncOpensTheSetListAgain() {
        let r = run([.resync])
        XCTAssertEqual(r.server.heard, [
            #"{"ep":"/api/setlist","method":"open","rid":1}"#,
            #"{"epid":7,"method":"close"}"#,
            #"{"ep":"/api/setlist","method":"open","rid":2}"#,
        ], "a close goes without a rid, as cantabile-js sends it")
    }

    func testOnlyListedRequests() {
        XCTAssertTrue(Cantabile.Request.openSetList.isAllowed)
        XCTAssertTrue(Cantabile.Request.loadNextSong(epid: 1, direction: -1).isAllowed)
        XCTAssertFalse(Cantabile.Request.loadNextSong(epid: 1, direction: 2).isAllowed)
        XCTAssertFalse(Cantabile.Request.loadSong(epid: 1, index: -1).isAllowed)
        XCTAssertFalse(Cantabile.Request.close(epid: 0).isAllowed)
        XCTAssertEqual(Cantabile.Request.close(epid: 7).json(rid: nil), #"{"epid":7,"method":"close"}"#)
        XCTAssertFalse(Cantabile.Request.close(epid: 7).answered)
        XCTAssertTrue(Cantabile.Request.openSetList.answered)
        XCTAssertTrue(Cantabile.info.capabilities.contains(.showChangesSound))
    }
}

final class HostLinkLogTests: XCTestCase {
    /// The log says what the Plug-in Host tab says, as it does for the console.
    func testALinkIsLoggedInWords() {
        XCTAssertEqual(Bridge.logLine(.listening(50002)), "listening on port 50002")
        XCTAssertEqual(Bridge.logLine(.connecting(peer: "127.0.0.1:8080")), "connecting to 127.0.0.1:8080")
        XCTAssertEqual(Bridge.logLine(.connected(name: "REAPER", peer: "127.0.0.1:8080")), "connected to REAPER at 127.0.0.1:8080")
        XCTAssertEqual(Bridge.logLine(.failed("no answer")), "not connected: no answer")
    }
}
