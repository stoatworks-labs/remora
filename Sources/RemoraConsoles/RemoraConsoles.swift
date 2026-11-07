import Foundation
import RemoraCore

/// Every console module in this build, in the picker's order.
public enum RemoraConsoles {
    public static let all: [ConsoleModuleEntry] = [yamahaCLQL, yamahaDM, allenHeathQu, allenHeathDLive, allenHeathSQ]

    /// Yamaha CL and QL: the editor port for the selection, RCP for names. Run on a QL1.
    public static let yamahaCLQL = ConsoleModuleEntry(ModuleInfo(
        id: "yamaha.ql", legacyIDs: [ConsoleKind.yamahaCLQL.rawValue], kind: .console,
        title: "Yamaha CL / QL", product: "CL / QL", maker: "Yamaha", status: .supported,
        about: "The editor port (TCP 50000) for the selected channel, RCP (TCP 49280) for channel names. Run on a QL1. Yamaha publishes one MIDI specification for the CL and QL, so a CL should behave the same, but it has not been tried.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.follows, .names, .routing])
    ) { c in
        LinkConsoleModule(YamahaCLQLConsole(host: c.consoleHost, platform: c.platform,
                                            readPatches: c.settings.routingSettings.enabled))
    }

    /// Yamaha DM7 and DM3: RCP for names and cue, cue as the selection. Documents only.
    public static let yamahaDM = ConsoleModuleEntry(ModuleInfo(
        id: "yamaha.dm", legacyIDs: [ConsoleKind.yamahaDM.rawValue], kind: .console,
        title: "Yamaha DM7 / DM3", product: "DM7 / DM3", maker: "Yamaha", status: .experimental,
        about: "RCP (TCP 49280) for channel names and cue. Yamaha documents no way to read the selected channel on a DM7 or DM3, so Remora follows the channel on cue instead: turn on [CUE] > [SEL] Link (Setup › Preferences), so cueing a channel selects it too, and the cue you press is the rack you get.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.follows, .names])
    ) { c in LinkConsoleModule(YamahaDMConsole(host: c.consoleHost, platform: c.platform)) }

    /// Allen & Heath Qu: PAFL as the selection (with "Sel follows PAFL"), names. Documents only.
    public static let allenHeathQu = ConsoleModuleEntry(ModuleInfo(
        id: "allenheath.qu", legacyIDs: [ConsoleKind.ahQu.rawValue], kind: .console,
        title: "Allen & Heath Qu", product: "Qu", maker: "Allen & Heath", status: .experimental,
        about: "MIDI over TCP (port 51325). The Qu does not say which channel is selected, but it does say which one is on PAFL: turn on Sel follows PAFL (Setup › Audio › PAFL) and PAFL a channel to follow it. Names come from the desk. The Qu takes one TCP MIDI connection at a time, so Remora holds it.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.follows, .names])
    ) { c in
        LinkConsoleModule(AllenHeathConsole(family: .qu, host: c.consoleHost,
                                            midiChannel: c.settings.consoleMIDIChannel, platform: c.platform))
    }

    /// Allen & Heath dLive and Avantis: names and controls, no selection. Documents only.
    public static let allenHeathDLive = ConsoleModuleEntry(ModuleInfo(
        id: "allenheath.dlive", legacyIDs: [ConsoleKind.ahDLive.rawValue], kind: .console,
        title: "Allen & Heath dLive / Avantis", product: "dLive / Avantis", maker: "Allen & Heath",
        status: .experimental,
        about: "MIDI over TCP (port 51325, without TLS: set TCP MIDI security to No Security). dLive and Avantis say neither which channel is selected nor which is on PAFL, so Remora cannot follow them. It reads channel names, and soft keys and MIDI Strips set to send MIDI can drive SuperRack as learned controls, a rack each with Go to rack.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.names, .needsMIDIChannel])
    ) { c in
        LinkConsoleModule(AllenHeathConsole(family: .dLive, host: c.consoleHost,
                                            midiChannel: c.settings.consoleMIDIChannel, platform: c.platform))
    }

    /// Allen & Heath SQ: controls only. Documents only.
    public static let allenHeathSQ = ConsoleModuleEntry(ModuleInfo(
        id: "allenheath.sq", legacyIDs: [ConsoleKind.ahSQ.rawValue], kind: .console,
        title: "Allen & Heath SQ", product: "SQ", maker: "Allen & Heath", status: .experimental,
        about: "MIDI over TCP (port 51325). The SQ's protocol has no channel names and no selection, so Remora cannot follow it. Soft keys set to send a MIDI note, and MIDI strips, can drive SuperRack as learned controls, a rack each with Go to rack.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.needsMIDIChannel])
    ) { c in
        LinkConsoleModule(AllenHeathConsole(family: .sq, host: c.consoleHost,
                                            midiChannel: c.settings.consoleMIDIChannel, platform: c.platform))
    }
}
