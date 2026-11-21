import Foundation
import RemoraCore

/// Remora's state as OSC, so a Companion module can show what Remora knows instead of firing
/// blind (docs/ARCHITECTURE.md §3.1). The engine sends it to the state target set on the Companion
/// tab: what changed, as it changes, and all of it when asked (`query`) or when the target's
/// socket opens. A listener that starts after Remora hears only changes until it asks. One message
/// per datagram, never a bundle.
///
/// It reports, it never claims: a rack Remora only counted to, or sent a command for, says so.
public enum StateFeed {
    /// Sent to Remora's OSC port: everything is sent to the state target again.
    public static let query = "/remora/state/query"

    /// Every address the feed sends, in the order a full send goes out.
    public enum Address {
        /// `,ss` the host module's id ("superrack.midi") and its product ("SuperRack"); the product
        /// is empty for a host this build does not have.
        public static let host = "/remora/state/host"
        /// `,ss` how the module's own link to the host stands, and the same in words: `none` (a
        /// host with no link of its own, such as SuperRack over MIDI, or one that has not
        /// answered yet), `listening`, `connecting`, `connected` or `failed`.
        public static let link = "/remora/state/host/link"
        /// `,s` why the racks cannot be read or the host reached, empty when nothing is wrong.
        public static let problem = "/remora/state/host/problem"
        /// `,i` how many racks the host has.
        public static let rackCount = "/remora/state/racks/count"
        /// `,s…` every rack's name in the host's order: the nth is rack n. No arguments for none.
        public static let rackNames = "/remora/state/racks/names"
        /// `,iss` the rack the host is on (from 1; 0 when Remora doesn't know), its name (empty
        /// when unknown), and how Remora knows: `reported`, `seen`, `counted`, `sent` or `unknown`.
        public static let rack = "/remora/state/rack"
        /// `,i` 1 when Follow is on, 0 when off.
        public static let follow = "/remora/state/follow"

        public static let all = [host, link, problem, rackCount, rackNames, rack, follow]
    }

    /// What `rack` says when Remora doesn't know where the host is.
    public static let unknown = "unknown"

    /// Everything Remora would say now, in `Address.all`'s order.
    public static func messages(_ st: Bridge.Status, hostID: String, product: String?, follow: Bool) -> [OSC.Message] {
        let names = rackNames(st.racks)
        let at = st.position.map { p in
            (number: Int32(p.index + 1), name: st.racks.first { $0.index == p.index }?.name ?? "", how: p.basis.rawValue)
        } ?? (number: 0, name: "", how: unknown)
        return [
            OSC.Message(address: Address.host, args: [.string(hostID), .string(product ?? "")]),
            OSC.Message(address: Address.link, args: link(st.hostLink).map(OSC.Arg.string)),
            OSC.Message(address: Address.problem, args: [.string(st.sessionError ?? "")]),
            OSC.Message(address: Address.rackCount, args: [.int(Int32(names.count))]),
            OSC.Message(address: Address.rackNames, args: names.map(OSC.Arg.string)),
            OSC.Message(address: Address.rack, args: [.int(at.number), .string(at.name), .string(at.how)]),
            OSC.Message(address: Address.follow, args: [.int(follow ? 1 : 0)]),
        ]
    }

    /// The racks' names by index, so the nth is rack n. A rack number the host skipped (none has
    /// so far) gets an empty name rather than moving every later name down one.
    static func rackNames(_ racks: [Rack]) -> [String] {
        guard let last = racks.map(\.index).max(), last >= 0 else { return [] }
        var names = [String](repeating: "", count: last + 1)
        for r in racks where r.index >= 0 { names[r.index] = r.name }
        return names
    }

    /// The link's state word and its log line.
    static func link(_ l: HostLink?) -> [String] {
        guard let l else { return ["none", ""] }
        let word: String
        switch l {
        case .listening: word = "listening"
        case .connecting: word = "connecting"
        case .connected: word = "connected"
        case .failed: word = "failed"
        }
        return [word, Bridge.logLine(l)]
    }
}
