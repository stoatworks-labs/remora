import Foundation

/// What a module says about itself. Its `id` is stable: settings.json stores it.
public struct ModuleInfo: Equatable {
    public enum Kind: String { case console, host }

    public enum Status: String {
        /// Run on the real kit, with the firmware and date in docs/PROTOCOL.md.
        case supported
        /// Built from documents or other people's captures and never run against the kit.
        case experimental
    }

    /// Where a host module can run: `local` needs the host's own computer (a virtual MIDI source,
    /// Accessibility, a session file); `network` can drive a host on another computer.
    public enum Reach: String { case local, network }

    public enum OS: String { case macOS, windows, linux }

    /// "yamaha.ql", "superrack.midi".
    public var id: String
    /// Earlier names for the module in settings.json: 0.1–0.3's `consoleKind` values.
    public var legacyIDs: [String]
    public var kind: Kind
    /// For the picker: "Yamaha CL / QL".
    public var title: String
    /// What logs and menus call it: "SuperRack".
    public var product: String
    /// Groups the picker.
    public var maker: String
    public var status: Status
    /// What it reads or drives, over what, and what is unproven.
    public var about: String
    public var platforms: Set<OS>
    public var reach: Reach
    public var capabilities: Capabilities
    /// A host module's own settings as they start, and what the user sets up in the host; empty
    /// for a console and for SuperRack, whose settings are their own.
    public var hostDefaults: HostDefaults

    public init(id: String, legacyIDs: [String] = [], kind: Kind, title: String, product: String,
                maker: String, status: Status, about: String, platforms: Set<OS>, reach: Reach,
                capabilities: Capabilities, hostDefaults: HostDefaults = HostDefaults()) {
        self.id = id
        self.legacyIDs = legacyIDs
        self.kind = kind
        self.title = title
        self.product = product
        self.maker = maker
        self.status = status
        self.about = about
        self.platforms = platforms
        self.reach = reach
        self.capabilities = capabilities
        self.hostDefaults = hostDefaults
    }

    public var experimental: Bool { status == .experimental }

    /// Whether settings.json's `id` names this module, by its id or an earlier name.
    public func answers(to id: String) -> Bool { self.id == id || legacyIDs.contains(id) }
}

public struct Capabilities: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The desk says which channel to follow, or something Remora can take for it (cue, PAFL).
    public static let follows = Capabilities(rawValue: 1 << 0)
    /// The desk gives channel names.
    public static let names = Capabilities(rawValue: 1 << 1)
    /// The desk's own MIDI channel has to be set in Remora (the Qu says its own).
    public static let needsMIDIChannel = Capabilities(rawValue: 1 << 2)
    /// The desk says how its channels are patched, for routing (`ConsoleEvent.routes`), or the
    /// host which inputs feed each rack (`Rack.inputs`).
    public static let routing = Capabilities(rawValue: 1 << 3)
    /// The host's only way to show a rack loads something (a patch, a rackspace, a song), which
    /// changes the sound. The engine sends such a host nothing until the user has ticked that they
    /// understand (`HostSettings.showChangesSoundAccepted`, docs/ARCHITECTURE.md §2.3).
    public static let showChangesSound = Capabilities(rawValue: 1 << 4)
}

// MARK: Consoles

/// A read-only link to a desk. It sends the desk only requests to read: nothing it sends may
/// change a parameter, recall a scene or press a key.
public protocol ConsoleModule: AnyObject {
    /// Set by the engine before `start()`. Called on the module's own queue.
    var onEvent: ((ConsoleEvent) -> Void)? { get set }
    func start()
    func stop()
}

public enum ConsoleEvent: Equatable {
    /// How the link to the desk stands.
    case link(ConsoleState)
    /// Whether channel names are coming in (a separate connection on some desks).
    case namesLink(Bool)
    case model(String)
    /// The selected channel, each time it changes (and once when the link opens, if the desk can
    /// say).
    case selected(ConsoleChannel)
    /// Every channel name the desk has given, each time one changes.
    case names([ConsoleChannel: String])
    /// Anything else the desk reports that a control could be learned from: a key, a fader.
    case control(ControlSource, Int32)
    /// Each channel's own ports as the desk patches them (its input source as `desk` ports), each
    /// time one changes. Only while routing is on (docs/ARCHITECTURE.md §4.1).
    case routes([ConsoleChannel: [AudioPort]])
}

// MARK: Plug-in hosts

/// Shows the rack the engine picks, the host's own way, and says what racks the host has.
/// Showing never changes the sound, unless the module says so (`Capabilities.showChangesSound`);
/// then the engine sends it nothing until the user has ticked that they understand.
public protocol HostModule: AnyObject {
    /// Set by the engine straight after the module is made, so events can come before `start()`.
    /// Called on any queue.
    var onEvent: ((HostEvent) -> Void)? { get set }
    func start()
    func stop()
    /// The settings changed: the module takes what is its own.
    func update(_ settings: Settings)
    /// A command the host cannot do is logged and dropped, never faked.
    func perform(_ command: HostCommand)
}

public enum HostCommand: Equatable {
    /// Show this rack (0-based).
    case show(Int)
    /// One rack on (+1) or back (-1).
    case step(Int)
    /// One plug-in on (+1) or back (-1).
    case stepPlugin(Int)
    case overview
    case openRack
    /// Forget where the host is and find out again.
    case resync
    /// A CC on the host's MIDI channel, in order with everything else the module sends.
    case cc(number: Int, value: Int)
}

public enum HostEvent: Equatable {
    case racks([Rack])
    /// Where the host is (0-based), nil when the module does not know.
    case position(Int?)
    case windows(PluginWindowStatus)
    /// Why the racks cannot be read; nil once they can.
    case problem(String?)
    /// How the module's own link to the host stands, for a host on one (ProLink). A host with
    /// no link of its own (SuperRack MIDI) never sends it.
    case link(HostLink)
}

public enum HostLink: Equatable {
    /// Waiting for the host to dial in, on this port.
    case listening(UInt16)
    /// The host dialled in and is being answered.
    case connecting(peer: String)
    /// `name` is the host's own name for itself.
    case connected(name: String, peer: String)
    case failed(String)
}

// MARK: Making modules

/// What a module is made with.
public struct ModuleContext {
    public var settings: Settings
    public var platform: Platform
    /// The engine's MIDI port or a test sink. Nil: no MIDI.
    public var midiOut: CCSink?

    public init(settings: Settings, platform: Platform, midiOut: CCSink? = nil) {
        self.settings = settings
        self.platform = platform
        self.midiOut = midiOut
    }

    /// The desk's address as typed, without surrounding spaces.
    public var consoleHost: String { settings.consoleHost.trimmingCharacters(in: .whitespaces) }
}

public struct ConsoleModuleEntry {
    public let info: ModuleInfo
    public let make: (ModuleContext) -> ConsoleModule
    public init(_ info: ModuleInfo, make: @escaping (ModuleContext) -> ConsoleModule) {
        self.info = info
        self.make = make
    }
}

public struct HostModuleEntry {
    public let info: ModuleInfo
    public let make: (ModuleContext) -> HostModule
    public init(_ info: ModuleInfo, make: @escaping (ModuleContext) -> HostModule) {
        self.info = info
        self.make = make
    }
}

/// Every module this build has. Nothing loads at run time: the app is one signed bundle, and
/// outside programs would plug in over the network instead.
public struct ModuleRegistry {
    public let consoles: [ConsoleModuleEntry]
    public let hosts: [HostModuleEntry]

    public init(consoles: [ConsoleModuleEntry], hosts: [HostModuleEntry]) {
        self.consoles = consoles
        self.hosts = hosts
    }

    /// By id or earlier name. Nil for an id this build does not know (from a newer Remora).
    public func console(_ id: String) -> ConsoleModuleEntry? { consoles.first { $0.info.answers(to: id) } }
    public func host(_ id: String) -> HostModuleEntry? { hosts.first { $0.info.answers(to: id) } }
}
