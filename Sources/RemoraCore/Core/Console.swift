import Foundation

/// The desk kinds 0.1–0.3 wrote to settings.json as `consoleKind`. Desks are now console modules,
/// named by id (`Settings.console`); these stay as their earlier names, so old files read the
/// same and an older Remora reading a newer file keeps its desk. Never add a case: modules newer
/// than 0.3 have only an id.
public enum ConsoleKind: String, Codable, CaseIterable {
    case yamahaCLQL
    case yamahaDM
    case ahQu
    case ahDLive
    case ahSQ

    /// The console module this kind now is.
    public var moduleID: String {
        switch self {
        case .yamahaCLQL: return "yamaha.ql"
        case .yamahaDM: return "yamaha.dm"
        case .ahQu: return "allenheath.qu"
        case .ahDLive: return "allenheath.dlive"
        case .ahSQ: return "allenheath.sq"
        }
    }

    /// The kind 0.1–0.3 know a module by; nil for a module they lack.
    public init?(moduleID: String) {
        guard let k = Self.allCases.first(where: { $0.moduleID == moduleID }) else { return nil }
        self = k
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
