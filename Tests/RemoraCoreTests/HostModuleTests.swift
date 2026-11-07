import XCTest
@testable import RemoraApple
@testable import RemoraConsoles
@testable import RemoraCore
@testable import RemoraEngine
@testable import RemoraHosts

/// Each stage 5 host: what it sends to show and step, what it reads, and its whitelist.
final class OSCHostModuleTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    private func run(_ spec: OSCHostSpec, racks: [String] = [], accepted: Bool = true,
                     _ commands: [HostCommand], answers: [OSC.Message] = [])
        -> (sent: [OSC.Message], events: [HostEvent], platform: TestPlatform) {
        var s = Settings()
        s.editHost(spec.info.id) {
            $0.racks = racks
            $0.showChangesSoundAccepted = accepted
        }
        let p = TestPlatform()
        let m = OSCHostModule(spec, ModuleContext(settings: s, platform: p))
        var events: [HostEvent] = []
        let lock = NSLock()
        m.onEvent = { e in lock.lock(); events.append(e); lock.unlock() }
        m.start()
        let u = p.udps[0]
        for a in answers {
            if let r = p.oscs.last, spec.info.hostDefaults.replyPort != nil { r.onMessage?(a) } else { u.receive(OSC.encode(a)) }
        }
        for c in commands { m.perform(c) }
        m.waitUntilIdle()
        m.stop()
        lock.lock()
        defer { lock.unlock() }
        return (u.messages, events, p)
    }

    /// Every message a spec can build is on its whitelist, and a few it must never send are not.
    private func assertWhitelisted(_ spec: OSCHostSpec, never: [OSC.Message], file: StaticString = #filePath, line: UInt = #line) {
        let racks = (0..<200).map { Rack(index: $0, name: "r\($0)") }
        var built = spec.ask
        for i in -1..<200 { built += spec.show(i, racks) }
        if let step = spec.step { built += step(1) + step(-1) }
        for m in built { XCTAssertTrue(spec.isAllowed(m), "\(m)", file: file, line: line) }
        for m in never { XCTAssertFalse(spec.isAllowed(m), "\(m)", file: file, line: line) }
    }

    func testLiveProfessorSelectsChainsFromOne() {
        let r = run(LiveProfessor.spec, racks: ["Vox", "Gtr", "Keys"], [.show(1), .step(1), .step(-1), .overview])
        XCTAssertEqual(r.sent, [OSC.Message(address: "/Chains/Select", args: [.int(2)]),
                                OSC.Message(address: "/Chains/Select/Next", args: []),
                                OSC.Message(address: "/Chains/Select/Previous", args: [])])
        XCTAssertEqual(r.events.first, .racks([Rack(index: 0, name: "Vox"), Rack(index: 1, name: "Gtr"), Rack(index: 2, name: "Keys")]))
        XCTAssertEqual(r.platform.udps.first?.port, 8000)
        XCTAssertTrue(LiveProfessor.spec.ask.isEmpty, "LiveProfessor is never asked anything")
        assertWhitelisted(LiveProfessor.spec, never: [
            OSC.Message(address: "/GlobalSnapshots/Recall", args: [.int(1)]),
            OSC.Message(address: "/Chains/Select", args: [.string("Vox")]),
            OSC.Message(address: "/Command/Save", args: []),
        ])
    }

    func testGigPerformerSwitchesRackspacesFromZero() {
        let r = run(GigPerformer.spec, racks: ["Piano", "Organ"], [.show(1), .show(1), .step(-1), .step(1)])
        XCTAssertEqual(r.sent, [OSC.Message(address: "/GigPerformer/SwitchToRackSpace", args: [.int(1)]),
                                OSC.Message(address: "/GigPerformer/PrevRackSpace", args: []),
                                OSC.Message(address: "/GigPerformer/NextRackSpace", args: [])],
                       "showing the rackspace it is on sends nothing")
        XCTAssertEqual(r.platform.udps.first?.port, 54344)
        XCTAssertTrue(GigPerformer.info.capabilities.contains(.showChangesSound))
        assertWhitelisted(GigPerformer.spec, never: [
            OSC.Message(address: "/GigPerformer/Panic", args: []),
            OSC.Message(address: "/GigPerformer/SwitchToRackSpace", args: [.int(1), .int(2)]),
            OSC.Message(address: "/GigPerformer/SetBPM", args: [.float(120)]),
        ])
    }

    func testVSTHostLoadsPerformancesAndAsksWhichIsLoaded() {
        let r = run(VSTHost.spec, racks: ["000", "Gig A", "Gig B"], [.show(2), .step(-1), .resync],
                    answers: [OSC.Message(address: "/performance/num", args: [.int(1)])])
        XCTAssertEqual(r.sent, [OSC.Message(address: "/performance/num", args: []),
                                OSC.Message(address: "/performance/num", args: [.int(2)]),
                                OSC.Message(address: "/performance/num", args: [.int(1)]),
                                OSC.Message(address: "/performance/num", args: [])])
        XCTAssertTrue(r.events.contains(.link(.connected(name: "VSTHost", peer: "127.0.0.1:7701"))))
        XCTAssertEqual(VSTHost.spec.read(OSC.Message(address: "/performance/num", args: [.int(-1)])), [.position(nil)])
        XCTAssertEqual(VSTHost.spec.read(OSC.Message(address: "/performance/num", args: [.float(4)])), [.position(4)])
        XCTAssertEqual(VSTHost.spec.poll, 2)
        assertWhitelisted(VSTHost.spec, never: [
            OSC.Message(address: "/plugin/1/bypass", args: [.int(1)]),
            OSC.Message(address: "/engine/run", args: [.int(0)]),
            OSC.Message(address: "/performance/num", args: [.string("1")]),
        ])
    }

    func testVSTHostIsAskedAgainWhilePolling() throws {
        // The spec's own two seconds, shortened: the module asks again by itself.
        var spec = VSTHost.spec
        spec.poll = 0.02
        var s = Settings()
        s.editHost(spec.info.id) { $0.showChangesSoundAccepted = true }
        let p = TestPlatform()
        let m = OSCHostModule(spec, ModuleContext(settings: s, platform: p))
        m.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        m.stop()
        let asked = try XCTUnwrap(p.udps.first).messages.count
        XCTAssertGreaterThan(asked, 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(p.udps.first?.messages.count, asked, "stopping stops the asking")
    }

    func testAHeldHostIsNeitherAskedNorSentAnythingUntilTicked() throws {
        // VSTHost loads what it shows. Unticked, the module doesn't even ask which performance is
        // loaded, and drops a command that got past the engine.
        var spec = VSTHost.spec
        spec.poll = 0.02
        var s = Settings()
        s.editHost(spec.info.id) { $0.racks = ["A", "B"] }
        let p = TestPlatform()
        let m = OSCHostModule(spec, ModuleContext(settings: s, platform: p))
        var events: [HostEvent] = []
        let lock = NSLock()
        m.onEvent = { e in lock.lock(); events.append(e); lock.unlock() }
        m.start()
        m.perform(.show(1))
        m.perform(.step(1))
        m.waitUntilIdle()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let u = try XCTUnwrap(p.udps.first)
        XCTAssertEqual(u.messages, [], "held: nothing at all")
        lock.lock()
        XCTAssertFalse(events.contains(.link(.connecting(peer: "127.0.0.1:7701"))))
        lock.unlock()

        s.editHost(spec.info.id) { $0.showChangesSoundAccepted = true }
        m.update(s)
        m.waitUntilIdle()
        XCTAssertEqual(u.messages.first, OSC.Message(address: "/performance/num", args: []), "ticked: asked at once")
        m.stop()
        lock.lock()
        XCTAssertTrue(events.contains(.link(.connecting(peer: "127.0.0.1:7701"))))
        lock.unlock()
    }

    func testAbletonReadsTrackNamesAndTheSelection() {
        let r = run(AbletonLive.spec, [.show(2), .step(1), .resync],
                    answers: [OSC.Message(address: "/live/song/get/track_names", args: [.string("Kick"), .string("Snare"), .string("Vox")]),
                              OSC.Message(address: "/live/view/get/selected_track", args: [.int(0)]),
                              OSC.Message(address: "/live/startup", args: [])])
        let asks = [OSC.Message(address: "/live/song/get/track_names", args: []),
                    OSC.Message(address: "/live/view/start_listen/selected_track", args: [])]
        XCTAssertEqual(r.sent, asks + asks + [OSC.Message(address: "/live/view/set/selected_track", args: [.int(2)])] + asks,
                       "asked at the start, again after Live's startup, and on Resync; the last rack is not stepped past")
        XCTAssertTrue(r.events.contains(.racks([Rack(index: 0, name: "Kick"), Rack(index: 1, name: "Snare"), Rack(index: 2, name: "Vox")])))
        XCTAssertTrue(r.events.contains(.position(0)))
        XCTAssertEqual(r.platform.oscs.last?.port, nil, "stopped")
        XCTAssertEqual(r.platform.udps.first?.port, 11000)
        assertWhitelisted(AbletonLive.spec, never: [
            OSC.Message(address: "/live/song/start_playing", args: []),
            OSC.Message(address: "/live/track/set/arm", args: [.int(0), .int(1)]),
            OSC.Message(address: "/live/song/get/*", args: []),
        ])
    }

    func testAbletonAnswersOnItsOwnPort() throws {
        let p = TestPlatform()
        let m = OSCHostModule(AbletonLive.spec, ModuleContext(settings: Settings(), platform: p))
        m.start()
        XCTAssertEqual(p.oscs.last?.port, 11001)
        m.stop()
    }
}

final class MIDIHostModuleTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    private func run(_ spec: MIDIHostSpec, racks: [String], _ commands: [HostCommand]) -> (MIDIRecorder, [HostEvent]) {
        var s = Settings()
        s.editHost(spec.info.id) {
            $0.racks = racks
            $0.showChangesSoundAccepted = true
        }
        let r = MIDIRecorder()
        let m = MIDIHostModule(spec, ModuleContext(settings: s, platform: TestPlatform(), midiOut: r))
        var events: [HostEvent] = []
        let lock = NSLock()
        m.onEvent = { e in lock.lock(); events.append(e); lock.unlock() }
        m.start()
        for c in commands { m.perform(c) }
        m.waitUntilIdle()
        lock.lock()
        defer { lock.unlock() }
        return (r, events)
    }

    private func assertWhitelisted(_ spec: MIDIHostSpec, never: [MIDIHostMessage], file: StaticString = #filePath, line: UInt = #line) {
        let racks = (0..<200).map { Rack(index: $0, name: "r\($0)") }
        var built: [MIDIHostMessage] = []
        for i in -1..<200 { built += spec.show(i, racks) }
        if let step = spec.step { built += step(1) + step(-1) }
        for m in built { XCTAssertTrue(spec.isAllowed(m), "\(m)", file: file, line: line) }
        for m in never { XCTAssertFalse(spec.isAllowed(m), "\(m)", file: file, line: line) }
    }

    func testMainStageSendsOnlyTypedPatchesAndNeverTheOneItIsOn() {
        let (r, events) = run(MainStage.spec, racks: ["Piano", "Strings", "Pad"],
                              [.show(1), .show(1), .step(1), .step(1), .show(7), .cc(number: 20, value: 127), .step(-1)])
        XCTAssertEqual(r.messages, [.programChange(1), .programChange(2), .programChange(1)],
                       "no second Program Change 1, none past the last patch, none for a patch not typed")
        XCTAssertEqual(Set(r.heard.map(\.channel)), [1])
        XCTAssertEqual(events.compactMap { if case .position(let p) = $0 { return p } else { return nil } }, [1, 2, 1])
        // With no patches typed, nothing goes.
        XCTAssertTrue(run(MainStage.spec, racks: [], [.show(0)]).0.messages.isEmpty)
        assertWhitelisted(MainStage.spec, never: [.cc(number: 0, value: 1), .programChange(128)])
    }

    func testLogicCountsFromTheFirstTrack() {
        let up = MIDIHostMessage.cc(number: 20, value: 127), down = MIDIHostMessage.cc(number: 22, value: 127)
        let (r, events) = run(Logic.spec, racks: ["Kick", "Snare", "Vox", "Gtr"], [.show(2), .show(3), .show(1), .resync])
        XCTAssertEqual(r.messages, [up, up, up, up, down, down, down, up, up, up, up, up, up],
                       "home (four back), two on, one on, two back; Resync homes again")
        XCTAssertEqual(Set(r.heard.map(\.channel)), [16])
        XCTAssertEqual(events.last, .position(0))
        assertWhitelisted(Logic.spec, never: [.cc(number: 20, value: 0), .programChange(0), .cc(number: 21, value: 127)])
    }

    func testLogicSkipsATrackNotTyped() {
        let (r, _) = run(Logic.spec, racks: ["Kick", "Snare"], [.show(5)])
        XCTAssertTrue(r.messages.isEmpty)
    }

    func testAHeldMIDIHostIsSentNothing() {
        // The module's own lock, behind the engine's gate: unticked, MainStage gets no MIDI.
        var s = Settings()
        s.editHost(MainStage.info.id) { $0.racks = ["Piano", "Organ"] }
        let out = MIDIRecorder()
        let m = MIDIHostModule(MainStage.spec, ModuleContext(settings: s, platform: TestPlatform(), midiOut: out))
        m.start()
        m.perform(.show(1))
        m.perform(.resync)
        m.waitUntilIdle()
        XCTAssertEqual(out.messages, [])
        s.editHost(MainStage.info.id) { $0.showChangesSoundAccepted = true }
        m.update(s)
        m.perform(.show(1))
        m.waitUntilIdle()
        XCTAssertEqual(out.messages, [.programChange(1)])
    }

    func testVSTLiveSelectsSongsByValue() {
        let (r, _) = run(VSTLive.spec, racks: ["Intro", "Song 1", "Song 2"], [.show(2), .step(-1), .step(1), .show(9)])
        XCTAssertEqual(r.messages, [.cc(number: 102, value: 2), .cc(number: 104, value: 127), .cc(number: 103, value: 127)])
        assertWhitelisted(VSTLive.spec, never: [.cc(number: 102, value: 128), .cc(number: 103, value: 0), .programChange(1),
                                                .cc(number: 7, value: 100)])
    }
}

final class Stage5RegistryTests: XCTestCase {
    func testTheHostsInThePickersOrder() {
        XCTAssertEqual(ModuleRegistry.standard.hosts.map(\.info.id),
                       ["superrack.midi", "superrack.prolink", "ableton", "logic", "mainstage", "liveprofessor",
                        "gigperformer", "vsthost", "vstlive"])
    }

    /// The approved defaults: these load what they show, so they are behind the sound gate (and
    /// Logic, whose selected track takes the live MIDI and is ready to record).
    func testWhichHostsAreBehindTheSoundGate() {
        let gated = ModuleRegistry.standard.hosts.filter { $0.info.capabilities.contains(.showChangesSound) }.map(\.info.id)
        XCTAssertEqual(Set(gated), ["logic", "mainstage", "gigperformer", "vsthost", "vstlive"])
    }

    func testEveryOtherHostHasItsOwnSettingsAndSetUp() {
        for e in ModuleRegistry.standard.hosts where e.info.product != "SuperRack" {
            let d = e.info.hostDefaults
            XCTAssertTrue(d.port != nil || d.midiChannel != nil, e.info.id)
            XCTAssertFalse(d.setUp.isEmpty, e.info.id)
            XCTAssertTrue(e.info.about.contains("not run against"), e.info.id)
        }
    }
}
