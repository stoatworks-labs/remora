import Foundation
import RemoraCore

/// One MIDI message to a host, on its channel.
public enum MIDIHostMessage: Equatable, CustomStringConvertible {
    case cc(number: Int, value: Int)
    case programChange(Int)

    public var description: String {
        switch self {
        case .cc(let n, let v): return "CC \(n) = \(v)"
        case .programChange(let p): return "Program Change \(p)"
        }
    }
}

/// What one MIDI host needs said: how it shows and steps, and what Remora may send it. A MIDI
/// host never answers, so its racks are the ones the user types (`HostSettings.racks`) and where
/// it is is only what Remora last sent. Each MIDI host module is one of these run by
/// `MIDIHostModule` (docs/ARCHITECTURE.md §2.4).
public struct MIDIHostSpec {
    public var info: ModuleInfo
    /// The messages that show rack `index` (0-based) of the typed `racks`; empty if the host
    /// can't show that one.
    public var show: (_ index: Int, _ racks: [Rack]) -> [MIDIHostMessage]
    /// The messages for one step on (+1) or back (-1); nil to step by showing the rack beside the
    /// one Remora last showed.
    public var step: ((Int) -> [MIDIHostMessage])?
    /// The send whitelist: true only for a message Remora may send this host.
    public var isAllowed: (MIDIHostMessage) -> Bool
    /// A host with no way to show a rack by number (Logic): a show counts steps from where Remora
    /// last left it, first stepping back once per typed rack (to the first) when it doesn't
    /// know, and Resync does that too. Needs `step`.
    public var counts: Bool
    /// The least time between two messages, for a host that drops ones that come too fast.
    public var spacing: TimeInterval

    public init(info: ModuleInfo, show: @escaping (Int, [Rack]) -> [MIDIHostMessage] = { _, _ in [] },
                step: ((Int) -> [MIDIHostMessage])? = nil, counts: Bool = false, spacing: TimeInterval = 0,
                isAllowed: @escaping (MIDIHostMessage) -> Bool) {
        precondition(!counts || step != nil, "a counted host needs a step")
        self.info = info
        self.show = show
        self.step = step
        self.counts = counts
        self.spacing = spacing
        self.isAllowed = isAllowed
    }
}

/// A host on Remora's MIDI port, on the channel its settings give. Everything runs on its own
/// queue, in order.
public final class MIDIHostModule: HostModule {
    public let spec: MIDIHostSpec
    public var onEvent: ((HostEvent) -> Void)?

    private let queue: DispatchQueue
    private let out: CCSink?
    private var own: HostSettings
    // On `queue`:
    private var racks: [Rack] = []
    private var position: Int?
    private var said: Set<String> = []

    public init(_ spec: MIDIHostSpec, _ context: ModuleContext) {
        self.spec = spec
        out = context.midiOut
        own = context.settings.host(spec.info.id)
        queue = DispatchQueue(label: "remora.host.\(spec.info.id)")
    }

    private var product: String { spec.info.product }
    private var channel: Int { own.midiChannel(spec.info.hostDefaults) }

    /// Showing a rack loads it and the user hasn't ticked that they understand: nothing is sent.
    private var held: Bool {
        spec.info.capabilities.contains(.showChangesSound) && !own.showChangesSoundAccepted
    }

    public func start() {
        queue.sync {
            if out == nil { onEvent?(.problem("Remora's MIDI port could not be made, so nothing reaches \(product)")) }
            setRacks()
        }
    }

    public func stop() {}

    public func update(_ settings: Settings) {
        let new = settings.host(spec.info.id)
        queue.sync {
            let old = own
            own = new
            if new.racks != old.racks { setRacks() }
            // Another channel is another set of ears: what was sent before says nothing.
            if new.midiChannel(spec.info.hostDefaults) != old.midiChannel(spec.info.hostDefaults), position != nil {
                position = nil
                onEvent?(.position(nil))
            }
        }
    }

    public func perform(_ command: HostCommand) {
        queue.async { [weak self] in self?.run(command) }
    }

    /// For tests: waits until everything performed so far has been sent.
    public func waitUntilIdle() { queue.sync {} }

    // MARK: On `queue`

    private func setRacks() {
        let new = own.typedRacks
        guard new != racks else { return }
        racks = new
        onEvent?(.racks(new))
    }

    private func send(_ m: MIDIHostMessage) {
        // The one rule: only what this host's whitelist lists. Anything else is a bug.
        precondition(spec.isAllowed(m), "\(product): \(m) is not on the send whitelist")
        switch m {
        case .cc(let n, let v): out?.sendCC(channel: channel, number: n, value: v)
        case .programChange(let p): out?.sendProgramChange(channel: channel, program: p)
        }
        if spec.spacing > 0 { Thread.sleep(forTimeInterval: spec.spacing) }
    }

    /// For a counted host: steps back once per typed rack, which reaches the first from anywhere
    /// in the list.
    private func home() {
        guard let step = spec.step else { return }
        for _ in 0..<max(racks.count, 1) { for m in step(-1) { send(m) } }
        moved(to: 0)
    }

    /// For a counted host: from where Remora last left it, or from the first after homing.
    private func count(to t: Int) {
        guard let step = spec.step else { return }
        guard racks.isEmpty || t < racks.count else {
            return once("show\(t)", "\(product): rack \(t + 1) can't be shown: it isn't one of the racks typed for it")
        }
        if position == nil { home() }
        guard let p = position, p != t else { return }
        for _ in 0..<abs(t - p) { for m in step(t > p ? 1 : -1) { send(m) } }
        moved(to: t)
    }

    private func moved(to p: Int?) {
        guard p != position else { return }
        position = p
        onEvent?(.position(p))
    }

    private func clamp(_ p: Int) -> Int { racks.isEmpty ? max(0, p) : min(max(0, p), racks.count - 1) }

    private func run(_ command: HostCommand) {
        // The engine's gate holds these already (`Bridge.hostPerform`); this is the second lock.
        guard !held else { return }
        switch command {
        case .show(let i):
            // Showing again would load it again: a patch's changes reverted, a performance reloaded.
            if position == i, spec.info.capabilities.contains(.showChangesSound) { return }
            if spec.counts { return count(to: i) }
            let ms = spec.show(i, racks)
            guard !ms.isEmpty else {
                return once("show\(i)", "\(product): rack \(i + 1) can't be shown: it isn't one of the racks typed for it")
            }
            for m in ms { send(m) }
            moved(to: i)
        case .step(let d):
            if let step = spec.step {
                for m in step(d) { send(m) }
                if let p = position { moved(to: clamp(p + d)) }
            } else if let p = position {
                // At either end a step stays put, and sends nothing.
                if clamp(p + d) != p { run(.show(clamp(p + d))) }
            } else {
                once("step", "\(product): not stepped, as Remora doesn't know where it is yet. Show a rack first.")
            }
        case .stepPlugin:
            once("plugin", "\(product) has no plug-in steps Remora can send")
        case .overview, .openRack:
            once("page", "\(product) has no overview or rack page Remora can send")
        case .resync:
            // Nothing to ask: forget, and the next show says where it is. A counted host goes
            // back to the first now.
            moved(to: nil)
            if spec.counts { home() }
        case .cc(let n, _):
            once("cc", "\(product): CC \(n) not sent: only \(product)'s own commands go to it")
        }
    }

    /// Logs a line the first time only: a command the host can't do is logged and dropped.
    private func once(_ key: String, _ line: String) {
        guard !said.contains(key) else { return }
        said.insert(key)
        Log.line(line)
    }
}
