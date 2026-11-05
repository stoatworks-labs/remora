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

/// Moves SuperRack to a rack with Next/Previous Rack, which is all its MIDI offers.
///
/// What SuperRack does (measured on 15.15.12.13, docs/PROTOCOL.md): every message is one step
/// whatever its value; it stops at the first and last rack rather than wrapping; it never says
/// which rack it is on. So the driver keeps count. With no count (at start, or in
/// `.homeEveryTime` before every move) it first sends one Previous per rack, which lands on
/// rack 1 from anywhere, then counts Next from there.
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
        public var spacing: TimeInterval = 0.02
        public var mode: Mode = .homeEveryTime
        public var openRackAfterMove = false
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
    /// Called on the driver's queue after each move, with the 0-based rack, nil if unknown.
    public var onPosition: ((Int?) -> Void)?

    private let sink: CCSink
    private let queue = DispatchQueue(label: "remora.superrack")
    private let lock = NSLock()
    private var _config = Config()
    private var _rackCount = 64
    private var position: Int?
    private var target: Int?
    private var busy = false

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

    /// Forgets the count and goes back to rack 1.
    public func resync() {
        lock.lock()
        position = nil
        target = 0
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
        if cfg.spacing > 0 { Thread.sleep(forTimeInterval: cfg.spacing) }
    }

    private func run() {
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
                lock.unlock()
                continue
            }
            if p == t {
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
