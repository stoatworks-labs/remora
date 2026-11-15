import Foundation
import RemoraCore

/// A Behringer X32 or Midas M32, or a Behringer Wing, over OSC (UDP), read-only, from Patrick-Gilles
/// Maillot's protocol documents (docs/PROTOCOL.md):
///
/// - Unofficial X32/M32 OSC Remote Protocol v4.09-02, for firmware 4.0 and later (the M32 is taken
///   to behave as the X32);
/// - WING Remote Protocols V3.0.5-1, for firmware 3.0.5 and later.
///
/// Neither has met a desk here: both are experimental. One Wing Compact user's report (2026-11-15)
/// is all the field evidence: input channels followed the selection and mix and matrix names came
/// through, but channels with custom link on showed no name, hence `WingLink`.
///
/// Remora asks; it never sets. An address sent with no arguments is a read on both desks, and
/// every message `BehringerOSC.isReadRequest` passes is one of a fixed list of addresses with no
/// arguments. Remora polls the selection rather than subscribing: an X32 pushes to four `/xremote`
/// clients and a Wing to one `/*s` subscription, and taking one could knock Companion or another
/// app off the desk.
public final class BehringerConsole: ConsoleLink {
    public var onState: ((ConsoleState) -> Void)?
    public var onNamesLink: ((Bool) -> Void)?
    public var onModel: ((String) -> Void)?
    public var onSelected: ((ConsoleChannel) -> Void)?
    public var onNames: (([ConsoleChannel: String]) -> Void)?
    public var onControl: ((ControlSource, Int32) -> Void)?

    public let family: BehringerOSC.Family
    private let queue = DispatchQueue(label: "remora.behringer")
    private let udp: UDPLink
    private var timer: DispatchSourceTimer?
    private var reported: ConsoleState = .stopped
    private var answered = false
    private var lastHeard = Date.distantPast
    private var lastAsked = Date.distantPast
    private var ticks = 0
    /// Name requests still to send, a few each tick so the desk is never flooded.
    private var pending: [String] = []
    /// Each channel's own name, as the desk answers it.
    private var ownNames: [ConsoleChannel: String] = [:]
    /// Wing: each channel's and aux's custom link and main input connection.
    private var links: [ConsoleChannel: BehringerOSC.WingLink] = [:]
    /// Wing: input source names, by the address they were read from.
    private var sourceNames: [String: String] = [:]
    /// Wing: the source names asked for in this round of names.
    private var roundSources: Set<String> = []
    /// The names last handed on, or about to be.
    private var names: [ConsoleChannel: String] = [:]
    private var selected: ConsoleChannel?
    private var flush: DispatchWorkItem?

    /// How often the selection is asked for.
    static let interval: TimeInterval = 0.2
    /// Name requests sent each tick.
    static let namesPerTick = 8
    /// Silence after which the desk counts as gone.
    static let silence: TimeInterval = 5

    public init(family: BehringerOSC.Family, host: String, port: UInt16? = nil, platform: Platform) {
        self.family = family
        udp = platform.udp(host: host, port: port ?? family.port, queue: queue)
        udp.onState = { [weak self] st in self?.socketState(st) }
        udp.onDatagram = { [weak self] bytes in self?.received(bytes) }
    }

    public func start() {
        queue.async {
            self.udp.start()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            udp.stop()
            answered = false
        }
    }

    // MARK: Sending (reads only)

    private func ask(_ address: String) {
        let m = BehringerOSC.request(address)
        // The one rule: only reads. Anything else is a bug.
        precondition(BehringerOSC.isReadRequest(m, family), "Remora sends only reads to a console")
        udp.send(m)
    }

    private func socketState(_ st: StreamState) {
        switch st {
        case .stopped: report(.stopped)
        case .connecting: report(.connecting)
        case .connected:
            report(.waitingForDesk)
            identify()
        case .failed(let why):
            answered = false
            onNamesLink?(false)
            report(.failed(why))
        }
    }

    private func identify() {
        lastAsked = Date()
        ask(family.identify)
    }

    private func tick() {
        guard udp.state == .connected else { return }
        ticks += 1
        if !answered {
            // Nothing heard yet: ask what the desk is every two seconds, and nothing else.
            if Date().timeIntervalSince(lastAsked) >= 2 { identify() }
            return
        }
        if Date().timeIntervalSince(lastHeard) > Self.silence {
            answered = false
            onNamesLink?(false)
            report(.failed("no answer from the desk for \(Int(Self.silence)) seconds"))
            identify()
            return
        }
        ask(family.selection)
        for _ in 0..<min(Self.namesPerTick, pending.count) { ask(pending.removeFirst()) }
        // Names again every 30 seconds, as on the other desks.
        if ticks % Int((30 / Self.interval).rounded()) == 0, pending.isEmpty { startRound() }
    }

    /// A round of names: every name, and on a Wing every link, with the linked sources' names
    /// asked as the links come back.
    private func startRound() {
        pending = BehringerOSC.reads(family)
        roundSources = []
    }

    private func report(_ s: ConsoleState) {
        guard s != reported else { return }
        reported = s
        onState?(s)
    }

    // MARK: Receiving

    /// For tests: a datagram as the desk would send it, handled on the link's queue.
    public func receiveForTesting(_ bytes: [UInt8]) { queue.sync { received(bytes) } }

    private func received(_ bytes: [UInt8]) {
        for m in OSC.parse(bytes) { handle(m) }
    }

    private func handle(_ m: OSC.Message) {
        lastHeard = Date()
        if !answered {
            // The first answer, or the first after a silence: live, and every name asked again.
            answered = true
            report(.live)
            onNamesLink?(true)
            startRound()
            ask(family.selection)
        }
        if m.address == family.identify {
            if let model = BehringerOSC.model(family, m.args) { onModel?(model) }
            return
        }
        if m.address == family.selection {
            guard let i = BehringerOSC.number(m.args), let ch = BehringerOSC.channel(family, selidx: i),
                  ch != selected else { return }
            selected = ch
            onSelected?(ch)
            return
        }
        if let ch = BehringerOSC.channel(family, nameAddress: m.address) {
            ownNames[ch] = Self.text(m.args)
            namesChanged()
            return
        }
        guard family == .wing else { return }
        if let (ch, field) = BehringerOSC.wingLink(address: m.address) {
            var link = links[ch] ?? BehringerOSC.WingLink()
            switch field {
            case .linked: link.linked = BehringerOSC.number(m.args).map { $0 != 0 }
            case .group: link.group = Self.text(m.args)
            case .index: link.index = BehringerOSC.number(m.args)
            }
            links[ch] = link
            // Each linked source's name once a round, as soon as a link points at it, so a rename
            // on the desk shows up like any other name.
            if let source = link.source, !roundSources.contains(source) {
                roundSources.insert(source)
                pending.insert(source, at: 0)
            }
            namesChanged()
            return
        }
        if BehringerOSC.isWingSourceName(m.address) {
            sourceNames[m.address] = Self.text(m.args) ?? ""
            namesChanged()
        }
    }

    /// The first string in an answer, trimmed, or nil if there is none or it is empty.
    private static func text(_ args: [OSC.Arg]) -> String? {
        let s = args.first { if case .string = $0 { return true } else { return false } }?.text
            .trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? nil : s
    }

    /// The names as the desk shows them: a Wing channel or aux with custom link on shows its input
    /// source's name, and its own stays empty. A source whose name isn't known yet, or is empty,
    /// leaves the channel's own name.
    private func namesChanged() {
        var now = ownNames
        for (ch, link) in links {
            guard let source = link.source, let name = sourceNames[source], !name.isEmpty else { continue }
            now[ch] = name
        }
        guard now != names else { return }
        names = now
        flush?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onNames?(self.names)
        }
        flush = w
        queue.asyncAfter(deadline: .now() + 0.2, execute: w)
    }
}

/// The OSC Remora uses on an X32/M32 and a Wing.
public enum BehringerOSC {
    public enum Family: String, CaseIterable {
        case x32, wing

        /// The desk's OSC port: X32 10023, Wing 2223.
        public var port: UInt16 { self == .x32 ? 10023 : 2223 }

        /// Says the desk is there, and what it is: `/info` (X32), `/?` (Wing).
        public var identify: String { self == .x32 ? "/info" : "/?" }

        /// The selected channel.
        public var selection: String { self == .x32 ? "/-stat/selidx" : "/$ctl/$stat/selidx" }
    }

    /// Every name Remora reads, with the channel it names. DCAs are left out: neither desk can
    /// select one.
    public static func names(_ f: Family) -> [(String, ConsoleChannel)] {
        var out: [(String, ConsoleChannel)] = []
        func add(_ count: Int, _ path: (Int) -> String, _ make: (Int) -> ConsoleChannel) {
            for n in 1...count { out.append((path(n), make(n))) }
        }
        switch f {
        case .x32:
            func nn(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
            add(32, { "/ch/\(nn($0))/config/name" }, ConsoleChannel.input)
            add(8, { "/auxin/\(nn($0))/config/name" }, ConsoleChannel.aux)
            add(8, { "/fxrtn/\(nn($0))/config/name" }, ConsoleChannel.fxReturn)
            add(16, { "/bus/\(nn($0))/config/name" }, ConsoleChannel.mix)
            add(6, { "/mtx/\(nn($0))/config/name" }, ConsoleChannel.matrix)
            out.append(("/main/st/config/name", .main(1)))
            out.append(("/main/m/config/name", .main(2)))
        case .wing:
            add(40, { "/ch/\($0)/name" }, ConsoleChannel.input)
            add(8, { "/aux/\($0)/name" }, ConsoleChannel.aux)
            add(16, { "/bus/\($0)/name" }, ConsoleChannel.mix)
            add(4, { "/main/\($0)/name" }, ConsoleChannel.main)
            add(8, { "/mtx/\($0)/name" }, ConsoleChannel.matrix)
        }
        return out
    }

    private static let nameIndex: [Family: [String: ConsoleChannel]] = Dictionary(uniqueKeysWithValues:
        Family.allCases.map { f in (f, Dictionary(uniqueKeysWithValues: names(f))) })

    public static func channel(_ f: Family, nameAddress a: String) -> ConsoleChannel? { nameIndex[f]?[a] }

    /// Every address Remora asks in a round of names: the names, and on a Wing each channel's and
    /// aux's link and input connection. Source names are asked once a link points at them.
    public static func reads(_ f: Family) -> [String] {
        names(f).map(\.0) + (f == .wing ? wingLinks.map(\.0) : [])
    }

    // MARK: Wing custom link

    /// A Wing channel or aux with custom link on (`clink`, "Link Customization to Source" on the
    /// desk) shows its input source's name, colour and icon, and its own `name` stays empty: the
    /// document's dump of `/ch/1` has `.conn.grp=LCL,in=1` … `.clink=1,col=1,name=`. So Remora
    /// reads the link and the main input connection too, and then the source's name.
    public struct WingLink: Equatable {
        public var linked: Bool?
        public var group: String?
        public var index: Int?

        public init(linked: Bool? = nil, group: String? = nil, index: Int? = nil) {
            self.linked = linked
            self.group = group
            self.index = index
        }

        /// The address of the name the channel shows, once the link is known to be on and points
        /// at a source that has a name. The alt input (`altgrp`, `altin`) isn't followed: the
        /// document doesn't say which one a linked channel shows while it is switched to alt.
        public var source: String? {
            guard linked == true, let group, let index else { return nil }
            return BehringerOSC.wingSourceName(group: group, index: index)
        }
    }

    public enum WingLinkField: Equatable { case linked, group, index }

    /// The link and main input connection of every channel (1–40) and aux (1–8).
    static let wingLinks: [(String, ConsoleChannel, WingLinkField)] = {
        var out: [(String, ConsoleChannel, WingLinkField)] = []
        let nodes: [(String, Int, (Int) -> ConsoleChannel)] = [("ch", 40, ConsoleChannel.input), ("aux", 8, ConsoleChannel.aux)]
        for (node, count, make) in nodes {
            for n in 1...count {
                out.append(("/\(node)/\(n)/clink", make(n), .linked))
                out.append(("/\(node)/\(n)/in/conn/grp", make(n), .group))
                out.append(("/\(node)/\(n)/in/conn/in", make(n), .index))
            }
        }
        return out
    }()

    private static let wingLinkIndex: [String: (ConsoleChannel, WingLinkField)] =
        Dictionary(uniqueKeysWithValues: wingLinks.map { ($0.0, ($0.1, $0.2)) })

    public static func wingLink(address a: String) -> (ConsoleChannel, WingLinkField)? { wingLinkIndex[a] }

    /// The input source groups under `/io/in` and how many sources each has (WING Remote Protocols
    /// V3.0.5-1). A channel can also take a bus, main or matrix (`BUS`, `MAIN`, `MTX`); those have
    /// no `/io/in` name, so a channel linked to one keeps its own.
    static let wingSourceGroups: [String: Int] = [
        "LCL": 24, "AUX": 8, "A": 48, "B": 48, "C": 48, "SC": 32, "USB": 48, "CRD": 64, "MOD": 64,
        "PLAY": 4, "AES": 2, "USR": 48, "OSC": 2,
    ]

    /// `/io/in/<group>/<index>/name`, or nil for a group or index the Wing doesn't have.
    public static func wingSourceName(group: String, index: Int) -> String? {
        guard let count = wingSourceGroups[group], (1...count).contains(index) else { return nil }
        return "/io/in/\(group)/\(index)/name"
    }

    private static let wingSourceNames: Set<String> = Set(wingSourceGroups.flatMap { group, count in
        (1...count).map { "/io/in/\(group)/\($0)/name" }
    })

    public static func isWingSourceName(_ a: String) -> Bool { wingSourceNames.contains(a) }

    /// The channel a `selidx` answer means.
    /// - X32, as documented: 0–31 channels, 32–39 aux ins, 40–47 FX returns (1L to 4R), 48–63
    ///   buses, 64–69 matrices, 70 main LR, 71 mono/centre.
    /// - Wing, inferred from the channel counts and not documented: 0–39 channels, 40–47 aux,
    ///   48–63 buses, 64–67 mains, 68–75 matrices.
    public static func channel(_ f: Family, selidx i: Int) -> ConsoleChannel? {
        switch (f, i) {
        case (.x32, 0...31): return .input(i + 1)
        case (.x32, 32...39): return .aux(i - 31)
        case (.x32, 40...47): return .fxReturn(i - 39)
        case (.x32, 48...63): return .mix(i - 47)
        case (.x32, 64...69): return .matrix(i - 63)
        case (.x32, 70...71): return .main(i - 69)
        case (.wing, 0...39): return .input(i + 1)
        case (.wing, 40...47): return .aux(i - 39)
        case (.wing, 48...63): return .mix(i - 47)
        case (.wing, 64...67): return .main(i - 63)
        case (.wing, 68...75): return .matrix(i - 67)
        default: return nil
        }
    }

    /// A number from an answer: the int if there is one (a Wing answers a get with a string, the
    /// raw float and the int), else a float, else a string that is a number.
    public static func number(_ args: [OSC.Arg]) -> Int? {
        for a in args { if case .int(let v) = a { return Int(v) } }
        for a in args { if case .float(let v) = a, v.isFinite { return Int(v.rounded()) } }
        for a in args { if case .string(let s) = a, let v = Int(s.trimmingCharacters(in: .whitespaces)) { return v } }
        return nil
    }

    /// The model from the answer to `identify`.
    /// - X32 `/info`: server version, server name, console model, console version ("X32C", "2.08").
    /// - Wing `/?`: one string, "WING,<ip>,<name>,<model>,<serial>,<firmware>", the model being
    ///   ngc-full (a Wing), wing-compact or wing-rack.
    public static func model(_ f: Family, _ args: [OSC.Arg]) -> String? {
        let strings = args.compactMap { a -> String? in if case .string(let s) = a { return s } else { return nil } }
        switch f {
        case .x32:
            guard strings.count >= 4 else { return strings.first }
            return "\(strings[2]) \(strings[3])"
        case .wing:
            guard let s = strings.first else { return nil }
            let p = s.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 6, p[0] == "WING" else { return s }
            let model: String
            switch p[3] {
            case "ngc-full": model = "Wing"
            case "wing-compact": model = "Wing Compact"
            case "wing-rack": model = "Wing Rack"
            default: model = p[3]
            }
            return "\(model) \(p[5].split(separator: "-").first.map(String.init) ?? p[5])"
        }
    }

    /// A read: the address, padded, and an empty type tag.
    public static func request(_ address: String) -> [UInt8] { OSC.encode(OSC.Message(address: address, args: [])) }

    private static let allowed: [Family: Set<String>] = Dictionary(uniqueKeysWithValues: Family.allCases.map { f in
        (f, Set(reads(f) + [f.identify, f.selection]).union(f == .wing ? wingSourceNames : []))
    })

    /// True only for what Remora may send: one of its addresses with no arguments, as `request`
    /// builds it (or with no type tag at all). On both desks an address with a value sets it, the
    /// X32's `/` with a string sets any node, and a Wing blob can carry a native command, so
    /// anything with an argument is refused, and so is any address not on the list: no
    /// `/xremote` or `/*s` (the push slots other apps use), no `/-action`, no `/-prefs`.
    public static func isReadRequest(_ m: [UInt8], _ f: Family) -> Bool {
        guard m.first == 0x2F, let end = m.firstIndex(of: 0) else { return false }
        let padded = (end / 4 + 1) * 4
        guard padded <= m.count, m[end..<padded].allSatisfy({ $0 == 0 }) else { return false }
        let address = String(decoding: m[..<end], as: UTF8.self)
        guard allowed[f]?.contains(address) == true else { return false }
        let rest = Array(m[padded...])
        return rest.isEmpty || rest == [0x2C, 0, 0, 0]
    }
}
