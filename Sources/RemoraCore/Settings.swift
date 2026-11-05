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
        case .sendCC: return "Send CC to SuperRack"
        }
    }

    public var nav: NavCommand? {
        switch self {
        case .nextRack: return .nextRack
        case .previousRack: return .previousRack
        case .nextPlugin: return .nextPlugin
        case .previousPlugin: return .previousPlugin
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
    /// The range the source has been seen to cover, for `.value`.
    public var low: Int32?
    public var high: Int32?

    public init() {}

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
    public var consoleHost = ""
    public var follow = true
    public var sessionPath = SuperRackSession.defaultPath
    public var midiPortName = "Remora"
    public var midiChannel = 16
    public var ccBase = 20
    public var stepMilliseconds = 20
    public var mode: SuperRackDriver.Mode = .homeEveryTime
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
    /// Read the rack SuperRack shows (Accessibility) instead of only counting MIDI steps. On by
    /// default: without an Accessibility grant it does nothing, and it never asks for one.
    public var readRackFromWindow = true

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every key is optional so an older or hand-edited file still loads.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        consoleHost = try c.decodeIfPresent(String.self, forKey: .consoleHost) ?? d.consoleHost
        follow = try c.decodeIfPresent(Bool.self, forKey: .follow) ?? d.follow
        sessionPath = try c.decodeIfPresent(String.self, forKey: .sessionPath) ?? d.sessionPath
        midiPortName = try c.decodeIfPresent(String.self, forKey: .midiPortName) ?? d.midiPortName
        midiChannel = try c.decodeIfPresent(Int.self, forKey: .midiChannel) ?? d.midiChannel
        ccBase = try c.decodeIfPresent(Int.self, forKey: .ccBase) ?? d.ccBase
        stepMilliseconds = try c.decodeIfPresent(Int.self, forKey: .stepMilliseconds) ?? d.stepMilliseconds
        mode = (try? c.decodeIfPresent(SuperRackDriver.Mode.self, forKey: .mode)) ?? d.mode
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
    }

    public var pluginWindowOptions: PluginWindowGuard.Options {
        PluginWindowGuard.Options(close: closePluginWindows, place: placePluginWindows,
                                  reopen: reopenPluginAfterRackChange,
                                  readRack: readRackFromWindow)
    }

    public var driverConfig: SuperRackDriver.Config {
        var c = SuperRackDriver.Config()
        c.channel = min(max(midiChannel, 1), 16)
        c.ccBase = min(max(ccBase, 0), 127 - NavCommand.allCases.count + 1)
        c.spacing = Double(min(max(stepMilliseconds, 0), 500)) / 1000
        c.mode = mode
        c.openRackAfterMove = openRackAfterMove
        return c
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
