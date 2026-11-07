import Foundation

/// What the engine and the modules need from the operating system. The core, the consoles and the
/// hosts reach the OS only through these, so they build anywhere Foundation does; RemoraApple's
/// `ApplePlatform` is macOS's.
public protocol Platform: AnyObject {
    /// A TCP connection to `host` that keeps reconnecting until stopped. Everything runs on `queue`.
    func tcp(host: String, port: UInt16, queue: DispatchQueue) -> TCPStream
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
