import Foundation

/// How a host stepped one rack at a time finds a rack: SuperRack MIDI's `mode` in settings.json.
public enum StepMode: String, Codable, CaseIterable {
    /// Back to rack 1 before every move. Slower, and right even after someone clicks a
    /// rack in SuperRack.
    case homeEveryTime
    /// Count from the last rack moved to. Fast; wrong after a click in SuperRack until
    /// the next Resync.
    case countFromLast
}

/// Which SuperRack both SuperRack modules drive: `superRackEdition` in settings.json. It picks the
/// app, its session file and its log.
public enum SuperRackEdition: String, Codable, CaseIterable {
    /// SuperRack Performer: the plug-ins run on the Mac. Run on 15.15.
    case performer
    /// SuperRack SoundGrid: the plug-ins run on a SoundGrid server. Not run.
    case soundGrid
}

/// What the plug-in window guard does with a host's plug-in windows (SuperRack's, today).
public struct PluginWindowOptions: Equatable {
    /// Close third-party windows when the rack, the page or the plug-in changes.
    public var close = false
    /// Move each third-party window over the Rack page's plug-in area when it opens.
    public var place = false
    /// After a move to another rack on the Rack page, show its selected third-party plug-in:
    /// SuperRack only does that when the Rack page is opened from another page, so Remora asks
    /// for the overview and the Rack page again (`onReopen`).
    public var reopen = false
    /// Read the rack SuperRack shows, for the driver. Needs Accessibility but never asks for it,
    /// and reads nothing else: no plug-in windows, no log.
    public var readRack = false
    /// Hide SuperRack (as ⌘H does) when another app comes to the front with a third-party window
    /// on screen (`PluginWindowPolicy.hidesSuperRack`). Switching back to SuperRack shows it.
    public var hide = false
    public init(close: Bool = false, place: Bool = false, reopen: Bool = false, readRack: Bool = false,
                hide: Bool = false) {
        self.close = close
        self.place = place
        self.reopen = reopen
        self.readRack = readRack
        self.hide = hide
    }
    public var any: Bool { windows || readRack }
    /// Anything done to plug-in windows (which needs the log and asks for Accessibility).
    public var windows: Bool { close || place || reopen || hide }
}

/// How the plug-in window guard stands, for the settings window and the menu.
public struct PluginWindowStatus: Equatable {
    public var trusted = false
    public var attached = false
    public var logOpen = false
    public var openWindows = 0
    public var lastAction: String?
    /// The driver can read the rack SuperRack shows.
    public var readsRack = false
    public init() {}
}

/// What a host module's own settings start as, and what the user sets up in the host once. The
/// Plug-in Host tab is drawn from it, for every host but SuperRack.
public struct HostDefaults: Equatable {
    /// The port Remora sends to, for a host on the network; nil for none.
    public var port: UInt16?
    /// The port Remora listens on for the host's answers, for a host that sends them to a fixed
    /// port rather than back where they came from; nil for none.
    public var replyPort: UInt16?
    /// The MIDI channel, for a host driven over Remora's MIDI port; nil for none.
    public var midiChannel: Int?
    /// The host can't list its racks, so the user types them, in order.
    public var typedRacks: Bool
    /// What to set up in the host once, for the Plug-in Host tab.
    public var setUp: String

    public init(port: UInt16? = nil, replyPort: UInt16? = nil, midiChannel: Int? = nil, typedRacks: Bool = false,
                setUp: String = "") {
        self.port = port
        self.replyPort = replyPort
        self.midiChannel = midiChannel
        self.typedRacks = typedRacks
        self.setUp = setUp
    }
}

/// One host module's own settings: settings.json's `hosts`, by module id. SuperRack's are the flat
/// keys 0.1–0.3 wrote, not these. Anything left nil takes the module's `HostDefaults`.
public struct HostSettings: Codable, Equatable {
    /// The host's computer, for a host on the network. Empty: this Mac.
    public var address = ""
    public var port: UInt16?
    public var replyPort: UInt16?
    public var midiChannel: Int?
    /// The racks, typed in order, for a host that can't list its own.
    public var racks: [String] = []
    /// The user has ticked that showing a rack on this host loads something, and that this is what
    /// they want. Until then the engine sends the host nothing (`Capabilities.showChangesSound`).
    public var showChangesSoundAccepted = false

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every key optional, as in the rest of the file.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = (try? c.decodeIfPresent(String.self, forKey: .address)) ?? ""
        port = try? c.decodeIfPresent(UInt16.self, forKey: .port)
        replyPort = try? c.decodeIfPresent(UInt16.self, forKey: .replyPort)
        midiChannel = (try? c.decodeIfPresent(Int.self, forKey: .midiChannel)).flatMap { $0 }.map { min(max($0, 1), 16) }
        racks = (try? c.decodeIfPresent([String].self, forKey: .racks)) ?? []
        showChangesSoundAccepted = (try? c.decodeIfPresent(Bool.self, forKey: .showChangesSoundAccepted)) ?? false
    }

    /// The host's address, this Mac's when none is typed.
    public var host: String {
        let a = address.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? "127.0.0.1" : a
    }

    public func port(_ d: HostDefaults) -> UInt16 { port ?? d.port ?? 0 }
    public func replyPort(_ d: HostDefaults) -> UInt16 { replyPort ?? d.replyPort ?? 0 }
    public func midiChannel(_ d: HostDefaults) -> Int { midiChannel ?? d.midiChannel ?? 1 }

    /// The typed racks as racks, numbered in order. Blank lines are dropped.
    public var typedRacks: [Rack] {
        racks.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.enumerated()
            .map { Rack(index: $0.offset, name: $0.element) }
    }
}
