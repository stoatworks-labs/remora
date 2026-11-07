import Foundation
import RemoraCore

/// MainStage over MIDI, from Apple's MainStage User Guide 4.3: a Program Change selects the patch
/// with that number. A patch is a sound, so the module is behind the sound gate. Remora sends a
/// Program Change only for a patch typed for it (an unused number can go on to a channel strip
/// and change a plug-in's preset), never the one it last sent (with Reload Patches from saved
/// state on, that reverts the patch), no Bank Select and no CC.
public enum MainStage {
    public static let info = ModuleInfo(
        id: "mainstage", kind: .host, title: "MainStage", product: "MainStage",
        maker: "Apple", status: .experimental,
        about: "Remora selects a MainStage patch with a Program Change on its MIDI port. A patch is a sound, so every move changes what is heard, as selecting the patch in MainStage does. MainStage can't say which patch is selected, so you type the patches in order and number them in that order, and Remora knows only what it last sent. Built from Apple's MainStage User Guide 4.3; not run against MainStage.",
        platforms: [.macOS], reach: .local, capabilities: [.showChangesSound],
        hostDefaults: HostDefaults(
            midiChannel: 1, typedRacks: true,
            setUp: """
            1. Patch List › Action menu › Reset Program Change Numbers (⌥⇧⌘R), so the numbers follow the list. Skipped patches keep their numbers.
            2. Type your patches under Racks, in the Patch List's order, leaving out skipped patches.
            3. MainStage › Settings › MIDI: Program Change Range 0–127, as Remora sends 0 for the first patch. Leave Reload Patches from saved state off, unless you want a patch to revert when it is selected.
            4. Concert Settings › MIDI: if program changes are taken from one device or channel only, make it Remora and the channel above. Leave Send unused Program Changes to Channel Strips off.
            """))

    public static let spec = MIDIHostSpec(
        info: info,
        show: { i, racks in i >= 0 && i < min(racks.count, 128) ? [.programChange(i)] : [] },
        isAllowed: { m in
            if case .programChange(let p) = m { return (0..<128).contains(p) }
            return false
        })

    public static let entry = HostModuleEntry(info) { MIDIHostModule(spec, $0) }
}
