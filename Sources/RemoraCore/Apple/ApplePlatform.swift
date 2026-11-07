import Foundation

/// macOS: Network.framework for TCP and UDP, a CoreMIDI virtual source, and Accessibility for
/// SuperRack's plug-in windows.
public final class ApplePlatform: Platform, PluginWindowPlatform {
    public init() {}

    public func tcp(host: String, port: UInt16, queue: DispatchQueue) -> TCPStream {
        TCPLink(host: host, port: port, queue: queue)
    }

    public func midi(name: String) -> MIDILink? { MIDIEndpoint(name: name) }

    public func oscReceiver() -> OSCReceiver { OSCListener() }

    public func pluginWindowWatcher() -> PluginWindowWatcher { PluginWindowGuard() }
}
