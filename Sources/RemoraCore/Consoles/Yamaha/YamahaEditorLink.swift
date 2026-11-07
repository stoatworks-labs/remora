import Foundation

/// The CL/QL editor port (TCP 50000), read-only.
///
/// Opens as QL Editor does: waits for the desk's first heartbeat, answers it with the Editor's
/// opening (read requests only), then asks for the selected channel. The desk then reports
/// every change. The selection is asked for again every few seconds as a safety net, and a
/// link with no heartbeat for five seconds is dropped and reopened.
public final class YamahaEditorLink {
    public typealias State = ConsoleState

    public var onState: ((State) -> Void)?
    public var onChange: ((YamahaSysEx.Change) -> Void)?

    public let host: String
    private let queue = DispatchQueue(label: "remora.yamaha.editor")
    private let tcp: TCPStream
    private var buffer: [UInt8] = []
    private var opened = false
    private var lastHeartbeat = Date()
    private var timer: DispatchSourceTimer?
    private var ticks = 0

    public init(host: String, port: UInt16 = 50000, platform: Platform) {
        self.host = host
        tcp = platform.tcp(host: host, port: port, queue: queue)
        tcp.onState = { [weak self] st in self?.linkState(st) }
        tcp.onData = { [weak self] bytes in self?.received(bytes) }
    }

    public func start() {
        queue.async {
            self.tcp.start()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            tcp.stop()
        }
    }

    /// Asks the desk for one parameter; the answer arrives through `onChange`.
    public func read(_ a: YamahaSysEx.Address) {
        queue.async { self.send(YamahaSysEx.readRequest(a)) }
    }

    private func send(_ m: [UInt8]) {
        // The one rule: never a parameter change. A request that is not a read is a bug.
        precondition(YamahaSysEx.isReadRequest(m), "Remora sends only read requests to a console")
        tcp.send(m)
    }

    private func linkState(_ st: StreamState) {
        switch st {
        case .stopped: report(.stopped)
        case .connecting: report(.connecting)
        case .connected:
            buffer = []
            opened = false
            lastHeartbeat = Date()
            report(.waitingForDesk)
        case .failed(let why): report(.failed(why))
        }
    }

    private var reported: State = .stopped
    private func report(_ s: State) {
        guard s != reported else { return }
        reported = s
        onState?(s)
    }

    private func received(_ bytes: [UInt8]) {
        buffer += bytes
        if buffer.count > 1 << 20 { buffer.removeAll() }
        for m in YamahaSysEx.split(&buffer) {
            if m == YamahaSysEx.heartbeat {
                lastHeartbeat = Date()
                if !opened {
                    opened = true
                    YamahaSysEx.editorOpening.forEach(send)
                    send(YamahaSysEx.readRequest(YamahaSysEx.selectedChannel))
                    report(.live)
                }
                continue
            }
            if let c = YamahaSysEx.parseChange(m) { onChange?(c) }
        }
    }

    private func tick() {
        guard tcp.state == .connected else { return }
        if Date().timeIntervalSince(lastHeartbeat) > 5 {
            tcp.reconnect(reason: "no heartbeat from the desk")
            return
        }
        ticks += 1
        if opened, ticks % 5 == 0 {
            send(YamahaSysEx.readRequest(YamahaSysEx.selectedChannel))
        }
    }
}
