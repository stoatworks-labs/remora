import Foundation
import RemoraConsoles
import RemoraCore
import RemoraHosts

/// The engine. It ties a console module to a plug-in host module: the desk's selection shows that
/// channel's rack, learned console and MIDI controls drive the host, and OSC lets Companion do
/// both. It knows no protocol: the modules do. Main thread only; modules report on their own
/// queues and their events hop here.
public final class Bridge {
    public struct Status: Equatable {
        public var console: ConsoleState = .stopped
        public var namesConnected = false
        public var model: String?
        public var selected: YamahaChannel?
        public var selectedName: String?
        /// The rack the selection maps to, if any.
        public var mappedRack: Rack?
        public var position: Int?
        public var racks: [Rack] = []
        public var sessionError: String?
        public var midiReady = false
        public var learning: UUID?
        public var namedChannels = 0
        public var pluginWindows = PluginWindowStatus()
        /// The host module's own link to the host, for one that has one (SuperRack over ProLink).
        public var hostLink: HostLink?
    }

    public private(set) var settings: Settings
    public private(set) var status = Status() {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    public var onStatus: ((Status) -> Void)?
    /// Called when a control learns a source or widens its range: save the settings.
    public var onSettingsChanged: ((Settings) -> Void)?

    public private(set) var names: [YamahaChannel: String] = [:]

    public let registry: ModuleRegistry
    private let platform: Platform
    private var console: ConsoleModule?
    private var host: HostModule?
    /// The host module's description; nil when settings name a host this build does not have.
    public private(set) var hostInfo: ModuleInfo?
    private let midi: MIDILink?
    /// Where host modules send MIDI: the test sink, or Remora's port.
    private let midiOut: CCSink?
    private let osc: OSCReceiver
    private var started = false
    /// Keeps App Nap off: a napping menu-bar app gets its timers stretched, and a 2 ms rack step
    /// became ~66 ms under background throttling (taskpolicy -b) in a test.
    private var activity: NSObjectProtocol?
    // Learning: parameters heard just before Learn was pressed are noise (meters, clocks).
    private var recentlyHeard: [ControlSource: Date] = [:]
    private var learnStarted = Date.distantPast

    /// `sink` stands in for Remora's MIDI port (tests, dry runs): no port is made.
    public init(settings: Settings, sink: CCSink? = nil, registry: ModuleRegistry = .standard,
                platform: Platform = Bridge.defaultPlatform()) {
        self.settings = settings
        self.registry = registry
        self.platform = platform
        if let sink {
            midi = nil
            midiOut = sink
        } else {
            midi = platform.midi(name: settings.midiPortName)
            midiOut = midi
        }
        osc = platform.oscReceiver()
        makeHost()
        midi?.onEvent = { [weak self] e in DispatchQueue.main.async { self?.midiEvent(e) } }
        osc.onMessage = { [weak self] m in DispatchQueue.main.async { self?.oscMessage(m) } }
        status.midiReady = midi != nil || sink != nil
    }

    public func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Following the console and driving SuperRack")
        started = true
        host?.start()
        connectConsole()
        startOSC()
        let port = midi == nil ? "a test sink (no MIDI port)" : "MIDI port \"\(settings.midiPortName)\" \(status.midiReady ? "up" : "FAILED")"
        Log.line("Remora: \(port), channel \(settings.midiChannel), CC \(settings.ccBase)–\(settings.ccBase + 5)")
    }

    public func stop() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        started = false
        console?.stop()
        osc.stop()
        host?.stop()
    }

    public func update(_ new: Settings) {
        let old = settings
        settings = new
        if new.pluginHost != old.pluginHost {
            makeHost()
            if started { host?.start() }
        } else {
            host?.update(new)
        }
        if new.consoleHost != old.consoleHost || new.console != old.console
            || new.consoleMIDIChannel != old.consoleMIDIChannel { connectConsole() }
        if new.oscEnabled != old.oscEnabled || new.oscPort != old.oscPort { startOSC() }
        if new.overrides != old.overrides, let ch = status.selected { status.mappedRack = rack(for: ch) }
        if new.midiPortName != old.midiPortName {
            Log.line("Remora: the MIDI port name takes effect at the next launch")
        }
    }

    // MARK: The plug-in host

    public func select(rack: Int) { host?.perform(.show(rack)) }
    /// Forgets where the host is and finds out again, then goes back to the selected channel's rack
    /// if following.
    public func resync() {
        host?.perform(.resync)
        let product = hostInfo?.product ?? "Plug-in host"
        if settings.follow, let ch = status.selected, let r = rack(for: ch) {
            Log.line("\(product): resync (home, then rack \(r.label) for \(ch))")
            host?.perform(.show(r.index))
        } else {
            Log.line("\(product): resync (home to rack 1)")
        }
    }
    public func send(_ c: NavCommand) { host?.perform(c.hostCommand) }
    public func sendCC(_ number: Int, value: Int) { host?.perform(.cc(number: number, value: value)) }

    /// Sends a control's CC once so SuperRack's MIDI Learn can pick it up.
    public func sendForLearn(_ m: ControlMapping) { host?.perform(.cc(number: m.cc, value: 127)) }

    private func makeHost() {
        host?.stop()
        host = nil
        hostInfo = nil
        status.racks = []
        status.position = nil
        status.mappedRack = nil
        status.pluginWindows = PluginWindowStatus()
        status.sessionError = nil
        status.hostLink = nil
        guard let entry = registry.host(settings.pluginHost) else {
            let why = "\(settings.pluginHost) is not in this version of Remora"
            Log.line("Plug-in host: \(why)")
            status.sessionError = why
            return
        }
        let h = entry.make(ModuleContext(settings: settings, platform: platform, midiOut: midiOut))
        h.onEvent = { [weak self] e in
            if Thread.isMainThread { self?.hostEvent(e) } else { DispatchQueue.main.async { self?.hostEvent(e) } }
        }
        host = h
        hostInfo = entry.info
    }

    private func hostEvent(_ e: HostEvent) {
        switch e {
        case .racks(let r):
            status.racks = r
            if let ch = status.selected { status.mappedRack = rack(for: ch) }
        case .position(let p): status.position = p
        case .windows(let w): status.pluginWindows = w
        case .problem(let p): status.sessionError = p
        case .link(let l): status.hostLink = l
        }
    }

    // MARK: Console

    private func connectConsole() {
        console?.stop()
        console = nil
        status.console = .stopped
        status.namesConnected = false
        status.selected = nil
        status.model = nil
        names = [:]
        let host = settings.consoleHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        guard let entry = registry.console(settings.console) else {
            let why = "\(settings.console) is not in this version of Remora"
            Log.line("Console: \(why)")
            status.console = .failed(why)
            return
        }
        let c = entry.make(ModuleContext(settings: settings, platform: platform, midiOut: midiOut))
        // Always later on the main queue, even from a link that reports inside `stop()`.
        c.onEvent = { [weak self] e in DispatchQueue.main.async { self?.consoleEvent(e, host: host) } }
        console = c
        if entry.info.experimental {
            Log.line("Console: \(entry.info.title) is experimental: built from the maker's documents, never run on a desk")
        }
        c.start()
    }

    private func consoleEvent(_ e: ConsoleEvent, host: String) {
        switch e {
        case .link(let st):
            if st != status.console { Log.line("Console: \(st)") }
            status.console = st
        case .namesLink(let up): status.namesConnected = up
        case .model(let m):
            Log.line("Console: \(m) at \(host)")
            status.model = m
        case .names(let n): namesArrived(n)
        case .selected(let ch): selected(ch)
        case .control(let src, let v): consoleControl(src, value: v)
        }
    }

    private func namesArrived(_ n: [YamahaChannel: String]) {
        let first = names.isEmpty
        names = n
        status.namedChannels = n.count
        guard let ch = status.selected else { return }
        status.selectedName = n[ch]
        let before = status.mappedRack
        status.mappedRack = rack(for: ch)
        // The selection arrived before its name: follow it now.
        if first || before != status.mappedRack { follow(ch) }
    }

    /// The rack for a channel: the override if there is one, else by name.
    /// A ST IN's right half takes its left half's override when it has none of its own.
    public func rack(for ch: YamahaChannel) -> Rack? {
        var o = settings.overrides[ch.key]
        if o == nil, case .stereoIn(let n, true) = ch {
            o = settings.overrides[YamahaChannel.stereoIn(n, right: false).key]
        }
        if let o { return status.racks.first { $0.index == o } }
        return automaticRack(for: ch)
    }

    /// The match by name, ignoring overrides. A ST IN half also tries its name without the
    /// trailing L or R, so "PB L" and "PB R" both find "PB".
    public func automaticRack(for ch: YamahaChannel) -> Rack? {
        guard let name = names[ch] else { return nil }
        if let r = RackMatcher.match(name, in: status.racks) { return r }
        guard case .stereoIn = ch, let last = name.last, "LRlr".contains(last) else { return nil }
        return RackMatcher.match(String(name.dropLast()), in: status.racks)
    }

    /// For tests: names as RCP would deliver them.
    public func setNamesForTesting(_ n: [YamahaChannel: String]) { namesArrived(n) }
    /// For tests: a change as the CL/QL editor port would deliver it.
    public func consoleChangeForTesting(_ c: YamahaSysEx.Change) {
        switch YamahaCLQLConsole.interpret(c) {
        case .selected(let ch): selected(ch)
        case .control(let src, let v): consoleControl(src, value: v)
        case .none: break
        }
    }
    /// For tests: a control as a desk would report it.
    public func controlForTesting(_ source: ControlSource, value: Int32) { consoleControl(source, value: value) }
    /// For tests: a selection as any desk would report it.
    public func selectionForTesting(_ ch: ConsoleChannel) { selected(ch) }
    /// For tests: racks as SuperRack's session would give them.
    public func setRacksForTesting(_ r: [Rack]) { superRack?.setRacksForTesting(r) }
    public var driverForTesting: SuperRackDriver {
        guard let s = superRack else { preconditionFailure("the testing hooks drive SuperRack MIDI") }
        return s.driver
    }
    /// For tests: stands in for SuperRack's window. Nil: counting only, as without Accessibility.
    public func setRackReaderForTesting(_ r: RackNameReader?) { superRack?.driver.reader = r }
    private var superRack: SuperRackMIDIModule? { host as? SuperRackMIDIModule }

    private func selected(_ ch: ConsoleChannel) {
        guard ch != status.selected else { return }
        status.selected = ch
        status.selectedName = names[ch]
        status.mappedRack = rack(for: ch)
        // Names not in yet: namesArrived follows this selection when they are, unless
        // an override already says where it goes.
        if names.isEmpty, console != nil, settings.overrides[ch.key] == nil { return }
        follow(ch)
    }

    private func consoleControl(_ source: ControlSource, value: Int32) {
        // A desk's MIDI (A&H) is a press only when it is on, as from any MIDI source; every
        // CL/QL change is one.
        var isPress = true
        if case .midi = source { isPress = value > 0 }
        if let id = status.learning, isPress, Date().timeIntervalSince(learnStarted) > 0.3,
           (recentlyHeard[source].map { learnStarted.timeIntervalSince($0) > 2 } ?? true) {
            learned(id, source, value: value)
            return
        }
        recentlyHeard[source] = Date()
        run(source, value: value, isPress: isPress)
    }

    private func follow(_ ch: YamahaChannel) {
        let name = names[ch].map { " \"\($0)\"" } ?? ""
        guard settings.follow else {
            Log.line("Console: selected \(ch)\(name) (follow is off)")
            return
        }
        if let r = rack(for: ch) {
            Log.line("Console: selected \(ch)\(name) → rack \(r.label)")
            host?.perform(.show(r.index))
        } else {
            Log.line("Console: selected \(ch)\(name) → no rack")
            if settings.noRack == .overview { host?.perform(.overview) }
        }
    }

    public func setFollow(_ on: Bool) {
        var s = settings
        s.follow = on
        update(s)
        onSettingsChanged?(s)
        Log.line("Follow \(on ? "on" : "off")")
        if on, let ch = status.selected { follow(ch) }
    }

    // MARK: Controls

    public func startLearning(_ id: UUID) {
        learnStarted = Date()
        status.learning = id
    }

    public func stopLearning() { status.learning = nil }

    private func learned(_ id: UUID, _ source: ControlSource, value: Int32) {
        status.learning = nil
        guard let i = settings.controls.firstIndex(where: { $0.id == id }) else { return }
        var s = settings
        s.controls[i].source = source
        s.controls[i].low = nil
        s.controls[i].high = nil
        s.controls[i].observe(value)
        Log.line("Learned \(source) for \"\(s.controls[i].name)\"")
        update(s)
        onSettingsChanged?(s)
    }

    private func midiEvent(_ e: MIDIEvent) {
        let source = ControlSource.midi(source: e.source, kind: e.kind, channel: e.channel, number: e.number)
        if let id = status.learning, e.value > 0 {
            learned(id, source, value: Int32(e.value))
            return
        }
        run(source, value: Int32(e.value), isPress: e.value > 0)
    }

    private func run(_ source: ControlSource, value: Int32, isPress: Bool) {
        var changed = false
        for i in settings.controls.indices where settings.controls[i].source == source {
            let m = settings.controls[i]
            switch m.action {
            case .sendCC:
                if m.mode == .value, settings.controls[i].observe(value) { changed = true }
                if m.mode == .trigger && !isPress { continue }
                host?.perform(.cc(number: m.cc, value: settings.controls[i].ccValue(for: value)))
            default:
                guard isPress else { continue }
                if let c = m.action.command { host?.perform(c) }
                if m.action == .resync { resync() }
                if m.action == .toggleFollow { setFollow(!settings.follow) }
                if m.action == .goToRack {
                    Log.line("Control \"\(m.name)\" → rack \(m.rack + 1)")
                    host?.perform(.show(m.rack))
                }
            }
        }
        if changed { onSettingsChanged?(settings) }
    }

    // MARK: OSC

    private func startOSC() {
        osc.stop()
        guard settings.oscEnabled else { return }
        do {
            try osc.start(port: settings.oscPort)
            Log.line("OSC: listening on UDP \(settings.oscPort)")
        } catch {
            Log.line("OSC: cannot listen on \(settings.oscPort): \(error)")
        }
    }

    /// /remora/rack/next, /prev, /select <n or name>, /resync, /open, /overview,
    /// /remora/plugin/next, /prev, /remora/follow <0|1>, /remora/follow/toggle,
    /// /remora/cc <number> <value>.
    private func oscMessage(_ m: OSC.Message) {
        let a = m.address.lowercased()
        let first = m.args.first
        switch a {
        case "/remora/rack/next": host?.perform(.step(1))
        case "/remora/rack/prev", "/remora/rack/previous": host?.perform(.step(-1))
        case "/remora/rack/open": host?.perform(.openRack)
        case "/remora/overview", "/remora/rack/overview": host?.perform(.overview)
        case "/remora/plugin/next": host?.perform(.stepPlugin(1))
        case "/remora/plugin/prev", "/remora/plugin/previous": host?.perform(.stepPlugin(-1))
        case "/remora/rack/resync", "/remora/resync": resync()
        case "/remora/rack/select":
            if case .string(let s)? = first, Int(s) == nil {
                if let r = RackMatcher.match(s, in: status.racks) { host?.perform(.show(r.index)) }
                else { Log.line("OSC: no rack called \"\(s)\"") }
            } else if let n = first?.number {
                host?.perform(.show(Int(n) - 1))
            }
        case "/remora/follow":
            if let n = first?.number { setFollow(n != 0) }
        case "/remora/follow/toggle": setFollow(!settings.follow)
        case "/remora/cc":
            if m.args.count >= 2, let n = m.args[0].number, let v = m.args[1].number {
                host?.perform(.cc(number: Int(n), value: Int(v)))
            }
        default:
            Log.line("OSC: unknown address \(m.address)")
            return
        }
        Log.line("OSC: \(m.address) \(m.args.map(\.text).joined(separator: " "))")
    }
}
