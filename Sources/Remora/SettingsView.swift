import RemoraCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: Model
    let saveMapping: () -> Void

    var body: some View {
        TabView {
            ConsoleTab(model: model).tabItem { Text("Console") }
            SuperRackTab(model: model, saveMapping: saveMapping).tabItem { Text("SuperRack") }
            ChannelsTab(model: model).tabItem { Text("Channels") }
            ControlsTab(model: model).tabItem { Text("Controls") }
            CompanionTab(model: model).tabItem { Text("Companion") }
            LogTab().tabItem { Text("Log") }
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
                HStack {
                    TextField("Console address", text: $host, prompt: Text("192.168.1.100"))
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                }
                Text(statusText).foregroundStyle(.secondary)
                Text("Yamaha CL and QL. Remora reads the desk and never changes it: the editor port (TCP 50000) for the selected channel, RCP (TCP 49280) for channel names.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
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
                Picker("Moving", selection: Binding(
                    get: { model.settings.mode },
                    set: { v in model.edit { $0.mode = v } })) {
                    Text("Back to rack 1 first, every time (safe)").tag(SuperRackDriver.Mode.homeEveryTime)
                    Text("Count from the last move (fast)").tag(SuperRackDriver.Mode.countFromLast)
                }
                Text("SuperRack's MIDI can only step to the next or previous rack, and never says where it is, so Remora counts. “Count from the last move” goes wrong if someone clicks a rack in SuperRack, until Resync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Set up SuperRack once") {
                Text("1. Setup › MIDI Controller (gear): tick “\(model.settings.midiPortName)” under MIDI In.\n2. Import the mapping saved below, or MIDI Learn the six navigation commands with the buttons.")
                    .font(.caption)
                HStack {
                    Button("Save Mapping…", action: saveMapping)
                    Button("Resync") { model.bridge.resync() }
                }
                HStack {
                    ForEach(NavCommand.allCases, id: \.self) { c in
                        Button(c.title) { model.bridge.send(c) }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

private struct ChannelsTab: View {
    @ObservedObject var model: Model

    private var channels: [YamahaChannel] {
        YamahaChannel.named.filter { model.bridge.names[$0] != nil }
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

    private func autoTitle(_ ch: YamahaChannel) -> String {
        "By name: \(model.bridge.automaticRack(for: ch).map(\.label) ?? "none")"
    }

    private func override(_ ch: YamahaChannel) -> Binding<Int> {
        Binding(get: { model.settings.overrides[ch.key] ?? -2 },
                set: { v in model.edit { $0.overrides[ch.key] = v == -2 ? nil : v } })
    }
}

private struct ControlsTab: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading) {
            Text("A console key or knob, or any MIDI control, can drive SuperRack. Press Learn, then press or turn it. On a CL/QL a spare channel's ON key and fader work well. For User Keys, plug-in controls and snapshots, choose “Send CC to SuperRack” and MIDI Learn that CC in SuperRack with Send.")
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
                if mapping.action == .sendCC {
                    Picker("", selection: field(\.mode)) {
                        ForEach(ControlMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 90)
                    Stepper("CC \(mapping.cc)", value: field(\.cc), in: 0...127).frame(width: 90)
                }
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
            Stepper("UDP port \(model.settings.oscPort)", value: Binding(
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
