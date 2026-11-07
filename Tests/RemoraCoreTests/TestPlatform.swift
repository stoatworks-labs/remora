import Foundation
@testable import RemoraApple
@testable import RemoraConsoles
@testable import RemoraCore
@testable import RemoraEngine
@testable import RemoraHosts

/// A platform that never connects: links made with it are fed by hand (`receiveForTesting`), and
/// what they would send is kept.
final class TestPlatform: Platform {
    private(set) var streams: [TestStream] = []
    private(set) var listeners: [TestListener] = []
    private(set) var udps: [TestUDP] = []
    /// The one OSC receiver it hands out, so a test can play messages into the engine.
    let osc = TestOSC()

    func tcp(host: String, port: UInt16, queue: DispatchQueue) -> TCPStream {
        let s = TestStream(host: host, port: port)
        streams.append(s)
        return s
    }

    func tcpListener(port: UInt16, queue: DispatchQueue) -> TCPListener {
        let l = TestListener(port: port, queue: queue)
        listeners.append(l)
        return l
    }

    func udp(host: String, port: UInt16, queue: DispatchQueue) -> UDPLink {
        let u = TestUDP(host: host, port: port, queue: queue)
        udps.append(u)
        return u
    }

    func midi(name: String) -> MIDILink? { nil }

    func oscReceiver() -> OSCReceiver { osc }
}

/// A UDP link that keeps what it would send, and takes datagrams by hand (`receive`).
final class TestUDP: UDPLink {
    let host: String
    let port: UInt16
    let queue: DispatchQueue
    var state: StreamState = .stopped
    var onState: ((StreamState) -> Void)?
    var onDatagram: (([UInt8]) -> Void)?
    private(set) var sent: [[UInt8]] = []

    init(host: String, port: UInt16, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.queue = queue
    }

    /// Ready at once, as a UDP socket is.
    func start() {
        state = .connected
        onState?(.connected)
    }
    func stop() { state = .stopped }
    func send(_ bytes: [UInt8]) { sent.append(bytes) }
    /// A datagram from the desk, on the link's queue.
    func receive(_ bytes: [UInt8]) { queue.sync { onDatagram?(bytes) } }
}

final class TestStream: TCPStream {
    let host: String
    let port: UInt16
    var state: StreamState = .stopped
    var onState: ((StreamState) -> Void)?
    var onData: (([UInt8]) -> Void)?
    private(set) var sent: [[UInt8]] = []

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func start() {}
    func stop() {}
    func reconnect(after delay: TimeInterval, reason: String) {}
    func send(_ bytes: [UInt8]) { sent.append(bytes) }
}

final class TestOSC: OSCReceiver {
    var onMessage: ((OSC.Message) -> Void)?
    func start(port: UInt16) throws {}
    func stop() {}
}

/// A listener a test dials by hand (`dial`). It listens as soon as it is started.
final class TestListener: TCPListener {
    let port: UInt16
    let queue: DispatchQueue
    var onState: ((ListenerState) -> Void)?
    var onConnection: ((TCPConnection) -> Void)?
    var state: ListenerState = .stopped {
        didSet { if state != oldValue { onState?(state) } }
    }
    /// What `start` does: listen, or fail as a port in use would.
    var failure: String?

    init(port: UInt16, queue: DispatchQueue) {
        self.port = port
        self.queue = queue
    }

    func start() { state = failure.map { .failed($0) } ?? .listening(port) }
    func stop() { state = .stopped }

    /// A peer connects; what it does next goes through the connection, on the listener's queue.
    func dial(from peer: String = "127.0.0.1:50100") -> TestConnection {
        let c = TestConnection(peer: peer, queue: queue)
        queue.sync { onConnection?(c) }
        return c
    }
}

/// The far end of a `TestListener`'s connection: what the near end sent, and the peer's moves.
final class TestConnection: TCPConnection {
    let peer: String
    let queue: DispatchQueue
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?
    private(set) var started = false
    private(set) var closed = false
    /// Every send, and a close's bytes, in order. Read on the queue (`frames` does).
    private(set) var sent: [[UInt8]] = []

    init(peer: String, queue: DispatchQueue) {
        self.peer = peer
        self.queue = queue
    }

    /// Each send and a close's bytes as they go, on the queue: the far end's ears.
    var onSend: (([UInt8]) -> Void)?

    func start() { started = true }
    func send(_ bytes: [UInt8]) {
        guard !closed else { return }
        sent.append(bytes)
        onSend?(bytes)
    }
    func close(after bytes: [UInt8]) {
        guard !closed else { return }
        if !bytes.isEmpty {
            sent.append(bytes)
            onSend?(bytes)
        }
        closed = true
    }

    /// The peer sends these bytes.
    func receive(_ bytes: [UInt8]) { queue.sync { onData?(bytes) } }

    /// The peer hangs up: nil for a clean close, or why the network ended it.
    func hangUp(_ why: String? = nil) { queue.sync { onClose?(why) } }

    /// Every frame sent so far.
    var frames: [ProLinkWire.Frame] {
        queue.sync {
            var p = ProLinkWire.Parser()
            return (try? p.feed(sent.flatMap { $0 })) ?? []
        }
    }

    /// The OSC messages among them.
    var messages: [ProLinkOSC.Message] {
        frames.compactMap { f in
            if case .osc(let b) = f { return ProLinkOSC.decode(b) } else { return nil }
        }
    }

    var isClosed: Bool { queue.sync { closed } }
}
