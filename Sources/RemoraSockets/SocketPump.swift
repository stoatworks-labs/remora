import Foundation

/// Owns one connected socket. A thread of its own reads it until the peer ends it, it fails, or
/// it is cancelled, then closes it. Nothing else closes the handle, so a number the system hands
/// out again is never read, written or closed by mistake.
///
/// `onData` and `onEnd` are called on the pump's thread: the owner hops to its own queue. `onEnd`
/// is not called after `cancel` or `finish`.
final class SocketPump {
    let handle: SocketHandle
    private let datagrams: Bool
    private var onData: (([UInt8]) -> Void)?
    /// nil: the peer ended the stream; else why it failed.
    private var onEnd: ((String?) -> Void)?

    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var closed = false
    /// Set by `finish`: read what is left until then, and close.
    private var finishBy: Date?
    /// Sends under way: the handle is closed only once there are none.
    private var sending = 0

    init(handle: SocketHandle, datagrams: Bool,
         onData: @escaping ([UInt8]) -> Void, onEnd: @escaping (String?) -> Void) {
        self.handle = handle
        self.datagrams = datagrams
        self.onData = onData
        self.onEnd = onEnd
    }

    func start() {
        lock.lock()
        let go = !started && !closed && !cancelled
        started = true
        lock.unlock()
        if go { spawn() }
    }

    /// Stops reading and closes the socket, within a fifth of a second. Nothing more is reported.
    func cancel() {
        lock.lock()
        cancelled = true
        if !closed { Sock.shutdownHandle(handle, .both) }
        let reading = started
        lock.unlock()
        if !reading { closeWhenIdle() }
    }

    /// Ends the stream after what has been sent: the peer gets the end of the stream, what it still
    /// sends is read and dropped for up to `seconds`, then the socket is closed. A close with
    /// unread bytes would reset the connection, and the peer could lose the last of ours.
    func finish(within seconds: TimeInterval = 2) {
        lock.lock()
        guard !closed, !cancelled, finishBy == nil else {
            lock.unlock()
            return
        }
        finishBy = Date().addingTimeInterval(seconds)
        Sock.shutdownHandle(handle, .write)
        let go = !started
        started = true
        lock.unlock()
        if go { spawn() }
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        guard !closed, !cancelled, finishBy == nil else {
            lock.unlock()
            return
        }
        sending += 1
        lock.unlock()
        Sock.sendAll(handle, bytes, datagram: datagrams)
        lock.lock()
        sending -= 1
        lock.unlock()
    }

    private func spawn() {
        let t = Thread { [self] in run() }
        t.name = "remora.socket"
        t.start()
    }

    private enum End { case peer, failed(String) }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var end: End?
        loop: while true {
            lock.lock()
            let stop = cancelled
            let by = finishBy
            lock.unlock()
            if stop { break }
            if let by, Date() >= by { break }
            switch Sock.wait(handle, ms: 200) {
            case .timeout:
                continue
            case .failed(let e):
                end = .failed(Sock.describe(e))
                break loop
            case .ready:
                let n = Sock.receive(handle, into: &buffer)
                if n > 0 {
                    if by == nil { onData?(Array(buffer[0..<n])) }
                } else if n == 0 {
                    if datagrams { continue }   // an empty datagram, not an end
                    end = .peer
                    break loop
                } else {
                    let e = Sock.lastError
                    if Sock.isInterrupted(e) || Sock.isWouldBlock(e) { continue }
                    // Nothing on the other port yet (an ICMP "port unreachable", which Winsock calls
                    // a reset): for UDP that is a desk not answering, which the module judges by
                    // its silence, as macOS's links do. Keep listening.
                    if datagrams, Sock.isUnreachablePort(e) { continue }
                    end = .failed(Sock.describe(e))
                    break loop
                }
            }
        }
        closeWhenIdle()
        lock.lock()
        let quiet = cancelled || finishBy != nil
        lock.unlock()
        let tell = onEnd
        onData = nil
        onEnd = nil
        guard let end, !quiet else { return }
        switch end {
        case .peer: tell?(nil)
        case .failed(let why): tell?(why)
        }
    }

    private func closeWhenIdle() {
        while true {
            lock.lock()
            if closed {
                lock.unlock()
                return
            }
            if sending == 0 {
                closed = true
                lock.unlock()
                Sock.closeHandle(handle)
                return
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}

/// Owns a listening socket: a thread takes each connection and hands it over, until cancelled.
final class SocketAcceptor {
    let handle: SocketHandle
    private var onAccept: ((SocketHandle) -> Void)?
    private var onEnd: ((String) -> Void)?
    private let lock = NSLock()
    private var cancelled = false

    /// `onAccept` owns the handle it is given. Both are called on the acceptor's thread.
    init(handle: SocketHandle, onAccept: @escaping (SocketHandle) -> Void, onEnd: @escaping (String) -> Void) {
        self.handle = handle
        self.onAccept = onAccept
        self.onEnd = onEnd
    }

    func start() {
        let t = Thread { [self] in run() }
        t.name = "remora.listener"
        t.start()
    }

    /// Stops listening within a fifth of a second. Connections already handed over stay open.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func run() {
        var failure: String?
        loop: while !isCancelled {
            switch Sock.wait(handle, ms: 200) {
            case .timeout:
                continue
            case .failed(let e):
                failure = Sock.describe(e)
                break loop
            case .ready:
                if let c = Sock.acceptOne(handle) {
                    if isCancelled {
                        Sock.closeHandle(c)
                    } else {
                        onAccept?(c)
                    }
                } else {
                    let e = Sock.lastError
                    if Sock.isInterrupted(e) || Sock.isWouldBlock(e) { continue }
                    failure = Sock.describe(e)
                    break loop
                }
            }
        }
        Sock.closeHandle(handle)
        let tell = onEnd
        onAccept = nil
        onEnd = nil
        if let failure, !isCancelled { tell?(failure) }
    }
}

/// A connect on a thread of its own, which `cancel` stops within a fifth of a second.
final class SocketDial {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// `done` is called on the dial's thread, and not at all once cancelled.
    func run(host: String, port: UInt16, kind: Sock.Kind, timeout: TimeInterval,
             done: @escaping (Result<SocketHandle, Sock.Failure>) -> Void) {
        let t = Thread { [self] in
            let r = Sock.dial(host, port: port, kind: kind, timeout: timeout, cancelled: { self.isCancelled })
            if isCancelled {
                if case .success(let h) = r { Sock.closeHandle(h) }
                return
            }
            done(r)
        }
        t.name = "remora.dial"
        t.start()
    }
}
