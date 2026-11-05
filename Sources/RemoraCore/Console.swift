import Foundation

/// The desks Remora can read. Each is a `ConsoleLink`; the bridge only sees channels, names and
/// learnable controls, never the protocol.
public enum ConsoleKind: String, Codable, CaseIterable {
    /// Yamaha CL and QL: the editor port for the selection, RCP for names. Run on a QL1.
    case yamahaCLQL
    /// Yamaha DM7 and DM3: RCP for names and cue, cue as the selection. Documents only.
    case yamahaDM
    /// Allen & Heath Qu: PAFL as the selection (with "Sel follows PAFL"), names. Documents only.
    case ahQu
    /// Allen & Heath dLive and Avantis: names and controls, no selection. Documents only.
    case ahDLive
    /// Allen & Heath SQ: controls only. Documents only.
    case ahSQ

    public var title: String {
        switch self {
        case .yamahaCLQL: return "Yamaha CL / QL"
        case .yamahaDM: return "Yamaha DM7 / DM3"
        case .ahQu: return "Allen & Heath Qu"
        case .ahDLive: return "Allen & Heath dLive / Avantis"
        case .ahSQ: return "Allen & Heath SQ"
        }
    }

    /// Built from documentation and never run against the desk.
    public var experimental: Bool { self != .yamahaCLQL }

    /// Whether the desk can say which channel to follow.
    public var canFollow: Bool {
        switch self {
        case .yamahaCLQL, .yamahaDM, .ahQu: return true
        case .ahDLive, .ahSQ: return false
        }
    }

    /// Whether the desk's MIDI channel has to be set here (the Qu says its own).
    public var needsMIDIChannel: Bool { self == .ahDLive || self == .ahSQ }

    /// One line for the settings window: what Remora reads, and over what.
    public var about: String {
        switch self {
        case .yamahaCLQL:
            return "The editor port (TCP 50000) for the selected channel, RCP (TCP 49280) for channel names. Run on a QL1. Yamaha publishes one MIDI specification for the CL and QL, so a CL should behave the same, but it has not been tried."
        case .yamahaDM:
            return "RCP (TCP 49280) for channel names and cue. Yamaha documents no way to read the selected channel on a DM7 or DM3, so Remora follows the channel on cue instead: turn on [CUE] > [SEL] Link (Setup › Preferences), so cueing a channel selects it too, and the cue you press is the rack you get."
        case .ahQu:
            return "MIDI over TCP (port 51325). The Qu does not say which channel is selected, but it does say which one is on PAFL: turn on Sel follows PAFL (Setup › Audio › PAFL) and PAFL a channel to follow it. Names come from the desk. The Qu takes one TCP MIDI connection at a time, so Remora holds it."
        case .ahDLive:
            return "MIDI over TCP (port 51325, without TLS: set TCP MIDI security to No Security). dLive and Avantis say neither which channel is selected nor which is on PAFL, so Remora cannot follow them. It reads channel names, and soft keys and MIDI Strips set to send MIDI can drive SuperRack as learned controls, a rack each with Go to rack."
        case .ahSQ:
            return "MIDI over TCP (port 51325). The SQ's protocol has no channel names and no selection, so Remora cannot follow it. Soft keys set to send a MIDI note, and MIDI strips, can drive SuperRack as learned controls, a rack each with Go to rack."
        }
    }

    /// Makes the link. Nothing connects until `start()`.
    public func link(host: String, midiChannel: Int = 1) -> ConsoleLink {
        switch self {
        case .yamahaCLQL: return YamahaCLQLConsole(host: host)
        case .yamahaDM: return YamahaDMConsole(host: host)
        case .ahQu: return AllenHeathConsole(family: .qu, host: host, midiChannel: midiChannel)
        case .ahDLive: return AllenHeathConsole(family: .dLive, host: host, midiChannel: midiChannel)
        case .ahSQ: return AllenHeathConsole(family: .sq, host: host, midiChannel: midiChannel)
        }
    }
}

/// How the link to the desk stands.
public enum ConsoleState: Equatable, CustomStringConvertible {
    case stopped
    case connecting
    /// Connected, waiting for the desk to say something (the CL/QL's first heartbeat).
    case waitingForDesk
    case live
    case failed(String)

    public var description: String {
        switch self {
        case .stopped: return "stopped"
        case .connecting: return "connecting"
        case .waitingForDesk: return "waitingForDesk"
        case .live: return "live"
        case .failed(let why): return "failed(\(why))"
        }
    }
}

/// A read-only link to a desk. Callbacks arrive on the link's own queue.
///
/// Every link keeps the one rule: it sends the desk only requests to read. Nothing a link sends
/// may change a parameter, recall a scene or press a key.
public protocol ConsoleLink: AnyObject {
    var onState: ((ConsoleState) -> Void)? { get set }
    /// Whether channel names are coming in (a separate connection on some desks).
    var onNamesLink: ((Bool) -> Void)? { get set }
    var onModel: ((String) -> Void)? { get set }
    /// The selected channel, each time it changes (and once when the link opens, if the desk
    /// can say).
    var onSelected: ((ConsoleChannel) -> Void)? { get set }
    /// Every channel name the link knows, each time one changes.
    var onNames: (([ConsoleChannel: String]) -> Void)? { get set }
    /// Anything else the desk reports that a control could be learned from: a key, a fader.
    var onControl: ((ControlSource, Int32) -> Void)? { get set }
    func start()
    func stop()
}

/// A channel on a desk. The CL/QL numbers its selection on the CL5 frame (see
/// `init(selection:)`); the other desks map theirs onto the same cases.
public enum ConsoleChannel: Hashable, Codable, CustomStringConvertible, Comparable {
    case input(Int)
    case stereoIn(Int, right: Bool)
    /// A stereo input that is one channel (a Qu's ST 1–3), not two halves.
    case stereo(Int)
    case mix(Int)
    case group(Int)
    case aux(Int)
    case fxReturn(Int)
    case matrix(Int)
    case other(Int)

    /// Stable key for the settings file. The CL/QL keys (in, stin, mix, raw) are the ones 0.1
    /// wrote; keep them.
    public var key: String {
        switch self {
        case .input(let n): return "in\(n)"
        case .stereoIn(let n, let right): return "stin\(n)\(right ? "R" : "L")"
        case .stereo(let n): return "st\(n)"
        case .mix(let n): return "mix\(n)"
        case .group(let n): return "grp\(n)"
        case .aux(let n): return "aux\(n)"
        case .fxReturn(let n): return "fxr\(n)"
        case .matrix(let n): return "mtx\(n)"
        case .other(let n): return "raw\(n)"
        }
    }

    public var description: String {
        switch self {
        case .input(let n): return "InCh \(n)"
        case .stereoIn(let n, let right): return "ST IN \(n)\(right ? "R" : "L")"
        case .stereo(let n): return "ST \(n)"
        case .mix(let n): return "MIX \(n)"
        case .group(let n): return "Group \(n)"
        case .aux(let n): return "Aux \(n)"
        case .fxReturn(let n): return "FX Return \(n)"
        case .matrix(let n): return "Matrix \(n)"
        case .other(let n): return String(format: "channel 0x%02X", n)
        }
    }

    /// Inputs first, then the rest in the order a desk lists them.
    private var order: (Int, Int) {
        switch self {
        case .input(let n): return (0, n)
        case .stereoIn(let n, let right): return (1, n * 2 + (right ? 1 : 0))
        case .stereo(let n): return (1, n * 2)
        case .fxReturn(let n): return (2, n)
        case .group(let n): return (3, n)
        case .aux(let n): return (4, n)
        case .mix(let n): return (5, n)
        case .matrix(let n): return (6, n)
        case .other(let n): return (7, n)
        }
    }

    public static func < (a: ConsoleChannel, b: ConsoleChannel) -> Bool { a.order < b.order }
}

/// The name 0.1 and 0.2 used, kept for the code that reads a CL/QL.
public typealias YamahaChannel = ConsoleChannel
