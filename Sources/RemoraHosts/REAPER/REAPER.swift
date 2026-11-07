import Foundation
import RemoraCore

/// REAPER (Cockos) through its web interface, from the protocol notes in the interface's own
/// main.js (REAPER 7.79) and REAPER's user guide (7.85). Remora asks for the track list every
/// second, and shows a track by selecting it alone; with Only allow one FX chain window open at a
/// time and Open FX window on track selection change on, REAPER then shows that track's FX.
/// Selecting a track doesn't change the sound unless the track is set to arm when selected.
public enum REAPER {
    public static let info = ModuleInfo(
        id: "reaper", kind: .host, title: "REAPER", product: "REAPER",
        maker: "Cockos", status: .experimental,
        about: "Remora reads REAPER's tracks through its web interface every second, and shows a track by selecting it, alone, as clicking it does. With REAPER set to open a track's FX when the selection changes, that shows its plug-ins. Selecting a track doesn't change the sound, unless the track is set to arm for recording when selected. Built from the web interface's notes (REAPER 7.79) and REAPER's user guide; not run against REAPER.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [],
        hostDefaults: HostDefaults(
            port: 8080, tcp: true,
            setUp: """
            1. Preferences › Control/OSC/web › Add › Control surface mode: Web browser interface. Note the port (8080 in REAPER's guide) and set the TCP port above to it. Leave the username and password empty: Remora sends none.
            2. Preferences › Plug-ins: tick Only allow one FX chain window open at a time, and Open FX window on track selection change, so selecting a track shows its plug-ins.
            3. Leave Automatic record arm when track selected off on every track: with it on, every move would arm a track.
            """))

    public static let entry = HostModuleEntry(info) { REAPERModule($0) }

    // MARK: What Remora may ask

    /// The track list: one line per track, master first.
    public static let trackList = "TRACK"
    /// Track: Unselect all tracks. REAPER's own index.html sends it before selecting one.
    public static let unselectAll = "40297"
    /// Selects track `n` (1 is the first track; 0 is the master, never selected).
    public static func select(track n: Int) -> String { "SET/TRACK/\(n)/SEL/1" }

    /// The whitelist: a path is `/_/` and commands joined by `;`, each one of the three above.
    /// Nothing else is ever sent: no action but 40297, no SET but a track's selection.
    public static func isAllowed(_ path: String) -> Bool {
        guard path.hasPrefix("/_/") else { return false }
        let commands = path.dropFirst(3).split(separator: ";", omittingEmptySubsequences: false)
        return !commands.isEmpty && commands.allSatisfy { c in
            if c == trackList || c == unselectAll { return true }
            let p = c.split(separator: "/", omittingEmptySubsequences: false)
            guard p.count == 5, p[0] == "SET", p[1] == "TRACK", p[3] == "SEL", p[4] == "1" else { return false }
            let n = p[2]
            return !n.isEmpty && n.count <= 5 && n.first != "0"
                && n.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        }
    }

    /// The user tracks in a TRACK answer, in order: (number from 1, name, selected). The master
    /// (0) is left out.
    public static func tracks(_ body: String) -> [(number: Int, name: String, selected: Bool)] {
        body.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 4, f[0] == "TRACK", let n = Int(f[1]), n >= 1, let flags = Int(f[3]) else { return nil }
            return (n, String(f[2]).trimmingCharacters(in: .whitespacesAndNewlines), flags & 2 != 0)
        }
    }
}

/// Polls REAPER's web interface and selects tracks through it, one request at a time. Everything
/// runs on its own queue.
public final class REAPERModule: HostModule {
    public var onEvent: ((HostEvent) -> Void)?

    private let queue = DispatchQueue(label: "remora.host.reaper")
    private let platform: Platform
    private let every: TimeInterval
    private var own: HostSettings
    // On `queue`:
    private var started = false
    private var timer: DispatchSourceTimer?
    /// Bumped whenever the link is reopened or stopped, so a late answer is dropped.
    private var generation = 0
    private var asking = false
    /// Waiting for the request in flight: the latest show, or a resync's question.
    private var queued: [String]?
    private var tracks: [(number: Int, name: String, selected: Bool)] = []
    private var racks: [Rack] = []
    private var position: Int?
    private var link: HostLink?
    private var said: Set<String> = []

    public init(_ context: ModuleContext, every: TimeInterval = 1) {
        platform = context.platform
        own = context.settings.host(REAPER.info.id)
        self.every = every
    }

    private var defaults: HostDefaults { REAPER.info.hostDefaults }
    private var peer: String { "\(own.host):\(own.port(defaults))" }

    public func start() {
        queue.sync {
            started = true
            open()
        }
    }

    public func stop() {
        queue.sync {
            started = false
            close()
        }
    }

    public func update(_ settings: Settings) {
        let new = settings.host(REAPER.info.id)
        queue.sync {
            let old = own
            own = new
            if started, new.host != old.host || new.port(defaults) != old.port(defaults) {
                close()
                open()
            }
        }
    }

    public func perform(_ command: HostCommand) {
        queue.async { [weak self] in self?.run(command) }
    }

    /// For tests: waits until everything performed so far has been handled.
    public func waitUntilIdle() { queue.sync {} }

    // MARK: On `queue`

    private func open() {
        racks = []
        tracks = []
        position = nil
        set(.connecting(peer: peer))
        ask([REAPER.trackList])
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + every, repeating: every)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func close() {
        timer?.cancel()
        timer = nil
        generation += 1
        asking = false
        queued = nil
    }

    private func poll() {
        guard !asking, queued == nil else { return }
        ask([REAPER.trackList])
    }

    /// Sends one request, or keeps it until the one in flight has its answer.
    private func ask(_ commands: [String]) {
        let path = "/_/" + commands.joined(separator: ";")
        // The one rule: only what the whitelist lists. Anything else is a bug.
        precondition(REAPER.isAllowed(path), "REAPER: \(path) is not on the send whitelist")
        guard !asking else {
            // A show waiting is never replaced by a question; a later show replaces it.
            if queued == nil || commands.count > 1 { queued = commands }
            return
        }
        asking = true
        let g = generation
        HTTPGet.get(platform, host: own.host, port: own.port(defaults), path: path, queue: queue) { [weak self] r in
            guard let self, self.generation == g else { return }
            self.asking = false
            self.answered(r)
            if let next = self.queued {
                self.queued = nil
                self.ask(next)
            }
        }
    }

    private func answered(_ r: Result<HTTPGet.Answer, HTTPGet.Failure>) {
        switch r {
        case .success(let a) where a.status == 200:
            read(a.body)
            set(.connected(name: "REAPER", peer: peer))
        case .success(let a) where a.status == 401:
            set(.failed("REAPER asked for a username and password, and Remora sends none: leave them empty in REAPER's web interface settings"))
        case .success(let a):
            set(.failed("\(peer) answered HTTP \(a.status), not as REAPER's web interface does"))
        case .failure(.unreachable(let why)):
            set(.failed("no REAPER web interface at \(peer) (\(why))"))
        case .failure(.timedOut):
            set(.failed("no answer from \(peer) within 3 s"))
        case .failure(.badAnswer):
            set(.failed("what answered at \(peer) isn't REAPER's web interface"))
        case .failure(.tooBig):
            set(.failed("REAPER's answer was over \(HTTPGet.maxBytes >> 20) MB"))
        }
    }

    private func read(_ body: String) {
        let t = REAPER.tracks(body)
        // An answer with no TRACK line at all isn't a track list (a project always has a master).
        guard !t.isEmpty || body.contains("TRACK\t0\t") else { return }
        tracks = t
        let new = t.enumerated().map { Rack(index: $0.offset, name: $0.element.name) }
        if new != racks {
            racks = new
            onEvent?(.racks(new))
        }
        let p = t.firstIndex { $0.selected }
        if p != position {
            position = p
            onEvent?(.position(p))
        }
    }

    private func set(_ l: HostLink) {
        guard l != link else { return }
        link = l
        onEvent?(.link(l))
    }

    private func run(_ command: HostCommand) {
        guard started else { return }
        switch command {
        case .show(let i):
            guard i >= 0, i < tracks.count else {
                once("show", "REAPER: rack \(i + 1) can't be shown: REAPER has no such track")
                return
            }
            // Only it selected, then the list again, so the answer says where REAPER is.
            ask([REAPER.unselectAll, REAPER.select(track: tracks[i].number), REAPER.trackList])
            if position != i {
                position = i
                onEvent?(.position(i))
            }
        case .step(let d):
            guard let p = position else {
                once("step", "REAPER: not stepped, as no track is selected. Show a rack first.")
                return
            }
            let t = min(max(p + d, 0), max(tracks.count - 1, 0))
            if t != p { run(.show(t)) }
        case .resync:
            ask([REAPER.trackList])
        case .stepPlugin:
            once("plugin", "REAPER has no plug-in steps Remora can send")
        case .overview, .openRack:
            once("page", "REAPER has no overview or rack page Remora can send")
        case .cc(let n, _):
            once("cc", "REAPER: CC \(n) not sent: only REAPER's own commands go to it")
        }
    }

    /// Logs a line the first time only: a command the host can't do is logged and dropped.
    private func once(_ key: String, _ line: String) {
        guard !said.contains(key) else { return }
        said.insert(key)
        Log.line(line)
    }
}
