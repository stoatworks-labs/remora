import Foundation
import RemoraCore

/// SuperRack over ProLink: Remora plays the console for SuperRack's "ProLink LAWO Console Remote"
/// controller (`ProLinkConsole`). SuperRack dials Remora and lists its racks, each with its first
/// input channel, and Remora shows a rack with ShowRack on that channel. No MIDI port and no
/// session file, so SuperRack can be on another computer.
public final class SuperRackProLinkModule: HostModule {
    public static let info = ModuleInfo(
        id: "superrack.prolink", kind: .host, title: "SuperRack (ProLink)", product: "SuperRack",
        maker: "Waves", status: .experimental,
        about: "Remora plays the console for SuperRack's ProLink LAWO Console Remote controller, as a LAWO mc² does. SuperRack dials Remora on TCP 50002 and lists its racks; Remora shows a rack with ShowRack on the rack's first input channel. No MIDI port and no session file, so SuperRack can be on another computer. Built from LAWO's mc² scripts and a link run against SuperRack Performer 15.15.12.13; this module has not met SuperRack yet.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [])

    public static let entry = HostModuleEntry(info) { SuperRackProLinkModule($0) }

    public var onEvent: ((HostEvent) -> Void)?

    private let queue = DispatchQueue(label: "remora.superrack.prolink")
    private let platform: Platform
    private var settings: Settings
    /// Made, used and replaced on `queue`.
    private var console: ProLinkConsole
    private var windows: PluginWindowWatcher?
    private var started = false
    // On `queue`:
    /// The rack each ShowRack or NavigateRack in flight is for, by command id.
    private var moves: [Int32: Int] = [:]
    private var saidNoCC = false

    public init(_ context: ModuleContext) {
        settings = context.settings
        platform = context.platform
        console = ProLinkConsole(listener: context.platform.tcpListener(port: context.settings.proLinkPort, queue: queue),
                                 queue: queue)
        wire(console)
    }

    public func start() {
        started = true
        queue.sync { console.start() }
        updateWindows(from: nil)
    }

    public func stop() {
        started = false
        queue.sync { console.stop() }
        windows?.stop()
        windows = nil
    }

    public func update(_ new: Settings) {
        let old = settings
        settings = new
        if new.proLinkPort != old.proLinkPort {
            queue.sync {
                console.stop()
                console = ProLinkConsole(listener: platform.tcpListener(port: new.proLinkPort, queue: queue), queue: queue)
                wire(console)
                if started { console.start() }
            }
        }
        updateWindows(from: old)
    }

    public func perform(_ command: HostCommand) {
        queue.async { [weak self] in self?.run(command) }
    }

    /// For tests: waits until every command performed so far has been handled.
    func waitUntilIdle() { queue.sync {} }

    // MARK: Commands, on `queue`

    private func run(_ command: HostCommand) {
        if case .cc(let n, _) = command {
            if !saidNoCC {
                saidNoCC = true
                Log.line("SuperRack (ProLink): CC \(n) not sent: ProLink has no MIDI. A Send CC control needs SuperRack (MIDI).")
            }
            return
        }
        guard console.isConnected else {
            Log.line("SuperRack (ProLink): not connected, so \(describe(command)) is not sent")
            return
        }
        switch command {
        case .show(let i): show(i)
        case .step(let n):
            cancelMoves()
            for _ in 0..<abs(n) { console.navigateRack(next: n > 0) }
            onEvent?(.position(nil))
        case .stepPlugin(let n):
            for _ in 0..<abs(n) { console.navigatePlugin(next: n > 0) }
        case .overview: console.setViewMode(.overview)
        case .openRack: console.setViewMode(.rack)
        case .resync:
            cancelMoves()
            console.requestRacks()
            onEvent?(.position(nil))
        case .cc: break
        }
    }

    private func show(_ index: Int) {
        let racks = console.racks
        guard let target = racks.first(where: { $0.index == index }) else {
            Log.line("SuperRack (ProLink): SuperRack has no rack \(index + 1)")
            return
        }
        cancelMoves()
        if target.firstInputChannel >= 0 {
            if let id = console.showRack(inputChannelIndex: target.firstInputChannel) { moves[id] = index }
            return
        }
        // ShowRack can't reach a rack no input channel feeds. Show the nearest rack one does, and
        // step from there. Unproven: NavigateRack's steps have not been watched on SuperRack.
        let fed = racks.filter { $0.firstInputChannel >= 0 }
        guard let from = fed.min(by: { a, b in
            let da = abs(a.index - index), db = abs(b.index - index)
            return da != db ? da < db : a.index < b.index
        }) else {
            Log.line("SuperRack (ProLink): no rack has an input channel, so ShowRack can't reach \(target.name)")
            return
        }
        let steps = index - from.index
        Log.line("SuperRack (ProLink): \(target.name) has no input channel: ShowRack on \(from.name), then \(abs(steps)) NavigateRack")
        console.showRack(inputChannelIndex: from.firstInputChannel)
        var last: Int32?
        for _ in 0..<abs(steps) { last = console.navigateRack(next: steps > 0) }
        if let last { moves[last] = index }
    }

    /// Drops rack moves not sent yet: the newest one wins.
    private func cancelMoves() {
        for id in console.cancelWaiting(["ShowRack", "NavigateRack"]) { moves[id] = nil }
    }

    private func describe(_ c: HostCommand) -> String {
        switch c {
        case .show(let i): return "rack \(i + 1)"
        case .step(let n): return n < 0 ? "Previous Rack" : "Next Rack"
        case .stepPlugin(let n): return n < 0 ? "Previous Plug-in" : "Next Plug-in"
        case .overview: return "Overview"
        case .openRack: return "Open Rack"
        case .resync: return "Resync"
        case .cc(let n, _): return "CC \(n)"
        }
    }

    // MARK: Events, on `queue`

    private func wire(_ c: ProLinkConsole) {
        c.consoleName = "Remora"
        c.onLog = { Log.line("SuperRack (ProLink): \($0)") }
        c.onState = { [weak self] st in self?.linkChanged(st) }
        c.onRacks = { [weak self] r in self?.onEvent?(.racks(r.map(\.rack))) }
        c.onResult = { [weak self] id, error, _ in
            guard let self, let rack = self.moves.removeValue(forKey: id) else { return }
            self.onEvent?(.position(error == 0 ? rack : nil))
        }
    }

    private func linkChanged(_ st: ProLinkConsole.State) {
        switch st {
        case .stopped:
            return
        case .listening(let p):
            Log.line("SuperRack (ProLink): waiting for SuperRack on TCP \(p)")
            onEvent?(.link(.listening(p)))
            onEvent?(.problem("not connected (Remora is waiting on TCP \(p))"))
        case .handshaking(let peer):
            onEvent?(.link(.connecting(peer: peer)))
            return
        case .connected(let peer, let name):
            Log.line("SuperRack (ProLink): connected to \(name) at \(peer)")
            onEvent?(.link(.connected(name: name, peer: peer)))
            onEvent?(.problem(nil))
        case .failed(let why):
            Log.line("SuperRack (ProLink): \(why)")
            onEvent?(.link(.failed(why)))
            onEvent?(.problem(why))
        }
        if !console.isConnected {
            moves = [:]
            onEvent?(.position(nil))
        }
    }

    // MARK: Plug-in windows

    /// The guard's options for ProLink. Showing the new rack's plug-in waits for its own run, and
    /// the rack is never read from the window: ShowRack goes straight there.
    private func windowOptions(_ s: Settings) -> PluginWindowOptions {
        var o = s.pluginWindowOptions
        o.reopen = false
        o.readRack = false
        return o
    }

    /// Makes the guard when a window option is first turned on (it starts a thread of its own),
    /// and remakes it for another edition.
    private func updateWindows(from old: Settings?) {
        guard started else { return }
        let o = windowOptions(settings)
        if let old, old.superRackEdition != settings.superRackEdition {
            windows?.stop()
            windows = nil
        }
        if windows == nil {
            guard o.windows else { return }
            windows = (platform as? PluginWindowPlatform)?.pluginWindowWatcher(for: settings.superRackEdition)
            windows?.onStatus = { [weak self] st in self?.onEvent?(.windows(st)) }
            windows?.set(o)
        } else if old.map({ windowOptions($0) }) != o {
            windows?.set(o)
        }
    }
}
