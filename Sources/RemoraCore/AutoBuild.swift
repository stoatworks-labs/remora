import Foundation

// Auto build (docs/ARCHITECTURE.md §12): the desk's channels and buses, picked by the user, become
// a plan for a SuperRack session (a rack each, its inputs and outputs, and a template rack's
// plug-ins) and a patch sheet for the desk. Stage A only plans: nothing here writes a SuperRack
// session, and nothing is sent to the desk, Dante or SuperRack.

/// A strip on the desk auto build can give a rack: a channel or a bus, with the name the desk
/// gives it. A stereo input pair is one strip, keyed by its left half.
public struct BuildStrip: Equatable, Hashable {
    public var channel: ConsoleChannel
    public var name: String
    public var stereo: Bool
    public init(channel: ConsoleChannel, name: String, stereo: Bool = false) {
        self.channel = channel
        self.name = name
        self.stereo = stereo
    }
}

/// A rack in a template session: its plug-ins are what a built rack would start with, and its
/// words pick it for a channel by name.
public struct BuildTemplate: Equatable, Hashable {
    public var name: String
    /// For the sheet: the plug-ins in the template rack, in order.
    public var plugins: [String]
    /// Lowercased. A channel whose name has one of these words gets this template.
    public var words: [String]

    /// `extraWords`: the user's, beside the template's own name's words.
    public init(name: String, plugins: [String] = [], extraWords: [String] = []) {
        self.name = name
        self.plugins = plugins
        var w = AutoBuild.words(in: name)
        for x in extraWords.flatMap(AutoBuild.words(in:)) where !w.contains(x) { w.append(x) }
        words = w
    }
}

/// How the desk feeds SuperRack, for the patch sheet.
public enum BuildFeed: String, Codable, CaseIterable {
    /// The channel's insert: send to SuperRack, return from it. SuperRack is in the signal path.
    case insert
    /// The channel's direct out to SuperRack; SuperRack's outputs come back to spare desk inputs.
    case directOut
}

public struct BuildOptions: Codable, Equatable {
    public var feed: BuildFeed = .insert
    /// SuperRack's input the first rack takes, from 1. Each rack takes the next one, or two for a
    /// stereo strip.
    public var firstInput = 1
    /// SuperRack's output the first rack sends to, from 1.
    public var firstOutput = 1
    /// Where the desk sends to SuperRack and hears it back: the patch sheet's ports.
    public var deskDomain: AudioPort.Domain = .dante
    /// The desk's first port in that domain, from 1.
    public var deskFirstPort = 1

    public init() {}

    enum CodingKeys: String, CodingKey { case feed, firstInput, firstOutput, deskDomain, deskFirstPort }

    /// Each field reads on its own: one of the wrong type is dropped, not the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BuildOptions()
        feed = (try? c.decodeIfPresent(BuildFeed.self, forKey: .feed)) ?? d.feed
        firstInput = (try? c.decodeIfPresent(Int.self, forKey: .firstInput)) ?? d.firstInput
        firstOutput = (try? c.decodeIfPresent(Int.self, forKey: .firstOutput)) ?? d.firstOutput
        deskDomain = (try? c.decodeIfPresent(AudioPort.Domain.self, forKey: .deskDomain)) ?? d.deskDomain
        deskFirstPort = (try? c.decodeIfPresent(Int.self, forKey: .deskFirstPort)) ?? d.deskFirstPort
    }
}

/// Auto build's choices, as settings.json's `autoBuild` key holds them (written only once they
/// differ from the default).
public struct AutoBuildSettings: Codable, Equatable {
    /// The channel keys to build racks for. The plan takes them in the desk's order.
    public var include: [String] = []
    /// A channel key → stereo (true) or mono (false), where the user changed what the desk says.
    public var stereo: [String: Bool] = [:]
    /// A channel key → the template it gets; "" for an empty rack. A channel not here gets the
    /// template its name picks.
    public var template: [String: String] = [:]
    /// A template's name → more words that pick it, beside its own name's.
    public var words: [String: [String]] = [:]
    /// A SuperRack session the user saved, whose racks are the templates. Read from a copy, as
    /// the current session is.
    public var templateSession = ""
    public var options = BuildOptions()

    public init() {}

    enum CodingKeys: String, CodingKey { case include, stereo, template, words, templateSession, options }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        include = (try? c.decodeIfPresent([String].self, forKey: .include)) ?? []
        stereo = (try? c.decodeIfPresent([String: Bool].self, forKey: .stereo)) ?? [:]
        template = (try? c.decodeIfPresent([String: String].self, forKey: .template)) ?? [:]
        words = (try? c.decodeIfPresent([String: [String]].self, forKey: .words)) ?? [:]
        templateSession = (try? c.decodeIfPresent(String.self, forKey: .templateSession)) ?? ""
        options = (try? c.decodeIfPresent(BuildOptions.self, forKey: .options)) ?? BuildOptions()
    }

    /// The templates a session's racks give, each with the user's words.
    public func templates(_ racks: [(name: String, plugins: [String])]) -> [BuildTemplate] {
        racks.map { BuildTemplate(name: $0.name, plugins: $0.plugins, extraWords: words[$0.name] ?? []) }
    }
}

/// How a planned rack got its template.
public enum TemplatePick: Equatable {
    /// The user picked it for this channel.
    case chosen
    /// The channel's name has one of the template's words.
    case byName(word: String)
    /// No template: the user chose an empty rack, or nothing matched.
    case none
}

/// One rack of the session auto build would make.
public struct PlannedRack: Equatable {
    /// SuperRack's rack order, from 0.
    public var index: Int
    /// The rack's name: the desk's, made unique in the session.
    public var name: String
    public var channel: ConsoleChannel
    /// The name the desk gives the channel, as it is.
    public var deskName: String
    public var stereo: Bool
    /// The template rack whose plug-ins this rack starts with; nil for an empty rack.
    public var template: String?
    public var pick: TemplatePick
    /// SuperRack's device inputs and outputs, from 1.
    public var hostInputs: [Int]
    public var hostOutputs: [Int]
    /// Where the desk sends the channel (an insert send or a direct out), on the desk's ports.
    public var deskSends: [AudioPort]
    /// Where the desk hears the rack back: the insert return, or a spare input for a direct out.
    public var deskReturns: [AudioPort]
}

public struct BuildPlan: Equatable {
    public var racks: [PlannedRack] = []
    public var feed: BuildFeed = .insert
    /// What the plan couldn't do, in words: too many racks, a template that isn't there.
    public var problems: [String] = []
    public init() {}
}

public enum AutoBuild {
    /// A SuperRack session has 64 rack slots (`config_info`, docs/PROTOCOL.md).
    public static let maxRacks = 64

    // MARK: The desk's strips

    /// The strips the desk's names give, in the desk's order. A Yamaha ST IN's two halves are one
    /// stereo strip, named for its left half without the "L"; a stereo input (a Qu's ST) is
    /// stereo. Everything else is mono until the user says otherwise: no desk reports its stereo
    /// links yet.
    public static func strips(from names: [ConsoleChannel: String]) -> [BuildStrip] {
        var out: [BuildStrip] = []
        for (ch, name) in names.sorted(by: { $0.key < $1.key }) {
            switch ch {
            case .stereoIn(let n, let right):
                if right {
                    // Its left half makes the strip; a lone right half stands for both.
                    if names[.stereoIn(n, right: false)] == nil {
                        out.append(BuildStrip(channel: ch, name: dropSide(name), stereo: true))
                    }
                } else {
                    let r = names[.stereoIn(n, right: true)]
                    out.append(BuildStrip(channel: ch, name: r == nil ? name : dropSide(name), stereo: true))
                }
            case .stereo: out.append(BuildStrip(channel: ch, name: name, stereo: true))
            default: out.append(BuildStrip(channel: ch, name: name))
            }
        }
        return out
    }

    /// "OH L" → "OH", "Kbd-R" → "Kbd"; "CL" stays, as the L isn't set apart.
    public static func dropSide(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard t.count > 2, let last = t.last, "LRlr".contains(last) else { return t }
        let before = t[t.index(t.endIndex, offsetBy: -2)]
        guard " -_".contains(before) else { return t }
        return String(t.dropLast(2)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Templates

    /// A name's words, lowercased, split at anything that isn't a letter or a digit and between
    /// letters and digits: "Vox1" → vox, "BV 2" → bv. Numbers and single letters are dropped.
    public static func words(in name: String) -> [String] {
        var words: [String] = [], cur = ""
        var curIsDigit = false
        func flush() {
            if cur.count >= 2, !curIsDigit, !words.contains(cur) { words.append(cur) }
            cur = ""
        }
        for ch in name.lowercased() {
            guard ch.isLetter || ch.isNumber else { flush(); continue }
            if !cur.isEmpty, ch.isNumber != curIsDigit { flush() }
            curIsDigit = ch.isNumber
            cur.append(ch)
        }
        flush()
        return words
    }

    /// The template a channel's name picks: the name's words in order, the first that a template
    /// has (in the templates' order). A template's word picks a name's word that is the same, or
    /// that starts with it when it has three letters or more ("gtr" picks "gtrs").
    public static func pick(_ name: String, in templates: [BuildTemplate]) -> (template: BuildTemplate, word: String)? {
        for w in words(in: name) {
            for t in templates {
                if let tw = t.words.first(where: { $0 == w || ($0.count >= 3 && w.hasPrefix($0)) }) { return (t, tw) }
            }
        }
        return nil
    }

    // MARK: The plan

    /// The racks for the strips the settings include, in the desk's order: each named for its
    /// strip (unique in the session), on the next SuperRack inputs and outputs and the desk's next
    /// ports, with its template. Racks past `maxRacks` are left out and said so.
    public static func plan(strips: [BuildStrip], settings: AutoBuildSettings, templates: [BuildTemplate]) -> BuildPlan {
        var plan = BuildPlan()
        let o = settings.options
        plan.feed = o.feed
        let wanted = Set(settings.include)
        let onDesk = Set(strips.map(\.channel.key))
        let gone = settings.include.filter { !onDesk.contains($0) }
        if !gone.isEmpty {
            plan.problems.append("Not on the desk now, so left out: \(gone.joined(separator: ", ")).")
        }
        var picked = strips.filter { wanted.contains($0.channel.key) }
        if picked.count > maxRacks {
            let left = picked[maxRacks...].map { $0.channel.description }
            plan.problems.append("A SuperRack session has \(maxRacks) racks: \(picked.count) picked, so \(left.count) left out (\(left.joined(separator: ", "))).")
            picked = Array(picked.prefix(maxRacks))
        }
        var input = max(o.firstInput, 1), output = max(o.firstOutput, 1), port = max(o.deskFirstPort, 1)
        var used: Set<String> = []
        for (i, s) in picked.enumerated() {
            let key = s.channel.key
            let stereo = settings.stereo[key] ?? s.stereo
            let width = stereo ? 2 : 1
            var name = s.name.trimmingCharacters(in: .whitespaces)
            // A name the rack matcher can't read ("--") would find no rack.
            if RackMatcher.normalise(name).isEmpty { name = s.channel.description }
            name = unique(name, in: &used)

            var template: String?
            var how = TemplatePick.none
            if let chosen = settings.template[key] {
                if chosen.isEmpty {
                    how = .none
                } else if templates.contains(where: { $0.name == chosen }) {
                    template = chosen
                    how = .chosen
                } else {
                    plan.problems.append("\(s.channel.description) (\(name)): the template “\(chosen)” isn't in the template session, so its rack is empty.")
                }
            } else if let p = pick(s.name, in: templates) {
                template = p.template.name
                how = .byName(word: p.word)
            }

            let ins = Array(input..<(input + width)), outs = Array(output..<(output + width))
            let ports = Array(port..<(port + width))
            plan.racks.append(PlannedRack(
                index: i, name: name, channel: s.channel, deskName: s.name, stereo: stereo,
                template: template, pick: how, hostInputs: ins, hostOutputs: outs,
                deskSends: ports.map { AudioPort(AudioPort.desk, o.deskDomain, .output, $0) },
                deskReturns: ports.map { AudioPort(AudioPort.desk, o.deskDomain, .input, $0) }))
            input += width
            output += width
            port += width
        }
        return plan
    }

    /// `name`, or "name 2", "name 3"… if the session has it already (names compared as the rack
    /// matcher compares them, so the channel still finds its rack).
    static func unique(_ name: String, in used: inout Set<String>) -> String {
        var candidate = name, n = 2
        while used.contains(RackMatcher.normalise(candidate)) {
            candidate = "\(name) \(n)"
            n += 1
        }
        used.insert(RackMatcher.normalise(candidate))
        return candidate
    }

    /// Whether a folder is Waves' own, where SuperRack keeps its sessions: auto build writes
    /// nothing there (AGENTS.md: SuperRack's files are read-only).
    public static func isWavesFolder(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath.lowercased() + "/"
        return ["/users/shared/waves/", "c:\\users\\public\\waves\\", "c:/users/public/waves/"].contains { p.hasPrefix($0) }
    }

    // MARK: The patch sheet

    /// "1" or "1–2".
    public static func range(_ n: [Int]) -> String {
        guard let a = n.first, let b = n.last else { return "" }
        return a == b ? "\(a)" : "\(a)–\(b)"
    }

    /// A desk port run without the device: "dante out 1–2".
    public static func ports(_ p: [AudioPort]) -> String {
        guard let f = p.first else { return "" }
        let domain = f.domain == .other ? "" : "\(f.domain.rawValue) "
        return "\(domain)\(f.side.rawValue) \(range(p.map(\.channel)))"
    }

    static func feedWords(_ f: BuildFeed) -> (send: String, back: String) {
        switch f {
        case .insert: return ("Insert send", "Insert return")
        case .directOut: return ("Direct out", "Return to a spare input")
        }
    }

    /// The patch sheet as CSV, a rack a row.
    public static func patchSheetCSV(_ plan: BuildPlan) -> String {
        let f = feedWords(plan.feed)
        var rows = [["Rack", "Name", "Channel", "Desk name", "Width", "Template", f.send, "SuperRack in",
                     "SuperRack out", f.back]]
        for r in plan.racks {
            rows.append(["\(r.index + 1)", r.name, r.channel.description, r.deskName, r.stereo ? "stereo" : "mono",
                         r.template ?? "", ports(r.deskSends), range(r.hostInputs), range(r.hostOutputs),
                         ports(r.deskReturns)])
        }
        return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func csvField(_ s: String) -> String {
        guard s.contains(where: { ",\"\n\r".contains($0) }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The patch sheet as plain text, to print or read: a heading, then a rack a line.
    public static func patchSheetText(_ plan: BuildPlan, desk: String, date: Date? = nil) -> String {
        let f = feedWords(plan.feed)
        var lines = ["Remora auto build: patch sheet"]
        var about = "Desk: \(desk)"
        if let date {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_GB")
            df.dateFormat = "yyyy-MM-dd HH:mm"
            about += "    \(df.string(from: date))"
        }
        lines.append(about)
        lines.append(plan.feed == .insert
                     ? "Feed: each channel's insert, sent to SuperRack and returned from it."
                     : "Feed: each channel's direct out to SuperRack; SuperRack's outputs come back to spare inputs.")
        lines.append("Remora doesn't patch the desk, Dante or SuperRack: patch each row yourself.")
        lines.append("")
        let header = ["Rack", "Channel", "Name", "Width", "Template", f.send, "SuperRack in", "SuperRack out", f.back]
        var table = [header]
        for r in plan.racks {
            table.append(["\(r.index + 1)", r.channel.description, r.name, r.stereo ? "stereo" : "mono",
                          r.template ?? "(empty)", ports(r.deskSends), range(r.hostInputs), range(r.hostOutputs),
                          ports(r.deskReturns)])
        }
        let widths = header.indices.map { c in table.map { $0[c].count }.max() ?? 0 }
        for row in table {
            lines.append(row.enumerated().map { c, v in v.padding(toLength: widths[c], withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
        if plan.racks.isEmpty { lines.append("(no racks: pick some channels)") }
        if !plan.problems.isEmpty {
            lines.append("")
            lines.append(contentsOf: plan.problems.map { "! \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The plan as JSON, for `--auto-build` and for the build stage to come: channels by key.
    public static func json(_ plan: BuildPlan, desk: String) -> Data {
        struct Row: Encodable {
            var rack: Int, name: String, channel: String, channelName: String, deskName: String
            var stereo: Bool, template: String?, templateBy: String, superRackInputs: [Int]
            var superRackOutputs: [Int], deskSends: [String], deskReturns: [String]
        }
        struct Doc: Encodable {
            var remoraAutoBuild = 1
            var desk: String, feed: String, racks: [Row], problems: [String]
        }
        let rows = plan.racks.map { r -> Row in
            let by: String
            switch r.pick {
            case .chosen: by = "chosen"
            case .byName(let w): by = "name: \(w)"
            case .none: by = "none"
            }
            return Row(rack: r.index + 1, name: r.name, channel: r.channel.key, channelName: r.channel.description,
                       deskName: r.deskName, stereo: r.stereo, template: r.template, templateBy: by,
                       superRackInputs: r.hostInputs, superRackOutputs: r.hostOutputs,
                       deskSends: r.deskSends.map(\.description), deskReturns: r.deskReturns.map(\.description))
        }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(Doc(desk: desk, feed: plan.feed.rawValue, racks: rows, problems: plan.problems))) ?? Data()
    }
}
