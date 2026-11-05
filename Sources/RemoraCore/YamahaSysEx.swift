import Foundation

/// Yamaha CL/QL editor-port messages (TCP 50000): Yamaha parameter-change SysEx over TCP.
/// Decoded from captures of a QL1 on V5.70a; see docs/PROTOCOL.md.
///
/// Remora only ever SENDS read requests (`F0 43 3n …`). A parameter change (`F0 43 1n …`)
/// would change the desk, so `isReadRequest` guards every send.
public enum YamahaSysEx {
    /// The desk sends this once a second. Clients never answer it.
    public static let heartbeat: [UInt8] = [0xF0, 0x43, 0x10, 0x3E, 0x19, 0x7F, 0xF7]

    /// One parameter: element (two bytes), index (two bytes), channel.
    public struct Address: Hashable, Codable, CustomStringConvertible {
        public var element: Int
        public var index: Int
        public var channel: Int

        public init(element: Int, index: Int, channel: Int) {
            self.element = element
            self.index = index
            self.channel = channel
        }

        public var description: String {
            String(format: "0x%04X/0x%02X ch %d", element, index, channel)
        }
    }

    public struct Change: Equatable {
        public var address: Address
        public var value: Int32
        public init(address: Address, value: Int32) {
            self.address = address
            self.value = value
        }
    }

    /// The selected channel, of any type (inputs, ST IN halves, MIXes).
    public static let selectedChannel = Address(element: 0x0300, index: 0x12, channel: 0)
    /// The last selected input; not updated when an output is selected.
    public static let selectedInput = Address(element: 0x0300, index: 0x13, channel: 0)

    /// Elements that move whenever the selection or the fader bank does. Never offered for
    /// learning a control: they would fire on every SEL press.
    public static let selectionNoise: Set<Int> = [0x0300, 0x0309, 0x030A, 0x0609, 0x055B]

    /// Cuts complete `F0 … F7` messages off the front of `buffer`, leaving any partial one.
    public static func split(_ buffer: inout [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        while let start = buffer.firstIndex(of: 0xF0) {
            guard let end = buffer[start...].firstIndex(of: 0xF7) else {
                if start > 0 { buffer.removeFirst(start) }
                return out
            }
            out.append(Array(buffer[start...end]))
            buffer.removeFirst(end + 1)
        }
        buffer.removeAll()
        return out
    }

    /// `F0 43 1n 3E 19 01 EE EE II II CC CC D1 D2 D3 D4 D5 F7` — a change the desk reports, or
    /// its reply to a read request. The value is five 7-bit bytes, big-endian, signed 32-bit.
    public static func parseChange(_ m: [UInt8]) -> Change? {
        guard m.count == 18, m[0] == 0xF0, m[1] == 0x43, m[2] & 0xF0 == 0x10,
              m[3] == 0x3E, m[4] == 0x19, m[5] == 0x01, m[17] == 0xF7 else { return nil }
        let address = Address(element: Int(m[6]) << 8 | Int(m[7]),
                              index: Int(m[8]) << 8 | Int(m[9]),
                              channel: Int(m[10]) << 7 | Int(m[11]))
        var raw: UInt32 = 0
        for b in m[12...16] { raw = raw << 7 | UInt32(b & 0x7F) }
        return Change(address: address, value: Int32(bitPattern: raw))
    }

    /// `F0 43 30 3E 19 01 EE EE II II CC CC F7`. The desk answers with the parameter's value.
    public static func readRequest(_ a: Address) -> [UInt8] {
        [0xF0, 0x43, 0x30, 0x3E, 0x19, 0x01,
         UInt8((a.element >> 8) & 0x7F), UInt8(a.element & 0x7F),
         UInt8((a.index >> 8) & 0x7F), UInt8(a.index & 0x7F),
         UInt8((a.channel >> 7) & 0x7F), UInt8(a.channel & 0x7F),
         0xF7]
    }

    /// True only for a request (`F0 43 3n …`): the one kind of message Remora may send.
    public static func isReadRequest(_ m: [UInt8]) -> Bool {
        m.count >= 6 && m[0] == 0xF0 && m[1] == 0x43 && m[2] & 0xF0 == 0x30
            && m[3] == 0x3E && m[4] == 0x19 && m.last == 0xF7
            && !m.dropFirst().dropLast().contains(where: { $0 & 0x80 != 0 })
    }

    /// QL Editor's opening, captured from QL Editor connecting to the QL1 (2026-11-05). Every
    /// message is a read request. After it the desk streams every parameter change to the
    /// socket; without it, a client gets heartbeats and answers to its own reads only.
    public static let editorOpening: [[UInt8]] = [
        "f043303e1932f7", "f043303e193100f7",
        "f043303e1901037000000000f7", "f043303e1901037000010000f7",
        "f043303e1901035800000000f7", "f043303e1901035800010000f7",
        "f043303e1901032a00000000f7", "f043303e1901032a00010000f7", "f043303e1901032a00020000f7",
        "f043303e1901015c00010000f7", "f043303e1901015c00010001f7", "f043303e1901015c00010002f7",
        "f043303e1901015c00010003f7", "f043303e1901015c00010004f7", "f043303e1901015c00010005f7",
        "f043303e1901015d00000000f7", "f043303e1901015d00000001f7", "f043303e1901015d00000002f7",
        "f043303e1901015d00000003f7", "f043303e1901015d00000004f7", "f043303e1901015d00000005f7",
        "f043303e1901035e00000000f7", "f043303e1901035e00000001f7", "f043303e1901035e00000002f7",
        "f043303e1901035e00000003f7", "f043303e1901035e00000004f7", "f043303e1901035e00000005f7",
        "f043303e1901035e00000006f7", "f043303e1901035e00000007f7", "f043303e1901035e00000008f7",
        "f043303e1901035e00000009f7", "f043303e1901035e0000000af7", "f043303e1901035e0000000bf7",
        "f043303e1901035e0000000cf7", "f043303e1901035e0000000df7", "f043303e1901035e0000000ef7",
        "f043303e1901033e00000000f7",
        "f043303e19004c696252644d61785343454e455f5f5ff7", // "LibRdMaxSCENE___"
    ].map(bytes(hex:))

    static func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
}

/// A channel as the CL/QL selection numbers it (the CL5 frame, whatever the model):
/// InCh 0–71, ST IN halves 72–87 (ST IN 1 L = 72), MIX 88–111. Inputs, ST IN 1 L and MIX 1
/// were confirmed at a QL1; the rest of the ranges follow the frame's sizes. Anything above
/// 111 (matrices, stereo, mono) is kept as a raw number.
extension ConsoleChannel {
    public init(selection i: Int) {
        switch i {
        case 0..<72: self = .input(i + 1)
        case 72..<88: self = .stereoIn((i - 72) / 2 + 1, right: (i - 72) % 2 == 1)
        case 88..<112: self = .mix(i - 87)
        default: self = .other(i)
        }
    }

    /// The RCP parameter that holds this channel's name, and its index.
    public var rcpName: (path: String, index: Int)? {
        switch self {
        case .input(let n): return ("MIXER:Current/InCh/Label/Name", n - 1)
        case .stereoIn(let n, let right): return ("MIXER:Current/StInCh/Label/Name", (n - 1) * 2 + (right ? 1 : 0))
        case .mix(let n): return ("MIXER:Current/Mix/Label/Name", n - 1)
        default: return nil
        }
    }

    /// Every channel whose name the bridge reads from a CL/QL.
    public static let named: [ConsoleChannel] =
        (1...72).map { .input($0) }
        + (1...8).flatMap { [.stereoIn($0, right: false), .stereoIn($0, right: true)] }
        + (1...24).map { .mix($0) }
}
