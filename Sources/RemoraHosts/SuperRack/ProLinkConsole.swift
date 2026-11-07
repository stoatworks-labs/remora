import Foundation
import RemoraCore

/// The console end of ProLink, as a LAWO mc² plays it for SuperRack's "ProLink LAWO Console
/// Remote" controller (docs/PROTOCOL.md).
///
/// SuperRack dials the console, on TCP 50002. The console:
/// - answers SuperRack's Init with its own, and is connected at SuperRack's HandshakeAck;
/// - keeps the link alive both ways with IAmAlive;
/// - asks for the racks (GetRacksInfo -1), and keeps them from NotifyRacksConfigChanged;
/// - sends commands one at a time, as the mc² does: the next goes when SuperRack answers
///   (ResultCommand, or the Give… for a Get…), or after `answerTimeout` without an answer.
///
/// Everything runs on `queue`: call every method on it. The callbacks come on it too.
public final class ProLinkConsole {
    public enum State: Equatable {
        case stopped
        case listening(UInt16)
        case handshaking(peer: String)
        /// `name` is the description SuperRack gave in its Init.
        case connected(peer: String, name: String)
        case failed(String)
    }

    /// SetViewMode's values in waveslib.tcl.
    public enum ViewMode: Int32 { case normal = 1, rack = 2, overview = 3 }

    /// Everything Remora may send SuperRack: the rack list, and showing and stepping racks,
    /// plug-ins and pages, as a console's rack keys do. `send` refuses any other command, so
    /// nothing that changes the audio or the session (snapshots, mutes, bypass, names) can go.
    public static let commands: Set<String> = ["GetRacksInfo", "ShowRack", "NavigateRack", "NavigatePlugin", "SetViewMode"]

    public let queue: DispatchQueue
    /// What SuperRack is told the console is called.
    public var consoleName = "Remora"
    /// The keepAlive Remora announces, in ms. SuperRack announced 2000 on 2026-11-07.
    public var keepAliveMs: Int32 = 2000
    /// How long a command waits for SuperRack's answer before the next goes anyway.
    public var answerTimeout: TimeInterval = 1
    public var onState: ((State) -> Void)?
    /// The racks, after each GiveRackInfo or NotifyRacksConfigChanged.
    public var onRacks: (([ProLinkRack]) -> Void)?
    /// Each ResultCommand: the id `send` gave, SuperRack's error (0 is OK) and its text.
    public var onResult: ((_ id: Int32, _ error: Int32, _ text: String) -> Void)?
    /// Every OSC message SuperRack sends, after the console has handled it.
    public var onMessage: ((ProLinkOSC.Message) -> Void)?
    public var onLog: ((String) -> Void)?
    /// The clock the timeouts read; tests set their own and call `tick`.
    var now: () -> DispatchTime = { .now() }

    public private(set) var state: State = .stopped {
        didSet { if state != oldValue { onState?(state) } }
    }
    public var isConnected: Bool { if case .connected = state { return true } else { return false } }
    public private(set) var racks: [ProLinkRack] = []

    private let listener: TCPListener
    private var link: TCPConnection?
    private var parser = ProLinkWire.Parser()
    private var peer = ""
    private var peerName = ""
    private var peerKeepAliveMs: Int32 = 2000
    private var lastHeard = DispatchTime.now()
    private var lastSent = DispatchTime.now()
    private var timer: DispatchSourceTimer?
    private var nextID: Int32 = 0
    private var racksRequest: Int32?
    private var running = false
    private var waiting: [(id: Int32, name: String, args: [ProLinkOSC.Arg])] = []
    /// The command sent and not yet answered, and when it went.
    private var inFlight: (id: Int32, sent: DispatchTime)?

    public init(listener: TCPListener, queue: DispatchQueue) {
        self.listener = listener
        self.queue = queue
        listener.onState = { [weak self] st in self?.listenerChanged(st) }
        listener.onConnection = { [weak self] c in self?.accept(c) }
    }

    public func start() {
        guard !running else { return }
        running = true
        listener.start()
    }

    public func stop() {
        running = false
        drop(reason: .disconnectRequestShutdown, why: "stopped")
        listener.stop()
        state = .stopped
    }

    // MARK: Commands

    /// Queues `/waves.com/remote/<name> id args…` and returns its id. Nil when SuperRack is not
    /// connected: nothing waits for the link, so a rack asked for while it is down is not shown later.
    /// Nil, and nothing sent, for a command that is not in `commands`.
    @discardableResult
    public func send(_ name: String, _ args: [ProLinkOSC.Arg] = []) -> Int32? {
        guard Self.commands.contains(name) else {
            log("\(name) not sent: Remora only shows and steps racks, plug-ins and pages")
            return nil
        }
        guard isConnected else { return nil }
        nextID = nextID == Int32.max ? 1 : nextID + 1
        waiting.append((nextID, name, args))
        pump()
        return nextID
    }

    /// Drops the queued commands with these names that have not gone yet, and returns their ids:
    /// a newer rack move makes them pointless.
    @discardableResult
    public func cancelWaiting(_ names: Set<String>) -> [Int32] {
        let gone = waiting.filter { names.contains($0.name) }.map(\.id)
        waiting.removeAll { names.contains($0.name) }
        return gone
    }

    /// Shows the rack this input channel (from 0) feeds, on SuperRack's Rack view.
    @discardableResult
    public func showRack(inputChannelIndex: Int) -> Int32? {
        send("ShowRack", [.int(Int32(inputChannelIndex))])
    }

    /// One rack on or back: NavigateRack 0 or 1, as the mc²'s Next and Previous Rack send them.
    @discardableResult
    public func navigateRack(next: Bool) -> Int32? { send("NavigateRack", [.int(next ? 0 : 1)]) }

    /// One plug-in on or back: NavigatePlugin 0 or 1, as the mc² sends them.
    @discardableResult
    public func navigatePlugin(next: Bool) -> Int32? { send("NavigatePlugin", [.int(next ? 0 : 1)]) }

    @discardableResult
    public func setViewMode(_ mode: ViewMode) -> Int32? { send("SetViewMode", [.int(mode.rawValue)]) }

    /// Asks for the whole rack list; `racks` and `onRacks` follow when it comes. Done by itself on
    /// every connect.
    @discardableResult
    public func requestRacks() -> Int32? {
        let id = send("GetRacksInfo", [.int(-1)])
        if id != nil { racksRequest = id }
        return id
    }

    public func rack(forInputChannel ch: Int) -> ProLinkRack? { racks.first { $0.takes(inputChannel: ch) } }

    public func rack(named name: String) -> ProLinkRack? {
        racks.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private func pump() {
        guard inFlight == nil, isConnected, let link, !waiting.isEmpty else { return }
        let c = waiting.removeFirst()
        inFlight = (c.id, now())
        link.send(ProLinkWire.command(c.name, id: c.id, c.args))
        log("TX \(([c.name, "\(c.id)"] + c.args.map(\.description)).joined(separator: " "))")
    }

    private func answered(_ id: Int32?) {
        guard let f = inFlight, id == f.id else { return }
        inFlight = nil
        pump()
    }

    // MARK: The link

    private func listenerChanged(_ st: ListenerState) {
        guard link == nil else { return }
        switch st {
        case .stopped: if !running { state = .stopped }
        case .listening(let p): state = .listening(p)
        case .failed(let why): state = .failed(why)
        }
    }

    private func accept(_ c: TCPConnection) {
        guard running else {
            c.close(after: [])
            return
        }
        if link != nil {
            // One SuperRack at a time: tell the newcomer why (waveslib.tcl's AlreadyConnected), and
            // let it go.
            log("refusing \(c.peer): SuperRack is already connected")
            c.close(after: ProLinkWire.close(.alreadyConnected))
            return
        }
        link = c
        parser = ProLinkWire.Parser()
        peer = c.peer
        peerName = ""
        racksRequest = nil
        waiting = []
        inFlight = nil
        lastHeard = now()
        state = .handshaking(peer: c.peer)
        log("connection from \(c.peer)")
        c.onData = { [weak self, weak c] bytes in
            guard let self, let c, self.link === c else { return }
            self.received(bytes)
        }
        c.onClose = { [weak self, weak c] why in
            guard let self, let c, self.link === c else { return }
            self.drop(reason: nil, why: why ?? "SuperRack closed the link")
        }
        c.start()
        startTimer()
    }

    private func received(_ bytes: [UInt8]) {
        lastHeard = now()
        let frames: [ProLinkWire.Frame]
        do {
            frames = try parser.feed(bytes)
        } catch {
            drop(reason: .receivedBadHeader, why: "bad data from SuperRack: \(error)")
            return
        }
        for f in frames {
            handle(f)
            if link == nil { return }   // that frame dropped the link
        }
    }

    private func handle(_ f: ProLinkWire.Frame) {
        switch f {
        case .initialize(let h):
            guard case .handshaking = state, peerName.isEmpty else {
                drop(reason: .receivedBadHeader, why: "a second Init")
                return
            }
            log("SuperRack's Init: keepAlive \(h.keepAlive) ms, format \(h.dataFormat), command set \(h.major).\(h.minor), \"\(h.description)\"")
            guard h.dataFormat == 0 else {
                drop(reason: .notSupportedFormat, why: "data format \(h.dataFormat)")
                return
            }
            guard h.major == 1 else {
                drop(reason: .notSupportedProtocolVersion, why: "command set \(h.major).\(h.minor)")
                return
            }
            peerKeepAliveMs = h.keepAlive > 0 ? h.keepAlive : keepAliveMs
            peerName = h.description.isEmpty ? "SuperRack" : h.description
            link?.send(ProLinkWire.initMessage(keepAlive: keepAliveMs, description: consoleName))
        case .handshakeAck:
            guard case .handshaking = state, !peerName.isEmpty else { return }
            state = .connected(peer: peer, name: peerName)
            requestRacks()
        case .iAmAlive:
            break
        case .close(let reason):
            drop(reason: nil, why: "SuperRack closed the link (reason \(reason))")
        case .osc(let bytes):
            guard let m = ProLinkOSC.decode(bytes) else {
                log("an OSC message that does not decode (\(bytes.count) bytes)")
                return
            }
            handle(m)
            onMessage?(m)
        }
    }

    private func handle(_ m: ProLinkOSC.Message) {
        switch m.command {
        case "GiveRackInfo":
            answered(m.id)
            let got = ProLinkRack.list(from: m.args)
            if m.id != nil && m.id == racksRequest {
                racksRequest = nil
                setRacks(got)
            } else {
                setRacks(merged(got))
            }
        case "NotifyRacksConfigChanged":
            setRacks(ProLinkRack.list(from: m.args))
        case "GiveNumRacks":
            answered(m.id)
            if m.args.count >= 2, case .int(let n) = m.args[1], Int(n) != racks.count, racksRequest == nil {
                requestRacks()
            }
        case "ResultCommand":
            guard m.args.count >= 2, case .int(let id) = m.args[0], case .int(let err) = m.args[1] else { return }
            var text = ""
            if m.args.count >= 3, case .string(let s) = m.args[2] { text = s }
            if err != 0 { log("SuperRack refused command \(id): error \(err) \(text)") }
            answered(id)
            onResult?(id, err, text)
        default:
            if m.command.hasPrefix("Give") { answered(m.id) }
        }
    }

    private func merged(_ updates: [ProLinkRack]) -> [ProLinkRack] {
        var all = racks
        for r in updates {
            if let i = all.firstIndex(where: { $0.index == r.index }) { all[i] = r } else { all.append(r) }
        }
        return all.sorted { $0.index < $1.index }
    }

    private func setRacks(_ new: [ProLinkRack]) {
        if new != racks {
            log("\(new.count) racks: " + new.map { r in
                "\(r.name) (\(r.firstInputChannel >= 0 ? "in \(r.firstInputChannel + 1)" : "no input"))"
            }.joined(separator: ", "))
        }
        racks = new
        onRacks?(new)
    }

    /// IAmAlive at half the shorter of the two keepAlives, so a late tick never misses SuperRack's.
    /// The link is dropped after three of SuperRack's keepAlives and a second without a word (the
    /// mc² waits two), or a handshake that takes over five seconds.
    private func startTimer() {
        timer?.cancel()
        lastSent = now()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// The timer's work, every 250 ms while SuperRack is connected or connecting.
    func tick() {
        guard let link else { return }
        let now = self.now()
        func ms(since t: DispatchTime) -> UInt64 {
            now.uptimeNanoseconds > t.uptimeNanoseconds ? (now.uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000 : 0
        }
        switch state {
        case .handshaking:
            if ms(since: lastHeard) > 5000 { drop(reason: .connectTimeout, why: "the handshake took over 5 s") }
        case .connected:
            let silent = ms(since: lastHeard)
            if silent > UInt64(3 * Int(peerKeepAliveMs) + 1000) {
                drop(reason: .keepAliveTimeout, why: "SuperRack silent for \(silent) ms")
                return
            }
            let every = UInt64(max(200, Int(min(keepAliveMs, peerKeepAliveMs)) / 2))
            if ms(since: lastSent) >= every {
                lastSent = now
                link.send(ProLinkWire.iAmAlive())
            }
            if let f = inFlight, Double(ms(since: f.sent)) > answerTimeout * 1000 {
                log("no answer to command \(f.id) within \(answerTimeout) s: sending the next")
                inFlight = nil
                pump()
            }
        default:
            break
        }
    }

    private func drop(reason: ProLinkWire.Reason?, why: String) {
        guard let c = link else { return }
        timer?.cancel()
        timer = nil
        link = nil
        c.onData = nil
        c.onClose = nil
        racksRequest = nil
        waiting = []
        inFlight = nil
        log("dropped: \(why)")
        c.close(after: reason.map { ProLinkWire.close($0) } ?? [])
        guard running else {
            state = .stopped
            return
        }
        switch listener.state {
        case .listening(let p): state = .listening(p)
        case .failed(let w): state = .failed(w)
        case .stopped: state = .failed(why)
        }
    }

    private func log(_ s: String) { onLog?(s) }
}
