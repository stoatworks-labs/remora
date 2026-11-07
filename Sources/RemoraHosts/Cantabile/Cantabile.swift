import Foundation
import RemoraCore

/// Cantabile (Topten Software) through its network server, over a WebSocket at
/// ws://host:35007/api/socket/, from Cantabile's Network Developer Guide and its JavaScript client
/// (cantabile-js 0.3.5). Remora opens the set list, which lists the songs and says which is
/// loaded, and loads a song by its place in the list. Loading a song is a sound, so the module is
/// behind the sound gate, and it doesn't even connect until ticked.
public enum Cantabile {
    public static let info = ModuleInfo(
        id: "cantabile", kind: .host, title: "Cantabile", product: "Cantabile",
        maker: "Topten Software", status: .experimental,
        about: "Remora reads Cantabile's set list through its network server, and loads a song from it, as picking the song in the set list does. A song is a sound, so every move changes what is heard. Cantabile runs on Windows; Remora reaches it over the network. Built from Cantabile's Network Developer Guide and its JavaScript client; not run against Cantabile.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.showChangesSound],
        hostDefaults: HostDefaults(
            port: 35007, tcp: true,
            setUp: """
            1. Options › Miscellaneous: turn on Enable Network Server. It listens on port 35007 and has no password, so keep it to the show network.
            2. Load the set list whose songs you want Remora to pick from: Remora's racks are its songs, in order, without the breaks.
            3. Tick “I understand” above, so Remora can send.
            """))

    public static let entry = HostModuleEntry(info) { CantabileModule($0) }

    /// Everything Remora may send Cantabile. Nothing else is ever built: no binding, command,
    /// engine, transport or song-state endpoint, no set list loaded, no MIDI injected.
    public enum Request: Equatable {
        /// Opens /api/setlist: the songs, the one loaded, and an event when either changes.
        case openSetList
        /// Closes the end point Remora opened, for a Resync.
        case close(epid: Int)
        /// Loads the item at `index` (breaks count), at once.
        case loadSong(epid: Int, index: Int)
        /// Loads the next song (`direction` 1) or the previous one (−1), at once, never wrapping.
        case loadNextSong(epid: Int, direction: Int)

        public var isAllowed: Bool {
            switch self {
            case .openSetList: return true
            case .close(let e): return e > 0
            case .loadSong(let e, let i): return e > 0 && i >= 0
            case .loadNextSong(let e, let d): return e > 0 && (d == 1 || d == -1)
            }
        }

        /// Whether Cantabile answers it. A close goes without a rid, as cantabile-js sends it.
        public var answered: Bool {
            if case .close = self { return false }
            return true
        }

        /// The message, as JSON text, tagged with `rid` for the answer.
        public func json(rid: Int?) -> String {
            var m: [String: Any] = [:]
            if let rid { m["rid"] = rid }
            switch self {
            case .openSetList:
                m["method"] = "open"
                m["ep"] = "/api/setlist"
            case .close(let e):
                m["method"] = "close"
                m["epid"] = e
            case .loadSong(let e, let i):
                m["method"] = "post"
                m["epid"] = e
                m["ep"] = "/loadSongByIndex"
                m["data"] = ["index": i, "delayed": false] as [String: Any]
            case .loadNextSong(let e, let d):
                m["method"] = "post"
                m["epid"] = e
                m["ep"] = "/loadNextSong"
                m["data"] = ["direction": d, "delayed": false, "wrap": false] as [String: Any]
            }
            let data = (try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys, .withoutEscapingSlashes]))
                ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// One set list item: a song, or a break between songs.
    struct Item: Equatable {
        var song: Bool
        var name: String

        init?(_ any: Any?) {
            guard let d = any as? [String: Any] else { return nil }
            song = (d["kind"] as? String) == "song"
            name = (d["name"] as? String) ?? ""
        }
    }
}

/// Cantabile over its WebSocket. Everything runs on its own queue.
public final class CantabileModule: HostModule {
    public var onEvent: ((HostEvent) -> Void)?

    private let queue = DispatchQueue(label: "remora.host.cantabile")
    private let platform: Platform
    private var own: HostSettings
    // On `queue`:
    private var started = false
    private var socket: WebSocketClient?
    private var epid: Int?
    private var openRid: Int?
    private var nextRid = 1
    private var items: [Cantabile.Item] = []
    /// The loaded song's place in `items`, breaks counted (−1: not in the set list). It follows
    /// the song through adds, moves and removes, as cantabile-js follows it.
    private var current: Int?
    /// Rack n is item `songs[n]`.
    private var songs: [Int] = []
    private var racks: [Rack] = []
    private var position: Int?
    private var link: HostLink?
    private var said: Set<String> = []

    public init(_ context: ModuleContext) {
        platform = context.platform
        own = context.settings.host(Cantabile.info.id)
    }

    private var defaults: HostDefaults { Cantabile.info.hostDefaults }
    private var peer: String { "\(own.host):\(own.port(defaults))" }
    /// Not ticked: no connection, and nothing sent.
    private var held: Bool { !own.showChangesSoundAccepted }

    public func start() {
        queue.sync {
            started = true
            if !held { open() }
        }
    }

    public func stop() {
        queue.sync {
            started = false
            close()
        }
    }

    public func update(_ settings: Settings) {
        let new = settings.host(Cantabile.info.id)
        queue.sync {
            let old = own
            let wasHeld = held
            own = new
            guard started else { return }
            if held {
                if !wasHeld { close() }
            } else if wasHeld || new.host != old.host || new.port(defaults) != old.port(defaults) {
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
        let s = WebSocketClient(stream: platform.tcp(host: own.host, port: own.port(defaults), queue: queue),
                                host: own.host, port: own.port(defaults), path: "/api/socket/")
        s.onState = { [weak self] st in self?.socketState(st) }
        s.onText = { [weak self] t in self?.heard(t) }
        socket = s
        s.start()
    }

    private func close() {
        socket?.stop()
        socket = nil
        epid = nil
        openRid = nil
        link = nil
    }

    private func socketState(_ st: WebSocketClient.State) {
        switch st {
        case .connecting:
            set(.connecting(peer: peer))
        case .open:
            openSetList()
        case .failed(let why):
            epid = nil
            // A close is said as Cantabile's: the stream words it for a desk.
            let closed = why == StreamState.closedByPeer || why == WebSocketClient.closedByServer
            set(.failed(closed ? "Cantabile closed the connection" : why))
        }
    }

    private func send(_ r: Cantabile.Request) {
        // The one rule: only what `Request` lists, in range. Anything else is a bug.
        precondition(r.isAllowed, "Cantabile: \(r) is not on the send list")
        var rid: Int?
        if r.answered {
            rid = nextRid
            nextRid += 1
        }
        socket?.send(text: r.json(rid: rid))
    }

    /// Opens the set list. Its rid is noted before it goes, so the answer is known whenever it
    /// comes.
    private func openSetList() {
        epid = nil
        openRid = nextRid
        send(.openSetList)
    }

    private func heard(_ text: String) {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        if let rid = m["rid"] as? Int {
            let status = (m["status"] as? Int) ?? 0
            if rid == openRid {
                openRid = nil
                guard (200..<300).contains(status), let e = m["epid"] as? Int,
                      let data = m["data"] as? [String: Any] else {
                    set(.failed("Cantabile didn't open its set list (\(status) \((m["statusDescription"] as? String) ?? ""))"))
                    return
                }
                epid = e
                load(data)
                set(.connected(name: "Cantabile", peer: peer))
            } else if !(200..<300).contains(status) {
                once("refused", "Cantabile refused a request: \(status) \((m["statusDescription"] as? String) ?? "")")
            }
        }
        guard let e = m["epid"] as? Int, e == epid, let event = m["eventName"] as? String else { return }
        let data = m["data"] as? [String: Any] ?? [:]
        let index = data["index"] as? Int
        switch event {
        case "setListChanged":
            load(data)
        case "itemsReload":
            items = (data["items"] as? [Any] ?? []).compactMap(Cantabile.Item.init)
            current = data["current"] as? Int
        case "itemAdded":
            if let i = index, let item = Cantabile.Item(data["item"]) {
                let at = min(max(i, 0), items.count)
                items.insert(item, at: at)
                if let c = current, c >= 0, at <= c { current = c + 1 }
            }
        case "itemRemoved":
            if let i = index, items.indices.contains(i) {
                items.remove(at: i)
                if let c = current, c >= 0 { current = c == i ? nil : (i < c ? c - 1 : c) }
            }
        case "itemMoved":
            if let f = data["from"] as? Int, let t = data["to"] as? Int, items.indices.contains(f) {
                let item = items.remove(at: f)
                let to = min(max(t, 0), items.count)
                items.insert(item, at: to)
                if let c = current, c >= 0 {
                    let left = f < c ? c - 1 : c
                    current = c == f ? to : (to <= left ? left + 1 : left)
                }
            }
        case "itemChanged":
            if let i = index, let item = Cantabile.Item(data["item"]), items.indices.contains(i) { items[i] = item }
        case "currentSongChanged":
            current = data["current"] as? Int
        default:
            return
        }
        changed()
    }

    private func load(_ data: [String: Any]) {
        items = (data["items"] as? [Any] ?? []).compactMap(Cantabile.Item.init)
        current = data["current"] as? Int
        changed()
    }

    /// The racks are the songs, in order; the position the loaded song's.
    private func changed() {
        songs = items.indices.filter { items[$0].song }
        let new = songs.enumerated().map { Rack(index: $0.offset, name: items[$0.element].name) }
        if new != racks {
            racks = new
            onEvent?(.racks(new))
        }
        let p = current.flatMap { c in songs.firstIndex(of: c) }
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
        // The engine's gate holds these already (`Bridge.hostPerform`); this is the second lock.
        guard started, !held else { return }
        switch command {
        case .show(let i):
            guard let e = epid else {
                once("closed", "Cantabile: nothing sent, as its set list isn't open yet")
                return
            }
            guard i >= 0, i < songs.count else {
                once("show", "Cantabile: rack \(i + 1) can't be shown: the set list has no such song")
                return
            }
            // Loading it again would load it again.
            guard position != i else { return }
            // Shown at once; Cantabile's currentSongChanged confirms it.
            position = i
            onEvent?(.position(i))
            send(.loadSong(epid: e, index: songs[i]))
        case .step(let d):
            guard let e = epid else {
                once("closed", "Cantabile: nothing sent, as its set list isn't open yet")
                return
            }
            for _ in 0..<abs(d) { send(.loadNextSong(epid: e, direction: d > 0 ? 1 : -1)) }
        case .resync:
            // Closed and opened again: the set list as it is now, and where it is.
            if let e = epid { send(.close(epid: e)) }
            openSetList()
        case .stepPlugin:
            once("plugin", "Cantabile has no plug-in steps Remora can send")
        case .overview, .openRack:
            once("page", "Cantabile has no overview or rack page Remora can send")
        case .cc(let n, _):
            once("cc", "Cantabile: CC \(n) not sent: only Cantabile's own commands go to it")
        }
    }

    /// Logs a line the first time only: a command the host can't do is logged and dropped.
    private func once(_ key: String, _ line: String) {
        guard !said.contains(key) else { return }
        said.insert(key)
        Log.line(line)
    }
}
