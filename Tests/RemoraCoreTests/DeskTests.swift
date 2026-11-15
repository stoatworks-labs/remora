import XCTest
@testable import RemoraConsoles
@testable import RemoraCore
@testable import RemoraEngine

/// Stage 4's desks, from documents (docs/PROTOCOL.md): the X32/M32 and Wing over OSC, the RIVAGE
/// PM over RCP, Avantis, and the CL listed apart from the QL. None has met a desk.
final class BehringerTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    private func osc(_ address: String, _ args: OSC.Arg...) -> [UInt8] {
        OSC.encode(OSC.Message(address: address, args: args))
    }

    private func addresses(_ sent: [[UInt8]]) -> [String] { sent.compactMap { OSC.parse($0).first?.address } }

    func testX32FollowsTheSelectionAndReadsNames() {
        let p = TestPlatform()
        let x = BehringerConsole(family: .x32, host: "10.0.0.20", platform: p)
        var states: [ConsoleState] = [], model: String?, selected: [ConsoleChannel] = []
        var names: [ConsoleChannel: String] = [:]
        let named = expectation(description: "names")
        x.onState = { states.append($0) }
        x.onModel = { model = $0 }
        x.onSelected = { selected.append($0) }
        x.onNames = { names = $0; named.fulfill() }
        x.start()
        defer { x.stop() }
        let udp = p.udps[0]
        XCTAssertEqual(udp.port, 10023)
        // Until the desk answers, it is only asked what it is.
        x.receiveForTesting([])
        XCTAssertEqual(states, [.waitingForDesk])
        XCTAssertEqual(addresses(udp.sent), ["/info"])

        x.receiveForTesting(osc("/info", .string("V2.05"), .string("osc-server"), .string("X32C"), .string("4.06")))
        XCTAssertEqual(states, [.waitingForDesk, .live])
        XCTAssertEqual(model, "X32C 4.06")
        XCTAssertEqual(addresses(udp.sent).last, "/-stat/selidx")

        for i: Int32 in [5, 5, 33, 70] { x.receiveForTesting(osc("/-stat/selidx", .int(i))) }
        XCTAssertEqual(selected, [.input(6), .aux(2), .main(1)])

        x.receiveForTesting(osc("/ch/01/config/name", .string("Kick")))
        x.receiveForTesting(osc("/ch/02/config/name", .string("")))
        x.receiveForTesting(osc("/bus/03/config/name", .string("Mon 3")))
        x.receiveForTesting(osc("/main/st/config/name", .string("LR")))
        wait(for: [named], timeout: 2)
        XCTAssertEqual(names, [.input(1): "Kick", .mix(3): "Mon 3", .main(1): "LR"])
        XCTAssertTrue(udp.sent.allSatisfy { BehringerOSC.isReadRequest($0, .x32) })
    }

    func testWingFollowsTheSelectionAndReadsNames() {
        let p = TestPlatform()
        let w = BehringerConsole(family: .wing, host: "10.0.0.21", platform: p)
        var model: String?, selected: [ConsoleChannel] = [], names: [ConsoleChannel: String] = [:]
        let named = expectation(description: "names")
        w.onModel = { model = $0 }
        w.onSelected = { selected.append($0) }
        w.onNames = { names = $0; named.fulfill() }
        w.start()
        defer { w.stop() }
        let udp = p.udps[0]
        XCTAssertEqual(udp.port, 2223)
        w.receiveForTesting(osc("/?", .string("WING,192.168.1.71,PGM,wing-compact,NO_SERIAL,3.0.5-0-g0c2b9d4a:release")))
        XCTAssertEqual(model, "Wing Compact 3.0.5")
        // A Wing answers a get with the text, the raw float and the int: the int counts.
        w.receiveForTesting(osc("/$ctl/$stat/selidx", .string("6"), .float(5), .int(5)))
        w.receiveForTesting(osc("/$ctl/$stat/selidx", .float(44)))
        w.receiveForTesting(osc("/$ctl/$stat/selidx", .int(65)))
        XCTAssertEqual(selected, [.input(6), .aux(5), .main(2)])
        w.receiveForTesting(osc("/ch/1/name", .string("Kick")))
        w.receiveForTesting(osc("/mtx/8/name", .string("Delay")))
        wait(for: [named], timeout: 2)
        XCTAssertEqual(names, [.input(1): "Kick", .matrix(8): "Delay"])
        XCTAssertTrue(udp.sent.allSatisfy { BehringerOSC.isReadRequest($0, .wing) })
        XCTAssertEqual(addresses(udp.sent).first, "/?")
    }

    /// A Wing channel or aux with custom link on ("Link Customization to Source") shows its input
    /// source's name and its own stays empty, so Remora follows the link to the source's name. A Wing
    /// Compact user saw only InCh 1, InCh 2… with the link on (2026-11-15).
    func testWingLinkedChannelsShowTheirSourcesNames() {
        let p = TestPlatform()
        let w = BehringerConsole(family: .wing, host: "10.0.0.21", platform: p)
        var names: [ConsoleChannel: String] = [:]
        w.onNames = { names = $0 }
        w.start()
        defer { w.stop() }
        let udp = p.udps[0]
        func sent() -> [String] { udp.queue.sync { addresses(udp.sent) } }
        func current() -> [ConsoleChannel: String] { udp.queue.sync { names } }
        func until(_ what: String, _ ok: () -> Bool) {
            let end = Date().addingTimeInterval(3)
            while !ok(), Date() < end { Thread.sleep(forTimeInterval: 0.02) }
            XCTAssertTrue(ok(), what)
        }
        func number(_ address: String, _ v: Int32) { w.receiveForTesting(osc(address, .string("\(v)"), .float(Float(v)), .int(v))) }

        w.receiveForTesting(osc("/?", .string("WING,192.168.1.71,PGM,wing-compact,NO_SERIAL,3.0.5-0-g0c2b9d4a:release")))
        // Channel 1 linked to local input 3, its own name empty, as in the document's dump of /ch/1.
        number("/ch/1/clink", 1)
        w.receiveForTesting(osc("/ch/1/in/conn/grp", .string("LCL")))
        number("/ch/1/in/conn/in", 3)
        w.receiveForTesting(osc("/ch/1/name", .string("")))
        // Channel 2 not linked: its own name counts, and its source's isn't asked.
        number("/ch/2/clink", 0)
        w.receiveForTesting(osc("/ch/2/in/conn/grp", .string("LCL")))
        number("/ch/2/in/conn/in", 4)
        w.receiveForTesting(osc("/ch/2/name", .string("Snare")))
        // Channel 3 linked to a bus, which has no /io/in name: its own name stays.
        number("/ch/3/clink", 1)
        w.receiveForTesting(osc("/ch/3/in/conn/grp", .string("BUS")))
        number("/ch/3/in/conn/in", 1)
        w.receiveForTesting(osc("/ch/3/name", .string("Bus feed")))
        // Aux 1 linked to aux input 1.
        number("/aux/1/clink", 1)
        w.receiveForTesting(osc("/aux/1/in/conn/grp", .string("AUX")))
        number("/aux/1/in/conn/in", 1)

        until("the linked sources' names are asked") {
            sent().contains("/io/in/LCL/3/name") && sent().contains("/io/in/AUX/1/name")
        }
        XCTAssertFalse(sent().contains("/io/in/LCL/4/name"))
        w.receiveForTesting(osc("/io/in/LCL/3/name", .string("Kick In")))
        w.receiveForTesting(osc("/io/in/AUX/1/name", .string("Playback")))
        until("the names as the desk shows them") {
            current() == [.input(1): "Kick In", .input(2): "Snare", .input(3): "Bus feed", .aux(1): "Playback"]
        }
        // A rename of the source comes through; turning the link off brings back the channel's own name.
        w.receiveForTesting(osc("/io/in/LCL/3/name", .string("Kick Sub")))
        until("the rename") { current()[.input(1)] == "Kick Sub" }
        number("/ch/1/clink", 0)
        until("the link off") { current()[.input(1)] == nil }
        XCTAssertTrue(udp.queue.sync { udp.sent }.allSatisfy { BehringerOSC.isReadRequest($0, .wing) })
    }

    /// Only an address on the list, with no arguments. On both desks a value sets a parameter,
    /// the X32's "/" with a string sets any node, a Wing blob can be a native command, and the
    /// push slots (`/xremote`, `/*s`) belong to other apps.
    func testOnlyReadsGoOut() {
        for f in BehringerOSC.Family.allCases {
            for a in BehringerOSC.reads(f) + [f.identify, f.selection] {
                XCTAssertTrue(BehringerOSC.isReadRequest(BehringerOSC.request(a), f), a)
            }
            // No type tag at all is a read too.
            XCTAssertTrue(BehringerOSC.isReadRequest(Array("/?\0\0".utf8), .wing))
        }
        let x32 = BehringerOSC.Family.x32, wing = BehringerOSC.Family.wing
        XCTAssertFalse(BehringerOSC.isReadRequest(osc("/ch/01/config/name", .string("Hacked")), x32))
        XCTAssertFalse(BehringerOSC.isReadRequest(osc("/", .string("ch/01/config/name Hacked")), x32))
        XCTAssertFalse(BehringerOSC.isReadRequest(osc("/-stat/selidx", .int(3)), x32))
        XCTAssertFalse(BehringerOSC.isReadRequest(osc("/-action/goscene", .int(1)), x32))
        XCTAssertFalse(BehringerOSC.isReadRequest(BehringerOSC.request("/xremote"), x32))
        XCTAssertFalse(BehringerOSC.isReadRequest(BehringerOSC.request("/-prefs/autosel"), x32))
        XCTAssertFalse(BehringerOSC.isReadRequest(BehringerOSC.request("/*s"), wing))
        XCTAssertFalse(BehringerOSC.isReadRequest(BehringerOSC.request("/$ctl/cfg/savenow"), wing))
        XCTAssertFalse(BehringerOSC.isReadRequest(osc("/ch/1/name", .float(1)), wing))
        // A blob, by hand: ",b" and a size.
        XCTAssertFalse(BehringerOSC.isReadRequest(Array("/ch/1/name\0\0,b\0\0".utf8) + [0, 0, 0, 1, 0xDD, 0, 0, 0], wing))
        // Another desk's address, broken padding, no leading slash.
        XCTAssertFalse(BehringerOSC.isReadRequest(BehringerOSC.request("/info"), wing))
        XCTAssertFalse(BehringerOSC.isReadRequest(Array("/info".utf8), x32))
        XCTAssertFalse(BehringerOSC.isReadRequest(Array("info\0\0\0\0".utf8), x32))
        XCTAssertFalse(BehringerOSC.isReadRequest(BehringerOSC.request("/info") + [0], x32))
        // A Wing source's name is a read; its gain, a source it doesn't have, and an X32 are not.
        XCTAssertTrue(BehringerOSC.isReadRequest(BehringerOSC.request("/io/in/LCL/24/name"), wing))
        XCTAssertTrue(BehringerOSC.isReadRequest(BehringerOSC.request("/io/in/USR/48/name"), wing))
        XCTAssertFalse(BehringerOSC.isReadRequest(BehringerOSC.request("/io/in/LCL/25/name"), wing))
        XCTAssertFalse(BehringerOSC.isReadRequest(BehringerOSC.request("/io/in/LCL/1/g"), wing))
        XCTAssertFalse(BehringerOSC.isReadRequest(osc("/ch/1/clink", .int(0)), wing))
        XCTAssertFalse(BehringerOSC.isReadRequest(BehringerOSC.request("/io/in/LCL/1/name"), x32))
    }

    func testSelectionNumbers() {
        let x32: [Int: ConsoleChannel?] = [0: .input(1), 31: .input(32), 32: .aux(1), 39: .aux(8), 40: .fxReturn(1),
                                            47: .fxReturn(8), 48: .mix(1), 63: .mix(16), 64: .matrix(1), 69: .matrix(6),
                                            70: .main(1), 71: .main(2), 72: nil, -1: nil]
        for (i, ch) in x32 { XCTAssertEqual(BehringerOSC.channel(.x32, selidx: i), ch, "x32 \(i)") }
        let wing: [Int: ConsoleChannel?] = [0: .input(1), 39: .input(40), 40: .aux(1), 47: .aux(8), 48: .mix(1),
                                             63: .mix(16), 64: .main(1), 67: .main(4), 68: .matrix(1), 75: .matrix(8),
                                             76: nil]
        for (i, ch) in wing { XCTAssertEqual(BehringerOSC.channel(.wing, selidx: i), ch, "wing \(i)") }
        XCTAssertEqual(BehringerOSC.names(.x32).count, 72)
        XCTAssertEqual(BehringerOSC.names(.wing).count, 76)
        // Plus each channel's and aux's link, input group and input number.
        XCTAssertEqual(BehringerOSC.reads(.wing).count, 76 + 48 * 3)
        XCTAssertEqual(BehringerOSC.reads(.x32).count, 72)
        XCTAssertEqual(BehringerOSC.wingSourceName(group: "LCL", index: 3), "/io/in/LCL/3/name")
        XCTAssertNil(BehringerOSC.wingSourceName(group: "BUS", index: 1))
        XCTAssertNil(BehringerOSC.wingSourceName(group: "OFF", index: 1))
        XCTAssertNil(BehringerOSC.wingSourceName(group: "A", index: 49))
        XCTAssertEqual(BehringerOSC.channel(.x32, nameAddress: "/fxrtn/08/config/name"), .fxReturn(8))
        XCTAssertNil(BehringerOSC.channel(.x32, nameAddress: "/ch/1/config/name"))
        XCTAssertEqual(ConsoleChannel.main(2).key, "main2")
    }
}

final class Stage4YamahaTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    func testPMFollowsCueAAndBAndReadsNames() {
        let p = TestPlatform()
        let pm = YamahaPMConsole(host: "127.0.0.1", platform: p)
        var model: String?, selected: [ConsoleChannel] = [], names: [ConsoleChannel: String] = [:]
        let named = expectation(description: "names")
        pm.onModel = { model = $0 }
        pm.onSelected = { selected.append($0) }
        pm.onNames = { names = $0; named.fulfill() }
        let rcp = p.streams[0]
        rcp.onState?(.connected)
        let sent = rcp.sent.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines) }
        XCTAssertEqual(sent.first, "devinfo productname")
        XCTAssertTrue(sent.contains("get MIXER:Current/InCh/Label/Name 287 0"))
        XCTAssertTrue(sent.contains("get MIXER:Current/Mtrx/Label/Name 35 0"))
        XCTAssertEqual(sent.count, 1 + 288 + 72 + 36)
        XCTAssertTrue(sent.allSatisfy { $0.hasPrefix("get ") || $0.hasPrefix("devinfo ") })

        pm.receiveForTesting(#"OK devinfo productname "RIVAGE PM10""#)
        XCTAssertEqual(model, "RIVAGE PM10")
        // Cue B on input 201, cue A off (not a selection), cue A on matrix 4.
        pm.receiveForTesting(#"NOTIFY set MIXER:Current/Cue/InCh/On 200 1 1 "ON""#)
        pm.receiveForTesting(#"NOTIFY set MIXER:Current/Cue/InCh/On 200 1 0 "OFF""#)
        pm.receiveForTesting(#"NOTIFY set MIXER:Current/Cue/Mtrx/On 3 0 1 "ON""#)
        XCTAssertEqual(selected, [.input(201), .matrix(4)])
        pm.receiveForTesting(#"OK get MIXER:Current/InCh/Label/Name 287 0 "Last""#)
        pm.receiveForTesting(#"OK get MIXER:Current/Mix/Label/Name 71 0 "Mon""#)
        wait(for: [named], timeout: 2)
        XCTAssertEqual(names, [.input(288): "Last", .mix(72): "Mon"])
    }

    /// One implementation listed twice: each entry says when the desk is the other one.
    func testTheCLAndQLAreOneCodeListedTwice() {
        XCTAssertEqual(YamahaCLQLConsole.model("QL1", entry: .ql), "QL1")
        XCTAssertTrue(YamahaCLQLConsole.model("CL5", entry: .ql).hasPrefix("CL5 (a CL:"))
        XCTAssertEqual(YamahaCLQLConsole.model("CL3", entry: .cl), "CL3")
        XCTAssertTrue(YamahaCLQLConsole.model("QL5", entry: .cl).hasPrefix("QL5 (a QL:"))
        let r = ModuleRegistry.standard
        let ctx = ModuleContext(settings: Settings(), platform: TestPlatform())
        for id in ["yamaha.ql", "yamaha.cl"] {
            let m = r.console(id)?.make(ctx) as? LinkConsoleModule
            XCTAssertTrue(m?.link is YamahaCLQLConsole, id)
        }
        XCTAssertEqual(r.console("yamaha.cl")?.info.status, .experimental)
        XCTAssertEqual(r.console("yamaha.ql")?.info.status, .supported)
        // A 0.3 file's CL/QL is still the QL's entry, the one run on a desk.
        XCTAssertEqual(r.console("yamahaCLQL")?.info.id, "yamaha.ql")
    }
}

final class AvantisTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    func testAvantisReadsInputs1To64WithTheDLivesMessages() {
        let p = TestPlatform()
        let a = AllenHeathConsole(family: .avantis, host: "127.0.0.1", midiChannel: 12, platform: p)
        var model: String?, names: [ConsoleChannel: String] = [:], got: [ControlSource] = []
        let named = expectation(description: "names")
        a.onModel = { model = $0 }
        a.onNames = { names = $0; named.fulfill() }
        a.onControl = { src, _ in got.append(src) }
        let tcp = p.streams[0]
        tcp.onState?(.connected)
        XCTAssertEqual(model, "Avantis")
        // 64 Get Names on N (MIDI channel 12 is 0B), each a read.
        XCTAssertEqual(tcp.sent.count, 64)
        XCTAssertTrue(tcp.sent.allSatisfy(AllenHeathMIDI.isReadRequest))
        XCTAssertEqual(tcp.sent.last, [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x10, 0x01, 0x00, 0x0B, 0x01, 0x3F, 0xF7])
        let h: [UInt8] = [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x10, 0x01, 0x00]
        a.receiveForTesting(h + [0x0B, 0x02, 0x3F] + Array("Last".utf8) + [0xF7])
        a.receiveForTesting(h + [0x0B, 0x02, 0x40] + Array("Beyond".utf8) + [0xF7])
        wait(for: [named], timeout: 2)
        XCTAssertEqual(names, [.input(64): "Last"])
        // Learned controls keep 0.3's source name, so a dLive user's controls work on either entry.
        a.receiveForTesting([0x9B, 0x05, 0x7F])
        XCTAssertEqual(got, [.midi(source: "dLive / Avantis", kind: .note, channel: 12, number: 5)])
    }
}

final class Stage4RegistryTests: XCTestCase {
    func testThePickerListsEveryDeskByMaker() {
        XCTAssertEqual(ModuleRegistry.standard.consoles.map(\.info.id), [
            "yamaha.ql", "yamaha.cl", "yamaha.dm", "yamaha.pm",
            "allenheath.qu", "allenheath.dlive", "allenheath.avantis", "allenheath.sq",
            "behringer.x32", "behringer.wing",
        ])
    }
}
