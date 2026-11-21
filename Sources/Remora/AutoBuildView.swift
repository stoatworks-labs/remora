import AppKit
import RemoraCore
import RemoraEngine
import RemoraHosts
import SwiftUI
import UniformTypeIdentifiers

/// Auto build (docs/ARCHITECTURE.md §12, stage A): which of the desk's channels and buses get a
/// rack, the template rack each starts from, and where their audio goes. It plans and saves a
/// patch sheet. It changes nothing: not the desk, not Dante, not SuperRack.
struct AutoBuildSheet: View {
    typealias TemplateRack = (name: String, plugins: [String])

    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    /// The template session's racks: read from its file, unless given (the screenshots give them).
    @State private var templateRacks: [TemplateRack]
    @State private var templateError: String?
    @State private var saveNote: String?
    @State private var showWords = false
    private let givenTemplates: Bool

    /// Stands for "the template the name picks" in a row's picker; never a template's name.
    private static let byName = "\u{1}byName"

    init(model: Model, templateRacks: [TemplateRack]? = nil) {
        self.model = model
        _templateRacks = State(initialValue: templateRacks ?? [])
        givenTemplates = templateRacks != nil
    }

    private var settings: AutoBuildSettings { model.settings.autoBuildSettings }
    private var options: BuildOptions { settings.options }
    private var strips: [BuildStrip] { AutoBuild.strips(from: model.bridge.names) }
    private var templates: [BuildTemplate] { settings.templates(templateRacks) }
    private var plan: BuildPlan { AutoBuild.plan(strips: strips, settings: settings, templates: templates) }

    var body: some View {
        let plan = self.plan
        VStack(alignment: .leading, spacing: 10) {
            Text("Auto Build (experimental)").font(.headline)
            Text("Pick the desk's channels and buses to give a rack each, and the template rack each one starts from. Remora plans the racks, their SuperRack inputs and outputs and the desk's ports, and saves a patch sheet. It changes nothing: not the desk, not Dante, not SuperRack. Writing the SuperRack session comes later, once SuperRack's session format has been captured.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            GroupBox("Templates") { templatesBox.padding(4) }
            GroupBox("Where the audio goes") { routingBox.padding(4) }

            HStack {
                Text("\(plan.racks.count) of \(strips.count) channels picked").font(.caption)
                Spacer()
                Button("Pick All") { model.edit { $0.autoBuildSettings.include = strips.map(\.channel.key) } }
                    .disabled(strips.isEmpty)
                Button("Pick None") { model.edit { $0.autoBuildSettings.include = [] } }
                    .disabled(settings.include.isEmpty)
            }
            if strips.isEmpty {
                Spacer()
                Text("No channel names yet: connect to the console. Unnamed channels aren't listed yet.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(strips, id: \.self) { s in row(s, plan: plan) }
            }
            ForEach(plan.problems, id: \.self) { p in
                Text(p).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(summary(plan)).font(.caption).foregroundStyle(.secondary)
                if let n = saveNote { Text(n).font(.caption) }
                Spacer()
                Button("Save Patch Sheet…") { save(plan) }.disabled(plan.racks.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 800, height: 700)
        .onAppear(perform: loadTemplates)
    }

    // MARK: Templates

    @ViewBuilder private var templatesBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Choose Template Session…", action: chooseSession)
                if !settings.templateSession.isEmpty {
                    Button("Forget It") {
                        model.edit { $0.autoBuildSettings.templateSession = "" }
                        templateRacks = []
                        templateError = nil
                    }
                }
                Spacer()
            }
            Text(templateSummary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = templateError { Text(e).font(.caption).foregroundStyle(.red) }
            if !templateRacks.isEmpty {
                DisclosureGroup("Words that pick each template", isExpanded: $showWords) {
                    ForEach(templateRacks.indices, id: \.self) { i in
                        let t = templateRacks[i]
                        HStack {
                            Text(t.name).frame(width: 120, alignment: .leading)
                            TextField("more words, such as vox, bv, mc", text: words(t.name))
                        }
                    }
                }.font(.caption)
            }
        }
    }

    private var templateSummary: String {
        let file = (settings.templateSession as NSString).lastPathComponent
        if templateRacks.isEmpty {
            return settings.templateSession.isEmpty
                ? "No template session, so each rack would start empty. In SuperRack, save a session whose racks are your channel strips (a rack called “Vocal” with its plug-ins, one called “Kick”…), then choose it here. Remora reads a copy of it, never the file itself."
                : "“\(file)” has no racks with plug-ins in them."
        }
        let names = templateRacks.map(\.name).joined(separator: ", ")
        return "\(givenTemplates || file.isEmpty ? "" : "“\(file)”: ")\(templateRacks.count) templates: \(names). A channel gets the first whose name's words it has, unless you pick one."
    }

    private func loadTemplates() {
        guard !givenTemplates, !settings.templateSession.isEmpty else { return }
        read(settings.templateSession)
    }

    private func read(_ path: String) {
        do {
            templateRacks = try SuperRackSession.templates(at: path)
            templateError = nil
        } catch {
            templateRacks = []
            templateError = "\((path as NSString).lastPathComponent): \(error)"
        }
    }

    private func chooseSession() {
        let panel = NSOpenPanel()
        panel.title = "Choose a SuperRack Session of Templates"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        read(url.path)
        if templateError == nil {
            model.edit { $0.autoBuildSettings.templateSession = url.path }
            Log.line("Auto build: \(templateRacks.count) templates from \(url.lastPathComponent)")
        }
    }

    private func words(_ template: String) -> Binding<String> {
        Binding(get: { (settings.words[template] ?? []).joined(separator: ", ") },
                set: { text in
                    let w = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                        .map { $0.lowercased() }.filter { !$0.isEmpty }
                    model.edit { $0.autoBuildSettings.words[template] = w.isEmpty ? nil : w }
                })
    }

    // MARK: Where the audio goes

    @ViewBuilder private var routingBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Picker("Feed", selection: option(\.feed)) {
                    Text("Insert").tag(BuildFeed.insert)
                    Text("Direct out").tag(BuildFeed.directOut)
                }
                .frame(width: 180)
                Picker("Desk ports", selection: option(\.deskDomain)) {
                    ForEach([AudioPort.Domain.dante, .madi, .usb, .aes50, .adat, .analog, .other], id: \.self) {
                        Text($0 == .other ? "other" : $0.rawValue).tag($0)
                    }
                }
                .frame(width: 180)
                Stepper("from \(options.deskFirstPort)", value: option(\.deskFirstPort), in: 1...1024)
            }
            HStack(spacing: 16) {
                Stepper("SuperRack inputs from \(options.firstInput)", value: option(\.firstInput), in: 1...1024)
                Stepper("outputs from \(options.firstOutput)", value: option(\.firstOutput), in: 1...1024)
            }
            Text(options.feed == .insert
                 ? "Each channel's insert sends on the desk's next port to the rack's input, and returns from the rack's output on the same port number."
                 : "Each channel's direct out goes on the desk's next port to the rack's input; the rack's output comes back on the same port number, to a spare input.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option<T>(_ key: WritableKeyPath<BuildOptions, T>) -> Binding<T> {
        Binding(get: { model.settings.autoBuildSettings.options[keyPath: key] },
                set: { v in model.edit { $0.autoBuildSettings.options[keyPath: key] = v } })
    }

    // MARK: The channels

    private func row(_ s: BuildStrip, plan: BuildPlan) -> some View {
        let planned = plan.racks.first { $0.channel == s.channel }
        return HStack {
            Toggle("", isOn: included(s)).labelsHidden()
            Text(s.channel.description).frame(width: 90, alignment: .leading)
            Text(s.name).frame(width: 110, alignment: .leading)
            Toggle("Stereo", isOn: stereo(s)).toggleStyle(.checkbox).font(.caption)
            Picker("", selection: template(s)) {
                Text(byNameTitle(s)).tag(Self.byName)
                Text("Empty rack").tag("")
                if let c = settings.template[s.channel.key], !c.isEmpty, !templates.contains(where: { $0.name == c }) {
                    Text("\(c) (not in the session)").tag(c)
                }
                ForEach(templates, id: \.name) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()
            .frame(width: 170)
            if let r = planned {
                // The rack's name only where it isn't the desk's (made unique, or the desk had none).
                let renamed = r.name != r.deskName.trimmingCharacters(in: .whitespaces) ? " “\(r.name)”" : ""
                let desk = r.deskSends.first.map { $0.domain == .other ? "" : "\($0.domain.rawValue) " } ?? ""
                Text("Rack \(r.index + 1)\(renamed) · in \(AutoBuild.range(r.hostInputs)), out \(AutoBuild.range(r.hostOutputs)) · desk \(desk)\(AutoBuild.range(r.deskSends.map(\.channel)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("\(options.feed == .insert ? "Insert send" : "Direct out") on \(AutoBuild.ports(r.deskSends)) → SuperRack in \(AutoBuild.range(r.hostInputs)); SuperRack out \(AutoBuild.range(r.hostOutputs)) → \(AutoBuild.ports(r.deskReturns))")
            }
        }
    }

    private func byNameTitle(_ s: BuildStrip) -> String {
        guard let p = AutoBuild.pick(s.name, in: templates) else { return "By name: empty rack" }
        return "By name: \(p.template.name)"
    }

    private func included(_ s: BuildStrip) -> Binding<Bool> {
        let key = s.channel.key
        return Binding(get: { settings.include.contains(key) },
                       set: { on in
                           model.edit { m in
                               var list = m.autoBuildSettings.include.filter { $0 != key }
                               if on { list.append(key) }
                               m.autoBuildSettings.include = list
                           }
                       })
    }

    private func stereo(_ s: BuildStrip) -> Binding<Bool> {
        let key = s.channel.key
        return Binding(get: { settings.stereo[key] ?? s.stereo },
                       set: { v in model.edit { $0.autoBuildSettings.stereo[key] = v == s.stereo ? nil : v } })
    }

    private func template(_ s: BuildStrip) -> Binding<String> {
        let key = s.channel.key
        return Binding(get: { settings.template[key] ?? Self.byName },
                       set: { v in model.edit { $0.autoBuildSettings.template[key] = v == Self.byName ? nil : v } })
    }

    // MARK: The patch sheet

    private var deskTitle: String {
        let title = model.bridge.registry.console(model.settings.console)?.info.title ?? model.settings.console
        return title + (model.status.model.map { " (\($0))" } ?? "")
    }

    private func summary(_ plan: BuildPlan) -> String {
        guard let first = plan.racks.first, let last = plan.racks.last else { return "No racks yet." }
        let ins = (first.hostInputs.first ?? 0, last.hostInputs.last ?? 0)
        let outs = (first.hostOutputs.first ?? 0, last.hostOutputs.last ?? 0)
        let templated = plan.racks.filter { $0.template != nil }.count
        return "\(plan.racks.count) racks, \(templated) from templates; SuperRack in \(ins.0)–\(ins.1), out \(outs.0)–\(outs.1)."
    }

    private func save(_ plan: BuildPlan) {
        let panel = NSSavePanel()
        panel.title = "Save Patch Sheet"
        panel.nameFieldStringValue = "Patch sheet.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Saves the sheet as CSV, and as text beside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if AutoBuild.isWavesFolder(url.deletingLastPathComponent().path) {
            saveNote = "Not saved: that is Waves' folder, where SuperRack keeps its sessions."
            return
        }
        let text = url.deletingPathExtension().appendingPathExtension("txt")
        do {
            try Data(AutoBuild.patchSheetCSV(plan).utf8).write(to: url, options: .atomic)
            try Data(AutoBuild.patchSheetText(plan, desk: deskTitle, date: Date()).utf8).write(to: text, options: .atomic)
            saveNote = "Saved \(url.lastPathComponent) and \(text.lastPathComponent)."
            Log.line("Auto build: saved a patch sheet of \(plan.racks.count) racks to \(url.path)")
        } catch {
            saveNote = "Not saved: \(error.localizedDescription)"
        }
    }
}
