import XCTest
@testable import RemoraCore
@testable import RemoraWindows

/// Windows' MIDI rules and the 1 ms timer hold (docs/ARCHITECTURE.md §8). They are plain Swift, so
/// they run on every system; the WinMM calls themselves are tried on Windows only, at the end.
final class WindowsPlatformTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    /// Remora's port is the output named as `midiPortName`, whatever its case or spaces, and cut
    /// to WinMM's 31 characters.
    func testTheOutputIsTheOneNamedAsRemorasPort() {
        let outputs = ["Microsoft GS Wavetable Synth", " remora ", "Remora"]
        XCTAssertEqual(WindowsMIDIRules.output(named: "Remora", in: outputs), 1)
        XCTAssertNil(WindowsMIDIRules.output(named: "Remora 2", in: outputs))
        XCTAssertNil(WindowsMIDIRules.output(named: "  ", in: outputs + [""]))
        XCTAssertNil(WindowsMIDIRules.output(named: "Remora", in: []))
        let long = "Remora to SuperRack, stage left PC"
        XCTAssertGreaterThan(long.count, WindowsMIDIRules.nameLimit)
        XCTAssertEqual(WindowsMIDIRules.output(named: long, in: [String(long.prefix(31))]), 0)
    }

    /// A Windows MIDI Services loopback made from "Remora" is a pair, "Remora (A)" and "Remora (B)"
    /// (winlab, 2026-11-22). Remora's port, "Remora" by default, is then its A side.
    func testALoopbackPairsASideIsRemorasPort() {
        let outputs = ["Microsoft GS Wavetable Synth", "Remora (A)", "Remora (B)"]
        XCTAssertEqual(WindowsMIDIRules.output(named: "Remora", in: outputs), 1)
        XCTAssertEqual(WindowsMIDIRules.output(named: "Remora (B)", in: outputs), 2, "a side named outright")
        XCTAssertEqual(WindowsMIDIRules.output(named: "remora", in: ["Remora (A)", "Remora"]), 1, "a port of the very name first")
        XCTAssertNil(WindowsMIDIRules.output(named: "Remora", in: ["Remora (B)"]))
        XCTAssertNil(WindowsMIDIRules.output(named: "Remora", in: ["Remora 2 (A)"]))
    }

    /// A loopback hands back what Remora sends on it, so its own port's input is never a control:
    /// with a loopback pair, neither side is.
    func testRemorasOwnInputIsNeverHeard() {
        XCTAssertTrue(WindowsMIDIRules.isOwn("Remora", port: "Remora"))
        XCTAssertTrue(WindowsMIDIRules.isOwn("REMORA ", port: "remora"))
        XCTAssertFalse(WindowsMIDIRules.isOwn("Remora Desk", port: "Remora"))
        XCTAssertFalse(WindowsMIDIRules.isOwn("nanoKONTROL2", port: "Remora"))
        for side in ["Remora (A)", "Remora (B)"] {
            XCTAssertTrue(WindowsMIDIRules.isOwn(side, port: "Remora"), side)
            XCTAssertTrue(WindowsMIDIRules.isOwn(side, port: "Remora (A)"), side)
        }
        XCTAssertFalse(WindowsMIDIRules.isOwn("nanoKONTROL2 (A)", port: "Remora"))
        XCTAssertFalse(WindowsMIDIRules.isOwn("Remora 2 (B)", port: "Remora"))
    }

    func testTwoInputsOfOneKindAreToldApart() {
        XCTAssertEqual(WindowsMIDIRules.keys(["nanoKONTROL2", "X-Touch", "nanoKONTROL2", "nanoKONTROL2 "]),
                       ["nanoKONTROL2", "X-Touch", "nanoKONTROL2 #2", "nanoKONTROL2 #3"])
    }

    /// The bytes `midiOutShortMsg` takes, and what an input's MIM_DATA becomes: the Mac's port
    /// reads the same three kinds.
    func testShortMessages() {
        XCTAssertEqual(WindowsMIDIRules.shortMessage(status: 0xB0, channel: 1, 20, 127), 0x7F_14_B0)
        XCTAssertEqual(WindowsMIDIRules.shortMessage(status: 0xB0, channel: 16, 22, 127), 0x7F_16_BF)
        XCTAssertEqual(WindowsMIDIRules.shortMessage(status: 0xC0, channel: 3, 5, 0), 0x00_05_C2)
        XCTAssertEqual(WindowsMIDIRules.shortMessage(status: 0xB0, channel: 1, 200, 300), 0x2C_48_B0, "data bytes keep 7 bits")

        XCTAssertEqual(WindowsMIDIRules.event(0x7F_14_B1, source: "pad"),
                       MIDIEvent(source: "pad", kind: .cc, channel: 2, number: 20, value: 127))
        XCTAssertEqual(WindowsMIDIRules.event(0x40_3C_9F, source: "pad"),
                       MIDIEvent(source: "pad", kind: .note, channel: 16, number: 60, value: 64))
        XCTAssertEqual(WindowsMIDIRules.event(0x40_3C_80, source: "pad"),
                       MIDIEvent(source: "pad", kind: .note, channel: 1, number: 60, value: 0))
        XCTAssertNil(WindowsMIDIRules.event(0xF8, source: "pad"), "clock")
        XCTAssertNil(WindowsMIDIRules.event(0x40_00_E0, source: "pad"), "pitch bend")
        XCTAssertNil(WindowsMIDIRules.event(0x05_C0, source: "pad"), "program change")
    }

    /// Inputs are opened only where Windows MIDI Services shares them: its WinMM driver among
    /// Drivers32's MIDI drivers, as on winlab (Windows 11 25H2, 2026-11-22).
    func testInputsAreSharedOnlyWithWindowsMIDIServices() {
        XCTAssertTrue(WindowsMIDIRules.sharesPorts(midiDrivers: ["wdmaud.drv", "wdmaud2.drv"]))
        XCTAssertTrue(WindowsMIDIRules.sharesPorts(midiDrivers: ["WDMAUD2.DRV"]))
        XCTAssertFalse(WindowsMIDIRules.sharesPorts(midiDrivers: ["wdmaud.drv"]))
        XCTAssertFalse(WindowsMIDIRules.sharesPorts(midiDrivers: []))
    }

    /// 1 ms timers begin with the first message and end once MIDI has been quiet for `idle`.
    func testTheTimerHoldBeginsOnceAndEndsWhenQuiet() {
        let log = Counts()
        let h = BusyHold(idle: 0.1, begin: { log.add("begin") }, end: { log.add("end") })
        h.touch()
        h.touch()
        h.touch()
        XCTAssertTrue(h.isHeld)
        XCTAssertEqual(log.all, ["begin"])
        wait(until: { !h.isHeld }, within: 2)
        XCTAssertEqual(log.all, ["begin", "end"])
        h.touch()
        XCTAssertEqual(log.all, ["begin", "end", "begin"])
        h.release()
        h.release()
        XCTAssertFalse(h.isHeld)
        XCTAssertEqual(log.all, ["begin", "end", "begin", "end"])
        // A check that was due after the release ends nothing more.
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(log.all, ["begin", "end", "begin", "end"])
    }

    /// While messages keep coming, the hold stays.
    func testTheTimerHoldStaysWhileMIDIKeepsComing() {
        let log = Counts()
        let h = BusyHold(idle: 0.2, begin: { log.add("begin") }, end: { log.add("end") })
        let until = Date().addingTimeInterval(0.6)
        while Date() < until {
            h.touch()
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(h.isHeld)
        XCTAssertEqual(log.all, ["begin"])
        wait(until: { !h.isHeld }, within: 2)
        XCTAssertEqual(log.all, ["begin", "end"])
    }

    #if os(Windows)
    /// With no output of the name, there is no port, and the log says what to make.
    func testNoPortOfTheNameSaysWhatToMake() {
        let p = WindowsPlatform()
        let name = "Remora test \(UUID().uuidString.prefix(8))"
        XCTAssertNil(p.midi(name: name))
        XCTAssertTrue(p.midiUnavailable?.hasPrefix("no MIDI output named \"\(name)\"") == true, p.midiUnavailable ?? "nil")
    }

    /// The port's 1 ms timers make a 15-step move at SuperRack's 2 ms spacing at least twice as
    /// quick as Windows' default tick allows, and print both times for docs/ARCHITECTURE.md §8.
    /// The move tests hold the absolute bound; on a VM whose CPU another program holds, even 1 ms
    /// timers come close to it (winlab, 2026-11-22: 346–783 ms by default, 123–249 ms with them).
    func testThePortsTimersKeepTwoMillisecondSteps() {
        func move() -> TimeInterval {
            let start = Date()
            for _ in 0..<15 { Thread.sleep(forTimeInterval: 0.002) }
            return Date().timeIntervalSince(start)
        }
        let without = move()
        let hold = WinMM.timerHold()
        hold.touch()
        let with = move()
        hold.release()
        print("15 steps of 2 ms: \(Int(without * 1000)) ms by default, \(Int(with * 1000)) ms with the port's 1 ms timers")
        XCTAssertLessThan(with, without / 2)
    }

    /// Staying awake is held and let go without complaint.
    func testStayingAwakeIsHeldAndEnded() {
        let hold = WindowsPlatform().stayAwake(reason: "Testing")
        XCTAssertNotNil(hold)
        hold?.end()
        hold?.end()
    }
    #endif

    // MARK: Helpers

    private final class Counts {
        private let lock = NSLock()
        private var events: [String] = []
        func add(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func wait(until done: () -> Bool, within seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(done(), "not within \(seconds) s")
    }
}
