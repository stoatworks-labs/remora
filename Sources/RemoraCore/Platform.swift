import Foundation

/// What the engine and the modules need from the operating system. The core, the consoles and the
/// hosts reach the OS only through these, so they build anywhere Foundation does; RemoraApple's
/// `ApplePlatform` is macOS's.
public protocol Platform: AnyObject {
    /// A TCP connection to `host` that keeps reconnecting until stopped. Everything runs on `queue`.
    func tcp(host: String, port: UInt16, queue: DispatchQueue) -> TCPStream
    /// A TCP listener on `port` (0: any free port) that keeps trying to listen until stopped, for a
    /// host that dials Remora (SuperRack's ProLink). Everything runs on `queue`.
    func tcpListener(port: UInt16, queue: DispatchQueue) -> TCPListener
    /// Datagrams to `host` and `port`, and the ones that come back from there, for a desk that
    /// answers OSC over UDP (X32, Wing). Keeps trying until stopped. Everything runs on `queue`.
    func udp(host: String, port: UInt16, queue: DispatchQueue) -> UDPLink
    /// Remora's MIDI: one virtual source other apps listen to, and an input that hears every other
    /// source. Nil if the system would not make one.
    func midi(name: String) -> MIDILink?
    /// An OSC listener on UDP, not yet listening.
    func oscReceiver() -> OSCReceiver
}

public enum StreamState: Equatable {
    case stopped
    case connecting
    case connected
    case failed(String)
}

/// A TCP connection that keeps reconnecting until stopped.
public protocol TCPStream: AnyObject {
    var state: StreamState { get }
    var onState: ((StreamState) -> Void)? { get set }
    var onData: (([UInt8]) -> Void)? { get set }
    /// Call on the stream's queue.
    func start()
    /// Call on the stream's queue.
    func stop()
    /// Drops the connection and tries again after `delay`. Call on the stream's queue.
    func reconnect(after delay: TimeInterval, reason: String)
    func send(_ bytes: [UInt8])
}

extension TCPStream {
    /// Drops the connection and tries again in two seconds. Call on the stream's queue.
    public func reconnect(reason: String) { reconnect(after: 2, reason: reason) }
}

public enum ListenerState: Equatable {
    case stopped
    /// Listening on this port: the one asked for, or the one picked for 0.
    case listening(UInt16)
    /// Not listening, and trying again every two seconds: "TCP 50002 is in use by another program".
    case failed(String)
}

/// Takes TCP connections on one port, and keeps trying to listen until stopped.
public protocol TCPListener: AnyObject {
    var state: ListenerState { get }
    var onState: ((ListenerState) -> Void)? { get set }
    /// A peer connected. The handler owns the connection: it starts it, or closes it.
    var onConnection: ((TCPConnection) -> Void)? { get set }
    /// Call on the listener's queue.
    func start()
    /// Stops listening. Connections already handed over stay as they are. Call on the queue.
    func stop()
}

/// One connection a `TCPListener` took. Everything runs on the listener's queue.
public protocol TCPConnection: AnyObject {
    /// Where it came from, for logs: "169.254.136.158:52116".
    var peer: String { get }
    var onData: (([UInt8]) -> Void)? { get set }
    /// Called once when the peer or the network ends it: nil when the peer closed it, else why.
    /// Not called for a `close`.
    var onClose: ((String?) -> Void)? { get set }
    func start()
    func send(_ bytes: [UInt8])
    /// Sends `bytes`, if any, then closes.
    func close(after bytes: [UInt8])
}

/// Datagrams to one host and port, and the ones it sends back. UDP has no connection, so
/// `connected` only means the socket is ready: whether anything answers is the module's to judge.
public protocol UDPLink: AnyObject {
    var state: StreamState { get }
    var onState: ((StreamState) -> Void)? { get set }
    var onDatagram: (([UInt8]) -> Void)? { get set }
    /// Call on the link's queue.
    func start()
    /// Call on the link's queue.
    func stop()
    func send(_ bytes: [UInt8])
}

/// Where control changes go. The app's is a CoreMIDI virtual source; tests use a recorder.
public protocol CCSink: AnyObject {
    /// `channel` is 1–16.
    func sendCC(channel: Int, number: Int, value: Int)
}

/// Remora's MIDI port: CCs out to the host, and every MIDI event heard from other sources in.
public protocol MIDILink: CCSink {
    var name: String { get }
    /// Called on CoreMIDI's thread (or the platform's equivalent).
    var onEvent: ((MIDIEvent) -> Void)? { get set }
}

/// A MIDI 1.0 channel message from any source, for learning and running console/MIDI controls.
public struct MIDIEvent: Equatable {
    public enum Kind: String, Codable { case cc, note }
    public var source: String
    public var kind: Kind
    /// 1–16.
    public var channel: Int
    public var number: Int
    public var value: Int

    public init(source: String, kind: Kind, channel: Int, number: Int, value: Int) {
        self.source = source
        self.kind = kind
        self.channel = channel
        self.number = number
        self.value = value
    }
}

/// Listens for OSC over UDP.
public protocol OSCReceiver: AnyObject {
    /// Called on the receiver's own queue.
    var onMessage: ((OSC.Message) -> Void)? { get set }
    func start(port: UInt16) throws
    func stop()
}

/// A sink that drops everything: SuperRack's driver when there is no MIDI port.
public final class NullSink: CCSink {
    public init() {}
    public func sendCC(channel: Int, number: Int, value: Int) {}
}
