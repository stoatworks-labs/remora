import Foundation
import RemoraCore

/// How Remora picks and reads Windows' MIDI ports (docs/ARCHITECTURE.md §8). Plain logic, so it is
/// tested on every system; `WinMMPort` does the calls.
///
/// Windows can't let Remora make a port of its own without a driver or Windows MIDI Services' App
/// SDK, so the user makes a loopback port once (loopMIDI, or a Windows MIDI Services loopback) and
/// names it as Remora's port (`Settings.midiPortName`, "Remora"). Remora sends on that port's
/// output; the host listens to its input.
public enum WindowsMIDIRules {
    /// WinMM keeps 31 characters of a port's name (`szPname` is 32 with its terminator).
    public static let nameLimit = 31

    /// The name as WinMM would show it, for comparing: no surrounding spaces, cut to 31
    /// characters, any case.
    static func comparable(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(nameLimit)).lowercased()
    }

    /// The two sides of a Windows MIDI Services loopback made from one name: `midi loopback create
    /// --root-name "Remora"` makes "Remora (A)" and "Remora (B)", each an input and an output in
    /// WinMM, and what goes out on A comes in on B (winlab, Tools 0.99.103-preview.14, 2026-11-22).
    static let pairSides = [" (a)", " (b)"]

    /// The name without a loopback pair's side, for comparing.
    static func root(_ name: String) -> String {
        let c = comparable(name)
        for side in pairSides where c.hasSuffix(side) { return String(c.dropLast(side.count)) }
        return c
    }

    /// The output to send on: the first named `name`, or else the A side of a Windows MIDI
    /// Services loopback made from that name, so the plug-in host listens to its B side. Nil if
    /// there is neither.
    public static func output(named name: String, in outputs: [String]) -> Int? {
        let want = comparable(name)
        guard !want.isEmpty else { return nil }
        if let exact = outputs.firstIndex(where: { comparable($0) == want }) { return exact }
        let sideA = comparable(name + " (A)")
        return outputs.firstIndex { comparable($0) == sideA }
    }

    /// Whether an input is Remora's own port: a loopback hands back what Remora sends, which
    /// Remora must never take for a control. Both sides of a loopback pair are its own: what
    /// Remora sends on A comes back on B.
    public static func isOwn(_ input: String, port name: String) -> Bool {
        root(input) == root(name)
    }

    /// A key for each input, so two of one kind can be told apart: "nanoKONTROL2",
    /// "nanoKONTROL2 #2". It is also the source name controls learn.
    public static func keys(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { n in
            let k = n.trimmingCharacters(in: .whitespaces)
            seen[k, default: 0] += 1
            let c = seen[k]!
            return c == 1 ? k : "\(k) #\(c)"
        }
    }

    /// A channel voice message as `midiOutShortMsg` takes it: the status in the low byte, then
    /// the two data bytes. `channel` is 1–16.
    public static func shortMessage(status: UInt8, channel: Int, _ data1: Int, _ data2: Int) -> UInt32 {
        UInt32(status & 0xF0 | UInt8((channel - 1) & 0x0F)) | UInt32(data1 & 0x7F) << 8 | UInt32(data2 & 0x7F) << 16
    }

    /// A CC or note heard on an input (`MIM_DATA`'s first parameter), as the Mac's port reads
    /// them: a note off is a note at 0. Anything else is nil.
    public static func event(_ message: UInt32, source: String) -> MIDIEvent? {
        let status = Int(message & 0xFF)
        let d1 = Int(message >> 8 & 0x7F), d2 = Int(message >> 16 & 0x7F)
        let ch = status & 0x0F + 1
        switch status & 0xF0 {
        case 0xB0: return MIDIEvent(source: source, kind: .cc, channel: ch, number: d1, value: d2)
        case 0x90: return MIDIEvent(source: source, kind: .note, channel: ch, number: d1, value: d2)
        case 0x80: return MIDIEvent(source: source, kind: .note, channel: ch, number: d1, value: 0)
        default: return nil
        }
    }

    /// Whether this Windows shares every MIDI port between programs: Windows MIDI Services does,
    /// and puts its own WinMM driver, `wdmaud2.drv`, among Drivers32's `midi` values (seen on
    /// Windows 11 25H2, 2026-11-22). Without it an input belongs to the first program to open it,
    /// and Remora would take a controller from the plug-in host.
    public static func sharesPorts(midiDrivers: [String]) -> Bool {
        midiDrivers.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "wdmaud2.drv" }
    }
}

/// Holds something while work goes on, and lets it go once there has been none for `idle`:
/// Windows' 1 ms timers while MIDI goes out (docs/ARCHITECTURE.md §8). `begin` and `end` are
/// called in turn, never twice in a row, under the hold's lock.
public final class BusyHold {
    private let idle: TimeInterval
    private let begin: () -> Void
    private let end: () -> Void
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "remora.busyhold")
    private var held = false
    private var last = Date.distantPast
    private var generation = 0

    public init(idle: TimeInterval, begin: @escaping () -> Void, end: @escaping () -> Void) {
        self.idle = idle
        self.begin = begin
        self.end = end
    }

    deinit { release() }

    /// Before each piece of work: holds, if not already.
    public func touch() {
        lock.lock()
        defer { lock.unlock() }
        last = Date()
        guard !held else { return }
        held = true
        begin()
        generation += 1
        check(after: idle, generation)
    }

    /// Lets go now.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        guard held else { return }
        held = false
        end()
    }

    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    private func check(after delay: TimeInterval, _ g: Int) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.held, self.generation == g else { return }
            let quiet = Date().timeIntervalSince(self.last)
            if quiet >= self.idle {
                self.held = false
                self.end()
            } else {
                self.check(after: self.idle - quiet, g)
            }
        }
    }
}
