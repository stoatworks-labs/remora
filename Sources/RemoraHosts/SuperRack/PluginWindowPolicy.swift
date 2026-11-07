#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import RemoraCore

/// A third-party plug-in's window in SuperRack Performer, as Remora sees it.
public struct PluginWindow: Equatable {
    /// SuperRack titles them "<rack>: <plug-in>", e.g. "head 1: De-Feedback".
    public var title: String
    /// SuperRack's own pin (the pin in the window's title bar). Remora never closes a pinned window.
    public var pinned: Bool
    /// When Remora first saw it open. Distant past for windows open before Remora looked.
    public var appeared: Date
    /// In the Dock rather than on screen: minimised by hand, as Remora never minimises one.
    public var minimised: Bool

    public init(title: String, pinned: Bool = false, appeared: Date = .distantPast, minimised: Bool = false) {
        self.title = title
        self.pinned = pinned
        self.appeared = appeared
        self.minimised = minimised
    }
}

/// What SuperRack does on its own (15.15.12.13, docs/PROTOCOL.md): selecting another third-party
/// plug-in swaps its unpinned window for the new one. Selecting a Waves plug-in, moving to another
/// rack or leaving the Rack page leaves the window open. These rules close it then.
public enum PluginWindowPolicy {
    public enum Change: Equatable, CustomStringConvertible {
        /// The rack SuperRack now shows, by name.
        case rack(String)
        /// The page now shown, as SuperRack's log names it (RACK, OVERVIEW1, SETUP …).
        case page(String)
        /// A plug-in selected on a rack (Waves or third-party).
        case plugin(rack: String, plugin: String)
        /// A plug-in window opened.
        case opened(title: String)

        public var description: String {
            switch self {
            case .rack(let r): return "rack is now \(r)"
            case .page(let p): return "page is now \(p)"
            case .plugin(let r, let p): return "\(r): \(p) selected"
            case .opened(let t): return "\(t) opened"
            }
        }
    }

    public static func title(rack: String, plugin: String) -> String { "\(rack): \(plugin)" }

    /// Whether a window `toClose` picked may be closed. SuperRack's Close on a minimised plug-in
    /// window takes the plug-in out of the rack and leaves its window in the Dock, empty
    /// (15.15.12.13, 2026-11-06), so a minimised window is never closed.
    public static func canClose(_ w: PluginWindow) -> Bool { !w.minimised }

    /// Whether to hide SuperRack, as ⌘H does: another app in front, SuperRack not hidden already,
    /// and a plug-in window on screen. The windows float over every app (the modal-panel level)
    /// even with SuperRack behind. Hiding the app takes them all down, pinned or not, and puts
    /// nothing in the Dock. Minimising each one did, and a Close on a minimised window (a
    /// right-click on its tile, or SuperRack's own) took the plug-in out of the rack. Switching back
    /// to SuperRack shows it again.
    public static func hidesSuperRack(_ windows: [PluginWindow], superRackInFront front: Bool,
                                      superRackHidden hidden: Bool) -> Bool {
        !front && !hidden && windows.contains { !$0.minimised }
    }

    /// The indices of the windows to close after a change made at `time`: unpinned, already open
    /// when it happened, and not what the change now shows. A window that opened after the change
    /// is never closed for it.
    public static func toClose(_ windows: [PluginWindow], after change: Change, at time: Date) -> [Int] {
        windows.indices.filter { i in
            let w = windows[i]
            guard !w.pinned, w.appeared < time else { return false }
            switch change {
            case .rack(let r): return !w.title.hasPrefix(r + ": ")
            case .page(let p): return p != "RACK"
            case .plugin(let r, let p): return w.title != title(rack: r, plugin: p)
            case .opened(let t): return w.title != t
            }
        }
    }

    /// The third-party plug-in to show after a move to `rack`, if its selected plug-in is one.
    /// `live` is the plug-in SuperRack's log last said was selected there, which is fresher than the
    /// session database. Racks sharing a name ("n/a") count only if they all agree.
    public static func reopenTarget(rack: String, chains: [RackChain], live: String?) -> ChainPlugin? {
        let named = chains.filter { $0.name == rack }
        guard !named.isEmpty else { return nil }
        let pick: ChainPlugin?
        if let live {
            let all = named.flatMap(\.plugins) + chains.flatMap(\.plugins)
            pick = all.first { $0.name == live }
        } else {
            let selected = named.map(\.selected)
            guard let first = selected.first ?? nil,
                  selected.allSatisfy({ $0?.name == first.name }) else { return nil }
            pick = first
        }
        guard let p = pick, !p.isWaves else { return nil }
        return p
    }

    /// The six page tabs of SuperRack's top bar, left to right, as its log names them.
    public static let pages = ["OVERVIEW1", "OVERVIEW2", "RACK", "SHOW", "PATCH", "SETUP"]

    /// Where a plug-in window goes to sit over the Rack page's plug-in area, given SuperRack's main
    /// window. The area was measured at SuperRack's default size (main window 1850 × 1034 points):
    /// 328 points in from the left, 127 down from the top, 504 short of the right, 3 short of the
    /// bottom. Centred across the area and at its top; a window wider than the area starts at its left.
    public static func placement(of size: CGSize, inMainWindow main: CGRect) -> CGPoint {
        let area = CGRect(x: main.minX + 328, y: main.minY + 127,
                          width: max(0, main.width - 328 - 504), height: max(0, main.height - 127 - 3))
        let x = size.width < area.width ? area.minX + ((area.width - size.width) / 2).rounded() : area.minX
        return CGPoint(x: x, y: area.minY)
    }
}
