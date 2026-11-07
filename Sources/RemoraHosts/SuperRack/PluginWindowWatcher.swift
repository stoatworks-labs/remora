import Foundation
import RemoraCore

/// SuperRack's plug-in window guard and rack reader, as the platform has it (Accessibility on
/// macOS: `PluginWindowGuard`). The rules it keeps are AGENTS.md's: press only a plug-in window's
/// own Close, never minimise, never close a minimised or pinned window.
public protocol PluginWindowWatcher: RackNameReader {
    /// Called on the main queue.
    var onStatus: ((PluginWindowStatus) -> Void)? { get set }
    /// Called on the main queue when SuperRack should go to the overview and back to the Rack page
    /// (Return To Last Overview Tab, then Open Rack Tab), to show the new rack's plug-in.
    var onReopen: (() -> Void)? { get set }
    /// Changes what the guard does. Turning on anything for plug-in windows asks for Accessibility
    /// if Remora lacks it; reading the rack alone never asks.
    func set(_ options: PluginWindowOptions)
    /// The session's chains, for which plug-in each rack has selected.
    func setChains(_ chains: [RackChain])
    func stop()
}

/// A platform that can watch SuperRack's windows. One that cannot leaves the SuperRack modules
/// counting only, with no window rules.
public protocol PluginWindowPlatform: Platform {
    /// Watches this edition of SuperRack: its app, its main window and its log.
    func pluginWindowWatcher(for edition: SuperRackEdition) -> PluginWindowWatcher
}
