import Foundation
import RemoraConsoles
import RemoraCore
import RemoraEngine
import RemoraHosts

/// The command line every system shares. The Mac app's main.swift and Windows' Remora.exe both
/// run these, then their own: the menu-bar app, --plugin-windows and --screenshots on macOS.
public struct CLI {
    public let args: [String]
    public let version: String

    public init(_ args: [String] = CommandLine.arguments, version: String) {
        self.args = args
        self.version = version
    }

    public func has(_ flag: String) -> Bool { args.contains(flag) }

    public func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    public func fail(_ why: String, _ code: Int32) -> Never {
        FileHandle.standardError.write("Remora: \(why)\n".data(using: .utf8)!)
        exit(code)
    }

    // MARK: --help

    /// The first line of --help.
    public var helpTitle: String {
        "Remora \(version): SuperRack Performer follows the console's selected channel."
    }

    /// --help's lines for the read-only commands, in the order the Mac app has always listed them.
    public static let readCommandsHelp = """
      Remora --racks [PATH]        the racks in SuperRack's current session
      Remora --mapping             SuperRack's MIDI mapping for the saved settings (.mrrc)
      Remora --probe HOST [SECS] [--console KIND] [--midi-channel N] [--all]
                                   watch a desk's selection and names (read-only, no MIDI);
                                   KIND: \(ModuleRegistry.standard.consoles.map(\.info.id).joined(separator: ", "))
                                   (or 0.3's \(ConsoleKind.allCases.map(\.rawValue).joined(separator: ", ")));
                                   N: an Allen & Heath desk's MIDI channel (1 unless given)
      Remora --auto-build HOST [SECS] --console KIND [--midi-channel N] [--choices FILE]
             [--templates NAME,NAME… | --template-session PATH] [--out DIR]
                                   read a desk's channels (read-only, as --probe; not the settings
                                   file, not SuperRack) and plan a SuperRack session for them: a
                                   rack each, inputs, outputs, templates. Writes plan.json,
                                   patch-sheet.csv and patch-sheet.txt to DIR (here unless given).
                                   FILE: auto build's settings as JSON; no include list means
                                   every channel. It writes no SuperRack session (not built yet)
      Remora --settings            where the settings file is; writes the defaults there first if
                                   there is none, to edit by hand
    """

    // MARK: The read-only commands

    /// --racks, --mapping, --settings, --probe and --auto-build, whichever the arguments name. Each
    /// exits; with none named, this returns.
    public func runReadCommands() {
        if has("--racks") { racks() }
        if has("--mapping") { mapping() }
        if has("--settings") { settingsFile() }
        if let host = value(after: "--probe") { probe(host) }
        if let host = value(after: "--auto-build") { autoBuild(host) }
    }

    func racks() -> Never {
        let path = value(after: "--racks").flatMap { $0.hasPrefix("--") ? nil : $0 } ?? Settings.load().sessionPath
        do {
            for r in try SuperRackSession.racks(at: path) { print(r.label) }
            exit(0)
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    func mapping() -> Never {
        let s = Settings.load()
        print(SuperRackMapping.mrrc(channel: s.midiChannel, ccBase: s.ccBase), terminator: "")
        exit(0)
    }

    func settingsFile() -> Never {
        let url = Settings.fileURL
        if !FileManager.default.fileExists(atPath: url.path) { Settings.load().save(to: url) }
        print(url.path)
        exit(FileManager.default.fileExists(atPath: url.path) ? 0 : 1)
    }

    func probe(_ host: String) -> Never {
        let secs = value(after: host).flatMap(Double.init) ?? 30
        let saved = Settings.load()
        let registry = ModuleRegistry.standard
        guard let entry = value(after: "--console").flatMap(registry.console) ?? registry.console(saved.console) else {
            FileHandle.standardError.write("Remora: \(saved.console) is not in this version; pass --console KIND\n".data(using: .utf8)!)
            exit(1)
        }
        let racks = (try? SuperRackSession.racks(at: saved.sessionPath)) ?? []
        var names: [ConsoleChannel: String] = [:]
        var probe = saved
        probe.consoleHost = host
        probe.consoleMIDIChannel = value(after: "--midi-channel").flatMap(Int.init).map { min(max($0, 1), 16) } ?? 1
        let console = entry.make(ModuleContext(settings: probe, platform: Bridge.defaultPlatform()))
        Log.line("probing \(entry.info.title) at \(host)\(entry.info.experimental ? " (experimental)" : "")")
        let all = has("--all")
        console.onEvent = { e in
            switch e {
            case .link(let st): Log.line("console: \(st)")
            case .namesLink(let up): Log.line("names link: \(up ? "up" : "down")")
            case .selected(let ch):
                DispatchQueue.main.async {
                    let name = names[ch] ?? "?"
                    let rack = RackMatcher.match(name, in: racks)
                    Log.line("selected \(ch) \"\(name)\" → \(rack.map { "rack \($0.label)" } ?? "no rack")")
                }
            case .control(let src, let v):
                if all { Log.line("change \(src) = \(v)") }
            case .model(let m): Log.line("model: \(m)")
            case .names(let n):
                DispatchQueue.main.async {
                    names = n
                    Log.line("names: \(n.count) channels")
                    if all {
                        for (ch, name) in n.sorted(by: { $0.key < $1.key }) { Log.line("name \(ch): \"\(name)\"") }
                    }
                }
            case .routes(let r):
                Log.line("patches: \(r.count) channels")
                if all {
                    for (ch, ports) in r.sorted(by: { $0.key < $1.key }) {
                        Log.line("patch \(ch): \(ports.map(\.description).joined(separator: ", "))")
                    }
                }
            }
        }
        console.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
        RunLoop.main.run()
        exit(0)
    }

    func autoBuild(_ host: String) -> Never {
        // The desk as --probe reads it, but from default settings: neither the settings file nor
        // SuperRack's session is read, so it runs beside the app on a Mac in a show. It writes only
        // into --out.
        let secs = value(after: host).flatMap(Double.init) ?? 10
        let registry = ModuleRegistry.standard
        guard let entry = value(after: "--console").flatMap(registry.console) else {
            fail("pass --console KIND (\(registry.consoles.map(\.info.id).joined(separator: ", ")))", 2)
        }
        var s = Settings()
        s.console = entry.info.id
        s.consoleHost = host
        s.consoleMIDIChannel = value(after: "--midi-channel").flatMap(Int.init).map { min(max($0, 1), 16) } ?? 1
        var choices = AutoBuildSettings()
        if let f = value(after: "--choices") {
            guard let data = FileManager.default.contents(atPath: f),
                  let c = try? JSONDecoder().decode(AutoBuildSettings.self, from: data) else { fail("can't read \(f)", 2) }
            choices = c
        }
        var templates: [BuildTemplate] = []
        if let path = value(after: "--template-session") {
            do { templates = choices.templates(try SuperRackSession.templates(at: path)) } catch { fail("\(error)", 2) }
        }
        if let list = value(after: "--templates") {
            templates += choices.templates(list.split(separator: ",").map {
                (name: $0.trimmingCharacters(in: .whitespaces), plugins: [String]())
            }.filter { !$0.name.isEmpty })
        }
        let out = URL(fileURLWithPath: value(after: "--out") ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        if AutoBuild.isWavesFolder(out.path) { fail("\(out.path) is Waves' folder: auto build writes nothing there", 2) }

        let console = entry.make(ModuleContext(settings: s, platform: Bridge.defaultPlatform()))
        var names: [ConsoleChannel: String] = [:]
        var model: String?
        var settle: DispatchWorkItem?
        func finish() {
            console.stop()
            guard !names.isEmpty else { fail("\(entry.info.title) at \(host) gave no channel names in \(Int(secs)) s", 1) }
            let strips = AutoBuild.strips(from: names)
            if choices.include.isEmpty { choices.include = strips.map(\.channel.key) }
            let plan = AutoBuild.plan(strips: strips, settings: choices, templates: templates)
            let desk = entry.info.title + (model.map { " (\($0))" } ?? "")
            let text = AutoBuild.patchSheetText(plan, desk: desk, date: Date())
            do {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try AutoBuild.json(plan, desk: desk).write(to: out.appendingPathComponent("plan.json"))
                try Data(AutoBuild.patchSheetCSV(plan).utf8).write(to: out.appendingPathComponent("patch-sheet.csv"))
                try Data(text.utf8).write(to: out.appendingPathComponent("patch-sheet.txt"))
            } catch { fail("can't write to \(out.path): \(error)", 1) }
            print(text, terminator: "")
            Log.line("auto build: \(plan.racks.count) racks, \(plan.problems.count) problems; wrote plan.json, patch-sheet.csv and patch-sheet.txt to \(out.path)")
            exit(plan.racks.isEmpty ? 1 : 0)
        }
        Log.line("auto build: reading \(entry.info.title) at \(host)\(entry.info.experimental ? " (experimental)" : "")")
        console.onEvent = { e in
            DispatchQueue.main.async {
                switch e {
                case .link(let st): Log.line("console: \(st)")
                case .model(let m):
                    model = m
                    Log.line("model: \(m)")
                case .names(let n):
                    names = n
                    Log.line("names: \(n.count) channels")
                    // Names come in one go, or the first few and then the rest: wait for them to stop.
                    settle?.cancel()
                    let w = DispatchWorkItem { finish() }
                    settle = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
                default: break
                }
            }
        }
        console.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { finish() }
        RunLoop.main.run()
        exit(0)
    }

    // MARK: --headless

    /// The bridge without a UI, logging to stdout, until killed or `--for SECS` is up. `--host`
    /// overrides the desk's address, `--dry-run` logs the MIDI instead of making a port, and
    /// `--through-app [PORT]` hands it to the running app (macOS only: `throughApp` makes its sink,
    /// and is nil where there is no app).
    public func headless(throughApp: ((UInt16) -> CCSink)? = nil) -> Never {
        var s = Settings.load()
        if let h = value(after: "--host") { s.consoleHost = h }
        let sink: CCSink?
        if has("--through-app") {
            guard let throughApp else { fail("--through-app needs the menu-bar app, which only macOS has", 2) }
            let port = value(after: "--through-app").flatMap(UInt16.init) ?? s.oscPort
            sink = throughApp(port)
            // The app has its OSC port (a test copy may listen on another), and its own guard for
            // SuperRack's plug-in windows: two guards would both press Close.
            if s.oscPort == port { s.oscEnabled = false }
            s.closePluginWindows = false
            s.placePluginWindows = false
            s.reopenPluginAfterRackChange = false
        } else {
            sink = has("--dry-run") ? LogSink() : nil
        }
        // A dry run moves nothing, so its guard would act on SuperRack beside the running app's.
        if has("--dry-run") {
            s.closePluginWindows = false
            s.placePluginWindows = false
            s.reopenPluginAfterRackChange = false
        }
        let bridge = sink.map { Bridge(settings: s, sink: $0) } ?? Bridge(settings: s)
        bridge.start()
        if let secs = value(after: "--for").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
        }
        withExtendedLifetime(bridge) { RunLoop.main.run() }
        exit(0)
    }
}

/// For --dry-run: logs what would go to SuperRack instead of making a MIDI port.
public final class LogSink: CCSink {
    public init() {}
    public func sendCC(channel: Int, number: Int, value: Int) {
        Log.line("MIDI (dry run): ch \(channel) CC \(number) = \(value)")
    }
    public func sendProgramChange(channel: Int, program: Int) {
        Log.line("MIDI (dry run): ch \(channel) Program Change \(program)")
    }
}
