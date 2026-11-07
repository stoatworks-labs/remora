import AppKit
import RemoraConsoles
import RemoraCore
import RemoraEngine
import RemoraHosts
import SwiftUI

/// The settings window drawn off screen from made-up demo data, for the README (`--screenshots
/// DIR`) and the video (`--film DIR`). Nothing connects to a desk or SuperRack, no window is
/// ever shown, the rack reader never looks at SuperRack's window, and the real settings file is
/// neither read nor written, so both are safe on a Mac in the middle of a show.
///
/// The film is a still per beat, each the real window after the demo desk's selection has gone
/// through the real Bridge, plus `beats.json` (captions, in the video tooling's format) and
/// `frames.txt` (an ffmpeg concat list that holds each still for its beat).
enum Screenshots {
    // MARK: The demo show

    static let racks = ["Kick", "Snare", "Tom", "OH", "Bass", "Gtr", "Keys", "Vox 1", "Vox 2", "BV", "Playback",
                        "Lectern", "Radio", "n/a", "n/a", "FX"]
        .enumerated().map { Rack(index: $0.offset, name: $0.element) }

    /// Twelve, so the Channels tab shows them all; the ones the film points at sit above the
    /// bottom-left captions.
    static let names: [ConsoleChannel: String] = [
        .input(1): "kick", .input(2): "snare", .input(3): "tom 1", .input(4): "bass", .input(5): "gtr",
        .input(6): "keys", .input(7): "vox1", .input(8): "vox 2", .input(9): "MC", .input(10): "BV1",
        .input(11): "radio 1", .input(12): "OH L",
    ]
    static let kick = ConsoleChannel.input(1), snare = ConsoleChannel.input(2)
    static let vox1 = ConsoleChannel.input(7), vox2 = ConsoleChannel.input(8), mc = ConsoleChannel.input(9)

    // MARK: Routing's demo

    /// The same racks, each with the host inputs that feed it.
    static let routedRacks: [Rack] = {
        let inputs: [[Int]] = [[1], [2], [3], [4, 5], [6], [7], [8, 9], [10], [11], [12], [13, 14], [15], [16], [], [], []]
        return racks.map { Rack(index: $0.index, name: $0.name, inputs: inputs[$0.index]) }
    }()

    /// A stage box both the desk and the host's Dante Virtual Soundcard subscribe to, 1 to 1.
    static let demoPreset = DantePreset(
        name: "Main rig", devices: ["Rio3224-D2", "QL5", "DVS-SuperRack"],
        links: (1...16).flatMap { n in
            [PatchLink(from: AudioPort("Rio3224-D2", .dante, .output, n), to: AudioPort("QL5", .dante, .input, n)),
             PatchLink(from: AudioPort("Rio3224-D2", .dante, .output, n), to: AudioPort("DVS-SuperRack", .dante, .input, n))]
        })

    /// Each channel's input patch on the desk: the bass on Dante 6, and "radio 1" patched to the
    /// playback's input by mistake, so routing and the name disagree.
    static let demoPatch: [ConsoleChannel: [AudioPort]] = Dictionary(uniqueKeysWithValues:
        [1, 2, 3, 6, 7, 8, 10, 11, 15, 12, 13, 4].enumerated().map { i, n in
            (ConsoleChannel.input(i + 1), [AudioPort(AudioPort.desk, .dante, .input, n)])
        })

    static func demoSettings(routing: Bool = false) -> RemoraCore.Settings {
        var s = RemoraCore.Settings()
        s.consoleHost = "192.168.0.128"
        s.noRack = .stay
        s.closePluginWindows = true
        s.placePluginWindows = true
        s.reopenPluginAfterRackChange = true
        // The MC's mic shares the lectern's rack.
        s.overrides = [mc.key: 11]
        var next = ControlMapping()
        next.name = "Next rack"
        next.action = .nextRack
        next.source = .yamaha(YamahaSysEx.Address(element: 0x0035, index: 0, channel: 47))
        var vox = ControlMapping()
        vox.name = "Vox rack"
        vox.action = .goToRack
        vox.rack = 7
        vox.source = .yamaha(YamahaSysEx.Address(element: 0x0035, index: 0, channel: 46))
        var snap = ControlMapping()
        snap.name = "De-ess on"
        snap.action = .sendCC
        snap.mode = .onOff
        snap.cc = 31
        snap.source = .midi(source: "X-Touch Mini", kind: .note, channel: 1, number: 8)
        s.controls = [next, vox, snap]
        if routing {
            s.routingSettings.enabled = true
            s.routingSettings.dante = demoPreset
            s.routingSettings.deskDante = "QL5"
            s.routingSettings.hostDante = "DVS-SuperRack"
            s.routingSettings.runs = ["desk channel out 1-32 > desk dante out 1"]
        }
        return s
    }

    /// The status as a desk that is up would leave it; the bridge's own fields (selection,
    /// rack) are kept.
    static func dressed(_ st: Bridge.Status, console: String = RemoraConsoles.yamahaQL.info.id,
                        host: String = SuperRackMIDIModule.info.id) -> Bridge.Status {
        var st = st
        switch console {
        case RemoraConsoles.yamahaQL.info.id:
            st.console = .live
            st.model = "QL5"
            st.namesConnected = true
        default:
            // An experimental desk is shown looking for its desk, not pretending to have one.
            st.console = .connecting
            st.model = nil
            st.namesConnected = false
            st.selected = nil
            st.selectedName = nil
            st.mappedRack = nil
        }
        st.midiReady = true
        st.pluginWindows.trusted = true
        st.pluginWindows.attached = true
        st.pluginWindows.logOpen = true
        st.pluginWindows.readsRack = true
        st.pluginWindows.openWindows = 1
        st.pluginWindows.lastAction = "closed Vox 2: Pro-Q 4 (rack is now Vox 1)"
        if host == SuperRackProLinkModule.info.id {
            // Waiting for SuperRack to dial in: the ProLink module has not met one yet.
            st.hostLink = .listening(50002)
            st.sessionError = "not connected (Remora is waiting on TCP 50002)"
            st.racks = []
            st.position = nil
            st.mappedRack = nil
            st.pluginWindows.readsRack = false
        }
        return st
    }

    final class Stage {
        let bridge: Bridge
        let model: Model
        var console = RemoraConsoles.yamahaQL.info.id
        var host = SuperRackMIDIModule.info.id

        /// `routing`: with routing on from the start, so the bridge never reconnects the desk link
        /// (it is never started, and nothing connects).
        init(routing: Bool = false) {
            let s = Screenshots.demoSettings(routing: routing)
            bridge = Bridge(settings: s, sink: Silent())
            // Counting only: the rack reader would look at the real SuperRack's window.
            bridge.setRackReaderForTesting(nil)
            bridge.setRacksForTesting(routing ? Screenshots.routedRacks : Screenshots.racks)
            bridge.setNamesForTesting(Screenshots.names)
            if routing { bridge.setRoutesForTesting(Screenshots.demoPatch) }
            model = Model(settings: s, bridge: bridge, save: false)
        }

        /// What the desk's SEL key would do, through the bridge the desk link feeds.
        func select(_ ch: ConsoleChannel) {
            bridge.selectionForTesting(ch)
            bridge.driverForTesting.waitUntilIdle()
            settle()
        }

        /// Shows another desk in the window without connecting to anything: the settings are
        /// set on the model only, never handed to the bridge.
        func show(_ entry: ConsoleModuleEntry) {
            console = entry.info.id
            var s = model.settings
            s.console = entry.info.id
            model.settings = s
            settle()
        }

        /// Shows another plug-in host in the window, as `show` does a desk: on the model only, so
        /// nothing listens or connects. `own` is that host's own settings.
        func show(host id: String, own: HostSettings? = nil) {
            host = id
            var s = model.settings
            s.pluginHost = id
            if let own { s.setHost(id, own) }
            model.settings = s
            settle()
        }

        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            var st = Screenshots.dressed(bridge.status, console: console, host: host)
            // Any other host: its typed racks, and the gate as its settings leave it. It hasn't met
            // the host, so it says nothing of where the host is.
            if let info = bridge.registry.host(host)?.info, info.product != "SuperRack" {
                let own = model.settings.host(host)
                st.racks = own.typedRacks
                st.position = nil
                st.mappedRack = nil
                st.sessionError = nil
                st.hostLink = nil
                st.pluginWindows = PluginWindowStatus()
                st.hostGated = info.capabilities.contains(.showChangesSound) && !own.showChangesSoundAccepted
            }
            model.status = st
        }

        func render(_ tab: SettingsView.Tab, size: NSSize, to file: URL) -> Bool {
            render(SettingsView(model: model, saveMapping: {}, tab: tab), size: size, to: file)
        }

        func render<V: View>(_ content: V, size: NSSize, to file: URL) -> Bool {
            // cacheDisplay draws no window background, so paint it in.
            let view = content
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            // A window that is never ordered in: the view needs one to lay out and draw.
            let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            defer { w.contentView = nil }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: file)) != nil
        }
    }

    private static func begin(_ dir: String) -> URL {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    // MARK: Screenshots

    static func render(to dir: String) -> Int32 {
        let out = begin(dir)
        let stage = Stage()
        stage.select(vox1)
        var failed = false
        for tab in [SettingsView.Tab.console, .host, .channels, .controls, .companion] {
            let file = out.appendingPathComponent("settings-\(tab.slug).png")
            if stage.render(tab, size: NSSize(width: 640, height: 560), to: file) { print(file.path) } else { failed = true }
        }
        stage.show(RemoraConsoles.allenHeathQu)
        let file = out.appendingPathComponent("settings-console-qu.png")
        if stage.render(.console, size: NSSize(width: 640, height: 560), to: file) { print(file.path) } else { failed = true }
        stage.show(host: SuperRackProLinkModule.info.id)
        let proLink = out.appendingPathComponent("settings-host-prolink.png")
        if stage.render(.host, size: NSSize(width: 640, height: 760), to: proLink) { print(proLink.path) } else { failed = true }
        // A host behind the sound gate, before the tick.
        var gig = HostSettings()
        gig.racks = ["Piano", "Organ", "Strings", "Pads", "Lead"]
        stage.show(host: GigPerformer.info.id, own: gig)
        let gated = out.appendingPathComponent("settings-host-gigperformer.png")
        if stage.render(.host, size: NSSize(width: 640, height: 1060), to: gated) { print(gated.path) } else { failed = true }
        // Routing, on a stage of its own.
        let routed = Stage(routing: true)
        routed.select(vox1)
        let channels = out.appendingPathComponent("settings-channels-routing.png")
        if routed.render(.channels, size: NSSize(width: 800, height: 560), to: channels) { print(channels.path) } else { failed = true }
        let sheet = out.appendingPathComponent("settings-routing.png")
        if routed.render(RoutingSheet(model: routed.model), size: NSSize(width: 560, height: 640), to: sheet) {
            print(sheet.path)
        } else { failed = true }
        return failed ? 1 : 0
    }

    // MARK: Film

    private struct Beat {
        let t: Double
        let tab: SettingsView.Tab
        let caption: String?
        let action: (Stage) -> Void
    }

    /// The take, in seconds. A caption holds until the next one; the last beat marks the end.
    private static let beats: [Beat] = [
        Beat(t: 0, tab: .console, caption: nil) { $0.select(kick) },
        Beat(t: 1, tab: .console,
             caption: "SuperRack has no idea which channel the engineer is working on. Remora tells it.") { _ in },
        Beat(t: 6, tab: .console,
             caption: "Press SEL on a Yamaha CL or QL, and SuperRack goes to that channel's rack.") { $0.select(snare) },
        Beat(t: 9, tab: .console, caption: nil) { $0.select(vox1) },
        Beat(t: 12, tab: .channels,
             caption: "Racks are found by name: the channel called vox 2 gets the rack called Vox 2.") { _ in },
        Beat(t: 15, tab: .channels, caption: nil) { $0.select(vox2) },
        Beat(t: 18, tab: .channels,
             caption: "Or give a channel its rack by hand: the MC's mic shares the lectern's.") { $0.select(mc) },
        Beat(t: 23, tab: .host,
             caption: "SuperRack's MIDI only steps one rack at a time. Remora reads which rack it is on, so a move is a few steps 2 ms apart.") { _ in },
        Beat(t: 30, tab: .controls,
             caption: "A spare key on the desk can step racks, jump to a given rack, or send SuperRack any CC it can learn.") { _ in },
        Beat(t: 36, tab: .console,
             caption: "New in 0.3: Yamaha DM7 and DM3, and Allen & Heath Qu, SQ, dLive and Avantis, built from the manuals and not yet tried on a desk.") { $0.show(RemoraConsoles.allenHeathQu) },
        Beat(t: 43, tab: .console,
             caption: "Remora 0.3.0 for macOS. More Yamaha and Allen & Heath desks are on the way.") { $0.show(RemoraConsoles.yamahaQL); $0.select(vox1) },
        Beat(t: 48, tab: .console, caption: nil) { _ in },
    ]

    static func film(to dir: String) -> Int32 {
        let out = begin(dir)
        let stage = Stage()
        var list = "ffconcat version 1.0\n"
        var json: [[String: Any]] = []
        for (i, beat) in beats.enumerated() {
            beat.action(stage)
            json.append(["t": beat.t, "caption": beat.caption ?? NSNull(), "focus": NSNull(), "address": beat.tab.rawValue])
            guard i + 1 < beats.count else { break }
            let file = out.appendingPathComponent(String(format: "beat-%02d.png", i))
            // 960 x 540 points, drawn at 2x: 1920 x 1080, the window filling the frame.
            guard stage.render(beat.tab, size: NSSize(width: 960, height: 540), to: file) else { return 1 }
            list += "file '\(file.lastPathComponent)'\nduration \(beats[i + 1].t - beat.t)\n"
            print(file.path)
        }
        // The concat demuxer takes the last file's duration only if it is listed again.
        list += "file '\(String(format: "beat-%02d.png", beats.count - 2))'\n"
        do {
            try list.write(to: out.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
            let data = try JSONSerialization.data(withJSONObject: ["beats": json], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: out.appendingPathComponent("beats.json"))
        } catch {
            return 1
        }
        return 0
    }

    private final class Silent: CCSink {
        func sendCC(channel: Int, number: Int, value: Int) {}
        func sendProgramChange(channel: Int, program: Int) {}
    }
}
