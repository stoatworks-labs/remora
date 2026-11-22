import Foundation
import RemoraCore
import RemoraHosts

/// macOS: Network.framework for TCP and UDP, a CoreMIDI virtual source, and Accessibility for
/// SuperRack's plug-in windows.
public final class ApplePlatform: Platform, PluginWindowPlatform {
    public init() {}

    public func tcp(host: String, port: UInt16, queue: DispatchQueue) -> TCPStream {
        TCPLink(host: host, port: port, queue: queue)
    }

    public func tcpListener(port: UInt16, queue: DispatchQueue) -> TCPListener {
        TCPServer(port: port, queue: queue)
    }

    public func udp(host: String, port: UInt16, queue: DispatchQueue) -> UDPLink {
        UDPSocket(host: host, port: port, queue: queue)
    }

    public func midi(name: String) -> MIDILink? { MIDIEndpoint(name: name) }

    public func oscReceiver() -> OSCReceiver { OSCListener() }

    /// App Nap off and timers precise, while idle system sleep stays the user's to set.
    public func stayAwake(reason: String) -> AwakeHold? { ProcessActivity(reason: reason) }

    public func pluginWindowWatcher(for edition: SuperRackEdition) -> PluginWindowWatcher {
        PluginWindowGuard(edition: edition)
    }
}

/// A `ProcessInfo` activity, held until `end()`.
final class ProcessActivity: AwakeHold {
    private var token: NSObjectProtocol?

    init(reason: String) {
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: reason)
    }

    func end() {
        if let t = token { ProcessInfo.processInfo.endActivity(t) }
        token = nil
    }

    deinit { end() }
}
