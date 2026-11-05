import AppKit
import ApplicationServices
import Foundation

/// A third-party plug-in's window in SuperRack Performer, as Remora sees it.
public struct PluginWindow: Equatable {
    /// SuperRack titles them "<rack>: <plug-in>", e.g. "head 1: De-Feedback".
    public var title: String
    /// SuperRack's own pin (the pin in the window's title bar). Remora never closes a pinned window.
    public var pinned: Bool
    /// When Remora first saw it open. Distant past for windows open before Remora looked.
    public var appeared: Date

    public init(title: String, pinned: Bool = false, appeared: Date = .distantPast) {
        self.title = title
        self.pinned = pinned
        self.appeared = appeared
    }
}

/// What SuperRack does on its own (15.15.12.13, docs/PROTOCOL.md): selecting another third-party
/// plug-in swaps its unpinned window for the new one. Selecting a Waves plug-in, moving to another
/// rack or leaving the Rack page leaves the window open. These rules close it then.
public enum PluginWindowPolicy {
    public enum Change: Equatable, CustomStringConvertible {
        /// The rack SuperRack now shows, by name.
        case rack(String)
        /// The page now shown, as SuperRack's log names it (RACK, OVERVIEW1, SETUP …).
        case page(String)
        /// A plug-in selected on a rack (Waves or third-party).
        case plugin(rack: String, plugin: String)
        /// A plug-in window opened.
        case opened(title: String)

        public var description: String {
            switch self {
            case .rack(let r): return "rack is now \(r)"
            case .page(let p): return "page is now \(p)"
            case .plugin(let r, let p): return "\(r): \(p) selected"
            case .opened(let t): return "\(t) opened"
            }
        }
    }

    public static func title(rack: String, plugin: String) -> String { "\(rack): \(plugin)" }

    /// The indices of the windows to close after a change made at `time`: unpinned, already open
    /// when it happened, and not what the change now shows. A window that opened after the change
    /// is never closed for it.
    public static func toClose(_ windows: [PluginWindow], after change: Change, at time: Date) -> [Int] {
        windows.indices.filter { i in
            let w = windows[i]
            guard !w.pinned, w.appeared < time else { return false }
            switch change {
            case .rack(let r): return !w.title.hasPrefix(r + ": ")
            case .page(let p): return p != "RACK"
            case .plugin(let r, let p): return w.title != title(rack: r, plugin: p)
            case .opened(let t): return w.title != t
            }
        }
    }

    /// The third-party plug-in to show after a move to `rack`, if its selected plug-in is one.
    /// `live` is the plug-in SuperRack's log last said was selected there, which is fresher than the
    /// session database. Racks sharing a name ("n/a") count only if they all agree.
    public static func reopenTarget(rack: String, chains: [RackChain], live: String?) -> ChainPlugin? {
        let named = chains.filter { $0.name == rack }
        guard !named.isEmpty else { return nil }
        let pick: ChainPlugin?
        if let live {
            let all = named.flatMap(\.plugins) + chains.flatMap(\.plugins)
            pick = all.first { $0.name == live }
        } else {
            let selected = named.map(\.selected)
            guard let first = selected.first ?? nil,
                  selected.allSatisfy({ $0?.name == first.name }) else { return nil }
            pick = first
        }
        guard let p = pick, !p.isWaves else { return nil }
        return p
    }

    /// The six page tabs of SuperRack's top bar, left to right, as its log names them.
    public static let pages = ["OVERVIEW1", "OVERVIEW2", "RACK", "SHOW", "PATCH", "SETUP"]

    /// Where a plug-in window goes to sit over the Rack page's plug-in area, given SuperRack's main
    /// window. The area was measured at SuperRack's default size (main window 1850 × 1034 points):
    /// 328 points in from the left, 127 down from the top, 504 short of the right, 3 short of the
    /// bottom. Centred across the area and at its top; a window wider than the area starts at its left.
    public static func placement(of size: CGSize, inMainWindow main: CGRect) -> CGPoint {
        let area = CGRect(x: main.minX + 328, y: main.minY + 127,
                          width: max(0, main.width - 328 - 504), height: max(0, main.height - 127 - 3))
        let x = size.width < area.width ? area.minX + ((area.width - size.width) / 2).rounded() : area.minX
        return CGPoint(x: x, y: area.minY)
    }
}

/// Closes, and if asked places, SuperRack Performer's third-party plug-in windows.
///
/// It watches SuperRack through Accessibility (the rack name in its top bar, its plug-in windows)
/// and its application log (the page, the plug-in selected), and acts only by pressing a plug-in
/// window's own Close button or moving the window. It never presses anything else in SuperRack:
/// those title bars also hold the plug-in's Bypass.
///
/// Everything runs on a thread of its own, so a busy SuperRack never holds up the console link.
public final class PluginWindowGuard {
    public struct Options: Equatable {
        /// Close third-party windows when the rack, the page or the plug-in changes.
        public var close = false
        /// Move each third-party window over the Rack page's plug-in area when it opens.
        public var place = false
        /// After a move to another rack on the Rack page, show its selected third-party plug-in:
        /// SuperRack only does that when the Rack page is opened from another page, so Remora asks
        /// for the overview and the Rack page again (`onReopen`).
        public var reopen = false
        public init(close: Bool = false, place: Bool = false, reopen: Bool = false) {
            self.close = close
            self.place = place
            self.reopen = reopen
        }
        public var any: Bool { close || place || reopen }
    }

    public struct Status: Equatable {
        public var trusted = false
        public var attached = false
        public var logOpen = false
        public var openWindows = 0
        public var lastAction: String?
        public init() {}
    }

    public static let superRackBundleID = "com.WavesAudio.SuperRack-Performer"

    /// Called on the main queue.
    public var onStatus: ((Status) -> Void)?
    /// Called on the main queue when SuperRack should go to the overview and back to the Rack page
    /// (Return To Last Overview Tab, then Open Rack Tab), to show the new rack's plug-in.
    public var onReopen: (() -> Void)?

    private let thread: Thread
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private let logQueue = DispatchQueue(label: "remora.superrack.log")
    private let log: SuperRackLogTail

    // Owned by the guard's thread from here on.
    private var options = Options()
    private var status = Status()
    private var pid: pid_t = 0
    private var app: AXUIElement?
    private var observer: AXObserver?
    private var rackField: AXUIElement?
    private var mainWindow: AXUIElement?
    private var rack: String?
    private var known: [Seen] = []
    private var firstLook = true
    private var pending: [(PluginWindowPolicy.Change, Date)] = []
    private var evaluateScheduled = false
    private var timer: CFRunLoopTimer?
    private var tabs: [AXUIElement] = []
    private var logPage: String?
    private var chains: [RackChain] = []
    /// The plug-in SuperRack's log last said was selected on each rack, and when.
    private var liveSelected: [String: (plugin: String, at: Date)] = [:]
    private var reopenTimer: CFRunLoopTimer?

    private struct Seen {
        var element: AXUIElement
        var title: String
        var appeared: Date
        /// The window's own Close and Pin, found once.
        var closeButton: AXUIElement
        var pin: AXUIElement
        var closeTried = false
        var placed = false
    }

    public init(logPath: String = SuperRackLogTail.defaultPath) {
        log = SuperRackLogTail(path: logPath, queue: logQueue)
        final class Box { var runLoop: CFRunLoop? }
        let box = Box()
        let sem = ready
        thread = Thread {
            box.runLoop = CFRunLoopGetCurrent()
            // A far-off timer keeps the run loop alive until there is real work.
            let keep = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1e9, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keep, .defaultMode)
            sem.signal()
            CFRunLoopRun()
        }
        thread.name = "remora.plugin-windows"
        thread.start()
        ready.wait()
        runLoop = box.runLoop
        log.onLine = { [weak self] l in self?.perform { self?.logged(l) } }
    }

    /// Changes what the guard does. Turning it on asks for Accessibility if Remora lacks it.
    public func set(_ o: Options) {
        if o.any && !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        perform { self.apply(o) }
    }

    public func stop() {
        perform { self.apply(Options()) }
    }

    /// The session's chains, for which plug-in each rack has selected.
    public func setChains(_ c: [RackChain]) {
        perform { self.chains = c }
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    private func apply(_ o: Options) {
        let was = options
        options = o
        if o.any && !was.any {
            log.start()
            let t = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0) { [weak self] _ in
                self?.tick()
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .defaultMode)
            timer = t
            Log.line("Plug-in windows: \(describe(o))")
            tick()
            return
        } else if !o.any && was.any {
            if let t = timer { CFRunLoopTimerInvalidate(t) }
            timer = nil
            log.stop()
            detach()
            Log.line("Plug-in windows: left alone")
        } else if o != was {
            Log.line("Plug-in windows: \(describe(o))")
        }
        publish()
    }

    private func describe(_ o: Options) -> String {
        [o.close ? "closed when the rack, page or plug-in changes" : nil,
         o.place ? "placed over the rack page" : nil,
         o.reopen ? "the new rack's shown after a move" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Attaching

    /// Once a second: find SuperRack (it may start, quit or restart), pick the log up again, and
    /// catch anything a notification missed.
    private func tick() {
        status.trusted = AXIsProcessTrusted()
        log.check()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.superRackBundleID)
            .first { !$0.isTerminated }
        if let r = running, status.trusted {
            if r.processIdentifier != pid || app == nil { attach(r.processIdentifier) }
            if rackField == nil { findMainWindow() }
            readRack(at: Date())
            schedule(after: 0)
        } else if app != nil {
            detach()
        }
        publish()
    }

    private func attach(_ p: pid_t) {
        detach()
        pid = p
        let a = AXUIElementCreateApplication(p)
        // A busy SuperRack answers late; never wait long on it.
        AXUIElementSetMessagingTimeout(a, 0.25)
        app = a
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, note, refcon in
            guard let refcon else { return }
            Unmanaged<PluginWindowGuard>.fromOpaque(refcon).takeUnretainedValue().notified(note as String, element)
        }
        if AXObserverCreate(p, callback, &obs) == .success, let obs {
            let me = Unmanaged.passUnretained(self).toOpaque()
            for n in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(obs, a, n as CFString, me)
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observer = obs
        }
        firstLook = true
        known = []
        rack = nil
        findMainWindow()
        status.attached = true
        Log.line("Plug-in windows: watching SuperRack (pid \(p))")
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        if app != nil { Log.line("Plug-in windows: SuperRack gone") }
        app = nil
        pid = 0
        mainWindow = nil
        rackField = nil
        rack = nil
        tabs = []
        known = []
        pending = []
        if let t = reopenTimer { CFRunLoopTimerInvalidate(t) }
        reopenTimer = nil
        status.attached = false
        status.openWindows = 0
    }

    /// The main window, and in its top bar the rack's name (the text field furthest left) and the
    /// six page tabs (untitled check boxes, 71 points tall, value 1 for the page shown).
    private func findMainWindow() {
        guard let app else { return }
        rackField = nil
        mainWindow = nil
        tabs = []
        for w in elements(app, kAXWindowsAttribute) where (string(w, kAXTitleAttribute) ?? "").hasPrefix("SuperRack Performer") {
            mainWindow = w
            let children = elements(w, kAXChildrenAttribute)
            let fields = children.filter { string($0, kAXRoleAttribute) == kAXTextFieldRole }
            rackField = fields.min { (frame($0)?.minX ?? .infinity) < (frame($1)?.minX ?? .infinity) }
            let boxes = children.compactMap { c -> (AXUIElement, CGFloat)? in
                guard string(c, kAXRoleAttribute) == kAXCheckBoxRole, let f = frame(c), f.height >= 50 else { return nil }
                return (c, f.minX)
            }
            if boxes.count == PluginWindowPolicy.pages.count { tabs = boxes.sorted { $0.1 < $1.1 }.map(\.0) }
            if let f = rackField, let obs = observer {
                AXObserverAddNotification(obs, f, kAXValueChangedNotification as CFString,
                                          Unmanaged.passUnretained(self).toOpaque())
            }
            rack = rackField.flatMap { string($0, kAXValueAttribute) }
            return
        }
    }

    // MARK: Events

    private func notified(_ note: String, _ element: AXUIElement) {
        if note == kAXValueChangedNotification {
            readRack(at: Date())
        } else if note == kAXUIElementDestroyedNotification, let m = mainWindow, CFEqual(m, element) {
            mainWindow = nil
            rackField = nil
        }
        // Window changes settle for a moment: SuperRack shows the new one, then hides the old.
        schedule(after: 0.1)
    }

    private func readRack(at time: Date) {
        guard let f = rackField else { return }
        // Being renamed: not a rack change.
        if (value(f, kAXFocusedAttribute) as? Bool) == true { return }
        guard let r = string(f, kAXValueAttribute) else {
            rackField = nil
            return
        }
        if let old = rack, old != r {
            pending.append((.rack(r), time))
            scheduleReopen()
        }
        rack = r
    }

    /// The page SuperRack shows: its tabs if they were found, else what its log last said.
    private func currentPage() -> String? {
        if !tabs.isEmpty {
            let on = tabs.map { (value($0, kAXValueAttribute) as? NSNumber)?.intValue == 1 }
            if on.filter({ $0 }).count == 1, let i = on.firstIndex(of: true) { return PluginWindowPolicy.pages[i] }
        }
        return logPage
    }

    /// A move steps through racks every 20 ms or so: wait until it has settled.
    private func scheduleReopen() {
        guard options.reopen else { return }
        if let t = reopenTimer { CFRunLoopTimerInvalidate(t) }
        let t = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.35, 0, 0, 0) { [weak self] _ in
            self?.reopenTimer = nil
            self?.considerReopen()
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .defaultMode)
        reopenTimer = t
    }

    /// Asks once for the overview and the Rack page again if the rack SuperRack has moved to has a
    /// third-party plug-in selected and its window is not already showing.
    private func considerReopen() {
        guard options.reopen, let r = rack, currentPage() == "RACK" else { return }
        let live = liveSelected[r].flatMap { Date().timeIntervalSince($0.at) < 10 ? $0.plugin : nil }
        guard let p = PluginWindowPolicy.reopenTarget(rack: r, chains: chains, live: live) else { return }
        let title = PluginWindowPolicy.title(rack: r, plugin: p.name)
        if known.contains(where: { $0.title == title }) { return }
        Log.line("Plug-in windows: showing \(title) (overview and back)")
        status.lastAction = "showed \(title)"
        DispatchQueue.main.async { self.onReopen?() }
        // One try per move: if SuperRack did not show it, say so and leave it.
        let check = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1.5, 0, 0, 0) { [weak self] _ in
            guard let self, self.rack == r, !self.known.contains(where: { $0.title == title }) else { return }
            Log.line("Plug-in windows: SuperRack did not show \(title)")
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), check, .defaultMode)
    }

    private func logged(_ l: SuperRackLogLine) {
        switch l.event {
        case .page(let p):
            logPage = p
            pending.append((.page(p), l.time))
        case .pluginSelected(let r, let p, _):
            liveSelected[r] = (p, Date())
            pending.append((.plugin(rack: r, plugin: p), l.time))
        case .rackPicked: return  // the rack name in the top bar says it
        }
        schedule(after: 0.05)
    }

    private func schedule(after delay: TimeInterval) {
        guard !evaluateScheduled, app != nil else { return }
        evaluateScheduled = true
        let t = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { [weak self] _ in
            self?.evaluateScheduled = false
            self?.evaluate()
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .defaultMode)
    }

    /// Looks at the plug-in windows, then closes and places as the options say.
    private func evaluate() {
        guard app != nil else { return }
        let now = Date()
        let seen = snapshot(now: now)
        let windows = seen.map { s -> PluginWindow in
            PluginWindow(title: s.title, pinned: (value(s.pin, kAXValueAttribute) as? NSNumber)?.intValue == 1,
                         appeared: s.appeared)
        }
        var changes = pending
        pending = []
        // A window that opened since the last look is a change of its own (one window at a time).
        if !firstLook {
            for s in seen where s.appeared == now { changes.append((.opened(title: s.title), now)) }
        }
        firstLook = false
        changes.sort { $0.1 < $1.1 }

        var closing = Set<Int>()
        if options.close {
            for (change, time) in changes {
                for i in PluginWindowPolicy.toClose(windows, after: change, at: time) where !closing.contains(i) {
                    closing.insert(i)
                    close(i, because: change)
                }
            }
        }
        if options.place {
            for i in known.indices where !known[i].placed && !closing.contains(i) {
                known[i].placed = true
                // Windows already open when Remora started are left where they are.
                if known[i].appeared != .distantPast { place(known[i]) }
            }
        }
        status.openWindows = known.count - closing.count
        publish()
    }

    /// SuperRack's plug-in windows now on screen. Accessibility lists only shown windows; a plug-in
    /// window is a dialog titled "<rack>: <plug-in>" with the Pin and Close of SuperRack's own title bar.
    private func snapshot(now: Date) -> [Seen] {
        guard let app else { return [] }
        var next: [Seen] = []
        for w in elements(app, kAXWindowsAttribute) {
            guard string(w, kAXSubroleAttribute) == kAXDialogSubrole,
                  let title = string(w, kAXTitleAttribute), title.contains(": ") else { continue }
            if let old = known.first(where: { CFEqual($0.element, w) && $0.title == title }) {
                next.append(old)
                continue
            }
            var close: AXUIElement?, pin: AXUIElement?
            for c in elements(w, kAXChildrenAttribute) {
                let role = string(c, kAXRoleAttribute), d = string(c, kAXDescriptionAttribute)
                if role == kAXButtonRole && d == "Close" { close = c }
                if role == kAXCheckBoxRole && d == "Pin/Unpin window" { pin = c }
            }
            guard let close, let pin else { continue }
            next.append(Seen(element: w, title: title, appeared: firstLook ? .distantPast : now,
                             closeButton: close, pin: pin, placed: firstLook))
        }
        known = next
        return next
    }

    // MARK: Acting

    /// Presses the window's own Close, once. Nothing else in SuperRack is ever pressed.
    private func close(_ i: Int, because change: PluginWindowPolicy.Change) {
        guard !known[i].closeTried else { return }
        known[i].closeTried = true
        let title = known[i].title
        let r = AXUIElementPerformAction(known[i].closeButton, kAXPressAction as CFString)
        // Gone already: SuperRack hid it itself (it swaps unpinned windows on its own).
        if r == .invalidUIElement { return }
        let line = r == .success ? "closed \(title) (\(change))" : "could not close \(title): AX error \(r.rawValue)"
        Log.line("Plug-in windows: \(line)")
        status.lastAction = line
    }

    private func place(_ s: Seen) {
        guard let m = mainWindow, let main = frame(m), let f = frame(s.element) else { return }
        var p = PluginWindowPolicy.placement(of: f.size, inMainWindow: main)
        guard abs(p.x - f.minX) > 1 || abs(p.y - f.minY) > 1, let v = AXValueCreate(.cgPoint, &p) else { return }
        let r = AXUIElementSetAttributeValue(s.element, kAXPositionAttribute as CFString, v)
        if r != .success { Log.line("Plug-in windows: could not move \(s.title): AX error \(r.rawValue)") }
    }

    private func publish() {
        status.logOpen = log.isOpen
        let s = status
        DispatchQueue.main.async { self.onStatus?(s) }
    }

    // MARK: Accessibility helpers

    private func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private func string(_ e: AXUIElement, _ name: String) -> String? { value(e, name) as? String }

    private func elements(_ e: AXUIElement, _ name: String) -> [AXUIElement] {
        (value(e, name) as? [AXUIElement]) ?? []
    }

    private func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = value(e, kAXPositionAttribute), let s = value(e, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
