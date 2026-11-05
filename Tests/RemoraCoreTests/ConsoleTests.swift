import XCTest
@testable import RemoraCore

/// The desks other than the CL/QL, from their makers' documents (no captures yet), and the
/// console plumbing they share.
final class AllenHeathTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    func testParserRunningStatusSysExAndRealTime() {
        var p = MIDIStreamParser()
        // dLive mute on, then the same status omitted (running status), an Active Sense in the
        // middle of a SysEx, and a SysEx split across two reads.
        var out = p.feed([0x90, 0x05, 0x7F, 0x05, 0x00, 0xF0, 0x00, 0xFE, 0x00, 0x1A])
        out += p.feed([0x50, 0xF7, 0xB1, 0x07, 0x40])
        XCTAssertEqual(out, [.channel(status: 0x90, 0x05, 0x7F), .channel(status: 0x90, 0x05, 0x00),
                             .sysEx([0xF0, 0x00, 0x00, 0x1A, 0x50, 0xF7]), .channel(status: 0xB1, 0x07, 0x40)])
    }

    func testNRPNCompletesOnTheDataLSB() {
        var n = NRPNAssembler()
        XCTAssertEqual(n.feed(channel: 0, controller: 0x63, value: 0x20), .some(nil))
        XCTAssertEqual(n.feed(channel: 0, controller: 0x62, value: 0x51), .some(nil))
        XCTAssertEqual(n.feed(channel: 0, controller: 0x06, value: 0x01), .some(nil))
        XCTAssertEqual(n.feed(channel: 0, controller: 0x26, value: 0x07),
                       .some(NRPNAssembler.Parameter(channel: 0, msb: 0x20, lsb: 0x51, value: 1, index: 7)))
        XCTAssertNil(n.feed(channel: 0, controller: 0x07, value: 0x40) ?? nil)
        XCTAssertEqual(n.feed(channel: 0, controller: 0x07, value: 0x40) == nil, true)
    }

    func testOnlyRequestsGoOut() {
        let h: [UInt8] = [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x10, 0x01, 0x00]
        XCTAssertTrue(AllenHeathMIDI.isReadRequest(h + [0x00, 0x01, 0x10, 0xF7]))      // get name
        XCTAssertTrue(AllenHeathMIDI.isReadRequest(AllenHeathMIDI.quSystemStateRequest))
        XCTAssertFalse(AllenHeathMIDI.isReadRequest(h + [0x00, 0x03, 0x10, 0x41, 0xF7])) // set name
        XCTAssertFalse(AllenHeathMIDI.isReadRequest([0x90, 0x05, 0x7F]))                 // a mute
        XCTAssertFalse(AllenHeathMIDI.isReadRequest([0xB0, 0x63, 0x20, 0xB0, 0x62, 0x17, 0xB0, 0x06, 0x62]))
        XCTAssertFalse(AllenHeathMIDI.isReadRequest([0xC0, 0x01]))                       // a scene
    }

    func testQuNumbering() {
        XCTAssertEqual(AllenHeathMIDI.channel(.qu, offset: 0, number: 0x20), .input(1))
        XCTAssertEqual(AllenHeathMIDI.channel(.qu, offset: 0, number: 0x3F), .input(32))
        XCTAssertEqual(AllenHeathMIDI.channel(.qu, offset: 0, number: 0x41), .stereo(2))
        XCTAssertEqual(AllenHeathMIDI.channel(.qu, offset: 0, number: 0x0A), .fxReturn(3))
        XCTAssertEqual(AllenHeathMIDI.channel(.qu, offset: 0, number: 0x64), .mix(5))
        XCTAssertEqual(AllenHeathMIDI.channel(.qu, offset: 0, number: 0x66), .mix(9))
        XCTAssertEqual(AllenHeathMIDI.channel(.dLive, offset: 0, number: 0x7F), .input(128))
        XCTAssertEqual(AllenHeathMIDI.channel(.dLive, offset: 4, number: 0x21), .fxReturn(2))
        XCTAssertNil(AllenHeathMIDI.channel(.dLive, offset: 1, number: 0x00))
    }

    /// The Qu's reply to Get System State says its model and channel; then PAFL on a channel is
    /// the selection, and names come back for the channels asked for.
    func testQuFollowsPAFLAndReadsNames() {
        let qu = AllenHeathConsole(family: .qu, host: "127.0.0.1", midiChannel: 1)
        var model: String?, selected: [ConsoleChannel] = [], names: [ConsoleChannel: String] = [:]
        let named = expectation(description: "names")
        qu.onModel = { model = $0 }
        qu.onSelected = { selected.append($0) }
        qu.onNames = { names = $0; named.fulfill() }
        let h: [UInt8] = [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x11, 0x01, 0x00]
        // Box 3 (Qu-32) on channel 2 (N = 1).
        qu.receiveForTesting(h + [0x01, 0x11, 0x03, 0x01, 0x09, 0xF7])
        XCTAssertEqual(model, "Qu-32")
        // PAFL on Input 5 (CH 24) on N = 1, then off, then a PAFL on another channel's MIDI
        // channel (not the desk's: ignored).
        qu.receiveForTesting([0xB1, 0x63, 0x24, 0xB1, 0x62, 0x51, 0xB1, 0x06, 0x01, 0xB1, 0x26, 0x07])
        qu.receiveForTesting([0x63, 0x24, 0x62, 0x51, 0x06, 0x00, 0x26, 0x07])
        qu.receiveForTesting([0xB2, 0x63, 0x25, 0xB2, 0x62, 0x51, 0xB2, 0x06, 0x01, 0xB2, 0x26, 0x07])
        XCTAssertEqual(selected, [.input(5)])
        // Name of Input 5.
        qu.receiveForTesting(h + [0x01, 0x02, 0x24] + Array("Vox".utf8) + [0xF7])
        wait(for: [named], timeout: 2)
        XCTAssertEqual(names[.input(5)], "Vox")
    }

    func testDLiveMuteIsALearnableNote() {
        let d = AllenHeathConsole(family: .dLive, host: "127.0.0.1", midiChannel: 1)
        var got: [(ControlSource, Int32)] = []
        d.onControl = { got.append(($0, $1)) }
        d.receiveForTesting([0x90, 0x05, 0x7F, 0x05, 0x00])
        XCTAssertEqual(got.map(\.0), [.midi(source: "dLive / Avantis", kind: .note, channel: 1, number: 5),
                                       .midi(source: "dLive / Avantis", kind: .note, channel: 1, number: 5)])
        XCTAssertEqual(got.map(\.1), [127, 0])
    }

    func testDLiveNamesByChannelType() {
        let d = AllenHeathConsole(family: .dLive, host: "127.0.0.1", midiChannel: 3)
        let named = expectation(description: "names")
        var names: [ConsoleChannel: String] = [:]
        d.onNames = { names = $0; named.fulfill() }
        let h: [UInt8] = [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x10, 0x01, 0x00]
        // N = 2 (MIDI channel 3): Input 1 on 02, FX Return 1 on 06.
        d.receiveForTesting(h + [0x02, 0x02, 0x00] + Array("Kick".utf8) + [0xF7])
        d.receiveForTesting(h + [0x06, 0x02, 0x20] + Array("Verb".utf8) + [0xF7])
        wait(for: [named], timeout: 2)
        XCTAssertEqual(names, [.input(1): "Kick", .fxReturn(1): "Verb"])
    }
}

/// The DM7 and DM3, from Yamaha's manuals and the RCP parameter lists (no captures yet).
final class YamahaDMTests: XCTestCase {
    func testDMFollowsCueAndReadsNamesByModel() {
        let dm = YamahaDMConsole(host: "127.0.0.1")
        var model: String?, selected: [ConsoleChannel] = [], names: [ConsoleChannel: String] = [:]
        let named = expectation(description: "names")
        dm.onModel = { model = $0 }
        dm.onSelected = { selected.append($0) }
        dm.onNames = { names = $0; named.fulfill() }
        dm.receiveForTesting(#"OK devinfo productname "DM3""#)
        XCTAssertEqual(model, "DM3")
        // A cue on, a cue off (not a selection), a mix's cue on.
        dm.receiveForTesting(#"NOTIFY set MIXER:Current/Cue/InCh/On 3 0 1 "ON""#)
        dm.receiveForTesting(#"NOTIFY set MIXER:Current/Cue/InCh/On 3 0 0 "OFF""#)
        dm.receiveForTesting(#"NOTIFY set MIXER:Current/Cue/Mix/On 5 1 1 "ON""#)
        XCTAssertEqual(selected, [.input(4), .mix(6)])
        // A DM3 has 16 inputs: a name past them is not one of its channels.
        dm.receiveForTesting(#"OK get MIXER:Current/InCh/Label/Name 3 0 "vox1""#)
        dm.receiveForTesting(#"OK get MIXER:Current/InCh/Label/Name 40 0 "ghost""#)
        dm.receiveForTesting(#"OK get MIXER:Current/StInCh/Label/Name 0 0 "PB""#)
        wait(for: [named], timeout: 2)
        XCTAssertEqual(names, [.input(4): "vox1", .stereo(1): "PB"])
    }

    func testDMLayouts() {
        XCTAssertEqual(YamahaDM.channels(model: "DM3 Standard")["MIXER:Current/InCh/Label/Name"]?.count, 16)
        XCTAssertEqual(YamahaDM.channels(model: "DM7")["MIXER:Current/InCh/Label/Name"]?.count, 120)
        // A model it does not know (or no answer at all) is read as a DM7.
        XCTAssertEqual(YamahaDM.channels(model: "")["MIXER:Current/Mix/Label/Name"]?.count, 48)
    }

    func testCLQLNamesLinkIgnoresCue() {
        let rcp = YamahaRCPNames(host: "127.0.0.1")
        var cued = false
        rcp.onCue = { _ in cued = true }
        rcp.receiveForTesting(#"NOTIFY set MIXER:Current/Cue/InCh/On 3 0 1 "ON""#)
        XCTAssertFalse(cued)
    }
}

final class ConsolePlumbingTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    func testOldSettingsAreACLQL() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"consoleHost": "10.0.0.5"}"#.utf8))
        XCTAssertEqual(s.consoleKind, .yamahaCLQL)
        XCTAssertEqual(s.consoleMIDIChannel, 1)
    }

    func testOldControlsLoadWithoutARack() throws {
        let json = #"{"controls": [{"id": "6A1D7E8C-0D5E-4F43-9A32-1B2C3D4E5F60", "name": "Next", "action": "nextRack", "mode": "trigger", "cc": 30}]}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.controls.count, 1)
        XCTAssertEqual(s.controls[0].name, "Next")
        XCTAssertEqual(s.controls[0].rack, 0)
    }

    func testStepSpacingMovesToTheMinimum() throws {
        func load(_ json: String) throws -> Settings { try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
        XCTAssertEqual(try load(#"{"stepMilliseconds": 20}"#).stepMilliseconds, 2, "0.2's default becomes 0.3's")
        XCTAssertEqual(try load(#"{"stepMilliseconds": 50}"#).stepMilliseconds, 50, "a chosen spacing stays")
        XCTAssertEqual(try load(#"{"stepMilliseconds": 20, "settingsVersion": 3}"#).stepMilliseconds, 20,
                       "20 chosen in 0.3 stays")
        XCTAssertEqual(Settings().driverConfig.spacing, 0.002)
        let again = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(try load(#"{"stepMilliseconds": 20}"#)))
        XCTAssertEqual(again.settingsVersion, Settings.currentVersion)
    }

    /// At 2 ms a move from the last rack to the first is 15 steps, about 30 ms of MIDI.
    func testAMoveAtTheMinimumSpacing() {
        let rig = FakeSuperRack(count: allanRacks.count, at: 15)
        let d = SuperRackDriver(sink: rig)
        var c = SuperRackDriver.Config()
        c.mode = .countFromLast
        d.config = c
        d.rackCount = allanRacks.count
        d.select(15)
        d.waitUntilIdle()
        let start = Date()
        d.select(0)
        d.waitUntilIdle()
        XCTAssertEqual(rig.rack, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
    }

    func testChannelsSortInputsFirst() {
        XCTAssertEqual([ConsoleChannel.mix(1), .fxReturn(2), .input(10), .stereo(1), .input(2)].sorted(),
                       [.input(2), .input(10), .stereo(1), .fxReturn(2), .mix(1)])
    }

    func testCLQLKeysUnchanged() {
        XCTAssertEqual(ConsoleChannel(selection: 16).key, "in17")
        XCTAssertEqual(ConsoleChannel(selection: 73).key, "stin1R")
        XCTAssertEqual(ConsoleChannel(selection: 88).key, "mix1")
    }

    /// A soft key learned as Go to rack moves SuperRack to that rack, from wherever it is.
    func testGoToRackFromADeskKey() {
        let rig = FakeSuperRack(count: allanRacks.count, at: 6)
        var s = Settings()
        var m = ControlMapping()
        m.action = .goToRack
        m.rack = 8
        m.source = .midi(source: "SQ", kind: .note, channel: 1, number: 60)
        s.controls = [m]
        let bridge = Bridge(settings: s, sink: rig)
        bridge.driverForTesting.config.spacing = 0
        bridge.setRacksForTesting(allanRacks)
        bridge.controlForTesting(.midi(source: "SQ", kind: .note, channel: 1, number: 60), value: 0)
        bridge.driverForTesting.waitUntilIdle()
        XCTAssertEqual(rig.rack, 6, "a note off is not a press")
        bridge.controlForTesting(.midi(source: "SQ", kind: .note, channel: 1, number: 60), value: 127)
        bridge.driverForTesting.waitUntilIdle()
        XCTAssertEqual(rig.rack, 8)
    }
}
