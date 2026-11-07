import AppKit
import RemoraCore
import RemoraEngine
import RemoraHosts
import SwiftUI

/// Owns the bridge and publishes its state to the settings window.
final class Model: ObservableObject {
    let bridge: Bridge
    @Published var settings: RemoraCore.Settings
    @Published var status: Bridge.Status
    private let saves: Bool

    convenience init() {
        let s = RemoraCore.Settings.load()
        self.init(settings: s, bridge: Bridge(settings: s), save: true)
    }

    /// `save: false` for the screenshots, which must never touch the real settings file.
    init(settings s: RemoraCore.Settings, bridge: Bridge, save: Bool) {
        settings = s
        self.bridge = bridge
        saves = save
        status = bridge.status
        bridge.onStatus = { [weak self] st in self?.status = st }
        bridge.onSettingsChanged = { [weak self] s in
            guard let self else { return }
            self.settings = s
            if self.saves { s.save() }
        }
    }

    /// Every edit from the window goes through here.
    func edit(_ change: (inout RemoraCore.Settings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        settings = s
        bridge.update(s)
        if saves { s.save() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let model = Model()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        model.bridge.onStatus = { [weak self] st in
            self?.model.status = st
            self?.updateIcon()
        }
        updateIcon()
        model.bridge.start()
        if model.settings.consoleHost.isEmpty { showSettings() }
    }

    func applicationWillTerminate(_ note: Notification) {
        model.bridge.stop()
    }

    private func updateIcon() {
        guard let button = item.button else { return }
        let live = model.status.console == .live
        let symbol = live ? "fish.fill" : "fish"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Remora") {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.title = "R"
        }
        button.appearsDisabled = !live || !model.settings.follow
        button.toolTip = "Remora: \(consoleLine)"
    }

    private var consoleLine: String {
        let host = model.settings.consoleHost
        guard !host.isEmpty else { return "no console set" }
        let model = self.model.status.model ?? "Console"
        switch self.model.status.console {
        case .live: return "\(model) at \(host)"
        case .waitingForDesk: return "\(model) at \(host), waiting for the desk"
        case .connecting: return "connecting to \(host)…"
        case .failed(let why): return "\(host): \(why)"
        case .stopped: return "stopped"
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let st = model.status
        func info(_ s: String) {
            let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        info(consoleLine)
        if let ch = st.selected {
            let name = st.selectedName.map { " “\($0)”" } ?? ""
            let rack = st.mappedRack.map { " → rack \($0.label)" } ?? " → no rack"
            info("Selected: \(ch)\(name)\(rack)")
        }
        let product = model.bridge.hostInfo?.product ?? "Plug-in host"
        if let err = st.sessionError {
            info("\(product): \(err)")
        } else {
            let at = st.position.flatMap { p in st.racks.first { $0.index == p } }
            info("\(product): \(st.racks.count) racks, \(at.map { "on \($0.label)" } ?? "position unknown")")
        }
        menu.addItem(.separator())

        let follow = NSMenuItem(title: "Follow Console Selection", action: #selector(toggleFollow), keyEquivalent: "")
        follow.target = self
        follow.state = model.settings.follow ? .on : .off
        menu.addItem(follow)

        if product == "SuperRack" {
            let close = NSMenuItem(title: "Close Plug-in Windows on Change", action: #selector(toggleClosePluginWindows), keyEquivalent: "")
            close.target = self
            close.state = model.settings.closePluginWindows ? .on : .off
            menu.addItem(close)
        }

        let racks = NSMenuItem(title: "Go to Rack", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for r in st.racks {
            let i = NSMenuItem(title: r.label, action: #selector(goToRack(_:)), keyEquivalent: "")
            i.target = self
            i.tag = r.index
            i.state = st.position == r.index ? .on : .off
            sub.addItem(i)
        }
        racks.submenu = sub
        racks.isEnabled = !st.racks.isEmpty
        menu.addItem(racks)

        add(menu, "Resync \(product)", #selector(resync))
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(showSettingsAction), key: ",")
        if model.settings.pluginHost == SuperRackMIDIModule.info.id {
            add(menu, "Save SuperRack Mapping…", #selector(saveMapping))
        }
        add(menu, "Show Log", #selector(showLog))
        menu.addItem(.separator())
        add(menu, "About Remora", #selector(about))
        add(menu, "Quit Remora", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    @objc private func toggleFollow() {
        model.bridge.setFollow(!model.settings.follow)
        updateIcon()
    }

    @objc private func toggleClosePluginWindows() {
        model.edit { $0.closePluginWindows.toggle() }
    }

    @objc private func goToRack(_ sender: NSMenuItem) { model.bridge.select(rack: sender.tag) }
    @objc private func resync() { model.bridge.resync() }
    @objc private func showSettingsAction() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Remora.log")
        NSWorkspace.shared.open(url)
    }

    @objc private func about() { StoatworksAbout.show() }

    @objc func saveMapping() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        // No allowedContentTypes: .mrrc has no registered type, and the dynamic one made the panel
        // save "Remora.mrrc.mrrc".
        panel.nameFieldStringValue = "Remora.mrrc"
        panel.message = "Import this in SuperRack: Setup › MIDI Controller › Import."
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "mrrc" { url.appendPathExtension("mrrc") }
        let s = model.settings
        do {
            try SuperRackMapping.mrrc(channel: s.midiChannel, ccBase: s.ccBase)
                .write(to: url, atomically: true, encoding: .utf8)
            Log.line("Saved SuperRack mapping to \(url.path)")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Remora"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model, saveMapping: { [weak self] in
                self?.saveMapping()
            }))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
