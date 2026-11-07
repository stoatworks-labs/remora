import Foundation
import RemoraCore

/// Every console module in this build, in the picker's order.
public enum RemoraConsoles {
    public static let all: [ConsoleModuleEntry] = [
        yamahaQL, yamahaCL, yamahaDM, yamahaPM,
        allenHeathQu, allenHeathDLive, allenHeathAvantis, allenHeathSQ,
        behringerX32, behringerWing,
    ]

    /// Yamaha QL: the editor port for the selection, RCP for names. Run on a QL1.
    public static let yamahaQL = ConsoleModuleEntry(ModuleInfo(
        id: "yamaha.ql", legacyIDs: [ConsoleKind.yamahaCLQL.rawValue], kind: .console,
        title: "Yamaha QL", product: "QL", maker: "Yamaha", status: .supported,
        about: "The editor port (TCP 50000) for the selected channel, RCP (TCP 49280) for channel names. Run on a QL1. For a CL, pick Yamaha CL: it is the same code.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.follows, .names, .routing])
    ) { c in
        LinkConsoleModule(YamahaCLQLConsole(host: c.consoleHost, platform: c.platform,
                                            readPatches: c.settings.routingSettings.enabled, entry: .ql))
    }

    /// Yamaha CL: the QL's code, listed apart because it has not been run on a CL.
    public static let yamahaCL = ConsoleModuleEntry(ModuleInfo(
        id: "yamaha.cl", kind: .console,
        title: "Yamaha CL", product: "CL", maker: "Yamaha", status: .experimental,
        about: "The editor port (TCP 50000) for the selected channel, RCP (TCP 49280) for channel names: the code that runs on a QL1. Yamaha publishes one MIDI specification for the CL and QL, and RCP lists the same parameters for both, so a CL should behave the same, but it has not been tried.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.follows, .names, .routing])
    ) { c in
        LinkConsoleModule(YamahaCLQLConsole(host: c.consoleHost, platform: c.platform,
                                            readPatches: c.settings.routingSettings.enabled, entry: .cl))
    }

    /// Yamaha DM7 and DM3: RCP for names and cue, cue as the selection. Documents only.
    public static let yamahaDM = ConsoleModuleEntry(ModuleInfo(
        id: "yamaha.dm", legacyIDs: [ConsoleKind.yamahaDM.rawValue], kind: .console,
        title: "Yamaha DM7 / DM3", product: "DM7 / DM3", maker: "Yamaha", status: .experimental,
        about: "RCP (TCP 49280) for channel names and cue. Yamaha documents no way to read the selected channel on a DM7 or DM3, so Remora follows the channel on cue instead: turn on [CUE] > [SEL] Link (Setup › Preferences), so cueing a channel selects it too, and the cue you press is the rack you get.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.follows, .names])
    ) { c in LinkConsoleModule(YamahaDMConsole(host: c.consoleHost, platform: c.platform)) }

    /// Yamaha RIVAGE PM: RCP for names and cue, cue as the selection. Companion's list only.
    public static let yamahaPM = ConsoleModuleEntry(ModuleInfo(
        id: "yamaha.pm", kind: .console,
        title: "Yamaha RIVAGE PM", product: "RIVAGE PM", maker: "Yamaha", status: .experimental,
        about: "RCP (TCP 49280) for channel names and cue. A PM has no selected-channel parameter, and its screens can show up to three selected channels, so Remora follows the channel last put on cue, A or B, as on a DM. RCP on a PM is known only from Companion's Yamaha RCP module: Yamaha documents OSC instead, and what a PM answers has not been seen.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.follows, .names])
    ) { c in LinkConsoleModule(YamahaPMConsole(host: c.consoleHost, platform: c.platform)) }

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

    /// Allen & Heath dLive: names and controls, no selection. Documents only.
    public static let allenHeathDLive = ConsoleModuleEntry(ModuleInfo(
        id: "allenheath.dlive", legacyIDs: [ConsoleKind.ahDLive.rawValue], kind: .console,
        title: "Allen & Heath dLive", product: "dLive", maker: "Allen & Heath", status: .experimental,
        about: "MIDI over TCP (port 51325, without TLS: set TCP MIDI security to No Security). The dLive says neither which channel is selected nor which is on PAFL, so Remora cannot follow it. It reads channel names, and soft keys and MIDI Strips set to send MIDI can drive SuperRack as learned controls, a rack each with Go to rack. For an Avantis, pick Allen & Heath Avantis.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.names, .needsMIDIChannel])
    ) { c in
        LinkConsoleModule(AllenHeathConsole(family: .dLive, host: c.consoleHost,
                                            midiChannel: c.settings.consoleMIDIChannel, platform: c.platform))
    }

    /// Allen & Heath Avantis: the dLive's code, with Avantis's inputs. Documents only.
    public static let allenHeathAvantis = ConsoleModuleEntry(ModuleInfo(
        id: "allenheath.avantis", kind: .console,
        title: "Allen & Heath Avantis", product: "Avantis", maker: "Allen & Heath", status: .experimental,
        about: "MIDI over TCP (port 51325), with the dLive's messages. Avantis says neither which channel is selected nor which is on PAFL, so Remora cannot follow it. It reads the names of inputs 1–64 (version 2.0's inputs 65–96 are not read yet), and soft keys set to send MIDI can drive SuperRack as learned controls, a rack each with Go to rack. Avantis's MIDI channel is 12 unless it has been changed.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.names, .needsMIDIChannel])
    ) { c in
        LinkConsoleModule(AllenHeathConsole(family: .avantis, host: c.consoleHost,
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

    /// Behringer X32 and Midas M32: the selection polled over OSC, names. Documents only.
    public static let behringerX32 = ConsoleModuleEntry(ModuleInfo(
        id: "behringer.x32", kind: .console,
        title: "Behringer X32 / Midas M32", product: "X32 / M32", maker: "Behringer", status: .experimental,
        about: "OSC over UDP (port 10023). Remora asks the desk which channel is selected five times a second, and reads the names of channels, aux ins, FX returns, buses, matrices and mains. It only asks: it never sends a value, and it takes none of the four push slots (/xremote) other apps use. From Patrick-Gilles Maillot's unofficial X32/M32 OSC document, for firmware 4.0 on; an M32 is taken to behave as an X32.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.follows, .names])
    ) { c in LinkConsoleModule(BehringerConsole(family: .x32, host: c.consoleHost, platform: c.platform)) }

    /// Behringer Wing: the selection polled over OSC, names. Documents only.
    public static let behringerWing = ConsoleModuleEntry(ModuleInfo(
        id: "behringer.wing", kind: .console,
        title: "Behringer Wing", product: "Wing", maker: "Behringer", status: .experimental,
        about: "OSC over UDP (port 2223). Remora asks the desk which channel is selected five times a second, and reads the names of channels, aux, buses, mains and matrices. It only asks: it never sends a value, and it leaves the Wing's one OSC subscription to whatever has it (Companion, say). From the WING Remote Protocols document, for firmware 3.0.5 on. The order of the selection's numbers is worked out from the channel counts: the document doesn't give it.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.follows, .names])
    ) { c in LinkConsoleModule(BehringerConsole(family: .wing, host: c.consoleHost, platform: c.platform)) }
}
