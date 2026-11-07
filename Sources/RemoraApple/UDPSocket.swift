import Foundation
import Network
import RemoraCore

/// Datagrams to one host and port, and the ones that come back from there. A socket that fails
/// (no route, or the host answers "port unreachable") is opened again two seconds later, until
/// stopped. Everything runs on `queue`.
final class UDPSocket: UDPLink {
    let host: String
    let port: UInt16
    let queue: DispatchQueue
    var onState: ((StreamState) -> Void)?
    var onDatagram: (([UInt8]) -> Void)?

    private var connection: NWConnection?
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

    /// Call on `queue`.
    func start() {
        guard !running else { return }
        running = true
        open()
    }

    /// Call on `queue`.
    func stop() {
        running = false
        generation += 1
        connection?.cancel()
        connection = nil
        state = .stopped
    }

    func send(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func open() {
        guard let p = NWEndpoint.Port(rawValue: port), !host.isEmpty else {
            state = .failed("no address")
            return
        }
        generation += 1
        let g = generation
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .udp)
        connection = c
        state = .connecting
        c.stateUpdateHandler = { [weak self] st in
            guard let self, self.generation == g else { return }
            switch st {
            case .ready: self.state = .connected
            case .failed(let e), .waiting(let e): self.reopen(why: e.localizedDescription)
            case .cancelled, .setup, .preparing: break
            @unknown default: break
            }
        }
        c.start(queue: queue)
        receive(c, g)
    }

    private func reopen(why: String) {
        guard running else { return }
        generation += 1
        connection?.cancel()
        connection = nil
        state = .failed(why)
        let g = generation
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running, self.generation == g else { return }
            self.open()
        }
    }

    private func receive(_ c: NWConnection, _ g: Int) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.generation == g else { return }
            if let data, !data.isEmpty { self.onDatagram?([UInt8](data)) }
            if let error {
                self.reopen(why: error.localizedDescription)
            } else {
                self.receive(c, g)
            }
        }
    }
}
