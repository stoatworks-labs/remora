import XCTest
@testable import RemoraApple
@testable import RemoraConsoles
@testable import RemoraCore
@testable import RemoraEngine
@testable import RemoraHosts
import SQLite3

/// SuperRack as measured: one step per message whatever the value, stopping at both ends.
final class FakeSuperRack: CCSink {
    let channel: Int, base: Int, count: Int
    private let lock = NSLock()
    private var _rack: Int
    private(set) var log: [(Int, Int, Int)] = []
    /// Rack steps this soon after Back to overview or Open rack page are lost, as the real one
    /// loses them within about 20 ms (docs/PROTOCOL.md). 0: never.
    var deafAfterPage: TimeInterval = 0
    private(set) var lostSteps = 0
    private var lastPage = Date.distantPast
    init(channel: Int = 16, base: Int = 20, count: Int, at: Int) {
        self.channel = channel
        self.base = base
        self.count = count
        _rack = at
    }
    var rack: Int { lock.lock(); defer { lock.unlock() }; return _rack }
    /// Moves it as a mouse click in SuperRack would.
    func click(_ r: Int) { lock.lock(); _rack = r; lock.unlock() }
    func sendCC(channel: Int, number: Int, value: Int) {
        lock.lock()
        defer { lock.unlock() }
        log.append((channel, number, value))
        guard channel == self.channel else { return }
        let c = NavCommand(rawValue: number - base)
        if c == .previousRack || c == .nextRack, Date().timeIntervalSince(lastPage) < deafAfterPage {
            lostSteps += 1
            return
        }
        switch c {
        case .previousRack: _rack = max(0, _rack - 1)
        case .nextRack: _rack = min(count - 1, _rack + 1)
        case .overview, .openRack: lastPage = Date()
        default: break
        }
    }
    /// SuperRack ignores Program Change (Follow Prg. Changes is None): recorded, nothing moves.
    private(set) var programs: [(Int, Int)] = []
    func sendProgramChange(channel: Int, program: Int) {
        lock.lock()
        defer { lock.unlock() }
        programs.append((channel, program))
    }
}

/// SuperRack's top bar as Accessibility reads it: the name of the rack the fake is on.
final class FakeWindow: RackNameReader {
    let sr: FakeSuperRack
    let names: [String]
    var canRead = true
    /// A window that cannot be trusted: shows this whatever the rack.
    var stuck: String?
    /// A window still changing: every read shows another rack.
    var flicker = false
    private(set) var reads = 0
    init(_ sr: FakeSuperRack, names: [String]) {
        self.sr = sr
        self.names = names
    }
    var canReadRackName: Bool { canRead }
    func readRackName() -> String? {
        reads += 1
        if flicker { return names[(sr.rack + reads) % names.count] }
        return stuck ?? names[sr.rack]
    }
}

func hex(_ s: String) -> [UInt8] { YamahaSysEx.bytes(hex: s.replacingOccurrences(of: " ", with: "")) }

let allanRacks = ["head 1", "head 2", "n/a", "head 4", "hh 1", "hh 2", "hh 3", "n/a", "Lec", "mains",
                  "Rack 11", "Rack 12", "Rack 13", "Rack 14", "Rack 15", "Rack 16"]
    .enumerated().map { Rack(index: $0.offset, name: $0.element) }

final class YamahaTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    func testSelectionCaptures() {
        // Captured from the QL1, 2026-11-05: SEL on ch 1, 5, 17, 25, MIX 1, ST IN 1.
        let cases: [(String, YamahaChannel)] = [
            ("f0 43 10 3e 19 01 03 00 00 12 00 00 00 00 00 00 00 f7", .input(1)),
            ("f0 43 10 3e 19 01 03 00 00 12 00 00 00 00 00 00 04 f7", .input(5)),
            ("f0 43 10 3e 19 01 03 00 00 12 00 00 00 00 00 00 10 f7", .input(17)),
            ("f0 43 10 3e 19 01 03 00 00 12 00 00 00 00 00 00 18 f7", .input(25)),
            ("f0 43 10 3e 19 01 03 00 00 12 00 00 00 00 00 00 58 f7", .mix(1)),
            ("f0 43 10 3e 19 01 03 00 00 12 00 00 00 00 00 00 48 f7", .stereoIn(1, right: false)),
            ("f0 43 10 3e 19 01 03 00 00 12 00 00 00 00 00 00 49 f7", .stereoIn(1, right: true)),
        ]
        for (h, want) in cases {
            let c = YamahaSysEx.parseChange(hex(h))
            XCTAssertEqual(c?.address, YamahaSysEx.selectedChannel, h)
            XCTAssertEqual(c.map { YamahaChannel(selection: Int($0.value)) }, want, h)
        }
    }

    func testValues() {
        // ON key of ch 18, on and off; fader of ch 21.
        XCTAssertEqual(YamahaSysEx.parseChange(hex("f0 43 10 3e 19 01 00 35 00 00 00 11 00 00 00 00 01 f7")),
                       .init(address: .init(element: 0x35, index: 0, channel: 17), value: 1))
        XCTAssertEqual(YamahaSysEx.parseChange(hex("f0 43 10 3e 19 01 00 37 00 00 00 14 00 00 00 00 53 f7"))?.value, 0x53)
        // −∞ on a fader: −32768 as five 7-bit bytes.
        XCTAssertEqual(YamahaSysEx.parseChange(hex("f0 43 10 3e 19 01 00 37 00 00 00 14 0f 7f 7e 00 00 f7"))?.value, -32768)
        XCTAssertNil(YamahaSysEx.parseChange(YamahaSysEx.heartbeat))
    }

    func testSplitKeepsPartialMessage() {
        var buf = hex("f0 43 10 3e 19 7f f7 f0 43 10 3e 19 01 03 00 00 12 00 00 00 00 00 00 11 f7 f0 43 10")
        let msgs = YamahaSysEx.split(&buf)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0], YamahaSysEx.heartbeat)
        XCTAssertEqual(buf, hex("f0 43 10"))
    }

    func testOnlyReadRequestsGoOut() {
        // The read the desk answered at 20:0x on 2026-11-05.
        XCTAssertEqual(YamahaSysEx.readRequest(YamahaSysEx.selectedChannel), hex("f043303e1901030000120000f7"))
        for m in YamahaSysEx.editorOpening + [YamahaSysEx.readRequest(YamahaSysEx.selectedChannel)] {
            XCTAssertTrue(YamahaSysEx.isReadRequest(m))
        }
        XCTAssertEqual(YamahaSysEx.editorOpening.count, 38)
        // A parameter change must never pass the guard.
        XCTAssertFalse(YamahaSysEx.isReadRequest(hex("f0 43 10 3e 19 01 00 35 00 00 00 11 00 00 00 00 01 f7")))
        XCTAssertFalse(YamahaSysEx.isReadRequest(YamahaSysEx.heartbeat))
    }

    func testChannelNumbering() {
        XCTAssertEqual(YamahaChannel(selection: 71), .input(72))
        XCTAssertEqual(YamahaChannel(selection: 87), .stereoIn(8, right: true))
        XCTAssertEqual(YamahaChannel(selection: 111), .mix(24))
        XCTAssertEqual(YamahaChannel(selection: 112), .other(112))
        XCTAssertEqual(YamahaChannel.stereoIn(2, right: true).rcpName?.index, 3)
        XCTAssertEqual(YamahaChannel.named.count, 112)
    }

    func testRCPQuoted() {
        XCTAssertEqual(YamahaRCPNames.quoted(#"OK get MIXER:Current/InCh/Label/Name 24 0 "lec 1""#), "lec 1")
        XCTAssertEqual(YamahaRCPNames.quoted(#"OK get MIXER:Current/InCh/Label/Name 24 0 """#), "")
    }
}

final class MatchTests: XCTestCase {
    func testAllansNames() {
        // The QL1's names and the SuperRack session's racks, 2026-11-05.
        let want: [String: String?] = [
            "head1": "head 1", "head2": "head 2", "head3": nil, "head4": "head 4",
            "hh1": "hh 1", "hh2": "hh 2", "hh3": "hh 3", "hh4": nil,
            "lec 1": "Lec", "lec 2": "Lec", "vt": nil, "ch 1": nil, "ch27": nil, "": nil,
        ]
        for (name, rack) in want {
            XCTAssertEqual(RackMatcher.match(name, in: allanRacks)?.name, rack, name)
        }
    }

    func testStemNeedsOneRack() {
        let racks = [Rack(index: 0, name: "Vox"), Rack(index: 1, name: "vox")]
        XCTAssertEqual(RackMatcher.match("vox", in: racks)?.index, 0)  // exact: the first
        XCTAssertNil(RackMatcher.match("vox 2", in: racks))            // stem: ambiguous
    }

    func testStereoHalvesAndOverrides() {
        var s = Settings()
        s.overrides = ["in1": 3, "stin2L": 9]
        let b = Bridge(settings: s, sink: FakeSuperRack(count: 16, at: 0))
        b.setRacksForTesting(allanRacks + [Rack(index: 16, name: "PB")])
        b.setNamesForTesting([.stereoIn(1, right: false): "PB L", .stereoIn(1, right: true): "PB R",
                              .input(1): "head1", .input(2): "head2"])
        XCTAssertEqual(b.rack(for: .stereoIn(1, right: false))?.name, "PB")
        XCTAssertEqual(b.rack(for: .stereoIn(1, right: true))?.name, "PB")
        XCTAssertEqual(b.rack(for: .input(1))?.name, "head 4")             // override beats the name
        XCTAssertEqual(b.rack(for: .input(2))?.name, "head 2")
        XCTAssertEqual(b.rack(for: .stereoIn(2, right: true))?.name, "mains") // R takes L's override
    }
}

final class DriverTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    func driver(_ sr: FakeSuperRack, _ mode: SuperRackDriver.Mode) -> SuperRackDriver {
        let d = SuperRackDriver(sink: sr)
        var c = SuperRackDriver.Config()
        c.spacing = 0
        c.mode = mode
        d.config = c
        d.rackCount = sr.count
        return d
    }

    func driver(_ sr: FakeSuperRack, _ mode: SuperRackDriver.Mode, window: FakeWindow?) -> SuperRackDriver {
        let d = driver(sr, mode)
        var c = d.config
        c.settle = 0
        d.config = c
        d.racks = allanRacks
        d.reader = window
        return d
    }

    func testLandsFromAnywhere() {
        for mode in SuperRackDriver.Mode.allCases {
            for start in [0, 7, 15] {
                for target in [0, 1, 8, 15] {
                    let sr = FakeSuperRack(count: 16, at: start)
                    let d = driver(sr, mode)
                    d.select(target)
                    d.waitUntilIdle()
                    XCTAssertEqual(sr.rack, target, "\(mode) \(start)→\(target)")
                    XCTAssertEqual(d.currentRack, target)
                }
            }
        }
    }

    func testHomeEveryTimeSurvivesClicks() {
        let sr = FakeSuperRack(count: 16, at: 4)
        let d = driver(sr, .homeEveryTime)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            if Bool.random(using: &rng) { sr.click(Int.random(in: 0..<16, using: &rng)) }
            let t = Int.random(in: 0..<16, using: &rng)
            d.select(t)
            d.waitUntilIdle()
            XCTAssertEqual(sr.rack, t)
        }
    }

    func testCountFromLastIsFastButTrustsItsCount() {
        let sr = FakeSuperRack(count: 16, at: 0)
        let d = driver(sr, .countFromLast)
        d.select(5)
        d.waitUntilIdle()
        let n = sr.log.count
        d.select(7)
        d.waitUntilIdle()
        XCTAssertEqual(sr.log.count - n, 2)  // just the difference
        sr.click(12)                          // someone clicks in SuperRack
        d.select(8)
        d.waitUntilIdle()
        XCTAssertEqual(sr.rack, 13)           // wrong, as documented…
        d.resync()
        d.waitUntilIdle()
        d.select(8)
        d.waitUntilIdle()
        XCTAssertEqual(sr.rack, 8)            // …until Resync
    }

    func testHomingSendsOnePreviousPerRack() {
        let sr = FakeSuperRack(count: 16, at: 9)
        let d = driver(sr, .homeEveryTime)
        d.select(2)
        d.waitUntilIdle()
        XCTAssertEqual(sr.log.map(\.1), Array(repeating: 20, count: 16) + [22, 22])
        XCTAssertTrue(sr.log.allSatisfy { $0.0 == 16 && $0.2 == 127 })
    }

    func testStepsAndOtherCommandsKeepTheCount() {
        let sr = FakeSuperRack(count: 16, at: 3)
        let d = driver(sr, .countFromLast)
        d.select(3)
        d.send(.nextRack)
        d.send(.nextRack)
        d.send(.openRack)
        d.send(.previousRack)
        d.waitUntilIdle()
        XCTAssertEqual(sr.rack, 4)
        XCTAssertEqual(d.currentRack, 4)
        XCTAssertEqual(sr.log.last.map(\.1), 20)
    }

    func testFollowThroughTheBridge() {
        let sr = FakeSuperRack(count: 16, at: 11)
        var s = Settings()
        s.stepMilliseconds = 0
        let b = Bridge(settings: s, sink: sr)
        b.setRacksForTesting(allanRacks)
        b.setNamesForTesting([.input(17): "head1", .input(18): "head2", .input(25): "lec 1", .input(1): "ch 1"])
        func sel(_ i: Int32) {
            b.consoleChangeForTesting(.init(address: YamahaSysEx.selectedChannel, value: i))
            b.driverForTesting.waitUntilIdle()
        }
        sel(17); XCTAssertEqual(sr.rack, 1)   // head2 → head 2
        sel(24); XCTAssertEqual(sr.rack, 8)   // lec 1 → Lec
        sel(0); XCTAssertEqual(sr.rack, 8)    // ch 1 has no rack: stay
        sel(16); XCTAssertEqual(sr.rack, 0)   // head1 → head 1
    }

    func testResyncGoesBackToTheSelectedChannelsRack() {
        let sr = FakeSuperRack(count: 16, at: 0)
        var s = Settings()
        s.stepMilliseconds = 0
        s.mode = .countFromLast
        let b = Bridge(settings: s, sink: sr)
        b.setRacksForTesting(allanRacks)
        b.setNamesForTesting([.input(25): "lec 1"])
        b.consoleChangeForTesting(.init(address: YamahaSysEx.selectedChannel, value: 24))
        b.driverForTesting.waitUntilIdle()
        XCTAssertEqual(sr.rack, 8)            // lec 1 → Lec
        sr.click(12)                          // someone clicks in SuperRack
        b.resync()
        b.driverForTesting.waitUntilIdle()
        XCTAssertEqual(sr.rack, 8)            // back to Lec, not rack 1
    }
}

final class RackSightingTests: XCTestCase {
    func testANameOneRackHasIsWhereItIs() {
        XCTAssertEqual(RackSighting.candidates("Lec", in: allanRacks, count: 16), [8])
        XCTAssertEqual(RackSighting.position(seen: "Lec", counted: nil, racks: allanRacks, count: 16), 8)
        // It beats a count: someone clicked.
        XCTAssertEqual(RackSighting.position(seen: "Lec", counted: 3, racks: allanRacks, count: 16), 8)
        // Exact names: SuperRack shows the rack's own.
        XCTAssertEqual(RackSighting.candidates("lec", in: allanRacks, count: 16), [])
        XCTAssertEqual(RackSighting.candidates("head 1", in: allanRacks, count: 16), [0])
    }

    func testASharedNameOnlyKeepsACountThatFits() {
        XCTAssertEqual(RackSighting.candidates("n/a", in: allanRacks, count: 16), [2, 7])
        XCTAssertEqual(RackSighting.position(seen: "n/a", counted: 7, racks: allanRacks, count: 16), 7)
        XCTAssertEqual(RackSighting.position(seen: "n/a", counted: 2, racks: allanRacks, count: 16), 2)
        XCTAssertNil(RackSighting.position(seen: "n/a", counted: 5, racks: allanRacks, count: 16))
        XCTAssertNil(RackSighting.position(seen: "n/a", counted: nil, racks: allanRacks, count: 16))
    }

    func testANameTheSessionDoesNotHaveIsNoPosition() {
        // A rack renamed since the session was read.
        XCTAssertNil(RackSighting.position(seen: "head 4b", counted: nil, racks: allanRacks, count: 16))
        XCTAssertNil(RackSighting.position(seen: "head 4b", counted: 3, racks: allanRacks, count: 16))
        // Only racks inside the session's rack count.
        XCTAssertNil(RackSighting.position(seen: "Rack 16", counted: nil, racks: allanRacks, count: 12))
    }
}

final class WindowDriverTests: XCTestCase {
    override func setUp() { Log.enabled = false }
    let names = allanRacks.map(\.name)

    func make(at start: Int, _ mode: SuperRackDriver.Mode) -> (FakeSuperRack, FakeWindow, SuperRackDriver) {
        let sr = FakeSuperRack(count: 16, at: start)
        let w = FakeWindow(sr, names: names)
        let d = DriverTests().driver(sr, mode, window: w)
        return (sr, w, d)
    }

    func testGoesStraightThereWithoutHoming() {
        for mode in SuperRackDriver.Mode.allCases {
            for (start, target) in [(4, 8), (8, 0), (15, 14), (0, 15), (5, 5)] {
                let (sr, _, d) = make(at: start, mode)
                d.select(target)
                d.waitUntilIdle()
                XCTAssertEqual(sr.rack, target, "\(mode) \(start)→\(target)")
                XCTAssertEqual(sr.log.count, abs(target - start), "\(mode) \(start)→\(target)")
                XCTAssertEqual(d.currentRack, target)
            }
        }
    }

    func testStaysRightAfterClicks() {
        for mode in SuperRackDriver.Mode.allCases {
            let (sr, _, d) = make(at: 4, mode)
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<200 {
                if Bool.random(using: &rng) { sr.click(Int.random(in: 0..<16, using: &rng)) }
                let t = Int.random(in: 0..<16, using: &rng)
                let from = sr.rack, n = sr.log.count
                d.select(t)
                d.waitUntilIdle()
                XCTAssertEqual(sr.rack, t, "\(mode)")
                // Only an n/a start homes.
                if ![2, 7].contains(from) { XCTAssertEqual(sr.log.count - n, abs(t - from), "\(mode) \(from)→\(t)") }
            }
        }
    }

    func testCountFromLastNoLongerGoesWrongAfterAClick() {
        // testCountFromLastIsFastButTrustsItsCount, with the window.
        let (sr, _, d) = make(at: 0, .countFromLast)
        d.select(5)
        d.waitUntilIdle()
        sr.click(12)
        let n = sr.log.count
        d.select(8)
        d.waitUntilIdle()
        XCTAssertEqual(sr.rack, 8)
        XCTAssertEqual(sr.log.count - n, 4)   // 12 → 8
    }

    func testASharedNameHomesAndCounts() {
        // On the second "n/a" (rack 8), unseen: the name could be rack 3 or rack 8.
        let (sr, _, d) = make(at: 7, .homeEveryTime)
        d.select(8)
        d.waitUntilIdle()
        XCTAssertEqual(sr.rack, 8)
        XCTAssertEqual(sr.log.map(\.1), Array(repeating: 20, count: 16) + Array(repeating: 22, count: 8))
    }

    func testASharedNameKeepsACountThatFits() {
        let (sr, _, d) = make(at: 0, .countFromLast)
        d.select(7)
        d.waitUntilIdle()
        let n = sr.log.count
        d.select(8)
        d.waitUntilIdle()
        XCTAssertEqual(sr.rack, 8)
        XCTAssertEqual(sr.log.count - n, 1)
    }

    func testAClickBetweenSharedNamesIsCaughtOnLanding() {
        // Counted to the first n/a (3); someone clicks the other (8). Nothing at the start can tell.
        let (sr, _, d) = make(at: 0, .countFromLast)
        d.select(2)
        d.waitUntilIdle()
        sr.click(7)
        let n = sr.log.count
        d.select(8)
        d.waitUntilIdle()
        // Six Next from the count land on 14 ("Rack 14", not "Lec"), so it homes and counts once.
        XCTAssertEqual(sr.rack, 8)
        XCTAssertEqual(sr.log.count - n, 6 + 16 + 8)
    }

    func testARenamedRackIsCounted() {
        // The session still says "head 4"; SuperRack shows the new name.
        let sr = FakeSuperRack(count: 16, at: 3)
        var shown = allanRacks.map(\.name)
        shown[3] = "head 4b"
        let d = DriverTests().driver(sr, .homeEveryTime, window: FakeWindow(sr, names: shown))
        d.select(5)
        d.waitUntilIdle()
        XCTAssertEqual(sr.rack, 5)
        XCTAssertEqual(sr.log.count, 16 + 5)
    }

    func testAWindowThatCannotBeTrustedFallsBackToCounting() {
        let (sr, w, d) = make(at: 4, .homeEveryTime)
        w.stuck = "head 1"
        d.select(8)
        d.waitUntilIdle()
        // Believed rack 1, so eight Next went to 13; the landing shows the wrong name: home, count.
        XCTAssertEqual(sr.rack, 8)
        XCTAssertEqual(sr.log.count, 8 + 16 + 8)
        // Disagreed after counting: the window is not used for a start until it agrees.
        let n = sr.log.count
        d.select(3)
        d.waitUntilIdle()
        XCTAssertEqual(sr.rack, 3)
        XCTAssertEqual(sr.log.count - n, 16 + 3)
        // It shows the truth again: that landing agrees, and the next move goes straight there.
        w.stuck = nil
        d.select(5)
        d.waitUntilIdle()
        let m = sr.log.count
        d.select(9)
        d.waitUntilIdle()
        XCTAssertEqual(sr.rack, 9)
        XCTAssertEqual(sr.log.count - m, 4)
    }

    func testAWindowThatWillNotHoldStillIsNotUsed() {
        let (sr, w, d) = make(at: 4, .homeEveryTime)
        w.flicker = true
        d.select(8)
        d.waitUntilIdle()
        XCTAssertEqual(sr.rack, 8)
        XCTAssertEqual(sr.log.count, 16 + 8)
        XCTAssertGreaterThan(w.reads, 2)
    }

    func testWithoutAccessibilityNothingChanges() {
        // No reader, and a reader that cannot read (no grant, SuperRack not running): the MIDI is
        // exactly what the driver sent before it could read the window, and the window is never read.
        for mode in SuperRackDriver.Mode.allCases {
            var logs: [[Int]] = []
            for variant in 0..<3 {
                let sr = FakeSuperRack(count: 16, at: 9)
                let w = FakeWindow(sr, names: names)
                w.canRead = false
                let d: SuperRackDriver
                switch variant {
                case 0: d = DriverTests().driver(sr, mode)
                case 1: d = DriverTests().driver(sr, mode, window: nil)
                default: d = DriverTests().driver(sr, mode, window: w)
                }
                for t in [2, 8, 8, 0] {
                    d.select(t)
                    d.waitUntilIdle()
                    sr.click(12)
                }
                d.resync()
                d.waitUntilIdle()
                logs.append(sr.log.map(\.1))
                XCTAssertEqual(w.reads, 0)
            }
            XCTAssertEqual(logs[0], logs[1], "\(mode)")
            XCTAssertEqual(logs[0], logs[2], "\(mode)")
        }
    }

    func testResyncStillHomesByCounting() {
        let (sr, _, d) = make(at: 9, .homeEveryTime)
        d.resync()
        d.waitUntilIdle()
        XCTAssertEqual(sr.rack, 0)
        XCTAssertEqual(sr.log.map(\.1), Array(repeating: 20, count: 16))
    }

    func testFollowThroughTheBridgeWithTheWindow() {
        let sr = FakeSuperRack(count: 16, at: 11)
        var s = Settings()
        s.stepMilliseconds = 0
        let b = Bridge(settings: s, sink: sr)
        b.setRacksForTesting(allanRacks)
        b.setRackReaderForTesting(FakeWindow(sr, names: names))
        var c = b.driverForTesting.config
        c.settle = 0
        b.driverForTesting.config = c
        b.setNamesForTesting([.input(17): "head1", .input(18): "head2", .input(25): "lec 1"])
        func sel(_ i: Int32) {
            b.consoleChangeForTesting(.init(address: YamahaSysEx.selectedChannel, value: i))
            b.driverForTesting.waitUntilIdle()
        }
        sel(17); XCTAssertEqual(sr.rack, 1); XCTAssertEqual(sr.log.count, 10)    // 12 → 2
        sel(24); XCTAssertEqual(sr.rack, 8); XCTAssertEqual(sr.log.count, 17)    // → 9
        sr.click(14)
        sel(16); XCTAssertEqual(sr.rack, 0); XCTAssertEqual(sr.log.count, 31)    // 15 → 1
    }

    func testSettingsReadTheWindowByDefault() throws {
        XCTAssertTrue(Settings().readRackFromWindow)
        XCTAssertTrue(Settings().pluginWindowOptions.readRack)
        // An older file without the key.
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"mode": "countFromLast"}"#.utf8))
        XCTAssertTrue(old.readRackFromWindow)
        var s = Settings()
        s.readRackFromWindow = false
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).readRackFromWindow)
        // Reading the rack alone does nothing to plug-in windows (and so never asks for Accessibility).
        XCTAssertFalse(PluginWindowGuard.Options(readRack: true).windows)
        XCTAssertTrue(PluginWindowGuard.Options(readRack: true).any)
    }
}

final class MappingTests: XCTestCase {
    func testMatchesSuperRacksOwnExport() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/superrack-export.mrrc")
        let exported = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(SuperRackMapping.mrrc(channel: 16, ccBase: 20), exported)
    }
}

final class OSCTests: XCTestCase {
    func testRoundTrip() {
        let m = OSC.Message(address: "/remora/rack/select", args: [.string("head 1"), .int(3), .float(0.5)])
        XCTAssertEqual(OSC.parse(OSC.encode(m)), [m])
    }

    func testBundle() {
        let a = OSC.encode(.init(address: "/remora/rack/next", args: []))
        let b = OSC.encode(.init(address: "/remora/follow", args: [.int(0)]))
        var bundle = Array("#bundle".utf8) + [0] + [UInt8](repeating: 0, count: 8)
        for e in [a, b] {
            bundle += [0, 0, 0, UInt8(e.count)] + e
        }
        XCTAssertEqual(OSC.parse(bundle).map(\.address), ["/remora/rack/next", "/remora/follow"])
    }
}

final class SettingsTests: XCTestCase {
    func testOldFilesLoad() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"consoleHost":"10.0.0.5"}"#.utf8))
        XCTAssertEqual(s.consoleHost, "10.0.0.5")
        XCTAssertEqual(s.midiChannel, 16)
        XCTAssertEqual(s.ccBase, 20)
        XCTAssertEqual(s.mode, .homeEveryTime)
    }

    func testRoundTrip() throws {
        var s = Settings()
        var m = ControlMapping()
        m.source = .yamaha(.init(element: 0x37, index: 0, channel: 30))
        m.action = .sendCC
        m.mode = .value
        s.controls = [m]
        s.overrides = ["in17": 0]
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testControlScaling() {
        var m = ControlMapping()
        m.mode = .value
        m.observe(-32768) // fader at −∞: not part of the range
        XCTAssertNil(m.low)
        m.observe(-13800)
        m.observe(1000)
        XCTAssertEqual(m.ccValue(for: -13800), 0)
        XCTAssertEqual(m.ccValue(for: 1000), 127)
        XCTAssertEqual(m.ccValue(for: -32768), 0)
        m.mode = .onOff
        XCTAssertEqual(m.ccValue(for: 1), 127)
        XCTAssertEqual(m.ccValue(for: 0), 0)
    }
}

/// SuperRack Performer 15.15.12.13's application log, lines copied from Allan's Mac 2026-11-05.
let superRackLogLines = """
2026-Nov-05 21:33:36.932061 @[ipd...] [4bd8:-           ] [INF] [general     ] @[WCTopBar_Base.cpp:138] [] Top Bar: select RACK @[InnerProcessDictionary.dylib]
2026-Nov-05 21:33:37.971071 @[wl....] [4bd8:-           ] [INF] [general     ] @[MixerChainerCore.cpp:4554] [] head 1 plugin De-Feedback slot 2 select @[WavesLib]
2026-Nov-05 16:43:07.579350 @[ipd...] [4bd8:-           ] [INF] [general     ] @[WCTopBar_Base.cpp:138] [] Top Bar: select OVERVIEW1 @[InnerProcessDictionary.dylib]
2026-Nov-05 19:54:42.678893 @[ipd...] [4bd8:-           ] [INF] [general     ] @[WCTopBar_MR.cpp:2322] [] Top Bar: select rack 1 @[InnerProcessDictionary.dylib]
2026-Nov-05 16:51:19.887585 @[wl....] [4bd8:-           ] [INF] [general     ] @[MixerChainerCore.cpp:4554] [] head 1 plugin Pro-Q 4 slot 3 select @[WavesLib]
2026-Nov-05 21:06:56.132361 @[wl....] [4bd8:-           ] [INF] [general     ] @[MixerChainerCore.cpp:4554] [] hh 1 plugin PSE slot 1 select @[WavesLib]
2026-Oct-18 19:27:19.630805 @[wl....] [fbd8:-           ] [INF] [general     ] @[MixerChainerCore.cpp:27211] [] lec 1 plugin De-Feedback slot 2 IN off @[WavesLib]
2026-Nov-05 12:22:46.081080 @[wl....] [6600:JobS(05)    ] [INF] [general     ] @[MixerChainerCore.cpp:7350] [] Rack 2 add plugin De-Feedback to slot 2 @[WavesLib]
2026-Nov-05 19:45:51.612143 @[ipd...] [8600:sfc         ] [INF] [general     ] @[WCMapperOverview_App.cpp:11946] [] Overview 1: select mode rack @[InnerProcessDictionary.dylib]
2026-Nov-05 20:16:22.296326 @[dyld..] [b600:sfc         ] [INF] [general     ] @[PhMIDIMapper.cpp:220] [] MIDI: select port Remora on @[dyld]
"""

final class SuperRackLogTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    func testEvents() {
        let events = superRackLogLines.split(separator: "\n").map { SuperRackLogParser.parse(String($0))?.event }
        XCTAssertEqual(events, [
            .page("RACK"),
            .pluginSelected(rack: "head 1", plugin: "De-Feedback", slot: 2),
            .page("OVERVIEW1"),
            .rackPicked(1),
            .pluginSelected(rack: "head 1", plugin: "Pro-Q 4", slot: 3),
            .pluginSelected(rack: "hh 1", plugin: "PSE", slot: 1),
            nil, nil, nil, nil,  // bypass, add, overview mode, MIDI port: not events
        ])
    }

    func testTimeToTheMicrosecond() throws {
        let l = try XCTUnwrap(SuperRackLogParser.parse(String(superRackLogLines.split(separator: "\n")[1])))
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: l.time)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 11, 5, 21, 33, 37])
        XCTAssertEqual(Double(c.nanosecond!) / 1e9, 0.971071, accuracy: 1e-5)
    }

    func testTailReadsOnlyWhatIsNewAndWholeLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remora-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = superRackLogLines.split(separator: "\n").map(String.init)
        try (lines[0] + "\n").write(to: url, atomically: false, encoding: .utf8)
        let q = DispatchQueue(label: "test.tail")
        let tail = SuperRackLogTail(path: url.path, queue: q)
        var got: [SuperRackLogEvent] = []
        tail.onLine = { got.append($0.event) }
        tail.start()
        q.sync {}
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        // A line written in two pieces arrives once, whole.
        let second = lines[1]
        h.write(second.prefix(40).data(using: .utf8)!)
        tail.check()
        q.sync {}
        XCTAssertEqual(got, [])
        h.write((second.dropFirst(40) + "\n" + lines[5] + "\n").data(using: .utf8)!)
        try h.close()
        tail.check()
        q.sync {}
        XCTAssertEqual(got, [.pluginSelected(rack: "head 1", plugin: "De-Feedback", slot: 2),
                             .pluginSelected(rack: "hh 1", plugin: "PSE", slot: 1)])
        tail.stop()
        q.sync {}
    }
}

final class PluginWindowTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    func w(_ title: String, pinned: Bool = false, at s: TimeInterval = 0) -> PluginWindow {
        PluginWindow(title: title, pinned: pinned, appeared: t0.addingTimeInterval(s))
    }

    func testWavesPluginSelectedClosesTheThirdPartyWindow() {
        // As run 2026-11-05: De-Feedback open on head 1, PSE (Waves) selected.
        let open = [w("head 1: De-Feedback")]
        XCTAssertEqual(PluginWindowPolicy.toClose(open, after: .plugin(rack: "head 1", plugin: "PSE"), at: t0 + 5), [0])
        XCTAssertEqual(PluginWindowPolicy.toClose(open, after: .plugin(rack: "head 1", plugin: "De-Feedback"), at: t0 + 5), [])
    }

    func testAnotherRackClosesTheOldRacksWindows() {
        let open = [w("head 1: Pro-Q 4"), w("head 2: Pro-C 3")]
        XCTAssertEqual(PluginWindowPolicy.toClose(open, after: .rack("head 2"), at: t0 + 5), [0])
        // "head 1" is not "head 10"'s prefix: the ": " is part of it.
        XCTAssertEqual(PluginWindowPolicy.toClose([w("head 10: Pro-Q 4")], after: .rack("head 1"), at: t0 + 5), [0])
    }

    func testLeavingTheRackPageClosesEverythingUnpinned() {
        let open = [w("head 1: Pro-C 3"), w("head 1: De-Feedback", pinned: true)]
        XCTAssertEqual(PluginWindowPolicy.toClose(open, after: .page("OVERVIEW1"), at: t0 + 5), [0])
        XCTAssertEqual(PluginWindowPolicy.toClose(open, after: .page("RACK"), at: t0 + 5), [])
    }

    func testPinnedWindowsAndLaterWindowsStay() {
        let open = [w("head 1: De-Feedback", pinned: true), w("head 2: Pro-C 3", at: 10)]
        // The change happened at 5; Pro-C 3 opened at 10, after it.
        XCTAssertEqual(PluginWindowPolicy.toClose(open, after: .rack("n/a"), at: t0 + 5), [])
        XCTAssertEqual(PluginWindowPolicy.toClose(open, after: .rack("n/a"), at: t0 + 11), [1])
    }

    func testOneWindowAtATime() {
        let open = [w("head 1: Pro-Q 4"), w("head 1: Pro-C 3", at: 10)]
        XCTAssertEqual(PluginWindowPolicy.toClose(open, after: .opened(title: "head 1: Pro-C 3"), at: t0 + 10), [0])
    }

    func testPlacementMeasured() {
        // SuperRack's main window at 103,153, 1850 × 1034; positions as placed live 2026-11-05.
        let main = CGRect(x: 103, y: 153, width: 1850, height: 1034)
        XCTAssertEqual(PluginWindowPolicy.placement(of: CGSize(width: 840, height: 552), inMainWindow: main), CGPoint(x: 520, y: 280))
        XCTAssertEqual(PluginWindowPolicy.placement(of: CGSize(width: 550, height: 582), inMainWindow: main), CGPoint(x: 665, y: 280))
        // Wider than the area (Pro-Q 4): starts at its left edge.
        XCTAssertEqual(PluginWindowPolicy.placement(of: CGSize(width: 1350, height: 842), inMainWindow: main), CGPoint(x: 431, y: 280))
    }

    func testSettingsKeepTheOptions() throws {
        var s = Settings()
        XCTAssertFalse(s.pluginWindowOptions.windows)
        s.closePluginWindows = true
        s.placePluginWindows = true
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.pluginWindowOptions, PluginWindowGuard.Options(close: true, place: true, readRack: true))
    }

    func testHidingIsOffByDefaultAndKept() throws {
        XCTAssertFalse(Settings().hidePluginWindowsInBackground)
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"closePluginWindows": true}"#.utf8))
        XCTAssertFalse(old.hidePluginWindowsInBackground)
        var s = Settings()
        s.hidePluginWindowsInBackground = true
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.pluginWindowOptions, PluginWindowGuard.Options(readRack: true, hide: true))
        // Hiding works on plug-in windows, so it needs the log and Accessibility like the others.
        XCTAssertTrue(PluginWindowGuard.Options(hide: true).windows)
    }

    func testHidingHidesSuperRackOnlyWhenAWindowWouldFloatOverAnotherApp() {
        let open = [w("head 1: Pro-Q 4"), w("head 1: De-Feedback", pinned: true)]
        // Behind, with plug-in windows on screen: pinned ones float over other apps too.
        XCTAssertTrue(PluginWindowPolicy.hidesSuperRack(open, superRackInFront: false, superRackHidden: false))
        XCTAssertTrue(PluginWindowPolicy.hidesSuperRack([open[1]], superRackInFront: false, superRackHidden: false))
        // In front, already hidden, or nothing on screen: SuperRack is left as it is.
        XCTAssertFalse(PluginWindowPolicy.hidesSuperRack(open, superRackInFront: true, superRackHidden: false))
        XCTAssertFalse(PluginWindowPolicy.hidesSuperRack(open, superRackInFront: false, superRackHidden: true))
        XCTAssertFalse(PluginWindowPolicy.hidesSuperRack([], superRackInFront: false, superRackHidden: false))
        // A window someone minimised is in the Dock, floating over nothing.
        let docked = [PluginWindow(title: "head 2: Pro-C 3", minimised: true)]
        XCTAssertFalse(PluginWindowPolicy.hidesSuperRack(docked, superRackInFront: false, superRackHidden: false))
    }

    func testAMinimisedWindowIsNeverClosed() {
        // Close on a minimised window takes the plug-in out of the rack and leaves an empty frame
        // (2026-11-06), whoever minimised it. Remora never minimises one.
        XCTAssertTrue(PluginWindowPolicy.canClose(w("head 1: Pro-Q 4")))
        XCTAssertTrue(PluginWindowPolicy.canClose(w("head 1: De-Feedback", pinned: true)))  // pinning is toClose's rule
        XCTAssertFalse(PluginWindowPolicy.canClose(PluginWindow(title: "head 1: Pro-C 3", minimised: true)))
    }
}

/// Allan's session as read 2026-11-05: every rack has PSE, De-Feedback, Pro-Q 4, Pro-C 3.
func allanChain(_ index: Int, _ name: String, selected: Int?) -> RackChain {
    RackChain(index: index, name: name, selectedSlot: selected, plugins: [
        ChainPlugin(slot: 1, name: "PSE", vendor: "Waves"),
        ChainPlugin(slot: 2, name: "De-Feedback", vendor: "Alpha Labs LLC"),
        ChainPlugin(slot: 3, name: "Pro-Q 4", vendor: "FabFilter"),
        ChainPlugin(slot: 4, name: "Pro-C 3", vendor: "FabFilter"),
    ])
}

final class ReopenTests: XCTestCase {
    // head 1 on PSE, head 2 on Pro-C 3, "n/a" with nothing selected: as tested live.
    let chains = [allanChain(0, "head 1", selected: 1), allanChain(1, "head 2", selected: 4),
                  allanChain(2, "n/a", selected: nil), allanChain(7, "n/a", selected: 3)]

    func testOnlyAThirdPartySelectionIsShown() {
        XCTAssertEqual(PluginWindowPolicy.reopenTarget(rack: "head 2", chains: chains, live: nil)?.name, "Pro-C 3")
        XCTAssertNil(PluginWindowPolicy.reopenTarget(rack: "head 1", chains: chains, live: nil))  // PSE docks
        XCTAssertNil(PluginWindowPolicy.reopenTarget(rack: "nowhere", chains: chains, live: nil))
    }

    func testTheLogBeatsTheDatabase() {
        XCTAssertEqual(PluginWindowPolicy.reopenTarget(rack: "head 1", chains: chains, live: "Pro-Q 4")?.name, "Pro-Q 4")
        XCTAssertNil(PluginWindowPolicy.reopenTarget(rack: "head 2", chains: chains, live: "PSE"))
    }

    func testRacksSharingANameMustAgree() {
        XCTAssertNil(PluginWindowPolicy.reopenTarget(rack: "n/a", chains: chains, live: nil))
    }

    func testSessionChainsFromTheDatabase() throws {
        // The tables and columns Remora reads, as in SuperRack 15.15's CurrentSPRKP.dat.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remora-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("CurrentSPRKP.dat").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let sql = """
            create table config_info (track_type integer, num_tracks integer);
            create table object (id integer primary key, obj_type integer, obj_index integer);
            create table snapshot_chainer (chainer_id integer, snapshot_id integer, name text, selected_slot integer default -1);
            create table plug (chainer_id integer, slot integer, plugin_name text, vendor_name text);
            insert into config_info values (0, 2);
            insert into object values (10, 0, 0), (11, 0, 1), (12, 0, 2);
            insert into snapshot_chainer values (10, -1, 'head 1', 1), (11, -1, 'head 2', 4), (12, -1, 'beyond', 1),
                                                (10, 3, 'head 1 in a snapshot', 2);
            insert into plug values (10, 0, 'PSE', 'Waves'), (10, 1, 'De-Feedback', 'Alpha Labs LLC'),
                                    (11, 0, 'PSE', 'Waves'), (11, 3, 'Pro-C 3', 'FabFilter');
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let c = try SuperRackSession.read(at: path)
        XCTAssertEqual(c.racks, [Rack(index: 0, name: "head 1"), Rack(index: 1, name: "head 2")])
        XCTAssertEqual(c.chains.map(\.selected?.name), ["PSE", "Pro-C 3"])
        XCTAssertEqual(c.chains[0].plugins.map(\.slot), [1, 2])  // plug.slot is 0-based
        XCTAssertEqual(c.chains[1].selected?.isWaves, false)
    }

    func testSettingsKeepReopen() throws {
        var s = Settings()
        s.reopenPluginAfterRackChange = true
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.pluginWindowOptions, PluginWindowGuard.Options(reopen: true, readRack: true))
        // Reopening acts on plug-in windows: it needs the log and asks for Accessibility.
        XCTAssertTrue(back.pluginWindowOptions.windows)
    }
}
