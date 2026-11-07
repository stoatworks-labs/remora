import Foundation
import Network
import RemoraCore

/// Takes TCP connections on one port, for a host that dials Remora (SuperRack's ProLink), and
/// keeps trying to listen until stopped. Everything runs on `queue`.
final class TCPServer: TCPListener {
    let port: UInt16
    let queue: DispatchQueue
    var onState: ((ListenerState) -> Void)?
    var onConnection: ((TCPConnection) -> Void)?

    private var listener: NWListener?
    private var generation = 0
    private var running = false
    /// Tries since the start that failed without a word: a listener just stopped on the port lets
    /// it go a moment later, so the first few failures try again soon and say nothing.
    private var quietTries = 0
    private static let quietLimit = 4
    private(set) var state: ListenerState = .stopped {
        didSet { if state != oldValue { onState?(state) } }
    }

    init(port: UInt16, queue: DispatchQueue) {
        self.port = port
        self.queue = queue
    }

    /// Call on `queue`.
    func start() {
        guard !running else { return }
        running = true
        quietTries = 0
        listen()
    }

    /// Call on `queue`.
    func stop() {
        running = false
        generation += 1
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func listen() {
        generation += 1
        let g = generation
        let l: NWListener
        do {
            if port == 0 {
                l = try NWListener(using: .tcp)
            } else {
                guard let p = NWEndpoint.Port(rawValue: port) else {
                    state = .failed("no port")
                    return
                }
                l = try NWListener(using: .tcp, on: p)
            }
        } catch {
            retry(g, why: describe(error))
            return
        }
        listener = l
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, self.generation == g else { return }
            switch st {
            case .ready:
                self.state = .listening(l?.port?.rawValue ?? self.port)
            case .failed(let e), .waiting(let e):
                self.retry(g, why: self.describe(e))
            case .setup, .cancelled:
                break
            @unknown default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] c in
            guard let self, self.generation == g, let take = self.onConnection else {
                c.cancel()
                return
            }
            take(TCPServerConnection(c, queue: self.queue))
        }
        l.start(queue: queue)
    }

    /// Stops this try and listens again: every quarter of a second, unreported, for the first second
    /// after a start, then every two seconds.
    private func retry(_ g: Int, why: String) {
        guard running, generation == g else { return }
        generation += 1
        listener?.cancel()
        listener = nil
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

    private func describe(_ e: Error) -> String {
        if case .posix(let code)? = e as? NWError, code == .EADDRINUSE {
            return "TCP \(port) is in use by another program"
        }
        return "TCP \(port): \(e.localizedDescription)"
    }
}

/// One connection `TCPServer` took. Everything runs on the server's queue.
final class TCPServerConnection: TCPConnection {
    let peer: String
    var onData: (([UInt8]) -> Void)?
    var onClose: ((String?) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var started = false
    private var ended = false

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        peer = Self.describe(connection.endpoint)
    }

    deinit {
        if !ended { connection.cancel() }
    }

    func start() {
        guard !started, !ended else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed(let e), .waiting(let e): self?.end(e.localizedDescription)
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func send(_ bytes: [UInt8]) {
        guard started, !ended, !bytes.isEmpty else { return }
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    func close(after bytes: [UInt8]) {
        guard !ended else { return }
        ended = true
        onData = nil
        onClose = nil
        connection.stateUpdateHandler = nil
        if bytes.isEmpty {
            connection.cancel()
            return
        }
        if !started {
            started = true
            connection.start(queue: queue)
        }
        let c = connection
        c.send(content: Data(bytes), contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { _ in c.cancel() })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            if let data, !data.isEmpty { self.onData?([UInt8](data)) }
            if self.ended { return }
            if complete {
                self.end(nil)
            } else if let error {
                self.end(error.localizedDescription)
            } else {
                self.receive()
            }
        }
    }

    private func end(_ why: String?) {
        guard !ended else { return }
        ended = true
        let tell = onClose
        onData = nil
        onClose = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        tell?(why)
    }

    private static func describe(_ e: NWEndpoint) -> String {
        guard case .hostPort(let host, let port) = e else { return "\(e)" }
        switch host {
        case .ipv4(let a): return "\(a):\(port)"
        case .ipv6(let a): return "[\(a)]:\(port)"
        case .name(let n, _): return "\(n):\(port)"
        @unknown default: return "\(host):\(port)"
        }
    }
}
