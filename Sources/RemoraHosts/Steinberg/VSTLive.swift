import Foundation
import RemoraCore

/// Steinberg VST Live over MIDI, from its operation manual (2.0, pp. 195–199) and its developer's
/// forum answers: three actions the user maps to Remora's CCs. Select Song takes the song's index,
/// from 0, as the CC's value; Next Song and Previous Song step. Activating a song changes what is
/// heard, so the module is behind the sound gate. Nothing else is sent: no volume, preset, quick
/// control, transport or panic action.
public enum VSTLive {
    /// Undefined in the MIDI spec, so no layer's instrument should take them for anything.
    static let selectSong = 102, nextSong = 103, previousSong = 104

    public static let info = ModuleInfo(
        id: "vstlive", kind: .host, title: "VST Live", product: "VST Live",
        maker: "Steinberg", status: .experimental,
        about: "Remora selects a VST Live song with a MIDI action you map in VST Live (Select Song, with the song's number from 0 as the CC's value), and steps with Next Song and Previous Song. Activating a song changes what is heard, as selecting it in VST Live does. VST Live can't say which song is active, so you type the songs in order, and Remora knows only what it last sent: up to 128 songs. Built from VST Live's manual and its developer's forum answers; not run against VST Live.",
        platforms: [.macOS], reach: .local, capabilities: [.showChangesSound],
        hostDefaults: HostDefaults(
            midiChannel: 1, typedRacks: true,
            setUp: """
            1. Devices › Actions & Shortcuts: for Select Song set MIDI In to Remora, MIDI Status to Controller, Chan From and To to the channel above, and Data From and To to 102. Leave Source at Data 2. Then Next Song on 103 and Previous Song on 104.
            2. Type your songs under Racks, in VST Live's order: the first line is song 0.
            3. Keep every layer off Remora's MIDI port: a layer listening to it would play Remora's messages.
            """))

    public static let spec = MIDIHostSpec(
        info: info,
        show: { i, racks in i >= 0 && i < min(racks.count, 128) ? [.cc(number: selectSong, value: i)] : [] },
        step: { d in [.cc(number: d > 0 ? nextSong : previousSong, value: 127)] },
        isAllowed: { m in
            guard case .cc(let n, let v) = m else { return false }
            return (n == selectSong && (0...127).contains(v)) || ((n == nextSong || n == previousSong) && v == 127)
        })

    public static let entry = HostModuleEntry(info) { MIDIHostModule(spec, $0) }
}
