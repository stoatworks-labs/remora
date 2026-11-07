import RemoraCore
import RemoraEngine
import RemoraHosts
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
        case console = "Console", host = "Plug-in Host", channels = "Channels"
        case controls = "Controls", companion = "Companion", log = "Log"
        var id: Self { self }
        /// For file names: "plug-in host" would not do.
        var slug: String { self == .host ? "host" : rawValue.lowercased() }
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
                case .host: HostTab(model: model, saveMapping: saveMapping)
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

    /// The chosen console module; nil for one from a newer Remora's settings.
    private var info: ModuleInfo? { model.bridge.registry.console(model.settings.console)?.info }

    var body: some View {
        Form {
            Section {
                Picker("Console", selection: Binding(
                    get: { model.settings.console },
                    set: { v in model.edit { $0.console = v } })) {
                    ForEach(model.bridge.registry.consoles, id: \.info.id) { e in
                        Text(e.info.experimental ? "\(e.info.title) (experimental)" : e.info.title).tag(e.info.id)
                    }
                    if info == nil {
                        Text("\(model.settings.console) (not in this version)").tag(model.settings.console)
                    }
                }
                if info?.capabilities.contains(.needsMIDIChannel) == true {
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
                Text("Remora reads the desk and never changes it. \(info?.about ?? "This version of Remora does not have this console: the setting came from a newer Remora.")")
                    .font(.caption).foregroundStyle(.secondary)
                if info?.experimental == true {
                    Text("Experimental: written from the maker's documents and not yet run on a real desk. Try it before a show depends on it, and tell me how it went.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                if info?.capabilities.contains(.follows) == false {
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
            if let r = st.mappedRack {
                s += " → rack \(r.label)"
                if case .routing(let path)? = st.mappedBy { s += ", by routing (\(MappingSource.describe(path)))" }
                s += "."
            } else {
                s += " → no rack."
            }
        }
        return s
    }
}

private struct HostTab: View {
    @ObservedObject var model: Model
    let saveMapping: () -> Void
    /// The host's address as typed, applied on Return or Connect.
    @State private var address = ""

    /// The chosen host module; nil for one from a newer Remora's settings.
    private var info: ModuleInfo? { model.bridge.registry.host(model.settings.pluginHost)?.info }
    private var isMIDI: Bool { model.settings.pluginHost == SuperRackMIDIModule.info.id }
    private var isProLink: Bool { model.settings.pluginHost == SuperRackProLinkModule.info.id }
    private var edition: SuperRackEdition { model.settings.superRackEdition }

    var body: some View {
        Form {
            Section {
                Picker("Plug-in host", selection: Binding(
                    get: { model.settings.pluginHost },
                    set: { v in
                        guard let picked = model.bridge.registry.host(v)?.info else { return }
                        model.edit { $0.pick(host: picked) }
                    })) {
                    ForEach(model.bridge.registry.hosts, id: \.info.id) { e in
                        Text(e.info.experimental ? "\(e.info.title) (experimental)" : e.info.title).tag(e.info.id)
                    }
                    if info == nil {
                        Text("\(model.settings.pluginHost) (not in this version)").tag(model.settings.pluginHost)
                    }
                }
                if info?.product == "SuperRack" {
                    Picker("Edition", selection: Binding(
                        get: { model.settings.superRackEdition },
                        set: { v in model.edit { s in
                            // A session path left at the old edition's own follows the edition.
                            if s.sessionPath == s.superRackEdition.defaultSessionPath { s.sessionPath = v.defaultSessionPath }
                            s.superRackEdition = v
                        } })) {
                        ForEach(SuperRackEdition.allCases, id: \.self) { Text($0.appName).tag($0) }
                    }
                }
                Text(info?.about ?? "This version of Remora does not have this plug-in host: the setting came from a newer Remora.")
                    .font(.caption).foregroundStyle(.secondary)
                if info?.experimental == true {
                    Text("Experimental: not yet run against the real host. Try it before a show depends on it, and tell me how it went.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if isMIDI { midiSections }
            if isProLink { proLinkSections }
            if info?.product == "SuperRack" { windowSection }
            if let info, info.product != "SuperRack" { otherHostSections(info) }
        }
        .formStyle(.grouped)
        .onAppear { address = model.settings.host(model.settings.pluginHost).address }
        .onChange(of: model.settings.pluginHost) { id in address = model.settings.host(id).address }
    }

    // MARK: SuperRack over MIDI

    @ViewBuilder private var midiSections: some View {
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
        Section("Set up SuperRack once") {
            Text("1. Setup › MIDI Controller (gear): tick “\(model.settings.midiPortName)” under MIDI In.\n2. Import the mapping saved below, or MIDI Learn the six navigation commands with the buttons.")
                .font(.caption)
            HStack {
                Button("Save Mapping…", action: saveMapping)
                Button("Resync") { model.bridge.resync() }
            }
            navButtons
        }
    }

    // MARK: SuperRack over ProLink

    @ViewBuilder private var proLinkSections: some View {
        Section("ProLink") {
            Text(linkLine).foregroundStyle(linkFailed ? Color.red : Color.primary)
            TextField("Listen on TCP port", value: Binding(
                get: { Int(model.settings.proLinkPort) },
                set: { v in model.edit { $0.proLinkPort = UInt16(clamping: max(1, v)) } }),
                      format: .number.grouping(.never))
            if !model.status.racks.isEmpty {
                Text(model.status.racks.map(\.label).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Resync") { model.bridge.resync() }
            navButtons
        }
        Section("Set up SuperRack once") {
            Text("1. Setup › Controllers: add “ProLink LAWO Console Remote”.\n2. Its console IP is this Mac's address (127.0.0.1 if SuperRack runs on this Mac), its port \(String(model.settings.proLinkPort)). Assign it.\n3. Its PORT must be a wired Ethernet adapter: Wi-Fi did not work. An adapter plugged in after SuperRack started is listed only once SuperRack restarts.")
                .font(.caption)
            Text("Remora takes one SuperRack at a time. It shows a rack with ShowRack on the rack's first input channel, as a LAWO desk's hot-rack key does; a rack no input feeds is reached by Next or Previous Rack from the nearest one that has one.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Not listening at all (the port is taken): waiting for SuperRack is no failure.
    private var linkFailed: Bool {
        if case .failed? = model.status.hostLink { return true } else { return false }
    }

    private var linkLine: String {
        switch model.status.hostLink {
        case nil: return "Starting."
        case .listening(let p): return "Waiting for SuperRack to connect on TCP \(String(p))."
        case .connecting(let peer): return "SuperRack is connecting from \(peer)…"
        case .connected(let name, let peer): return "Connected: \(name), from \(peer)."
        case .failed(let why): return "Not listening: \(why)."
        }
    }

    // MARK: Any other host

    /// The host's own settings (`HostSettings`): what its `HostDefaults` says it has.
    @ViewBuilder private func otherHostSections(_ info: ModuleInfo) -> some View {
        let d = info.hostDefaults
        let own = model.settings.host(info.id)
        Section(info.product) {
            Text(otherLinkLine(info)).foregroundStyle(otherLinkFailed ? Color.red : Color.primary)
            if d.port != nil {
                HStack {
                    TextField("Address", text: $address, prompt: Text("127.0.0.1"))
                        .onSubmit { applyAddress(info) }
                    Button("Connect") { applyAddress(info) }
                }
                TextField("UDP port", value: Binding(
                    get: { Int(own.port(d)) },
                    set: { v in editHost(info) { $0.port = UInt16(clamping: max(1, v)) } }),
                          format: .number.grouping(.never))
            }
            if d.replyPort != nil {
                TextField("Answers on UDP port", value: Binding(
                    get: { Int(own.replyPort(d)) },
                    set: { v in editHost(info) { $0.replyPort = UInt16(clamping: max(1, v)) } }),
                          format: .number.grouping(.never))
            }
            if d.midiChannel != nil {
                Text("MIDI port “\(model.settings.midiPortName)”\(model.status.midiReady ? "" : " could not be made")")
                Stepper("Channel \(own.midiChannel(d))", value: Binding(
                    get: { own.midiChannel(d) },
                    set: { v in editHost(info) { $0.midiChannel = v } }), in: 1...16)
            }
            if !model.status.racks.isEmpty {
                Text(model.status.racks.map(\.label).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Resync") { model.bridge.resync() }
                Button(NavCommand.previousRack.title) { model.bridge.send(.previousRack) }
                Button(NavCommand.nextRack.title) { model.bridge.send(.nextRack) }
            }
            .controlSize(.small)
        }
        if d.typedRacks {
            Section("Racks") {
                TextEditor(text: Binding(
                    get: { own.racks.joined(separator: "\n") },
                    set: { v in editHost(info) { $0.racks = v.components(separatedBy: "\n") } }))
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                Text("One per line, in \(info.product)'s order: \(info.product) can't say what it has, so Remora matches channel names against these. Rack 1 is the first line.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if info.capabilities.contains(.showChangesSound) {
            Section("Showing a rack changes the sound") {
                Toggle("I understand: showing a rack in \(info.product) loads it", isOn: Binding(
                    get: { own.showChangesSoundAccepted },
                    set: { v in editHost(info) { $0.showChangesSoundAccepted = v } }))
                Text("\(info.product) has no way to show a rack without switching to it, so every move Remora makes changes what is heard, as pressing it in \(info.product) would. Remora sends \(info.product) nothing until this is ticked.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        if !d.setUp.isEmpty {
            Section("Set up \(info.product) once") {
                Text(d.setUp).font(.caption).textSelection(.enabled)
            }
        }
    }

    private func editHost(_ info: ModuleInfo, _ change: @escaping (inout HostSettings) -> Void) {
        model.edit { $0.editHost(info.id, change) }
    }

    private func applyAddress(_ info: ModuleInfo) {
        let a = address.trimmingCharacters(in: .whitespaces)
        editHost(info) { $0.address = a }
    }

    private var otherLinkFailed: Bool {
        if case .failed? = model.status.hostLink { return true } else { return false }
    }

    private func otherLinkLine(_ info: ModuleInfo) -> String {
        let d = info.hostDefaults
        let own = model.settings.host(info.id)
        if model.status.hostGated {
            return "Nothing goes to \(info.product) until you tick below that showing a rack loads it."
        }
        let at = model.status.position.flatMap { p in model.status.racks.first { $0.index == p } }
        let on = at.map { " On \($0.label)." } ?? ""
        switch model.status.hostLink {
        case .connected(let name, let peer)?: return "Connected: \(name) at \(peer).\(on)"
        case .connecting(let peer)?: return "Asking \(info.product) at \(peer)…"
        case .failed(let why)?: return "Not connected: \(why)."
        case .listening?, nil:
            if d.port != nil {
                return "Sending to \(own.host), UDP \(String(own.port(d))). \(info.product) sends nothing back, so check that it moves.\(on)"
            }
            if d.midiChannel != nil {
                return "Sending on Remora's MIDI port, channel \(own.midiChannel(d)). \(info.product) sends nothing back, so check that it moves.\(on)"
            }
            return "Starting."
        }
    }

    // MARK: Both

    /// Two rows: six buttons in one ran off the window.
    private var navButtons: some View {
        ForEach([Array(NavCommand.allCases.prefix(4)), Array(NavCommand.allCases.dropFirst(4))], id: \.self) { row in
            HStack {
                ForEach(row, id: \.self) { c in
                    Button(c.title) { model.bridge.send(c) }
                }
            }
            .controlSize(.small)
        }
    }

    private var windowSection: some View {
        Section("Third-party plug-in windows") {
            Toggle("Close them when the rack, page or plug-in changes", isOn: Binding(
                get: { model.settings.closePluginWindows },
                set: { v in model.edit { $0.closePluginWindows = v } }))
            Toggle("Place them over the rack page's plug-in area", isOn: Binding(
                get: { model.settings.placePluginWindows },
                set: { v in model.edit { $0.placePluginWindows = v } }))
            if isMIDI {
                Toggle("Show the new rack's plug-in after a rack change", isOn: Binding(
                    get: { model.settings.reopenPluginAfterRackChange },
                    set: { v in model.edit { $0.reopenPluginAfterRackChange = v } }))
            }
            Toggle("Hide SuperRack while another app is in front", isOn: Binding(
                get: { model.settings.hidePluginWindowsInBackground },
                set: { v in model.edit { $0.hidePluginWindowsInBackground = v } }))
            Text("SuperRack opens non-Waves plug-ins in floating windows and leaves them open on another rack, a Waves plug-in or the overview. Remora closes those, as a docked plug-in would go. A window with SuperRack's pin set is left alone. Placing moves each window over the plug-in area as it opens; SuperRack will not resize them, so a wide one covers the output column.\(isMIDI ? " After a rack change on the Rack page SuperRack shows nothing for a non-Waves plug-in; showing it flicks SuperRack to the overview and back (Remora's Back to overview and Open rack page), only when that rack's selected plug-in is a non-Waves one." : "") The windows float over every other app, even with SuperRack behind. Hiding hides SuperRack itself, as ⌘H does, when you switch to another app with one of them open; its audio carries on. Switch back to SuperRack to show it again; it also comes back by itself whenever it takes one of Remora's commands.")
                .font(.caption).foregroundStyle(.secondary)
            if model.settings.pluginWindowOptions.windows || (isMIDI && model.settings.pluginWindowOptions.any) {
                Text(pluginWindowsLine).font(.caption)
                if !model.status.pluginWindows.trusted {
                    Button("Open Accessibility Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }
    }

    private var rackReadingLine: String {
        let st = model.status.pluginWindows
        guard model.settings.readRackFromWindow else { return "Off: counting only." }
        if st.readsRack { return "Reading it now." }
        guard st.trusted else { return "Remora has no Accessibility grant, so it counts." }
        guard st.attached else { return "\(edition.appName) is not running." }
        return "SuperRack's rack name cannot be seen (its window may be hidden or on another Space), so Remora counts."
    }

    private var pluginWindowsLine: String {
        let st = model.status.pluginWindows
        guard st.trusted else {
            return "Remora needs Accessibility: System Settings › Privacy & Security › Accessibility, then tick Remora."
        }
        guard st.attached else { return "Waiting for \(edition.appName) to start." }
        var s = "Watching SuperRack"
        if !st.logOpen { s += " (its log is not readable, so a Waves plug-in or a page change will not close windows)" }
        s += ". "
        if let a = st.lastAction { s += "Last: \(a)." }
        return s
    }
}

private struct ChannelsTab: View {
    @ObservedObject var model: Model
    @State private var editingRouting = false

    private var channels: [ConsoleChannel] {
        model.bridge.names.keys.sorted()
    }

    private var routingOn: Bool { model.settings.routingSettings.enabled }

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline) {
                Text(routingOn
                     ? "Racks are found by routing, then by name. Pick a rack to override."
                     : "Racks are matched by name (“head1” finds “head 1”, “lec 2” finds “Lec”). Pick a rack to override.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Routing…") { editingRouting = true }
                    .help("Find racks by how the audio is patched (experimental)")
            }
            .sheet(isPresented: $editingRouting) { RoutingSheet(model: model) }
            if channels.isEmpty {
                Spacer()
                Text("No channel names yet: connect to the console.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(channels, id: \.self) { ch in
                    HStack {
                        Text(ch.description).frame(width: 90, alignment: .leading)
                        Text(model.bridge.names[ch] ?? "").frame(width: 110, alignment: .leading)
                        if routingOn { routingCell(ch) }
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
        if routingOn, case .rack(let i, _)? = model.bridge.mapping(for: ch).routing,
           let r = model.status.racks.first(where: { $0.index == i }) {
            return "By routing: \(r.label)"
        }
        return "By name: \(model.bridge.automaticRack(for: ch).map(\.label) ?? "none")"
    }

    /// What routing says, with the path or the reason on hover, and a warning where routing and
    /// the name pick different racks.
    @ViewBuilder private func routingCell(_ ch: ConsoleChannel) -> some View {
        let m = model.bridge.mapping(for: ch)
        let answer = m.routing ?? RoutingAnswer.none
        HStack(spacing: 4) {
            Text(answer.text(racks: model.status.racks)).font(.caption)
            if m.disagrees {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Routing finds one rack, the name \(m.byName?.label ?? "another")")
            }
        }
        .frame(width: 150, alignment: .leading)
        .help(routingHelp(answer))
    }

    private func routingHelp(_ a: RoutingAnswer) -> String {
        switch a {
        case .rack(_, let path): return MappingSource.describe(path)
        case .none:
            return model.bridge.routes.isEmpty
                ? "The desk hasn't reported its patch, and no declared link reaches a rack's input"
                : "No link reaches a rack's input"
        case .several(let r):
            let names = r.compactMap { i in model.status.racks.first { $0.index == i }?.label }
            return "Several racks: \(names.joined(separator: ", ")). The name decides."
        }
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
