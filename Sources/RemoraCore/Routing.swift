import Foundation

// Routing: which rack a channel feeds, from how the audio is patched rather than from names.
// Off until the user turns it on (docs/ARCHITECTURE.md §4.1).

/// One channel of a port on a device: "QL1 dante out 5", "host in 12".
///
/// Two device names are special: `desk`, the console Remora follows, and `host`, the plug-in
/// host's inputs (a rack's inputs are `host` inputs). Device names compare without case.
public struct AudioPort: Hashable, Codable, Comparable, CustomStringConvertible {
    public enum Domain: String, Codable, CaseIterable {
        case dante, aes67, madi, usb, aes50, adat, analog
        /// A desk channel's own signal, its direct out or insert send: `desk channel out 5` is
        /// InCh 5's.
        case channel
        /// The plug-in host's inputs.
        case host
        case other
    }

    public enum Side: String, Codable {
        case input = "in", output = "out"
    }

    public static let desk = "desk"
    public static let host = "host"

    public var device: String
    public var domain: Domain
    public var side: Side
    /// From 1.
    public var channel: Int

    public init(_ device: String, _ domain: Domain, _ side: Side, _ channel: Int) {
        self.device = device
        self.domain = domain
        self.side = side
        self.channel = channel
    }

    /// The plug-in host's input `n`, from 1.
    public static func hostInput(_ n: Int) -> AudioPort { AudioPort(host, .host, .input, n) }
    /// Input channel `n`'s own signal on the desk.
    public static func deskChannel(_ n: Int) -> AudioPort { AudioPort(desk, .channel, .output, n) }

    public func offset(_ n: Int) -> AudioPort { AudioPort(device, domain, side, channel + n) }

    public static func == (a: AudioPort, b: AudioPort) -> Bool {
        a.domain == b.domain && a.side == b.side && a.channel == b.channel
            && a.device.caseInsensitiveCompare(b.device) == .orderedSame
    }

    public func hash(into h: inout Hasher) {
        h.combine(device.lowercased())
        h.combine(domain)
        h.combine(side)
        h.combine(channel)
    }

    public static func < (a: AudioPort, b: AudioPort) -> Bool {
        (a.device.lowercased(), a.domain.rawValue, a.side.rawValue, a.channel)
            < (b.device.lowercased(), b.domain.rawValue, b.side.rawValue, b.channel)
    }

    public var description: String {
        domain == .host || domain == .other
            ? "\(device) \(side.rawValue) \(channel)"
            : "\(device) \(domain.rawValue) \(side.rawValue) \(channel)"
    }
}

/// Audio goes from one port to another: a Dante subscription (transmit to receive), a cable, a
/// direct out patched to an output, or two names for one channel (a Dante receive channel and the
/// host input it is).
public struct PatchLink: Hashable, Codable {
    public var from: AudioPort
    public var to: AudioPort
    public init(from: AudioPort, to: AudioPort) {
        self.from = from
        self.to = to
    }
}

/// A run of channels written once, one per line, for the links Remora cannot read:
///
///     desk channel out 1-32 > desk dante out 1     InCh 1–32's direct outs on the desk's Dante 1–32
///     DVS dante in 1-64 > host in 1                Dante Virtual Soundcard's channels are the host's
///     QL1 madi out 1-64 > MADI card madi in 1      a MADI cable
///
/// Each side is a device name (any words), an optional domain, `in` or `out`, and a channel or a
/// range. The right side's range, if it has one, must be as long as the left's. `#` starts a
/// comment. `host` is always the plug-in host's inputs.
public struct PortRun: Hashable, Codable {
    public var from: AudioPort
    public var to: AudioPort
    public var count: Int

    public static let maxCount = 1024

    public init(from: AudioPort, to: AudioPort, count: Int) {
        self.from = from
        self.to = to
        self.count = count
    }

    public var links: [PatchLink] { (0..<count).map { PatchLink(from: from.offset($0), to: to.offset($0)) } }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case noArrow
        case side(String)
        case lengths(Int, Int)

        public var description: String {
            switch self {
            case .noArrow: return "no “>” between the two ends"
            case .side(let s): return "“\(s)” is not a device, an optional domain, in or out, and a channel or range"
            case .lengths(let a, let b): return "\(a) channels go to \(b)"
            }
        }
    }

    /// Nil for a blank line or a comment.
    public static func parse(_ line: String) throws -> PortRun? {
        let text = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty else { return nil }
        let halves = text.split(separator: ">", omittingEmptySubsequences: false)
        guard halves.count == 2 else { throw ParseError.noArrow }
        let (from, n) = try side(halves[0])
        let (to, m) = try side(halves[1])
        guard m == 1 || m == n else { throw ParseError.lengths(n, m) }
        return PortRun(from: from, to: to, count: n)
    }

    /// One end: its first port and how many channels it names.
    static func side(_ s: Substring) throws -> (AudioPort, Int) {
        let words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        let bad = ParseError.side(s.trimmingCharacters(in: .whitespaces))
        guard words.count >= 3 else { throw bad }
        let range = words[words.count - 1].replacingOccurrences(of: "–", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(range.count), let first = Int(range[0]), first >= 1 else { throw bad }
        let last = range.count == 2 ? Int(range[1]) : first
        guard let last, last >= first, last - first < maxCount else { throw bad }
        let sideWord = words[words.count - 2].lowercased()
        let side: AudioPort.Side
        switch sideWord {
        case "in", "rx", "input": side = .input
        case "out", "tx", "output": side = .output
        default: throw bad
        }
        var rest = Array(words[..<(words.count - 2)])
        var domain = AudioPort.Domain.other
        if rest.count >= 2, let d = AudioPort.Domain(rawValue: rest[rest.count - 1].lowercased()) {
            domain = d
            rest.removeLast()
        }
        let device = rest.joined(separator: " ")
        guard !device.isEmpty else { throw bad }
        if device.caseInsensitiveCompare(AudioPort.host) == .orderedSame {
            // The host's ports are its inputs, whatever the line calls them.
            guard side == .input else { throw bad }
            return (.hostInput(first), last - first + 1)
        }
        return (AudioPort(device, domain, side, first), last - first + 1)
    }

    /// The line as Remora would write it.
    public var text: String {
        let end = count > 1 ? "\(from.channel)-\(from.channel + count - 1)" : "\(from.channel)"
        let fromText = from.description.split(separator: " ").dropLast().joined(separator: " ")
        return "\(fromText) \(end) > \(to)"
    }
}

/// What routing says about one channel.
public enum RoutingAnswer: Equatable {
    /// One rack is reached. `path` runs in signal order from where the channel's audio starts
    /// (its source, or a port upstream of it) to the rack's input.
    case rack(Int, path: [AudioPort])
    /// Routing knows nothing that reaches a rack.
    case none
    /// More than one rack is reached, so the names decide.
    case several([Int])
}

/// How a channel's rack was found (docs/ARCHITECTURE.md §4).
public enum MappingSource: Equatable {
    case override
    /// Routing reached the rack, by this path (`RoutingAnswer.rack`).
    case routing([AudioPort])
    case name

    /// A path on one line: every port when there are four or fewer, else the ends.
    public static func describe(_ path: [AudioPort]) -> String {
        guard let first = path.first, let last = path.last else { return "" }
        return path.count <= 4 ? path.map(\.description).joined(separator: " → ") : "\(first) → … → \(last)"
    }
}

/// One channel's rack, how it was found, and what routing and the name each say.
public struct ChannelMapping: Equatable {
    public var rack: Rack?
    public var source: MappingSource?
    /// Routing's answer, while routing is on.
    public var routing: RoutingAnswer?
    /// The rack the name alone finds.
    public var byName: Rack?

    public init() {}

    /// Routing and the name each found a rack, and not the same one.
    public var disagrees: Bool {
        if case .rack(let i, _)? = routing, let n = byName { return n.index != i }
        return false
    }
}

/// Every link Remora knows, as a graph to search.
public struct PatchGraph {
    private var forward: [AudioPort: [AudioPort]] = [:]
    private var backward: [AudioPort: [AudioPort]] = [:]
    public private(set) var linkCount = 0

    public init(_ links: [PatchLink]) {
        for l in Set(links) where l.from != l.to {
            forward[l.from, default: []].append(l.to)
            backward[l.to, default: []].append(l.from)
            linkCount += 1
        }
        // Searched in a fixed order, so the path shown is the same every time.
        for k in forward.keys { forward[k]?.sort() }
        for k in backward.keys { backward[k]?.sort() }
    }

    /// The rack a channel feeds.
    ///
    /// `own` is the channel's own ports: the source the desk reports and the channel's own
    /// signal. The search goes back from them to everything that feeds them (the stage box
    /// input both the desk and the host take), then forward from all of those. One rack with an
    /// input in reach is the answer: that covers a host on the channel's direct out or insert, and
    /// a host fed the same input as the desk.
    public func rack(from own: [AudioPort], racks: [Int: [AudioPort]]) -> RoutingAnswer {
        var starts = Set(own)
        var stack = own.sorted()
        while let p = stack.popLast() {
            for q in backward[p] ?? [] where starts.insert(q).inserted { stack.append(q) }
        }
        var parent: [AudioPort: AudioPort] = [:]
        var seen = starts
        var queue = starts.sorted()
        var i = 0
        while i < queue.count {
            let p = queue[i]
            i += 1
            for q in forward[p] ?? [] where seen.insert(q).inserted {
                parent[q] = p
                queue.append(q)
            }
        }
        // The first input reached for each rack, in search order.
        let order = Dictionary(queue.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var reached: [Int: AudioPort] = [:]
        for (rack, inputs) in racks {
            if let p = inputs.filter({ seen.contains($0) }).min(by: { order[$0]! < order[$1]! }) { reached[rack] = p }
        }
        switch reached.count {
        case 0: return .none
        case 1:
            let (rack, input) = reached.first!
            var path = [input]
            while let p = parent[path[0]] { path.insert(p, at: 0) }
            return .rack(rack, path: path)
        default: return .several(reached.keys.sorted())
        }
    }
}

/// The Dante subscriptions in a preset Dante Controller saved (File › Save Preset).
public struct DantePreset: Codable, Equatable {
    /// The preset's own name.
    public var name: String
    /// Every device in it, in its order.
    public var devices: [String]
    /// Every subscription, from the transmit channel to the receive channel, by channel number.
    public var links: [PatchLink]
    /// Subscriptions whose transmit channel could not be numbered: its device is not in the preset,
    /// or has no transmit channel with that label. "Amp-1 in 3 ← Mix L@Desk".
    public var unresolved: [String]

    public init(name: String = "", devices: [String] = [], links: [PatchLink] = [], unresolved: [String] = []) {
        self.name = name
        self.devices = devices
        self.links = links
        self.unresolved = unresolved
    }
}

/// Routing's settings (the `routing` key in settings.json).
public struct RoutingSettings: Codable, Equatable {
    /// Find a channel's rack by routing before its name. Off by default.
    public var enabled = false
    /// The desk's name in the Dante preset: its ports there are the `desk` the desk reports.
    public var deskDante = ""
    /// The Dante device whose receive channel N is the plug-in host's input N, such as Dante
    /// Virtual Soundcard on the host's computer.
    public var hostDante = ""
    /// Declared runs, one per line (`PortRun`).
    public var runs: [String] = []
    /// The last Dante preset imported.
    public var dante: DantePreset?

    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, deskDante, hostDante, runs, dante }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        deskDante = (try? c.decodeIfPresent(String.self, forKey: .deskDante)) ?? ""
        hostDante = (try? c.decodeIfPresent(String.self, forKey: .hostDante)) ?? ""
        runs = (try? c.decodeIfPresent([String].self, forKey: .runs)) ?? []
        dante = try? c.decodeIfPresent(DantePreset.self, forKey: .dante)
    }

    /// Each run line that does not parse, with why.
    public var runErrors: [(line: String, why: String)] {
        runs.compactMap { line in
            do {
                _ = try PortRun.parse(line)
                return nil
            } catch {
                return (line, "\(error)")
            }
        }
    }

    /// Every link: the preset's subscriptions and the declared runs, with the desk's Dante name
    /// read as `desk`, and the host's Dante device's receive channels joined to the host's inputs.
    public var links: [PatchLink] {
        func alias(_ p: AudioPort) -> AudioPort {
            guard !deskDante.isEmpty, p.device.caseInsensitiveCompare(deskDante) == .orderedSame else { return p }
            var p = p
            p.device = AudioPort.desk
            return p
        }
        var declared: [PatchLink] = []
        for line in runs {
            if let run = try? PortRun.parse(line) { declared += run.links }
        }
        var out: [PatchLink] = (dante?.links ?? []) + declared
        out = out.map { PatchLink(from: alias($0.from), to: alias($0.to)) }
        if !hostDante.isEmpty {
            // Every receive channel of the host's Dante device that something reaches.
            var rx = Set<AudioPort>()
            for l in out where l.to.domain == .dante && l.to.side == .input
                && l.to.device.caseInsensitiveCompare(hostDante) == .orderedSame {
                rx.insert(l.to)
            }
            out += rx.sorted().map { PatchLink(from: $0, to: .hostInput($0.channel)) }
        }
        return out
    }
}
