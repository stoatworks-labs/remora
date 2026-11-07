import XCTest
@testable import RemoraApple
@testable import RemoraConsoles
@testable import RemoraCore
@testable import RemoraEngine
@testable import RemoraHosts

/// A made-up OSC host, for the shared module's own tests: `/show i` shows rack i (1-based),
/// `/next` and `/prev` step, `/list` asks, and it answers `/racks s…` and `/at i`.
enum ExampleOSCHost {
    static func info(_ capabilities: Capabilities = [], replyPort: UInt16? = nil,
                     typedRacks: Bool = false) -> ModuleInfo {
        ModuleInfo(id: "example.osc", kind: .host, title: "Example", product: "Example", maker: "Example",
                   status: .experimental, about: "", platforms: [.macOS], reach: .network,
                   capabilities: capabilities,
                   hostDefaults: HostDefaults(port: 7000, replyPort: replyPort, typedRacks: typedRacks))
    }

    static func spec(_ info: ModuleInfo, steps: Bool = true) -> OSCHostSpec {
        OSCHostSpec(
            info: info,
            show: { i, _ in [OSC.Message(address: "/show", args: [.int(Int32(i + 1))])] },
            step: steps ? { d in [OSC.Message(address: d > 0 ? "/next" : "/prev", args: [])] } : nil,
            ask: [OSC.Message(address: "/list", args: [])],
            read: { m in
                switch m.address {
                case "/racks": return [.racks(m.args.map(\.text))]
                case "/at": return m.args.first?.number.map { [.position(Int($0) - 1)] } ?? []
                default: return []
                }
            },
            isAllowed: OSCHostSpec.only(["/show": ["i"], "/next": [""], "/prev": [""], "/list": [""]]))
    }

    static func entry(_ info: ModuleInfo, steps: Bool = true) -> HostModuleEntry {
        HostModuleEntry(info) { OSCHostModule(spec(info, steps: steps), $0) }
    }
}

/// What a test UDP link has sent, as OSC.
extension TestUDP {
    var messages: [OSC.Message] { queue.sync { sent.flatMap { OSC.parse($0) } } }
    func answer(_ address: String, _ args: [OSC.Arg] = []) {
        receive(OSC.encode(OSC.Message(address: address, args: args)))
    }
}

final class OSCHostTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    private func make(_ info: ModuleInfo, steps: Bool = true, settings: Settings = Settings())
        -> (OSCHostModule, TestPlatform, () -> [HostEvent]) {
        let p = TestPlatform()
        let m = OSCHostModule(ExampleOSCHost.spec(info, steps: steps), ModuleContext(settings: settings, platform: p))
        var events: [HostEvent] = []
        let lock = NSLock()
        m.onEvent = { e in lock.lock(); events.append(e); lock.unlock() }
        return (m, p, { m.waitUntilIdle(); lock.lock(); defer { lock.unlock() }; return events })
    }

    func testItAsksThenReadsTheRacksAndWhereTheHostIs() throws {
        let (m, p, events) = make(ExampleOSCHost.info())
        m.start()
        let u = try XCTUnwrap(p.udps.first)
        XCTAssertEqual(u.host, "127.0.0.1")
        XCTAssertEqual(u.port, 7000)
        XCTAssertEqual(u.messages, [OSC.Message(address: "/list", args: [])])
        XCTAssertEqual(events(), [.link(.connecting(peer: "127.0.0.1:7000"))])
        u.answer("/racks", [.string("Vox"), .string("Gtr")])
        u.answer("/at", [.int(2)])
        u.answer("/whatever", [.int(9)])
        XCTAssertEqual(events().dropFirst(), [.link(.connected(name: "Example", peer: "127.0.0.1:7000")),
                                              .racks([Rack(index: 0, name: "Vox"), Rack(index: 1, name: "Gtr")]),
                                              .position(1)])
    }

    func testShowAndStepSendWhatTheSpecSays() throws {
        let (m, p, events) = make(ExampleOSCHost.info())
        m.start()
        let u = try XCTUnwrap(p.udps.first)
        u.answer("/racks", [.string("A"), .string("B"), .string("C")])
        m.perform(.show(1))
        m.perform(.step(1))
        m.perform(.step(1))
        m.perform(.step(-1))
        _ = events()
        XCTAssertEqual(u.messages.map(\.address), ["/list", "/show", "/next", "/next", "/prev"])
        XCTAssertEqual(u.messages[1].args, [.int(2)])
        // Stepped from rack 2 to 3, held at 3 (the last), back to 2.
        XCTAssertEqual(events().compactMap { if case .position(let p) = $0 { return p } else { return nil } },
                       [1, 2, 2, 1])
    }

    func testAHostWithNoStepIsSteppedByShowingTheNextRack() throws {
        let (m, p, _) = make(ExampleOSCHost.info(), steps: false)
        m.start()
        let u = try XCTUnwrap(p.udps.first)
        m.perform(.step(1))   // where it is is not known: nothing sent
        m.perform(.show(4))
        m.perform(.step(1))
        m.perform(.step(-1))
        m.waitUntilIdle()
        XCTAssertEqual(u.messages.dropFirst().map(\.args), [[.int(5)], [.int(6)], [.int(5)]])
    }

    func testWhatTheHostCantDoIsDroppedAndResyncAsksAgain() throws {
        let (m, p, events) = make(ExampleOSCHost.info())
        m.start()
        let u = try XCTUnwrap(p.udps.first)
        m.perform(.stepPlugin(1))
        m.perform(.overview)
        m.perform(.openRack)
        m.perform(.cc(number: 20, value: 127))
        m.perform(.show(2))
        m.perform(.resync)
        XCTAssertEqual(u.messages.map(\.address), ["/list", "/show", "/list"])
        XCTAssertEqual(events().suffix(2), [.position(2), .position(nil)])
    }

    func testEverythingSentIsOnTheWhitelist() {
        let spec = ExampleOSCHost.spec(ExampleOSCHost.info())
        XCTAssertTrue(spec.isAllowed(OSC.Message(address: "/show", args: [.int(3)])))
        XCTAssertFalse(spec.isAllowed(OSC.Message(address: "/show", args: [.string("3")])))
        XCTAssertFalse(spec.isAllowed(OSC.Message(address: "/show", args: [])))
        XCTAssertFalse(spec.isAllowed(OSC.Message(address: "/delete", args: [])))
        XCTAssertFalse(spec.isAllowed(OSC.Message(address: "/next", args: [.int(1)])))
    }

    func testAnswersOnAPortOfRemorasOwn() throws {
        var s = Settings()
        s.editHost("example.osc") { $0.address = " 10.0.0.5 " }
        let (m, p, events) = make(ExampleOSCHost.info(replyPort: 9000), settings: s)
        m.start()
        // The module's receiver: the platform's first is the engine's, and here there is none.
        let r = try XCTUnwrap(p.oscs.last)
        XCTAssertEqual(r.port, 9000)
        XCTAssertEqual(p.udps.first?.host, "10.0.0.5")
        r.onMessage?(OSC.Message(address: "/racks", args: [.string("Only")]))
        XCTAssertEqual(events().last, .racks([Rack(index: 0, name: "Only")]))
        m.stop()
        XCTAssertNil(r.port)
    }

    func testAReplyPortInUseSaysSo() throws {
        struct InUse: Error {}
        let (m, p, events) = make(ExampleOSCHost.info(replyPort: 9000))
        // With no engine here, the module's receiver is the platform's first.
        p.osc.failure = InUse()
        m.start()
        XCTAssertEqual(events().first, .link(.failed("UDP 9000, for Example's answers, is in use by another program")))
    }

    func testTypedRacksStandForAHostThatCantList() throws {
        var s = Settings()
        s.editHost("example.osc") { $0.racks = [" Vox ", "", "Keys"] }
        let (m, p, events) = make(ExampleOSCHost.info(typedRacks: true), settings: s)
        m.start()
        XCTAssertEqual(events().first, .racks([Rack(index: 0, name: "Vox"), Rack(index: 1, name: "Keys")]))
        // What the host lists is ignored: the typed racks are the user's.
        p.udps.first?.answer("/racks", [.string("Other")])
        s.editHost("example.osc") { $0.racks = ["Vox", "Keys", "Pad"] }
        m.update(s)
        XCTAssertEqual(events().compactMap { if case .racks(let r) = $0 { return r.map(\.name) } else { return nil } },
                       [["Vox", "Keys"], ["Vox", "Keys", "Pad"]])
        XCTAssertEqual(p.udps.count, 1, "new racks are no reason to reconnect")
        s.editHost("example.osc") { $0.port = 7001 }
        m.update(s)
        XCTAssertEqual(p.udps.map(\.port), [7000, 7001])
    }
}

final class HostSettingsTests: XCTestCase {
    func testAHostsOwnSettingsAreSavedOnlyOnceSet() throws {
        var s = Settings()
        func saved() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        }
        XCTAssertNil(try saved()["hosts"])
        s.editHost("reaper.osc") { $0.port = 8001 }
        let hosts = try XCTUnwrap(try saved()["hosts"] as? [String: Any])
        XCTAssertEqual(Array(hosts.keys), ["reaper.osc"])
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.host("reaper.osc").port, 8001)
        XCTAssertEqual(back, s)
        s.editHost("reaper.osc") { $0.port = nil }
        XCTAssertNil(try saved()["hosts"], "a host back at its defaults leaves nothing behind")
    }

    func testEveryKeyIsOptionalAndTheChannelIsClamped() throws {
        let h = try JSONDecoder().decode(HostSettings.self, from: Data(#"{"midiChannel": 40, "racks": ["A"]}"#.utf8))
        XCTAssertEqual(h.midiChannel, 16)
        XCTAssertEqual(h.racks, ["A"])
        XCTAssertEqual(h.address, "")
        XCTAssertFalse(h.showChangesSoundAccepted)
        let d = HostDefaults(port: 8000, replyPort: 9000, midiChannel: 2)
        XCTAssertEqual(HostSettings().port(d), 8000)
        XCTAssertEqual(HostSettings().replyPort(d), 9000)
        XCTAssertEqual(HostSettings().midiChannel(d), 2)
        XCTAssertEqual(HostSettings().host, "127.0.0.1")
        // A newer Remora's host, or one with a bad entry, doesn't lose the rest.
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"hosts": {"a.b": {"port": 1}, "c.d": 7}}"#.utf8))
        XCTAssertEqual(s.host("a.b").port, 1)
    }
}

final class SoundGateTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    /// A host whose only way to show a rack loads it gets nothing until the user has ticked that
    /// they understand; then everything goes.
    func testNothingGoesToASoundChangingHostUntilTicked() throws {
        let info = ExampleOSCHost.info(.showChangesSound)
        let registry = ModuleRegistry(consoles: ModuleRegistry.standard.consoles,
                                      hosts: ModuleRegistry.standard.hosts + [ExampleOSCHost.entry(info)])
        var s = Settings()
        s.pluginHost = info.id
        let p = TestPlatform()
        let b = Bridge(settings: s, sink: FakeSuperRack(count: 4, at: 0), registry: registry, platform: p)
        b.start()
        defer { b.stop() }
        XCTAssertTrue(b.status.hostGated)
        let u = try XCTUnwrap(p.udps.first)
        b.select(rack: 2)
        b.send(.nextRack)
        b.resync()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(u.messages.map(\.address), [], "nothing at all, not even the ask, which only reads")
        s.editHost(info.id) { $0.showChangesSoundAccepted = true }
        b.update(s)
        XCTAssertFalse(b.status.hostGated)
        b.select(rack: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(u.messages.map(\.address), ["/list", "/show"], "ticked: the ask at once, then the show")
        // Ticked off again, it stops again.
        s.editHost(info.id) { $0.showChangesSoundAccepted = false }
        b.update(s)
        b.select(rack: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(u.messages.count, 2)
    }

    func testFollowStartsOffForASoundChangingHost() {
        var s = Settings()
        XCTAssertTrue(s.follow)
        s.pick(host: ExampleOSCHost.info())
        XCTAssertTrue(s.follow, "a host that only shows leaves follow alone")
        s.pick(host: ExampleOSCHost.info(.showChangesSound))
        XCTAssertFalse(s.follow)
        XCTAssertEqual(s.pluginHost, "example.osc")
        s.follow = true
        s.editHost("example.osc") { $0.showChangesSoundAccepted = true }
        s.pick(host: ExampleOSCHost.info(.showChangesSound))
        XCTAssertTrue(s.follow, "once ticked, picking it again leaves follow alone")
    }

    func testAHostThatOnlyShowsIsNeverGated() {
        let info = ExampleOSCHost.info()
        let registry = ModuleRegistry(consoles: [], hosts: [ExampleOSCHost.entry(info)])
        var s = Settings()
        s.pluginHost = info.id
        let b = Bridge(settings: s, sink: FakeSuperRack(count: 4, at: 0), registry: registry, platform: TestPlatform())
        XCTAssertFalse(b.status.hostGated)
        XCTAssertTrue(ModuleRegistry.standard.hosts.filter { !$0.info.experimental }
            .allSatisfy { !$0.info.capabilities.contains(.showChangesSound) })
    }
}

/// Remora's MIDI port, as a host hears it.
final class MIDIRecorder: CCSink {
    private let lock = NSLock()
    private var _heard: [(channel: Int, message: MIDIHostMessage)] = []
    var heard: [(channel: Int, message: MIDIHostMessage)] { lock.lock(); defer { lock.unlock() }; return _heard }
    var messages: [MIDIHostMessage] { heard.map(\.message) }
    func sendCC(channel: Int, number: Int, value: Int) {
        lock.lock(); _heard.append((channel, .cc(number: number, value: value))); lock.unlock()
    }
    func sendProgramChange(channel: Int, program: Int) {
        lock.lock(); _heard.append((channel, .programChange(program))); lock.unlock()
    }
}

/// A made-up MIDI host: Program Change n shows rack n + 1, CC 1 steps on and CC 2 back.
enum ExampleMIDIHost {
    static let info = ModuleInfo(id: "example.midi", kind: .host, title: "Example MIDI", product: "Example",
                                 maker: "Example", status: .experimental, about: "", platforms: [.macOS],
                                 reach: .local, capabilities: [],
                                 hostDefaults: HostDefaults(midiChannel: 3, typedRacks: true))
    static func spec(steps: Bool = true) -> MIDIHostSpec {
        MIDIHostSpec(info: info,
                     show: { i, _ in i < 128 ? [.programChange(i)] : [] },
                     step: steps ? { d in [.cc(number: d > 0 ? 1 : 2, value: 127)] } : nil,
                     isAllowed: { m in
                         switch m {
                         case .programChange(let p): return (0..<128).contains(p)
                         case .cc(let n, let v): return (n == 1 || n == 2) && v == 127
                         }
                     })
    }
}

final class MIDIHostTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    private func make(steps: Bool = true, settings: Settings = Settings(), sink: CCSink? = nil)
        -> (MIDIHostModule, MIDIRecorder, () -> [HostEvent]) {
        let r = MIDIRecorder()
        let m = MIDIHostModule(ExampleMIDIHost.spec(steps: steps),
                               ModuleContext(settings: settings, platform: TestPlatform(), midiOut: sink ?? r))
        var events: [HostEvent] = []
        let lock = NSLock()
        m.onEvent = { e in lock.lock(); events.append(e); lock.unlock() }
        return (m, r, { m.waitUntilIdle(); lock.lock(); defer { lock.unlock() }; return events })
    }

    func testShowAndStepOnTheHostsChannel() {
        var s = Settings()
        s.editHost("example.midi") { $0.racks = ["Piano", "Organ", "Pad"] }
        let (m, r, events) = make(settings: s)
        m.start()
        m.perform(.show(1))
        m.perform(.step(1))
        m.perform(.step(1))
        m.perform(.show(200))
        _ = events()
        XCTAssertEqual(r.messages, [.programChange(1), .cc(number: 1, value: 127), .cc(number: 1, value: 127)])
        XCTAssertEqual(Set(r.heard.map(\.channel)), [3])
        XCTAssertEqual(events(), [.racks([Rack(index: 0, name: "Piano"), Rack(index: 1, name: "Organ"),
                                          Rack(index: 2, name: "Pad")]),
                                  .position(1), .position(2)])
    }

    func testStepsByShowingWhenTheHostHasNoStep() {
        var s = Settings()
        s.editHost("example.midi") { $0.midiChannel = 9 }
        let (m, r, _) = make(steps: false, settings: s)
        m.start()
        m.perform(.step(1))   // nothing shown yet: nothing to step from
        m.perform(.show(5))
        m.perform(.step(-1))
        m.perform(.resync)
        m.perform(.step(-1))  // forgotten again
        m.perform(.stepPlugin(1))
        m.perform(.overview)
        m.perform(.cc(number: 20, value: 127))
        m.waitUntilIdle()
        XCTAssertEqual(r.messages, [.programChange(5), .programChange(4)])
        XCTAssertEqual(Set(r.heard.map(\.channel)), [9])
    }

    func testNoPortSaysSo() {
        let m = MIDIHostModule(ExampleMIDIHost.spec(), ModuleContext(settings: Settings(), platform: TestPlatform()))
        var events: [HostEvent] = []
        m.onEvent = { events.append($0) }
        m.start()
        XCTAssertEqual(events.first, .problem("Remora's MIDI port could not be made, so nothing reaches Example"))
    }
}
