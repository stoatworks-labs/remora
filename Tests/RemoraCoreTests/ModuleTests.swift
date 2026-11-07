import XCTest
@testable import RemoraApple
@testable import RemoraConsoles
@testable import RemoraCore
@testable import RemoraEngine
@testable import RemoraHosts

final class ModuleSettingsTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    /// A settings.json as 0.3.1 writes it, with every key away from its default.
    static let file031 = #"""
    {
      "ccBase" : 40,
      "closePluginWindows" : true,
      "consoleHost" : "192.168.8.128",
      "consoleKind" : "ahDLive",
      "consoleMIDIChannel" : 3,
      "controls" : [
        {
          "action" : "goToRack",
          "cc" : 31,
          "id" : "6A1D7E8C-0D5E-4F43-9A32-1B2C3D4E5F60",
          "mode" : "trigger",
          "name" : "Vox",
          "rack" : 4,
          "source" : { "midi" : { "channel" : 3, "kind" : "note", "number" : 60, "source" : "dLive" } }
        }
      ],
      "follow" : false,
      "hidePluginWindowsInBackground" : true,
      "midiChannel" : 7,
      "midiPortName" : "Remora B",
      "mode" : "countFromLast",
      "noRack" : "overview",
      "openRackAfterMove" : true,
      "oscEnabled" : false,
      "oscPort" : 9030,
      "overrides" : { "in1" : 3, "stin2L" : -1 },
      "placePluginWindows" : true,
      "readRackFromWindow" : false,
      "reopenPluginAfterRackChange" : true,
      "sessionPath" : "/tmp/elsewhere/CurrentSPRKP.dat",
      "settingsVersion" : 3,
      "stepMilliseconds" : 7
    }
    """#

    func testA031FileReadsTheSame() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(Self.file031.utf8))
        XCTAssertEqual(s.console, "allenheath.dlive")
        XCTAssertEqual(s.consoleKind, .ahDLive)
        XCTAssertEqual(s.pluginHost, "superrack.midi")
        XCTAssertEqual(s.consoleHost, "192.168.8.128")
        XCTAssertEqual(s.consoleMIDIChannel, 3)
        XCTAssertEqual(s.controls.count, 1)
        XCTAssertEqual(s.controls.first?.source, .midi(source: "dLive", kind: .note, channel: 3, number: 60))
        XCTAssertEqual(s.controls.first?.rack, 4)
        XCTAssertFalse(s.follow)
        XCTAssertEqual(s.midiChannel, 7)
        XCTAssertEqual(s.ccBase, 40)
        XCTAssertEqual(s.mode, .countFromLast)
        XCTAssertEqual(s.noRack, .overview)
        XCTAssertEqual(s.overrides, ["in1": 3, "stin2L": -1])
        XCTAssertEqual(s.oscPort, 9030)
        XCTAssertEqual(s.stepMilliseconds, 7)
        XCTAssertEqual(s.sessionPath, "/tmp/elsewhere/CurrentSPRKP.dat")
        XCTAssertEqual(s.pluginWindowOptions, PluginWindowOptions(close: true, place: true, reopen: true,
                                                                  readRack: false, hide: true))
    }

    /// Saving keeps every 0.3.1 key as it was, `consoleKind` included, so 0.3.1 reading the file
    /// back keeps its desk; the module ids are added beside them.
    func testSavingKeepsEvery031Key() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(Self.file031.utf8))
        let old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.file031.utf8)) as? [String: Any])
        let new = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        for (key, value) in old {
            XCTAssertTrue((new[key] as AnyObject).isEqual(value), "\(key): \(String(describing: new[key])) vs \(value)")
        }
        XCTAssertEqual(Set(new.keys).subtracting(old.keys), ["console", "pluginHost", "superRackEdition", "proLinkPort"])
        XCTAssertEqual(new["console"] as? String, "allenheath.dlive")
        XCTAssertEqual(new["pluginHost"] as? String, "superrack.midi")
        XCTAssertEqual(new["superRackEdition"] as? String, "performer")
        XCTAssertEqual(new["proLinkPort"] as? Int, 50002)
    }

    func testAConsoleThisBuildLacksIsKept() throws {
        // A made-up id, as a newer Remora's module would be.
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"console": "example.desk"}"#.utf8))
        XCTAssertEqual(s.console, "example.desk")
        XCTAssertNil(s.consoleKind)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        XCTAssertEqual(saved["console"] as? String, "example.desk")
        XCTAssertNil(saved["consoleKind"], "0.3 would read a kind it has as that desk")
        XCTAssertNil(ModuleRegistry.standard.console(s.console))
    }

    func testTheModuleIDWinsAndOldNamesAreNormalised() throws {
        func load(_ json: String) throws -> Settings { try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
        XCTAssertEqual(try load(#"{"console": "yamaha.dm", "consoleKind": "ahQu"}"#).console, "yamaha.dm")
        XCTAssertEqual(try load(#"{"console": "yamaha.dm", "consoleKind": "ahQu"}"#).consoleKind, .yamahaDM)
        XCTAssertEqual(try load(#"{"console": "ahSQ"}"#).console, "allenheath.sq")
        XCTAssertEqual(try load(#"{"consoleKind": "nonsense"}"#).console, "yamaha.ql")
        var s = Settings()
        s.console = "allenheath.qu"
        XCTAssertEqual(s.consoleKind, .ahQu)
        s.console = "behringer.x32"
        XCTAssertNil(s.consoleKind)
        // Split out of an older kind, so 0.3 runs it with the same code.
        s.console = "yamaha.cl"
        XCTAssertEqual(s.consoleKind, .yamahaCLQL)
        s.console = "allenheath.avantis"
        XCTAssertEqual(s.consoleKind, .ahDLive)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        XCTAssertEqual(saved["consoleKind"] as? String, "ahDLive")
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).console, "allenheath.avantis")
    }
}

final class RegistryTests: XCTestCase {
    func testEveryOldKindIsAModule() {
        let r = ModuleRegistry.standard
        for k in ConsoleKind.allCases {
            XCTAssertEqual(r.console(k.rawValue)?.info.id, k.moduleID, "\(k)")
            XCTAssertEqual(r.console(k.moduleID)?.info.legacyIDs, [k.rawValue], "\(k)")
        }
        let ids = r.consoles.map(\.info.id) + r.hosts.map(\.info.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique")
        XCTAssertEqual(Set(r.consoles.flatMap(\.info.legacyIDs)), Set(ConsoleKind.allCases.map(\.rawValue)))
    }

    /// Only what has been run on the real kit is supported (docs/PROTOCOL.md).
    func testOnlyTheQLAndSuperRackAreSupported() {
        let r = ModuleRegistry.standard
        XCTAssertEqual(r.consoles.filter { !$0.info.experimental }.map(\.info.id), ["yamaha.ql"])
        XCTAssertEqual(r.hosts.filter { !$0.info.experimental }.map(\.info.id),
                       ["superrack.midi", "superrack.prolink"])
        XCTAssertTrue(r.consoles.allSatisfy { $0.info.kind == .console })
        XCTAssertTrue(r.hosts.allSatisfy { $0.info.kind == .host })
    }

    func testALinkBecomesEvents() {
        final class Link: ConsoleLink {
            var onState: ((ConsoleState) -> Void)?
            var onNamesLink: ((Bool) -> Void)?
            var onModel: ((String) -> Void)?
            var onSelected: ((ConsoleChannel) -> Void)?
            var onNames: (([ConsoleChannel: String]) -> Void)?
            var onControl: ((ControlSource, Int32) -> Void)?
            func start() { onState?(.live) }
            func stop() { onState?(.stopped) }
        }
        let link = Link()
        let m = LinkConsoleModule(link)
        var events: [ConsoleEvent] = []
        m.onEvent = { events.append($0) }
        m.start()
        link.onNamesLink?(true)
        link.onModel?("QL1")
        link.onSelected?(.input(3))
        link.onNames?([.input(3): "Vox"])
        link.onControl?(.yamaha(.init(element: 1, index: 2, channel: 3)), 7)
        m.stop()
        XCTAssertEqual(events, [.link(.live), .namesLink(true), .model("QL1"), .selected(.input(3)),
                                .names([.input(3): "Vox"]),
                                .control(.yamaha(.init(element: 1, index: 2, channel: 3)), 7), .link(.stopped)])
    }
}

final class EngineTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    /// Each OSC address becomes its host command, and SuperRack MIDI sends the CC for it.
    func testOSCAddressesDriveTheHost() {
        let sr = FakeSuperRack(count: allanRacks.count, at: 5)
        let p = TestPlatform()
        var s = Settings()
        s.stepMilliseconds = 0
        let b = Bridge(settings: s, sink: sr, platform: p)
        b.setRacksForTesting(allanRacks)
        func osc(_ address: String, _ args: [OSC.Arg] = []) -> [Int] {
            let before = sr.log.count
            p.osc.onMessage?(OSC.Message(address: address, args: args))
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            b.driverForTesting.waitUntilIdle()
            return sr.log.dropFirst(before).map { $0.1 }
        }
        XCTAssertEqual(osc("/remora/rack/next"), [22])
        XCTAssertEqual(osc("/remora/rack/prev"), [20])
        XCTAssertEqual(osc("/remora/rack/previous"), [20])
        XCTAssertEqual(osc("/remora/rack/open"), [21])
        XCTAssertEqual(osc("/remora/overview"), [23])
        XCTAssertEqual(osc("/remora/plugin/previous"), [24])
        XCTAssertEqual(osc("/remora/plugin/next"), [25])
        XCTAssertEqual(osc("/remora/cc", [.int(30), .int(64)]), [30])
        XCTAssertEqual(sr.log.last.map { $0.2 }, 64)
        _ = osc("/remora/rack/select", [.int(9)])
        XCTAssertEqual(sr.rack, 8)
        _ = osc("/remora/rack/select", [.string("head 2")])
        XCTAssertEqual(sr.rack, 1)
        XCTAssertEqual(osc("/remora/bogus"), [])
    }

    func testAHostThisBuildLacksDropsCommands() {
        var s = Settings()
        s.pluginHost = "acme.rack"
        let sr = FakeSuperRack(count: 16, at: 3)
        let b = Bridge(settings: s, sink: sr, platform: TestPlatform())
        XCTAssertEqual(b.status.sessionError, "acme.rack is not in this version of Remora")
        XCTAssertNil(b.hostInfo)
        b.select(rack: 7)
        b.resync()
        b.send(.nextRack)
        XCTAssertTrue(sr.log.isEmpty)
    }

    func testAConsoleThisBuildLacksSaysSo() {
        let b = Bridge(settings: Settings(), sink: FakeSuperRack(count: 16, at: 0), platform: TestPlatform())
        var s = b.settings
        s.console = "example.desk"
        s.consoleHost = "10.0.0.9"
        b.update(s)
        XCTAssertEqual(b.status.console, .failed("example.desk is not in this version of Remora"))
    }

    /// The console module gets the desk's address and MIDI channel from the settings.
    func testTheConsoleModuleIsMadeFromTheSettings() {
        let p = TestPlatform()
        let b = Bridge(settings: Settings(), sink: FakeSuperRack(count: 16, at: 0), platform: p)
        var s = b.settings
        s.console = "allenheath.qu"
        s.consoleHost = "  10.0.0.9 "
        b.update(s)
        XCTAssertEqual(p.streams.map(\.host), ["10.0.0.9"])
        XCTAssertEqual(p.streams.map(\.port), [51325])
        s.console = "yamaha.ql"
        b.update(s)
        XCTAssertEqual(p.streams.dropFirst().map(\.port), [50000, 49280])
    }
}
