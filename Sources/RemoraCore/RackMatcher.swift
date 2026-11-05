import Foundation

/// Finds the rack for a console channel by name.
///
/// Names are compared lower-case with everything but letters and digits removed, so "head1"
/// finds "head 1". A channel that is a rack's name plus a number finds that rack when no other
/// rack has the name: "lec 1" and "lec 2" both find "Lec". Racks named "n/a" or nothing are
/// never matched.
public enum RackMatcher {
    public static func normalise(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    public static func match(_ channelName: String, in racks: [Rack]) -> Rack? {
        let n = normalise(channelName)
        guard !n.isEmpty else { return nil }
        let usable = racks.filter { let r = normalise($0.name); return !r.isEmpty && r != "na" }
        if let r = usable.first(where: { normalise($0.name) == n }) { return r }
        let stem = String(n.reversed().drop(while: { $0.isNumber }).reversed())
        guard !stem.isEmpty, stem != n else { return nil }
        let candidates = usable.filter { normalise($0.name) == stem }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
