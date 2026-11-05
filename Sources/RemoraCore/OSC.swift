import Foundation
import Network

/// Just enough OSC for Companion's generic OSC module: messages and bundles with int, float
/// and string arguments.
public enum OSC {
    public enum Arg: Equatable {
        case int(Int32)
        case float(Float)
        case string(String)

        public var number: Double? {
            switch self {
            case .int(let i): return Double(i)
            case .float(let f): return Double(f)
            case .string(let s): return Double(s)
            }
        }
        public var text: String {
            switch self {
            case .int(let i): return String(i)
            case .float(let f): return String(f)
            case .string(let s): return s
            }
        }
    }

    public struct Message: Equatable {
        public var address: String
        public var args: [Arg]
        public init(address: String, args: [Arg]) {
            self.address = address
            self.args = args
        }
    }

    public static func parse(_ data: [UInt8]) -> [Message] {
        var i = 0
        guard let head = string(data, &i) else { return [] }
        if head == "#bundle" {
            i += 8 // time tag
            var out: [Message] = []
            while i + 4 <= data.count {
                let n = Int(int32(data, i))
                i += 4
                guard n > 0, i + n <= data.count else { break }
                out += parse(Array(data[i..<i + n]))
                i += n
            }
            return out
        }
        guard head.hasPrefix("/") else { return [] }
        var args: [Arg] = []
        if i < data.count, let tags = string(data, &i), tags.hasPrefix(",") {
            for t in tags.dropFirst() {
                switch t {
                case "i":
                    guard i + 4 <= data.count else { return [] }
                    args.append(.int(int32(data, i)))
                    i += 4
                case "f":
                    guard i + 4 <= data.count else { return [] }
                    args.append(.float(Float(bitPattern: UInt32(bitPattern: int32(data, i)))))
                    i += 4
                case "s":
                    guard let s = string(data, &i) else { return [] }
                    args.append(.string(s))
                case "T": args.append(.int(1))
                case "F": args.append(.int(0))
                default: return [Message(address: head, args: args)]
                }
            }
        }
        return [Message(address: head, args: args)]
    }

    /// Encodes a message; for tests and replies.
    public static func encode(_ m: Message) -> [UInt8] {
        var out = pad(Array(m.address.utf8))
        var tags = ","
        var body: [UInt8] = []
        for a in m.args {
            switch a {
            case .int(let v):
                tags += "i"
                body += be(UInt32(bitPattern: v))
            case .float(let v):
                tags += "f"
                body += be(v.bitPattern)
            case .string(let s):
                tags += "s"
                body += pad(Array(s.utf8))
            }
        }
        out += pad(Array(tags.utf8)) + body
        return out
    }

    private static func pad(_ b: [UInt8]) -> [UInt8] {
        b + [UInt8](repeating: 0, count: 4 - b.count % 4)
    }

    private static func be(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static func int32(_ d: [UInt8], _ i: Int) -> Int32 {
        Int32(bitPattern: UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3]))
    }

    private static func string(_ d: [UInt8], _ i: inout Int) -> String? {
        guard i < d.count, let end = d[i...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: d[i..<end], as: UTF8.self)
        i = (end / 4 + 1) * 4
        return s
    }
}

/// Listens for OSC over UDP.
public final class OSCListener {
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
