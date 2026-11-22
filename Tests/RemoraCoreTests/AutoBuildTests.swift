import Foundation
import RemoraCore
import RemoraHosts
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import XCTest

/// Auto build, stage A (docs/ARCHITECTURE.md §12): strips, templates, the plan and the patch sheet.
final class AutoBuildTests: XCTestCase {
    private let kick = BuildTemplate(name: "Kick", extraWords: ["kik", "bd"])
    private let vocal = BuildTemplate(name: "Vocal", extraWords: ["vox", "bv", "mc"])
    private let gtr = BuildTemplate(name: "Gtr")

    private func settings(_ keys: [String], _ change: (inout AutoBuildSettings) -> Void = { _ in }) -> AutoBuildSettings {
        var s = AutoBuildSettings()
        s.include = keys
        change(&s)
        return s
    }

    // MARK: Strips

    func testStripsComeInTheDesksOrderWithStereoPairsAsOne() {
        let strips = AutoBuild.strips(from: [
            .mix(1): "Wedge 1", .input(2): "Snare", .input(1): "Kick",
            .stereoIn(1, right: false): "OH L", .stereoIn(1, right: true): "OH R",
            .stereoIn(2, right: true): "PB-R", .stereo(2): "Radio", .main(1): "LR",
        ])
        XCTAssertEqual(strips, [
            BuildStrip(channel: .input(1), name: "Kick"), BuildStrip(channel: .input(2), name: "Snare"),
            BuildStrip(channel: .stereoIn(1, right: false), name: "OH", stereo: true),
            BuildStrip(channel: .stereo(2), name: "Radio", stereo: true),
            BuildStrip(channel: .stereoIn(2, right: true), name: "PB", stereo: true),
            BuildStrip(channel: .mix(1), name: "Wedge 1"), BuildStrip(channel: .main(1), name: "LR"),
        ])
    }

    func testOnlyASetApartLOrRIsDropped() {
        XCTAssertEqual(AutoBuild.dropSide("OH L"), "OH")
        XCTAssertEqual(AutoBuild.dropSide("Kbd-R"), "Kbd")
        XCTAssertEqual(AutoBuild.dropSide("Amb_l"), "Amb")
        XCTAssertEqual(AutoBuild.dropSide("CL"), "CL")
        XCTAssertEqual(AutoBuild.dropSide("Vocal"), "Vocal")
    }

    // MARK: Templates

    func testNamesSplitIntoWords() {
        XCTAssertEqual(AutoBuild.words(in: "Vox1"), ["vox"])
        XCTAssertEqual(AutoBuild.words(in: "BV 2"), ["bv"])
        XCTAssertEqual(AutoBuild.words(in: "Kick In/Sub"), ["kick", "in", "sub"])
        XCTAssertEqual(AutoBuild.words(in: "Gtr L"), ["gtr"])
        XCTAssertEqual(AutoBuild.words(in: "12"), [])
        XCTAssertEqual(vocal.words, ["vocal", "vox", "bv", "mc"])
    }

    func testANamesFirstWordThatATemplateHasPicksIt() {
        let t = [kick, vocal, gtr]
        XCTAssertEqual(AutoBuild.pick("Kick In", in: t)?.template.name, "Kick")
        XCTAssertEqual(AutoBuild.pick("kik", in: t)?.template.name, "Kick")
        XCTAssertEqual(AutoBuild.pick("vox1", in: t)?.word, "vox")
        XCTAssertEqual(AutoBuild.pick("BV2", in: t)?.template.name, "Vocal")
        // Three letters or more also pick a longer word; two must be the whole word.
        XCTAssertEqual(AutoBuild.pick("Gtrs", in: t)?.template.name, "Gtr")
        XCTAssertNil(AutoBuild.pick("bvx", in: t))
        // The name's first word decides, whatever order the templates are in.
        XCTAssertEqual(AutoBuild.pick("Vox Gtr", in: [gtr, vocal])?.template.name, "Vocal")
        XCTAssertNil(AutoBuild.pick("Keys", in: t))
    }

    // MARK: The plan

    func testRacksTakeTheNextInputsOutputsAndPorts() {
        let strips = [BuildStrip(channel: .input(1), name: "Kick"), BuildStrip(channel: .input(2), name: "Keys"),
                      BuildStrip(channel: .stereoIn(1, right: false), name: "OH", stereo: true),
                      BuildStrip(channel: .input(3), name: "Vox 1")]
        let s = settings(["in1", "stin1L", "in3"]) {
            $0.options.firstInput = 33
            $0.options.firstOutput = 9
            $0.options.deskFirstPort = 5
        }
        let plan = AutoBuild.plan(strips: strips, settings: s, templates: [kick, vocal])
        XCTAssertEqual(plan.problems, [])
        XCTAssertEqual(plan.racks.map(\.name), ["Kick", "OH", "Vox 1"])
        XCTAssertEqual(plan.racks.map(\.index), [0, 1, 2])
        XCTAssertEqual(plan.racks.map(\.hostInputs), [[33], [34, 35], [36]])
        XCTAssertEqual(plan.racks.map(\.hostOutputs), [[9], [10, 11], [12]])
        XCTAssertEqual(plan.racks[1].deskSends, [AudioPort("desk", .dante, .output, 6), AudioPort("desk", .dante, .output, 7)])
        XCTAssertEqual(plan.racks[1].deskReturns, [AudioPort("desk", .dante, .input, 6), AudioPort("desk", .dante, .input, 7)])
        XCTAssertEqual(plan.racks.map(\.template), ["Kick", nil, "Vocal"])
        XCTAssertEqual(plan.racks.map(\.pick), [.byName(word: "kick"), .none, .byName(word: "vox")])
    }

    func testTheUsersChoicesBeatTheDesk() {
        let strips = [BuildStrip(channel: .input(1), name: "Kick"), BuildStrip(channel: .input(2), name: "Vox"),
                      BuildStrip(channel: .input(3), name: "Gtr"), BuildStrip(channel: .main(1), name: "LR")]
        let s = settings(["main1", "in1", "in2", "in3", "in9"]) {
            $0.stereo = ["main1": true]
            $0.template = ["in1": "", "in2": "Gtr", "in3": "Strings"]
        }
        let plan = AutoBuild.plan(strips: strips, settings: s, templates: [kick, vocal, gtr])
        // The desk's order, not the include list's.
        XCTAssertEqual(plan.racks.map(\.channel), [.input(1), .input(2), .input(3), .main(1)])
        XCTAssertEqual(plan.racks.map(\.template), [nil, "Gtr", nil, nil])
        XCTAssertEqual(plan.racks.map(\.pick), [.none, .chosen, .none, .none])
        XCTAssertEqual(plan.racks[3].hostInputs, [4, 5])
        XCTAssertEqual(plan.problems, [
            "Not on the desk now, so left out: in9.",
            "InCh 3 (Gtr): the template “Strings” isn't in the template session, so its rack is empty.",
        ])
    }

    func testNamesAreMadeUniqueAndNeverBlank() {
        let strips = [BuildStrip(channel: .input(1), name: "Vox"), BuildStrip(channel: .input(2), name: "vox"),
                      BuildStrip(channel: .input(3), name: "  "), BuildStrip(channel: .input(4), name: "--"),
                      BuildStrip(channel: .input(5), name: "Vox 2")]
        let plan = AutoBuild.plan(strips: strips, settings: settings(["in1", "in2", "in3", "in4", "in5"]), templates: [])
        XCTAssertEqual(plan.racks.map(\.name), ["Vox", "vox 2", "InCh 3", "InCh 4", "Vox 2 2"])
    }

    func testASessionHoldsSixtyFourRacks() {
        let strips = (1...70).map { BuildStrip(channel: .input($0), name: "ch \($0)") }
        let plan = AutoBuild.plan(strips: strips, settings: settings(strips.map(\.channel.key)), templates: [])
        XCTAssertEqual(plan.racks.count, 64)
        XCTAssertEqual(plan.racks.last?.hostInputs, [64])
        XCTAssertEqual(plan.problems.count, 1)
        XCTAssertTrue(plan.problems[0].hasPrefix("A SuperRack session has 64 racks: 70 picked, so 6 left out (InCh 65"))
    }

    func testNothingPickedPlansNothing() {
        let plan = AutoBuild.plan(strips: [BuildStrip(channel: .input(1), name: "Kick")], settings: AutoBuildSettings(),
                                  templates: [kick])
        XCTAssertEqual(plan.racks, [])
        XCTAssertEqual(plan.problems, [])
    }

    // MARK: The patch sheet

    func testThePatchSheetHasARackARow() {
        let strips = [BuildStrip(channel: .input(1), name: "Kick, In"), BuildStrip(channel: .stereoIn(1, right: false), name: "OH", stereo: true)]
        var plan = AutoBuild.plan(strips: strips, settings: settings(["in1", "stin1L"]), templates: [kick])
        XCTAssertEqual(AutoBuild.patchSheetCSV(plan), """
            Rack,Name,Channel,Desk name,Width,Template,Insert send,SuperRack in,SuperRack out,Insert return
            1,"Kick, In",InCh 1,"Kick, In",mono,Kick,dante out 1,1,1,dante in 1
            2,OH,ST IN 1L,OH,stereo,,dante out 2–3,2–3,2–3,dante in 2–3

            """)
        let text = AutoBuild.patchSheetText(plan, desk: "Allen & Heath SQ (SQ-5)")
        XCTAssertTrue(text.contains("Desk: Allen & Heath SQ (SQ-5)\n"))
        XCTAssertTrue(text.contains("Remora doesn't patch the desk, Dante or SuperRack"))
        XCTAssertTrue(text.contains("1     InCh 1    Kick, In  mono    Kick"), text)
        XCTAssertTrue(text.contains("(empty)"))

        plan.feed = .directOut
        XCTAssertTrue(AutoBuild.patchSheetCSV(plan).hasPrefix("Rack,Name,Channel,Desk name,Width,Template,Direct out,SuperRack in,SuperRack out,Return to a spare input\n"))
    }

    func testThePlanAsJSONNamesChannelsByKey() throws {
        let plan = AutoBuild.plan(strips: [BuildStrip(channel: .input(7), name: "Vox")], settings: settings(["in7"]),
                                  templates: [vocal])
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: AutoBuild.json(plan, desk: "Yamaha QL (QL1)")) as? [String: Any])
        XCTAssertEqual(doc["desk"] as? String, "Yamaha QL (QL1)")
        XCTAssertEqual(doc["feed"] as? String, "insert")
        let rack = try XCTUnwrap((doc["racks"] as? [[String: Any]])?.first)
        XCTAssertEqual(rack["channel"] as? String, "in7")
        XCTAssertEqual(rack["template"] as? String, "Vocal")
        XCTAssertEqual(rack["templateBy"] as? String, "name: vox")
        XCTAssertEqual(rack["superRackInputs"] as? [Int], [1])
        XCTAssertEqual(rack["deskSends"] as? [String], ["desk dante out 1"])
    }

    func testNothingIsWrittenToWavesFolder() {
        XCTAssertTrue(AutoBuild.isWavesFolder("/Users/Shared/Waves/SuperRack Performer/Sessions"))
        XCTAssertTrue(AutoBuild.isWavesFolder("/Users/Shared/Waves"))
        XCTAssertTrue(AutoBuild.isWavesFolder("/Users/Shared/../Shared/Waves/x"))
        XCTAssertFalse(AutoBuild.isWavesFolder("/Users/Shared/WavesNot"))
        XCTAssertFalse(AutoBuild.isWavesFolder("/Users/someone/Desktop"))
    }

    // MARK: Settings

    func testAutoBuildLeavesNoKeyUntilUsed() throws {
        var s = Settings()
        let e = JSONEncoder()
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: e.encode(s)) as? [String: Any])
        XCTAssertNil(plain["autoBuild"])

        s.autoBuildSettings.include = ["in1"]
        s.autoBuildSettings.options.feed = .directOut
        s.autoBuildSettings.words = ["Vocal": ["vox"]]
        let back = try JSONDecoder().decode(Settings.self, from: e.encode(s))
        XCTAssertEqual(back.autoBuildSettings, s.autoBuildSettings)

        s.autoBuildSettings = AutoBuildSettings()
        let cleared = try XCTUnwrap(JSONSerialization.jsonObject(with: e.encode(s)) as? [String: Any])
        XCTAssertNil(cleared["autoBuild"])
    }

    func testABadAutoBuildFieldLosesOnlyItself() throws {
        let json = #"{"autoBuild": {"include": ["in1", "in2"], "stereo": "yes", "options": {"feed": "sideways", "firstInput": 17}}}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(s.autoBuildSettings.include, ["in1", "in2"])
        XCTAssertEqual(s.autoBuildSettings.stereo, [:])
        XCTAssertEqual(s.autoBuildSettings.options.feed, .insert)
        XCTAssertEqual(s.autoBuildSettings.options.firstInput, 17)
    }

    func testTemplatesCarryTheUsersWords() {
        var a = AutoBuildSettings()
        a.words = ["Vocal": ["vox", "MC"]]
        let t = a.templates([(name: "Vocal", plugins: ["F6"]), (name: "Kick", plugins: [])])
        XCTAssertEqual(t.map(\.words), [["vocal", "vox", "mc"], ["kick"]])
        XCTAssertEqual(t[0].plugins, ["F6"])
    }

    // MARK: A template session

    func testATemplateSessionsRacksWithPlugInsAreTheTemplates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remora-templates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Strip templates").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        // The tables Remora reads from a session (docs/PROTOCOL.md), with made-up rows.
        let sql = """
            create table config_info (track_type integer, num_tracks integer);
            create table object (id integer primary key, obj_type integer, obj_index integer);
            create table snapshot_chainer (chainer_id integer, snapshot_id integer, name text, selected_slot integer default -1);
            create table plug (chainer_id integer, slot integer, plugin_name text, vendor_name text);
            insert into config_info values (0, 4);
            insert into object values (10, 0, 0), (11, 0, 1), (12, 0, 2), (13, 0, 3);
            insert into snapshot_chainer values (10, -1, 'Vocal', 1), (11, -1, 'Empty', -1), (12, -1, 'n/a', 1),
                                                (13, -1, 'Kick', 2);
            insert into plug values (10, 0, 'F6', 'Waves'), (10, 1, 'DeEsser', 'Waves'), (12, 0, 'C6', 'Waves'),
                                    (13, 0, 'Trigger 2', 'Slate'), (13, 1, 'F6', 'Waves');
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let t = try SuperRackSession.templates(at: path)
        XCTAssertEqual(t.map(\.name), ["Vocal", "Kick"])
        XCTAssertEqual(t.map(\.plugins), [["F6", "DeEsser"], ["Trigger 2", "F6"]])
    }
}
