import AppKit
import RemoraCore
import RemoraEngine
import SwiftUI
import UniformTypeIdentifiers

/// Routing's settings (docs/ARCHITECTURE.md §4.1): on or off, the imported Dante preset, which of
/// its devices are the desk and the host, and the runs the user declares.
struct RoutingSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var importError: String?
    @State private var showUnresolved = false

    private var routing: RoutingSettings { model.settings.routingSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Routing").font(.headline)
            Toggle("Find each channel's rack by routing, then by name (experimental)", isOn: bind(\.enabled))
            Text("Remora follows a channel's audio from its input patch on the desk to a rack's input on the host, through the Dante subscriptions and the runs below. One rack reached wins over the name; an override still wins over both. Remora only reads: it never changes a patch or a subscription. The desk's patch is read from a CL or QL, and the racks' inputs from SuperRack.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            GroupBox("Dante") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Import Dante Controller Preset…", action: importPreset)
                        if routing.dante != nil {
                            Button("Forget It") { model.edit { $0.routingSettings.dante = nil } }
                        }
                        Spacer()
                    }
                    if let e = importError { Text(e).font(.caption).foregroundStyle(.red) }
                    if let p = routing.dante {
                        Text(summary(p)).font(.caption)
                        if !p.unresolved.isEmpty {
                            DisclosureGroup("\(p.unresolved.count) subscriptions name a channel the preset doesn't have",
                                            isExpanded: $showUnresolved) {
                                ScrollView {
                                    Text(p.unresolved.joined(separator: "\n")).font(.caption.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                }.frame(maxHeight: 80)
                            }.font(.caption)
                        }
                        devicePicker("The desk is", \.deskDante, p.devices)
                        devicePicker("The host's inputs are", \.hostDante, p.devices,
                                     help: "The Dante device whose receive channel N is the host's input N, such as Dante Virtual Soundcard on the host's computer.")
                    } else {
                        Text("In Dante Controller, File › Save Preset saves every device's subscriptions. Import it again after a change: Remora doesn't read Dante live.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(4)
            }

            GroupBox("Other links, one run per line") {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: runsText)
                        .font(.body.monospaced())
                        .frame(minHeight: 70, maxHeight: 110)
                    Text("desk channel out 1-32 > desk dante out 1   (direct outs on Dante 1–32)\nMADI card madi in 1-64 > host in 1   (a MADI interface is the host's inputs)\nA device's name, an optional domain (dante, madi, usb, aes50, adat, analog), in or out, a channel or range. “desk” is the console, “host” the plug-in host's inputs.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(routing.runErrors.enumerated()), id: \.offset) { _, e in
                        Text("“\(e.line)”: \(e.why)").font(.caption).foregroundStyle(.red)
                    }
                }.padding(4)
            }

            HStack {
                Text("\(model.bridge.graph.linkCount) links").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560)
    }

    private func bind(_ key: WritableKeyPath<RoutingSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings.routingSettings[keyPath: key] },
                set: { v in model.edit { $0.routingSettings[keyPath: key] = v } })
    }

    private var runsText: Binding<String> {
        Binding(get: { model.settings.routingSettings.runs.joined(separator: "\n") },
                set: { text in
                    var lines = text.components(separatedBy: "\n")
                    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
                    model.edit { $0.routingSettings.runs = lines }
                })
    }

    private func devicePicker(_ title: String, _ key: WritableKeyPath<RoutingSettings, String>, _ devices: [String],
                              help: String? = nil) -> some View {
        let current = model.settings.routingSettings[keyPath: key]
        return Picker(title, selection: Binding(get: { current },
                                                set: { v in model.edit { $0.routingSettings[keyPath: key] = v } })) {
            Text("None").tag("")
            if !current.isEmpty && !devices.contains(current) { Text("\(current) (not in this preset)").tag(current) }
            ForEach(devices, id: \.self) { Text($0).tag($0) }
        }
        .help(help ?? "")
    }

    private func summary(_ p: DantePreset) -> String {
        let name = p.name.isEmpty ? "A preset" : "“\(p.name)”"
        return "\(name): \(p.devices.count) devices, \(p.links.count) subscriptions."
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.title = "Import Dante Controller Preset"
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let p = try DantePreset.read(contentsOf: url)
            importError = nil
            model.edit { s in
                s.routingSettings.dante = p
                // Names the new preset no longer has are kept, and shown as missing.
            }
            Log.line("Routing: imported \(url.lastPathComponent): \(p.devices.count) devices, \(p.links.count) subscriptions, \(p.unresolved.count) unresolved")
        } catch {
            importError = "\(url.lastPathComponent): \(error)"
        }
    }
}

extension RoutingAnswer {
    /// For the Channels tab: what routing found, in a few words.
    func text(racks: [Rack]) -> String {
        switch self {
        case .rack(let i, _): return "Routing: \(racks.first { $0.index == i }?.label ?? "rack \(i + 1)")"
        case .none: return "Routing: none"
        case .several(let r): return "Routing: \(r.count) racks"
        }
    }
}
