import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(Windows)
typealias SocketHandle = SOCKET
typealias AddressLength = Int32
#else
typealias SocketHandle = Int32
typealias AddressLength = socklen_t
#endif

/// The few BSD socket calls Remora needs, worded once for Winsock and once for POSIX. Everything
/// else in RemoraSockets is the same on every system.
///
/// Sockets are blocking for sends and waited on with poll (WSAPoll) for reads, a fifth of a second
/// at a time, so a thread that owns a socket notices it was cancelled without the handle being
/// closed under it (`SocketPump`).
enum Sock {
    enum Kind {
        case stream, datagram

        var raw: Int32 {
            #if os(Windows)
            return self == .stream ? Int32(SOCK_STREAM) : Int32(SOCK_DGRAM)
            #elseif canImport(Darwin)
            return self == .stream ? SOCK_STREAM : SOCK_DGRAM
            #else
            return self == .stream ? Int32(SOCK_STREAM.rawValue) : Int32(SOCK_DGRAM.rawValue)
            #endif
        }
    }

    /// Why a connect, a bind or a read failed, in the words Network.framework's links use on macOS
    /// ("connection refused"), so the status reads the same on both.
    struct Failure: Error, CustomStringConvertible {
        var code: Int32
        var reason: String
        init(_ code: Int32) {
            self.code = code
            reason = Sock.describe(code)
        }
        init(code: Int32, reason: String) {
            self.code = code
            self.reason = reason
        }
        static let cancelled = Failure(code: cancelledCode, reason: "cancelled")
        var refused: Bool { Sock.isRefused(code) }
        var description: String { reason }
    }

    /// Not a system error: what `dial` returns when it was cancelled.
    static let cancelledCode = Int32.min

    // MARK: Start-up and errors

    private static let started: Void = {
        #if os(Windows)
        var data = WSADATA()
        _ = WSAStartup(0x0202, &data)
        #endif
    }()

    /// Winsock needs WSAStartup once before any socket call; POSIX needs nothing.
    static func startup() { _ = started }

    static var lastError: Int32 {
        #if os(Windows)
        return WSAGetLastError()
        #else
        return errno
        #endif
    }

    #if os(Windows)
    // Winsock's codes (winerror.h), written out: Swift imports them inconsistently.
    private static let wsaEINTR: Int32 = 10004
    private static let wsaEACCES: Int32 = 10013
    private static let wsaEWOULDBLOCK: Int32 = 10035
    private static let wsaEINPROGRESS: Int32 = 10036
    private static let wsaEADDRINUSE: Int32 = 10048
    private static let wsaEADDRNOTAVAIL: Int32 = 10049
    private static let wsaENETDOWN: Int32 = 10050
    private static let wsaENETUNREACH: Int32 = 10051
    private static let wsaECONNABORTED: Int32 = 10053
    private static let wsaECONNRESET: Int32 = 10054
    private static let wsaETIMEDOUT: Int32 = 10060
    private static let wsaECONNREFUSED: Int32 = 10061
    private static let wsaEHOSTUNREACH: Int32 = 10065
    /// FIONBIO is a macro Swift can't import (`_IOW('f', 126, u_long)`).
    private static let fionbio = Int32(bitPattern: 0x8004_667E)
    #endif

    static var timedOutCode: Int32 {
        #if os(Windows)
        return wsaETIMEDOUT
        #else
        return ETIMEDOUT
        #endif
    }

    static func isRefused(_ e: Int32) -> Bool {
        #if os(Windows)
        return e == wsaECONNREFUSED
        #else
        return e == ECONNREFUSED
        #endif
    }

    /// What a connected UDP socket's read says after its datagram met a closed port: Winsock
    /// reports the ICMP as a reset, POSIX as a refusal.
    static func isUnreachablePort(_ e: Int32) -> Bool {
        #if os(Windows)
        return e == wsaECONNRESET || e == wsaECONNREFUSED
        #else
        return e == ECONNREFUSED
        #endif
    }

    static func isInterrupted(_ e: Int32) -> Bool {
        #if os(Windows)
        return e == wsaEINTR
        #else
        return e == EINTR
        #endif
    }

    static func isWouldBlock(_ e: Int32) -> Bool {
        #if os(Windows)
        return e == wsaEWOULDBLOCK
        #else
        return e == EAGAIN || e == EWOULDBLOCK
        #endif
    }

    /// A non-blocking connect under way.
    static func isInProgress(_ e: Int32) -> Bool {
        #if os(Windows)
        return e == wsaEWOULDBLOCK || e == wsaEINPROGRESS
        #else
        return e == EINPROGRESS
        #endif
    }

    static func isAddressInUse(_ e: Int32) -> Bool {
        #if os(Windows)
        return e == wsaEADDRINUSE || e == wsaEACCES
        #else
        return e == EADDRINUSE
        #endif
    }

    /// "connection refused": strerror's words, lower-cased, as macOS's links say them. Winsock's
    /// codes are given the same words.
    static func describe(_ e: Int32) -> String {
        #if os(Windows)
        switch e {
        case wsaECONNREFUSED: return "connection refused"
        case wsaETIMEDOUT: return "operation timed out"
        case wsaECONNRESET: return "connection reset by peer"
        case wsaECONNABORTED: return "software caused connection abort"
        case wsaEHOSTUNREACH: return "no route to host"
        case wsaENETUNREACH: return "network is unreachable"
        case wsaENETDOWN: return "network is down"
        case wsaEADDRINUSE: return "address already in use"
        case wsaEADDRNOTAVAIL: return "can't assign requested address"
        case wsaEACCES: return "permission denied"
        default: return "Winsock error \(e)"
        }
        #else
        let s = String(cString: strerror(e))
        return s.prefix(1).lowercased() + s.dropFirst()
        #endif
    }

    // MARK: Handles

    static func isValid(_ h: SocketHandle) -> Bool {
        #if os(Windows)
        return h != SOCKET.max   // INVALID_SOCKET, (SOCKET)(~0)
        #else
        return h >= 0
        #endif
    }

    static func open(family: Int32, kind: Kind) -> SocketHandle? {
        startup()
        let h = socket(family, kind.raw, 0)
        guard isValid(h) else { return nil }
        #if canImport(Darwin)
        // A send on a socket the peer closed would raise SIGPIPE and end Remora.
        setOption(h, SOL_SOCKET, SO_NOSIGPIPE, 1)
        #endif
        return h
    }

    static func closeHandle(_ h: SocketHandle) {
        #if os(Windows)
        _ = closesocket(h)
        #else
        _ = close(h)
        #endif
    }

    enum Direction { case write, both }

    /// Ends one or both directions without giving the handle back: a thread waiting on it wakes,
    /// and the number can't be handed out again until the owner closes it.
    static func shutdownHandle(_ h: SocketHandle, _ d: Direction) {
        #if os(Windows)
        _ = shutdown(h, d == .write ? 1 : 2)   // SD_SEND, SD_BOTH
        #elseif canImport(Darwin)
        _ = shutdown(h, d == .write ? SHUT_WR : SHUT_RDWR)
        #else
        _ = shutdown(h, Int32(d == .write ? SHUT_WR : SHUT_RDWR))
        #endif
    }

    @discardableResult
    static func setOption(_ h: SocketHandle, _ level: Int32, _ name: Int32, _ value: Int32) -> Bool {
        var v = value
        #if os(Windows)
        return withUnsafePointer(to: &v) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 4) { setsockopt(h, level, name, $0, 4) }
        } == 0
        #else
        return setsockopt(h, level, name, &v, socklen_t(MemoryLayout<Int32>.size)) == 0
        #endif
    }

    /// SO_ERROR: 0 once a non-blocking connect has connected, else why it failed.
    static func pendingError(_ h: SocketHandle) -> Int32 {
        var v: Int32 = 0
        #if os(Windows)
        var len: Int32 = 4
        let r = withUnsafeMutablePointer(to: &v) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 4) { getsockopt(h, SOL_SOCKET, SO_ERROR, $0, &len) }
        }
        #else
        var len = socklen_t(4)
        let r = getsockopt(h, SOL_SOCKET, SO_ERROR, &v, &len)
        #endif
        return r == 0 ? v : lastError
    }

    static func setBlocking(_ h: SocketHandle, _ blocking: Bool) {
        #if os(Windows)
        var mode: u_long = blocking ? 0 : 1
        _ = ioctlsocket(h, fionbio, &mode)
        #else
        let flags = fcntl(h, F_GETFL, 0)
        _ = fcntl(h, F_SETFL, blocking ? flags & ~O_NONBLOCK : flags | O_NONBLOCK)
        #endif
    }

    // MARK: Addresses

    /// A socket address as bytes, as getaddrinfo or getsockname gave it.
    struct Address {
        var family: Int32
        var bytes: [UInt8]

        func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, AddressLength) -> R) -> R {
            let p = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 128), alignment: 16)
            defer { p.deallocate() }
            p.initializeMemory(as: UInt8.self, repeating: 0, count: max(bytes.count, 128))
            bytes.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
            return body(UnsafePointer(p.assumingMemoryBound(to: sockaddr.self)), AddressLength(bytes.count))
        }
    }

    /// Every address for `host` (nil: any local address, for a listener), IPv4 first: a desk is an
    /// IPv4 address, and "localhost" can be something else on ::1 (AGENTS.md).
    static func resolve(_ host: String?, port: UInt16, kind: Kind, passive: Bool = false,
                        family: Int32 = AF_UNSPEC) -> [Address] {
        startup()
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = kind.raw
        hints.ai_flags = passive ? AI_PASSIVE : 0
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var out: [Address] = []
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let a = next {
            if let sa = a.pointee.ai_addr {
                let n = Int(a.pointee.ai_addrlen)
                out.append(Address(family: a.pointee.ai_family,
                                   bytes: Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(sa), count: n))))
            }
            next = a.pointee.ai_next
        }
        return out.filter { $0.family == AF_INET } + out.filter { $0.family != AF_INET }
    }

    /// 0, or why the call failed.
    static func connectTo(_ h: SocketHandle, _ a: Address) -> Int32 {
        a.withSockaddr { sa, n in connect(h, sa, n) == 0 ? 0 : lastError }
    }

    /// 0, or why the call failed.
    static func bindTo(_ h: SocketHandle, _ a: Address) -> Int32 {
        a.withSockaddr { sa, n in bind(h, sa, n) == 0 ? 0 : lastError }
    }

    /// Fills a socket address with `fill` (getsockname, getpeername) and returns it.
    private static func fetch(_ fill: (UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<AddressLength>) -> Int32) -> [UInt8]? {
        let p = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 16)
        defer { p.deallocate() }
        p.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        var len = AddressLength(128)
        guard fill(p.assumingMemoryBound(to: sockaddr.self), &len) == 0 else { return nil }
        return Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(p), count: min(Int(len), 128)))
    }

    /// The port a socket is bound to: the one asked for, or the one the system picked for 0.
    static func localPort(_ h: SocketHandle) -> UInt16? {
        fetch { getsockname(h, $0, $1) }.flatMap(port(of:))
    }

    /// "169.254.136.158:52116", for logs.
    static func peerName(_ h: SocketHandle) -> String {
        fetch { getpeername(h, $0, $1) }.map(describe(address:)) ?? "?"
    }

    /// sin_port and sin6_port sit at the same offset on every system, in network order.
    static func port(of b: [UInt8]) -> UInt16? {
        b.count >= 4 ? UInt16(b[2]) << 8 | UInt16(b[3]) : nil
    }

    static func describe(address b: [UInt8]) -> String {
        guard b.count >= 8, let port = port(of: b) else { return "?" }
        #if canImport(Darwin)
        let family = Int32(b[1])   // BSD's sockaddr starts with its length
        #else
        let family = Int32(b[0]) | Int32(b[1]) << 8
        #endif
        if family == AF_INET { return "\(b[4]).\(b[5]).\(b[6]).\(b[7]):\(port)" }
        guard b.count >= 24 else { return "?:\(port)" }
        let groups = stride(from: 8, to: 24, by: 2).map { String(UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]), radix: 16) }
        return "[\(groups.joined(separator: ":"))]:\(port)"
    }

    // MARK: Waiting, reading and writing

    enum Wait { case ready, timeout, failed(Int32) }

    /// Waits up to `ms` for the socket to be readable (or writable): a connection to take, a
    /// datagram, bytes, or the end of the stream.
    static func wait(_ h: SocketHandle, write: Bool = false, ms: Int) -> Wait {
        #if os(Windows)
        // POLLRDNORM | POLLRDBAND, or POLLWRNORM: Windows' POLLIN and POLLOUT, written out.
        var p = WSAPOLLFD(fd: h, events: Int16(write ? 0x0010 : 0x0300), revents: 0)
        let r = WSAPoll(&p, 1, Int32(ms))
        #else
        var p = pollfd(fd: h, events: Int16(write ? POLLOUT : POLLIN), revents: 0)
        let r = poll(&p, 1, Int32(ms))
        #endif
        if r > 0 { return .ready }
        if r == 0 { return .timeout }
        let e = lastError
        return isInterrupted(e) ? .timeout : .failed(e)
    }

    /// recv: bytes read, 0 at the end of a stream (or an empty datagram), -1 on an error.
    static func receive(_ h: SocketHandle, into buffer: inout [UInt8]) -> Int {
        let n = buffer.count
        return buffer.withUnsafeMutableBytes { raw -> Int in
            #if os(Windows)
            return Int(recv(h, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(n), 0))
            #else
            return recv(h, raw.baseAddress!, n, 0)
            #endif
        }
    }

    /// recvfrom on an unconnected datagram socket: bytes read (-1 on an error) and who sent them.
    /// The tests' UDP echo uses it; Remora's own links are connected.
    static func receiveFrom(_ h: SocketHandle, into buffer: inout [UInt8]) -> (count: Int, from: [UInt8]) {
        let p = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 16)
        defer { p.deallocate() }
        p.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        var len = AddressLength(128)
        let sa = p.assumingMemoryBound(to: sockaddr.self)
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            #if os(Windows)
            return Int(recvfrom(h, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), 0, sa, &len))
            #else
            return recvfrom(h, raw.baseAddress!, raw.count, 0, sa, &len)
            #endif
        }
        return (n, n >= 0 ? Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(p), count: min(Int(len), 128))) : [])
    }

    /// sendto: one datagram to `address` (bytes as `receiveFrom` gave them). 0, or why it failed.
    @discardableResult
    static func sendTo(_ h: SocketHandle, _ bytes: [UInt8], _ address: [UInt8]) -> Int32 {
        let n = Address(family: 0, bytes: address).withSockaddr { sa, len in
            bytes.withUnsafeBytes { raw -> Int in
                #if os(Windows)
                return Int(sendto(h, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), 0, sa, len))
                #else
                return sendto(h, raw.baseAddress!, raw.count, 0, sa, len)
                #endif
            }
        }
        return n >= 0 ? 0 : lastError
    }

    /// Sends all of `bytes` (one datagram, for UDP). 0, or why it failed.
    @discardableResult
    static func sendAll(_ h: SocketHandle, _ bytes: [UInt8], datagram: Bool) -> Int32 {
        var offset = 0
        while offset < bytes.count {
            let n: Int = bytes.withUnsafeBytes { raw in
                let p = raw.baseAddress! + offset
                let left = bytes.count - offset
                #if os(Windows)
                return Int(send(h, p.assumingMemoryBound(to: CChar.self), Int32(left), 0))
                #elseif canImport(Darwin)
                return send(h, p, left, 0)
                #else
                return send(h, p, left, Int32(MSG_NOSIGNAL))
                #endif
            }
            if n < 0 {
                let e = lastError
                if isInterrupted(e) { continue }
                if isWouldBlock(e) {
                    _ = wait(h, write: true, ms: 200)
                    continue
                }
                return e
            }
            if datagram { return 0 }
            offset += n
        }
        return 0
    }

    // MARK: Connecting and listening

    /// Connects to `host` and `port`, trying each address in turn, for at most `timeout` seconds
    /// each, checking `cancelled` five times a second. A datagram socket is only bound to the peer.
    static func dial(_ host: String, port: UInt16, kind: Kind, timeout: TimeInterval,
                     cancelled: () -> Bool) -> Result<SocketHandle, Failure> {
        let addresses = resolve(host, port: port, kind: kind)
        guard !addresses.isEmpty else { return .failure(Failure(code: 0, reason: "can't find \(host)")) }
        var last = Failure(code: 0, reason: "no address")
        for a in addresses {
            if cancelled() { return .failure(.cancelled) }
            guard let h = open(family: a.family, kind: kind) else {
                last = Failure(lastError)
                continue
            }
            if kind == .datagram {
                let e = connectTo(h, a)
                if e == 0 { return .success(h) }
                closeHandle(h)
                last = Failure(e)
                continue
            }
            setOption(h, SOL_SOCKET, SO_KEEPALIVE, 1)
            setBlocking(h, false)
            var e = connectTo(h, a)
            if e != 0, isInProgress(e) { e = waitForConnect(h, timeout: timeout, cancelled: cancelled) }
            if e == 0 {
                setBlocking(h, true)
                return .success(h)
            }
            closeHandle(h)
            if e == cancelledCode { return .failure(.cancelled) }
            last = Failure(e)
        }
        return .failure(last)
    }

    private static func waitForConnect(_ h: SocketHandle, timeout: TimeInterval, cancelled: () -> Bool) -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if cancelled() { return cancelledCode }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return timedOutCode }
            switch wait(h, write: true, ms: min(200, max(1, Int(left * 1000)))) {
            case .timeout: continue
            case .ready: return pendingError(h)
            case .failed(let e): return e
            }
        }
    }

    /// A TCP socket listening on every IPv4 interface, non-blocking, with the port it got.
    static func listenTCP(port: UInt16) -> Result<(SocketHandle, UInt16), Failure> {
        guard let a = resolve(nil, port: port, kind: .stream, passive: true, family: AF_INET).first,
              let h = open(family: a.family, kind: .stream) else { return .failure(Failure(lastError)) }
        #if !os(Windows)
        // Lets a relaunch listen again while the last run's connections linger in TIME_WAIT. On
        // Windows it would let another program take a port in use, so it is left off there.
        setOption(h, SOL_SOCKET, SO_REUSEADDR, 1)
        #endif
        var e = bindTo(h, a)
        if e == 0, listen(h, 16) != 0 { e = lastError }
        guard e == 0 else {
            closeHandle(h)
            return .failure(Failure(e))
        }
        setBlocking(h, false)
        return .success((h, localPort(h) ?? port))
    }

    /// A UDP socket bound to `port` on every IPv4 interface.
    static func bindUDP(port: UInt16) -> Result<SocketHandle, Failure> {
        guard let a = resolve(nil, port: port, kind: .datagram, passive: true, family: AF_INET).first,
              let h = open(family: a.family, kind: .datagram) else { return .failure(Failure(lastError)) }
        let e = bindTo(h, a)
        guard e == 0 else {
            closeHandle(h)
            return .failure(Failure(e))
        }
        return .success(h)
    }

    /// Takes one waiting connection from a listening socket, blocking for its reads and writes.
    static func acceptOne(_ h: SocketHandle) -> SocketHandle? {
        let c = accept(h, nil, nil)
        guard isValid(c) else { return nil }
        #if canImport(Darwin)
        setOption(c, SOL_SOCKET, SO_NOSIGPIPE, 1)
        #endif
        setBlocking(c, true)
        return c
    }
}
