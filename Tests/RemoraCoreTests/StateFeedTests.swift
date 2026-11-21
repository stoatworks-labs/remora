import XCTest
@testable import RemoraCore
@testable import RemoraEngine
@testable import RemoraHosts

final class StateFeedTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    typealias A = StateFeed.Address

    private func rack(_ m: [OSC.Message]) -> [OSC.Arg]? { m.last { $0.address == A.rack }?.args }

    // MARK: What it says

    func testANewEngineSaysItKnowsNothing() {
        let m = StateFeed.messages(Bridge.Status(), hostID: "superrack.midi", product: "SuperRack", follow: true)
        XCTAssertEqual(m, [
            OSC.Message(address: "/remora/state/host", args: [.string("superrack.midi"), .string("SuperRack")]),
            OSC.Message(address: "/remora/state/host/link", args: [.string("none"), .string("")]),
            OSC.Message(address: "/remora/state/host/problem", args: [.string("")]),
            OSC.Message(address: "/remora/state/racks/count", args: [.int(0)]),
            OSC.Message(address: "/remora/state/racks/names", args: []),
            OSC.Message(address: "/remora/state/rack", args: [.int(0), .string(""), .string("unknown")]),
            OSC.Message(address: "/remora/state/follow", args: [.int(1)]),
        ])
        XCTAssertEqual(m.map(\.address), A.all)
        // A host this build lacks has no product, and Follow off is 0.
        let other = StateFeed.messages(Bridge.Status(), hostID: "acme.rack", product: nil, follow: false)
        XCTAssertEqual(other.first?.args, [.string("acme.rack"), .string("")])
        XCTAssertEqual(other.last?.args, [.int(0)])
    }

    /// Every way Remora can know where the host is goes out as its own word: a rack it only counted
    /// to never reads as confirmed.
    func testTheRackSaysHowRemoraKnows() {
        var st = Bridge.Status()
        st.racks = allanRacks
        let cases: [(RackPosition, String, Bool)] = [(.reported(4), "reported", true), (.seen(4), "seen", true),
                                                     (.counted(4), "counted", false), (.sent(4), "sent", false)]
        for (p, how, confirmed) in cases {
            st.position = p
            XCTAssertEqual(rack(StateFeed.messages(st, hostID: "h", product: "H", follow: true)),
                           [.int(5), .string("hh 1"), .string(how)])
            XCTAssertEqual(p.confirmed, confirmed, how)
        }
        XCTAssertEqual(Set(RackPosition.Basis.allCases.map(\.rawValue)), ["reported", "seen", "counted", "sent"])
        // A position the rack list doesn't have yet: its number, no name.
        st.position = .counted(40)
        XCTAssertEqual(rack(StateFeed.messages(st, hostID: "h", product: "H", follow: true)),
                       [.int(41), .string(""), .string("counted")])
    }

    func testTheRacksAndTheLink() {
        var st = Bridge.Status()
        st.racks = allanRacks
        st.hostLink = .connected(name: "Waves SuperRack", peer: "10.0.0.2:5000")
        let m = StateFeed.messages(st, hostID: "superrack.prolink", product: "SuperRack", follow: true)
        XCTAssertEqual(m.first { $0.address == A.rackCount }?.args, [.int(16)])
        XCTAssertEqual(m.first { $0.address == A.rackNames }?.args, allanRacks.map { .string($0.name) })
        XCTAssertEqual(m.first { $0.address == A.link }?.args,
                       [.string("connected"), .string("connected to Waves SuperRack at 10.0.0.2:5000")])
        XCTAssertEqual(StateFeed.link(.listening(50002)), ["listening", "listening on port 50002"])
        XCTAssertEqual(StateFeed.link(.connecting(peer: "10.0.0.2:5000")), ["connecting", "connecting to 10.0.0.2:5000"])
        XCTAssertEqual(StateFeed.link(.failed("TCP 50002 is in use")), ["failed", "not connected: TCP 50002 is in use"])
        // A rack number the host skipped keeps the nth name rack n.
        XCTAssertEqual(StateFeed.rackNames([Rack(index: 2, name: "C"), Rack(index: 0, name: "A")]), ["A", "", "C"])
    }

    // MARK: The engine sends it

    /// A SuperRack MIDI engine with the feed on, a session that can't be read, and no MIDI port.
    private func engine(at start: Int = 5, feed: Bool = true) -> (Bridge, TestPlatform, FakeSuperRack) {
        var s = Settings()
        s.stepMilliseconds = 0
        s.sessionPath = "/nonexistent/CurrentSPRKP.dat"
        if feed { s.stateFeedSettings = StateFeedSettings(enabled: true, host: " 10.0.0.7 ", port: 9100) }
        let sr = FakeSuperRack(count: 16, at: start)
        let p = TestPlatform()
        let b = Bridge(settings: s, sink: sr, platform: p)
        return (b, p, sr)
    }

    /// Lets the state socket open, the engine hear about it, and its sends go out.
    private func settle(_ p: TestPlatform) {
        for _ in 0..<3 {
            for u in p.udps { u.queue.sync {} }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testItIsOffByDefaultAndAQuerySendsNothing() {
        XCTAssertEqual(Settings().stateFeedSettings, StateFeedSettings())
        XCTAssertFalse(Settings().stateFeedSettings.enabled)
        let (b, p, _) = engine(feed: false)
        b.start()
        defer { b.stop() }
        p.osc.onMessage?(OSC.Message(address: StateFeed.query, args: []))
        b.setRacksForTesting(allanRacks)
        settle(p)
        XCTAssertTrue(p.udps.isEmpty, "no socket is made, so nothing goes anywhere")
    }

    func testAllOfItWhenTheSocketOpensThenOnlyWhatChanges() throws {
        let (b, p, sr) = engine()
        XCTAssertTrue(p.udps.isEmpty, "nothing before the engine starts")
        b.start()
        defer { b.stop() }
        let u = try XCTUnwrap(p.udps.first)
        XCTAssertEqual(u.host, "10.0.0.7", "the address as typed, without its spaces")
        XCTAssertEqual(u.port, 9100)
        settle(p)
        let first = u.messages
        XCTAssertEqual(first.map(\.address), A.all)
        XCTAssertNotEqual(first.first { $0.address == A.problem }?.args, [.string("")], "the session can't be read")
        XCTAssertEqual(rack(first), [.int(0), .string(""), .string("unknown")])

        var mark = u.messages.count
        b.setRacksForTesting(allanRacks)
        settle(p)
        XCTAssertEqual(u.messages.dropFirst(mark).map(\.address), [A.rackCount, A.rackNames])

        // Counted there with no window to look at: it says so.
        mark = u.messages.count
        b.select(rack: 4)
        b.driverForTesting.waitUntilIdle()
        settle(p)
        XCTAssertEqual(sr.rack, 4)
        XCTAssertEqual(Array(u.messages.dropFirst(mark)),
                       [OSC.Message(address: A.rack, args: [.int(5), .string("hh 1"), .string("counted")])])

        mark = u.messages.count
        b.setFollow(false)
        settle(p)
        XCTAssertEqual(Array(u.messages.dropFirst(mark)), [OSC.Message(address: A.follow, args: [.int(0)])])

        // Asked: everything again, as it stands.
        mark = u.messages.count
        p.osc.onMessage?(OSC.Message(address: "/remora/state/query", args: []))
        settle(p)
        let again = Array(u.messages.dropFirst(mark))
        XCTAssertEqual(again.map(\.address), A.all)
        XCTAssertEqual(rack(again), [.int(5), .string("hh 1"), .string("counted")])
        XCTAssertEqual(again.first { $0.address == A.rackCount }?.args, [.int(16)])

        // Turned off: the socket closes and nothing more is sent.
        var off = b.settings
        off.stateFeedSettings.enabled = false
        b.update(off)
        settle(p)
        XCTAssertEqual(u.state, .stopped)
        mark = u.messages.count
        b.setFollow(true)
        settle(p)
        XCTAssertEqual(u.messages.count, mark)
        XCTAssertEqual(p.udps.count, 1)
    }

    /// A new address or port is a new socket, sent everything.
    func testANewTargetGetsEverything() throws {
        let (b, p, _) = engine()
        b.start()
        defer { b.stop() }
        settle(p)
        var s = b.settings
        s.stateFeedSettings.port = 9200
        b.update(s)
        settle(p)
        XCTAssertEqual(p.udps.map(\.port), [9100, 9200])
        XCTAssertEqual(p.udps[0].state, .stopped)
        XCTAssertEqual(p.udps[1].messages.map(\.address), A.all)
    }

    /// With SuperRack's window to read, a landing it shows is seen. A window that disagrees leaves
    /// the rack counted, even after homing and counting again.
    func testARackTheWindowShowedIsSeenAndOneItDisputesIsCounted() throws {
        let (b, p, sr) = engine(at: 11)
        b.start()
        defer { b.stop() }
        b.setRacksForTesting(allanRacks)
        let w = FakeWindow(sr, names: allanRacks.map(\.name))
        b.setRackReaderForTesting(w)
        var c = b.driverForTesting.config
        c.settle = 0
        b.driverForTesting.config = c
        let u = try XCTUnwrap(p.udps.first)
        b.select(rack: 8)
        b.driverForTesting.waitUntilIdle()
        settle(p)
        XCTAssertEqual(b.status.position, .seen(8))
        XCTAssertEqual(rack(u.messages), [.int(9), .string("Lec"), .string("seen")])

        w.stuck = "mains"
        b.select(rack: 3)
        b.driverForTesting.waitUntilIdle()
        settle(p)
        XCTAssertEqual(sr.rack, 3, "homed and counted when the window disagreed")
        XCTAssertEqual(b.status.position, .counted(3))
        XCTAssertEqual(rack(u.messages), [.int(4), .string("head 4"), .string("counted")])

        // One step is counted, whatever the window showed before it.
        w.stuck = nil
        b.send(.nextRack)
        b.driverForTesting.waitUntilIdle()
        settle(p)
        XCTAssertEqual(rack(u.messages), [.int(5), .string("hh 1"), .string("counted")])
    }

    /// Over ProLink: the link as it comes up, the racks SuperRack lists, and a rack it answered.
    func testProLinksLinkAndAnsweredRack() throws {
        var s = Settings()
        s.pluginHost = "superrack.prolink"
        s.stateFeedSettings = StateFeedSettings(enabled: true, host: "127.0.0.1", port: 9100)
        let p = TestPlatform()
        let b = Bridge(settings: s, sink: NullSink(), platform: p)
        b.start()
        defer { b.stop() }
        settle(p)
        let u = try XCTUnwrap(p.udps.first)
        XCTAssertEqual(u.messages.first { $0.address == A.link }?.args,
                       [.string("listening"), .string("listening on port 50002")])
        let l = p.listeners[0]
        let sr = FakeProLinkPeer(l.dial())
        sr.hello()
        for _ in 0..<30 { l.queue.sync {} }
        settle(p)
        XCTAssertEqual(u.messages.last { $0.address == A.link }?.args.first, .string("connected"))
        XCTAssertEqual(u.messages.last { $0.address == A.rackCount }?.args, [.int(16)])
        XCTAssertEqual(u.messages.last { $0.address == A.problem }?.args, [.string("")])
        b.select(rack: 9)
        for _ in 0..<30 { l.queue.sync {} }
        settle(p)
        XCTAssertEqual(sr.commands.last, "ShowRack 14")
        XCTAssertEqual(rack(u.messages)?.first, .int(10))
        XCTAssertEqual(rack(u.messages)?.last, .string("reported"))
    }

    // MARK: Settings

    func testTheTargetIsSavedOnlyOnceSet() throws {
        func keys(_ s: Settings) throws -> Set<String> {
            let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any]
            return Set(o?.keys.map { $0 } ?? [])
        }
        XCTAssertFalse(try keys(Settings()).contains("stateFeed"), "a file that never used it gains no key")
        var s = Settings()
        s.stateFeedSettings = StateFeedSettings(enabled: true, host: "10.0.0.7", port: 9100)
        XCTAssertTrue(try keys(s).contains("stateFeed"))
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).stateFeedSettings,
                       s.stateFeedSettings)
        s.stateFeedSettings = StateFeedSettings()
        XCTAssertFalse(try keys(s).contains("stateFeed"))
        // Each field reads on its own.
        let odd = #"{"stateFeed": {"enabled": true, "host": 7, "port": 9100}}"#
        let read = try JSONDecoder().decode(Settings.self, from: Data(odd.utf8)).stateFeedSettings
        XCTAssertEqual(read, StateFeedSettings(enabled: true, host: "127.0.0.1", port: 9100))
        // On with no address sends nothing.
        XCTAssertFalse(StateFeedSettings(enabled: true, host: "  ", port: 9021).sends)
        XCTAssertTrue(StateFeedSettings(enabled: true, host: "127.0.0.1", port: 9021).sends)
    }
}
