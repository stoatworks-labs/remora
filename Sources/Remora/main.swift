import AppKit
import RemoraApple
import RemoraConsoles
import RemoraCore
import RemoraEngine
import RemoraHosts

let args = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--version") {
    print(appVersion)
    exit(0)
}

if args.contains("--help") {
    print("""
    Remora \(appVersion): SuperRack Performer follows the console's selected channel.

      Remora                       the menu-bar app
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
      Remora --headless [--host HOST] [--for SECS] [--dry-run | --through-app [PORT]]
                                   run the bridge without the menu bar, logging to stdout;
                                   --dry-run logs the MIDI instead of making a port;
                                   --through-app sends it as /remora/cc to the running Remora's
                                   OSC (UDP 9020), for testing beside the app
      Remora --screenshots DIR     the settings window's tabs as PNGs, drawn off screen from
                                   demo data (no desk, no SuperRack, no window, no settings file)
      Remora --film DIR            the same, as a still per beat of the video, with beats.json
      Remora --plugin-windows [--place] [--reopen] [--hide] [--watch] [--for SECS]
                                   only the SuperRack plug-in window guard: close third-party
                                   windows on a rack, page or plug-in change; --place moves them
                                   over the rack page; --reopen shows the new rack's plug-in
                                   after a move, through the running app's OSC; --hide hides
                                   SuperRack (as ⌘H) while another app is in front; --watch closes nothing. No MIDI port and no OSC listener, so it runs beside
                                   the app.
    """)
    exit(0)
}

if args.contains("--racks") {
    let path = value(after: "--racks").flatMap { $0.hasPrefix("--") ? nil : $0 } ?? Settings.load().sessionPath
    do {
        for r in try SuperRackSession.racks(at: path) { print(r.label) }
        exit(0)
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

if args.contains("--mapping") {
    let s = Settings.load()
    print(SuperRackMapping.mrrc(channel: s.midiChannel, ccBase: s.ccBase), terminator: "")
    exit(0)
}

if let host = value(after: "--probe") {
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
            if args.contains("--all") { Log.line("change \(src) = \(v)") }
        case .model(let m): Log.line("model: \(m)")
        case .names(let n):
            DispatchQueue.main.async {
                names = n
                Log.line("names: \(n.count) channels")
                if args.contains("--all") {
                    for (ch, name) in n.sorted(by: { $0.key < $1.key }) { Log.line("name \(ch): \"\(name)\"") }
                }
            }
        case .routes(let r):
            Log.line("patches: \(r.count) channels")
            if args.contains("--all") {
                for (ch, ports) in r.sorted(by: { $0.key < $1.key }) {
                    Log.line("patch \(ch): \(ports.map(\.description).joined(separator: ", "))")
                }
            }
        }
    }
    console.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
    RunLoop.main.run()
}

if let host = value(after: "--auto-build") {
    // The desk as --probe reads it, but from default settings: neither the settings file nor
    // SuperRack's session is read, so it runs beside the app on a Mac in a show. It writes only
    // into --out.
    func fail(_ why: String, _ code: Int32) -> Never {
        FileHandle.standardError.write("Remora: \(why)\n".data(using: .utf8)!)
        exit(code)
    }
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
}

if args.contains("--plugin-windows") {
    let settings = Settings.load()
    let guardian = PluginWindowGuard(edition: settings.superRackEdition)
    var shown = PluginWindowGuard.Status()
    guardian.onStatus = { st in
        if st.trusted != shown.trusted || st.attached != shown.attached || st.logOpen != shown.logOpen {
            Log.line("Plug-in windows: Accessibility \(st.trusted ? "granted" : "NOT granted"), SuperRack \(st.attached ? "found" : "not running"), log \(st.logOpen ? "open" : "not open")")
        }
        shown = st
    }
    let options = PluginWindowGuard.Options(close: !args.contains("--watch"), place: args.contains("--place"),
                                            reopen: args.contains("--reopen"), hide: args.contains("--hide"))
    // No MIDI port here: the bounce goes through the running app's OSC.
    guardian.onReopen = {
        for a in ["/remora/overview", "/remora/rack/open"] {
            sendOSC(OSC.Message(address: a, args: []), port: settings.oscPort)
        }
    }
    func loadChains() {
        if let c = try? SuperRackSession.read(at: settings.sessionPath) { guardian.setChains(c.chains) }
    }
    loadChains()
    let chainsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in loadChains() }
    guardian.set(options)
    if !options.any { Log.line("Plug-in windows: --watch alone does nothing; add --place, --reopen or --hide") }
    if let secs = value(after: "--for").flatMap(Double.init) {
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
    }
    withExtendedLifetime((guardian, chainsTimer)) { RunLoop.main.run() }
}

/// One OSC message to this Mac.
func sendOSC(_ m: OSC.Message, port: UInt16) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bytes = OSC.encode(m)
    _ = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

/// For --dry-run: logs what would go to SuperRack instead of making a MIDI port.
final class LogSink: CCSink {
    func sendCC(channel: Int, number: Int, value: Int) {
        Log.line("MIDI (dry run): ch \(channel) CC \(number) = \(value)")
    }
    func sendProgramChange(channel: Int, program: Int) {
        Log.line("MIDI (dry run): ch \(channel) Program Change \(program)")
    }
}

/// For --through-app: SuperRack does not hear a MIDI port made after it started (docs/PROTOCOL.md),
/// so a test copy hands each CC to the running Remora as /remora/cc, which sends it on the port
/// SuperRack hears, on the app's channel.
final class ThroughAppSink: CCSink {
    let port: UInt16
    init(port: UInt16) { self.port = port }
    func sendCC(channel: Int, number: Int, value: Int) {
        sendOSC(.init(address: "/remora/cc", args: [.int(Int32(number)), .int(Int32(value))]), port: port)
        Log.line("MIDI (through the app): CC \(number) = \(value)")
    }
    /// The app's OSC has no Program Change: logged, not sent.
    func sendProgramChange(channel: Int, program: Int) {
        Log.line("MIDI (through the app): Program Change \(program) not sent: the app's OSC carries only CCs")
    }
}

if let dir = value(after: "--screenshots") {
    Log.enabled = false
    exit(Screenshots.render(to: dir))
}

if let dir = value(after: "--film") {
    Log.enabled = false
    exit(Screenshots.film(to: dir))
}

if args.contains("--headless") {
    var s = Settings.load()
    if let h = value(after: "--host") { s.consoleHost = h }
    let sink: CCSink?
    if args.contains("--through-app") {
        let port = value(after: "--through-app").flatMap(UInt16.init) ?? s.oscPort
        sink = ThroughAppSink(port: port)
        // The app has its OSC port (a test copy may listen on another), and its own guard for
        // SuperRack's plug-in windows: two guards would both press Close.
        if s.oscPort == port { s.oscEnabled = false }
        s.closePluginWindows = false
        s.placePluginWindows = false
        s.reopenPluginAfterRackChange = false
    } else {
        sink = args.contains("--dry-run") ? LogSink() : nil
    }
    // A dry run moves nothing, so its guard would act on SuperRack beside the running app's.
    if args.contains("--dry-run") {
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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// The bundle's LSUIElement keeps the app out of the Dock. A bare executable (swift run) has none.
if Bundle.main.object(forInfoDictionaryKey: "LSUIElement") == nil { app.setActivationPolicy(.accessory) }
app.run()
