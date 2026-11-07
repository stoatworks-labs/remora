import Foundation
import Network
import RemoraCore

/// Listens for OSC over UDP.
public final class OSCListener: OSCReceiver {
    public var onMessage: ((OSC.Message) -> Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "remora.osc")

    public init() {}

    public func start(port: UInt16) throws {
        stop()
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let l = try NWListener(using: .udp, on: p)
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: self?.queue ?? .main)
            self?.receive(c)
        }
        l.stateUpdateHandler = { st in
            if case .failed(let e) = st { Log.line("OSC: listener failed: \(e)") }
        }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            if let data { OSC.parse([UInt8](data)).forEach { self?.onMessage?($0) } }
            if error == nil { self?.receive(c) }
        }
    }
}
