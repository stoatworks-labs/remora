import XCTest
@testable import RemoraCore

/// SuperRack as measured: one step per message whatever the value, stopping at both ends.
final class FakeSuperRack: CCSink {
    let channel: Int, base: Int, count: Int
    private let lock = NSLock()
    private var _rack: Int
    private(set) var log: [(Int, Int, Int)] = []
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
        switch number - base {
        case NavCommand.previousRack.rawValue: _rack = max(0, _rack - 1)
        case NavCommand.nextRack.rawValue: _rack = min(count - 1, _rack + 1)
        default: break
        }
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
