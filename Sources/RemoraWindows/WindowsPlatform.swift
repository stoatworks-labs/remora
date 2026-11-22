#if os(Windows)
import Foundation
import RemoraCore
import RemoraSockets
import WinSDK

/// Windows' platform services (docs/ARCHITECTURE.md §8): TCP, UDP and OSC from RemoraSockets on
/// Winsock, MIDI through WinMM on a loopback port the user makes (`WinMMPort`), and staying awake
/// while the engine runs (`WindowsAwake`).
public final class WindowsPlatform: Platform {
    private let sockets = SocketPlatform()
    private var midiProblem: String?

    public init() {}

    public func tcp(host: String, port: UInt16, queue: DispatchQueue) -> TCPStream {
        sockets.tcp(host: host, port: port, queue: queue)
    }

    public func tcpListener(port: UInt16, queue: DispatchQueue) -> TCPListener {
        sockets.tcpListener(port: port, queue: queue)
    }

    public func udp(host: String, port: UInt16, queue: DispatchQueue) -> UDPLink {
        sockets.udp(host: host, port: port, queue: queue)
    }

    public func oscReceiver() -> OSCReceiver { sockets.oscReceiver() }

    public func midi(name: String) -> MIDILink? {
        switch WinMMPort.open(name: name) {
        case .success(let port):
            midiProblem = nil
            return port
        case .failure(let why):
            midiProblem = why.description
            return nil
        }
    }

    public var midiUnavailable: String? { midiProblem }

    public func stayAwake(reason: String) -> AwakeHold? { WindowsAwake(reason: reason) }
}

/// Keeps Windows from sleeping while the engine runs (`SetThreadExecutionState`, held by the
/// engine's thread), and Remora out of power throttling: no EcoQoS for its threads, and its 1 ms
/// timer requests honoured even with no window showing (Windows 11 otherwise may not).
final class WindowsAwake: AwakeHold {
    private static let continuous: UInt32 = 0x8000_0000      // ES_CONTINUOUS
    private static let systemRequired: UInt32 = 0x0000_0001  // ES_SYSTEM_REQUIRED
    // PROCESS_POWER_THROTTLING_EXECUTION_SPEED and _IGNORE_TIMER_RESOLUTION.
    private static let throttling: UInt32 = 0x1 | 0x4

    private var held = false

    /// `reason` is for macOS's activity; Windows' state has none.
    init(reason: String) {
        held = SetThreadExecutionState(EXECUTION_STATE(Self.continuous | Self.systemRequired)) != 0
        let unthrottled = Self.throttle(false)
        let awake = held ? "staying awake" : "could not keep the computer awake (error \(GetLastError()))"
        let power = unthrottled ? "power throttling off" : "power throttling left on (error \(GetLastError()))"
        Log.line("Windows: \(awake) while the engine runs; \(power)")
    }

    func end() {
        guard held else { return }
        held = false
        SetThreadExecutionState(EXECUTION_STATE(Self.continuous))
        _ = Self.throttle(true)
    }

    deinit { end() }

    /// Throttling off: the two kinds in the control mask, none in the state mask. On: neither in
    /// the control mask, so Windows decides again.
    private static func throttle(_ allowed: Bool) -> Bool {
        var state = PROCESS_POWER_THROTTLING_STATE()
        state.Version = 1   // PROCESS_POWER_THROTTLING_CURRENT_VERSION
        state.ControlMask = allowed ? 0 : throttling
        state.StateMask = 0
        return SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, &state,
                                     DWORD(MemoryLayout<PROCESS_POWER_THROTTLING_STATE>.size))
    }
}
#endif
