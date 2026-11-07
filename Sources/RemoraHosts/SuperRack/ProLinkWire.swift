import Foundation

/// ProLink's framing between SuperRack and a console, as LAWO's mc² firmware 12.4.0.1 writes it
/// (its `waves_osc` scripts, waveslib.tcl) and as SuperRack Performer 15.15.12.13 answered it on
/// 2026-11-07 (docs/PROTOCOL.md). A 16-byte header (protocol version 1, "Wave", the command, one
/// int32), then a body for Init and OSC. Every integer is big-endian.
public enum ProLinkWire {
    public static let protocolVersion: UInt32 = 1
    public static let magic: [UInt8] = Array("Wave".utf8)
    public static let headerSize = 16
    /// dataFormat, the command set's major and minor version, a 16-byte GUID, the description's size.
    public static let initBodySize = 28
    /// waveslib.tcl refuses an Init with a longer description.
    public static let maxDescription = 256
    /// Remora's own bound on one OSC message.
    public static let maxOSC = 1 << 20
    /// waveslib.tcl's bounds on an Init's keepAlive, in ms. -1 means none.
    public static let keepAliveRange: ClosedRange<Int32> = 200...60000

    public enum Command: UInt32 {
        case initialize = 1, handshakeAck = 2, close = 3, iAmAlive = 4, osc = 5
    }

    /// Why a side closes the link, by waveslib.tcl's names.
    public enum Reason: Int32 {
        case keepAliveTimeout = 2, connectTimeout = 5, receivedBadHeader = 1001, alreadyConnected = 1002
        case notSupportedFormat = 1003, notSupportedProtocolVersion = 1004, consoleInLockState = 1005
        case disconnectRequestShutdown = 1006
    }

    public struct Hello: Equatable {
        public var keepAlive: Int32
        public var dataFormat: UInt32
        public var major: UInt16
        public var minor: UInt16
        public var guid: [UInt8]
        public var description: String
    }

    public enum Frame: Equatable {
        case initialize(Hello)
        case handshakeAck
        case close(Int32)
        case iAmAlive
        case osc([UInt8])
    }

    public enum WireError: Error, Equatable {
        case badHeader(String)
        case badInit(String)
        case tooLarge(Int)
    }

    // MARK: building

    public static func header(_ cmd: Command, _ value: Int32) -> [UInt8] {
        be32(protocolVersion) + magic + be32(cmd.rawValue) + be32(UInt32(bitPattern: value))
    }

    /// The console's Init, sent after SuperRack's: dataFormat 0 (OSC 1.1) and command set 1.0, as
    /// the mc² sends. SuperRack 15.15.12.13 announced 1.1 and took 1.0.
    public static func initMessage(keepAlive: Int32, description: String,
                                   guid: [UInt8] = Array(repeating: 0, count: 16)) -> [UInt8] {
        let desc = Array(description.utf8.prefix(maxDescription))
        precondition(guid.count == 16, "guid is 16 bytes")
        return header(.initialize, keepAlive) + be32(0) + be16(1) + be16(0) + guid
            + be32(UInt32(desc.count)) + desc
    }

    public static func handshakeAck() -> [UInt8] { header(.handshakeAck, 0) }
    public static func iAmAlive() -> [UInt8] { header(.iAmAlive, 0) }
    public static func close(_ reason: Reason) -> [UInt8] { header(.close, reason.rawValue) }

    public static func osc(_ message: ProLinkOSC.Message) -> [UInt8] {
        let data = ProLinkOSC.encode(message)
        return header(.osc, Int32(data.count)) + data
    }

    /// One remote command: `/waves.com/remote/<name>` with the int32 id first, then its arguments.
    public static func command(_ name: String, id: Int32, _ args: [ProLinkOSC.Arg]) -> [UInt8] {
        osc(.init(address: "/waves.com/remote/" + name, args: [.int(id)] + args))
    }

    // MARK: parsing

    /// Takes bytes as they arrive and returns whole frames. Throws on a header or Init outside the
    /// bounds above, so a bad peer is dropped rather than misread.
    public struct Parser {
        private var buffer: [UInt8] = []
        public init() {}

        public mutating func feed(_ bytes: [UInt8]) throws -> [Frame] {
            buffer += bytes
            var frames: [Frame] = []
            while let (frame, used) = try next() {
                frames.append(frame)
                buffer.removeFirst(used)
            }
            return frames
        }

        private func next() throws -> (Frame, Int)? {
            guard buffer.count >= headerSize else { return nil }
            let proto = rd32(buffer, 0)
            guard proto == protocolVersion, Array(buffer[4..<8]) == magic else {
                throw WireError.badHeader("protocol \(proto), magic \(Array(buffer[4..<8]))")
            }
            guard let cmd = Command(rawValue: rd32(buffer, 8)) else {
                throw WireError.badHeader("command \(rd32(buffer, 8))")
            }
            let value = Int32(bitPattern: rd32(buffer, 12))
            switch cmd {
            case .initialize:
                guard value == -1 || keepAliveRange.contains(value) else {
                    throw WireError.badHeader("keepAlive \(value)")
                }
                guard buffer.count >= headerSize + initBodySize else { return nil }
                let b = headerSize
                let descSize = Int(rd32(buffer, b + 24))
                let major = rd16(buffer, b + 4)
                guard descSize <= maxDescription, major != 0 else {
                    throw WireError.badInit("description \(descSize) bytes, major \(major)")
                }
                let total = headerSize + initBodySize + descSize
                guard buffer.count >= total else { return nil }
                let hello = Hello(keepAlive: value, dataFormat: rd32(buffer, b), major: major,
                                  minor: rd16(buffer, b + 6), guid: Array(buffer[(b + 8)..<(b + 24)]),
                                  description: String(decoding: buffer[(b + 28)..<total], as: UTF8.self))
                return (.initialize(hello), total)
            case .osc:
                guard value > 0 else { throw WireError.badHeader("OSC size \(value)") }
                guard Int(value) <= maxOSC else { throw WireError.tooLarge(Int(value)) }
                let total = headerSize + Int(value)
                guard buffer.count >= total else { return nil }
                return (.osc(Array(buffer[headerSize..<total])), total)
            case .handshakeAck: return (.handshakeAck, headerSize)
            case .close: return (.close(value), headerSize)
            case .iAmAlive: return (.iAmAlive, headerSize)
            }
        }
    }

    // MARK: bytes

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }
    static func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xffff_ffff)) }
    static func rd16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
    static func rd32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}

/// Just enough OSC 1.1 for ProLink: the types SuperRack sends back (int, string, float, bools and
/// the array markers of a rack list) and the int32 arguments it takes.
public enum ProLinkOSC {
    public enum Arg: Equatable, CustomStringConvertible {
        case int(Int32)
        case float(Float)
        case string(String)
        case bool(Bool)
        case int64(Int64)
        case double(Double)
        case arrayStart
        case arrayEnd
        case null

        var tag: Character {
            switch self {
            case .int: return "i"
            case .float: return "f"
            case .string: return "s"
            case .bool(let b): return b ? "T" : "F"
            case .int64: return "h"
            case .double: return "d"
            case .arrayStart: return "["
            case .arrayEnd: return "]"
            case .null: return "N"
            }
        }

        public var description: String {
            switch self {
            case .int(let v): return "\(v)"
            case .float(let v): return "\(v)f"
            case .string(let s): return "\"\(s)\""
            case .bool(let b): return b ? "T" : "F"
            case .int64(let v): return "\(v)h"
            case .double(let v): return "\(v)d"
            case .arrayStart: return "["
            case .arrayEnd: return "]"
            case .null: return "N"
            }
        }
    }

    public struct Message: Equatable, CustomStringConvertible {
        public var address: String
        public var args: [Arg]
        public init(address: String, args: [Arg]) {
            self.address = address
            self.args = args
        }
        /// The command's name, after `/waves.com/remote/`.
        public var command: String { String(address.split(separator: "/").last ?? "") }
        /// The leading int32: the command's id, given back in the reply to it.
        public var id: Int32? { if case .int(let i)? = args.first { return i } else { return nil } }
        public var description: String { ([command] + args.map(\.description)).joined(separator: " ") }
    }

    public static func encode(_ m: Message) -> [UInt8] {
        var out = string(m.address) + string("," + String(m.args.map(\.tag)))
        for a in m.args {
            switch a {
            case .int(let i): out += ProLinkWire.be32(UInt32(bitPattern: i))
            case .float(let f): out += ProLinkWire.be32(f.bitPattern)
            case .string(let s): out += string(s)
            case .int64(let i): out += ProLinkWire.be64(UInt64(bitPattern: i))
            case .double(let d): out += ProLinkWire.be64(d.bitPattern)
            case .bool, .arrayStart, .arrayEnd, .null: break
            }
        }
        return out
    }

    public static func decode(_ b: [UInt8]) -> Message? {
        var i = 0
        guard let address = readString(b, &i), address.hasPrefix("/") else { return nil }
        guard i < b.count else { return Message(address: address, args: []) }
        guard let tags = readString(b, &i), tags.hasPrefix(",") else { return nil }
        var args: [Arg] = []
        for t in tags.dropFirst() {
            switch t {
            case "i", "f":
                guard i + 4 <= b.count else { return nil }
                let v = ProLinkWire.rd32(b, i); i += 4
                args.append(t == "i" ? .int(Int32(bitPattern: v)) : .float(Float(bitPattern: v)))
            case "h", "d":
                guard i + 8 <= b.count else { return nil }
                let v = (UInt64(ProLinkWire.rd32(b, i)) << 32) | UInt64(ProLinkWire.rd32(b, i + 4)); i += 8
                args.append(t == "h" ? .int64(Int64(bitPattern: v)) : .double(Double(bitPattern: v)))
            case "s":
                guard let s = readString(b, &i) else { return nil }
                args.append(.string(s))
            case "T": args.append(.bool(true))
            case "F": args.append(.bool(false))
            case "[": args.append(.arrayStart)
            case "]": args.append(.arrayEnd)
            case "N": args.append(.null)
            default: return nil
            }
        }
        return Message(address: address, args: args)
    }

    static func string(_ s: String) -> [UInt8] {
        var b = Array(s.utf8) + [0]
        while b.count % 4 != 0 { b.append(0) }
        return b
    }

    static func readString(_ b: [UInt8], _ i: inout Int) -> String? {
        guard i < b.count, let end = b[i...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: b[i..<end], as: UTF8.self)
        i = (end + 4) & ~3
        return s
    }
}
