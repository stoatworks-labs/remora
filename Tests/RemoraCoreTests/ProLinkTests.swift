import Network
import XCTest
@testable import RemoraApple
@testable import RemoraCore
@testable import RemoraEngine
@testable import RemoraHosts

/// The racks SuperRack Performer 15.15.12.13 listed over ProLink on 2026-11-07 (docs/PROTOCOL.md):
/// ten fed from input 4 (from 0) on, two of them stereo, and six no input feeds.
let capturedRacks: [ProLinkRack] = {
    let fed: [(name: String, width: Int, input: Int)] = [
        ("head 1", 1, 4), ("head 2", 1, 5), ("n/a", 1, 6), ("head 4", 1, 7), ("hh 1", 1, 8),
        ("hh 2", 1, 9), ("hh 3", 1, 10), ("n/a", 1, 11), ("Lec", 2, 12), ("mains", 2, 14),
    ]
    let stem = { (w: Int) in w == 2 ? 101 : 100 }
    return fed.enumerated().map { i, r in
        ProLinkRack(index: i, name: r.name, inputs: r.width, outputs: r.width, inputStemFormat: stem(r.width),
                    outputStemFormat: stem(r.width), firstInputChannel: r.input, firstOutputChannel: r.input)
    } + (10..<16).map { ProLinkRack(index: $0, name: "Rack \($0 + 1)") }
}()

/// A command as the far end reads it, without its id: "ShowRack 8".
func said(_ m: ProLinkOSC.Message) -> String {
    ([m.command] + m.args.dropFirst().map(\.description)).joined(separator: " ")
}

/// SuperRack's answer to a command, as it answered on 2026-11-07.
func resultCommand(_ id: Int32, _ command: String, error: Int32 = 0) -> [UInt8] {
    let text = "/waves.com/remote/\(command) \(error == 0 ? "succeeded" : "failed")"
    return ProLinkWire.osc(.init(address: "/waves.com/remote/ResultCommand", args: [.int(id), .int(error), .string(text)]))
}

/// GiveRackInfo as SuperRack sent it on 2026-11-07: the id, the count, then one array per rack.
func giveRackInfo(_ id: Int32, _ racks: [ProLinkRack]) -> [UInt8] {
    var args: [ProLinkOSC.Arg] = [.int(id), .int(Int32(racks.count))]
    for r in racks { args += [.arrayStart] + r.arguments + [.arrayEnd] }
    return ProLinkWire.osc(.init(address: "/waves.com/remote/GiveRackInfo", args: args))
}

/// SuperRack's Init as it sent it on 2026-11-07: keepAlive 2000, format 0, command set 1.1.
func superRackInit(keepAlive: Int32 = 2000, format: UInt32 = 0, major: UInt16 = 1,
                   description: String = "Waves SuperRack 15.15.12.13 Build 288878") -> [UInt8] {
    var b = ProLinkWire.initMessage(keepAlive: keepAlive, description: description)
    b.replaceSubrange(16..<20, with: ProLinkWire.be32(format))
    b.replaceSubrange(20..<22, with: ProLinkWire.be16(major))
    b.replaceSubrange(22..<24, with: ProLinkWire.be16(1))
    return b
}

/// SuperRack's end of a link, played over a `TestConnection` as SuperRack played it on 2026-11-07:
/// Init first, HandshakeAck after the console's Init, the racks for GetRacksInfo, and a
/// ResultCommand for every other command. Its replies come later on the link's queue, as a
/// network's would.
final class FakeProLinkPeer {
    let link: TestConnection
    var racks: [ProLinkRack]
    // On the link's queue:
    private var answers = true
    private var refuse: Set<String> = []
    private var heard: [ProLinkOSC.Message] = []
    private var frames: [ProLinkWire.Frame] = []
    private var unanswered: [ProLinkOSC.Message] = []
    private var parser = ProLinkWire.Parser()

    init(_ link: TestConnection, racks: [ProLinkRack] = capturedRacks) {
        self.link = link
        self.racks = racks
        link.onSend = { [weak self] b in self?.hear(b) }
    }

    func hello(_ bytes: [UInt8] = superRackInit()) { link.receive(bytes) }

    /// Off: commands wait for `answerNext`.
    func set(answers on: Bool) { link.queue.sync { answers = on } }
    /// These commands get error 9, as SuperRack refused a rack it lacked.
    func set(refusing names: Set<String>) { link.queue.sync { refuse = names } }

    /// Answers the oldest command still waiting.
    func answerNext() {
        link.queue.sync {
            guard !unanswered.isEmpty else { return }
            answer(unanswered.removeFirst())
        }
    }

    /// Every command heard, without ids.
    var commands: [String] { link.queue.sync { heard.map(said) } }
    var heardFrames: [ProLinkWire.Frame] { link.queue.sync { frames } }
    var alives: Int { link.queue.sync { frames.filter { $0 == .iAmAlive }.count } }

    private func hear(_ b: [UInt8]) {
        guard let fs = try? parser.feed(b) else { return }
        for f in fs {
            frames.append(f)
            switch f {
            case .initialize: reply(ProLinkWire.handshakeAck())
            case .osc(let data):
                guard let m = ProLinkOSC.decode(data) else { continue }
                heard.append(m)
                if answers { answer(m) } else { unanswered.append(m) }
            default: break
            }
        }
    }

    private func answer(_ m: ProLinkOSC.Message) {
        guard let id = m.id else { return }
        if m.command == "GetRacksInfo" {
            reply(giveRackInfo(id, racks))
        } else {
            reply(resultCommand(id, m.command, error: refuse.contains(m.command) ? 9 : 0))
        }
    }

    private func reply(_ b: [UInt8]) {
        link.queue.async { [link] in link.onData?(b) }
    }
}

final class ProLinkWireTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    /// ShowRack id 1, channel 3, framed as LAWO's waveslib.tcl frames it: a 16-byte header with the
    /// OSC's size, then the OSC.
    func testShowRackBytes() {
        let b = ProLinkWire.command("ShowRack", id: 1, [.int(3)])
        XCTAssertEqual(hex(b), "000000015761766500000005000000282f77617665732e636f6d2f72656d6f74652f53686f775261636b00002c6969000000000100000003")
    }

    func testConsoleInitLayout() {
        let b = ProLinkWire.initMessage(keepAlive: 2000, description: "Remora")
        XCTAssertEqual(b.count, 16 + 28 + 6)
        XCTAssertEqual(ProLinkWire.rd32(b, 12), 2000, "keepAlive rides in the header")
        XCTAssertEqual(ProLinkWire.rd32(b, 16), 0, "data format 0: OSC 1.1")
        XCTAssertEqual(ProLinkWire.rd16(b, 20), 1, "command set major")
        XCTAssertEqual(ProLinkWire.rd16(b, 22), 0, "command set minor")
        XCTAssertEqual(ProLinkWire.rd32(b, 40), 6, "description size")
        XCTAssertEqual(String(decoding: b[44...], as: UTF8.self), "Remora")
    }

    func testParserTakesAnInitByteByByte() throws {
        var p = ProLinkWire.Parser()
        var frames: [ProLinkWire.Frame] = []
        for byte in superRackInit() + ProLinkWire.handshakeAck() { frames += try p.feed([byte]) }
        XCTAssertEqual(frames.count, 2)
        guard case .initialize(let h) = frames[0] else { return XCTFail("\(frames)") }
        XCTAssertEqual(h.keepAlive, 2000)
        XCTAssertEqual(h.major, 1)
        XCTAssertEqual(h.minor, 1)
        XCTAssertEqual(h.description, "Waves SuperRack 15.15.12.13 Build 288878")
        XCTAssertEqual(frames[1], .handshakeAck)
    }

    /// Outside waveslib.tcl's bounds (keepAlive 200–60000 or -1, a description of 256 bytes at
    /// most) or not a ProLink header at all: the peer is dropped rather than misread.
    func testParserRefusesWhatIsOutOfBounds() throws {
        func refused(_ b: [UInt8]) -> Bool {
            var p = ProLinkWire.Parser()
            return (try? p.feed(b)) == nil
        }
        XCTAssertTrue(refused(Array("GET / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertTrue(refused(ProLinkWire.header(.initialize, 100) + Array(repeating: 0, count: 28)))
        XCTAssertTrue(refused(ProLinkWire.header(.osc, 0)))
        var long = ProLinkWire.initMessage(keepAlive: 2000, description: "")
        long.replaceSubrange(40..<44, with: ProLinkWire.be32(257))
        XCTAssertTrue(refused(long + Array(repeating: 65, count: 257)))
        var p = ProLinkWire.Parser()
        XCTAssertEqual(try p.feed(ProLinkWire.initMessage(keepAlive: -1, description: "x")).count, 1, "-1 is no keepAlive")
    }

    func testRackListRoundTrips() {
        let kick = ProLinkRack(index: 0, name: "Kick", firstInputChannel: 0, firstOutputChannel: 0)
        let vox = ProLinkRack(index: 2, name: "Vox", inputs: 2, outputs: 2, firstInputChannel: 4, firstOutputChannel: 4)
        let m = ProLinkOSC.Message(address: "/waves.com/remote/GiveRackInfo",
                                   args: [.int(7), .int(2), .arrayStart] + kick.arguments + [.arrayEnd, .arrayStart]
                                       + vox.arguments + [.arrayEnd])
        let bytes = ProLinkOSC.encode(m)
        var tags = 32   // "/waves.com/remote/GiveRackInfo" and its NUL, padded to 4
        XCTAssertEqual(ProLinkOSC.readString(bytes, &tags), ",ii[isiiiiiiFTi][isiiiiiiFTi]")
        XCTAssertEqual(ProLinkOSC.decode(bytes), m)
        XCTAssertEqual(m.command, "GiveRackInfo")
        XCTAssertEqual(m.id, 7)
        XCTAssertEqual(ProLinkRack.list(from: m.args), [kick, vox])
    }

    func testASplitFrameWaitsForTheRest() throws {
        let b = ProLinkWire.command("GetNumRacks", id: 9, [.int(4)])
        var p = ProLinkWire.Parser()
        XCTAssertEqual(try p.feed(Array(b[..<20])), [])
        let frames = try p.feed(Array(b[20...]))
        guard case .osc(let data) = frames.first, let m = ProLinkOSC.decode(data) else { return XCTFail() }
        XCTAssertEqual(m.args, [.int(9), .int(4)])
    }
}

final class ProLinkRackTests: XCTestCase {
    /// The record waveslib.tcl's own comment gives: {0 {Rack 1} 1 1 100 100 -1 -1 false true 0}.
    func testLAWOsExampleRecord() throws {
        let args: [ProLinkOSC.Arg] = [.int(0), .string("Rack 1"), .int(1), .int(1), .int(100), .int(100),
                                      .int(-1), .int(-1), .bool(false), .bool(true), .int(0)]
        let r = try XCTUnwrap(ProLinkRack(record: args[...]))
        XCTAssertEqual(r, ProLinkRack(index: 0, name: "Rack 1"))
        XCTAssertEqual(r.arguments, args)
        XCTAssertFalse(r.takes(inputChannel: 0), "a rack no input feeds takes no channel")
    }

    func testARecordHasElevenTypedFields() {
        let good = ProLinkRack(index: 3, name: "Bass").arguments
        XCTAssertNil(ProLinkRack(record: good.dropLast()[...]))
        var wrong = good
        wrong[8] = .int(0)   // mute is T or F
        XCTAssertNil(ProLinkRack(record: wrong[...]))
    }

    func testTheListSkipsTheCountAndBadRecords() {
        let a = ProLinkRack(index: 0, name: "Kick", firstInputChannel: 0)
        let b = ProLinkRack(index: 1, name: "Snare", firstInputChannel: 1)
        let args: [ProLinkOSC.Arg] = [.int(3), .arrayStart] + a.arguments + [.arrayEnd]
            + [.arrayStart, .int(9), .arrayEnd]
            + [.arrayStart] + b.arguments + [.arrayEnd]
        XCTAssertEqual(ProLinkRack.list(from: args), [a, b])
        XCTAssertEqual(ProLinkRack.list(from: [.int(1), .arrayStart] + a.arguments), [], "an array never closed")
    }

    /// The list from 2026-11-07, as NotifyRacksConfigChanged carried it (the count, then the racks).
    func testTheListSuperRackSent() {
        var args: [ProLinkOSC.Arg] = [.int(16)]
        for r in capturedRacks { args += [.arrayStart] + r.arguments + [.arrayEnd] }
        let racks = ProLinkRack.list(from: args)
        XCTAssertEqual(racks, capturedRacks)
        XCTAssertEqual(racks.filter { $0.takes(inputChannel: 13) }.map(\.name), ["Lec"], "stereo: 12 and 13")
        XCTAssertEqual(racks.filter { $0.takes(inputChannel: 3) }, [], "nothing on input 3")
        XCTAssertEqual(racks.filter { $0.firstInputChannel < 0 }.count, 6)
    }
}

final class ProLinkConsoleTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.prolink")
    private var listener: TestListener!
    private var console: ProLinkConsole!
    private var clock = DispatchTime.now()
    private var results: [(Int32, Int32)] = []

    override func setUp() {
        listener = TestListener(port: 50002, queue: queue)
        console = ProLinkConsole(listener: listener, queue: queue)
        console.now = { [unowned self] in self.clock }
        console.onResult = { [unowned self] id, err, _ in self.results.append((id, err)) }
        queue.sync { console.start() }
    }

    override func tearDown() { queue.sync { console.stop() } }

    private func settle() { for _ in 0..<20 { queue.sync {} } }
    private func on<T>(_ f: () -> T) -> T { queue.sync(execute: f) }
    private var state: ProLinkConsole.State { on { console.state } }

    /// Moves the clock on and runs the timer's work once.
    private func advance(ms: Int) {
        queue.sync {
            clock = clock + .milliseconds(ms)
            console.tick()
        }
    }

    private func connect() -> FakeProLinkPeer {
        let sr = FakeProLinkPeer(listener.dial(from: "169.254.136.158:52116"))
        sr.hello()
        settle()
        return sr
    }

    func testTheHandshakeThenTheRacks() throws {
        XCTAssertEqual(state, .listening(50002))
        let link = listener.dial(from: "169.254.136.158:52116")
        XCTAssertEqual(state, .handshaking(peer: "169.254.136.158:52116"))
        XCTAssertTrue(link.started)
        let sr = FakeProLinkPeer(link)
        XCTAssertEqual(sr.heardFrames, [], "SuperRack speaks first")
        sr.hello()
        settle()
        guard case .initialize(let h)? = sr.heardFrames.first else { return XCTFail("\(sr.heardFrames)") }
        XCTAssertEqual(h.dataFormat, 0)
        XCTAssertEqual(h.major, 1)
        XCTAssertEqual(h.minor, 0)
        XCTAssertEqual(h.keepAlive, 2000)
        XCTAssertEqual(h.description, "Remora")
        XCTAssertEqual(state, .connected(peer: "169.254.136.158:52116", name: "Waves SuperRack 15.15.12.13 Build 288878"))
        XCTAssertEqual(sr.commands, ["GetRacksInfo -1"])
        XCTAssertEqual(on { console.racks }, capturedRacks)
        XCTAssertEqual(on { console.rack(forInputChannel: 13)?.name }, "Lec")
        XCTAssertEqual(on { console.rack(named: "MAINS")?.index }, 9)
    }

    func testANotifyReplacesTheRacks() {
        let sr = connect()
        var args: [ProLinkOSC.Arg] = [.int(2)]
        for r in capturedRacks.prefix(2) { args += [.arrayStart] + r.arguments + [.arrayEnd] }
        sr.link.receive(ProLinkWire.osc(.init(address: "/waves.com/remote/NotifyRacksConfigChanged", args: args)))
        XCTAssertEqual(on { console.racks.map(\.name) }, ["head 1", "head 2"])
    }

    func testCommandsGoOneAtATime() {
        let sr = connect()
        sr.set(answers: false)
        let ids = on { [console.showRack(inputChannelIndex: 8), console.navigateRack(next: true), console.setViewMode(.overview)] }
        XCTAssertEqual(sr.commands, ["GetRacksInfo -1", "ShowRack 8"])
        sr.answerNext()
        settle()
        XCTAssertEqual(sr.commands.last, "NavigateRack 0")
        sr.answerNext()
        settle()
        XCTAssertEqual(sr.commands.last, "SetViewMode 3")
        XCTAssertEqual(on { results.map(\.0) }, [ids[0], ids[1]].compactMap { $0 })
        XCTAssertEqual(on { results.map(\.1) }, [0, 0])
    }

    func testOnlyRackCommandsCanBeSent() {
        let sr = connect()
        XCTAssertNil(on { console.send("DeleteSnapshot", [.int(1)]) })
        XCTAssertNil(on { console.send("SetSnapshotName", [.int(1), .string("x")]) })
        XCTAssertNil(on { console.send("showrack", [.int(8)]) }, "names are matched exactly")
        settle()
        XCTAssertEqual(sr.commands, ["GetRacksInfo -1"])
        XCTAssertEqual(ProLinkConsole.commands, ["GetRacksInfo", "ShowRack", "NavigateRack", "NavigatePlugin", "SetViewMode"])
    }

    func testQueuedMovesCanBeDropped() {
        let sr = connect()
        sr.set(answers: false)
        let dropped = on { () -> [Int32] in
            console.showRack(inputChannelIndex: 8)
            let later = [console.showRack(inputChannelIndex: 9), console.navigateRack(next: false)].compactMap { $0 }
            console.setViewMode(.rack)
            XCTAssertEqual(console.cancelWaiting(["ShowRack", "NavigateRack"]), later)
            return later
        }
        XCTAssertEqual(dropped.count, 2)
        sr.answerNext()
        settle()
        XCTAssertEqual(sr.commands, ["GetRacksInfo -1", "ShowRack 8", "SetViewMode 2"])
    }

    func testAnUnansweredCommandStopsHoldingTheQueue() {
        let sr = connect()
        sr.set(answers: false)
        on {
            console.showRack(inputChannelIndex: 8)
            console.showRack(inputChannelIndex: 9)
        }
        advance(ms: 900)
        XCTAssertEqual(sr.commands.last, "ShowRack 8")
        advance(ms: 200)
        XCTAssertEqual(sr.commands.last, "ShowRack 9")
    }

    func testKeepAliveBothWays() {
        let sr = connect()
        advance(ms: 999)
        XCTAssertEqual(sr.alives, 0)
        advance(ms: 1)
        XCTAssertEqual(sr.alives, 1, "half the 2 s keepAlive")
        advance(ms: 4000)
        sr.link.receive(ProLinkWire.iAmAlive())
        advance(ms: 6999)
        XCTAssertTrue(on { console.isConnected }, "three keepAlives and a second")
        advance(ms: 2)
        XCTAssertEqual(state, .listening(50002))
        XCTAssertEqual(sr.heardFrames.last, .close(ProLinkWire.Reason.keepAliveTimeout.rawValue))
        XCTAssertTrue(sr.link.isClosed)
    }

    func testAHandshakeThatNeverEnds() {
        let link = listener.dial()
        advance(ms: 5001)
        XCTAssertEqual(state, .listening(50002))
        XCTAssertEqual(link.frames, [.close(ProLinkWire.Reason.connectTimeout.rawValue)])
    }

    func testASecondSuperRackIsTurnedAway() {
        let sr = connect()
        let other = listener.dial(from: "10.0.0.9:50000")
        XCTAssertTrue(other.isClosed)
        XCTAssertFalse(other.started)
        XCTAssertEqual(other.frames, [.close(ProLinkWire.Reason.alreadyConnected.rawValue)])
        XCTAssertEqual(state, .connected(peer: "169.254.136.158:52116", name: "Waves SuperRack 15.15.12.13 Build 288878"))
        XCTAssertFalse(sr.link.isClosed)
    }

    func testAHangUpGoesBackToListening() {
        let sr = connect()
        sr.link.hangUp()
        XCTAssertEqual(state, .listening(50002))
        XCTAssertNil(on { console.showRack(inputChannelIndex: 8) }, "nothing waits for the link")
        let again = connect()
        XCTAssertTrue(on { console.isConnected })
        XCTAssertEqual(again.commands, ["GetRacksInfo -1"])
    }

    func testBadDataDropsThePeer() {
        let link = listener.dial()
        link.receive(Array("GET / HTTP/1.1\r\n\r\n".utf8))
        XCTAssertEqual(state, .listening(50002))
        XCTAssertEqual(link.frames, [.close(ProLinkWire.Reason.receivedBadHeader.rawValue)])
    }

    func testAFormatOrCommandSetItCannotSpeak() {
        let a = listener.dial()
        a.receive(superRackInit(format: 1))
        XCTAssertEqual(a.frames, [.close(ProLinkWire.Reason.notSupportedFormat.rawValue)])
        let b = listener.dial()
        b.receive(superRackInit(major: 2))
        XCTAssertEqual(b.frames, [.close(ProLinkWire.Reason.notSupportedProtocolVersion.rawValue)])
        XCTAssertEqual(state, .listening(50002))
    }

    func testStoppingTellsSuperRack() {
        let sr = connect()
        queue.sync { console.stop() }
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(sr.heardFrames.last, .close(ProLinkWire.Reason.disconnectRequestShutdown.rawValue))
        XCTAssertTrue(sr.link.isClosed)
    }

    func testAPortInUseSaysSo() {
        let l = TestListener(port: 50002, queue: queue)
        l.failure = "TCP 50002 is in use by another program"
        let c = ProLinkConsole(listener: l, queue: queue)
        queue.sync { c.start() }
        XCTAssertEqual(queue.sync { c.state }, .failed("TCP 50002 is in use by another program"))
    }
}

final class SuperRackProLinkModuleTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    /// A ProLink module on a test platform, and what it reported.
    private final class Rig {
        let platform: TestPlatform
        let module: SuperRackProLinkModule
        private var events: [HostEvent] = []   // on the module's queue
        var listener: TestListener { platform.listeners.last! }

        init(_ settings: Settings = Settings(), platform: TestPlatform = TestPlatform()) {
            self.platform = platform
            module = SuperRackProLinkModule(ModuleContext(settings: settings, platform: platform))
            module.onEvent = { [unowned self] e in self.events.append(e) }
            module.start()
        }

        @discardableResult
        func connect(racks: [ProLinkRack] = capturedRacks) -> FakeProLinkPeer {
            let sr = FakeProLinkPeer(listener.dial(from: "169.254.136.158:52116"), racks: racks)
            sr.hello()
            settle()
            return sr
        }

        func perform(_ c: HostCommand) {
            module.perform(c)
            settle()
        }

        func settle() { for _ in 0..<30 { listener.queue.sync {} } }
        var mark: Int { listener.queue.sync { events.count } }
        func events(since mark: Int = 0) -> [HostEvent] { listener.queue.sync { Array(events.dropFirst(mark)) } }
    }

    func testWaitingForSuperRackIsTheProblem() {
        let rig = Rig()
        XCTAssertEqual(rig.listener.port, 50002)
        XCTAssertEqual(rig.events(), [.link(.listening(50002)), .problem("not connected (Remora is waiting on TCP 50002)"),
                                      .position(nil)])
        rig.perform(.show(3))
        rig.perform(.step(1))
        XCTAssertEqual(rig.events().count, 3, "nothing sent, nothing reported")
    }

    func testConnectingListsTheRacks() {
        let rig = Rig()
        let mark = rig.mark
        let sr = rig.connect()
        XCTAssertEqual(sr.commands, ["GetRacksInfo -1"])
        XCTAssertEqual(rig.events(since: mark), [
            .link(.connecting(peer: "169.254.136.158:52116")),
            .link(.connected(name: "Waves SuperRack 15.15.12.13 Build 288878", peer: "169.254.136.158:52116")),
            .problem(nil),
            // Each rack's inputs, from 1: SuperRack's input 4 (from 0) is the host's input 5.
            .racks([Rack(index: 0, name: "head 1", inputs: [5]), Rack(index: 1, name: "head 2", inputs: [6]),
                    Rack(index: 2, name: "n/a", inputs: [7]), Rack(index: 3, name: "head 4", inputs: [8]),
                    Rack(index: 4, name: "hh 1", inputs: [9]), Rack(index: 5, name: "hh 2", inputs: [10]),
                    Rack(index: 6, name: "hh 3", inputs: [11]), Rack(index: 7, name: "n/a", inputs: [12]),
                    Rack(index: 8, name: "Lec", inputs: [13, 14]), Rack(index: 9, name: "mains", inputs: [15, 16])]
                   + (10..<16).map { Rack(index: $0, name: "Rack \($0 + 1)") }),
        ])
        let gone = rig.mark
        sr.link.hangUp()
        rig.settle()
        XCTAssertEqual(rig.events(since: gone), [.link(.listening(50002)), .problem("not connected (Remora is waiting on TCP 50002)"),
                                                 .position(nil)])
    }

    /// ShowRack on the rack's first input channel: "hh 1" is fed from input 8, as on 2026-11-07.
    func testShowGoesByTheRacksFirstInput() {
        let rig = Rig()
        let sr = rig.connect()
        let mark = rig.mark
        rig.perform(.show(4))
        XCTAssertEqual(sr.commands.last, "ShowRack 8")
        XCTAssertEqual(rig.events(since: mark), [.position(4)])
        sr.set(refusing: ["ShowRack"])
        rig.perform(.show(8))
        XCTAssertEqual(sr.commands.last, "ShowRack 12")
        XCTAssertEqual(rig.events(since: mark).last, .position(nil), "refused: where SuperRack is, is not known")
        rig.perform(.show(40))
        XCTAssertEqual(sr.commands.last, "ShowRack 12", "no rack 41")
    }

    /// No input feeds racks 11 to 16: the nearest fed rack ("mains", 9) and steps from there.
    func testARackNoInputFeedsIsReachedFromTheNearestOne() {
        let rig = Rig()
        let sr = rig.connect()
        let mark = rig.mark
        rig.perform(.show(12))
        XCTAssertEqual(Array(sr.commands.dropFirst()), ["ShowRack 14", "NavigateRack 0", "NavigateRack 0", "NavigateRack 0"])
        XCTAssertEqual(rig.events(since: mark), [.position(12)])
        let unfed = capturedRacks.map { r -> ProLinkRack in var r = r; r.firstInputChannel = -1; return r }
        let lone = Rig()
        let sr2 = lone.connect(racks: unfed)
        lone.perform(.show(2))
        XCTAssertEqual(sr2.commands, ["GetRacksInfo -1"], "no rack has an input: nothing to start from")
    }

    func testANewerMoveDropsTheQueuedOnes() {
        let rig = Rig()
        let sr = rig.connect()
        sr.set(answers: false)
        rig.perform(.show(12))   // ShowRack 14 goes; three NavigateRack wait
        rig.perform(.show(0))
        sr.answerNext()
        rig.settle()
        XCTAssertEqual(Array(sr.commands.dropFirst()), ["ShowRack 14", "ShowRack 4"])
    }

    func testStepsPlugInsAndViews() {
        let rig = Rig()
        let sr = rig.connect()
        rig.perform(.step(2))
        rig.perform(.step(-1))
        rig.perform(.stepPlugin(1))
        rig.perform(.stepPlugin(-1))
        rig.perform(.overview)
        rig.perform(.openRack)
        rig.perform(.resync)
        XCTAssertEqual(Array(sr.commands.dropFirst()), [
            "NavigateRack 0", "NavigateRack 0", "NavigateRack 1", "NavigatePlugin 0", "NavigatePlugin 1",
            "SetViewMode 3", "SetViewMode 2", "GetRacksInfo -1",
        ])
        let mark = rig.mark
        rig.perform(.cc(number: 30, value: 127))
        XCTAssertEqual(sr.commands.count, 9, "ProLink has no MIDI")
        XCTAssertEqual(rig.events(since: mark), [])
    }

    func testAnotherPortMakesAnotherListener() {
        let p = TestPlatform()
        let rig = Rig(platform: p)
        var s = Settings()
        s.proLinkPort = 50010
        rig.module.update(s)
        XCTAssertEqual(p.listeners.map(\.port), [50002, 50010])
        XCTAssertEqual(p.listeners[0].state, .stopped)
        XCTAssertEqual(p.listeners[1].state, .listening(50010))
        rig.module.stop()
        XCTAssertEqual(p.listeners[1].state, .stopped)
    }

    /// Through the engine: the host's link in the status, and a selected rack shown.
    func testThroughTheBridge() {
        var s = Settings()
        s.pluginHost = "superrack.prolink"
        let p = TestPlatform()
        let b = Bridge(settings: s, sink: NullSink(), platform: p)
        b.start()
        defer { b.stop() }
        XCTAssertEqual(b.hostInfo?.id, "superrack.prolink")
        XCTAssertEqual(b.status.hostLink, .listening(50002))
        XCTAssertEqual(b.status.sessionError, "not connected (Remora is waiting on TCP 50002)")
        let l = p.listeners[0]
        let sr = FakeProLinkPeer(l.dial())
        sr.hello()
        for _ in 0..<30 { l.queue.sync {} }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(b.status.hostLink, .connected(name: "Waves SuperRack 15.15.12.13 Build 288878", peer: "127.0.0.1:50100"))
        XCTAssertNil(b.status.sessionError)
        XCTAssertEqual(b.status.racks.count, 16)
        b.select(rack: 9)
        for _ in 0..<30 { l.queue.sync {} }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(sr.commands.last, "ShowRack 14")
        XCTAssertEqual(b.status.position, 9)
    }
}

/// The two SuperRack editions: where each keeps its session, its app and its log.
final class SuperRackEditionTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    func testEachEditionsPlaces() {
        XCTAssertEqual(SuperRackEdition.performer.defaultSessionPath, Settings.defaultSessionPath)
        XCTAssertEqual(SuperRackEdition.soundGrid.defaultSessionPath, "/Users/Shared/Waves/SuperRack SoundGrid/Sessions/CurrentSPRK.dat")
        XCTAssertEqual(SuperRackEdition.performer.bundleID, "com.WavesAudio.SuperRack-Performer")
        XCTAssertEqual(SuperRackEdition.soundGrid.bundleID, "com.WavesAudio.SuperRack-SoundGrid")
        XCTAssertTrue(SuperRackEdition.soundGrid.logPath.hasSuffix("/Library/Logs/Waves Audio/SuperRack SoundGridApplication.log"))
        XCTAssertEqual(PluginWindowGuard(edition: .soundGrid, logPath: "/nonexistent").appName, "SuperRack SoundGrid")
    }

    /// A platform with window watchers, keeping the edition each was made for.
    private final class WatchingPlatform: PluginWindowPlatform {
        final class Watcher: PluginWindowWatcher {
            var onStatus: ((PluginWindowStatus) -> Void)?
            var onReopen: (() -> Void)?
            private(set) var options: [PluginWindowOptions] = []
            private(set) var stopped = false
            var canReadRackName: Bool { false }
            func readRackName() -> String? { nil }
            func set(_ o: PluginWindowOptions) { options.append(o) }
            func setChains(_ chains: [RackChain]) {}
            func stop() { stopped = true }
        }
        let base = TestPlatform()
        private(set) var made: [(edition: SuperRackEdition, watcher: Watcher)] = []
        func tcp(host: String, port: UInt16, queue: DispatchQueue) -> TCPStream { base.tcp(host: host, port: port, queue: queue) }
        func tcpListener(port: UInt16, queue: DispatchQueue) -> TCPListener { base.tcpListener(port: port, queue: queue) }
        func midi(name: String) -> MIDILink? { nil }
        func oscReceiver() -> OSCReceiver { base.oscReceiver() }
        func pluginWindowWatcher(for edition: SuperRackEdition) -> PluginWindowWatcher {
            let w = Watcher()
            made.append((edition, w))
            return w
        }
    }

    func testTheMIDIModuleWatchesTheEditionChosen() {
        let p = WatchingPlatform()
        var s = Settings()
        s.sessionPath = "/nonexistent/CurrentSPRKP.dat"
        s.closePluginWindows = true
        let m = SuperRackMIDIModule(ModuleContext(settings: s, platform: p, midiOut: NullSink()))
        m.start()
        defer { m.stop() }
        XCTAssertEqual(p.made.map(\.edition), [.performer])
        s.superRackEdition = .soundGrid
        m.update(s)
        XCTAssertEqual(p.made.map(\.edition), [.performer, .soundGrid])
        XCTAssertTrue(p.made[0].watcher.stopped)
        XCTAssertEqual(p.made[1].watcher.options, [s.pluginWindowOptions])
    }

    /// ProLink makes no guard until a window option is on, and its guard never reopens or reads.
    func testTheProLinkModulesGuard() {
        let p = WatchingPlatform()
        var s = Settings()
        XCTAssertEqual(s.pluginWindowOptions, PluginWindowOptions(readRack: true), "the default")
        let m = SuperRackProLinkModule(ModuleContext(settings: s, platform: p))
        m.start()
        defer { m.stop() }
        XCTAssertTrue(p.made.isEmpty)
        s.closePluginWindows = true
        s.reopenPluginAfterRackChange = true
        m.update(s)
        XCTAssertEqual(p.made.map(\.edition), [.performer])
        XCTAssertEqual(p.made[0].watcher.options, [PluginWindowOptions(close: true, reopen: false, readRack: false)])
        s.superRackEdition = .soundGrid
        m.update(s)
        XCTAssertEqual(p.made.map(\.edition), [.performer, .soundGrid])
        XCTAssertTrue(p.made[0].watcher.stopped)
    }
}

/// The console over the real listener, with SuperRack's side played over loopback TCP.
final class TCPServerTests: XCTestCase {
    /// Dials, says Init first, acks the console's Init, lists racks for GetRacksInfo and answers
    /// every other command.
    private final class LoopbackPeer {
        let queue = DispatchQueue(label: "test.peer")
        let connection: NWConnection
        var onCommand: ((String) -> Void)?
        var onFrame: ((ProLinkWire.Frame) -> Void)?
        var onEnd: (() -> Void)?
        private var parser = ProLinkWire.Parser()

        init(port: UInt16) {
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] st in
                if case .ready = st { self?.send(superRackInit(description: "SuperRack (loopback)")) }
            }
            connection.start(queue: queue)
            receive()
        }

        func cancel() { queue.sync { connection.cancel() } }

        private func send(_ b: [UInt8]) { connection.send(content: Data(b), completion: .contentProcessed { _ in }) }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data, let frames = try? self.parser.feed([UInt8](data)) { frames.forEach(self.handle) }
                if done || error != nil { self.onEnd?() } else { self.receive() }
            }
        }

        private func handle(_ f: ProLinkWire.Frame) {
            onFrame?(f)
            switch f {
            case .initialize: send(ProLinkWire.handshakeAck())
            case .osc(let b):
                guard let m = ProLinkOSC.decode(b), let id = m.id else { return }
                onCommand?(said(m))
                send(m.command == "GetRacksInfo" ? giveRackInfo(id, Array(capturedRacks.prefix(2))) : resultCommand(id, m.command))
            default: break
            }
        }
    }

    func testProLinkOverLoopback() throws {
        let queue = DispatchQueue(label: "test.tcpserver")
        let server = TCPServer(port: 0, queue: queue)
        let console = ProLinkConsole(listener: server, queue: queue)
        let listening = expectation(description: "listening")
        let connected = expectation(description: "connected")
        let racks = expectation(description: "racks")
        let back = expectation(description: "listening again")
        var port: UInt16 = 0
        var peers: [String] = []
        console.onState = { st in
            switch st {
            case .listening(let p):
                if port == 0 {
                    port = p
                    listening.fulfill()
                } else {
                    back.fulfill()
                }
            case .connected(let peer, let name):
                XCTAssertEqual(name, "SuperRack (loopback)")
                peers.append(peer)
                connected.fulfill()
            default: break
            }
        }
        console.onRacks = { r in if r.count == 2 { racks.fulfill() } }
        queue.sync { console.start() }
        wait(for: [listening], timeout: 5)
        XCTAssertNotEqual(port, 0)

        let sr = LoopbackPeer(port: port)
        let shown = expectation(description: "ShowRack heard")
        sr.onCommand = { if $0 == "ShowRack 8" { shown.fulfill() } }
        sr.start()
        wait(for: [connected, racks], timeout: 5)
        let peer = queue.sync { peers.first ?? "" }
        XCTAssertTrue(peer.hasPrefix("127.0.0.1:"), peer)
        queue.sync { _ = console.showRack(inputChannelIndex: 8) }
        wait(for: [shown], timeout: 5)

        // A second SuperRack is told why, and let go.
        let other = LoopbackPeer(port: port)
        let refused = expectation(description: "Close 1002")
        let ended = expectation(description: "closed")
        other.onFrame = { if $0 == .close(ProLinkWire.Reason.alreadyConnected.rawValue) { refused.fulfill() } }
        other.onEnd = { ended.fulfill() }
        other.start()
        wait(for: [refused, ended], timeout: 5)
        XCTAssertTrue(queue.sync { console.isConnected })

        sr.cancel()
        wait(for: [back], timeout: 5)
        queue.sync { console.stop() }

        // Listening again on the same port straight after, as a relaunch would.
        let again = TCPServer(port: port, queue: queue)
        let relisten = expectation(description: "listening on the same port")
        var states: [ListenerState] = []
        again.onState = {
            states.append($0)
            if $0 == .listening(port) { relisten.fulfill() }
        }
        queue.sync { again.start() }
        wait(for: [relisten], timeout: 3)
        XCTAssertEqual(queue.sync { states }, [.listening(port)], "no failure shown while the old one lets go")
        queue.sync { again.stop() }
    }

    func testAPortInUseSaysSo() {
        let queue = DispatchQueue(label: "test.inuse")
        let first = TCPServer(port: 0, queue: queue)
        let up = expectation(description: "listening")
        var port: UInt16 = 0
        first.onState = { if case .listening(let p) = $0 { port = p; up.fulfill() } }
        queue.sync { first.start() }
        wait(for: [up], timeout: 5)
        let second = TCPServer(port: port, queue: queue)
        let failed = expectation(description: "in use")
        second.onState = { st in
            if case .failed(let why) = st {
                XCTAssertEqual(why, "TCP \(port) is in use by another program")
                failed.fulfill()
            }
        }
        queue.sync { second.start() }
        wait(for: [failed], timeout: 5)
        queue.sync {
            second.stop()
            first.stop()
        }
    }
}
