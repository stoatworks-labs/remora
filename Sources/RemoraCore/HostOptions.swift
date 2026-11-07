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
