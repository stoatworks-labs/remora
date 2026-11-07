import Foundation
import RemoraCore

/// LiveProfessor (Audiostrom) over its OSC control: Remora selects a chain by number and steps
/// chains, from LiveProfessor's manual (updated July 2026, pp. 54–57). Selecting a chain only
/// selects it. Nothing else is sent: never a Global Snapshot (it restores plug-in settings,
/// routing and gains), a cue, the tempo or a command.
public enum LiveProfessor {
    public static let info = ModuleInfo(
        id: "liveprofessor", kind: .host, title: "LiveProfessor", product: "LiveProfessor",
        maker: "Audiostrom", status: .experimental,
        about: "Remora selects a chain in LiveProfessor over its OSC control (/Chains/Select, counting from 1) and steps with /Chains/Select/Next and /Previous. LiveProfessor can't list its chains or say which one is selected, so you type the chains in order. Global Snapshots, cues and commands are never sent. Built from LiveProfessor's manual; not run against LiveProfessor.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [],
        hostDefaults: HostDefaults(
            port: 8000, typedRacks: true,
            setUp: """
            1. Options › Project Options › Osc Control: tick Enable OSC Control, and set its Input Port to the UDP port above.
            2. Type your chains under Racks, in LiveProfessor's order.
            3. With Enable OSC Triggers on, check that no cue is triggered by /Chains/Select: Remora sends it.
            """))

    public static let spec = OSCHostSpec(
        info: info,
        show: { i, _ in i >= 0 ? [OSC.Message(address: "/Chains/Select", args: [.int(Int32(clamping: i + 1))])] : [] },
        step: { d in [OSC.Message(address: d > 0 ? "/Chains/Select/Next" : "/Chains/Select/Previous", args: [])] },
        isAllowed: OSCHostSpec.only(["/Chains/Select": ["i"], "/Chains/Select/Next": [""], "/Chains/Select/Previous": [""]]))

    public static let entry = HostModuleEntry(info) { OSCHostModule(spec, $0) }
}
