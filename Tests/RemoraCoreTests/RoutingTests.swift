import Foundation
import SQLite3
import XCTest
@testable import RemoraConsoles
@testable import RemoraCore
@testable import RemoraEngine
@testable import RemoraHosts

/// Routing (docs/ARCHITECTURE.md §4.1): declared runs, the patch graph, Dante presets, and the
/// engine's order of override, routing, name. Nothing here has met a real Dante network.
final class RoutingTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    private func dante(_ device: String, _ side: AudioPort.Side, _ n: Int) -> AudioPort {
        AudioPort(device, .dante, side, n)
    }

    // MARK: Declared runs

    func testRunsParse() throws {
        XCTAssertEqual(try PortRun.parse("desk channel out 1-32 > desk dante out 1"),
                       PortRun(from: .deskChannel(1), to: dante("desk", .output, 1), count: 32))
        XCTAssertEqual(try PortRun.parse("DVS dante in 1–64 > host in 1"),
                       PortRun(from: dante("DVS", .input, 1), to: .hostInput(1), count: 64))
        let madi = try XCTUnwrap(PortRun.parse("QL1 madi out 1-64 > MADI card madi in 1  # the slot's cable"))
        XCTAssertEqual(madi.to, AudioPort("MADI card", .madi, .input, 1))
        XCTAssertEqual(madi.links.count, 64)
        XCTAssertEqual(madi.links.last, PatchLink(from: AudioPort("QL1", .madi, .output, 64), to: AudioPort("MADI card", .madi, .input, 64)))
        // A device with no domain word, and a single channel.
        XCTAssertEqual(try PortRun.parse("Split out 3 > host in 9"),
                       PortRun(from: AudioPort("Split", .other, .output, 3), to: .hostInput(9), count: 1))
        XCTAssertNil(try PortRun.parse("   # only a comment"))
        XCTAssertNil(try PortRun.parse(""))
        // Written back, a run reads the same.
        for line in ["desk channel out 1-32 > desk dante out 1", "QL1 madi out 1-64 > MADI card madi in 1", "Split out 3 > host in 9"] {
            let run = try XCTUnwrap(PortRun.parse(line))
            XCTAssertEqual(try PortRun.parse(run.text), run, run.text)
        }
    }

    func testBadRunsSayWhy() {
        XCTAssertThrowsError(try PortRun.parse("desk dante out 1")) { XCTAssertEqual($0 as? PortRun.ParseError, .noArrow) }
        XCTAssertThrowsError(try PortRun.parse("desk in 1-4 > host in 1-3")) {
            XCTAssertEqual($0 as? PortRun.ParseError, .lengths(4, 3))
        }
        XCTAssertThrowsError(try PortRun.parse("desk sideways 1 > host in 1"))
        XCTAssertThrowsError(try PortRun.parse("in 1 > host in 1"))
        XCTAssertThrowsError(try PortRun.parse("desk out 0 > host in 1"))
        XCTAssertThrowsError(try PortRun.parse("desk out 9-2 > host in 1"))
        XCTAssertThrowsError(try PortRun.parse("desk out 1-5000 > host in 1"))
        // The host's ports are its inputs.
        XCTAssertThrowsError(try PortRun.parse("host out 3 > desk in 1"))
        var r = RoutingSettings()
        r.runs = ["desk out 1 > host in 1", "nonsense", "# fine"]
        XCTAssertEqual(r.runErrors.map(\.line), ["nonsense"])
    }

    // MARK: The graph

    /// The desk and the host take the same stage-box input: back from the desk's input to the
    /// stage box, then forward to the host's.
    func testAStageBoxInputBothTake() {
        var r = RoutingSettings()
        r.deskDante = "QL1-1234"
        r.hostDante = "DVS-Mac"
        r.dante = DantePreset(devices: ["Rio-A", "QL1-1234", "DVS-Mac"], links: [
            PatchLink(from: dante("Rio-A", .output, 5), to: dante("QL1-1234", .input, 5)),
            PatchLink(from: dante("Rio-A", .output, 5), to: dante("DVS-Mac", .input, 9)),
            PatchLink(from: dante("Rio-A", .output, 6), to: dante("DVS-Mac", .input, 10)),
        ])
        let g = PatchGraph(r.links)
        let racks = [0: [AudioPort.hostInput(9)], 1: [AudioPort.hostInput(10)]]
        XCTAssertEqual(g.rack(from: [dante("desk", .input, 5)], racks: racks),
                       .rack(0, path: [dante("Rio-A", .output, 5), dante("DVS-Mac", .input, 9), .hostInput(9)]))
        // The desk's Dante name is "desk" whatever its case in the preset.
        r.deskDante = "ql1-1234"
        XCTAssertEqual(PatchGraph(r.links).rack(from: [dante("DESK", .input, 5)], racks: racks).rackIndex, 0)
    }

    /// The host on a direct out: the channel's own signal, declared onto the desk's Dante
    /// outputs, subscribed by the host.
    func testADirectOut() {
        var r = RoutingSettings()
        r.deskDante = "QL1-1234"
        r.hostDante = "DVS-Mac"
        r.runs = ["desk channel out 1-8 > desk dante out 1"]
        r.dante = DantePreset(links: [PatchLink(from: dante("QL1-1234", .output, 3), to: dante("DVS-Mac", .input, 11))])
        let g = PatchGraph(r.links)
        XCTAssertEqual(g.rack(from: [.deskChannel(3)], racks: [4: [.hostInput(11)], 5: [.hostInput(12)]]),
                       .rack(4, path: [.deskChannel(3), dante("desk", .output, 3), dante("DVS-Mac", .input, 11), .hostInput(11)]))
        XCTAssertEqual(g.rack(from: [.deskChannel(4)], racks: [4: [.hostInput(11)]]), RoutingAnswer.none)
    }

    func testTwoRacksLeaveItToTheName() {
        let g = PatchGraph([
            PatchLink(from: AudioPort("Split", .other, .output, 1), to: .hostInput(1)),
            PatchLink(from: AudioPort("Split", .other, .output, 1), to: .hostInput(2)),
        ])
        XCTAssertEqual(g.rack(from: [AudioPort("Split", .other, .output, 1)], racks: [7: [.hostInput(2)], 3: [.hostInput(1)]]),
                       .several([3, 7]))
        // A stereo rack's two inputs are one rack.
        XCTAssertEqual(g.rack(from: [AudioPort("Split", .other, .output, 1)], racks: [3: [.hostInput(1), .hostInput(2)]]).rackIndex, 3)
    }

    // MARK: Dante Controller presets

    private let preset = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <preset version="2.1.0">
            <name>Test rig</name>
            <description>Dante Controller preset</description>
            <device>
                <name>Rio-A</name>
                <friendly_name>Rio-A</friendly_name>
                <txchannel danteId="1" mediaType="audio"><label>Kick</label></txchannel>
                <txchannel danteId="2" mediaType="audio"><label>Snare</label><label>SN</label></txchannel>
            </device>
            <device>
                <name>QL1-1234</name>
                <txchannel danteId="1" mediaType="audio"><label>Dir 1</label></txchannel>
                <rxchannel danteId="1" mediaType="audio">
                    <name>01</name>
                    <subscribed_channel>Kick</subscribed_channel>
                    <subscribed_device>Rio-A</subscribed_device>
                </rxchannel>
                <rxchannel danteId="2" mediaType="audio">
                    <name>02</name>
                    <subscribed_channel>sn</subscribed_channel>
                    <subscribed_device>rio-a</subscribed_device>
                </rxchannel>
                <rxchannel danteId="3" mediaType="audio"><name>03</name></rxchannel>
            </device>
            <device>
                <name>DVS-Mac</name>
                <txchannel danteId="4" mediaType="audio"><label>Loop</label></txchannel>
                <rxchannel danteId="1" mediaType="audio">
                    <subscribed_channel>Dir 1</subscribed_channel>
                    <subscribed_device>QL1-1234</subscribed_device>
                </rxchannel>
                <rxchannel danteId="2" mediaType="audio">
                    <subscribed_channel>Gone</subscribed_channel>
                    <subscribed_device>Rio-A</subscribed_device>
                </rxchannel>
                <rxchannel danteId="3" mediaType="audio">
                    <subscribed_channel><![CDATA[Mix L]]></subscribed_channel>
                    <subscribed_device>Desk-X</subscribed_device>
                </rxchannel>
                <rxchannel danteId="4" mediaType="audio">
                    <subscribed_channel>Loop</subscribed_channel>
                    <subscribed_device>.</subscribed_device>
                </rxchannel>
            </device>
        </preset>
        """

    func testAPresetsSubscriptions() throws {
        let p = try DantePreset.read(Data(preset.utf8))
        XCTAssertEqual(p.name, "Test rig")
        XCTAssertEqual(p.devices, ["Rio-A", "QL1-1234", "DVS-Mac"])
        XCTAssertEqual(p.links, [
            PatchLink(from: dante("Rio-A", .output, 1), to: dante("QL1-1234", .input, 1)),
            // A second label, and names in another case.
            PatchLink(from: dante("Rio-A", .output, 2), to: dante("QL1-1234", .input, 2)),
            PatchLink(from: dante("QL1-1234", .output, 1), to: dante("DVS-Mac", .input, 1)),
            // "." is the receiving device itself.
            PatchLink(from: dante("DVS-Mac", .output, 4), to: dante("DVS-Mac", .input, 4)),
        ])
        XCTAssertEqual(p.unresolved, ["DVS-Mac in 2 ← Gone@Rio-A", "DVS-Mac in 3 ← Mix L@Desk-X"])
        // It survives the settings file.
        var s = Settings()
        s.routingSettings.dante = p
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).routingSettings.dante, p)
    }

    func testPresetsWithDeclarationsAreRefused() {
        let evil = """
            <?xml version="1.0"?>
            <!DOCTYPE preset [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;">]>
            <preset version="2.1.0"><name>&lol2;</name></preset>
            """
        XCTAssertThrowsError(try DantePreset.read(Data(evil.utf8))) { XCTAssertEqual($0 as? DantePreset.ReadError, .declaration) }
        let external = #"<?xml version="1.0"?><!doctype preset SYSTEM "file:///etc/passwd"><preset/>"#
        XCTAssertThrowsError(try DantePreset.read(Data(external.utf8))) { XCTAssertEqual($0 as? DantePreset.ReadError, .declaration) }
        XCTAssertThrowsError(try DantePreset.read(Data(count: DantePreset.maxBytes + 1))) {
            XCTAssertEqual($0 as? DantePreset.ReadError, .tooBig(DantePreset.maxBytes + 1))
        }
        XCTAssertThrowsError(try DantePreset.read(Data("<settings><name>x</name></settings>".utf8))) {
            XCTAssertEqual($0 as? DantePreset.ReadError, .notAPreset)
        }
        // UTF-16, which the scan for declarations could not read.
        XCTAssertThrowsError(try DantePreset.read("<preset/>".data(using: .utf16)!)) {
            XCTAssertEqual($0 as? DantePreset.ReadError, .notAPreset)
        }
        XCTAssertThrowsError(try DantePreset.read(Data("<preset><device>".utf8))) {
            guard case .xml? = $0 as? DantePreset.ReadError else { return XCTFail("\($0)") }
        }
    }

    // MARK: Settings

    /// Routing stays out of the file until someone changes it, so a 0.3.1 file saved again gains
    /// no key for it (ModuleSettingsTests).
    func testRoutingIsWrittenOnlyOnceUsed() throws {
        func keys(_ s: Settings) throws -> Set<String> {
            Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any] ?? [:]).keys)
        }
        var s = Settings()
        XCTAssertFalse(try keys(s).contains("routing"))
        s.routingSettings.enabled = true
        s.routingSettings.runs = ["desk channel out 1-8 > desk dante out 1"]
        XCTAssertTrue(try keys(s).contains("routing"))
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.routingSettings, s.routingSettings)
        s.routingSettings = RoutingSettings()
        XCTAssertFalse(try keys(s).contains("routing"))
        // A hand-edited routing key with a wrong type loses only that field.
        let odd = #"{"routing": {"enabled": "yes", "runs": ["desk out 1 > host in 1"]}}"#
        let read = try JSONDecoder().decode(Settings.self, from: Data(odd.utf8))
        XCTAssertFalse(read.routingSettings.enabled)
        XCTAssertEqual(read.routingSettings.runs, ["desk out 1 > host in 1"])
    }

    // MARK: The desk's patch

    func testTheQLsPatchIsReadOnlyWhenAsked() {
        func sent(readPatches: Bool) -> [String] {
            let p = TestPlatform()
            let ql = YamahaCLQLConsole(host: "127.0.0.1", platform: p, readPatches: readPatches)
            _ = ql
            let rcp = p.streams.first { $0.port == 49280 }!
            rcp.onState?(.connected)
            return rcp.sent.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines) }
        }
        let without = sent(readPatches: false)
        XCTAssertFalse(without.contains { $0.contains("/Patch") })
        let with = sent(readPatches: true)
        XCTAssertTrue(with.contains("get MIXER:Current/InCh/Patch 0 0"))
        XCTAssertTrue(with.contains("get MIXER:Current/InCh/Patch 71 0"))
        XCTAssertTrue(with.contains("get MIXER:Current/StInCh/Patch 15 0"))
        XCTAssertEqual(with.count, without.count + 72 + 16)
        // Still only reads.
        XCTAssertTrue(with.allSatisfy { $0.hasPrefix("get ") || $0.hasPrefix("devinfo ") })
    }

    func testPatchesBecomeDeskPorts() {
        let rcp = YamahaRCPNames(host: "127.0.0.1", platform: TestPlatform(), patches: YamahaRCPNames.clqlPatches)
        let got = expectation(description: "patches")
        var routes: [ConsoleChannel: [AudioPort]] = [:]
        rcp.onPatches = { routes = $0; got.fulfill() }
        rcp.receiveForTesting(#"OK get MIXER:Current/InCh/Patch 4 0 "DANTE5""#)
        rcp.receiveForTesting(#"OK get MIXER:Current/InCh/Patch 5 0 "NONE""#)
        rcp.receiveForTesting(#"NOTIFY set MIXER:Current/StInCh/Patch 1 0 "DANTE34""#)
        wait(for: [got], timeout: 2)
        XCTAssertEqual(routes, [.input(5): [dante("desk", .input, 5)], .stereoIn(1, right: true): [dante("desk", .input, 34)]])
        XCTAssertEqual(YamahaRCPNames.port(patch: "dante12"), dante("desk", .input, 12))
        XCTAssertNil(YamahaRCPNames.port(patch: "DANTE0"))
        XCTAssertNil(YamahaRCPNames.port(patch: "OMNI1"))
    }

    // MARK: The host's inputs

    func testSuperRacksRoutesGiveEachRacksInputs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remora-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("CurrentSPRKP.dat").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        // As SuperRack Performer 15.15's session held them on 2026-11-07: device inputs (cluster
        // 10, index 0) to racks (cluster 0), and rack outputs (cluster 0) to the device (11).
        let sql = """
            create table config_info (track_type integer, num_tracks integer);
            create table object (id integer primary key, obj_type integer, obj_index integer);
            create table snapshot_chainer (chainer_id integer, snapshot_id integer, name text, selected_slot integer default -1);
            create table plug (chainer_id integer, slot integer, plugin_name text, vendor_name text);
            create table routes (id integer primary key, src_cluster_type integer, src_cluster_type_index integer,
                                 src_section_type integer, src_section_index integer, src_channel_index integer,
                                 dst_cluster_type integer, dst_cluster_type_index integer, dst_section_type integer,
                                 dst_section_index integer, dst_channel_index integer);
            insert into config_info values (0, 3);
            insert into object values (10, 0, 0), (11, 0, 1), (12, 0, 2);
            insert into snapshot_chainer values (10, -1, 'head 1', 1), (11, -1, 'Lec', 1), (12, -1, 'Rack 3', 1);
            insert into routes (src_cluster_type, src_cluster_type_index, src_section_type, src_section_index,
                                src_channel_index, dst_cluster_type, dst_cluster_type_index, dst_section_type,
                                dst_section_index, dst_channel_index) values
                (10, 0, -1, -1, 4, 0, 0, 0, 0, 0),
                (10, 0, -1, -1, 12, 0, 1, 0, 0, 0), (10, 0, -1, -1, 13, 0, 1, 0, 0, 1),
                (0, 0, -1, 0, 0, 11, 0, 0, -1, 4);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertEqual(try SuperRackSession.read(at: path).racks, [
            Rack(index: 0, name: "head 1", inputs: [5]), Rack(index: 1, name: "Lec", inputs: [13, 14]),
            Rack(index: 2, name: "Rack 3"),
        ])
    }

    func testProLinkRacksGiveTheirInputs() {
        XCTAssertEqual(ProLinkRack(index: 8, name: "Lec", inputs: 2, firstInputChannel: 12).rack,
                       Rack(index: 8, name: "Lec", inputs: [13, 14]))
        XCTAssertEqual(ProLinkRack(index: 10, name: "Rack 11", firstInputChannel: -1).rack, Rack(index: 10, name: "Rack 11"))
    }

    // MARK: The engine

    /// Override, then routing while it is on, then the name.
    func testTheEngineTriesRoutingBeforeTheName() {
        let sr = FakeSuperRack(count: 4, at: 0)
        var s = Settings()
        s.stepMilliseconds = 0
        s.routingSettings.enabled = true
        s.routingSettings.deskDante = "QL1-1234"
        s.routingSettings.hostDante = "DVS-Mac"
        s.routingSettings.dante = DantePreset(links: [
            PatchLink(from: dante("Rio-A", .output, 5), to: dante("QL1-1234", .input, 5)),
            PatchLink(from: dante("Rio-A", .output, 5), to: dante("DVS-Mac", .input, 3)),
        ])
        let b = Bridge(settings: s, sink: sr, platform: TestPlatform())
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            b.driverForTesting.waitUntilIdle()
        }
        b.setRacksForTesting([Rack(index: 0, name: "Kick"), Rack(index: 1, name: "Snare"),
                              Rack(index: 2, name: "Vox", inputs: [3]), Rack(index: 3, name: "Spare", inputs: [4])])
        b.setNamesForTesting([.input(1): "Kick", .input(2): "Snare"])
        b.setRoutesForTesting([.input(1): [dante("desk", .input, 5)]])
        // InCh 1 is named Kick, but its audio reaches Vox's input.
        b.selectionForTesting(.input(1))
        settle()
        XCTAssertEqual(b.status.mappedRack?.name, "Vox")
        XCTAssertEqual(b.status.mappedBy, .routing([dante("Rio-A", .output, 5), dante("DVS-Mac", .input, 3), .hostInput(3)]))
        XCTAssertEqual(sr.rack, 2)
        let m = b.mapping(for: .input(1))
        XCTAssertTrue(m.disagrees)
        XCTAssertEqual(m.byName?.name, "Kick")
        // Routing knows nothing of InCh 2: its name decides.
        b.selectionForTesting(.input(2))
        settle()
        XCTAssertEqual(b.status.mappedBy, .name)
        XCTAssertEqual(sr.rack, 1)
        // An override beats routing.
        var o = b.settings
        o.overrides[ConsoleChannel.input(1).key] = 3
        b.update(o)
        XCTAssertEqual(b.mapping(for: .input(1)).rack?.name, "Spare")
        XCTAssertEqual(b.mapping(for: .input(1)).source, .override)
        // Routing off: the console is reconnected so it stops reading the patch, and what it had
        // said goes. Then the name again, and routing says nothing.
        o.overrides = [:]
        o.routingSettings.enabled = false
        b.update(o)
        XCTAssertTrue(b.routes.isEmpty)
        b.setNamesForTesting([.input(1): "Kick", .input(2): "Snare"])
        XCTAssertEqual(b.mapping(for: .input(1)).rack?.name, "Kick")
        XCTAssertNil(b.mapping(for: .input(1)).routing)
    }

    /// A patch that arrives after the selection moves the host, as late names do.
    func testALatePatchIsFollowed() {
        let sr = FakeSuperRack(count: 4, at: 0)
        var s = Settings()
        s.stepMilliseconds = 0
        s.routingSettings.enabled = true
        s.routingSettings.runs = ["desk dante in 1-8 > host in 1"]
        let b = Bridge(settings: s, sink: sr, platform: TestPlatform())
        b.setRacksForTesting([Rack(index: 0, name: "A", inputs: [1]), Rack(index: 1, name: "B", inputs: [2]),
                              Rack(index: 2, name: "C", inputs: [3]), Rack(index: 3, name: "D")])
        b.setNamesForTesting([.input(7): "A"])
        b.selectionForTesting(.input(7))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        b.driverForTesting.waitUntilIdle()
        XCTAssertEqual(sr.rack, 0)
        b.setRoutesForTesting([.input(7): [dante("desk", .input, 3)]])
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        b.driverForTesting.waitUntilIdle()
        XCTAssertEqual(sr.rack, 2)
        XCTAssertEqual(b.status.mappedRack?.name, "C")
    }
}

extension RoutingAnswer {
    var rackIndex: Int? {
        if case .rack(let i, _) = self { return i }
        return nil
    }
}
