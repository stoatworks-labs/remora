import AppKit
import RemoraApple
import RemoraCLI
import RemoraConsoles
import RemoraCore
import RemoraEngine
import RemoraHosts

// The commands every system has are RemoraCLI's (Windows' Remora.exe runs the same ones); the
// menu-bar app, the screenshots and the plug-in window guard are macOS's own.
let cli = CLI(version: appVersion)
let args = cli.args

func value(after flag: String) -> String? { cli.value(after: flag) }

if args.contains("--version") {
    print(appVersion)
    exit(0)
}

if args.contains("--help") {
    print("""
    \(cli.helpTitle)

      Remora                       the menu-bar app
    \(CLI.readCommandsHelp)
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

// --racks, --mapping, --settings, --probe and --auto-build: each exits.
cli.runReadCommands()

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
    cli.headless(throughApp: { ThroughAppSink(port: $0) })
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// The bundle's LSUIElement keeps the app out of the Dock. A bare executable (swift run) has none.
if Bundle.main.object(forInfoDictionaryKey: "LSUIElement") == nil { app.setActivationPolicy(.accessory) }
app.run()
