import Foundation
import RemoraCore

/// VSTHost (Hermann Seib) over its OSC, from VSTHost's manual (V1.58, pp. 66–69, 73, 100–102):
/// `/performance/num n` loads performance n, and with no argument VSTHost answers with the one
/// loaded. VSTHost never says by itself, so Remora asks every two seconds. A load replaces the
/// whole setup, so the module is behind the sound gate. Nothing else is sent: every other address
/// takes an argument that changes the engine or a plug-in.
public enum VSTHost {
    public static let info = ModuleInfo(
        id: "vsthost", kind: .host, title: "VSTHost", product: "VSTHost",
        maker: "Hermann Seib", status: .experimental,
        about: "Remora loads a VSTHost performance over OSC (/performance/num), and asks which one is loaded every two seconds. Loading a performance replaces the whole setup, so every move changes what is heard, and with Autosave on VSTHost saves the current performance before it loads another. VSTHost runs on Windows; Remora reaches it over the network. VSTHost can't list its performances by name, so you type them in order. Built from VSTHost's manual (1.58); not run against VSTHost.",
        platforms: [.macOS, .windows, .linux], reach: .network, capabilities: [.showChangesSound],
        hostDefaults: HostDefaults(
            port: 7701, typedRacks: true,
            setUp: """
            1. Engine › Configure › OSC: turn on OSC over UDP, on port 7701 (the default) or the port above.
            2. Type your performances under Racks, in VSTHost's order: the first line is performance 000.
            3. With Performance › Autosave on, VSTHost saves the current performance whenever another loads: back up the performances first.
            """))

    private static let num = "/performance/num"

    public static let spec = OSCHostSpec(
        info: info,
        show: { i, _ in (0...127).contains(i) ? [OSC.Message(address: num, args: [.int(Int32(i))])] : [] },
        ask: [OSC.Message(address: num, args: [])],
        poll: 2,
        read: { m in
            guard m.address == num, let n = m.args.first?.number else { return [] }
            // −1 is in the documented range, and says no performance Remora can show.
            return [.position(n >= 0 ? Int(n) : nil)]
        },
        isAllowed: OSCHostSpec.only([num: ["i", ""]]))

    public static let entry = HostModuleEntry(info) { OSCHostModule(spec, $0) }
}
