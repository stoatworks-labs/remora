#if os(Windows)
import Foundation
import RemoraCore
import WinSDK

/// Remora's MIDI on Windows, through WinMM (docs/ARCHITECTURE.md §8): CCs out on the loopback port
/// named as Remora's port, and every other input in, for learned controls.
///
/// - **Out:** the output named `name` (`WindowsMIDIRules.output`), opened once at launch, as the
///   Mac's virtual source is made once. A port that goes away later is logged; nothing reaches the
///   host again until Remora restarts, as on the Mac after SuperRack loses Remora.
/// - **In:** only where Windows MIDI Services shares every port between programs
///   (`WindowsMIDIRules.sharesPorts`). Without it an input is the first program's to open it, and
///   Remora would take a controller from the plug-in host, so it opens none. Its own port's input
///   is never opened: a loopback hands back what Remora sends. New inputs are looked for every
///   5 s.
/// - **Timers:** 1 ms while MIDI goes out, and 2 s after (`BusyHold`), so SuperRack's 2 ms steps
///   aren't rounded up to Windows' ~15.6 ms tick.
final class WinMMPort: MIDILink {
    let name: String
    var onEvent: ((MIDIEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onEvent }
        set { lock.lock(); _onEvent = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var _onEvent: ((MIDIEvent) -> Void)?
    private var out: HMIDIOUT?
    private var sendFailed = false
    private let timers: BusyHold
    private let shares: Bool
    private let queue = DispatchQueue(label: "remora.winmm")
    private var scan: DispatchSourceTimer?
    // On `queue`:
    private var inputs: [String: WinMMInput] = [:]
    private var refused: Set<String> = []

    /// Opens the output named `name`, or says why not.
    static func open(name: String) -> Result<WinMMPort, WinMMProblem> {
        let outputs = WinMM.outputNames()
        guard let id = WindowsMIDIRules.output(named: name, in: outputs) else {
            let here = outputs.isEmpty ? "none" : outputs.joined(separator: ", ")
            return .failure(WinMMProblem("no MIDI output named \"\(name)\": make a loopback port of that name (loopMIDI, or a Windows MIDI Services loopback) and start Remora again. Outputs here: \(here)"))
        }
        var h: HMIDIOUT?
        let r = midiOutOpen(&h, UINT(id), 0, 0, DWORD(WinMM.callbackNull))
        guard r == WinMM.ok, let h else {
            return .failure(WinMMProblem("MIDI output \"\(outputs[id])\" would not open: \(WinMM.outText(r))"))
        }
        let shares = WindowsMIDIRules.sharesPorts(midiDrivers: WinMM.midiDrivers())
        Log.line("MIDI: sending on \"\(outputs[id])\", Windows MIDI output \(id + 1) of \(outputs.count)\(shares ? ", with Windows MIDI Services sharing every port" : "")")
        return .success(WinMMPort(name: name, out: h, shares: shares))
    }

    private init(name: String, out: HMIDIOUT, shares: Bool) {
        self.name = name
        self.out = out
        self.shares = shares
        timers = WinMM.timerHold()
        queue.sync { listen(first: true) }
        guard shares else {
            Log.line("MIDI: listening to no input: without Windows MIDI Services a Windows MIDI input is one program's at a time, and Remora won't take one from the plug-in host, so learned MIDI controls need Windows 11 with Windows MIDI Services")
            return
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.listen(first: false) }
        t.resume()
        scan = t
    }

    deinit {
        // Not through `queue`: the last reference may go inside one of its blocks.
        scan?.cancel()
        inputs.values.forEach { $0.close() }
        timers.release()
        lock.lock()
        if let h = out { midiOutClose(h) }
        out = nil
        lock.unlock()
    }

    func sendCC(channel: Int, number: Int, value: Int) {
        send(WindowsMIDIRules.shortMessage(status: 0xB0, channel: channel, number, value))
    }

    func sendProgramChange(channel: Int, program: Int) {
        send(WindowsMIDIRules.shortMessage(status: 0xC0, channel: channel, program, 0))
    }

    private func send(_ message: UInt32) {
        timers.touch()
        lock.lock()
        defer { lock.unlock() }
        guard let h = out else { return }
        let r = midiOutShortMsg(h, DWORD(message))
        if r == WinMM.ok {
            if sendFailed { Log.line("MIDI: \"\(name)\" takes messages again") }
            sendFailed = false
        } else if !sendFailed {
            sendFailed = true
            Log.line("MIDI: sending on \"\(name)\" failed: \(WinMM.outText(r)). Until it works again nothing reaches the plug-in host, and what Remora counted may be wrong: Resync once it does")
        }
    }

    /// Delivered from WinMM's thread.
    fileprivate func heard(_ message: UInt32, from source: String) {
        guard let e = WindowsMIDIRules.event(message, source: source) else { return }
        onEvent?(e)
    }

    // MARK: On `queue`

    /// Opens every input not yet open but Remora's own, and closes any that went away.
    private func listen(first: Bool) {
        guard shares else { return }
        let names = WinMM.inputNames()
        let keys = WindowsMIDIRules.keys(names)
        var opened: [String] = []
        for (id, key) in keys.enumerated() where inputs[key] == nil && !WindowsMIDIRules.isOwn(names[id], port: name) {
            switch WinMMInput.open(id: id, key: key, port: self) {
            case .success(let input):
                inputs[key] = input
                refused.remove(key)
                opened.append(key)
            case .failure(let why):
                if !refused.contains(key) { Log.line("MIDI: not listening to \"\(key)\": \(why.description)") }
                refused.insert(key)
            }
        }
        for key in inputs.keys where !keys.contains(key) {
            inputs.removeValue(forKey: key)?.close()
            Log.line("MIDI: \"\(key)\" went away")
        }
        if first {
            Log.line(opened.isEmpty ? "MIDI: no other inputs to listen to yet" : "MIDI: listening to \(opened.joined(separator: ", "))")
        } else if !opened.isEmpty {
            Log.line("MIDI: listening to \(opened.joined(separator: ", ")) too")
        }
    }
}

/// One open input. WinMM calls `inputProc` on its own thread with the box as the instance; the
/// box lives until the handle is closed.
final class WinMMInput {
    fileprivate final class Box {
        weak var port: WinMMPort?
        let source: String
        init(port: WinMMPort, source: String) {
            self.port = port
            self.source = source
        }
    }

    private var handle: HMIDIIN?
    private let box: Box

    private init(handle: HMIDIIN, box: Box) {
        self.handle = handle
        self.box = box
    }

    static func open(id: Int, key: String, port: WinMMPort) -> Result<WinMMInput, WinMMProblem> {
        let box = Box(port: port, source: key)
        let instance = DWORD_PTR(UInt(bitPattern: Unmanaged.passUnretained(box).toOpaque()))
        let callback = DWORD_PTR(unsafeBitCast(inputProc, to: UInt.self))
        var h: HMIDIIN?
        let r = midiInOpen(&h, UINT(id), callback, instance, DWORD(WinMM.callbackFunction))
        guard r == WinMM.ok, let h else {
            return .failure(WinMMProblem(r == WinMM.allocated ? "another program has it" : WinMM.inText(r)))
        }
        let input = WinMMInput(handle: h, box: box)
        let s = midiInStart(h)
        guard s == WinMM.ok else {
            input.close()
            return .failure(WinMMProblem(WinMM.inText(s)))
        }
        return .success(input)
    }

    func close() {
        guard let h = handle else { return }
        handle = nil
        midiInStop(h)
        midiInClose(h)
    }

    deinit { close() }

    /// MIM_DATA's first parameter is the short message; everything else (SysEx, open, close) is
    /// dropped. Only Remora's own code runs here: WinMM must not be called from its callback.
    private static let inputProc: @convention(c) (HMIDIIN?, UINT, DWORD_PTR, DWORD_PTR, DWORD_PTR) -> Void = {
        _, message, instance, param1, _ in
        guard message == WinMM.mimData, let raw = UnsafeRawPointer(bitPattern: UInt(instance)) else { return }
        let box = Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue()
        box.port?.heard(UInt32(truncatingIfNeeded: param1), from: box.source)
    }
}

/// Why a port or an input didn't open, in words for the log.
struct WinMMProblem: Error, CustomStringConvertible {
    let description: String
    init(_ why: String) { description = why }
}

/// The WinMM calls and constants Remora uses, and Drivers32 from the registry.
enum WinMM {
    static let ok: MMRESULT = 0
    /// MMSYSERR_ALLOCATED: another program has the port.
    static let allocated: MMRESULT = 4
    static let callbackNull: UInt32 = 0
    static let callbackFunction: UInt32 = 0x0003_0000
    static let mimData: UINT = 0x3C3

    static func outputNames() -> [String] {
        (0..<midiOutGetNumDevs()).map { id in
            var caps = MIDIOUTCAPSW()
            guard midiOutGetDevCapsW(UINT_PTR(id), &caps, UINT(MemoryLayout<MIDIOUTCAPSW>.size)) == ok else { return "" }
            return string(caps.szPname)
        }
    }

    static func inputNames() -> [String] {
        (0..<midiInGetNumDevs()).map { id in
            var caps = MIDIINCAPSW()
            guard midiInGetDevCapsW(UINT_PTR(id), &caps, UINT(MemoryLayout<MIDIINCAPSW>.size)) == ok else { return "" }
            return string(caps.szPname)
        }
    }

    static func outText(_ r: MMRESULT) -> String {
        var buf = [WCHAR](repeating: 0, count: 256)
        guard midiOutGetErrorTextW(r, &buf, UINT(buf.count)) == ok else { return "error \(r)" }
        return String(decodingCString: buf, as: UTF16.self)
    }

    static func inText(_ r: MMRESULT) -> String {
        var buf = [WCHAR](repeating: 0, count: 256)
        guard midiInGetErrorTextW(r, &buf, UINT(buf.count)) == ok else { return "error \(r)" }
        return String(decodingCString: buf, as: UTF16.self)
    }

    private static var saidTimers = false

    /// The port's hold on 1 ms timers: from its first message to 2 s after its last.
    static func timerHold() -> BusyHold {
        BusyHold(idle: 2, begin: { preciseTimers(true) }, end: { preciseTimers(false) })
    }

    /// 1 ms timers on or off. The first time, says so.
    static func preciseTimers(_ on: Bool) {
        if on {
            let r = timeBeginPeriod(1)
            if !saidTimers {
                saidTimers = true
                Log.line(r == ok ? "Windows: 1 ms timers while MIDI goes out" : "Windows: no 1 ms timers (error \(r)): MIDI steps will be ~16 ms apart")
            }
        } else {
            timeEndPeriod(1)
        }
    }

    /// A fixed-size UTF-16 name, up to its terminator.
    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let units = raw.bindMemory(to: UInt16.self)
            let n = units.firstIndex(of: 0) ?? units.count
            return String(decoding: units[..<n], as: UTF16.self)
        }
    }

    /// Drivers32's `midi`, `midi1` … `midi9`: which WinMM drivers carry MIDI.
    static func midiDrivers() -> [String] {
        let key = #"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32"#
        return (0..<10).compactMap { i in registryString(key, i == 0 ? "midi" : "midi\(i)") }
    }

    /// HKEY_LOCAL_MACHINE: a sign-extended constant, which Swift doesn't import.
    private static let localMachine = HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0002)))

    private static func registryString(_ key: String, _ value: String) -> String? {
        var buf = [WCHAR](repeating: 0, count: 260)
        var size = DWORD(buf.count * MemoryLayout<WCHAR>.size)
        let rrfString: DWORD = 0x0000_0002   // RRF_RT_REG_SZ
        let r = key.withCString(encodedAs: UTF16.self) { k in
            value.withCString(encodedAs: UTF16.self) { v in
                RegGetValueW(localMachine, k, v, rrfString, nil, &buf, &size)
            }
        }
        guard r == 0 else { return nil }
        return String(decodingCString: buf, as: UTF16.self)
    }
}
#endif
