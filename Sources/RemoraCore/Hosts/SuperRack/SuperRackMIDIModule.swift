import Foundation

/// SuperRack Performer over its MIDI Controller: rack steps counted by `SuperRackDriver`, the racks
/// from a copy of its session, and, where the platform has them, the plug-in window guard and the
/// rack read from SuperRack's window.
public final class SuperRackMIDIModule: HostModule {
    public static let info = ModuleInfo(
        id: "superrack.midi", kind: .host, title: "SuperRack Performer (MIDI)", product: "SuperRack",
        maker: "Waves", status: .supported,
        about: "Next and Previous Rack over a virtual MIDI source, counted one message a step, with the racks read from a copy of SuperRack's session file. Run on SuperRack Performer 15.15.",
        platforms: [.macOS], reach: .local, capabilities: [])

    public static let entry = HostModuleEntry(info) { SuperRackMIDIModule($0) }

    public var onEvent: ((HostEvent) -> Void)?

    public let driver: SuperRackDriver
    private let windows: PluginWindowWatcher?
    private var settings: Settings
    private var sessionStamp = ""
    private var sessionTimer: Timer?
    private var racks: [Rack] = []
    private var problem: String?

    /// The platform's window guard, if it has one (macOS: Accessibility).
    public init(_ context: ModuleContext) {
        settings = context.settings
        driver = SuperRackDriver(sink: context.midiOut ?? NullSink())
        windows = (context.platform as? PluginWindowPlatform)?.pluginWindowWatcher()
        driver.config = settings.driverConfig
        driver.reader = windows
        driver.onPosition = { [weak self] p in self?.onEvent?(.position(p)) }
        windows?.onStatus = { [weak self] st in self?.onEvent?(.windows(st)) }
        // The guard's "show the new rack's plug-in": overview, then the Rack page again.
        windows?.onReopen = { [weak self] in
            self?.driver.send(.overview)
            self?.driver.send(.openRack)
        }
    }

    public func start() {
        reloadSession(force: true)
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reloadSession(force: false)
        }
        if settings.pluginWindowOptions.any { windows?.set(settings.pluginWindowOptions) }
    }

    public func stop() {
        sessionTimer?.invalidate()
        windows?.stop()
    }

    public func update(_ new: Settings) {
        let old = settings
        settings = new
        driver.config = new.driverConfig
        if new.sessionPath != old.sessionPath { reloadSession(force: true) }
        if new.pluginWindowOptions != old.pluginWindowOptions { windows?.set(new.pluginWindowOptions) }
    }

    public func perform(_ command: HostCommand) {
        switch command {
        case .show(let rack): driver.select(rack)
        case .step(let n): driver.send(n < 0 ? .previousRack : .nextRack)
        case .stepPlugin(let n): driver.send(n < 0 ? .previousPlugin : .nextPlugin)
        case .overview: driver.send(.overview)
        case .openRack: driver.send(.openRack)
        case .resync: driver.resync()
        case .cc(let number, let value): driver.sendRaw(number: number, value: value)
        }
    }

    /// For tests: racks as the session would give them.
    public func setRacksForTesting(_ r: [Rack]) {
        racks = r
        driver.rackCount = r.count
        driver.racks = r
        onEvent?(.racks(r))
    }

    private func reloadSession(force: Bool) {
        let path = settings.sessionPath
        let stamp = SuperRackSession.stamp(path)
        guard force || stamp != sessionStamp else { return }
        sessionStamp = stamp
        do {
            let contents = try SuperRackSession.read(at: path)
            let new = contents.racks
            windows?.setChains(contents.chains)
            if new != racks {
                Log.line("SuperRack: \(new.count) racks: \(new.map(\.name).joined(separator: ", "))")
            }
            racks = new
            driver.rackCount = max(new.count, 1)
            driver.racks = new
            problem = nil
            onEvent?(.racks(new))
            onEvent?(.problem(nil))
        } catch {
            if problem != "\(error)" { Log.line("SuperRack: \(error)") }
            problem = "\(error)"
            onEvent?(.problem(problem))
        }
    }
}
