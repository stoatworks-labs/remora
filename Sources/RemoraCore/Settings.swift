import Foundation

public enum NoRackBehaviour: String, Codable, CaseIterable {
    /// Leave SuperRack where it is.
    case stay
    /// Go back to SuperRack's overview.
    case overview
}

/// What a learned control does.
public enum ControlAction: String, Codable, CaseIterable {
    case nextRack, previousRack, nextPlugin, previousPlugin, openRack, overview
    case resync, toggleFollow
    /// One rack, by its number: a soft key per rack on a desk that cannot say what is selected.
    case goToRack
    /// A CC to SuperRack on the bridge's channel, for anything MIDI-learned there
    /// (User Keys, Continuous/Discrete Controls, snapshots).
    case sendCC

    public var title: String {
        switch self {
        case .nextRack: return "Next rack"
        case .previousRack: return "Previous rack"
        case .nextPlugin: return "Next plug-in"
        case .previousPlugin: return "Previous plug-in"
        case .openRack: return "Open rack page"
        case .overview: return "Back to overview"
        case .resync: return "Resync SuperRack"
        case .toggleFollow: return "Follow on/off"
        case .goToRack: return "Go to rack"
        case .sendCC: return "Send CC to SuperRack"
        }
    }

    /// What the host is asked to do, for the actions that are one command.
    public var command: HostCommand? {
        switch self {
        case .nextRack: return .step(1)
        case .previousRack: return .step(-1)
        case .nextPlugin: return .stepPlugin(1)
        case .previousPlugin: return .stepPlugin(-1)
        case .openRack: return .openRack
        case .overview: return .overview
        default: return nil
        }
    }
}

/// How a control's value becomes a CC (for `sendCC`).
public enum ControlMode: String, Codable, CaseIterable {
    /// 127 on every press (a console key's every change, a MIDI value above 0).
    case trigger
    /// The control's position, 0–127 across the range it has been seen to cover.
    case value
    /// 127 while on, 0 while off.
    case onOff

    public var title: String {
        switch self {
        case .trigger: return "Press"
        case .value: return "Value"
        case .onOff: return "On/off"
        }
    }
}

public enum ControlSource: Codable, Hashable, CustomStringConvertible {
    case yamaha(YamahaSysEx.Address)
    case midi(source: String, kind: MIDIEvent.Kind, channel: Int, number: Int)

    public var description: String {
        switch self {
        case .yamaha(let a): return "Console \(a)"
        case .midi(let s, let k, let ch, let n):
            return "\(s): \(k == .cc ? "CC" : "note") \(n) ch \(ch)"
        }
    }
}

public struct ControlMapping: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name = "Control"
    public var source: ControlSource?
    public var action: ControlAction = .nextRack
    public var mode: ControlMode = .trigger
    public var cc = 30
    /// For `goToRack`: the rack, 0-based.
    public var rack = 0
    /// The range the source has been seen to cover, for `.value`.
    public var low: Int32?
    public var high: Int32?

    public init() {}

    // By hand, so a file from before a field existed still loads: the synthesised decoder
    // fails on any missing key, and a failed list loses every learned control.
    private enum CodingKeys: String, CodingKey { case id, name, source, action, mode, cc, rack, low, high }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ControlMapping()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        source = try? c.decodeIfPresent(ControlSource.self, forKey: .source)
        action = (try? c.decodeIfPresent(ControlAction.self, forKey: .action)) ?? d.action
        mode = (try? c.decodeIfPresent(ControlMode.self, forKey: .mode)) ?? d.mode
        cc = try c.decodeIfPresent(Int.self, forKey: .cc) ?? d.cc
        rack = try c.decodeIfPresent(Int.self, forKey: .rack) ?? d.rack
        low = try c.decodeIfPresent(Int32.self, forKey: .low)
        high = try c.decodeIfPresent(Int32.self, forKey: .high)
    }

    /// Yamaha's fader minus infinity: left out of the range.
    static let minusInfinity: Int32 = -32768

    /// Widens the learned range. Returns true if it changed.
    @discardableResult
    public mutating func observe(_ v: Int32) -> Bool {
        guard v != Self.minusInfinity else { return false }
        let l = min(low ?? v, v), h = max(high ?? v, v)
        defer { low = l; high = h }
        return l != low || h != high
    }

    /// 0–127 for `.value` and `.onOff`.
    public func ccValue(for v: Int32) -> Int {
        switch mode {
        case .trigger: return 127
        case .onOff: return v != 0 && v != Self.minusInfinity ? 127 : 0
        case .value:
            guard v != Self.minusInfinity, let l = low, let h = high, h > l else { return 0 }
            let f = Double(min(max(v, l), h) - l) / Double(h - l)
            return Int((f * 127).rounded())
        }
    }
}

public struct Settings: Codable, Equatable {
    /// The console module's id ("yamaha.ql"). One this build does not know, from a newer Remora,
    /// is kept as it is.
    public var console = ConsoleKind.yamahaCLQL.moduleID {
        didSet { consoleKind = ConsoleKind(moduleID: console) }
    }
    /// `console` as 0.1–0.3 name it, written beside it so an older Remora keeps its desk; nil
    /// for a console they lack.
    public private(set) var consoleKind: ConsoleKind? = .yamahaCLQL
    /// The plug-in host module's id.
    public var pluginHost = "superrack.midi"
    public var consoleHost = ""
    /// The desk's own MIDI channel (1–16), for an A&H dLive or SQ.
    public var consoleMIDIChannel = 1
    public var follow = true
    /// SuperRack MIDI's session file. This and the keys after it, to `readRackFromWindow`, are
    /// SuperRack's, flat at the top level as 0.1–0.3 wrote them.
    public var sessionPath = Settings.defaultSessionPath
    public static let defaultSessionPath = "/Users/Shared/Waves/SuperRack Performer/Sessions/CurrentSPRKP.dat"
    public var midiPortName = "Remora"
    public var midiChannel = 16
    public var ccBase = 20
    /// Between rack steps. The settings window's minimum, 2 ms, since 0.3; 0.1 and 0.2 used 20.
    public var stepMilliseconds = 2
    /// Which defaults the file was written with. Absent (0) in files from 0.1 and 0.2.
    public var settingsVersion = Settings.currentVersion
    public static let currentVersion = 3
    public var mode: StepMode = .homeEveryTime
    public var noRack: NoRackBehaviour = .stay
    public var openRackAfterMove = false
    /// Channel key (`YamahaChannel.key`) → 0-based rack, or -1 for no rack. Beats the names.
    public var overrides: [String: Int] = [:]
    public var controls: [ControlMapping] = []
    public var oscEnabled = true
    public var oscPort: UInt16 = 9020
    /// Close SuperRack's third-party plug-in windows when the rack, page or plug-in changes.
    /// Off by default: it needs Accessibility, and closes windows someone may want open.
    public var closePluginWindows = false
    /// Move each third-party plug-in window over the Rack page's plug-in area when it opens.
    public var placePluginWindows = false
    /// After a move on the Rack page, show the new rack's selected third-party plug-in (SuperRack
    /// flicks to the overview and back).
    public var reopenPluginAfterRackChange = false
    /// Hide SuperRack, as ⌘H does, when another app comes to the front with a third-party plug-in
    /// window on screen (they float over every app otherwise). Switching back to SuperRack shows it.
    public var hidePluginWindowsInBackground = false
    /// Read the rack SuperRack shows (Accessibility) instead of only counting MIDI steps. On by
    /// default: without an Accessibility grant it does nothing, and it never asks for one.
    public var readRackFromWindow = true
    /// Which SuperRack, for both SuperRack modules: its app, session file and log.
    public var superRackEdition: SuperRackEdition = .performer
    /// SuperRack ProLink's port: the console port SuperRack's ProLink controller dials.
    public var proLinkPort: UInt16 = 50002
    /// Routing (docs/ARCHITECTURE.md §4.1), as the file holds it: nil, and no `routing` key, until
    /// it first differs from the default. Read and change it through `routingSettings`.
    public private(set) var routing: RoutingSettings?
    /// Every other host module's own settings, by module id (`HostSettings`): nil, and no `hosts`
    /// key, until one first differs from its default. Read and change them through `host(_:)`.
    public private(set) var hosts: [String: HostSettings]?

    /// A host module's own settings, whether or not the file has them.
    public func host(_ id: String) -> HostSettings { hosts?[id] ?? HostSettings() }

    /// Changes a host module's own settings; a module back at its defaults leaves the file.
    public mutating func setHost(_ id: String, _ s: HostSettings) {
        var all = hosts ?? [:]
        all[id] = s == HostSettings() ? nil : s
        hosts = all.isEmpty ? nil : all
    }

    public mutating func editHost(_ id: String, _ change: (inout HostSettings) -> Void) {
        var s = host(id)
        change(&s)
        setHost(id, s)
    }

    /// Picks a plug-in host. Follow starts off for one whose showing changes the sound, until the
    /// user has ticked that they understand (docs/ARCHITECTURE.md §2.3).
    public mutating func pick(host info: ModuleInfo) {
        pluginHost = info.id
        if info.capabilities.contains(.showChangesSound), !host(info.id).showChangesSoundAccepted { follow = false }
    }

    /// Routing's settings, whether or not the file has them.
    public var routingSettings: RoutingSettings {
        get { routing ?? RoutingSettings() }
        set { routing = newValue == RoutingSettings() ? nil : newValue }
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every key is optional so an older or hand-edited file still loads.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        // `console` is the module id; files from 0.1–0.3 have only `consoleKind`.
        let id = try? c.decodeIfPresent(String.self, forKey: .console)
        let kind = try? c.decodeIfPresent(ConsoleKind.self, forKey: .consoleKind)
        console = id.map { ConsoleKind(rawValue: $0)?.moduleID ?? $0 } ?? kind?.moduleID ?? d.console
        consoleKind = ConsoleKind(moduleID: console)
        pluginHost = (try? c.decodeIfPresent(String.self, forKey: .pluginHost)) ?? d.pluginHost
        consoleMIDIChannel = try c.decodeIfPresent(Int.self, forKey: .consoleMIDIChannel) ?? d.consoleMIDIChannel
        consoleHost = try c.decodeIfPresent(String.self, forKey: .consoleHost) ?? d.consoleHost
        follow = try c.decodeIfPresent(Bool.self, forKey: .follow) ?? d.follow
        sessionPath = try c.decodeIfPresent(String.self, forKey: .sessionPath) ?? d.sessionPath
        midiPortName = try c.decodeIfPresent(String.self, forKey: .midiPortName) ?? d.midiPortName
        midiChannel = try c.decodeIfPresent(Int.self, forKey: .midiChannel) ?? d.midiChannel
        ccBase = try c.decodeIfPresent(Int.self, forKey: .ccBase) ?? d.ccBase
        stepMilliseconds = try c.decodeIfPresent(Int.self, forKey: .stepMilliseconds) ?? d.stepMilliseconds
        settingsVersion = try c.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 0
        // 0.1 and 0.2 wrote their default, 20 ms, into every file: move those to the new default.
        // A spacing someone chose (anything else) stays.
        if settingsVersion < 3, stepMilliseconds == 20 { stepMilliseconds = d.stepMilliseconds }
        settingsVersion = Settings.currentVersion
        mode = (try? c.decodeIfPresent(StepMode.self, forKey: .mode)) ?? d.mode
        noRack = (try? c.decodeIfPresent(NoRackBehaviour.self, forKey: .noRack)) ?? d.noRack
        openRackAfterMove = try c.decodeIfPresent(Bool.self, forKey: .openRackAfterMove) ?? d.openRackAfterMove
        overrides = try c.decodeIfPresent([String: Int].self, forKey: .overrides) ?? d.overrides
        controls = (try? c.decodeIfPresent([ControlMapping].self, forKey: .controls)) ?? d.controls
        oscEnabled = try c.decodeIfPresent(Bool.self, forKey: .oscEnabled) ?? d.oscEnabled
        oscPort = try c.decodeIfPresent(UInt16.self, forKey: .oscPort) ?? d.oscPort
        closePluginWindows = try c.decodeIfPresent(Bool.self, forKey: .closePluginWindows) ?? d.closePluginWindows
        placePluginWindows = try c.decodeIfPresent(Bool.self, forKey: .placePluginWindows) ?? d.placePluginWindows
        reopenPluginAfterRackChange = try c.decodeIfPresent(Bool.self, forKey: .reopenPluginAfterRackChange) ?? d.reopenPluginAfterRackChange
        readRackFromWindow = try c.decodeIfPresent(Bool.self, forKey: .readRackFromWindow) ?? d.readRackFromWindow
        hidePluginWindowsInBackground = try c.decodeIfPresent(Bool.self, forKey: .hidePluginWindowsInBackground)
            ?? d.hidePluginWindowsInBackground
        superRackEdition = (try? c.decodeIfPresent(SuperRackEdition.self, forKey: .superRackEdition))
            ?? d.superRackEdition
        proLinkPort = (try? c.decodeIfPresent(UInt16.self, forKey: .proLinkPort)) ?? d.proLinkPort
        routingSettings = (try? c.decodeIfPresent(RoutingSettings.self, forKey: .routing)) ?? RoutingSettings()
        // One host's bad entry (a newer Remora's) loses only that host.
        for (id, h) in (try? c.decodeIfPresent([String: Lenient<HostSettings>].self, forKey: .hosts)) ?? [:] {
            if let v = h.value { setHost(id, v) }
        }
    }

    public var pluginWindowOptions: PluginWindowOptions {
        PluginWindowOptions(close: closePluginWindows, place: placePluginWindows,
                            reopen: reopenPluginAfterRackChange,
                            readRack: readRackFromWindow, hide: hidePluginWindowsInBackground)
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Remora/settings.json")
    }

    public static func load(from url: URL = fileURL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(to url: URL = Settings.fileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

/// A value that decodes to nil instead of failing what holds it.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
