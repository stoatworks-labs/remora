import Foundation

/// Ties it together: the console's selection moves SuperRack, learned console and MIDI
/// controls drive SuperRack, and OSC lets Companion do both. Main thread only; the links call
/// back on their own queues and hop here.
public final class Bridge {
    public struct Status: Equatable {
        public var console: YamahaEditorLink.State = .stopped
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
        public var pluginWindows = PluginWindowGuard.Status()
    }

    public private(set) var settings: Settings
    public private(set) var status = Status() {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    public var onStatus: ((Status) -> Void)?
    /// Called when a control learns a source or widens its range: save the settings.
    public var onSettingsChanged: ((Settings) -> Void)?

    public private(set) var names: [YamahaChannel: String] = [:]

    private var editor: YamahaEditorLink?
    private var rcp: YamahaRCPNames?
    private let midi: MIDIEndpoint?
    private let driver: SuperRackDriver
    private let osc = OSCListener()
    private let windows = PluginWindowGuard()
    private var sessionStamp = ""
    private var sessionTimer: Timer?
    // Learning: parameters heard just before Learn was pressed are noise (meters, clocks).
    private var recentlyHeard: [YamahaSysEx.Address: Date] = [:]
    private var learnStarted = Date.distantPast

    public init(settings: Settings, sink: CCSink? = nil) {
        self.settings = settings
        if let sink {
            midi = nil
            driver = SuperRackDriver(sink: sink)
        } else {
            let m = MIDIEndpoint(name: settings.midiPortName)
            midi = m
            driver = SuperRackDriver(sink: m ?? NullSink())
        }
        driver.config = settings.driverConfig
        driver.onPosition = { [weak self] p in
            DispatchQueue.main.async { self?.status.position = p }
        }
        windows.onStatus = { [weak self] st in self?.status.pluginWindows = st }
        midi?.onEvent = { [weak self] e in DispatchQueue.main.async { self?.midiEvent(e) } }
        osc.onMessage = { [weak self] m in DispatchQueue.main.async { self?.oscMessage(m) } }
        status.midiReady = midi != nil || sink != nil
    }

    public func start() {
        reloadSession(force: true)
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reloadSession(force: false)
        }
        connectConsole()
        startOSC()
        if settings.pluginWindowOptions.any { windows.set(settings.pluginWindowOptions) }
        let port = midi == nil ? "a test sink (no MIDI port)" : "MIDI port \"\(settings.midiPortName)\" \(status.midiReady ? "up" : "FAILED")"
        Log.line("Remora: \(port), channel \(settings.midiChannel), CC \(settings.ccBase)–\(settings.ccBase + 5)")
    }

    public func stop() {
        sessionTimer?.invalidate()
        editor?.stop()
        rcp?.stop()
        osc.stop()
        windows.stop()
    }

    public func update(_ new: Settings) {
        let old = settings
        settings = new
        driver.config = new.driverConfig
        if new.consoleHost != old.consoleHost { connectConsole() }
        if new.sessionPath != old.sessionPath { reloadSession(force: true) }
        if new.oscEnabled != old.oscEnabled || new.oscPort != old.oscPort { startOSC() }
        if new.pluginWindowOptions != old.pluginWindowOptions { windows.set(new.pluginWindowOptions) }
        if new.overrides != old.overrides, let ch = status.selected { status.mappedRack = rack(for: ch) }
        if new.midiPortName != old.midiPortName {
            Log.line("Remora: the MIDI port name takes effect at the next launch")
        }
    }

    // MARK: SuperRack

    public func select(rack: Int) { driver.select(rack) }
    /// Forgets the position and homes, then goes back to the selected channel's rack if following.
    public func resync() {
        driver.resync()
        if settings.follow, let ch = status.selected, let r = rack(for: ch) {
            Log.line("SuperRack: resync (home, then rack \(r.label) for \(ch))")
            driver.select(r.index)
        } else {
            Log.line("SuperRack: resync (home to rack 1)")
        }
    }
    public func send(_ c: NavCommand) { driver.send(c) }
    public func sendCC(_ number: Int, value: Int) { driver.sendRaw(number: number, value: value) }

    /// Sends a control's CC once so SuperRack's MIDI Learn can pick it up.
    public func sendForLearn(_ m: ControlMapping) { driver.sendRaw(number: m.cc, value: 127) }

    private func reloadSession(force: Bool) {
        let path = settings.sessionPath
        let stamp = SuperRackSession.stamp(path)
        guard force || stamp != sessionStamp else { return }
        sessionStamp = stamp
        do {
            let racks = try SuperRackSession.racks(at: path)
            if racks != status.racks {
                Log.line("SuperRack: \(racks.count) racks: \(racks.map(\.name).joined(separator: ", "))")
            }
            driver.rackCount = max(racks.count, 1)
            status.racks = racks
            status.sessionError = nil
            if let ch = status.selected { status.mappedRack = rack(for: ch) }
        } catch {
            if status.sessionError != "\(error)" { Log.line("SuperRack: \(error)") }
            status.sessionError = "\(error)"
        }
    }

    // MARK: Console

    private func connectConsole() {
        editor?.stop()
        rcp?.stop()
        editor = nil
        rcp = nil
        status.console = .stopped
        status.namesConnected = false
        status.selected = nil
        status.model = nil
        names = [:]
        let host = settings.consoleHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        let e = YamahaEditorLink(host: host)
        e.onState = { [weak self] st in
            DispatchQueue.main.async {
                guard let self else { return }
                if st != self.status.console { Log.line("Console: \(st)") }
                self.status.console = st
            }
        }
        e.onChange = { [weak self] c in DispatchQueue.main.async { self?.consoleChange(c) } }
        let r = YamahaRCPNames(host: host)
        r.onState = { [weak self] up in DispatchQueue.main.async { self?.status.namesConnected = up } }
        r.onModel = { [weak self] m in
            DispatchQueue.main.async {
                Log.line("Console: \(m) at \(host)")
                self?.status.model = m
            }
        }
        r.onNames = { [weak self] n in DispatchQueue.main.async { self?.namesArrived(n) } }
        editor = e
        rcp = r
        e.start()
        r.start()
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
    /// For tests: a change as the editor port would deliver it.
    public func consoleChangeForTesting(_ c: YamahaSysEx.Change) { consoleChange(c) }
    /// For tests: racks as the session would give them.
    public func setRacksForTesting(_ r: [Rack]) {
        status.racks = r
        driver.rackCount = r.count
    }
    public var driverForTesting: SuperRackDriver { driver }

    private func consoleChange(_ c: YamahaSysEx.Change) {
        if c.address == YamahaSysEx.selectedChannel {
            let ch = YamahaChannel(selection: Int(c.value))
            guard ch != status.selected else { return }
            status.selected = ch
            status.selectedName = names[ch]
            status.mappedRack = rack(for: ch)
            // Names not in yet: namesArrived follows this selection when they are, unless
            // an override already says where it goes.
            if names.isEmpty, rcp != nil, settings.overrides[ch.key] == nil { return }
            follow(ch)
            return
        }
        if YamahaSysEx.selectionNoise.contains(c.address.element) { return }
        if let id = status.learning, Date().timeIntervalSince(learnStarted) > 0.3,
           (recentlyHeard[c.address].map { learnStarted.timeIntervalSince($0) > 2 } ?? true) {
            learned(id, .yamaha(c.address), value: c.value)
            return
        }
        recentlyHeard[c.address] = Date()
        run(.yamaha(c.address), value: c.value, isPress: true)
    }

    private func follow(_ ch: YamahaChannel) {
        let name = names[ch].map { " \"\($0)\"" } ?? ""
        guard settings.follow else {
            Log.line("Console: selected \(ch)\(name) (follow is off)")
            return
        }
        if let r = rack(for: ch) {
            Log.line("Console: selected \(ch)\(name) → rack \(r.label)")
            driver.select(r.index)
        } else {
            Log.line("Console: selected \(ch)\(name) → no rack")
            if settings.noRack == .overview { driver.send(.overview) }
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
                driver.sendRaw(number: m.cc, value: settings.controls[i].ccValue(for: value))
            default:
                guard isPress else { continue }
                if let nav = m.action.nav { driver.send(nav) }
                if m.action == .resync { resync() }
                if m.action == .toggleFollow { setFollow(!settings.follow) }
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
        case "/remora/rack/next": driver.send(.nextRack)
        case "/remora/rack/prev", "/remora/rack/previous": driver.send(.previousRack)
        case "/remora/rack/open": driver.send(.openRack)
        case "/remora/overview", "/remora/rack/overview": driver.send(.overview)
        case "/remora/plugin/next": driver.send(.nextPlugin)
        case "/remora/plugin/prev", "/remora/plugin/previous": driver.send(.previousPlugin)
        case "/remora/rack/resync", "/remora/resync": resync()
        case "/remora/rack/select":
            if case .string(let s)? = first, Int(s) == nil {
                if let r = RackMatcher.match(s, in: status.racks) { driver.select(r.index) }
                else { Log.line("OSC: no rack called \"\(s)\"") }
            } else if let n = first?.number {
                driver.select(Int(n) - 1)
            }
        case "/remora/follow":
            if let n = first?.number { setFollow(n != 0) }
        case "/remora/follow/toggle": setFollow(!settings.follow)
        case "/remora/cc":
            if m.args.count >= 2, let n = m.args[0].number, let v = m.args[1].number {
                driver.sendRaw(number: Int(n), value: Int(v))
            }
        default:
            Log.line("OSC: unknown address \(m.address)")
            return
        }
        Log.line("OSC: \(m.address) \(m.args.map(\.text).joined(separator: " "))")
    }
}

private final class NullSink: CCSink {
    func sendCC(channel: Int, number: Int, value: Int) {}
}
