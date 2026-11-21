import XCTest
@testable import RemoraConsoles
@testable import RemoraCore

/// The SQ's remote port, from bytes captured off a real SQ-5 on 2026-11-21 (docs/PROTOCOL.md).
final class SQRemoteTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    /// The first 41880 bytes of the state the SQ-5 sent for SceneSyncRequest (97376 in all), cut
    /// after the marker that ends its names section.
    private func capturedState() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sq5-state-names.bin")
        return [UInt8](try Data(contentsOf: url))
    }

    // The desk's side of the opening, as captured (port 0 announced).
    private let deskHello: [UInt8] = [0x7F, 0x00, 0x02, 0x00, 0x00, 0x00, 0x7E, 0xC8]
    private let boxInfo: [UInt8] = [0x7F, 0x02, 0x0C, 0x00, 0x00, 0x00,
                                    0x01, 0x01, 0x06, 0x01, 0x0A, 0x13, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00]
    private let featureSet: [UInt8] = [0x7F, 0x0C, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00]
    /// Input 8 selected, at surface position 7: the desk's answer to the ask for the selection.
    private let selectedInput8: [UInt8] = [0xF7, 0x09, 0x09, 0x0C, 0x07, 0x00, 0x01, 0x07]
    /// Input 8 renamed "test" on the desk.
    private let renamedInput8: [UInt8] = [0x7F, 0x08, 0x0E, 0x00, 0x00, 0x00,
                                          0x18, 0x18, 0x07, 0x00, 0x07, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x00]

    func testOnlyTheOpeningAndKeepaliveGoOut() {
        for m in [SQRemote.hello, SQRemote.discoveryRequest, SQRemote.featureSetRequest, SQRemote.messageFilter,
                  SQRemote.sceneSyncRequest, SQRemote.keepAlive, SQRemote.selectionRequest, SQRemote.find] {
            XCTAssertTrue(SQRemote.isReadRequest(m))
        }
        // As MixPad sends them: the opening bytes captured from it.
        XCTAssertEqual(SQRemote.hello, [0x7F, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(SQRemote.featureSetRequest, [0x7F, 0x0B, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00])
        XCTAssertEqual(SQRemote.keepAlive, [0x7F, 0x05, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(SQRemote.messageFilter.count, 6 + 0x2000)
        XCTAssertEqual(Array(SQRemote.messageFilter.prefix(6)), [0x7F, 0x0A, 0x00, 0x20, 0x00, 0x00])
        // MixPad setting the desk's clock, a fader move, a rename, MixPad's hello with a meter port,
        // and a filter that is not MixPad's: none of them.
        XCTAssertFalse(SQRemote.isReadRequest([0x7F, 0x1A, 0x08, 0x00, 0x00, 0x00, 0x26, 0x34, 0x1F, 0x6A, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertFalse(SQRemote.isReadRequest([0xF7, 0x08, 0x0C, 0x0C, 0x07, 0x01, 0x00, 0x60]))
        XCTAssertFalse(SQRemote.isReadRequest(renamedInput8))
        XCTAssertFalse(SQRemote.isReadRequest([0x7F, 0x00, 0x02, 0x00, 0x00, 0x00, 0xFC, 0xC8]))
        var filter = SQRemote.messageFilter
        filter[6] = 0x00
        XCTAssertFalse(SQRemote.isReadRequest(filter))
    }

    func testParserSplitsFramesAndShortMessagesAcrossReads() {
        var p = SQRemote.Parser()
        let stream = deskHello + [0x00] + selectedInput8 + featureSet
        var out = p.feed(Array(stream.prefix(5)))
        out += p.feed(Array(stream.dropFirst(5).prefix(7)))
        out += p.feed(Array(stream.dropFirst(12)))
        XCTAssertEqual(out, [.frame(0x00, [0x7E, 0xC8]),
                             .message(source: 0x09, recipient: 0x09, parameter: 0x0C, data: [0x07, 0x00, 0x01, 0x07]),
                             .frame(0x0C, [0x01, 0x00])])
        XCTAssertEqual(p.feed(renamedInput8),
                       [.message(source: 0x18, recipient: 0x18, parameter: 0x07,
                                 data: [0x00, 0x07, 0x00, 0x00, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x00])])
    }

    func testNamesFromTheSQ5sState() throws {
        let names = try XCTUnwrap(SQRemote.names(fromState: try capturedState()))
        XCTAssertEqual(names, [0: "hh1", 1: "hh2", 2: "hh3", 3: "hh4", 4: "hh5", 5: "bgm", 6: "tv", 7: "test",
                               40: "ST1", 42: "ST2", 44: "ST3", 46: "USB", 72: "hhs", 119: "roof"])
        // A state laid out some other way gives none, rather than wrong ones.
        XCTAssertNil(SQRemote.names(fromState: Array(try capturedState().dropLast(4))))
    }

    func testStripsByRange() {
        XCTAssertEqual(SQRemote.channel(strip: 0), .input(1))
        XCTAssertEqual(SQRemote.channel(strip: 46), .input(47))
        XCTAssertEqual(SQRemote.channel(strip: 67), .fxReturn(4))
        XCTAssertEqual(SQRemote.channel(strip: 72), .group(1))
        XCTAssertEqual(SQRemote.channel(strip: 93), .aux(6))
        XCTAssertEqual(SQRemote.channel(strip: 104), .main(1))
        XCTAssertEqual(SQRemote.channel(strip: 119), .other(119))
        // A selection on the surface reaches recipient 09; the copies to other recipients, a layer
        // change and a DCA strip are not a channel's selection.
        var p = SQRemote.Parser()
        let m = p.feed([0xF7, 0x15, 0x09, 0x0C, 0x0B, 0x00, 0x01, 0x2E,   // Input 47
                        0xF7, 0x34, 0x34, 0x0C, 0x01, 0x2E, 0x01, 0x00,
                        0xF7, 0x08, 0x15, 0x0C, 0x2E, 0x00, 0x00, 0x00,
                        0xF7, 0x08, 0x09, 0x0E, 0x02, 0x00, 0x00, 0x00,
                        0xF7, 0x09, 0x09, 0x0C, 0x03, 0x00, 0x02, 0x01])
        XCTAssertEqual(m.map(SQRemote.selectedStrip), [46, nil, nil, nil, nil])
    }

    /// The opening goes one step per answer, every byte of it a read; then the state's names,
    /// the selection and a rename come through.
    func testOpeningFollowsTheDesk() throws {
        let p = TestPlatform()
        let link = SQRemoteLink(host: "192.168.0.5", platform: p)
        var states: [ConsoleState] = [], selected: [ConsoleChannel] = [], names: [[ConsoleChannel: String]] = []
        var namesLink: [Bool] = []
        let renamed = expectation(description: "rename")
        link.onState = { states.append($0) }
        link.onSelected = { selected.append($0) }
        link.onNamesLink = { namesLink.append($0) }
        link.onNames = { n in
            names.append(n)
            if names.count == 2 { renamed.fulfill() }
        }
        let tcp = try XCTUnwrap(p.streams.first)
        XCTAssertEqual(tcp.port, 51326)
        tcp.onState?(.connected)
        XCTAssertEqual(tcp.sent, [SQRemote.hello])
        link.receiveForTesting(deskHello)
        XCTAssertEqual(tcp.sent.last, SQRemote.discoveryRequest)
        link.receiveForTesting(boxInfo)
        XCTAssertEqual(tcp.sent.last, SQRemote.featureSetRequest)
        link.receiveForTesting(featureSet)
        XCTAssertEqual(Array(tcp.sent.suffix(2)), [SQRemote.messageFilter, SQRemote.sceneSyncRequest])
        XCTAssertEqual(states, [.waitingForDesk])
        link.receiveForTesting(SQRemote.frame(0x04, try capturedState()))
        XCTAssertEqual(states, [.waitingForDesk, .live])
        XCTAssertEqual(namesLink, [true])
        XCTAssertEqual(tcp.sent.last, SQRemote.selectionRequest)
        XCTAssertEqual(names.first?[.input(8)], "test")
        XCTAssertEqual(names.first?[.group(1)], "hhs")
        // The desk's Matrix 6: a raw channel until matrices are numbered, but named.
        XCTAssertEqual(names.first?[.other(119)], "roof")
        link.receiveForTesting(selectedInput8)
        link.receiveForTesting(selectedInput8)
        XCTAssertEqual(selected, [.input(8)])
        link.receiveForTesting([0x7F, 0x08, 0x0D, 0x00, 0x00, 0x00, 0x18, 0x18, 0x07, 0x00, 0x07, 0x00, 0x00,
                                0x56, 0x6F, 0x78, 0x00, 0x00, 0x00])
        wait(for: [renamed], timeout: 2)
        XCTAssertEqual(names.last?[.input(8)], "Vox")
        XCTAssertTrue(tcp.sent.allSatisfy(SQRemote.isReadRequest))
    }

    /// The log says the SQ has been run on a desk, and a documents-only desk that it hasn't.
    func testSaysHowFarItHasBeenRun() {
        XCTAssertEqual(RemoraConsoles.allenHeathSQ.info.experimentalWhy,
                       "run on an SQ-5 for the selection and names, but not yet on a show")
        XCTAssertEqual(RemoraConsoles.allenHeathQu.info.experimentalWhy,
                       "built from the maker's documents, never run on a desk")
    }

    func testModelFromFind() throws {
        let p = TestPlatform()
        let link = SQRemoteLink(host: "192.168.0.5", platform: p)
        var models: [String] = []
        link.onModel = { models.append($0) }
        let udp = try XCTUnwrap(p.udps.first), tcp = try XCTUnwrap(p.streams.first)
        XCTAssertEqual(udp.port, 51320)
        // Sent once both are up, whichever comes second.
        udp.start()
        XCTAssertEqual(udp.sent, [])
        tcp.state = .connected
        tcp.onState?(.connected)
        XCTAssertEqual(udp.sent, [Array("SQ Find".utf8)])
        udp.receive(Array("SQ-5".utf8) + [0x00])
        XCTAssertEqual(models, ["SQ-5"])
    }

    /// The SQ entry keeps the MIDI link: its soft keys stay learnable under 0.3's source name, and
    /// MIDI sends the desk nothing. A desk whose remote port never answers is live on MIDI alone.
    func testSQKeepsItsMIDIControls() throws {
        let p = TestPlatform()
        let sq = AllenHeathSQConsole(host: "192.168.0.5", midiChannel: 1, platform: p)
        var got: [ControlSource] = [], states: [ConsoleState] = [], models: [String] = []
        sq.onControl = { src, _ in got.append(src) }
        sq.onState = { states.append($0) }
        sq.onModel = { models.append($0) }
        let midi = try XCTUnwrap(p.streams.first { $0.port == 51325 })
        let remote = try XCTUnwrap(p.streams.first { $0.port == 51326 })
        midi.onState?(.connected)
        remote.onState?(.connected)
        remote.onState?(.failed("connection refused"))
        XCTAssertEqual(states, [.live])
        XCTAssertEqual(models, ["SQ"])
        sq.midi.receiveForTesting([0x90, 0x3C, 0x7F])
        XCTAssertEqual(got, [.midi(source: "SQ", kind: .note, channel: 1, number: 60)])
        XCTAssertEqual(midi.sent, [])
        // With MIDI down, the remote port's state is the link's.
        midi.onState?(.failed(StreamState.closedByPeer))
        XCTAssertEqual(states, [.live, .failed("connection refused")])
    }
}
