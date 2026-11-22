import XCTest
@testable import RemoraConsoles
@testable import RemoraCore
@testable import RemoraEngine
@testable import RemoraHosts

// docs/MODULES.md's worked example, kept here so it builds and is tested with everything else.
// The desk is made up: no such desk exists, and nothing in Remora's registry lists it.

/// A made-up desk that speaks OSC over UDP 9000:
/// - `/info` answers `/info s` (the model);
/// - `/sel` answers `/sel i` (the selected input, from 0);
/// - `/ch/N/name` answers `/ch/N/name s` (input N's name, N from 1 to 32).
///
/// Remora asks; it never sets. Every message it sends has no arguments and an address on the list,
/// and `isReadRequest` is the one place that says so.
final class ExampleDesk: ConsoleLink {
    var onState: ((ConsoleState) -> Void)?
    var onNamesLink: ((Bool) -> Void)?
    var onModel: ((String) -> Void)?
    var onSelected: ((ConsoleChannel) -> Void)?
    var onNames: (([ConsoleChannel: String]) -> Void)?
    var onControl: ((ControlSource, Int32) -> Void)?

    static let port: UInt16 = 9000
    static let inputs = 1...32

    /// Everything the link does runs here; the engine moves events to the main queue itself.
    private let queue = DispatchQueue(label: "remora.example-desk")
    private let udp: UDPLink
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var lastHeard = Date.distantPast
    private var live = false
    private var selected: ConsoleChannel?
    private var names: [ConsoleChannel: String] = [:]

    init(host: String, platform: Platform) {
        udp = platform.udp(host: host, port: Self.port, queue: queue)
        udp.onState = { [weak self] in self?.socket($0) }
        udp.onDatagram = { [weak self] in self?.received($0) }
    }

    func start() { queue.async { self.udp.start() } }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            udp.stop()
        }
    }

    // MARK: The read guard

    /// True only for a request to read: an address on the list, with no arguments.
    static func isReadRequest(_ m: OSC.Message) -> Bool {
        guard m.args.isEmpty else { return false }
        if m.address == "/info" || m.address == "/sel" { return true }
        return inputs.contains { m.address == "/ch/\($0)/name" }
    }

    /// The only way anything reaches the desk.
    private func ask(_ address: String) {
        let m = OSC.Message(address: address, args: [])
        precondition(Self.isReadRequest(m), "Remora sends only reads to a console")
        udp.send(OSC.encode(m))
    }

    // MARK: The link

    private func socket(_ st: StreamState) {
        switch st {
        case .connected:
            onState?(.waitingForDesk)
            ask("/info")
            startPolling()
        case .connecting: onState?(.connecting)
        case .failed(let why): onState?(.failed(why))
        case .stopped: onState?(.stopped)
        }
    }

    /// Five times a second: the selection while the desk answers, only `/info` while it doesn't.
    /// The names at the start and every 30 s. A desk that has said nothing for 5 s is gone.
    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        ticks += 1
        if live, Date().timeIntervalSince(lastHeard) > 5 {
            live = false
            onState?(.waitingForDesk)
        }
        guard live else {
            if ticks % 10 == 0 { ask("/info") }
            return
        }
        ask("/sel")
        if ticks % 150 == 0 { askNames() }
    }

    private func askNames() {
        for n in Self.inputs { ask("/ch/\(n)/name") }
    }

    // MARK: Answers

    private func received(_ bytes: [UInt8]) {
        for m in OSC.parse(bytes) {
            lastHeard = Date()
            if !live {
                live = true
                onState?(.live)
                askNames()
            }
            switch (m.address, m.args.first) {
            case ("/info", .string(let model)?):
                onModel?(model)
            case ("/sel", .int(let i)?):
                let ch = ConsoleChannel.input(Int(i) + 1)
                if ch != selected {
                    selected = ch
                    onSelected?(ch)
                }
            case (let a, .string(let name)?) where a.hasPrefix("/ch/") && a.hasSuffix("/name"):
                guard let n = Int(a.dropFirst(4).dropLast(5)), Self.inputs.contains(n) else { continue }
                let ch = ConsoleChannel.input(n)
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if names[ch] != (trimmed.isEmpty ? nil : trimmed) {
                    names[ch] = trimmed.isEmpty ? nil : trimmed
                    onNames?(names)
                }
            default:
                break
            }
        }
    }

    // MARK: The registry entry

    static let entry = ConsoleModuleEntry(ModuleInfo(
        id: "example.desk", kind: .console,
        title: "Example desk", product: "Example", maker: "Example", status: .experimental,
        about: "OSC over UDP 9000: /sel for the selected input and /ch/N/name for its name, asked five times a second and every 30 s. Built from the example's own description; never run on a desk.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.follows, .names])
    ) { c in LinkConsoleModule(ExampleDesk(host: c.consoleHost, platform: c.platform)) }
}

final class ModuleGuideTests: XCTestCase {
    override func setUp() { Log.enabled = false }

    func testTheExampleDeskFollowsTheSelectionAndReadsNames() throws {
        let p = TestPlatform()
        let desk = ExampleDesk(host: "10.0.0.30", platform: p)
        var states: [ConsoleState] = []
        var model: String?
        var selected: [ConsoleChannel] = []
        var names: [ConsoleChannel: String] = [:]
        desk.onState = { states.append($0) }
        desk.onModel = { model = $0 }
        desk.onSelected = { selected.append($0) }
        desk.onNames = { names = $0 }
        desk.start()
        defer { desk.stop() }

        let udp = try XCTUnwrap(p.udps.first)
        XCTAssertEqual(udp.host, "10.0.0.30")
        XCTAssertEqual(udp.port, 9000)
        XCTAssertEqual(udp.messages.map(\.address), ["/info"], "until the desk answers, it is only asked what it is")

        udp.answer("/info", [.string("EX-1")])
        udp.answer("/sel", [.int(4)])
        udp.answer("/sel", [.int(4)])
        udp.answer("/ch/5/name", [.string("Lead Vox")])
        udp.answer("/ch/6/name", [.string("  ")])
        udp.answer("/ch/99/name", [.string("not an input")])

        XCTAssertEqual(states, [.waitingForDesk, .live])
        XCTAssertEqual(model, "EX-1")
        XCTAssertEqual(selected, [.input(5)], "the same selection twice is one event")
        XCTAssertEqual(names, [.input(5): "Lead Vox"], "an empty name is no name")
        XCTAssertTrue(udp.messages.allSatisfy(ExampleDesk.isReadRequest), "everything sent is a read")
    }

    /// The guard on every message the desk could be sent: only a read from the list passes.
    func testTheReadGuard() {
        XCTAssertTrue(ExampleDesk.isReadRequest(OSC.Message(address: "/sel", args: [])))
        XCTAssertTrue(ExampleDesk.isReadRequest(OSC.Message(address: "/ch/32/name", args: [])))
        XCTAssertFalse(ExampleDesk.isReadRequest(OSC.Message(address: "/sel", args: [.int(3)])), "a set")
        XCTAssertFalse(ExampleDesk.isReadRequest(OSC.Message(address: "/ch/1/name", args: [.string("x")])), "a rename")
        XCTAssertFalse(ExampleDesk.isReadRequest(OSC.Message(address: "/ch/33/name", args: [])), "not an input")
        XCTAssertFalse(ExampleDesk.isReadRequest(OSC.Message(address: "/ch/1/mute", args: [])), "not on the list")
    }

    /// Registered, the engine makes it from settings.json's `console`, and follows it to a rack.
    func testTheEngineMakesItFromTheRegistry() throws {
        let registry = ModuleRegistry(consoles: [ExampleDesk.entry], hosts: [ExampleOSCHost.entry(ExampleOSCHost.info())])
        var s = Settings()
        s.console = "example.desk"
        s.consoleHost = "10.0.0.30"
        s.pluginHost = "example.osc"
        let p = TestPlatform()
        let bridge = Bridge(settings: s, sink: NullSink(), registry: registry, platform: p)
        bridge.start()
        defer { bridge.stop() }
        let desk = try XCTUnwrap(p.udps.first { $0.port == 9000 })
        let host = try XCTUnwrap(p.udps.first { $0.port == 7000 })
        host.answer("/racks", [.string("Kick"), .string("Lead Vox")])
        desk.answer("/info", [.string("EX-1")])
        desk.answer("/ch/5/name", [.string("Lead Vox")])
        desk.answer("/sel", [.int(4)])
        let until = Date().addingTimeInterval(2)
        while bridge.status.mappedRack == nil, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(bridge.status.mappedRack?.name, "Lead Vox")
        XCTAssertEqual(host.messages.last, OSC.Message(address: "/show", args: [.int(2)]))
    }
}
