import Foundation
import RemoraCore

/// Allen & Heath MIDI over TCP (port 51325), read-only, from A&H's own protocol documents:
///
/// - dLive MIDI Over TCP/IP Protocol, firmware V1.9;
/// - Avantis MIDI TCP/IP Protocol V1.10: the dLive's header and name messages, inputs 1–64;
/// - SQ MIDI Protocol Issue 5, firmware V1.5.0+;
/// - Qu Mixer MIDI Protocol, firmware V1.9+, issue 2.
///
/// None of this has met a desk: it is experimental (docs/PROTOCOL.md says what is documented and
/// what a capture still has to settle).
///
/// What each desk can tell Remora, by those documents:
/// - **Qu**: channel names (SysEx), and PAFL per channel (NRPN parameter 0x51). With the desk's
///   "Sel follows PAFL" on, PAFL is the selection, so Remora follows it. The Qu allows only one
///   TCP MIDI connection at a time.
/// - **dLive, Avantis**: channel names, but no selection and no PAFL for audio channels.
/// - **SQ**: neither names nor selection; only what its soft keys and MIDI strips send.
///
/// Notes and CCs the desk sends (soft keys, MIDI strips, mutes) come out as learnable controls.
public final class AllenHeathConsole: ConsoleLink {
    public enum Family: Equatable {
        case dLive, avantis, sq, qu

        var title: String {
            switch self {
            case .dLive: return "dLive"
            case .avantis: return "Avantis"
            case .sq: return "SQ"
            case .qu: return "Qu"
            }
        }

        /// The source learned controls are stored under. 0.3 stored "dLive / Avantis" for both
        /// desks, so it stays that for both: controls learned then keep working, on either entry.
        var controlSource: String {
            switch self {
            case .dLive, .avantis: return "dLive / Avantis"
            case .sq: return "SQ"
            case .qu: return "Qu"
            }
        }
    }

    public var onState: ((ConsoleState) -> Void)?
    public var onNamesLink: ((Bool) -> Void)?
    public var onModel: ((String) -> Void)?
    public var onSelected: ((ConsoleChannel) -> Void)?
    public var onNames: (([ConsoleChannel: String]) -> Void)?
    public var onControl: ((ControlSource, Int32) -> Void)?

    public let family: Family
    private let queue = DispatchQueue(label: "remora.allenheath")
    private let tcp: TCPStream
    private var parser = MIDIStreamParser()
    private var nrpn = NRPNAssembler()
    /// The desk's MIDI channel N, 0-based. The Qu says its own; dLive and SQ take the setting.
    private var channel: Int
    private var names: [ConsoleChannel: String] = [:]
    private var flush: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var lastData = Date()
    private var ticks = 0
    private var reported: ConsoleState = .stopped

    /// `midiChannel` is 1–16, as the desk's MIDI settings show it.
    public init(family: Family, host: String, midiChannel: Int, port: UInt16 = 51325, platform: Platform) {
        self.family = family
        channel = min(max(midiChannel, 1), 16) - 1
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

    // MARK: Sending (requests only)

    private func send(_ m: [UInt8]) {
        // The one rule: only requests to read. Anything else is a bug.
        precondition(AllenHeathMIDI.isReadRequest(m), "Remora sends only read requests to a console")
        tcp.send(m)
    }

    private func requestNames() {
        guard let header = AllenHeathMIDI.header(family) else { return }
        for (offset, ch) in AllenHeathMIDI.namedChannels(family) {
            send(header + [UInt8((channel + offset) & 0x0F), 0x01, UInt8(ch), 0xF7])
        }
    }

    // MARK: Receiving

    private func linkState(_ st: StreamState) {
        switch st {
        case .stopped: report(.stopped)
        case .connecting: report(.connecting)
        case .connected:
            parser = MIDIStreamParser()
            nrpn = NRPNAssembler()
            lastData = Date()
            report(.live)
            onModel?(family == .qu ? "Qu" : family.title)
            switch family {
            case .qu:
                // Asks the Qu which model and channel it is, and for its state (PAFL included).
                // iPadFlag 0: Remora is not Qu-Pad, so the desk expects no Active Sense from it.
                send(AllenHeathMIDI.quSystemStateRequest)
            case .dLive, .avantis:
                onNamesLink?(true)
                requestNames()
            case .sq:
                onNamesLink?(false)
            }
        case .failed(let why):
            onNamesLink?(false)
            report(.failed(why))
        }
    }

    private func report(_ s: ConsoleState) {
        guard s != reported else { return }
        reported = s
        onState?(s)
    }

    /// For tests: bytes as the desk would send them, handled on the link's queue.
    public func receiveForTesting(_ bytes: [UInt8]) { queue.sync { received(bytes) } }

    private func received(_ bytes: [UInt8]) {
        lastData = Date()
        for m in parser.feed(bytes) { handle(m) }
    }

    private func handle(_ m: MIDIStreamParser.Message) {
        switch m {
        case .sysEx(let s): sysEx(s)
        case .channel(let status, let d1, let d2):
            let ch = Int(status & 0x0F), kind = status & 0xF0
            if kind == 0xB0, let p = nrpn.feed(channel: ch, controller: Int(d1), value: Int(d2)) {
                if let p = p { parameter(p) }
                return
            }
            switch kind {
            case 0x90, 0x80:
                let v = kind == 0x80 ? 0 : Int32(d2)
                onControl?(.midi(source: family.controlSource, kind: .note, channel: ch + 1, number: Int(d1)), v)
            case 0xB0:
                onControl?(.midi(source: family.controlSource, kind: .cc, channel: ch + 1, number: Int(d1)), Int32(d2))
            default:
                break
            }
        }
    }

    private func sysEx(_ s: [UInt8]) {
        guard let header = AllenHeathMIDI.header(family), s.count > header.count + 2,
              Array(s.prefix(header.count)) == header else { return }
        let n = Int(s[header.count]), command = s[header.count + 1]
        let body = Array(s[(header.count + 2)..<(s.count - 1)])
        switch command {
        case 0x11 where family == .qu:
            // Sysex Header, 11, BoxID, Major, Minor, F7: the Qu's model, and its channel N.
            channel = n & 0x0F
            if let box = body.first { onModel?(AllenHeathMIDI.quModel(Int(box))) }
            onNamesLink?(true)
            requestNames()
        case 0x02:
            // Sysex Header (0N), 02, CH, Name, F7.
            guard let ch = body.first,
                  let target = AllenHeathMIDI.channel(family, offset: (n - channel) & 0x0F, number: Int(ch))
            else { return }
            let name = String(decoding: body.dropFirst().filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard names[target] != name else { return }
            names[target] = name
            flush?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.onNames?(self.names)
            }
            flush = w
            queue.asyncAfter(deadline: .now() + 0.2, execute: w)
        default:
            break
        }
    }

    /// A complete NRPN on the desk's channel. On a Qu, PAFL on (parameter 0x51, value 1) is the
    /// selection.
    private func parameter(_ p: NRPNAssembler.Parameter) {
        guard family == .qu, p.channel == channel, p.lsb == 0x51, p.value == 1,
              let ch = AllenHeathMIDI.channel(.qu, offset: 0, number: p.msb) else { return }
        onSelected?(ch)
    }

    private func tick() {
        guard tcp.state == .connected else { return }
        // A Qu sends Active Sense about every 300 ms when it has nothing else to say.
        if family == .qu, Date().timeIntervalSince(lastData) > 5 {
            tcp.reconnect(reason: "nothing from the desk for five seconds")
            return
        }
        ticks += 1
        if ticks % 30 == 0 { requestNames() }
    }
}

/// The bytes of A&H's MIDI protocols that Remora needs.
public enum AllenHeathMIDI {
    /// `F0 00 00 1A 50 <10 dLive and Avantis | 11 Qu> 01 00`, before the `0N` channel byte. SQ
    /// has no SysEx of its own.
    public static func header(_ f: AllenHeathConsole.Family) -> [UInt8]? {
        switch f {
        case .dLive, .avantis: return [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x10, 0x01, 0x00]
        case .qu: return [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x11, 0x01, 0x00]
        case .sq: return nil
        }
    }

    /// Get System State, All Call (`7F`), iPadFlag 0.
    public static let quSystemStateRequest: [UInt8] = [0xF0, 0x00, 0x00, 0x1A, 0x50, 0x11, 0x01, 0x00, 0x7F, 0x10, 0x00, 0xF7]

    /// True only for the requests Remora may send: Get Name (`01`) to a dLive, an Avantis (the
    /// dLive's header) or a Qu, and the Qu's Get System State (`10`). Never a Set, a NRPN, a
    /// note or a CC.
    public static func isReadRequest(_ m: [UInt8]) -> Bool {
        if m == quSystemStateRequest { return true }
        for f in [AllenHeathConsole.Family.dLive, .qu] {
            guard let h = header(f), m.count == h.count + 4, Array(m.prefix(h.count)) == h else { continue }
            let n = m[h.count], command = m[h.count + 1], ch = m[h.count + 2]
            return n <= 0x0F && command == 0x01 && ch < 0x80 && m.last == 0xF7
        }
        return false
    }

    /// The channels whose names Remora asks for, as (offset from N, CH).
    public static func namedChannels(_ f: AllenHeathConsole.Family) -> [(Int, Int)] {
        switch f {
        case .dLive:
            // Inputs 1–128 on N; FX returns 1–16 on N+4, CH 20–2F.
            return (0..<128).map { (0, $0) } + (0x20...0x2F).map { (4, $0) }
        case .avantis:
            // Inputs 1–64 on N (V1.10's range; V2.0 has 96, in a document not yet read).
            return (0..<64).map { (0, $0) }
        case .qu:
            // Inputs 1–32 (20–3F), stereo inputs (40–42), FX returns 1–4 (08–0B), mixes (60–66),
            // groups (68–6B). All on N.
            return ((0x20...0x3F).map { $0 } + (0x40...0x42).map { $0 } + (0x08...0x0B).map { $0 }
                    + (0x60...0x66).map { $0 } + (0x68...0x6B).map { $0 }).map { (0, $0) }
        case .sq:
            return []
        }
    }

    /// The desk's channel for a number in its protocol, `offset` being the MIDI channel above N
    /// (dLive's channel types; always 0 on a Qu).
    public static func channel(_ f: AllenHeathConsole.Family, offset: Int, number ch: Int) -> ConsoleChannel? {
        switch f {
        case .dLive:
            switch (offset, ch) {
            case (0, 0x00...0x7F): return .input(ch + 1)
            case (4, 0x20...0x2F): return .fxReturn(ch - 0x20 + 1)
            default: return nil
            }
        case .avantis:
            guard offset == 0, (0x00...0x3F).contains(ch) else { return nil }
            return .input(ch + 1)
        case .qu:
            guard offset == 0 else { return nil }
            switch ch {
            case 0x20...0x3F: return .input(ch - 0x20 + 1)
            case 0x40...0x42: return .stereo(ch - 0x40 + 1)
            case 0x08...0x0B: return .fxReturn(ch - 0x08 + 1)
            // Mix 1–4 are mono, then 5-6, 7-8, 9-10.
            case 0x60...0x63: return .mix(ch - 0x60 + 1)
            case 0x64...0x66: return .mix(5 + (ch - 0x64) * 2)
            // Groups 1-2, 3-4, 5-6, 7-8.
            case 0x68...0x6B: return .group(1 + (ch - 0x68) * 2)
            default: return nil
            }
        case .sq:
            return nil
        }
    }

    /// The Qu's BoxID.
    public static func quModel(_ box: Int) -> String {
        switch box {
        case 1: return "Qu-16"
        case 2: return "Qu-24"
        case 3: return "Qu-32"
        case 4: return "Qu-Pac"
        case 5: return "Qu-SB"
        default: return "Qu (model \(box))"
        }
    }
}

/// MIDI 1.0 bytes into messages: running status (dLive uses it), SysEx, and real-time bytes
/// (a Qu's Active Sense) anywhere, which are dropped.
public struct MIDIStreamParser {
    public enum Message: Equatable {
        case channel(status: UInt8, UInt8, UInt8)
        case sysEx([UInt8])
    }

    private var status: UInt8 = 0
    private var data: [UInt8] = []
    private var sysEx: [UInt8]?

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [Message] {
        var out: [Message] = []
        for b in bytes {
            if b >= 0xF8 { continue }                       // real time: clock, active sense
            if b == 0xF0 { sysEx = [b]; continue }
            if b == 0xF7 {
                if var s = sysEx { s.append(b); out.append(.sysEx(s)) }
                sysEx = nil
                continue
            }
            if var s = sysEx {
                if b & 0x80 == 0 {
                    s.append(b)
                    sysEx = s.count > 4096 ? nil : s
                    continue
                }
                sysEx = nil                                 // a status byte ends a broken SysEx
            }
            if b & 0x80 != 0 {
                status = b >= 0xF0 ? 0 : b                  // system common cancels running status
                data = []
                continue
            }
            guard status != 0 else { continue }
            data.append(b)
            let need = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
            if data.count == need {
                out.append(.channel(status: status, data[0], need == 2 ? data[1] : 0))
                data = []
            }
        }
        return out
    }
}

/// NRPN as A&H sends it: `BN 63 MSB, BN 62 LSB, BN 06 value, BN 26 index`. The parameter is
/// complete at the data entry LSB (26); a 06 with no 26 after it is not reported.
public struct NRPNAssembler {
    public struct Parameter: Equatable {
        public var channel: Int, msb: Int, lsb: Int, value: Int, index: Int
    }

    private var msb: [Int: Int] = [:], lsb: [Int: Int] = [:], value: [Int: Int] = [:]

    public init() {}

    /// Nil if the controller is not part of a NRPN (pass it on as a CC). `.some(nil)` if it is,
    /// and the parameter is not complete yet.
    public mutating func feed(channel: Int, controller: Int, value v: Int) -> Parameter?? {
        switch controller {
        case 0x63: msb[channel] = v; return .some(nil)
        case 0x62: lsb[channel] = v; return .some(nil)
        case 0x06: value[channel] = v; return .some(nil)
        case 0x26:
            guard let m = msb[channel], let l = lsb[channel], let d = value[channel] else { return .some(nil) }
            value[channel] = nil
            return .some(Parameter(channel: channel, msb: m, lsb: l, value: d, index: v))
        case 0x60, 0x61: return .some(nil)                 // A&H's "get" uses 60 7F
        default: return nil
        }
    }
}
