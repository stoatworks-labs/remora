import Foundation
import Network
import RemoraCore

/// A TCP connection that keeps reconnecting until stopped. Everything runs on `queue`.
final class TCPLink: TCPStream {
    typealias State = StreamState

    let host: String
    let port: UInt16
    let queue: DispatchQueue
    var onState: ((State) -> Void)?
    var onData: (([UInt8]) -> Void)?

    private var connection: NWConnection?
    private var generation = 0
    private var running = false
    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onState?(state) } }
    }

    init(host: String, port: UInt16, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.queue = queue
    }

    /// Call on `queue`.
    func start() {
        guard !running else { return }
        running = true
        connect()
    }

    /// Call on `queue`.
    func stop() {
        running = false
        generation += 1
        connection?.cancel()
        connection = nil
        state = .stopped
    }

    /// Drops the connection and tries again shortly. Call on `queue`.
    func reconnect(after delay: TimeInterval, reason: String) {
        guard running else { return }
        generation += 1
        connection?.cancel()
        connection = nil
        state = .failed(reason)
        let g = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.generation == g else { return }
            self.connect()
        }
    }

    func send(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func connect() {
        guard let p = NWEndpoint.Port(rawValue: port), !host.isEmpty else {
            state = .failed("no address")
            return
        }
        generation += 1
        let g = generation
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 4
        tcp.enableKeepalive = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: NWParameters(tls: nil, tcp: tcp))
        connection = c
        state = .connecting
        c.stateUpdateHandler = { [weak self] st in
            guard let self, self.generation == g else { return }
            switch st {
            case .ready:
                self.state = .connected
            case .failed(let e):
                self.reconnect(reason: e.localizedDescription)
            case .waiting(let e):
                self.reconnect(after: 3, reason: e.localizedDescription)
            case .cancelled, .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        c.start(queue: queue)
        receive(c, g)
    }

    private func receive(_ c: NWConnection, _ g: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.generation == g else { return }
            if let data, !data.isEmpty { self.onData?([UInt8](data)) }
            if complete {
                self.reconnect(reason: StreamState.closedByPeer)
            } else if let error {
                self.reconnect(reason: error.localizedDescription)
            } else {
                self.receive(c, g)
            }
        }
    }
}
