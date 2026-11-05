import Foundation

/// The SuperRack MIDI Controller commands Remora drives. Their MIDI Learn names are SuperRack
/// Performer 15.15's, as its mapping export writes them.
public enum NavCommand: Int, CaseIterable, Codable {
    // Order = offset from the base CC, as first learned on Allan's rig (CC 20–25).
    case previousRack, openRack, nextRack, overview, previousPlugin, nextPlugin

    public var superRackName: String {
        switch self {
        case .previousRack: return "Previous Rack Navigation"
        case .openRack: return "Open Rack Tab"
        case .nextRack: return "Next Rack Navigation"
        case .overview: return "Return To Last Overview Tab"
        case .previousPlugin: return "Previous Plug-in Navigation"
        case .nextPlugin: return "Next Plug-in Navigation"
        }
    }

    public var title: String {
        switch self {
        case .previousRack: return "Previous rack"
        case .openRack: return "Open rack page"
        case .nextRack: return "Next rack"
        case .overview: return "Back to overview"
        case .previousPlugin: return "Previous plug-in"
        case .nextPlugin: return "Next plug-in"
        }
    }
}

/// Something that can say which rack SuperRack shows: `PluginWindowGuard`, which reads the name in
/// SuperRack's top bar through Accessibility.
public protocol RackNameReader: AnyObject {
    /// Cheap, never blocks: whether a read could answer now (Accessibility granted, SuperRack's
    /// rack field found, reading switched on).
    var canReadRackName: Bool { get }
    /// The rack's name as SuperRack shows it now, read fresh. Nil if it cannot be read.
    func readRackName() -> String?
}

/// Where SuperRack is, from the rack name its window shows, mapped through the session's racks.
/// A name only one rack has says where SuperRack is; a name several racks share ("n/a") says only
/// that it is one of them.
public enum RackSighting {
    /// The racks (0-based) a name could be. Exact: SuperRack shows the rack's own name.
    public static func candidates(_ name: String, in racks: [Rack], count: Int) -> [Int] {
        racks.filter { $0.index < count && $0.name == name }.map(\.index)
    }

    /// The position to move from, given the count (nil if there is none) and the name seen. A name
    /// one rack has wins over the count. A shared name keeps a count that is one of its racks and
    /// otherwise shows the count is wrong. Nil: no position, so home and count.
    public static func position(seen name: String, counted: Int?, racks: [Rack], count: Int) -> Int? {
        let c = candidates(name, in: racks, count: count)
        if c.count == 1 { return c[0] }
        if let p = counted, c.contains(p) { return p }
        return nil
    }
}

/// Moves SuperRack to a rack with Next/Previous Rack, which is all its MIDI offers.
///
/// What SuperRack does (measured on 15.15.12.13, docs/PROTOCOL.md): every message is one step
/// whatever its value; it stops at the first and last rack rather than wrapping; its MIDI never
/// says which rack it is on. So the driver keeps count. With no count (at start, or in
/// `.homeEveryTime` before every move) it first sends one Previous per rack, which lands on
/// rack 1 from anywhere, then counts Next from there.
///
/// With a `reader` (Accessibility granted, SuperRack running) it looks before each move: a rack
/// name only one rack has gives the position, so the trip to rack 1 is skipped and a click in
/// SuperRack is caught. After landing it checks that SuperRack shows the target's name; if not, and
/// the move did not home, it homes and counts once. Without a reader, or with a name it cannot
/// place, it counts exactly as before.
public final class SuperRackDriver {
    public enum Mode: String, Codable, CaseIterable {
        /// Back to rack 1 before every move. Slower, and right even after someone clicks a
        /// rack in SuperRack.
        case homeEveryTime
        /// Count from the last rack moved to. Fast; wrong after a click in SuperRack until
        /// the next Resync.
        case countFromLast
    }

    public struct Config: Equatable {
        public var channel = 16
        public var ccBase = 20
        public var spacing: TimeInterval = 0.002
        public var mode: Mode = .homeEveryTime
        public var openRackAfterMove = false
        /// How long after the last message the driver waits before reading SuperRack's window, so
        /// the window shows every step sent.
        public var settle: TimeInterval = 0.1
        public init() {}
    }

    public var config: Config {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }
    /// Racks in the session. A change forgets the count.
    public var rackCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _rackCount }
        set {
            lock.lock()
            if newValue != _rackCount { position = nil }
            _rackCount = max(1, newValue)
            lock.unlock()
        }
    }
    /// The session's racks, for placing the name SuperRack shows. Changing them keeps the count.
    public var racks: [Rack] {
        get { lock.lock(); defer { lock.unlock() }; return _racks }
        set { lock.lock(); _racks = newValue; lock.unlock() }
    }
    /// Reads the rack SuperRack shows. Nil, or unable to read: the driver only counts.
    public var reader: RackNameReader? {
        get { lock.lock(); defer { lock.unlock() }; return _reader }
        set { lock.lock(); _reader = newValue; lock.unlock() }
    }
    /// Called on the driver's queue after each move, with the 0-based rack, nil if unknown.
    public var onPosition: ((Int?) -> Void)?

    private let sink: CCSink
    private let queue = DispatchQueue(label: "remora.superrack")
    private let lock = NSLock()
    private var _config = Config()
    private var _rackCount = 64
    private var _racks: [Rack] = []
    private var _reader: RackNameReader?
    private var position: Int?
    private var target: Int?
    private var busy = false
    /// Resync asked for a counted homing: the window is not consulted until it is done.
    private var homeNext = false
    /// False after the window disagreed with a counted landing: it is not used for a start
    /// position until a landing agrees with it again.
    private var windowAgrees = true
    /// When the last rack message went out. Driver queue only.
    private var lastEmit = Date.distantPast

    public init(sink: CCSink) {
        self.sink = sink
    }

    /// 0-based, nil until the driver has homed.
    public var currentRack: Int? {
        lock.lock(); defer { lock.unlock() }
        return position
    }

    /// Moves to a rack (0-based). A new target while moving replaces the old one.
    public func select(_ rack: Int) {
        lock.lock()
        target = min(max(0, rack), _rackCount - 1)
        if _config.mode == .homeEveryTime && !busy { position = nil }
        lock.unlock()
        queue.async { self.run() }
    }

    /// Forgets the count and goes back to rack 1 by counting: Previous once per rack, whatever
    /// SuperRack's window says.
    public func resync() {
        lock.lock()
        position = nil
        target = 0
        homeNext = true
        lock.unlock()
        queue.async { self.run() }
    }

    /// One step or one other command, in order with any move in progress.
    public func send(_ command: NavCommand) {
        queue.async {
            self.lock.lock()
            self.target = nil
            switch command {
            case .nextRack: self.position = self.position.map { min($0 + 1, self._rackCount - 1) }
            case .previousRack: self.position = self.position.map { max($0 - 1, 0) }
            default: break
            }
            let p = self.position
            self.lock.unlock()
            self.emit(command)
            if command == .nextRack || command == .previousRack { self.onPosition?(p) }
        }
    }

    /// Any CC on the driver's channel, in order with moves (Companion, learned controls).
    public func sendRaw(number: Int, value: Int) {
        queue.async {
            self.sink.sendCC(channel: self.config.channel, number: number, value: value)
        }
    }

    /// Blocks until queued work is done. For tests and the command line.
    public func waitUntilIdle() {
        queue.sync {}
    }

    private func emit(_ c: NavCommand) {
        let cfg = config
        sink.sendCC(channel: cfg.channel, number: cfg.ccBase + c.rawValue, value: 127)
        lastEmit = Date()
        if cfg.spacing > 0 { Thread.sleep(forTimeInterval: cfg.spacing) }
    }

    /// The window as SuperRack shows it once every message sent has had time to show: read after
    /// `settle`, and again until two reads agree (a SuperRack still working through steps shows
    /// them changing). Nil without a reader that can read now (then nothing waits), or if the
    /// window will not hold still.
    private func readWindow() -> String? {
        guard let r = reader, r.canReadRackName else { return nil }
        let settle = config.settle
        let wait = lastEmit.addingTimeInterval(settle).timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        guard var last = r.readRackName() else { return nil }
        for _ in 0..<5 {
            if settle > 0 { Thread.sleep(forTimeInterval: min(0.03, settle)) }
            guard let now = r.readRackName() else { return nil }
            if now == last { return now }
            last = now
        }
        return nil
    }

    /// Before a move from rest: where the window says SuperRack is.
    private func look() {
        lock.lock()
        let skip = homeNext || !windowAgrees || _racks.isEmpty
        lock.unlock()
        guard !skip, let seen = readWindow() else { return }
        lock.lock()
        let was = position
        position = RackSighting.position(seen: seen, counted: was, racks: _racks, count: _rackCount)
        let now = position
        let label = now.flatMap { p in _racks.first { $0.index == p }?.label }
        let shared = RackSighting.candidates(seen, in: _racks, count: _rackCount).count
        lock.unlock()
        if let label, now != was {
            Log.line("SuperRack: its window shows \"\(seen)\": on rack \(label)")
        } else if now == nil {
            let why = shared == 0 ? "no rack in the session has that name"
                : was == nil ? "\(shared) racks have that name" : "not the counted rack"
            Log.line("SuperRack: its window shows \"\(seen)\", \(why): homing")
        }
    }

    /// After landing on `t`: does SuperRack show its name? True to stop, false to home and count
    /// again (only when this move did not home: the start position was wrong). A counted landing
    /// the window disagrees with keeps the count, and the window is not used for a start until it
    /// agrees again.
    private func landed(on t: Int, homed: Bool) -> Bool {
        lock.lock()
        let want = _racks.first { $0.index == t }?.name
        lock.unlock()
        guard let want, let seen = readWindow() else { return true }
        lock.lock()
        defer { lock.unlock() }
        if seen == want {
            windowAgrees = true
            return true
        }
        if homed {
            if windowAgrees { Log.line("SuperRack: its window shows \"\(seen)\" after counting to \"\(want)\": counting only until they agree") }
            windowAgrees = false
            return true
        }
        Log.line("SuperRack: its window shows \"\(seen)\", not \"\(want)\": homing")
        position = nil
        return false
    }

    private func run() {
        lock.lock()
        let fromRest = !busy && target != nil
        lock.unlock()
        if fromRest { look() }
        var homed = false
        while true {
            lock.lock()
            guard let t = target else {
                busy = false
                lock.unlock()
                return
            }
            busy = true
            guard let p = position else {
                let steps = _rackCount
                lock.unlock()
                for _ in 0..<steps { emit(.previousRack) }
                lock.lock()
                position = 0
                homeNext = false
                lock.unlock()
                homed = true
                continue
            }
            if p == t {
                lock.unlock()
                if !landed(on: t, homed: homed) { continue }
                lock.lock()
                // A new target came in while the window was read: carry on to it.
                guard target == t, position == t else {
                    lock.unlock()
                    continue
                }
                target = nil
                busy = false
                let open = _config.openRackAfterMove
                lock.unlock()
                if open { emit(.openRack) }
                onPosition?(t)
                return
            }
            position = t > p ? p + 1 : p - 1
            lock.unlock()
            emit(t > p ? .nextRack : .previousRack)
        }
    }
}
