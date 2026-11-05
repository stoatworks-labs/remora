import AppKit
import RemoraCore

/// The one place the version is written; scripts/build-app.sh reads it.
let appVersion = "0.1.0"

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
      Remora --probe HOST [SECS]   watch a CL/QL's selection and names (read-only, no MIDI)
      Remora --headless [--host HOST] [--for SECS] [--dry-run]
                                   run the bridge without the menu bar, logging to stdout;
                                   --dry-run logs the MIDI instead of making a port
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
    let racks = (try? SuperRackSession.racks(at: Settings.load().sessionPath)) ?? []
    var names: [YamahaChannel: String] = [:]
    let link = YamahaEditorLink(host: host)
    let rcp = YamahaRCPNames(host: host)
    link.onState = { st in Log.line("editor port: \(st)") }
    link.onChange = { c in
        DispatchQueue.main.async {
            if c.address == YamahaSysEx.selectedChannel {
                let ch = YamahaChannel(selection: Int(c.value))
                let name = names[ch] ?? "?"
                let rack = RackMatcher.match(name, in: racks)
                Log.line("selected \(ch) \"\(name)\" → \(rack.map { "rack \($0.label)" } ?? "no rack")")
            } else if args.contains("--all") {
                Log.line("change \(c.address) = \(c.value)")
            }
        }
    }
    rcp.onModel = { m in Log.line("model: \(m)") }
    rcp.onNames = { n in
        DispatchQueue.main.async {
            names = n
            Log.line("names: \(n.count) channels")
        }
    }
    link.start()
    rcp.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
    RunLoop.main.run()
}

/// For --dry-run: logs what would go to SuperRack instead of making a MIDI port.
final class LogSink: CCSink {
    func sendCC(channel: Int, number: Int, value: Int) {
        Log.line("MIDI (dry run): ch \(channel) CC \(number) = \(value)")
    }
}

if args.contains("--headless") {
    var s = Settings.load()
    if let h = value(after: "--host") { s.consoleHost = h }
    let bridge = args.contains("--dry-run") ? Bridge(settings: s, sink: LogSink()) : Bridge(settings: s)
    bridge.start()
    if let secs = value(after: "--for").flatMap(Double.init) {
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
    }
    withExtendedLifetime(bridge) { RunLoop.main.run() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
