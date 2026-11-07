import Foundation
import RemoraCore

/// Logic Pro over MIDI, from Apple's Logic Pro User Guide: two key commands the user assigns to
/// Remora's CCs, Select Previous Track and Select Next Track. Logic can't select a track by number
/// or say which one is selected, so Remora counts. Selecting a track can change what is heard (the
/// focused track is ready to record, and live MIDI goes to the selected track), so the module is
/// behind the sound gate. Nothing else is sent: never a note, which the selected track would play.
public enum Logic {
    /// The two CCs, as SuperRack MIDI's Previous and Next Rack on its default base.
    static let previous = 20, next = 22

    public static let info = ModuleInfo(
        id: "logic", kind: .host, title: "Logic Pro", product: "Logic Pro",
        maker: "Apple", status: .experimental,
        about: "Remora steps Logic's track selection with two key commands you assign to its MIDI, Select Previous Track and Select Next Track, counting from the first track: Logic can't select a track by number or say which one is selected, so you type the tracks in order. Selecting a track can change what is heard: the focused track is ready to record, and live MIDI goes to the selected track. Built from Apple's Logic Pro User Guide; not run against Logic.",
        platforms: [.macOS], reach: .local, capabilities: [.showChangesSound],
        hostDefaults: HostDefaults(
            midiChannel: 16, typedRacks: true,
            setUp: """
            1. Tick “I understand” above, so Remora can send.
            2. Logic Pro › Key Commands › Edit: select Select Previous Track, click Learn New Assignment, and press Previous rack above. Then Select Next Track, with Next rack.
            3. Type every track under Racks, top to bottom, as Logic's Tracks area lists them.
            4. Resync steps back to the first track. A track picked in Logic itself throws the count until Resync.
            """))

    public static let spec = MIDIHostSpec(
        info: info,
        step: { d in [.cc(number: d > 0 ? next : previous, value: 127)] },
        counts: true, spacing: 0.02,
        isAllowed: { m in
            if case .cc(let n, 127) = m { return n == previous || n == next }
            return false
        })

    public static let entry = HostModuleEntry(info) { MIDIHostModule(spec, $0) }
}
