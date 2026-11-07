import Foundation
import RemoraCore

/// Gig Performer (Deskew) over its OSC, from the Gig Performer 5 manual's OSC pages: Remora
/// switches rackspace by number (from 0) and steps rackspaces. A rackspace that isn't active
/// doesn't process audio, so a switch changes what is heard: the module is behind the sound gate.
/// Nothing else is sent: no variation, song, setlist, tempo, transport, master fader or panic (sent
/// twice in 500 ms it resets the audio engine), and no widget handle.
public enum GigPerformer {
    public static let info = ModuleInfo(
        id: "gigperformer", kind: .host, title: "Gig Performer", product: "Gig Performer",
        maker: "Deskew", status: .experimental,
        about: "Remora switches Gig Performer's rackspace over OSC (/GigPerformer/SwitchToRackSpace, counting from 0) and steps with NextRackSpace and PrevRackSpace. A rackspace that isn't active doesn't process audio, so every switch changes what is heard, as switching in Gig Performer does. OSC needs Gig Performer Pro. Gig Performer's rackspace list and the active rackspace can't be read in a documented form, so you type the rackspaces in order. Built from Gig Performer 5's manual; not run against Gig Performer.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.showChangesSound],
        hostDefaults: HostDefaults(
            port: 54344, typedRacks: true,
            setUp: """
            1. Options › OSC Setup…: tick Enable OSC (Gig Performer Pro), and set the UDP port above to Gig Performer's listening port. Leave Use Lemur augmented OSC messages off.
            2. Type your rackspaces under Racks, in Gig Performer's order: the first line is rackspace 0.
            3. Keep the rackspaces loaded (predictive loading, or enough of them): a switch to one that isn't loaded can wait for it to load.
            """))

    public static let spec = OSCHostSpec(
        info: info,
        show: { i, _ in i >= 0 ? [OSC.Message(address: "/GigPerformer/SwitchToRackSpace", args: [.int(Int32(clamping: i))])] : [] },
        step: { d in [OSC.Message(address: d > 0 ? "/GigPerformer/NextRackSpace" : "/GigPerformer/PrevRackSpace", args: [])] },
        isAllowed: OSCHostSpec.only(["/GigPerformer/SwitchToRackSpace": ["i"],
                                     "/GigPerformer/NextRackSpace": [""], "/GigPerformer/PrevRackSpace": [""]]))

    public static let entry = HostModuleEntry(info) { OSCHostModule(spec, $0) }
}
