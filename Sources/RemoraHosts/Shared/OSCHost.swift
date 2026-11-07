import Foundation
import RemoraCore

/// What one OSC host needs said: how it shows and steps, what to ask it, how to read its answers,
/// and what Remora may send it. Each OSC host module is one of these run by `OSCHostModule`
/// (docs/ARCHITECTURE.md §2.4).
public struct OSCHostSpec {
    public var info: ModuleInfo
    /// The messages that show rack `index` (0-based) of `racks`; empty if the host can't.
    public var show: (_ index: Int, _ racks: [Rack]) -> [OSC.Message]
    /// The messages for one step on (+1) or back (-1); nil to step by showing the rack beside the
    /// one the host is on.
    public var step: ((Int) -> [OSC.Message])?
    /// Asked when the link opens and on Resync, for the racks and where the host is.
    public var ask: [OSC.Message]
    /// Asked again this often, for a host that never says by itself; nil for never.
    public var poll: TimeInterval?
    /// What an answer from the host says.
    public var read: (OSC.Message) -> [OSCHostAnswer]
    /// The send whitelist: true only for a message Remora may send this host. `OSCHostModule`
    /// refuses anything else, as a console module's read guard does.
    public var isAllowed: (OSC.Message) -> Bool

    public init(info: ModuleInfo, show: @escaping (Int, [Rack]) -> [OSC.Message],
                step: ((Int) -> [OSC.Message])? = nil, ask: [OSC.Message] = [], poll: TimeInterval? = nil,
                read: @escaping (OSC.Message) -> [OSCHostAnswer] = { _ in [] },
                isAllowed: @escaping (OSC.Message) -> Bool) {
        self.info = info
        self.show = show
        self.step = step
        self.ask = ask
        self.poll = poll
        self.read = read
        self.isAllowed = isAllowed
    }

    /// A whitelist from addresses and the argument types each may carry ("i", "s", "" for none).
    public static func only(_ allowed: [String: Set<String>]) -> (OSC.Message) -> Bool {
        { m in allowed[m.address]?.contains(m.typeTags) == true }
    }
}

public enum OSCHostAnswer: Equatable {
    /// The host's racks, in order.
    case racks([String])
    /// Where the host is (0-based); nil when it is on nothing Remora knows.
    case position(Int?)
    /// The host started again and forgot what it was asked: ask again.
    case reask
}

extension OSC.Message {
    /// The argument types, "is" for an int and a string, "" for none.
    public var typeTags: String {
        String(args.map { a -> Character in
            switch a {
            case .int: return "i"
            case .float: return "f"
            case .string: return "s"
            }
        })
    }
}

/// An OSC host over UDP: sends to the host's port and reads its answers, whether they come back
/// where they were sent from or to a port of Remora's own (`HostDefaults.replyPort`). Everything
/// runs on its own queue.
public final class OSCHostModule: HostModule {
    public let spec: OSCHostSpec
    public var onEvent: ((HostEvent) -> Void)?

    private let queue: DispatchQueue
    private let platform: Platform
    private var own: HostSettings
    private var started = false
    // On `queue`:
    private var link: UDPLink?
    private var linkUp = false
    private var receiver: OSCReceiver?
    private var poller: DispatchSourceTimer?
    private var racks: [Rack] = []
    private var position: Int?
    private var answered = false
    private var said: Set<String> = []

    /// Showing a rack loads it and the user hasn't ticked that they understand. The engine sends
    /// the host nothing then, and nor does the module: it doesn't ask where the host is either.
    private var held: Bool {
        spec.info.capabilities.contains(.showChangesSound) && !own.showChangesSoundAccepted
    }

    public init(_ spec: OSCHostSpec, _ context: ModuleContext) {
        self.spec = spec
        platform = context.platform
        own = context.settings.host(spec.info.id)
        queue = DispatchQueue(label: "remora.host.\(spec.info.id)")
    }

    private var product: String { spec.info.product }
    private var defaults: HostDefaults { spec.info.hostDefaults }
    private var peer: String { "\(own.host):\(own.port(defaults))" }

    public func start() {
        queue.sync {
            started = true
            open()
        }
    }

    public func stop() {
        queue.sync {
            started = false
            close()
        }
    }

    public func update(_ settings: Settings) {
        let new = settings.host(spec.info.id)
        queue.sync {
            let old = own
            let wasHeld = held
            own = new
            if new.host != old.host || new.port(defaults) != old.port(defaults)
                || new.replyPort(defaults) != old.replyPort(defaults) {
                if started {
                    close()
                    open()
                }
            } else {
                if new.racks != old.racks, defaults.typedRacks {
                    setRacks(new.typedRacks.map(\.name))
                }
                // Just ticked: ask now, as the link's opening would have.
                if wasHeld, !held, linkUp { askFirst() }
            }
        }
    }

    public func perform(_ command: HostCommand) {
        queue.async { [weak self] in self?.run(command) }
    }

    /// For tests: waits until everything performed so far has been handled.
    public func waitUntilIdle() { queue.sync {} }

    // MARK: The link, on `queue`

    private func open() {
        racks = []
        position = nil
        answered = false
        if defaults.typedRacks { setRacks(own.typedRacks.map(\.name)) }
        let replyPort = own.replyPort(defaults)
        if replyPort != 0 {
            let r = platform.oscReceiver()
            r.onMessage = { [weak self] m in self?.queue.async { self?.heard(m) } }
            do {
                try r.start(port: replyPort)
                receiver = r
            } catch {
                onEvent?(.link(.failed("UDP \(replyPort), for \(product)'s answers, is in use by another program")))
            }
        }
        let l = platform.udp(host: own.host, port: own.port(defaults), queue: queue)
        l.onDatagram = { [weak self] bytes in
            for m in OSC.parse(bytes) { self?.heard(m) }
        }
        l.onState = { [weak self] st in self?.linkState(st) }
        link = l
        l.start()
        if let every = spec.poll, !spec.ask.isEmpty {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + every, repeating: every)
            t.setEventHandler { [weak self] in self?.ask() }
            t.resume()
            poller = t
        }
    }

    private func close() {
        poller?.cancel()
        poller = nil
        link?.stop()
        link = nil
        linkUp = false
        receiver?.stop()
        receiver = nil
    }

    private func linkState(_ st: StreamState) {
        switch st {
        case .connected:
            linkUp = true
            askFirst()
        case .failed(let why):
            linkUp = false
            answered = false
            onEvent?(.link(.failed(why)))
        case .stopped, .connecting:
            break
        }
    }

    /// The first questions on a link: says it's waiting for an answer, then asks.
    private func askFirst() {
        guard !held, !spec.ask.isEmpty else { return }
        onEvent?(.link(.connecting(peer: peer)))
        ask()
    }

    private func ask() {
        guard !held else { return }
        for m in spec.ask { send(m) }
    }

    private func send(_ m: OSC.Message) {
        // The one rule: only what this host's whitelist lists. Anything else is a bug.
        precondition(spec.isAllowed(m), "\(product): \(m.address) is not on the send whitelist")
        link?.send(OSC.encode(m))
    }

    // MARK: Answers, on `queue`

    private func heard(_ m: OSC.Message) {
        let answers = spec.read(m)
        guard !answers.isEmpty else { return }
        if !answered {
            answered = true
            onEvent?(.link(.connected(name: product, peer: peer)))
        }
        for a in answers {
            switch a {
            case .racks(let names): if !defaults.typedRacks { setRacks(names) }
            case .position(let p):
                guard p != position else { continue }
                position = p
                onEvent?(.position(p))
            case .reask: ask()
            }
        }
    }

    private func setRacks(_ names: [String]) {
        let new = names.enumerated().map { Rack(index: $0.offset, name: $0.element) }
        guard new != racks else { return }
        racks = new
        onEvent?(.racks(new))
    }

    // MARK: Commands, on `queue`

    private func run(_ command: HostCommand) {
        // The engine's gate holds these already (`Bridge.hostPerform`); this is the second lock.
        guard !held else { return }
        switch command {
        case .show(let i):
            // Showing again would load it again: a patch's changes reverted, a performance reloaded.
            if position == i, spec.info.capabilities.contains(.showChangesSound) { return }
            let ms = spec.show(i, racks)
            guard !ms.isEmpty else {
                return once("show\(i)", "\(product): rack \(i + 1) can't be shown: it isn't one of the racks Remora knows")
            }
            for m in ms { send(m) }
            // A host that answers corrects this; one that doesn't is taken to have done it.
            if position != i {
                position = i
                onEvent?(.position(i))
            }
        case .step(let d):
            if let step = spec.step {
                for m in step(d) { send(m) }
                if let p = position {
                    position = racks.isEmpty ? max(0, p + d) : min(max(0, p + d), racks.count - 1)
                    onEvent?(.position(position))
                }
            } else if let p = position {
                let to = racks.isEmpty ? max(0, p + d) : min(max(0, p + d), racks.count - 1)
                // At either end a step stays put, and sends nothing.
                if to != p { run(.show(to)) }
            } else {
                once("step", "\(product): not stepped, as Remora doesn't know where it is yet. Show a rack first.")
            }
        case .stepPlugin:
            once("plugin", "\(product) has no plug-in steps Remora can send")
        case .overview, .openRack:
            once("page", "\(product) has no overview or rack page Remora can send")
        case .resync:
            position = nil
            onEvent?(.position(nil))
            ask()
        case .cc(let n, _):
            once("cc", "\(product): CC \(n) not sent: Remora reaches it over OSC, with no MIDI")
        }
    }

    /// Logs a line the first time only: a command the host can't do is logged and dropped.
    private func once(_ key: String, _ line: String) {
        guard !said.contains(key) else { return }
        said.insert(key)
        Log.line(line)
    }
}
