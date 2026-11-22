import Foundation
import RemoraCore

/// Platform services over BSD sockets: Winsock on Windows, POSIX elsewhere. It is Windows' platform
/// (docs/ARCHITECTURE.md §8): TCP, a TCP listener, UDP and an OSC receiver, each behaving as
/// RemoraApple's Network.framework classes do, so the modules can't tell them apart. It makes no
/// MIDI port yet. On macOS it is built only for its tests.
public final class SocketPlatform: Platform {
    public init() { Sock.startup() }

    public func tcp(host: String, port: UInt16, queue: DispatchQueue) -> TCPStream {
        SocketTCPStream(host: host, port: port, queue: queue)
    }

    public func tcpListener(port: UInt16, queue: DispatchQueue) -> TCPListener {
        SocketTCPListener(port: port, queue: queue)
    }

    public func udp(host: String, port: UInt16, queue: DispatchQueue) -> UDPLink {
        SocketUDPLink(host: host, port: port, queue: queue)
    }

    public func midi(name: String) -> MIDILink? { nil }

    public var midiUnavailable: String? {
        "Remora has no MIDI on \(ModuleInfo.OS.current.title) yet: MIDI hosts and SuperRack's MIDI module get nothing"
    }

    public func oscReceiver() -> OSCReceiver { SocketOSCReceiver() }
}

/// A TCP connection that keeps reconnecting until stopped, as RemoraApple's `TCPLink` does: a
/// refused connection is tried again after 3 s, any other failure or the peer's close after 2 s,
/// and the connect gives up after 4 s. Everything runs on `queue`.
final class SocketTCPStream: TCPStream {
    let host: String
    let port: UInt16
    let queue: DispatchQueue
    var onState: ((StreamState) -> Void)?
    var onData: (([UInt8]) -> Void)?

    private var dial: SocketDial?
    private var pump: SocketPump?
    private var generation = 0
    private var running = false
    private(set) var state: StreamState = .stopped {
        didSet { if state != oldValue { onState?(state) } }
    }

    init(host: String, port: UInt16, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.queue = queue
    }

    func start() {
        guard !running else { return }
        running = true
        connect()
    }

    func stop() {
        running = false
        generation += 1
        drop()
        state = .stopped
    }

    func reconnect(after delay: TimeInterval, reason: String) {
        guard running else { return }
        generation += 1
        drop()
        state = .failed(reason)
        let g = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.generation == g else { return }
            self.connect()
        }
    }

    func send(_ bytes: [UInt8]) { pump?.send(bytes) }

    private func drop() {
        dial?.cancel()
        dial = nil
        pump?.cancel()
        pump = nil
    }

    private func connect() {
        guard port != 0, !host.isEmpty else {
            state = .failed("no address")
            return
        }
        generation += 1
        let g = generation
        state = .connecting
        let d = SocketDial()
        dial = d
        d.run(host: host, port: port, kind: .stream, timeout: 4) { [weak self] result in
            guard let self else {
                if case .success(let h) = result { Sock.closeHandle(h) }
                return
            }
            self.queue.async { self.dialled(result, g) }
        }
    }

    private func dialled(_ result: Result<SocketHandle, Sock.Failure>, _ g: Int) {
        guard running, generation == g else {
            if case .success(let h) = result { Sock.closeHandle(h) }
            return
        }
        dial = nil
        switch result {
        case .success(let h):
            let p = SocketPump(handle: h, datagrams: false, onData: { [weak self] bytes in
                self?.queue.async {
                    guard let self, self.generation == g else { return }
                    self.onData?(bytes)
                }
            }, onEnd: { [weak self] why in
                self?.queue.async {
                    guard let self, self.generation == g else { return }
                    self.reconnect(reason: why ?? StreamState.closedByPeer)
                }
            })
            pump = p
            state = .connected
            p.start()
        case .failure(let f):
            reconnect(after: f.refused ? 3 : 2, reason: f.reason)
        }
    }
}

/// Takes TCP connections on one port, on every IPv4 interface, and keeps trying to listen until
/// stopped, as RemoraApple's `TCPServer` does: the first second's failures are tried again quietly
/// (a listener just stopped lets go of its port a moment later), then every two seconds, saying so.
final class SocketTCPListener: TCPListener {
    let port: UInt16
    let queue: DispatchQueue
    var onState: ((ListenerState) -> Void)?
    var onConnection: ((TCPConnection) -> Void)?

    private var acceptor: SocketAcceptor?
    private var generation = 0
    private var running = false
    private var quietTries = 0
    private static let quietLimit = 4
    private(set) var state: ListenerState = .stopped {
        didSet { if state != oldValue { onState?(state) } }
    }

    init(port: UInt16, queue: DispatchQueue) {
        self.port = port
        self.queue = queue
    }

    func start() {
        guard !running else { return }
        running = true
        quietTries = 0
        listen()
    }

    func stop() {
        running = false
        generation += 1
        acceptor?.cancel()
        acceptor = nil
        state = .stopped
    }

    private func listen() {
        generation += 1
        let g = generation
        switch Sock.listenTCP(port: port) {
        case .failure(let f):
            retry(g, why: describe(f))
        case .success(let (h, bound)):
            let a = SocketAcceptor(handle: h, onAccept: { [weak self] c in
                guard let self else {
                    Sock.closeHandle(c)
                    return
                }
                self.queue.async {
                    guard self.running, self.generation == g, let take = self.onConnection else {
                        Sock.closeHandle(c)
                        return
                    }
                    take(SocketConnection(handle: c, queue: self.queue))
                }
            }, onEnd: { [weak self] why in
                self?.queue.async { self?.retry(g, why: "TCP \(bound): \(why)") }
            })
            acceptor = a
            state = .listening(bound)
            a.start()
        }
    }

    private func retry(_ g: Int, why: String) {
        guard running, generation == g else { return }
        generation += 1
        acceptor?.cancel()
        acceptor = nil
        let delay: TimeInterval
        if quietTries < Self.quietLimit {
            quietTries += 1
            delay = 0.25
        } else {
            state = .failed(why)
            delay = 2
        }
        let next = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.generation == next else { return }
            self.listen()
        }
    }

    private func describe(_ f: Sock.Failure) -> String {
        Sock.isAddressInUse(f.code) ? "TCP \(port) is in use by another program" : "TCP \(port): \(f.reason)"
    }
}

/// One connection `SocketTCPListener` took. Everything runs on the listener's queue.
final class SocketConnection: TCPConnection {
    let peer: String
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?

    private let queue: DispatchQueue
    private var pump: SocketPump!
    private var started = false
    private var ended = false

    init(handle: SocketHandle, queue: DispatchQueue) {
        self.queue = queue
        peer = Sock.peerName(handle)
        pump = SocketPump(handle: handle, datagrams: false, onData: { [weak self] bytes in
            self?.queue.async {
                guard let self, !self.ended else { return }
                self.onData?(bytes)
            }
        }, onEnd: { [weak self] why in
            self?.queue.async { self?.end(why) }
        })
    }

    deinit {
        if !ended { pump.cancel() }
    }

    func start() {
        guard !started, !ended else { return }
        started = true
        pump.start()
    }

    func send(_ bytes: [UInt8]) {
        guard started, !ended, !bytes.isEmpty else { return }
        pump.send(bytes)
    }

    func close(after bytes: [UInt8]) {
        guard !ended else { return }
        ended = true
        onData = nil
        onClose = nil
        if bytes.isEmpty {
            pump.cancel()
            return
        }
        pump.send(bytes)
        pump.finish()
    }

    private func end(_ why: String?) {
        guard !ended else { return }
        ended = true
        let tell = onClose
        onData = nil
        onClose = nil
        pump.cancel()
        tell?(why)
    }
}

/// Datagrams to one host and port, and the ones that come back from there, as RemoraApple's
/// `UDPSocket`: a socket that fails (no route, or the host answers "port unreachable") is opened
/// again two seconds later, until stopped. Everything runs on `queue`.
final class SocketUDPLink: UDPLink {
    let host: String
    let port: UInt16
    let queue: DispatchQueue
    var onState: ((StreamState) -> Void)?
    var onDatagram: (([UInt8]) -> Void)?

    private var dial: SocketDial?
    private var pump: SocketPump?
    private var generation = 0
    private var running = false
    private(set) var state: StreamState = .stopped {
        didSet { if state != oldValue { onState?(state) } }
    }

    init(host: String, port: UInt16, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.queue = queue
    }

    func start() {
        guard !running else { return }
        running = true
        open()
    }

    func stop() {
        running = false
        generation += 1
        drop()
        state = .stopped
    }

    func send(_ bytes: [UInt8]) { pump?.send(bytes) }

    private func drop() {
        dial?.cancel()
        dial = nil
        pump?.cancel()
        pump = nil
    }

    private func open() {
        guard port != 0, !host.isEmpty else {
            state = .failed("no address")
            return
        }
        generation += 1
        let g = generation
        state = .connecting
        let d = SocketDial()
        dial = d
        d.run(host: host, port: port, kind: .datagram, timeout: 0) { [weak self] result in
            guard let self else {
                if case .success(let h) = result { Sock.closeHandle(h) }
                return
            }
            self.queue.async { self.opened(result, g) }
        }
    }

    private func opened(_ result: Result<SocketHandle, Sock.Failure>, _ g: Int) {
        guard running, generation == g else {
            if case .success(let h) = result { Sock.closeHandle(h) }
            return
        }
        dial = nil
        switch result {
        case .success(let h):
            let p = SocketPump(handle: h, datagrams: true, onData: { [weak self] bytes in
                self?.queue.async {
                    guard let self, self.generation == g else { return }
                    self.onDatagram?(bytes)
                }
            }, onEnd: { [weak self] why in
                self?.queue.async {
                    guard let self, self.generation == g else { return }
                    self.reopen(why: why ?? "closed")
                }
            })
            pump = p
            state = .connected
            p.start()
        case .failure(let f):
            reopen(why: f.reason)
        }
    }

    private func reopen(why: String) {
        guard running else { return }
        generation += 1
        drop()
        state = .failed(why)
        let g = generation
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running, self.generation == g else { return }
            self.open()
        }
    }
}

/// Listens for OSC over UDP, on every IPv4 interface. Messages come on the receiver's own queue.
public final class SocketOSCReceiver: OSCReceiver {
    public var onMessage: ((OSC.Message) -> Void)?
    private let queue = DispatchQueue(label: "remora.osc")
    private var pump: SocketPump?

    public init() {}

    /// Throws when the port can't be had: "UDP 9020: address already in use".
    public func start(port: UInt16) throws {
        stop()
        switch Sock.bindUDP(port: port) {
        case .failure(let f):
            throw Sock.Failure(code: f.code, reason: "UDP \(port): \(f.reason)")
        case .success(let h):
            let p = SocketPump(handle: h, datagrams: true, onData: { [weak self] bytes in
                self?.queue.async {
                    guard let self else { return }
                    OSC.parse(bytes).forEach { self.onMessage?($0) }
                }
            }, onEnd: { why in
                Log.line("OSC: listener failed: \(why ?? "closed")")
            })
            pump = p
            p.start()
        }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
    }
}
