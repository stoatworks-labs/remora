import RemoraCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: Model
    let saveMapping: () -> Void
    @State private var tab: Tab

    init(model: Model, saveMapping: @escaping () -> Void, tab: Tab = .console) {
        self.model = model
        self.saveMapping = saveMapping
        _tab = State(initialValue: tab)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case console = "Console", superRack = "SuperRack", channels = "Channels"
        case controls = "Controls", companion = "Companion", log = "Log"
        var id: Self { self }
    }

    var body: some View {
        // A segmented picker, not a TabView: on macOS 26 a TabView moves its tabs into the window's
        // toolbar, and in this window they ended up hidden behind a » overflow button.
        VStack(spacing: 14) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Group {
                switch tab {
                case .console: ConsoleTab(model: model)
                case .superRack: SuperRackTab(model: model, saveMapping: saveMapping)
                case .channels: ChannelsTab(model: model)
                case .controls: ControlsTab(model: model)
                case .companion: CompanionTab(model: model)
                case .log: LogTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 480)
    }
}

private struct ConsoleTab: View {
    @ObservedObject var model: Model
    @State private var host = ""

    var body: some View {
        Form {
            Section {
                Picker("Console", selection: Binding(
                    get: { model.settings.consoleKind },
                    set: { v in model.edit { $0.consoleKind = v } })) {
                    ForEach(ConsoleKind.allCases, id: \.self) { k in
                        Text(k.experimental ? "\(k.title) (experimental)" : k.title).tag(k)
                    }
                }
                if model.settings.consoleKind.needsMIDIChannel {
                    Stepper("The desk's MIDI channel: \(model.settings.consoleMIDIChannel)", value: Binding(
                        get: { model.settings.consoleMIDIChannel },
                        set: { v in model.edit { $0.consoleMIDIChannel = v } }), in: 1...16)
                }
                HStack {
                    TextField("Console address", text: $host, prompt: Text("192.168.1.100"))
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                }
                Text(statusText).foregroundStyle(.secondary)
                Text("Remora reads the desk and never changes it. \(model.settings.consoleKind.about)")
                    .font(.caption).foregroundStyle(.secondary)
                if model.settings.consoleKind.experimental {
                    Text("Experimental: written from the maker's documents and not yet run on a real desk. Try it before a show depends on it, and tell me how it went.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                if !model.settings.consoleKind.canFollow {
                    Text("This desk cannot say which channel is selected, so there is nothing to follow. Learn its soft keys as Go to rack controls instead (Controls tab).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Follow the console's selected channel", isOn: Binding(
                    get: { model.settings.follow },
                    set: { model.bridge.setFollow($0) }))
                Picker("When a channel has no rack", selection: Binding(
                    get: { model.settings.noRack },
                    set: { v in model.edit { $0.noRack = v } })) {
                    Text("Stay on the current rack").tag(NoRackBehaviour.stay)
                    Text("Go back to the overview").tag(NoRackBehaviour.overview)
                }
                Toggle("Open the rack page after moving", isOn: Binding(
                    get: { model.settings.openRackAfterMove },
                    set: { v in model.edit { $0.openRackAfterMove = v } }))
            }
        }
        .formStyle(.grouped)
        .onAppear { host = model.settings.consoleHost }
    }

    private func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        model.edit { $0.consoleHost = h }
    }

    private var statusText: String {
        let st = model.status
        var s: String
        switch st.console {
        case .stopped: s = model.settings.consoleHost.isEmpty ? "Set the console's address." : "Stopped."
        case .connecting: s = "Connecting…"
        case .waitingForDesk: s = "Connected, waiting for the desk."
        case .live: s = "Live\(st.model.map { ": \($0)" } ?? "")."
        case .failed(let why): s = "Not connected: \(why)."
        }
        s += st.namesConnected ? " Names: \(st.namedChannels) channels." : " Names: not connected."
        if let ch = st.selected {
            s += " Selected: \(ch)\(st.selectedName.map { " “\($0)”" } ?? "")"
            s += st.mappedRack.map { " → rack \($0.label)." } ?? " → no rack."
        }
        return s
    }
}

private struct SuperRackTab: View {
    @ObservedObject var model: Model
    let saveMapping: () -> Void

    var body: some View {
        Form {
            Section("Session") {
                Text(model.settings.sessionPath).font(.caption).textSelection(.enabled)
                if let e = model.status.sessionError {
                    Text(e).foregroundStyle(.red)
                } else {
                    Text(model.status.racks.map(\.label).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("MIDI") {
                Text("Port “\(model.settings.midiPortName)”\(model.status.midiReady ? "" : " could not be made")")
                Stepper("Channel \(model.settings.midiChannel)", value: Binding(
                    get: { model.settings.midiChannel },
                    set: { v in model.edit { $0.midiChannel = v } }), in: 1...16)
                Stepper("Rack and plug-in commands on CC \(model.settings.ccBase)–\(model.settings.ccBase + 5)", value: Binding(
                    get: { model.settings.ccBase },
                    set: { v in model.edit { $0.ccBase = v } }), in: 0...122)
                Stepper("\(model.settings.stepMilliseconds) ms between steps", value: Binding(
                    get: { model.settings.stepMilliseconds },
                    set: { v in model.edit { $0.stepMilliseconds = v } }), in: 2...200, step: 2)
                Toggle("Read the rack from SuperRack's window", isOn: Binding(
                    get: { model.settings.readRackFromWindow },
                    set: { v in model.edit { $0.readRackFromWindow = v } }))
                Text("SuperRack's MIDI can only step to the next or previous rack, and never says where it is. With Accessibility, Remora reads the rack's name in SuperRack's top bar and steps straight there, so a click in SuperRack no longer throws it. \(rackReadingLine)")
                    .font(.caption).foregroundStyle(.secondary)
                if model.settings.readRackFromWindow && !model.status.pluginWindows.trusted {
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                Picker("When counting", selection: Binding(
                    get: { model.settings.mode },
                    set: { v in model.edit { $0.mode = v } })) {
                    Text("Back to rack 1 first, every time (safe)").tag(SuperRackDriver.Mode.homeEveryTime)
                    Text("Count from the last move (fast)").tag(SuperRackDriver.Mode.countFromLast)
                }
                Text("Without the window, or for racks that share a name such as n/a, Remora counts steps. “Count from the last move” goes wrong if someone clicks a rack in SuperRack, until Resync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Third-party plug-in windows") {
                Toggle("Close them when the rack, page or plug-in changes", isOn: Binding(
                    get: { model.settings.closePluginWindows },
                    set: { v in model.edit { $0.closePluginWindows = v } }))
                Toggle("Place them over the rack page's plug-in area", isOn: Binding(
                    get: { model.settings.placePluginWindows },
                    set: { v in model.edit { $0.placePluginWindows = v } }))
                Toggle("Show the new rack's plug-in after a rack change", isOn: Binding(
                    get: { model.settings.reopenPluginAfterRackChange },
                    set: { v in model.edit { $0.reopenPluginAfterRackChange = v } }))
                Toggle("Hide them while SuperRack isn't the app in front", isOn: Binding(
                    get: { model.settings.hidePluginWindowsInBackground },
                    set: { v in model.edit { $0.hidePluginWindowsInBackground = v } }))
                Text("SuperRack opens non-Waves plug-ins in floating windows and leaves them open on another rack, a Waves plug-in or the overview. Remora closes those, as a docked plug-in would go. A window with SuperRack's pin set is left alone. Placing moves each window over the plug-in area as it opens; SuperRack will not resize them, so a wide one covers the output column. After a rack change on the Rack page SuperRack shows nothing for a non-Waves plug-in; showing it flicks SuperRack to the overview and back (Remora's Back to overview and Open rack page), only when that rack's selected plug-in is a non-Waves one. The windows float over every other app, even with SuperRack behind; hiding minimises them (each leaves a tile in the Dock) and puts them back when SuperRack is in front again, which it comes to whenever it takes one of Remora's commands.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.settings.pluginWindowOptions.any {
                    Text(pluginWindowsLine).font(.caption)
                    if !model.status.pluginWindows.trusted {
                        Button("Open Accessibility Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }
            Section("Set up SuperRack once") {
                Text("1. Setup › MIDI Controller (gear): tick “\(model.settings.midiPortName)” under MIDI In.\n2. Import the mapping saved below, or MIDI Learn the six navigation commands with the buttons.")
                    .font(.caption)
                HStack {
                    Button("Save Mapping…", action: saveMapping)
                    Button("Resync") { model.bridge.resync() }
                }
                // Two rows: six buttons in one ran off the window.
                ForEach([Array(NavCommand.allCases.prefix(4)), Array(NavCommand.allCases.dropFirst(4))], id: \.self) { row in
                    HStack {
                        ForEach(row, id: \.self) { c in
                            Button(c.title) { model.bridge.send(c) }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var rackReadingLine: String {
        let st = model.status.pluginWindows
        guard model.settings.readRackFromWindow else { return "Off: counting only." }
        if st.readsRack { return "Reading it now." }
        guard st.trusted else { return "Remora has no Accessibility grant, so it counts." }
        guard st.attached else { return "SuperRack Performer is not running." }
        return "SuperRack's rack name cannot be seen (its window may be hidden or on another Space), so Remora counts."
    }

    private var pluginWindowsLine: String {
        let st = model.status.pluginWindows
        guard st.trusted else {
            return "Remora needs Accessibility: System Settings › Privacy & Security › Accessibility, then tick Remora."
        }
        guard st.attached else { return "Waiting for SuperRack Performer to start." }
        var s = "Watching SuperRack"
        if !st.logOpen { s += " (its log is not readable, so a Waves plug-in or a page change will not close windows)" }
        s += ". "
        if let a = st.lastAction { s += "Last: \(a)." }
        return s
    }
}

private struct ChannelsTab: View {
    @ObservedObject var model: Model

    private var channels: [ConsoleChannel] {
        model.bridge.names.keys.sorted()
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Racks are matched by name (“head1” finds “head 1”, “lec 2” finds “Lec”). Pick a rack to override.")
                .font(.caption).foregroundStyle(.secondary)
            if channels.isEmpty {
                Spacer()
                Text("No channel names yet: connect to the console.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(channels, id: \.self) { ch in
                    HStack {
                        Text(ch.description).frame(width: 90, alignment: .leading)
                        Text(model.bridge.names[ch] ?? "").frame(width: 110, alignment: .leading)
                        Picker("", selection: override(ch)) {
                            Text(autoTitle(ch)).tag(-2)
                            Text("No rack").tag(-1)
                            ForEach(model.status.racks, id: \.index) { r in Text(r.label).tag(r.index) }
                        }
                        .labelsHidden()
                        if model.status.selected == ch { Text("selected").font(.caption).foregroundStyle(.tint) }
                    }
                }
            }
        }
    }

    private func autoTitle(_ ch: ConsoleChannel) -> String {
        "By name: \(model.bridge.automaticRack(for: ch).map(\.label) ?? "none")"
    }

    private func override(_ ch: ConsoleChannel) -> Binding<Int> {
        Binding(get: { model.settings.overrides[ch.key] ?? -2 },
                set: { v in model.edit { $0.overrides[ch.key] = v == -2 ? nil : v } })
    }
}

private struct ControlsTab: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading) {
            Text("A console key or knob, or any MIDI control, can drive SuperRack. Press Learn, then press or turn it. On a CL/QL a spare channel's ON key and fader work well; on an Allen & Heath desk, a soft key or MIDI Strip set to send MIDI. For User Keys, plug-in controls and snapshots, choose “Send CC to SuperRack” and MIDI Learn that CC in SuperRack with Send.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(model.settings.controls) { m in
                    ControlRow(model: model, mapping: m)
                }
            }
            HStack {
                Button("Add Control") {
                    model.edit { s in
                        var m = ControlMapping()
                        m.name = "Control \(s.controls.count + 1)"
                        m.cc = min(127, 30 + s.controls.count)
                        s.controls.append(m)
                    }
                }
                if model.status.learning != nil {
                    Text("Learning: press or turn a control…").foregroundStyle(.tint)
                    Button("Cancel") { model.bridge.stopLearning() }
                }
            }
        }
    }
}

private struct ControlRow: View {
    @ObservedObject var model: Model
    let mapping: ControlMapping

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Name", text: field(\.name)).frame(width: 130)
                Picker("", selection: field(\.action)) {
                    ForEach(ControlAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 190)
                Spacer()
                Button(model.status.learning == mapping.id ? "Learning…" : "Learn") {
                    model.bridge.startLearning(mapping.id)
                }
                if mapping.action == .sendCC {
                    Button("Send") { model.bridge.sendForLearn(mapping) }
                }
                Button(role: .destructive) {
                    model.edit { $0.controls.removeAll { $0.id == mapping.id } }
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
            }
            if mapping.action == .goToRack {
                Picker("Rack", selection: field(\.rack)) {
                    ForEach(model.status.racks, id: \.index) { r in Text(r.label).tag(r.index) }
                    if !model.status.racks.contains(where: { $0.index == mapping.rack }) {
                        Text("Rack \(mapping.rack + 1)").tag(mapping.rack)
                    }
                }
                .frame(width: 260)
            }
            // A line of its own: on the first line these squeezed Learn and Send to nothing.
            if mapping.action == .sendCC {
                HStack {
                    Picker("", selection: field(\.mode)) {
                        ForEach(ControlMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                    Stepper("CC \(mapping.cc)", value: field(\.cc), in: 0...127).fixedSize()
                    Text("on channel \(model.settings.midiChannel)").foregroundStyle(.secondary)
                }
            }
            Text(mapping.source.map { "\($0)" + range } ?? "Not learned yet")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var range: String {
        guard mapping.action == .sendCC, mapping.mode == .value, let l = mapping.low, let h = mapping.high else { return "" }
        return ", seen \(l)…\(h)"
    }

    private func field<T>(_ path: WritableKeyPath<ControlMapping, T>) -> Binding<T> {
        Binding(get: { mapping[keyPath: path] },
                set: { v in
                    model.edit { s in
                        if let i = s.controls.firstIndex(where: { $0.id == mapping.id }) {
                            s.controls[i][keyPath: path] = v
                        }
                    }
                })
    }
}

private struct CompanionTab: View {
    @ObservedObject var model: Model

    var body: some View {
        Form {
            Toggle("Listen for OSC", isOn: Binding(
                get: { model.settings.oscEnabled },
                set: { v in model.edit { $0.oscEnabled = v } }))
            // A String, not an interpolated key: that printed the port as "9,020".
            Stepper("UDP port " + String(model.settings.oscPort), value: Binding(
                get: { Int(model.settings.oscPort) },
                set: { v in model.edit { $0.oscPort = UInt16(v) } }), in: 1024...65535)
            Text("""
            In Companion, add a Generic OSC connection to this Mac on that port, then send:
            /remora/rack/next   /remora/rack/prev   /remora/rack/select <number or name>
            /remora/rack/open   /remora/overview    /remora/rack/resync
            /remora/plugin/next   /remora/plugin/prev
            /remora/follow <0 or 1>   /remora/follow/toggle
            /remora/cc <number> <value>   (any CC to SuperRack on Remora's channel)
            """)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        }
        .formStyle(.grouped)
    }
}

private struct LogTab: View {
    @State private var lines: [String] = Log.recent
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            Text(lines.suffix(120).joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .onReceive(timer) { _ in lines = Log.recent }
    }
}
