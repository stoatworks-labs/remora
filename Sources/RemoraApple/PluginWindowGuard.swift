import AppKit
import ApplicationServices
import Foundation
import RemoraCore
import RemoraHosts

/// Closes, and if asked places, SuperRack Performer's third-party plug-in windows, and reads the
/// rack SuperRack shows for the driver (`RackNameReader`).
///
/// It watches SuperRack through Accessibility (the rack name in its top bar, its plug-in windows)
/// and its application log (the page, the plug-in selected), and acts only by pressing a plug-in
/// window's own Close button or moving the window. It never presses anything else in SuperRack:
/// those title bars also hold the plug-in's Bypass.
///
/// Everything runs on a thread of its own, so a busy SuperRack never holds up the console link.
public final class PluginWindowGuard: PluginWindowWatcher {
    public typealias Options = PluginWindowOptions
    public typealias Status = PluginWindowStatus

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
    /// `canReadRackName`, kept for other threads.
    private let readableLock = NSLock()
    private var readable = false
    /// SuperRack is the app in front. Taken as true until known: nothing hides on a guess.
    private var superRackFront = true
    /// Ticks in a row on which `isActive` disagreed with `superRackFront`.
    private var frontDisagreed = 0
    private var workspaceObserver: NSObjectProtocol?
    /// Remora hid SuperRack since it was last in front. Once each time it goes behind: a SuperRack
    /// shown again from outside without coming to the front is left showing, never fought.
    private var hidSuperRack = false

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
        // Posted on the main thread whenever an app comes to the front.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let front = app?.bundleIdentifier == Self.superRackBundleID
            self?.perform {
                self?.frontDisagreed = 0
                self?.frontChanged(front)
            }
        }
    }

    deinit {
        if let o = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    /// Changes what the guard does. Turning on anything for plug-in windows asks for Accessibility
    /// if Remora lacks it; reading the rack alone never asks.
    public func set(_ o: Options) {
        if o.windows && !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        perform { self.apply(o) }
    }

    /// Stops, waiting up to a second for that. A SuperRack that Remora hid stays hidden: it is an
    /// ordinary hidden app, shown again by switching to it, and nothing of it is in the Dock.
    public func stop() {
        let done = DispatchSemaphore(value: 0)
        perform {
            self.apply(Options())
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
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
        if o.windows && !was.windows {
            log.start()
            // Windows open now count as open before Remora looked, as at attach.
            known = []
            pending = []
            firstLook = true
            Log.line("Plug-in windows: \(describe(o))")
        } else if !o.windows && was.windows {
            log.stop()
            status.openWindows = 0
            Log.line("Plug-in windows: left alone")
        } else if o.windows && (o.close, o.place, o.reopen, o.hide) != (was.close, was.place, was.reopen, was.hide) {
            Log.line("Plug-in windows: \(describe(o))")
        }
        if o.readRack != was.readRack {
            Log.line(o.readRack ? "SuperRack: reading its rack from its window (needs Accessibility)"
                                : "SuperRack: not reading its window; counting only")
        }
        if o.any && !was.any {
            let t = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0) { [weak self] _ in
                self?.tick()
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .defaultMode)
            timer = t
            tick()
            return
        } else if !o.any && was.any {
            if let t = timer { CFRunLoopTimerInvalidate(t) }
            timer = nil
            detach()
        }
        publish()
    }

    private func describe(_ o: Options) -> String {
        [o.close ? "closed when the rack, page or plug-in changes" : nil,
         o.place ? "placed over the rack page" : nil,
         o.reopen ? "the new rack's shown after a move" : nil,
         o.hide ? "SuperRack hidden while another app is in front" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Attaching

    /// Once a second: find SuperRack (it may start, quit or restart), pick the log up again, and
    /// catch anything a notification missed.
    private func tick() {
        status.trusted = AXIsProcessTrusted()
        if options.windows { log.check() }
        if let r = runningSuperRack(), status.trusted {
            if r.processIdentifier != pid || app == nil { attach(r.processIdentifier) }
            // In case a notification was missed: twice running, so a value read just as the front
            // app changes cannot flick the windows.
            if r.isActive != superRackFront {
                frontDisagreed += 1
                if frontDisagreed >= 2 {
                    frontDisagreed = 0
                    frontChanged(r.isActive)
                }
            } else {
                frontDisagreed = 0
            }
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
        hidSuperRack = false
        setReadable(false)
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
            if options.windows { pending.append((.rack(r), time)) }
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

    // MARK: The rack, for the driver

    public var canReadRackName: Bool {
        readableLock.lock(); defer { readableLock.unlock() }
        return readable
    }

    private func setReadable(_ r: Bool) {
        readableLock.lock()
        readable = r
        readableLock.unlock()
        status.readsRack = r
    }

    /// Reads the rack field now, on the guard's thread, waiting at most 0.3 s for it. A name being
    /// typed (the field focused) is no reading.
    public func readRackName() -> String? {
        guard canReadRackName else { return nil }
        final class Box { var name: String? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        perform {
            if let f = self.rackField, (self.value(f, kAXFocusedAttribute) as? Bool) != true {
                let before = self.rack
                self.readRack(at: Date())
                box.name = self.rackField == nil ? nil : self.rack
                // The notification for this change finds it already read: evaluate for it here.
                if self.rack != before { self.schedule(after: 0.1) }
            }
            done.signal()
        }
        return done.wait(timeout: .now() + 0.3) == .success ? box.name : nil
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

    /// Looks at the plug-in windows, then closes, places and hides as the options say.
    private func evaluate() {
        guard app != nil, options.windows else { return }
        // Hidden, SuperRack lists none of its windows (docs/PROTOCOL.md, "Out of sight"). Keep what
        // is known, and take the next look as a first one: windows coming back are not new, so they
        // are neither closed nor placed for having "opened".
        if superRackHidden() {
            firstLook = true
            return
        }
        let now = Date()
        let seen = snapshot(now: now)
        let windows = seen.map { s -> PluginWindow in
            PluginWindow(title: s.title, pinned: (value(s.pin, kAXValueAttribute) as? NSNumber)?.intValue == 1,
                         appeared: s.appeared, minimised: isMinimised(s.element))
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
                for i in PluginWindowPolicy.toClose(windows, after: change, at: time)
                    where !closing.contains(i) && PluginWindowPolicy.canClose(windows[i]) {
                    closing.insert(i)
                    close(i, because: change)
                }
            }
        }
        if options.place {
            for i in known.indices where !known[i].placed && !closing.contains(i) && !windows[i].minimised {
                known[i].placed = true
                // Windows already open when Remora started are left where they are.
                if known[i].appeared != .distantPast { place(known[i]) }
            }
        }
        if options.hide && !hidSuperRack {
            let open = windows.indices.filter { !closing.contains($0) }.map { windows[$0] }
            if PluginWindowPolicy.hidesSuperRack(open, superRackInFront: superRackFront, superRackHidden: false) {
                hidSuperRack = true
                hideSuperRack(showing: open.filter { !$0.minimised }.count)
            }
        }
        status.openWindows = known.count - closing.count
        publish()
    }

    // MARK: Hiding

    private func frontChanged(_ front: Bool) {
        guard front != superRackFront else { return }
        superRackFront = front
        if front { hidSuperRack = false }
        if options.hide { schedule(after: 0) }
    }

    /// Asks SuperRack to hide, as ⌘H would. On macOS 26.4.1 `NSRunningApplication.hide()` answered
    /// false for an app it did hide (a test app with a modal-panel-level window, 2026-11-06), so the
    /// answer is not read: a second later Remora looks whether it went.
    private func hideSuperRack(showing count: Int) {
        guard let r = runningSuperRack() else { return }
        DispatchQueue.main.async { _ = r.hide() }
        note("hid SuperRack: another app is in front, with \(count) plug-in window\(count == 1 ? "" : "s") on screen")
        let check = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1, 0, 0, 0) { [weak self] _ in
            guard let self, self.hidSuperRack, !self.superRackFront, !self.superRackHidden() else { return }
            Log.line("Plug-in windows: SuperRack did not hide")
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), check, .defaultMode)
    }

    private func runningSuperRack() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.superRackBundleID)
            .first { !$0.isTerminated }
    }

    private func superRackHidden() -> Bool { runningSuperRack()?.isHidden ?? false }

    private func isMinimised(_ e: AXUIElement) -> Bool {
        (value(e, kAXMinimizedAttribute) as? Bool) == true
    }

    private func note(_ line: String) {
        Log.line("Plug-in windows: \(line)")
        status.lastAction = line
    }

    /// SuperRack's plug-in windows. Accessibility lists the shown and minimised ones, not those
    /// SuperRack has closed (it keeps them, hidden); a plug-in window is a dialog titled
    /// "<rack>: <plug-in>" with the Pin and Close of SuperRack's own title bar.
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
        setReadable(options.readRack && status.trusted && app != nil && rackField != nil)
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
