import Network
import XCTest
@testable import RemoraApple
import RemoraCore

/// `TCPLink` over loopback: a port nothing listens on, and a server that answers and closes.
final class TCPLinkTests: XCTestCase {
    private let queue = DispatchQueue(label: "test.tcplink")

    /// Nothing listening: the link says the connection was refused. It used to start reading as it
    /// started the connection, and the refusal ended that read as a close does, so the link said
    /// "closed by the desk" for a desk that wasn't there.
    func testARefusedConnectionIsSaidAsRefused() throws {
        let link = TCPLink(host: "127.0.0.1", port: try closedPort(), queue: queue)
        XCTAssertEqual(statesToFirstFailure(of: link), [.connecting, .failed("connection refused")])
    }

    /// Reading starts once connected: what the server sends arrives, and its close is the desk's.
    func testItReadsOnceConnectedAndTheServersCloseIsTheDesks() throws {
        let server = try LoopbackServer(sending: Array("hello".utf8), queue: queue)
        defer { server.stop() }
        let link = TCPLink(host: "127.0.0.1", port: server.port, queue: queue)
        var got: [UInt8] = []
        link.onData = { got += $0 }
        XCTAssertEqual(statesToFirstFailure(of: link), [.connecting, .connected, .failed(StreamState.closedByPeer)])
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "hello")
    }

    func testNetworkErrorsAreWordedAsRemorasOtherReasons() {
        XCTAssertEqual(TCPLink.describe(.posix(.ECONNREFUSED)), "connection refused")
        XCTAssertEqual(TCPLink.describe(.posix(.ETIMEDOUT)), "operation timed out")
    }

    /// Starts the link, and stops it at its first failure.
    private func statesToFirstFailure(of link: TCPLink) -> [StreamState] {
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
        wait(for: [failed], timeout: 5)
        queue.sync { link.stop() }
        return states
    }

    /// A loopback port nothing listens on: the system gives it to a socket that closes without
    /// listening.
    private func closedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound: Bool = withUnsafeMutablePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                guard Darwin.bind(fd, sa, len) == 0 else { return false }
                return getsockname(fd, sa, &len) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        return UInt16(bigEndian: a.sin_port)
    }
}

/// Listens on 127.0.0.1. Whoever dials gets `bytes`, then the end of the stream.
private final class LoopbackServer {
    private let listener: NWListener
    private let queue: DispatchQueue
    private var accepted: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(sending bytes: [UInt8], queue: DispatchQueue) throws {
        self.queue = queue
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: p)
        listener.newConnectionHandler = { [weak self] c in
            self?.accepted.append(c)
            c.start(queue: queue)
            c.send(content: Data(bytes), contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        }
        let up = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { up.signal() } }
        listener.start(queue: queue)
        guard up.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw POSIXError(.ETIMEDOUT)
        }
        self.port = port
    }

    func stop() {
        queue.sync {
            accepted.forEach { $0.cancel() }
            listener.cancel()
        }
    }
}
