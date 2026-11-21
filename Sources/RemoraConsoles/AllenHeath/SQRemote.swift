import Foundation
import RemoraCore

/// The SQ's remote protocol: what SQ MixPad speaks to the desk over TCP 51326, read-only.
///
/// A&H does not document it. Everything here was read off captures of SQ MixPad 1.6.0 talking to
/// a real SQ-5, and off Remora's own probe of that desk (2026-11-21); MixPad's own symbols name
/// the messages. docs/PROTOCOL.md has the captures, and what they leave open.
///
/// Frames are `7F type len32-LE payload`, or `F7` and seven bytes (a short message). A message
/// (frame type 08, or a short one) is `source, recipient, parameter, data…`.
///
/// Remora's opening is the smallest one the desk was seen to accept: hello (announcing UDP port 0,
/// so the desk sends no meters), DiscoveryRequest, FeatureSetRequest (without it the desk sends no
/// live messages), MixPad's MessageFilter, SceneSyncRequest (the desk's whole state, names in it),
/// then one ask for the selected channel. A keepalive every second holds the link: the desk drops a
/// client it has heard nothing from for about six seconds. MixPad also sets the desk's clock
/// (frame 1A) when it connects. Remora never does, and never sends any other frame.
public enum SQRemote {
    public static let port: UInt16 = 51326
    /// Where the desk answers "SQ Find" with its model ("SQ-5").
    public static let findPort: UInt16 = 51320

    public static func frame(_ type: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        let n = UInt32(payload.count)
        return [0x7F, type, UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)] + payload
    }

    /// Hello, announcing UDP port 0: the desk keeps the link and sends no meters to anyone.
    public static let hello = frame(0x00, [0x00, 0x00])
    public static let discoveryRequest = frame(0x01)
    /// FeatureSetRequest 2, as MixPad asks. The desk answers `7F 0C 01 00` and only then sends
    /// live messages.
    public static let featureSetRequest = frame(0x0B, [0x02, 0x00])
    public static let sceneSyncRequest = frame(0x03)
    public static let keepAlive = frame(0x05)
    /// Asks recipient 09 which channel is selected; the desk answers with a selection message.
    public static let selectionRequest: [UInt8] = [0xF7, 0x09, 0x09, 0x2F, 0x00, 0x00, 0x00, 0x00]
    /// The discovery datagram MixPad broadcasts; Remora sends it to the desk alone.
    public static let find: [UInt8] = Array("SQ Find".utf8)

    /// The recipients MixPad's MessageFilter lets through (every message to each). 09 carries the
    /// selection, 18 names and colours.
    public static let filterRecipients: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x04, 0x07, 0x09, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13,
        0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x23, 0x24, 0x25, 0x26,
        0x27, 0x28, 0x29, 0x2B, 0x2D, 0x2F, 0x30, 0x34, 0x36,
    ]

    /// MessageFilter (frame 0A): 32 bytes for each of 0x100 recipients, a bit per message, set
    /// for the messages to be sent. It chooses what the desk tells Remora, and changes nothing on it.
    public static let messageFilter: [UInt8] = {
        var f = [UInt8](repeating: 0, count: 0x2000)
        for r in filterRecipients { for i in 0..<32 { f[Int(r) * 32 + i] = 0xFF } }
        return frame(0x0A, f)
    }()

    /// True only for the bytes Remora may send an SQ: the opening above, the keepalive, the ask
    /// for the selection, and "SQ Find". Never a message that sets anything, and never the clock.
    public static func isReadRequest(_ m: [UInt8]) -> Bool {
        [hello, discoveryRequest, featureSetRequest, messageFilter, sceneSyncRequest, keepAlive,
         selectionRequest, find].contains(m)
    }

    public enum Message: Equatable {
        /// A frame that is not a message: its type and payload.
        case frame(UInt8, [UInt8])
        /// A message (frame type 08, or a short F7 one).
        case message(source: UInt8, recipient: UInt8, parameter: UInt8, data: [UInt8])
    }

    /// The desk's byte stream into frames and messages.
    public struct Parser {
        private var buffer: [UInt8] = []
        /// A frame longer than this is taken as the stream being out of step (the whole state of
        /// an SQ-5 is 97 KB).
        static let longest = 1 << 22

        public init() {}

        public mutating func feed(_ bytes: [UInt8]) -> [Message] {
            buffer += bytes
            var out: [Message] = [], i = 0
            scan: while i < buffer.count {
                switch buffer[i] {
                case 0x7F:
                    guard buffer.count - i >= 6 else { break scan }
                    let n = Int(buffer[i + 2]) | Int(buffer[i + 3]) << 8 | Int(buffer[i + 4]) << 16 | Int(buffer[i + 5]) << 24
                    guard n <= Self.longest else { i += 1; continue }
                    guard buffer.count - i >= 6 + n else { break scan }
                    let type = buffer[i + 1], p = Array(buffer[(i + 6)..<(i + 6 + n)])
                    i += 6 + n
                    if type == 0x08, p.count >= 3 {
                        out.append(.message(source: p[0], recipient: p[1], parameter: p[2], data: Array(p.dropFirst(3))))
                    } else {
                        out.append(.frame(type, p))
                    }
                case 0xF7:
                    guard buffer.count - i >= 8 else { break scan }
                    out.append(.message(source: buffer[i + 1], recipient: buffer[i + 2], parameter: buffer[i + 3],
                                        data: Array(buffer[(i + 4)..<(i + 8)])))
                    i += 8
                default:
                    i += 1                                  // nothing belongs between frames: skip it
                }
            }
            buffer.removeFirst(i)
            return out
        }
    }

    /// The strip a selection message names: recipient 09, parameter 0C, data
    /// `[surface position] 00 [strip type] [strip]`. Only strip type 1 (MixPad's
    /// CH_STRIP_TYPE_CHANNEL) is a channel; 2 is a DCA and 3 a MIDI strip, which have no racks.
    public static func selectedStrip(_ m: Message) -> Int? {
        guard case .message(_, 0x09, 0x0C, let d) = m, d.count == 4, d[2] == 0x01 else { return nil }
        return Int(d[3])
    }

    /// A name change: recipient 18, parameter 07, data `[type] [index] 00 00 name… 00`. Type 0 is
    /// a channel (1 and 2 are DCAs and mute groups in MixPad).
    public static func renamed(_ m: Message) -> (strip: Int, name: String)? {
        guard case .message(_, 0x18, 0x07, let d) = m, d.count >= 4, d[0] == 0x00 else { return nil }
        return (Int(d[1]), text(d.dropFirst(4)))
    }

    /// Channel names (by strip) from the state the desk sends for SceneSyncRequest (frame 04).
    /// Its section 02 (after `02 A5 A5 A5`) is 122 records of 336 bytes, each a channel's name
    /// (ASCII, NUL-padded) first; section 03 follows. Nil if the state is not laid out so.
    public static func names(fromState s: [UInt8]) -> [Int: String]? {
        let marker: [UInt8] = [0x02, 0xA5, 0xA5, 0xA5], next: [UInt8] = [0x03, 0xA5, 0xA5, 0xA5]
        guard let at = find(marker, in: s) else { return nil }
        let first = at + 4, end = first + records * recordSize
        guard end + 4 <= s.count, Array(s[end..<(end + 4)]) == next else { return nil }
        var out: [Int: String] = [:]
        for r in 0..<records {
            let o = first + r * recordSize
            let name = text(s[o..<(o + nameField)])
            if !name.isEmpty { out[r] = name }
        }
        return out
    }

    static let records = 122, recordSize = 336
    /// The name's bytes in a record: the desk's names are short, and byte 13 on is other data.
    static let nameField = 13

    /// The channel a strip is, where the captures say: inputs 1–64 (an SQ-5 has 48; a stereo pair
    /// is its odd channel), FX returns 1–8, groups 1–16, auxes 1–16 (MixPad's own ranges, with
    /// strip 72 Group 1 and the FX return and aux pressed on the desk landing in theirs), and LR.
    /// The rest (105–122) are `.other`: the desk's Matrix 6 is strip 119, which MixPad's ranges
    /// make the fifth of 115–122, so their numbering is not settled.
    public static func channel(strip s: Int) -> ConsoleChannel {
        switch s {
        case 0...63: return .input(s + 1)
        case 64...71: return .fxReturn(s - 63)
        case 72...87: return .group(s - 71)
        case 88...103: return .aux(s - 87)
        case 104: return .main(1)
        default: return .other(s)
        }
    }

    static func text<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(decoding: bytes.prefix { $0 != 0 }.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }
}

/// An SQ's remote port (TCP 51326): the selected channel and channel names, read-only.
public final class SQRemoteLink {
    public var onState: ((ConsoleState) -> Void)?
    public var onNamesLink: ((Bool) -> Void)?
    public var onModel: ((String) -> Void)?
    public var onSelected: ((ConsoleChannel) -> Void)?
    public var onNames: (([ConsoleChannel: String]) -> Void)?

    private let queue = DispatchQueue(label: "remora.allenheath.sq")
    private let tcp: TCPStream
    private let finder: UDPLink
    private var parser = SQRemote.Parser()
    /// The desk answered the hello: the keepalive may start.
    private var greeted = false
    private var live = false
    private var names: [Int: String] = [:]
    private var selected: ConsoleChannel?
    private var model: String?
    private var flush: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var lastData = Date()
    private var reported: ConsoleState = .stopped

    public init(host: String, port: UInt16 = SQRemote.port, platform: Platform) {
        tcp = platform.tcp(host: host, port: port, queue: queue)
        finder = platform.udp(host: host, port: SQRemote.findPort, queue: queue)
        tcp.onState = { [weak self] st in self?.linkState(st) }
        tcp.onData = { [weak self] bytes in self?.received(bytes) }
        // "SQ Find" once a connection is up: whichever of the two is ready second sends it.
        finder.onState = { [weak self] st in
            if st == .connected, self?.tcp.state == .connected { self?.sendFind() }
        }
        finder.onDatagram = { [weak self] d in self?.found(d) }
    }

    public func start() {
        queue.async {
            self.tcp.start()
            self.finder.start()
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
            finder.stop()
        }
    }

    /// For tests: bytes as the desk would send them, handled on the link's queue.
    public func receiveForTesting(_ bytes: [UInt8]) { queue.sync { received(bytes) } }

    // MARK: Sending (reads only)

    private func send(_ m: [UInt8]) {
        // The one rule: nothing that changes the desk. Anything not on the list is a bug.
        precondition(SQRemote.isReadRequest(m), "Remora sends only read requests to a console")
        tcp.send(m)
    }

    private func sendFind() {
        precondition(SQRemote.isReadRequest(SQRemote.find), "Remora sends only read requests to a console")
        finder.send(SQRemote.find)
    }

    // MARK: Receiving

    private func linkState(_ st: StreamState) {
        switch st {
        case .stopped: report(.stopped)
        case .connecting: report(.connecting)
        case .connected:
            parser = SQRemote.Parser()
            greeted = false
            live = false
            names = [:]
            selected = nil
            lastData = Date()
            report(.waitingForDesk)
            send(SQRemote.hello)
            if finder.state == .connected { sendFind() }
        case .failed(let why):
            if live { onNamesLink?(false) }
            live = false
            report(.failed(why))
        }
    }

    private func report(_ s: ConsoleState) {
        guard s != reported else { return }
        reported = s
        onState?(s)
    }

    private func found(_ d: [UInt8]) {
        let m = SQRemote.text(d)
        guard m.hasPrefix("SQ"), m != model else { return }
        model = m
        onModel?(m)
    }

    private func received(_ bytes: [UInt8]) {
        lastData = Date()
        for m in parser.feed(bytes) { handle(m) }
    }

    private func handle(_ m: SQRemote.Message) {
        switch m {
        case .frame(0x00, _):
            // The desk's hello (its own UDP port, which Remora has no use for).
            greeted = true
            send(SQRemote.discoveryRequest)
        case .frame(0x02, _):
            // Box info.
            send(SQRemote.featureSetRequest)
        case .frame(0x0C, _):
            send(SQRemote.messageFilter)
            send(SQRemote.sceneSyncRequest)
        case .frame(0x04, let state):
            let read = SQRemote.names(fromState: state)
            if let read {
                names = read
                publishNames(now: true)
            }
            if !live {
                live = true
                // The desk's model comes from "SQ Find", usually just after the state. A desk
                // that does not answer it is still an SQ.
                queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.live, self.model == nil else { return }
                    self.model = "SQ"
                    self.onModel?("SQ")
                }
                report(.live)
                // Names come with the state; a state laid out otherwise has none Remora can read.
                onNamesLink?(read != nil)
            }
            send(SQRemote.selectionRequest)
        default:
            if let s = SQRemote.selectedStrip(m) {
                let ch = SQRemote.channel(strip: s)
                guard ch != selected else { return }
                selected = ch
                onSelected?(ch)
            } else if let r = SQRemote.renamed(m) {
                let name: String? = r.name.isEmpty ? nil : r.name
                guard names[r.strip] != name else { return }
                names[r.strip] = name
                publishNames(now: false)
            }
        }
    }

    /// The names, keyed by channel. A strip's record is its own: SEL on the strip whose record
    /// says "roof" gave strip 119, and record 119 is that one.
    private func publishNames(now: Bool) {
        flush?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var out: [ConsoleChannel: String] = [:]
            for (s, n) in self.names { out[SQRemote.channel(strip: s)] = n }
            self.onNames?(out)
        }
        flush = w
        if now { w.perform() } else { queue.asyncAfter(deadline: .now() + 0.2, execute: w) }
    }

    private func tick() {
        guard tcp.state == .connected else { return }
        if Date().timeIntervalSince(lastData) > 5 {
            tcp.reconnect(reason: "nothing from the desk for five seconds")
            return
        }
        if greeted { send(SQRemote.keepAlive) }
    }
}

/// An SQ: the remote port (TCP 51326) for the selected channel and names, and MIDI over TCP
/// (51325) for soft keys and MIDI strips learned as controls. Both read-only.
///
/// The link is live when the remote port is. A desk whose remote port does not answer (one that
/// speaks only the SQ's MIDI, as a Qu-5/6/7 may) is still live on MIDI alone, for its controls,
/// as this entry was before it read the remote port.
public final class AllenHeathSQConsole: ConsoleLink {
    public var onState: ((ConsoleState) -> Void)?
    public var onNamesLink: ((Bool) -> Void)?
    public var onModel: ((String) -> Void)?
    public var onSelected: ((ConsoleChannel) -> Void)?
    public var onNames: (([ConsoleChannel: String]) -> Void)?
    public var onControl: ((ControlSource, Int32) -> Void)?

    public let remote: SQRemoteLink
    public let midi: AllenHeathConsole
    /// The two links call in on their own queues.
    private let lock = NSLock()
    private var remoteState: ConsoleState = .stopped, midiState: ConsoleState = .stopped
    private var reported: ConsoleState = .stopped

    /// `midiChannel` is 1–16, as the desk's MIDI settings show it.
    public init(host: String, midiChannel: Int, platform: Platform) {
        remote = SQRemoteLink(host: host, platform: platform)
        midi = AllenHeathConsole(family: .sq, host: host, midiChannel: midiChannel, platform: platform)
        remote.onState = { [weak self] st in self?.state(remote: st) }
        remote.onNamesLink = { [weak self] up in self?.onNamesLink?(up) }
        remote.onModel = { [weak self] m in self?.onModel?(m) }
        remote.onSelected = { [weak self] ch in self?.onSelected?(ch) }
        remote.onNames = { [weak self] n in self?.onNames?(n) }
        midi.onState = { [weak self] st in self?.state(midi: st) }
        midi.onModel = { [weak self] m in
            guard let self, self.lock.withLock({ self.remoteState != .live }) else { return }
            self.onModel?(m)
        }
        midi.onControl = { [weak self] src, v in self?.onControl?(src, v) }
    }

    private func state(remote r: ConsoleState? = nil, midi m: ConsoleState? = nil) {
        let s: ConsoleState? = lock.withLock {
            if let r { remoteState = r }
            if let m { midiState = m }
            let s = remoteState == .live || midiState != .live ? remoteState : midiState
            guard s != reported else { return nil }
            reported = s
            return s
        }
        if let s { onState?(s) }
    }

    public func start() {
        remote.start()
        midi.start()
    }

    public func stop() {
        remote.stop()
        midi.stop()
    }
}
