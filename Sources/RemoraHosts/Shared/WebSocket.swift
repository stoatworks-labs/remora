import Foundation
import RemoraCore

/// A WebSocket client over one of Remora's TCP streams (RFC 6455), for Cantabile. Text messages
/// only; every frame masked, as a client's must be; the server's key checked; pings answered. On
/// anything else it drops the connection, and the stream dials again. Everything runs on the
/// stream's queue.
public final class WebSocketClient {
    public enum State: Equatable {
        case connecting
        case open
        case failed(String)
    }

    public var onState: ((State) -> Void)?
    public var onText: ((String) -> Void)?

    /// The most one message may be.
    public static let maxMessage = 8 << 20
    /// What the client fails with when the server sends a close.
    public static let closedByServer = "closed by the server"

    private let stream: TCPStream
    private let host: String
    private let port: UInt16
    private let path: String
    private var key = ""
    private var buffer: [UInt8] = []
    private var open = false
    /// A message coming in pieces: its opcode and what has come so far.
    private var pieces: (opcode: UInt8, bytes: [UInt8])?

    public init(stream: TCPStream, host: String, port: UInt16, path: String) {
        self.stream = stream
        self.host = host
        self.port = port
        self.path = path
        stream.onState = { [weak self] s in self?.streamState(s) }
        stream.onData = { [weak self] b in self?.received(b) }
    }

    /// Call on the stream's queue.
    public func start() {
        onState?(.connecting)
        stream.start()
    }

    /// Call on the stream's queue.
    public func stop() {
        open = false
        stream.onState = nil
        stream.onData = nil
        stream.stop()
    }

    /// Sends one text message, once open. Call on the stream's queue.
    public func send(text: String) {
        guard open else { return }
        stream.send(WebSocketFrame.encode(opcode: WebSocketFrame.text, payload: Array(text.utf8), mask: Self.randomMask()))
    }

    // MARK: On the stream's queue

    private func streamState(_ s: StreamState) {
        switch s {
        case .connected:
            buffer = []
            pieces = nil
            open = false
            key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            stream.send(Array(("GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\n"
                + "Connection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
                + "User-Agent: Remora\r\n\r\n").utf8))
        case .failed(let why):
            open = false
            onState?(.failed(why))
        case .connecting, .stopped:
            break
        }
    }

    private func fail(_ why: String) {
        open = false
        onState?(.failed(why))
        stream.reconnect(reason: why)
    }

    private func received(_ bytes: [UInt8]) {
        buffer += bytes
        if !open {
            guard let end = HTTPGet.find([13, 10, 13, 10], in: buffer) else {
                if buffer.count > 16 << 10 { fail("the answer to the WebSocket request was too long") }
                return
            }
            let head = String(decoding: buffer[..<end], as: UTF8.self)
            buffer.removeFirst(end + 4)
            guard Self.accepts(head, key: key) else {
                fail("\(host):\(port) didn't answer as a WebSocket server")
                return
            }
            open = true
            onState?(.open)
        }
        while open {
            if let n = WebSocketFrame.declaredLength(buffer), n > Self.maxMessage {
                fail("a message over \(Self.maxMessage >> 20) MB")
                return
            }
            guard let (frame, used) = WebSocketFrame.decode(buffer) else { break }
            buffer.removeFirst(used)
            handle(frame)
        }
    }

    private func handle(_ f: WebSocketFrame) {
        guard f.mask == nil else {
            fail("the server masked a frame")
            return
        }
        switch f.opcode {
        case WebSocketFrame.text, WebSocketFrame.binary:
            if f.fin {
                if f.opcode == WebSocketFrame.text { onText?(String(decoding: f.payload, as: UTF8.self)) }
            } else {
                pieces = (f.opcode, f.payload)
            }
        case WebSocketFrame.continuation:
            guard var p = pieces else {
                fail("a continuation with nothing to continue")
                return
            }
            p.bytes += f.payload
            guard p.bytes.count <= Self.maxMessage else {
                fail("a message over \(Self.maxMessage >> 20) MB")
                return
            }
            if f.fin {
                pieces = nil
                if p.opcode == WebSocketFrame.text { onText?(String(decoding: p.bytes, as: UTF8.self)) }
            } else {
                pieces = p
            }
        case WebSocketFrame.ping:
            stream.send(WebSocketFrame.encode(opcode: WebSocketFrame.pong, payload: f.payload, mask: Self.randomMask()))
        case WebSocketFrame.pong:
            break
        case WebSocketFrame.close:
            // Answered with a close, as the RFC asks, then dropped; the stream dials again.
            stream.send(WebSocketFrame.encode(opcode: WebSocketFrame.close, payload: Array(f.payload.prefix(2)),
                                              mask: Self.randomMask()))
            fail(Self.closedByServer)
        default:
            fail("an unknown frame (opcode \(f.opcode))")
        }
    }

    /// The server's answer to the upgrade: 101, and the key it was sent, hashed (RFC 6455 §4.2.2).
    static func accepts(_ head: String, key: String) -> Bool {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2, first[0].hasPrefix("HTTP/1.1"), first[1] == "101" else { return false }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                headers[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return headers["upgrade"]?.lowercased() == "websocket"
            && headers["connection"]?.lowercased().contains("upgrade") == true
            && headers["sec-websocket-accept"] == acceptKey(for: key)
    }

    public static func acceptKey(for key: String) -> String {
        Data(SHA1.hash(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    private static func randomMask() -> [UInt8] { (0..<4).map { _ in UInt8.random(in: 0...255) } }
}

/// One WebSocket frame (RFC 6455 §5.2).
public struct WebSocketFrame: Equatable {
    public static let continuation: UInt8 = 0x0
    public static let text: UInt8 = 0x1
    public static let binary: UInt8 = 0x2
    public static let close: UInt8 = 0x8
    public static let ping: UInt8 = 0x9
    public static let pong: UInt8 = 0xA

    public var fin: Bool
    public var opcode: UInt8
    /// The masking key, for a frame that came masked; the payload is already unmasked.
    public var mask: [UInt8]?
    public var payload: [UInt8]

    /// A frame's bytes, masked with `mask` if given (a client's always are).
    public static func encode(opcode: UInt8, payload: [UInt8], mask: [UInt8]? = nil, fin: Bool = true) -> [UInt8] {
        var out: [UInt8] = [(fin ? 0x80 : 0) | (opcode & 0x0F)]
        let m: UInt8 = mask == nil ? 0 : 0x80
        switch payload.count {
        case 0..<126:
            out.append(m | UInt8(payload.count))
        case 126...0xFFFF:
            out.append(m | 126)
            out += [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default:
            out.append(m | 127)
            out += (0..<8).reversed().map { UInt8((UInt64(payload.count) >> (UInt64($0) * 8)) & 0xFF) }
        }
        if let mask {
            out += mask
            out += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        } else {
            out += payload
        }
        return out
    }

    /// The payload length the first frame in `bytes` says it has, once its header has come that
    /// far: a reader can give up on a frame too big before it arrives.
    public static func declaredLength(_ bytes: [UInt8]) -> Int? {
        header(bytes).map(\.length)
    }

    /// The first frame's payload length and where its masking key or payload starts.
    private static func header(_ bytes: [UInt8]) -> (length: Int, start: Int)? {
        guard bytes.count >= 2 else { return nil }
        let length = Int(bytes[1] & 0x7F)
        switch length {
        case 126:
            guard bytes.count >= 4 else { return nil }
            return (Int(bytes[2]) << 8 | Int(bytes[3]), 4)
        case 127:
            guard bytes.count >= 10 else { return nil }
            var l: UInt64 = 0
            for b in bytes[2..<10] { l = l << 8 | UInt64(b) }
            return (l > UInt64(Int.max >> 1) ? Int.max >> 1 : Int(l), 10)
        default:
            return (length, 2)
        }
    }

    /// The first frame in `bytes` and how many bytes it took, or nil until it has all come.
    public static func decode(_ bytes: [UInt8]) -> (WebSocketFrame, Int)? {
        guard let (length, start) = header(bytes) else { return nil }
        let fin = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var i = start
        var mask: [UInt8]?
        if masked {
            guard bytes.count >= i + 4 else { return nil }
            mask = Array(bytes[i..<(i + 4)])
            i += 4
        }
        guard bytes.count >= i + length else { return nil }
        var payload = Array(bytes[i..<(i + length)])
        if let mask { payload = payload.enumerated().map { $0.element ^ mask[$0.offset % 4] } }
        return (WebSocketFrame(fin: fin, opcode: opcode, mask: mask, payload: payload), i + length)
    }
}

/// SHA-1, for the WebSocket handshake's key and nothing else (RFC 3174). The core may not import
/// CryptoKit or CommonCrypto (`PortabilityTests`).
public enum SHA1 {
    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var m = message
        let bits = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        m += (0..<8).reversed().map { UInt8((bits >> (UInt64($0) * 8)) & 0xFF) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(m[j]) << 24 | UInt32(m[j + 1]) << 16 | UInt32(m[j + 2]) << 8 | UInt32(m[j + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotl(b, 30)
                b = a
                a = t
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
        }
        return h.flatMap { v in (0..<4).map { UInt8((v >> UInt32(24 - $0 * 8)) & 0xFF) } }
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
}
