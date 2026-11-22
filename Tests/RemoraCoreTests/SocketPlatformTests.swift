import Foundation
import XCTest
@testable import RemoraCore
@testable import RemoraSockets

/// RemoraSockets' platform over loopback, on every system: the checks TCPLinkTests makes of
/// Network.framework's link on macOS, plus UDP, OSC and stopping mid-connect. On Windows this is
/// Winsock, and Windows' only platform. ProLink over its listener is in TCPServerTests.
final class SocketPlatformTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.sockets")
    private let platform = SocketPlatform()

    override func setUp() { Log.enabled = false }

    /// Nothing listening: the link says the connection was refused, in the words macOS's does.
    /// (Windows retries a refused SYN for about two seconds before saying so.)
    func testARefusedConnectionIsSaidAsRefused() throws {
        let link = platform.tcp(host: "127.0.0.1", port: try freePort(.stream), queue: queue)
        XCTAssertEqual(statesToFirstFailure(of: link), [.connecting, .failed("connection refused")])
    }

    /// Reading starts once connected: what the server sends arrives, and its close is the desk's.
    func testItReadsOnceConnectedAndTheServersCloseIsTheDesks() {
        let server = platform.tcpListener(port: 0, queue: queue)
        let up = expectation(description: "listening")
        var port: UInt16 = 0
        server.onState = { if case .listening(let p) = $0, port == 0 { port = p; up.fulfill() } }
        server.onConnection = { c in
            c.start()
            c.close(after: Array("hello".utf8))
        }
        queue.sync { server.start() }
        wait(for: [up], timeout: 5)
        defer { queue.sync { server.stop() } }

        let link = platform.tcp(host: "127.0.0.1", port: port, queue: queue)
        var got: [UInt8] = []
        link.onData = { got += $0 }
        XCTAssertEqual(statesToFirstFailure(of: link), [.connecting, .connected, .failed(StreamState.closedByPeer)])
        XCTAssertEqual(String(decoding: queue.sync { got }, as: UTF8.self), "hello")
    }

    /// Both ways over one connection: a line out, its echo back, and the peer's name.
    func testAConnectionCarriesBothWays() {
        let server = platform.tcpListener(port: 0, queue: queue)
        let up = expectation(description: "listening")
        var port: UInt16 = 0
        var peers: [String] = []
        var kept: [TCPConnection] = []
        server.onState = { if case .listening(let p) = $0, port == 0 { port = p; up.fulfill() } }
        server.onConnection = { c in
            peers.append(c.peer)
            kept.append(c)
            c.onData = { [weak c] in c?.send($0) }
            c.start()
        }
        queue.sync { server.start() }
        wait(for: [up], timeout: 5)

        let link = platform.tcp(host: "127.0.0.1", port: port, queue: queue)
        let echoed = expectation(description: "echoed")
        var got: [UInt8] = []
        link.onState = { if $0 == .connected { link.send(Array("ping\n".utf8)) } }
        link.onData = {
            got += $0
            if got.count == 5 { echoed.fulfill() }
        }
        queue.sync { link.start() }
        wait(for: [echoed], timeout: 5)
        queue.sync {
            link.stop()
            server.stop()
        }
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "ping\n")
        XCTAssertTrue(queue.sync { peers.first ?? "" }.hasPrefix("127.0.0.1:"))
        _ = kept
    }

    /// Stopped mid-connect, to an address that never answers: stopped at once, and nothing after.
    func testStoppingMidConnectSaysNothingMore() {
        let link = platform.tcp(host: "192.0.2.1", port: 9, queue: queue)   // TEST-NET-1: no one
        var states: [StreamState] = []
        link.onState = { states.append($0) }
        queue.sync { link.start() }
        Thread.sleep(forTimeInterval: 0.3)
        queue.sync { link.stop() }
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(queue.sync { states }.first, .connecting)
        XCTAssertEqual(queue.sync { states }.last, .stopped)
        XCTAssertFalse(queue.sync { states }.contains { if case .failed = $0 { return true } else { return false } })
    }

    /// A datagram out, and the answer back on the same link, as an X32 or Wing answers a poll.
    func testAUDPLinkHearsTheAnswer() throws {
        let echo = try UDPEcho()
        defer { echo.stop() }
        let link = platform.udp(host: "127.0.0.1", port: echo.port, queue: queue)
        let answered = expectation(description: "answered")
        var got: [[UInt8]] = []
        link.onState = { if $0 == .connected { link.send([1, 2, 3]) } }
        link.onDatagram = {
            got.append($0)
            answered.fulfill()
        }
        queue.sync { link.start() }
        wait(for: [answered], timeout: 5)
        queue.sync { link.stop() }
        XCTAssertEqual(got, [[1, 2, 3]])
    }

    /// A desk that isn't there yet: datagrams to a closed port bring back "port unreachable", which
    /// Winsock reports as a reset. The link stays up, as macOS's does, so the module can say it is
    /// waiting for the desk; seen on winlab 2026-11-22, when a fake X32 stopped.
    func testAUDPLinkToAClosedPortStaysUp() throws {
        let port = try freePort(.datagram)
        let link = platform.udp(host: "127.0.0.1", port: port, queue: queue)
        var states: [StreamState] = []
        link.onState = {
            states.append($0)
            if $0 == .connected { link.send([1]) }
        }
        queue.sync { link.start() }
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.1)
            queue.sync { link.send([2]) }
        }
        Thread.sleep(forTimeInterval: 0.3)
        queue.sync { link.stop() }
        XCTAssertEqual(queue.sync { states }, [.connecting, .connected, .stopped])
    }

    /// The OSC receiver Remora listens with: a message sent to its port arrives parsed.
    func testOSCArrives() throws {
        let port = try freePort(.datagram)
        let receiver = platform.oscReceiver()
        let heard = expectation(description: "heard")
        var messages: [OSC.Message] = []
        receiver.onMessage = {
            messages.append($0)
            heard.fulfill()
        }
        try receiver.start(port: port)
        defer { receiver.stop() }
        let link = platform.udp(host: "127.0.0.1", port: port, queue: queue)
        link.onState = {
            if $0 == .connected { link.send(OSC.encode(OSC.Message(address: "/remora/rack/next", args: []))) }
        }
        queue.sync { link.start() }
        wait(for: [heard], timeout: 5)
        queue.sync { link.stop() }
        XCTAssertEqual(messages.map(\.address), ["/remora/rack/next"])
    }

    /// Another receiver on a port in use is refused, and says which.
    func testOSCOnAPortInUseThrows() throws {
        let port = try freePort(.datagram)
        let first = platform.oscReceiver()
        try first.start(port: port)
        defer { first.stop() }
        XCTAssertThrowsError(try platform.oscReceiver().start(port: port)) {
            XCTAssertTrue("\($0)".hasPrefix("UDP \(port): "), "\($0)")
        }
    }

    func testErrorsAreWordedAsMacOSWordsThem() {
        XCTAssertEqual(Sock.describe(connectionRefused), "connection refused")
        #if !os(Linux)
        XCTAssertEqual(Sock.describe(Sock.timedOutCode), "operation timed out")
        #endif
    }

    // MARK: Helpers

    private var connectionRefused: Int32 {
        #if os(Windows)
        return 10061
        #else
        return ECONNREFUSED
        #endif
    }

    /// Starts the link, and stops it at its first failure.
    private func statesToFirstFailure(of link: TCPStream) -> [StreamState] {
        let failed = expectation(description: "failed")
        var states: [StreamState] = []
        var done = false
        link.onState = { st in
            guard !done else { return }
            states.append(st)
            if case .failed = st {
                done = true
                failed.fulfill()
            }
        }
        queue.sync { link.start() }
        wait(for: [failed], timeout: 8)
        queue.sync { link.stop() }
        return queue.sync { states }
    }

    /// A loopback port nothing uses: the system gives it to a socket that lets it go again.
    private func freePort(_ kind: Sock.Kind) throws -> UInt16 {
        guard let a = Sock.resolve("127.0.0.1", port: 0, kind: kind).first,
              let h = Sock.open(family: a.family, kind: kind) else { throw Sock.Failure(Sock.lastError) }
        defer { Sock.closeHandle(h) }
        guard Sock.bindTo(h, a) == 0, let port = Sock.localPort(h) else { throw Sock.Failure(Sock.lastError) }
        return port
    }
}

/// Sends every datagram back to whoever sent it, on a thread of its own.
private final class UDPEcho {
    let port: UInt16
    private let handle: SocketHandle
    private let lock = NSLock()
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)

    init() throws {
        switch Sock.bindUDP(port: 0) {
        case .failure(let f): throw f
        case .success(let h):
            handle = h
            guard let p = Sock.localPort(h) else { throw Sock.Failure(Sock.lastError) }
            port = p
        }
        Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            while !isStopped {
                guard case .ready = Sock.wait(handle, ms: 100) else { continue }
                let (n, from) = Sock.receiveFrom(handle, into: &buffer)
                if n > 0 { Sock.sendTo(handle, Array(buffer[0..<n]), from) }
            }
            Sock.closeHandle(handle)
            done.signal()
        }.start()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        _ = done.wait(timeout: .now() + 2)
    }
}
