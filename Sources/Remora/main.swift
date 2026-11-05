import AppKit
import RemoraCore

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
      Remora --probe HOST [SECS] [--console KIND] [--all]
                                   watch a desk's selection and names (read-only, no MIDI);
                                   KIND: \(ConsoleKind.allCases.map(\.rawValue).joined(separator: ", "))
      Remora --headless [--host HOST] [--for SECS] [--dry-run | --through-app [PORT]]
                                   run the bridge without the menu bar, logging to stdout;
                                   --dry-run logs the MIDI instead of making a port;
                                   --through-app sends it as /remora/cc to the running Remora's
                                   OSC (UDP 9020), for testing beside the app
      Remora --screenshots DIR     the settings window's tabs as PNGs, drawn off screen from
                                   demo data (no desk, no SuperRack, no window, no settings file)
      Remora --film DIR            the same, as a still per beat of the video, with beats.json
      Remora --plugin-windows [--place] [--reopen] [--watch] [--for SECS]
                                   only the SuperRack plug-in window guard: close third-party
                                   windows on a rack, page or plug-in change; --place moves them
                                   over the rack page; --reopen shows the new rack's plug-in
                                   after a move, through the running app's OSC; --watch closes
                                   nothing. No MIDI port and no OSC listener, so it runs beside
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
    let kind = value(after: "--console").flatMap(ConsoleKind.init(rawValue:)) ?? saved.consoleKind
    let racks = (try? SuperRackSession.racks(at: saved.sessionPath)) ?? []
    var names: [ConsoleChannel: String] = [:]
    let link = kind.link(host: host)
    Log.line("probing \(kind.title) at \(host)\(kind.experimental ? " (experimental)" : "")")
    link.onState = { st in Log.line("console: \(st)") }
    link.onNamesLink = { up in Log.line("names link: \(up ? "up" : "down")") }
    link.onSelected = { ch in
        DispatchQueue.main.async {
            let name = names[ch] ?? "?"
            let rack = RackMatcher.match(name, in: racks)
            Log.line("selected \(ch) \"\(name)\" → \(rack.map { "rack \($0.label)" } ?? "no rack")")
        }
    }
    link.onControl = { src, v in
        if args.contains("--all") { Log.line("change \(src) = \(v)") }
    }
    link.onModel = { m in Log.line("model: \(m)") }
    link.onNames = { n in
        DispatchQueue.main.async {
            names = n
            Log.line("names: \(n.count) channels")
        }
    }
    link.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
    RunLoop.main.run()
}

if args.contains("--plugin-windows") {
    let guardian = PluginWindowGuard()
    var shown = PluginWindowGuard.Status()
    guardian.onStatus = { st in
        if st.trusted != shown.trusted || st.attached != shown.attached || st.logOpen != shown.logOpen {
            Log.line("Plug-in windows: Accessibility \(st.trusted ? "granted" : "NOT granted"), SuperRack \(st.attached ? "found" : "not running"), log \(st.logOpen ? "open" : "not open")")
        }
        shown = st
    }
    let settings = Settings.load()
    let options = PluginWindowGuard.Options(close: !args.contains("--watch"), place: args.contains("--place"),
                                            reopen: args.contains("--reopen"))
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
    if !options.any { Log.line("Plug-in windows: --watch alone does nothing; add --place or --reopen") }
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
